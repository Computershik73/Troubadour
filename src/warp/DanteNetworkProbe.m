//
//  DanteNetworkProbe.m
//  Dante
//

#import "DanteNetworkProbe.h"
#import "DebugLog.h"
// Troubadour: вместо #import "DanteUtun.h" — список интерфейсов для
// networkKey (см. ниже); сам DanteUtun из части для системной службы.
#include <ifaddrs.h>
#include <net/if.h>
#include <arpa/inet.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <sys/select.h>

// TCP-connect с таймаутом. Возвращает fd >= 0 или -1.
static int DanteTCPConnect(const char *ip, uint16_t port, NSTimeInterval timeout) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_pton(AF_INET, ip, &addr.sin_addr);

    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (rc < 0 && errno != EINPROGRESS) {
        close(fd);
        return -1;
    }
    if (rc != 0) {
        fd_set wfds;
        FD_ZERO(&wfds);
        FD_SET(fd, &wfds);
        struct timeval tv;
        tv.tv_sec = (time_t)timeout;
        tv.tv_usec = (suseconds_t)((timeout - (time_t)timeout) * 1000000.0);
        rc = select(fd + 1, NULL, &wfds, NULL, &tv);
        if (rc <= 0) {
            close(fd);
            return -1;
        }
        int err = 0;
        socklen_t len = sizeof(err);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) < 0 || err != 0) {
            close(fd);
            return -1;
        }
    }

    // Обратно в блокирующий режим с таймаутами на чтение/запись.
    fcntl(fd, F_SETFL, flags);
    struct timeval tv;
    tv.tv_sec = (time_t)timeout;
    tv.tv_usec = (suseconds_t)((timeout - (time_t)timeout) * 1000000.0);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    return fd;
}

static BOOL DanteSendAll(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    while (len > 0) {
        ssize_t n = send(fd, p, len, 0);
        if (n <= 0) return NO;
        p += n;
        len -= (size_t)n;
    }
    return YES;
}

@implementation DanteNetworkProbe

+ (BOOL)detectWhitelistMode {
    //  три опорных хоста,
    // 350 мс на каждый. Все мимо — значит, сеть в режиме белых списков.
    const char *hosts[] = { "1.1.1.1", "1.0.0.1", "8.8.8.8" };
    for (size_t i = 0; i < sizeof(hosts) / sizeof(hosts[0]); i++) {
        int fd = DanteTCPConnect(hosts[i], 443, 0.35);
        if (fd >= 0) {
            close(fd);
            return NO;
        }
    }
    return YES;
}

+ (BOOL)verifyTunnelOnSOCKSPort:(uint16_t)port timeout:(NSTimeInterval)timeout {
    return [self traceOnSOCKSPort:port timeout:timeout] != nil;
}

+ (NSString *)traceOnSOCKSPort:(uint16_t)port timeout:(NSTimeInterval)timeout {
    int fd = DanteTCPConnect("127.0.0.1", port, timeout);
    if (fd < 0) return nil;

    BOOL ok = NO;
    NSString *text = nil;
    @try {
        // SOCKS5 greeting: версия 5, один метод — «без авторизации».
        uint8_t greet[] = { 0x05, 0x01, 0x00 };
        if (!DanteSendAll(fd, greet, sizeof(greet))) @throw @(1);
        uint8_t gresp[2];
        if (recv(fd, gresp, sizeof(gresp), 0) != 2 || gresp[0] != 0x05 || gresp[1] != 0x00)
            @throw @(2);

        // CONNECT www.cloudflare.com:80 (домен — заодно проверяется DNS
        // через туннель). 1.1.1.1/cdn-cgi/trace больше не отдаёт 200 по
        // plain HTTP (301 на https), а www.cloudflare.com отдаёт trace с 200.
        // Длина — через strlen, как в AWGHTTPSTransport из YouTube: с
        // зашитым числом в имя попадал завершающий NUL → NXDOMAIN.
        const char *host = "www.cloudflare.com";
        size_t hostLen = strlen(host);
        uint8_t conn[5 + 255 + 2];
        conn[0] = 0x05; conn[1] = 0x01; conn[2] = 0x00; conn[3] = 0x03;
        conn[4] = (uint8_t)hostLen;
        memcpy(conn + 5, host, hostLen);
        conn[5 + hostLen] = 0x00; conn[6 + hostLen] = 0x50;   // порт 80
        if (!DanteSendAll(fd, conn, 7 + hostLen)) @throw @(3);
        uint8_t cresp[10];
        ssize_t n = recv(fd, cresp, sizeof(cresp), MSG_WAITALL);
        if (n < 10 || cresp[0] != 0x05 || cresp[1] != 0x00) @throw @(4);

        //  GET /cdn-cgi/trace через прокси ядра.
        const char *req = "GET /cdn-cgi/trace HTTP/1.1\r\n"
                          "Host: www.cloudflare.com\r\n"
                          "User-Agent: Dante/1.0\r\n"
                          "Connection: close\r\n\r\n";
        if (!DanteSendAll(fd, req, strlen(req))) @throw @(5);

        NSMutableData *resp = [NSMutableData dataWithCapacity:2048];
        uint8_t buf[2048];
        while ([resp length] < 16384) {
            n = recv(fd, buf, sizeof(buf), 0);
            if (n <= 0) break;
            [resp appendBytes:buf length:(NSUInteger)n];
        }
        text = [[NSString alloc] initWithData:resp encoding:NSUTF8StringEncoding];
        DLog(@"[Probe] получено %lu байт: %@", (unsigned long)resp.length,
             text.length > 0 ? [text substringToIndex:MIN((NSUInteger)200, text.length)] : @"(бинарь/пусто)");
        if (text.length > 0 &&
            [text rangeOfString:@"200"].location != NSNotFound &&
            [text rangeOfString:@"warp=" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            ok = YES;
        }
    }
    @catch (id ignored) {
        ok = NO;
    }
    close(fd);
    return ok ? text : nil;
}

+ (NSString *)randomSNIFromResource:(NSString *)name {
    NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:@"sni"];
    if (!path) return nil;
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:
                            [NSCharacterSet newlineCharacterSet]]) {
        NSString *s = [line stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]];
        if (s.length > 0 && ![s hasPrefix:@"#"]) [names addObject:s];
    }
    if (names.count == 0) return nil;
    return [names objectAtIndex:arc4random_uniform((uint32_t)names.count)];
}

