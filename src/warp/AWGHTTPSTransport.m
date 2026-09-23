//
//  AWGHTTPSTransport.m
//  YouTube
//

#import "AWGHTTPSTransport.h"
#import "TLSTrustManager.h"
#import "DebugLog.h"

#import <Security/Security.h>
#import <Security/SecureTransport.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

NSString * const kAWGTransportErrorDomain = @"AWGHTTPSTransport";

// Gap between ClientHello fragments. Long enough that the kernel does not
// coalesce them into one segment, short enough not to trip the server's timer.
static const useconds_t kFragmentGapUsec = 40000;

typedef struct {
    int fd;
    const char *sniHost;
    size_t sniLen;
    int mode;                 // AWGFragmentMode, reset to none after the hello
} AWGTransportIO;

NSString *AWGFragmentModeName(AWGFragmentMode mode) {
    switch (mode) {
        case AWGFragmentNone:       return @"no split";
        case AWGFragmentMidSNI:     return @"split mid-SNI";
        case AWGFragmentFirstByte:  return @"split after 1 byte";
        case AWGFragmentBeforeSNI:  return @"split before SNI";
        case AWGFragmentTiny:       return @"many tiny segments";
        case AWGFragmentMidSNISlow: return @"split mid-SNI, slow";
    }
    return @"?";
}

#pragma mark - SecureTransport IO

static OSStatus awgSSLRead(SSLConnectionRef connection, void *data, size_t *dataLength) {
    AWGTransportIO *io = (AWGTransportIO *)connection;
    size_t want = *dataLength;
    size_t got = 0;
    uint8_t *p = (uint8_t *)data;

    while (got < want) {
        ssize_t n = recv(io->fd, p + got, want - got, 0);
        if (n > 0) { got += (size_t)n; continue; }
        *dataLength = got;
        if (n == 0) return errSSLClosedGraceful;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return errSSLWouldBlock;
        if (errno == EINTR) continue;
        return errSSLClosedAbort;
    }
    *dataLength = got;
    return noErr;
}

static BOOL awgSendAll(int fd, const uint8_t *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, buf + sent, len - sent, 0);
        if (n > 0) { sent += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        return NO;
    }
    return YES;
}

// Where the SNI hostname sits inside the ClientHello, or NSNotFound.
static size_t awgFindSNI(const uint8_t *data, size_t len, const char *host, size_t hostLen) {
    if (!host || hostLen < 4 || len < hostLen) return (size_t)-1;
    size_t i;
    for (i = 0; i + hostLen <= len; i++) {
        if (memcmp(data + i, host, hostLen) == 0) return i;
    }
    return (size_t)-1;
}

static OSStatus awgSSLWrite(SSLConnectionRef connection, const void *data, size_t *dataLength) {
    AWGTransportIO *io = (AWGTransportIO *)connection;
    const uint8_t *buf = (const uint8_t *)data;
    size_t len = *dataLength;

    if (io->mode != AWGFragmentNone && len > 16) {
        int mode = io->mode;
        io->mode = AWGFragmentNone;          // only the ClientHello is split

        size_t sniAt = awgFindSNI(buf, len, io->sniHost, io->sniLen);
        useconds_t gap = kFragmentGapUsec;
        size_t cuts[24];
        int cutCount = 0;

        switch (mode) {
            case AWGFragmentMidSNI:
                cuts[cutCount++] = (sniAt != (size_t)-1) ? sniAt + io->sniLen / 2 : len / 2;
                break;
            case AWGFragmentFirstByte:
                cuts[cutCount++] = 1;
                break;
            case AWGFragmentBeforeSNI:
                cuts[cutCount++] = (sniAt != (size_t)-1 && sniAt > 0) ? sniAt : len / 3;
                break;
            case AWGFragmentMidSNISlow:
                cuts[cutCount++] = (sniAt != (size_t)-1) ? sniAt + io->sniLen / 2 : len / 2;
                gap = 250000;
                break;
            case AWGFragmentTiny: {
                // Walk the whole record in small steps so no segment can carry
                // a recognisable hostname, however the box reassembles.
                size_t step = 6, at = step;
                while (at < len && cutCount < 23) { cuts[cutCount++] = at; at += step; }
                gap = 12000;
                break;
            }
            default:
                break;
        }

        DLog(@"[AWG/TLS] %@: hello %lu bytes in %d segments",
             AWGFragmentModeName((AWGFragmentMode)mode), (unsigned long)len, cutCount + 1);

        size_t sent = 0;
        int i;
        for (i = 0; i < cutCount; i++) {
            size_t cut = cuts[i];
            if (cut <= sent || cut >= len) continue;
            if (!awgSendAll(io->fd, buf + sent, cut - sent)) { *dataLength = 0; return errSSLClosedAbort; }
            usleep(gap);
            sent = cut;
        }
        if (sent < len && !awgSendAll(io->fd, buf + sent, len - sent)) { *dataLength = 0; return errSSLClosedAbort; }
        *dataLength = len;
        return noErr;
    }

    if (!awgSendAll(io->fd, buf, len)) { *dataLength = 0; return errSSLClosedAbort; }
    *dataLength = len;
    return noErr;
}


