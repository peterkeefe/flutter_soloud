#import "FlutterSoloudPlugin.h"

#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>

// ── Engine-lifecycle entry points, resolved at runtime ───────────────────────
//
// These three functions live in the native code asset that hook/build.dart
// builds and bundles as a dynamic library. They are looked up with dlsym()
// rather than called directly, so this translation unit contributes NO
// undefined symbols to whatever binary it is linked into.
//
// Why not link against them:
//
//   • Under `use_frameworks! :linkage => :static` — which FlutterFire
//     requires, and which FlutterFlow's generated Podfile uses — this pod has
//     no link step of its own. Direct references are deferred to the
//     application's link, where the pod's own OTHER_LDFLAGS do not apply, and
//     fail: "Undefined symbol: _prepareEngineInitForRequest".
//
//   • Propagating `-undefined dynamic_lookup` to the application target would
//     fix the link, but it makes the entire app binary tolerate flat-namespace
//     undefined symbols. Under chained fixups those bind at LAUNCH, before any
//     Dart code has run and therefore before the code asset is a loaded image
//     — trading a build failure for a possible launch crash in every app,
//     whether or not it ever plays a sound.
//
// dlsym() has neither problem: there is nothing to bind, and a failed lookup
// becomes a FlutterError rather than a dead process.
//
// `engine_lifecycle.h` is deliberately NOT included. Its declarations are
// reproduced as function-pointer typedefs below, so a future direct call
// cannot silently reintroduce a link-time reference.
//
// Signatures mirror src/engine_lifecycle.h exactly.
typedef bool (*FSPrepareEngineInitForRequest)(int64_t owner_engine_id,
                                              uint64_t shutdown_epoch);
typedef bool (*FSClearDartCallbackRegistrationsForEngine)(int64_t engine_id);
typedef bool (*FSRequestEngineTeardownForEngine)(int64_t engine_id);

static FSPrepareEngineInitForRequest fsPrepareEngineInitForRequest = NULL;
static FSClearDartCallbackRegistrationsForEngine
    fsClearDartCallbackRegistrationsForEngine = NULL;
static FSRequestEngineTeardownForEngine fsRequestEngineTeardownForEngine = NULL;

/// Resolve the three entry points against every image dyld has loaded.
///
/// Deliberately NOT dispatch_once: a lookup attempted before Dart has opened
/// the code asset must stay retryable, not be cached as permanently
/// unavailable. Only successful pointers are kept.
///
/// Called only from the platform thread, like everything else in this file
/// (see the ivar note in the @implementation), so the unsynchronised statics
/// need no locking — and adding any would contradict that contract.
static BOOL FSResolveEngineLifecycle(void) {
  if (fsPrepareEngineInitForRequest != NULL &&
      fsClearDartCallbackRegistrationsForEngine != NULL &&
      fsRequestEngineTeardownForEngine != NULL) {
    return YES;
  }
  // No leading underscore: dlsym() applies the platform's symbol prefix.
  if (fsPrepareEngineInitForRequest == NULL) {
    fsPrepareEngineInitForRequest = (FSPrepareEngineInitForRequest)dlsym(
        RTLD_DEFAULT, "prepareEngineInitForRequest");
  }
  if (fsClearDartCallbackRegistrationsForEngine == NULL) {
    fsClearDartCallbackRegistrationsForEngine =
        (FSClearDartCallbackRegistrationsForEngine)dlsym(
            RTLD_DEFAULT, "clearDartCallbackRegistrationsForEngine");
  }
  if (fsRequestEngineTeardownForEngine == NULL) {
    fsRequestEngineTeardownForEngine = (FSRequestEngineTeardownForEngine)dlsym(
        RTLD_DEFAULT, "requestEngineTeardownForEngine");
  }
  return fsPrepareEngineInitForRequest != NULL &&
         fsClearDartCallbackRegistrationsForEngine != NULL &&
         fsRequestEngineTeardownForEngine != NULL;
}

/// The engine-local channel Dart uses to hand this plugin its engine id.
///
/// iOS does not publicly expose the owning FlutterEngine's id to a plugin —
/// unlike Android, where `FlutterEngine.getEngineId()` is public — so the id
/// has to come from the isolate, which reads it from
/// `PlatformDispatcher.instance.engineId`.
static NSString *const kEngineLifecycleChannel =
    @"flutter_soloud/engine_lifecycle";

/// Matches `kNoEngineId` in the shared C++ implementation.
static const int64_t kNoEngineId = -1;

