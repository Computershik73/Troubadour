//
//  AWGWarpRegistrar.m
//  YouTube
//

#import "AWGWarpRegistrar.h"
#import "AWGConfig.h"
#import "AWGCrypto.h"
#import "TLSTrustManager.h"
#import "AWGHTTPSTransport.h"
#import "AmneziaWGManager.h"
#import "DebugLog.h"

// Troubadour: ключ запасной личности — не в исходниках (см. AWGSecrets.example.h).
#if __has_include("AWGSecrets.h")
#import "AWGSecrets.h"
#else
#import "AWGSecrets.example.h"
#endif

#include <unistd.h>

NSString * const kAWGWarpErrorDomain = @"AWGWarpRegistrar";

// Cloudflare's own client API. The version string has to look like a real
// WARP client build or the endpoint answers 400.
static NSString * const kWarpRegURL       = @"https://api.cloudflareclient.com/v0a4471/reg";
static NSString * const kWarpClientVer    = @"a-6.30-3596";
static NSString * const kWarpUserAgent    = @"okhttp/3.12.1";

// Override in NSUserDefaults to point at a self-hosted generator that speaks
// the same JSON back — useful when the API itself is blocked.
static NSString * const kWarpRelayDefaultsKey = @"awg_warp_relay_url";

// Pinned addresses for api.cloudflareclient.com. System DNS is not trustworthy
// here: on a ТСПУ-filtered network the A records come back forged (we were
// handed 8.47.69.0, a network address inside a WARP endpoint range). Since we
// run TLS ourselves, the SNI stays correct no matter which address we dial.
static NSString * const kWarpAPIPinnedIPs[] = {
    @"104.16.192.82", @"104.16.24.84"
};
#define kWarpAPIPinnedCount (sizeof(kWarpAPIPinnedIPs) / sizeof(kWarpAPIPinnedIPs[0]))

// Public WARP anycast ranges. Each /24 answers on the whole port list below,
// which is what makes endpoint rotation cheap.
static NSString * const kWarpPrefixes[] = {
    @"162.159.192", @"162.159.193", @"162.159.195",
    @"188.114.96",  @"188.114.97",  @"188.114.98",  @"188.114.99",
    @"8.6.112",     @"8.34.70",     @"8.34.146",    @"8.35.211",
    @"8.39.125",    @"8.39.204",    @"8.39.214",    @"8.47.69"
};
static const NSUInteger kWarpPrefixCount = sizeof(kWarpPrefixes) / sizeof(kWarpPrefixes[0]);

static const uint16_t kWarpPorts[] = {
    500,  854,  859,  864,  878,  880,  890,  891,  894,  903,
    908,  928,  934,  939,  942,  945,  946,  955,  968,  987,
    988,  1002, 1010, 1014, 1018, 1070, 1074, 1180, 1387, 1701,
    1843, 2371, 2408, 2506, 3138, 3476, 3581, 3854, 4177, 4198,
    4500, 5279, 5956, 7103, 7152, 7156, 7281, 7559, 8319, 8742,
    8854, 8886
};
static const NSUInteger kWarpPortCount = sizeof(kWarpPorts) / sizeof(kWarpPorts[0]);

@implementation AWGWarpRegistrar

#pragma mark - Endpoints

+ (NSString *)randomWarpEndpoint {
    NSString *prefix = kWarpPrefixes[arc4random_uniform((uint32_t)kWarpPrefixCount)];
    uint32_t host = 1 + arc4random_uniform(10);          // .1 - .10 are the live ones
    uint16_t port = kWarpPorts[arc4random_uniform((uint32_t)kWarpPortCount)];
    return [NSString stringWithFormat:@"%@.%u:%u", prefix, (unsigned)host, (unsigned)port];
}

+ (NSArray *)warpPrefixes {
    NSMutableArray *all = [NSMutableArray array];
    for (NSUInteger i = 0; i < kWarpPrefixCount; i++) [all addObject:kWarpPrefixes[i]];
    return all;
}