#pragma mark - Through the tunnel

static NSError *awgError(NSInteger code, NSString *msg) {
    return [NSError errorWithDomain:kAWGTransportErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}


static int awgSocksConnect(uint16_t socksPort, NSString *host, uint16_t port, NSError **error) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { if (error) *error = awgError(-20, @"socket() failed"); return -1; }

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
    struct timeval tv = { .tv_sec = 20, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(socksPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        if (error) *error = awgError(-21, @"Cannot reach the local SOCKS5 proxy");
        return -1;
    }

    // Greeting: version 5, one method, no authentication.
    uint8_t greet[3] = {0x05, 0x01, 0x00};
    uint8_t reply[2] = {0, 0};
    if (!awgSendAll(fd, greet, 3) || recv(fd, reply, 2, MSG_WAITALL) != 2 ||
        reply[0] != 0x05 || reply[1] != 0x00) {
        close(fd);
        if (error) *error = awgError(-22, @"SOCKS5 greeting refused");
        return -1;
    }

    // CONNECT by domain name: the proxy resolves it inside the tunnel.
    const char *hostUTF8 = [host UTF8String];
    size_t hostLen = strlen(hostUTF8);
    if (hostLen > 255) { close(fd); if (error) *error = awgError(-23, @"Host too long"); return -1; }

    NSMutableData *req = [NSMutableData data];
    uint8_t head[4] = {0x05, 0x01, 0x00, 0x03};
    uint8_t lenByte = (uint8_t)hostLen;
    uint16_t portBE = htons(port);
    [req appendBytes:head length:4];
    [req appendBytes:&lenByte length:1];
    [req appendBytes:hostUTF8 length:hostLen];
    [req appendBytes:&portBE length:2];

    uint8_t connectReply[10] = {0};
    if (!awgSendAll(fd, req.bytes, req.length) ||
        recv(fd, connectReply, sizeof(connectReply), MSG_WAITALL) != (ssize_t)sizeof(connectReply) ||
        connectReply[0] != 0x05 || connectReply[1] != 0x00) {
        close(fd);
        if (error) *error = awgError(-24, [NSString stringWithFormat:@"SOCKS5 CONNECT refused (code %u)",
                                           (unsigned)connectReply[1]]);
        return -1;
    }

    DLog(@"[AWG/TLS] tunnelled to %@:%u through the local SOCKS5 proxy", host, (unsigned)port);
    return fd;
}

#pragma mark - Transport

@implementation AWGHTTPSTransport

+ (NSData *)postViaSOCKS:(uint16_t)socksPort
                    host:(NSString *)host
                    port:(uint16_t)port
                    path:(NSString *)path
                    body:(NSData *)body
                 headers:(NSDictionary *)headers
              statusCode:(NSInteger *)outStatus
                   error:(NSError **)error {

    int fd = awgSocksConnect(socksPort, host, port, error);
    if (fd < 0) return nil;
    // No ClientHello splitting here: inside the tunnel nothing is watching.
    return [self runTLSOnSocket:fd host:host path:path body:body headers:headers
                   fragmentMode:AWGFragmentNone statusCode:outStatus error:error];
}


+ (NSData *)postToHost:(NSString *)host
             connectIP:(NSString *)connectIP
             socksPort:(uint16_t)socksPort
                  port:(uint16_t)port
                  path:(NSString *)path
                  body:(NSData *)body
               headers:(NSDictionary *)headers
          fragmentMode:(AWGFragmentMode)fragmentMode
            statusCode:(NSInteger *)outStatus
                 error:(NSError **)error {

    if (outStatus) *outStatus = 0;
    if (host.length == 0) {
        if (error) *error = awgError(-1, @"No host");
        return nil;
    }

    // Through the tunnel: dial the local SOCKS5 listener and let it do the
    // resolving and the connecting on the far side.
    if (socksPort > 0) {
        return [self postViaSOCKS:socksPort host:host port:port path:path
                             body:body headers:headers statusCode:outStatus error:error];
    }

    // IPv4 only: the device has no working IPv6 and a stalled AAAA attempt
    // would eat the whole timeout budget.
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    char portStr[8];
    snprintf(portStr, sizeof(portStr), "%u", (unsigned)port);

    // With a pinned IP we skip the resolver altogether; AI_NUMERICHOST keeps
    // getaddrinfo from quietly falling back to a lookup.
    NSString *dialTarget = connectIP.length ? connectIP : host;
    if (connectIP.length) hints.ai_flags = AI_NUMERICHOST;

    int rc = getaddrinfo([dialTarget UTF8String], portStr, &hints, &res);
    if (rc != 0 || !res) {
        if (error) *error = awgError(-2, [NSString stringWithFormat:@"Cannot resolve %@: %s", dialTarget, gai_strerror(rc)]);
        return nil;
    }

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) {
        freeaddrinfo(res);
        if (error) *error = awgError(-3, @"socket() failed");
        return nil;
    }

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));   // fragments must not coalesce
    struct timeval tv = { .tv_sec = 8, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    char ipbuf[INET_ADDRSTRLEN] = {0};
    struct sockaddr_in *sin = (struct sockaddr_in *)res->ai_addr;
    inet_ntop(AF_INET, &sin->sin_addr, ipbuf, sizeof(ipbuf));

    if (connect(fd, res->ai_addr, res->ai_addrlen) < 0) {
        freeaddrinfo(res);
        close(fd);
        if (error) *error = awgError(-4, [NSString stringWithFormat:@"connect(%s:%u) failed: %s", ipbuf, (unsigned)port, strerror(errno)]);
        return nil;
    }
    freeaddrinfo(res);
    DLog(@"[AWG/TLS] connected to %@ (%s:%u), %@",
         host, ipbuf, (unsigned)port, AWGFragmentModeName(fragmentMode));

    return [self runTLSOnSocket:fd host:host path:path body:body headers:headers
                   fragmentMode:fragmentMode statusCode:outStatus error:error];
}