@implementation FlutterSoloudPlugin {
  /// All of this is touched only from the platform thread: method calls are
  /// delivered there, and `detachFromEngineForRegistrar:` runs from
  /// `FlutterEngine dealloc`. No synchronization needed, and none should be
  /// added without revisiting that.
  FlutterMethodChannel *_channel;
  int64_t _engineId;
  BOOL _hasEngineId;
  BOOL _detached;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  // Deliberately does no native work. This runs at engine startup for every app
  // that depends on the plugin, whether or not it ever plays a sound: it must
  // stay a channel registration and nothing more.
  FlutterSoloudPlugin *instance = [[FlutterSoloudPlugin alloc] init];
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:kEngineLifecycleChannel
                                  binaryMessenger:[registrar messenger]];
  // Direct ivar access: legal from inside this @implementation, and avoids
  // publishing a setter that nothing else should call.
  instance->_channel = channel;
  [registrar addMethodCallDelegate:instance channel:channel];

  // Required: FlutterEngine only calls detachFromEngineForRegistrar: on
  // instances it has published. Without this the engine would deallocate with
  // no notification, which is the whole point of this class.
  [registrar publish:instance];
}

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _engineId = kNoEngineId;
    _hasEngineId = NO;
    _detached = NO;
  }
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall *)call
                  result:(FlutterResult)result {
  if (![call.method isEqualToString:@"prepareEngineInit"]) {
    result(FlutterMethodNotImplemented);
    return;
  }

  if (_detached) {
    // The engine is already going away; claiming for it would leave a claim
    // that nothing can ever retire.
    result([FlutterError errorWithCode:@"engine_detached"
                               message:@"The FlutterEngine is being destroyed."
                               details:nil]);
    return;
  }

  NSDictionary *arguments = call.arguments;
  if (![arguments isKindOfClass:[NSDictionary class]]) {
    result([FlutterError errorWithCode:@"invalid_arguments"
                               message:@"Expected a map of prepare arguments."
                               details:nil]);
    return;
  }

  NSNumber *engineIdArgument = arguments[@"engineId"];
  NSNumber *epochArgument = arguments[@"shutdownEpoch"];
  if (![engineIdArgument isKindOfClass:[NSNumber class]] ||
      ![epochArgument isKindOfClass:[NSNumber class]]) {
    result([FlutterError
        errorWithCode:@"invalid_arguments"
              message:@"Expected an engine id and a shutdown epoch."
              details:nil]);
    return;
  }

  const int64_t engineId = [engineIdArgument longLongValue];
  if (engineId == kNoEngineId) {
    result([FlutterError
        errorWithCode:@"invalid_engine_id"
              message:@"The engine id is the no-engine sentinel."
              details:nil]);
    return;
  }

  const uint64_t shutdownEpoch =
      (uint64_t)[epochArgument unsignedLongLongValue];

  // Resolve before taking any claim: a refused request must leave the native
  // state untouched, and an unresolvable one has taken nothing to retire.
  if (!FSResolveEngineLifecycle()) {
    result([FlutterError
        errorWithCode:@"engine_lifecycle_unavailable"
              message:@"The flutter_soloud native code asset is not loaded."
              details:nil]);
    return;
  }

  // Claimed here, before the reply, so the claim exists before Dart dispatches
  // the initialization. Opening the audio device takes a while, and an engine
  // deallocated during that window must still have something to tear down;
  // claiming after the reply would leave a gap where it does not.
  //
  // Conditional on the epoch Dart read before it sent this: `deinit()` can run
  // while Dart is suspended waiting for the reply, and a claim landing after
  // that teardown would lower the shutdown flag and record ownership for an
  // engine that is already gone.
  if (!fsPrepareEngineInitForRequest(engineId, shutdownEpoch)) {
    result([FlutterError
        errorWithCode:@"stale_prepare"
              message:@"This initialization was superseded by a shutdown."
              details:nil]);
    return;
  }

  // Only now is this plugin associated with the engine: a refused request must
  // not arm a teardown, because it took no claim to tear down.
  _engineId = engineId;
  _hasEngineId = YES;

  // Hot-restart recovery. iOS has no public equivalent of Android's
  // onPreEngineRestart(), so a restart leaves the previous isolate's callables
  // registered under this same engine id. This is the first point a supported
  // API can retire them. It is scoped to this engine, and the new isolate has
  // not registered its own callables yet, so it can only ever retire stale
  // same-engine ones.
  //
  // After the claim rather than before: a refused claim must leave everything
  // untouched, including a newer engine's callables.
  fsClearDartCallbackRegistrationsForEngine(engineId);

  result(@(YES));
}

- (void)detachFromEngineForRegistrar:
    (NSObject<FlutterPluginRegistrar> *)registrar {
  // Reached from FlutterEngine's dealloc, which notifies plugins before it
  // tears the rest of the engine down. It runs on the platform thread, so
  // everything here must return immediately: the blocking part of the teardown
  // (stopping the device, joining the scheduler) happens on a native worker.
  _detached = YES;
  [_channel setMethodCallHandler:nil];
  _channel = nil;

  if (!_hasEngineId) {
    // No handshake ever completed, so this plugin does not know which engine it
    // belongs to. Tearing down "whatever is current" would let a dying engine
    // destroy a replacement, so do nothing at all.
    return;
  }

  const int64_t engineId = _engineId;
  _hasEngineId = NO;
  _engineId = kNoEngineId;

  // This retires the engine's callables first — unconditionally, even when the
  // teardown itself is refused because another engine now owns the native
  // engine — and only then decides whether this engine may dispose it. One
  // call covers both; a separate retirement here would be redundant.
  // Unreachable with a NULL pointer in practice: _hasEngineId is only YES
  // after a claim succeeded, which required these to resolve. Guarded anyway
  // — this runs inside FlutterEngine's dealloc and must never crash.
  if (FSResolveEngineLifecycle()) {
    fsRequestEngineTeardownForEngine(engineId);
  }
}

@end