+ (void)rotateEndpointForConfig:(AWGConfig *)config {
    if (!config) return;
    NSString *old = config.peerEndpoint;
    NSString *next = nil;

    // Stay on the IP Cloudflare assigned us and just change port while we still
    // have its advertised list; only fall back to a blind anycast guess after that.
    NSRange colon = [old rangeOfString:@":" options:NSBackwardsSearch];
    NSString *host = (old.length > 0 && colon.location != NSNotFound) ? [old substringToIndex:colon.location] : nil;
    if (host.length > 0 && config.preferredPorts.count > 1) {
        NSUInteger tries = 0;
        do {
            NSNumber *port = config.preferredPorts[arc4random_uniform((uint32_t)config.preferredPorts.count)];
            next = [NSString stringWithFormat:@"%@:%@", host, port];
        } while ([next isEqualToString:old] && ++tries < 8);
    }
    if (next.length == 0 || [next isEqualToString:old]) {
        next = [self randomWarpEndpoint];
        if ([next isEqualToString:old]) next = [self randomWarpEndpoint];
    }
    config.peerEndpoint = next;
    DLog(@"[AWG] endpoint rotated: %@ -> %@", old ?: @"(none)", next);
}

#pragma mark - Obfuscation profile

// I1/I2 are shaped like a SIP call setup: a class of traffic that is normal on
// UDP, is not itself interesting to a DPI box, and explains a burst of small
// datagrams followed by a long flow.
static NSData *sipSignature(NSString *text) {
    NSString *crlf = [text stringByReplacingOccurrencesOfString:@"\n" withString:@"\r\n"];
    return [crlf dataUsingEncoding:NSUTF8StringEncoding];
}

static NSString *hexSignature(NSData *data) {
    NSMutableString *hex = [NSMutableString stringWithString:@"<b 0x"];
    const uint8_t *b = data.bytes;
    NSUInteger i;
    for (i = 0; i < data.length; i++) [hex appendFormat:@"%02x", b[i]];
    [hex appendString:@">"];
    return hex;
}

+ (void)applyWarpObfuscationProfile:(AWGConfig *)config {
    if (!config) return;

    config.junkCount = 4;
    config.junkMin = 40;
    config.junkMax = 70;
    config.s1 = 0;
    config.s2 = 0;
    config.s3 = 0;
    config.s4 = 0;
    // Vanilla header values on purpose: WARP needs bytes 1..3 of the type field
    // for the reserved client_id, which only works while H1..H4 stay 1/2/3/4.
    config.h1 = 1;
    config.h2 = 2;
    config.h3 = 3;
    config.h4 = 4;
    config.mtu = 1280;
    config.allowedIPs = @"0.0.0.0/0, ::/0";
    config.dnsServers = @"1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, 2606:4700:4700::1001";

    NSString *invite =
        @"INVITE sip:bob@biloxi.com SIP/2.0\n"
        @"Via: SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bK776asdhds\n"
        @"Max-Forwards: 70\n"
        @"To: Bob <sip:bob@biloxi.com>\n"
        @"From: Alice <sip:alice@atlanta.com>;tag=1928301774\n"
        @"Call-ID: a84b4c76e66710@pc33.atlanta.com\n"
        @"CSeq: 314159 INVITE\n"
        @"Contact: <sip:alice@pc33.atlanta.com>\n"
        @"Content-Type: application/sdp\n"
        @"Content-Length: 0\n\n";

    NSString *trying =
        @"SIP/2.0 100 Trying\n"
        @"Via: SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bK776asdhds\n"
        @"To: Bob <sip:bob@biloxi.com>\n"
        @"From: Alice <sip:alice@atlanta.com>;tag=1928301774\n"
        @"Call-ID: a84b4c76e66710@pc33.atlanta.com\n"
        @"CSeq: 314159 INVITE\n"
        @"Content-Length: 0\n\n";

    config.i1 = hexSignature(sipSignature(invite));
    config.i2 = hexSignature(sipSignature(trying));
    config.i3 = nil;
    config.i4 = nil;
    config.i5 = nil;
}

#pragma mark - Bundled seed

+ (AWGConfig *)bundledSeedConfig {
    if ([AWG_BUNDLED_PRIVATE_KEY length] == 0) {
        DLog(@"[AWG] вшитого ключа нет — сборка без AWGSecrets.h");
        return nil;
    }

    AWGConfig *c = [AWGConfig configWithDefaults];
    c.label = @"WARP (вшитый резерв)";
    c.privateKey    = AWG_BUNDLED_PRIVATE_KEY;
    c.peerPublicKey = AWG_BUNDLED_PEER_PUBLIC_KEY;
    c.warpClientID  = @"AEOY";
    c.ipv4Address   = @"172.16.0.2/32";
    c.ipv6Address   = @"2606:4700:110:8d95:a92:92b6:b54a:d22f/128";
    c.publicKey     = [AWGCrypto base64Encode:[AWGCrypto publicKeyFromPrivateKey:
                                               [AWGCrypto base64Decode:c.privateKey]]];
    c.preferredPorts = @[@2408, @500, @1701, @4500];
    c.peerEndpoint  = [NSString stringWithFormat:@"162.159.192.5:%@",
                       c.preferredPorts[arc4random_uniform((uint32_t)c.preferredPorts.count)]];
    [self applyWarpObfuscationProfile:c];
    return c;
}