+ (NSData *)runTLSOnSocket:(int)fd
                      host:(NSString *)host
                      path:(NSString *)path
                      body:(NSData *)body
                   headers:(NSDictionary *)headers
              fragmentMode:(AWGFragmentMode)fragmentMode
                statusCode:(NSInteger *)outStatus
                     error:(NSError **)error {

    const char *hostUTF8 = [host UTF8String];
    AWGTransportIO io;
    io.fd = fd;
    io.sniHost = hostUTF8;
    io.sniLen = strlen(hostUTF8);
    io.mode = (int)fragmentMode;

    SSLContextRef ctx = SSLCreateContext(kCFAllocatorDefault, kSSLClientSide, kSSLStreamType);
    if (!ctx) {
        close(fd);
        if (error) *error = awgError(-5, @"SSLCreateContext failed");
        return nil;
    }

    SSLSetIOFuncs(ctx, awgSSLRead, awgSSLWrite);
    SSLSetConnection(ctx, (SSLConnectionRef)&io);
    SSLSetPeerDomainName(ctx, hostUTF8, strlen(hostUTF8));
    SSLSetProtocolVersionMin(ctx, kTLSProtocol1);
    SSLSetProtocolVersionMax(ctx, kTLSProtocol12);
    SSLSetSessionOption(ctx, kSSLSessionOptionBreakOnServerAuth, true);

    OSStatus status;
    int guard = 0;
    do {
        status = SSLHandshake(ctx);
        if (status == errSSLServerAuthCompleted) {
            SecTrustRef peerTrust = NULL;
            if (SSLCopyPeerTrust(ctx, &peerTrust) == noErr && peerTrust) {
                BOOL ok = [[TLSTrustManager sharedManager] evaluateServerTrust:peerTrust forHost:host];
                CFRelease(peerTrust);
                if (!ok) {
                    DLog(@"[AWG/TLS] peer trust rejected for %@", host);
                    status = errSSLXCertChainInvalid;
                    break;
                }
                DLog(@"[AWG/TLS] peer trust ok for %@", host);
            }
            continue;
        }
        if (status == errSSLWouldBlock) usleep(5000);
    } while ((status == errSSLWouldBlock || status == errSSLServerAuthCompleted) && ++guard < 1200);

    if (status != noErr) {
        DLog(@"[AWG/TLS] handshake failed: %d", (int)status);
        SSLClose(ctx);
        CFRelease(ctx);
        close(fd);
        if (error) *error = awgError(status, [NSString stringWithFormat:@"TLS handshake failed (%d)", (int)status]);
        return nil;
    }

    // Request
    NSMutableString *req = [NSMutableString stringWithFormat:
                            @"POST %@ HTTP/1.1\r\nHost: %@\r\nConnection: close\r\nContent-Length: %lu\r\n",
                            path.length ? path : @"/", host, (unsigned long)body.length];
    for (NSString *key in headers) {
        [req appendFormat:@"%@: %@\r\n", key, headers[key]];
    }
    [req appendString:@"\r\n"];

    NSMutableData *out = [NSMutableData dataWithData:[req dataUsingEncoding:NSUTF8StringEncoding]];
    if (body.length) [out appendData:body];

    size_t written = 0;
    status = SSLWrite(ctx, out.bytes, out.length, &written);
    if (status != noErr) {
        SSLClose(ctx); CFRelease(ctx); close(fd);
        if (error) *error = awgError(status, [NSString stringWithFormat:@"SSLWrite failed (%d)", (int)status]);
        return nil;
    }

    // Response: read to close.
    NSMutableData *raw = [NSMutableData data];
    uint8_t buf[4096];
    // A deadline is not optional here: on a read timeout awgSSLRead hands back
    // errSSLWouldBlock with nothing read, and without this the loop spins for
    // ever — which is exactly how a successful handshake still produced no
    // answer and no error.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:45.0];
    for (;;) {
        size_t got = 0;
        status = SSLRead(ctx, buf, sizeof(buf), &got);
        if (got > 0) [raw appendBytes:buf length:got];
        if (status == errSSLClosedGraceful || status == errSSLClosedNoNotify) break;
        if (status == errSSLWouldBlock) {
            if ([deadline timeIntervalSinceNow] <= 0) {
                DLog(@"[AWG/TLS] response read timed out after %lu bytes", (unsigned long)raw.length);
                break;
            }
            if (got == 0) usleep(20000);
            continue;
        }
        if (status != noErr) break;
        if (raw.length > 4 * 1024 * 1024) break;
        if ([deadline timeIntervalSinceNow] <= 0) break;
    }

    SSLClose(ctx);
    CFRelease(ctx);
    close(fd);

    if (raw.length == 0) {
        if (error) *error = awgError(-6, @"Empty response");
        return nil;
    }

    // Split headers from body.
    const char *sep = "\r\n\r\n";
    NSRange headEnd = [raw rangeOfData:[NSData dataWithBytes:sep length:4]
                               options:0 range:NSMakeRange(0, raw.length)];
    if (headEnd.location == NSNotFound) {
        if (error) *error = awgError(-7, @"Malformed HTTP response");
        return nil;
    }

    NSString *head = [[NSString alloc] initWithData:[raw subdataWithRange:NSMakeRange(0, headEnd.location)]
                                           encoding:NSUTF8StringEncoding];
    NSInteger code = 0;
    NSArray *headLines = [head componentsSeparatedByString:@"\r\n"];
    if (headLines.count > 0) {
        NSArray *statusParts = [headLines[0] componentsSeparatedByString:@" "];
        if (statusParts.count > 1) code = [statusParts[1] integerValue];
    }
    if (outStatus) *outStatus = code;

    NSData *payload = [raw subdataWithRange:NSMakeRange(headEnd.location + 4,
                                                        raw.length - headEnd.location - 4)];

    // Cloudflare answers chunked when Connection: close is used.
    if ([head rangeOfString:@"chunked" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        payload = [self dechunk:payload];
    }

    DLog(@"[AWG/TLS] HTTP %ld, %lu bytes of body (raw %lu)",
         (long)code, (unsigned long)payload.length, (unsigned long)raw.length);
    for (NSString *line in headLines) {
        NSString *l = [line lowercaseString];
        if ([l hasPrefix:@"content-length"] || [l hasPrefix:@"transfer-encoding"] ||
            [l hasPrefix:@"connection"] || [l hasPrefix:@"content-encoding"]) {
            DLog(@"[AWG/TLS]   %@", line);
        }
    }
    return payload;
}

+ (NSData *)dechunk:(NSData *)data {
    NSMutableData *out = [NSMutableData data];
    const uint8_t *p = data.bytes;
    NSUInteger len = data.length, i = 0;

    while (i < len) {
        NSUInteger lineEnd = i;
        while (lineEnd + 1 < len && !(p[lineEnd] == '\r' && p[lineEnd + 1] == '\n')) lineEnd++;
        if (lineEnd + 1 >= len) break;

        char sizeBuf[32] = {0};
        NSUInteger sizeLen = lineEnd - i;
        if (sizeLen == 0 || sizeLen >= sizeof(sizeBuf)) break;
        memcpy(sizeBuf, p + i, sizeLen);
        unsigned long chunkSize = strtoul(sizeBuf, NULL, 16);
        if (chunkSize == 0) break;

        NSUInteger start = lineEnd + 2;
        if (start + chunkSize > len) break;
        [out appendBytes:p + start length:chunkSize];
        i = start + chunkSize + 2;   // skip the trailing CRLF
    }
    return out;
}

@end
