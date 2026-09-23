//
//  AWGConfig.h
//  YouTube
//
//  AmneziaWG tunnel configuration: keys, endpoint, obfuscation parameters.
//  WireGuard config format with AmneziaWG extensions (Jc/Jmin/Jmax/S1-S4/H1-H4/I1-I5).
//

#import <Foundation/Foundation.h>

@interface AWGConfig : NSObject <NSCoding>

// WireGuard identity
@property (nonatomic, copy) NSString *privateKey;   // base64, 32 bytes
@property (nonatomic, copy) NSString *publicKey;    // base64, 32 bytes (derived)
@property (nonatomic, copy) NSString *presharedKey; // base64, optional

// Interface addressing
@property (nonatomic, copy) NSString *ipv4Address;            // e.g. "10.2.0.2/32"
@property (nonatomic, copy) NSString *ipv6Address;  // e.g. "2a07:b944::2:2/128"
@property (nonatomic, copy) NSString *dnsServers;             // comma-separated
@property (nonatomic, assign) NSUInteger mtu;

// Peer
@property (nonatomic, copy) NSString *peerPublicKey;          // base64
@property (nonatomic, copy) NSString *peerEndpoint;           // "host:port" or "[v6]:port"
@property (nonatomic, copy) NSString *allowedIPs;             // comma-separated CIDRs

// AmneziaWG obfuscation (must match server side exactly)
@property (nonatomic, assign) NSUInteger junkCount;           // Jc: 0-12
@property (nonatomic, assign) NSUInteger junkMin;             // Jmin
@property (nonatomic, assign) NSUInteger junkMax;             // Jmax
@property (nonatomic, assign) NSUInteger s1;                  // S1 padding
@property (nonatomic, assign) NSUInteger s2;                  // S2 padding
@property (nonatomic, assign) NSUInteger s3;                  // S3 padding
@property (nonatomic, assign) NSUInteger s4;                  // S4 padding
@property (nonatomic, assign) NSUInteger h1;                  // H1 header value (random 4 bytes)
@property (nonatomic, assign) NSUInteger h2;                  // H2 header value
@property (nonatomic, assign) NSUInteger h3;                  // H3 header value
@property (nonatomic, assign) NSUInteger h4;                  // H4 header value
@property (nonatomic, copy) NSString *i1;           // I1 init bytes (hex or base64)
@property (nonatomic, copy) NSString *i2;           // I2 init bytes
@property (nonatomic, copy) NSString *i3;           // I3 init bytes
@property (nonatomic, copy) NSString *i4;           // I4 init bytes
@property (nonatomic, copy) NSString *i5;           // I5 init bytes

// Cloudflare WARP: client_id, base64 of the 3 "reserved" header bytes.
// Empty for ordinary AmneziaWG servers.
@property (nonatomic, copy) NSString *warpClientID;

// Metadata
@property (nonatomic, copy) NSString *label;                  // display name
@property (nonatomic, copy) NSString *preferredSNI; // traffic-masking SNI
@property (nonatomic, copy) NSArray *preferredPorts;

// YES when warpClientID decodes to exactly 3 bytes.
- (BOOL)hasReservedBytes;
- (void)copyReservedBytes:(uint8_t *)out;   // writes 3 bytes, zeros when unset

- (NSString *)wireguardConfigString;
- (NSString *)obfuscatedConfigString;   // full config including AWG params

+ (instancetype)configWithDefaults;
+ (instancetype)configFromWireguardString:(NSString *)string;

@end
