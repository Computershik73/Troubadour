//
//  AWGCrypto.h
//  YouTube
//
//  Thin wrappers around Monocypher for WireGuard/AmneziaWG primitives.
//

#import <Foundation/Foundation.h>

@interface AWGCrypto : NSObject

// Curve25519 key pair generation. Returns 32-byte raw private key.
+ (NSData *)generatePrivateKey;
+ (NSData *)publicKeyFromPrivateKey:(NSData *)privateKey;

// Base64 helpers used by WireGuard config format.
+ (NSString *)base64Encode:(NSData *)data;
+ (NSData *)base64Decode:(NSString *)string;

@end
