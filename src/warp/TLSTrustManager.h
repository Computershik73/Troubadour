//
//  TLSTrustManager.h
//  YouTube
//
//  Native TLS trust evaluation for iOS 6 using modern root CAs bundled
//  inside the app (extracted from tlsroot.litten.ca). Combined with the
//  TLSFix tweak (modern OpenSSL handshake/ciphers), this lets the client
//  talk to YouTube / Google directly.
//

#import <Foundation/Foundation.h>

@interface TLSTrustManager : NSObject

+ (instancetype)sharedManager;

// YES if the bundled modern root store loaded successfully.
@property (nonatomic, readonly) BOOL hasModernRoots;
@property (nonatomic, readonly) NSUInteger rootCount;

// Evaluate a SecTrustRef against bundled modern root certificates
- (BOOL)evaluateServerTrust:(SecTrustRef)serverTrust forHost:(NSString *)host;

// Handle an NSURLConnection server-trust challenge. Returns YES if it fully
// handled the challenge (accepted or rejected); NO to let the default logic run.
- (BOOL)handleAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
                        forConnection:(NSURLConnection *)connection;

@end
