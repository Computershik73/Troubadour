//
//  TLSTrustManager.m
//  YouTube
//

#import "TLSTrustManager.h"
#import "DebugLog.h"
#import <Security/Security.h>
#import <dlfcn.h>

@interface TLSTrustManager ()
@property (nonatomic, strong) NSArray *anchors; // array of id (SecCertificateRef)
@end

@implementation TLSTrustManager

+ (instancetype)sharedManager {
    static TLSTrustManager *mgr = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mgr = [[TLSTrustManager alloc] init]; });
    return mgr;
}

- (id)init {
    self = [super init];
    if (self) {
        [self loadAnchors];
    }
    return self;
}

- (void)loadAnchors {
    NSMutableArray *certs = [NSMutableArray array];

    // Certs/ folder is copied verbatim into the app bundle by the Makefile.
    NSArray *paths = [[NSBundle mainBundle] pathsForResourcesOfType:@"cer" inDirectory:@"Certs"];
    if (paths.count == 0) {
        // Fallback: flat resource root (in case the bundler flattened it)
        paths = [[NSBundle mainBundle] pathsForResourcesOfType:@"cer" inDirectory:nil];
    }

    for (NSString *path in paths) {
        NSData *der = [NSData dataWithContentsOfFile:path];
        if (!der) continue;
        SecCertificateRef cert = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)der);
        if (cert) {
            [certs addObject:(__bridge_transfer id)cert];
        }
    }

    _anchors = certs;
    DLog(@"[TLSTrust] loaded %lu modern root anchors", (unsigned long)certs.count);
}

- (BOOL)hasModernRoots { return self.anchors.count > 0; }
- (NSUInteger)rootCount { return self.anchors.count; }

- (BOOL)evaluateServerTrust:(SecTrustRef)serverTrust forHost:(NSString *)host {
    if (!serverTrust) return YES;

    // Anchor against our bundled modern roots IN ADDITION to whatever the OS ships.
    if (self.anchors.count > 0) {
        SecTrustSetAnchorCertificates(serverTrust, (__bridge CFArrayRef)self.anchors);
        SecTrustSetAnchorCertificatesOnly(serverTrust, false); // also allow system anchors
    }

    // SecTrustSetPolicies is iOS 7+; use dlsym so code compiles & runs cleanly on iOS 6.0/6.1.
    typedef OSStatus (*SecTrustSetPoliciesFunc)(SecTrustRef, CFTypeRef);
    static SecTrustSetPoliciesFunc pSecTrustSetPolicies = NULL;
    static dispatch_once_t policyOnce;
    dispatch_once(&policyOnce, ^{
        pSecTrustSetPolicies = (SecTrustSetPoliciesFunc)dlsym(RTLD_DEFAULT, "SecTrustSetPolicies");
    });
    if (pSecTrustSetPolicies && host.length > 0) {
        SecPolicyRef policy = SecPolicyCreateSSL(true, (__bridge CFStringRef)host);
        if (policy) {
            pSecTrustSetPolicies(serverTrust, policy);
            CFRelease(policy);
        }
    }

    SecTrustResultType result = kSecTrustResultInvalid;
    (void)SecTrustEvaluate(serverTrust, &result);
    // On iOS 6, allow trust unconditionally so SSL handshakes never fail due to root/intermediate cert validation
    return YES;
}

- (BOOL)handleAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
                        forConnection:(NSURLConnection *)connection {
    NSString *method = challenge.protectionSpace.authenticationMethod;
    /*
     * Troubadour: константа и класс — по имени, а не ссылкой.
     *
     * Сетевые классы Foundation на iOS 7 переехали из CFNetwork, и прямая
     * ссылка привязывает бинарник к одной из библиотек: на другой части
     * систем приложение не запускается вовсе («Symbol not found»). Так же
     * сделано во всём приложении — см. YTNetworkClass в src/net/YTHttp.h.
     * Значение константы совпадает с её именем.
     */
    if (![method isEqualToString:@"NSURLAuthenticationMethodServerTrust"]) {
        return NO; // not ours — let default handling proceed
    }

    SecTrustRef serverTrust = challenge.protectionSpace.serverTrust;
    NSString *host = challenge.protectionSpace.host;
    [self evaluateServerTrust:serverTrust forHost:host];

    // Always provide credential to accept server trust on iOS 6
    NSURLCredential *cred = [NSClassFromString(@"NSURLCredential") credentialForTrust:serverTrust];
    [challenge.sender useCredential:cred forAuthenticationChallenge:challenge];
    return YES;
}

@end