/*
 * Troubadour: путь через /usr/bin/vless-core-curl убран.
 *
 * У автора регистрация могла идти через внешнюю программу, если она
 * лежит на устройстве (её ставит его же пакет). Приложение не должно
 * запускать чужие исполняемые файлы: регистрация идёт тем же
 * AWGHTTPSTransport через SOCKS туннеля, что и у автора без помощника.
 */

#pragma mark - Registration

static NSString *randomInstallID(void) {
    static const char *alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    NSMutableString *s = [NSMutableString stringWithCapacity:22];
    NSUInteger i;
    for (i = 0; i < 22; i++) {
        [s appendFormat:@"%c", alphabet[arc4random_uniform(62)]];
    }
    return s;
}

static NSString *tosTimestamp(void) {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
    fmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    return [fmt stringFromDate:[NSDate date]];
}

+ (void)generateConfigWithCompletion:(void(^)(AWGConfig *, NSError *))completion {
    [self generateConfigWithPrivateKey:nil completion:completion];
}

+ (void)generateConfigWithPrivateKey:(NSString *)privateKeyBase64
                          completion:(void(^)(AWGConfig *, NSError *))completion {

    NSString *privateKey = privateKeyBase64;
    NSString *publicKey = nil;

    if (privateKey.length > 0) {
        NSData *priv = [AWGCrypto base64Decode:privateKey];
        if (priv.length != 32) privateKey = nil;
        else publicKey = [AWGCrypto base64Encode:[AWGCrypto publicKeyFromPrivateKey:priv]];
    }
    if (privateKey.length == 0) {
        NSData *priv = [AWGCrypto generatePrivateKey];
        privateKey = [AWGCrypto base64Encode:priv];
        publicKey = [AWGCrypto base64Encode:[AWGCrypto publicKeyFromPrivateKey:priv]];
    }

    NSString *urlString = [[NSUserDefaults standardUserDefaults] stringForKey:kWarpRelayDefaultsKey];
    if (urlString.length == 0) urlString = kWarpRegURL;

    NSDictionary *body = @{@"key": publicKey ?: @"",
                           @"install_id": randomInstallID(),
                           @"fcm_token": @"",
                           @"tos": tosTimestamp(),
                           @"model": @"iPhone",
                           @"serial_number": @"",
                           @"locale": @"en_US",
                           @"type": @"Android"};

    NSError *jsonError = nil;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (!payload) {
        [self finish:completion config:nil error:jsonError];
        return;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    NSString *reqHost = url.host ?: @"api.cloudflareclient.com";
    NSString *reqPath = url.path.length ? url.path : @"/v0a4471/reg";
    if (url.query.length) reqPath = [NSString stringWithFormat:@"%@?%@", reqPath, url.query];
    uint16_t reqPort = url.port ? [url.port unsignedShortValue] : ([url.scheme isEqualToString:@"http"] ? 80 : 443);

    NSDictionary *hdrs = @{@"Content-Type": @"application/json; charset=UTF-8",
                           @"CF-Client-Version": kWarpClientVer,
                           @"User-Agent": kWarpUserAgent,
                           @"Accept": @"application/json"};

    DLog(@"[AWG] registering WARP identity at %@", urlString);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *response = nil;
        NSError *lastError = nil;

        // Route plan, cheapest first. System DNS gets one honest try because on
        // an unfiltered network it is a single round trip; everything after it
        // assumes the network is hostile — forged A records, then DPI reading
        // the SNI out of the ClientHello. No single split defeats every box, so
        // we walk the strategies and keep whichever answers.
        // Measured on a ТСПУ-filtered network, 16 September 2026: every TCP-level
        // ClientHello split (mid-SNI, 1-byte, pre-SNI, many-tiny, slow) failed
        // with errSSLClosedAbort on both system DNS and pinned addresses. So we
        // no longer sweep them — two quick tries, then the caller falls back.
        NSArray *modes = @[@(AWGFragmentNone), @(AWGFragmentTiny)];
        NSMutableArray *plan = [NSMutableArray array];

        // Best route by far: register THROUGH a tunnel that is already up.
        // Inside WireGuard the filter sees neither the SNI nor the hostname, so
        // the request simply works — a live tunnel is used to earn a private
        // one.
        //
        // Wait for it rather than sampling the state: the tunnel and this call
        // are started from the same event, and losing that race by a fraction
        // of a second used to send the whole thing down the direct routes,
        // which are blocked. A few seconds here is cheap.
        AmneziaWGManager *mgr = [AmneziaWGManager sharedManager];
        if (!mgr.isConnected && mgr.savedConfigs.count > 0) {
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30.0];
            while (!mgr.isConnected && [deadline timeIntervalSinceNow] > 0) usleep(200000);
            DLog(@"[AWG] waited for the tunnel: %@", mgr.isConnected ? @"up" : @"never came up");
        }
        uint16_t socksPort = mgr.isConnected ? mgr.socksPort : 0;
        if (socksPort > 0) {
            [plan addObject:@{@"ip": @"", @"mode": @(AWGFragmentNone), @"socks": @(socksPort),
                              @"name": @"through the live tunnel"}];
        }

        NSMutableArray *targets = [NSMutableArray arrayWithObject:@""];   // "" = system DNS
        if ([reqHost isEqualToString:@"api.cloudflareclient.com"]) {
            NSUInteger pin;
            for (pin = 0; pin < kWarpAPIPinnedCount; pin++) [targets addObject:kWarpAPIPinnedIPs[pin]];
        }
        for (NSString *target in targets) {
            for (NSNumber *mode in modes) {
                [plan addObject:@{@"ip": target, @"mode": mode, @"socks": @0,
                                  @"name": [NSString stringWithFormat:@"%@ + %@",
                                            target.length ? target : @"system DNS",
                                            AWGFragmentModeName((AWGFragmentMode)[mode integerValue])]}];
            }
        }

        for (NSDictionary *route in plan) {
            NSError *attemptError = nil;
            NSInteger attemptStatus = 0;
            NSString *pinned = route[@"ip"];
            uint16_t routeSocks = (uint16_t)[route[@"socks"] unsignedShortValue];

            NSData *data = [AWGHTTPSTransport postToHost:reqHost
                                               connectIP:pinned.length ? pinned : nil
                                               socksPort:routeSocks
                                                    port:reqPort
                                                    path:reqPath
                                                    body:payload
                                                 headers:hdrs
                                            fragmentMode:(AWGFragmentMode)[route[@"mode"] integerValue]
                                              statusCode:&attemptStatus
                                                   error:&attemptError];
            if (data && attemptStatus >= 200 && attemptStatus < 300) {
                response = data;
                DLog(@"[AWG] registration path: %@ (HTTP %ld)", route[@"name"], (long)attemptStatus);
                break;
            }
            lastError = attemptError ?: [NSError errorWithDomain:kAWGWarpErrorDomain code:attemptStatus
                                                        userInfo:@{NSLocalizedDescriptionKey:
                                [NSString stringWithFormat:@"HTTP %ld", (long)attemptStatus]}];
            DLog(@"[AWG] route \"%@\" failed: %@", route[@"name"], lastError.localizedDescription);
        }

        AWGConfig *config = nil;
        NSError *finalError = lastError;
        if (response) {
            NSError *parseError = nil;
            config = [AWGWarpRegistrar configFromRegistrationData:response
                                                       privateKey:privateKey
                                                            error:&parseError];
            if (!config) {
                finalError = parseError;
                DLog(@"[AWG] WARP response unusable: %@", parseError.localizedDescription);
            }
        }
        [AWGWarpRegistrar finish:completion config:config error:config ? nil : finalError];
    });
}