#pragma mark - Отпечаток сети

// Отвечает ли хоть один из адресов. Все пробы идут разом, и как только
// откликнулся первый, остальные бросаем: ждать их незачем.
static BOOL DanteAnyReachable(const char *const *hosts, uint16_t port, NSTimeInterval timeout) {
    int fds[8];
    int count = 0;
    for (int i = 0; hosts[i] && count < 8; i++) {
        struct sockaddr_in sa;
        memset(&sa, 0, sizeof(sa));
        sa.sin_family = AF_INET;
        sa.sin_port = htons(port);
        if (inet_pton(AF_INET, hosts[i], &sa.sin_addr) != 1) continue;
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) continue;
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
        if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) == 0) {
            close(fd);
            for (int j = 0; j < count; j++) close(fds[j]);
            return YES;
        }
        if (errno != EINPROGRESS) { close(fd); continue; }
        fds[count++] = fd;
    }
    if (!count) return NO;

    struct timeval tv = { (time_t)timeout,
                          (suseconds_t)((timeout - (long)timeout) * 1e6) };
    fd_set w;
    FD_ZERO(&w);
    int maxFd = -1;
    for (int i = 0; i < count; i++) {
        FD_SET(fds[i], &w);
        if (fds[i] > maxFd) maxFd = fds[i];
    }
    BOOL ok = NO;
    if (select(maxFd + 1, NULL, &w, NULL, &tv) > 0) {
        for (int i = 0; i < count && !ok; i++) {
            if (!FD_ISSET(fds[i], &w)) continue;
            int err = 0;
            socklen_t len = sizeof(err);
            getsockopt(fds[i], SOL_SOCKET, SO_ERROR, &err, &len);
            ok = (err == 0);
        }
    }
    for (int i = 0; i < count; i++) close(fds[i]);
    return ok;
}

/*
 * Troubadour: ключ сети по списку интерфейсов, а не по маршруту.
 *
 * У автора основной канал находил DNPrimaryUplink из части для службы:
 * таблица маршрутов через сокет PF_ROUTE и SCDynamicStore через dlsym.
 * Приложению это ни к чему: ключ нужен только затем, чтобы заметить
 * переход в другую сеть. Wi-Fi различаем по своему адресу в ней (у каждой
 * сети он свой), сотовую — по интерфейсу, как и у автора: адрес там
 * меняется от подключения к подключению. Wi-Fi важнее: пока он поднят,
 * iOS ходит наружу через него.
 */
+ (NSString *)networkKey {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0 || list == NULL) {
        return @"нет сети";
    }
    NSString *wifi = nil;
    NSString *cellular = nil;
    for (struct ifaddrs *i = list; i != NULL; i = i->ifa_next) {
        if (i->ifa_addr == NULL || i->ifa_addr->sa_family != AF_INET) continue;
        if (!(i->ifa_flags & IFF_UP) || (i->ifa_flags & IFF_LOOPBACK)) continue;
        char address[INET_ADDRSTRLEN] = {0};
        inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr,
                  address, sizeof(address));
        if (wifi == nil && strncmp(i->ifa_name, "en", 2) == 0) {
            wifi = [NSString stringWithFormat:@"%s:%s", i->ifa_name, address];
        } else if (cellular == nil && strncmp(i->ifa_name, "pdp_ip", 6) == 0) {
            cellular = [NSString stringWithFormat:@"сотовая:%s", i->ifa_name];
        }
    }
    freeifaddrs(list);
    return wifi ?: (cellular ?: @"нет сети");
}

+ (DNNetworkKind)fingerprintNetwork {
    // Отпечаток нужен на каждой починке и у сторожа, поэтому он должен быть
    // быстрым. Вопрос, по сути, один: пускают ли наружу.
    static NSString *cachedKey;
    static DNNetworkKind cachedKind;
    static NSTimeInterval cachedAt;
    NSString *key = [self networkKey];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    @synchronized (self) {
        if (cachedKey && [cachedKey isEqualToString:key] && now - cachedAt < 30.0) return cachedKind;
    }

    // Пробы идут разом и по адресам, без имён: в сети с белым списком
    // разрешение имени висит секунд двадцать и одно съедает всё время пробы.
    static const char *kOutside[] = { "1.1.1.1", "104.16.132.229",
                                      "140.82.121.4", "8.8.8.8", NULL };
    static const char *kAllowed[] = { "87.240.132.67", "213.59.253.7", NULL };

    DNNetworkKind kind;
    if (DanteAnyReachable(kOutside, 443, 2.5)) kind = DNNetworkOpen;
    else if (DanteAnyReachable(kAllowed, 443, 2.5)) kind = DNNetworkRestricted;
    else kind = DNNetworkOffline;

    @synchronized (self) {
        cachedKey = [key copy];
        cachedKind = kind;
        cachedAt = now;
    }
    DLog(@"[net] сеть %@ — %@", key,
         kind == DNNetworkOpen ? @"пускают наружу"
         : kind == DNNetworkRestricted ? @"только белый список" : @"не отвечает никто");
    return kind;
}

@end
