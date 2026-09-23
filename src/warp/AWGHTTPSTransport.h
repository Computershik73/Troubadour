//
//  AWGHTTPSTransport.h
//  YouTube
//
//  Blocking HTTPS over SecureTransport with a fragmented ClientHello.
//
//  NSURLConnection cannot reach api.cloudflareclient.com from Russia: the TCP
//  connection opens, then ТСПУ reads the SNI out of the ClientHello and drops
//  the flow, so the request just times out with no callbacks at all. Splitting
//  the ClientHello so the hostname straddles two TCP segments defeats that,
//  and doing our own TLS also lets us validate against the bundled modern roots.
//

#import <Foundation/Foundation.h>

extern NSString * const kAWGTransportErrorDomain;

// ClientHello splitting strategies. A single TCP split is often reassembled by
// the DPI box, so there is no one answer — the caller walks the list and keeps
// whichever gets an answer.
typedef NS_ENUM(NSInteger, AWGFragmentMode) {
    AWGFragmentNone = 0,
    AWGFragmentMidSNI,        // one split through the middle of the hostname
    AWGFragmentFirstByte,     // 1 byte, then the rest
    AWGFragmentBeforeSNI,     // split just ahead of the hostname
    AWGFragmentTiny,          // many small segments across the whole record
    AWGFragmentMidSNISlow     // mid-hostname split with a long pause
};

NSString *AWGFragmentModeName(AWGFragmentMode mode);

@interface AWGHTTPSTransport : NSObject

// Blocking. Call from a background thread. Returns the response body, or nil
// with *error set. *outStatus receives the HTTP status code when there was one.
//
// connectIP, when set, is dialled instead of resolving `host` — but `host` is
// still what goes into the SNI and the Host header. Because we drive TLS
// ourselves the two are independent, which is what lets us skip system DNS
// entirely when it is being poisoned.
// socksPort, when non-zero, routes the whole request through a local SOCKS5
// proxy (the one AWGTunnel exposes). The hostname is handed to the proxy, so
// it is resolved inside the tunnel and the TLS handshake never crosses the
// filtered path at all — which is how a live tunnel can be used to register
// the next one.
+ (NSData *)postToHost:(NSString *)host
             connectIP:(NSString *)connectIP
             socksPort:(uint16_t)socksPort
                  port:(uint16_t)port
                  path:(NSString *)path
                  body:(NSData *)body
               headers:(NSDictionary *)headers
          fragmentMode:(AWGFragmentMode)fragmentMode
            statusCode:(NSInteger *)outStatus
                 error:(NSError **)error;

@end
