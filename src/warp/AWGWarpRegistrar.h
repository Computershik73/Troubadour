//
//  AWGWarpRegistrar.h
//  YouTube
//
//  Automatic AmneziaWG config generation, the way the Android bypass clients
//  do it: register a throwaway device with Cloudflare WARP, keep the private
//  key local, and wrap the peer Cloudflare hands back in a fixed AmneziaWG
//  obfuscation profile.
//

#import <Foundation/Foundation.h>

@class AWGConfig;

extern NSString * const kAWGWarpErrorDomain;

@interface AWGWarpRegistrar : NSObject

// Registers a fresh WARP identity and returns a ready-to-connect config.
// The completion runs on the main thread.
+ (void)generateConfigWithCompletion:(void(^)(AWGConfig *config, NSError *error))completion;

// Same, but reusing an existing private key (keeps the peer's routing stable
// across re-registration).
+ (void)generateConfigWithPrivateKey:(NSString *)privateKeyBase64
                          completion:(void(^)(AWGConfig *config, NSError *error))completion;

// A WARP identity registered ahead of time and shipped with the app, for when
// the registration API cannot be reached at all. This is what the Android
// bypass clients keep in warp_verified_seeds.json — a tunnel you can bring up
// on a network where nothing else gets out. Shared between everyone running
// this build, so it is a fallback, not the normal path.
// Troubadour: nil, если сборка без ключа (нет AWGSecrets.h).
+ (AWGConfig *)bundledSeedConfig;

// A random Cloudflare anycast endpoint from the public WARP ranges, as
// "host:port". Used for rotation when an endpoint gets throttled.
+ (NSString *)randomWarpEndpoint;

// Все публичные /24 WARP ("162.159.192" и т.д.) — для выбора дата-центра.
+ (NSArray *)warpPrefixes;

// Re-point an existing config at a fresh endpoint without re-registering.
+ (void)rotateEndpointForConfig:(AWGConfig *)config;

// The AmneziaWG obfuscation profile applied to WARP peers ("warp-awg-exact"):
// Jc=4/Jmin=40/Jmax=70, no S-padding, vanilla H1..H4 so the reserved bytes
// still fit, and SIP-shaped I1/I2 signature packets.
+ (void)applyWarpObfuscationProfile:(AWGConfig *)config;

@end