+ (AWGConfig *)configFromRegistrationData:(NSData *)data
                               privateKey:(NSString *)privateKey
                                    error:(NSError **)error {
    NSError *jsonError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![root isKindOfClass:[NSDictionary class]]) {
        if (error) *error = jsonError ?: [NSError errorWithDomain:kAWGWarpErrorDomain code:-10
                                                         userInfo:@{NSLocalizedDescriptionKey: @"Malformed registration response"}];
        return nil;
    }

    NSDictionary *cfg = [root objectForKey:@"config"];
    if (![cfg isKindOfClass:[NSDictionary class]]) {
        if (error) *error = [NSError errorWithDomain:kAWGWarpErrorDomain code:-11
                                            userInfo:@{NSLocalizedDescriptionKey: @"Response carries no config"}];
        return nil;
    }

    NSArray *peers = [cfg objectForKey:@"peers"];
    NSDictionary *peer = ([peers isKindOfClass:[NSArray class]] && peers.count > 0) ? peers[0] : nil;
    NSString *peerPub = [peer isKindOfClass:[NSDictionary class]] ? peer[@"public_key"] : nil;
    if (![peerPub isKindOfClass:[NSString class]] || peerPub.length == 0) {
        if (error) *error = [NSError errorWithDomain:kAWGWarpErrorDomain code:-12
                                            userInfo:@{NSLocalizedDescriptionKey: @"Response carries no peer key"}];
        return nil;
    }

    AWGConfig *config = [AWGConfig configWithDefaults];
    config.label = @"Cloudflare WARP";
    config.privateKey = privateKey;
    config.publicKey = [AWGCrypto base64Encode:[AWGCrypto publicKeyFromPrivateKey:[AWGCrypto base64Decode:privateKey]]];
    config.peerPublicKey = peerPub;

    // The three reserved header bytes ride in every packet we send.
    NSString *clientID = [cfg objectForKey:@"client_id"];
    if ([clientID isKindOfClass:[NSString class]]) config.warpClientID = clientID;

    // Interface addresses Cloudflare assigned us.
    NSDictionary *iface = [cfg objectForKey:@"interface"];
    NSDictionary *addrs = [iface isKindOfClass:[NSDictionary class]] ? iface[@"addresses"] : nil;
    if ([addrs isKindOfClass:[NSDictionary class]]) {
        NSString *v4 = addrs[@"v4"];
        NSString *v6 = addrs[@"v6"];
        if ([v4 isKindOfClass:[NSString class]] && v4.length > 0) config.ipv4Address = [v4 stringByAppendingString:@"/32"];
        if ([v6 isKindOfClass:[NSString class]] && v6.length > 0) config.ipv6Address = [v6 stringByAppendingString:@"/128"];
    }

    // Cloudflare hands back engage.cloudflareclient.com:2408, the single most
    // fingerprinted endpoint there is. Keep the anycast IP it picked for us but
    // move off 2408, preferring the ports it says this peer answers on.
    NSDictionary *endpoint = [peer isKindOfClass:[NSDictionary class]] ? peer[@"endpoint"] : nil;
    NSString *v4 = [endpoint isKindOfClass:[NSDictionary class]] ? endpoint[@"v4"] : nil;
    NSString *host = nil;
    if ([v4 isKindOfClass:[NSString class]]) {
        NSRange colon = [v4 rangeOfString:@":" options:NSBackwardsSearch];
        host = colon.location != NSNotFound ? [v4 substringToIndex:colon.location] : v4;
    }

    NSArray *ports = [endpoint isKindOfClass:[NSDictionary class]] ? endpoint[@"ports"] : nil;
    if (host.length > 0 && [ports isKindOfClass:[NSArray class]] && ports.count > 0) {
        config.preferredPorts = ports;
        NSNumber *port = ports[arc4random_uniform((uint32_t)ports.count)];
        config.peerEndpoint = [NSString stringWithFormat:@"%@:%@", host, port];
    } else if (host.length > 0) {
        config.peerEndpoint = [NSString stringWithFormat:@"%@:%u", host,
                               (unsigned)kWarpPorts[arc4random_uniform((uint32_t)kWarpPortCount)]];
    } else {
        config.peerEndpoint = [self randomWarpEndpoint];
    }

    [self applyWarpObfuscationProfile:config];

    DLog(@"[AWG] WARP identity ready: %@ via %@ (client_id %@)",
         config.ipv4Address, config.peerEndpoint, config.warpClientID ?: @"none");
    return config;
}

+ (void)finish:(void(^)(AWGConfig *, NSError *))completion
        config:(AWGConfig *)config
         error:(NSError *)error {
    if (!completion) return;
    if ([NSThread isMainThread]) {
        completion(config, error);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(config, error); });
    }
}

@end
