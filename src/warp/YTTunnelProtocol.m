#import "YTTunnelProtocol.h"

#import <libkern/OSAtomic.h>
#import <objc/runtime.h>
#import <Security/SecureTransport.h>
#import <Security/Security.h>
#import <zlib.h>

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#import "YTHttp.h"
#import "YTStrings.h"
#import "YTWarp.h"

/**
 * Значение константы NSURLErrorDomain совпадает с её именем. Пишем строкой
 * по той же причине, что и классы ищем по имени: сетевые символы Foundation
 * на разных iOS экспортируют разные библиотеки.
 */
static NSString *const YTTunnelErrorDomain = @"NSURLErrorDomain";

/** Предел заголовков ответа: дальше это уже не HTTP, а мусор. */
static const NSUInteger YTTunnelHeadLimit = 64 * 1024;

/**
 * Сколько запрос ждёт туннель, пока обход подключается.
 *
 * Подключение с регистрацией своей личности занимает до полуминуты с
 * небольшим; дольше держать запрос нет смысла — значит, что-то не так.
 */
static const NSTimeInterval YTTunnelWaitLimit = 45.0;

/**
 * Сколько держим открытое соединение без дела и сколько их на один узел.
 *
 * Google закрывает простаивающее соединение сам через минуту-другую;
 * двадцать секунд — с запасом, чтобы не наткнуться на уже закрытое.
 */
static const NSTimeInterval YTTunnelIdleLimit = 20.0;
static const NSUInteger YTTunnelIdlePerHost = 4;

/**
 * Срок на рукопожатие TLS и сколько раз открывать соединение заново.
 *
 * Через WARP часть соединений умирает сразу после открытия: сервер
 * подтверждает наш первый пакет, а его ответ не приходит никогда — стек
 * туннеля пишет «open 10s with nothing delivered (in 0 …)». Какие
 * соединения так умрут, заранее не видно, а новое обычно проходит.
 * Здоровое рукопожатие через туннель укладывается в полсекунды, поэтому
 * ждём четыре и открываем другое — до трёх раз.
 */
static const NSTimeInterval YTTunnelHandshakeLimit = 4.0;
static const NSUInteger YTTunnelFreshAttempts = 3;


#pragma mark - Сокет

static BOOL YTTunnelWriteAll(int fd, const void *bytes, size_t length) {
    const uint8_t *p = bytes;

    while (length > 0) {
        ssize_t n = send(fd, p, length, 0);

        if (n > 0) {
            p += n;
            length -= (size_t)n;
            continue;
        }

        if (n < 0 && errno == EINTR) {
            continue;
        }

        return NO;
    }

    return YES;
}

static BOOL YTTunnelReadExact(int fd, void *bytes, size_t length) {
    uint8_t *p = bytes;

    while (length > 0) {
        ssize_t n = recv(fd, p, length, 0);

        if (n > 0) {
            p += n;
            length -= (size_t)n;
            continue;
        }

        if (n < 0 && errno == EINTR) {
            continue;
        }

        return NO;
    }

    return YES;
}

/**
 * SOCKS5 CONNECT к узлу по имени.
 *
 * Имя, а не адрес, нарочно: разрешает его туннель, изнутри WireGuard.
 * Местный DNS в сети с блокировкой отвечает на имена YouTube подделкой
 * или не отвечает вовсе — автор Dante-WARP пишет об этом у
 * resolveHostThroughTunnel:, и приёмник туннеля имена принимает.
 */
static BOOL YTTunnelSocksConnect(int fd, NSString *host, uint16_t port) {
    uint8_t hello[3] = { 0x05, 0x01, 0x00 };
    uint8_t answer[2];

    if (!YTTunnelWriteAll(fd, hello, sizeof(hello)) ||
        !YTTunnelReadExact(fd, answer, sizeof(answer)) ||
        answer[0] != 0x05 || answer[1] != 0x00) {
        return NO;
    }

    NSData *name = [host dataUsingEncoding:NSUTF8StringEncoding];

    if ([name length] == 0 || [name length] > 255) {
        return NO;
    }

    uint8_t request[4 + 1 + 255 + 2];
    size_t at = 0;

    request[at++] = 0x05;               // версия
    request[at++] = 0x01;               // CONNECT
    request[at++] = 0x00;
    request[at++] = 0x03;               // адрес — имя узла
    request[at++] = (uint8_t)[name length];

    memcpy(request + at, [name bytes], [name length]);
    at += [name length];

    request[at++] = (uint8_t)(port >> 8);
    request[at++] = (uint8_t)(port & 0xFF);

    if (!YTTunnelWriteAll(fd, request, at)) {
        return NO;
    }

    uint8_t head[4];

    if (!YTTunnelReadExact(fd, head, sizeof(head)) || head[0] != 0x05 || head[1] != 0x00) {
        return NO;
    }

    // Адрес в ответе нам не нужен, но его надо дочитать.
    uint8_t skip[256 + 2];
    size_t tail = 0;

    if (head[3] == 0x01) {
        tail = 4 + 2;
    } else if (head[3] == 0x04) {
        tail = 16 + 2;
    } else if (head[3] == 0x03) {
        uint8_t length = 0;

        if (!YTTunnelReadExact(fd, &length, 1)) {
            return NO;
        }

        tail = (size_t)length + 2;
    } else {
        return NO;
    }

    return YTTunnelReadExact(fd, skip, tail);
}


#pragma mark - TLS

/**
 * Ввод-вывод SecureTransport поверх блокирующего сокета.
 *
 * Читаем и пишем ровно столько, сколько просят: сокет блокирующий, с пределом
 * ожидания (SO_RCVTIMEO). Истёкший предел приходит как EAGAIN и значит
 * обрыв — неполной записи SecureTransport здесь не ждёт.
 */
static OSStatus YTTunnelSSLRead(SSLConnectionRef connection, void *data, size_t *length) {
    int fd = (int)(intptr_t)connection;

    size_t want = *length;
    size_t got = 0;

    while (got < want) {
        ssize_t n = recv(fd, (uint8_t *)data + got, want - got, 0);

        if (n > 0) {
            got += (size_t)n;
            continue;
        }

        *length = got;

        if (n == 0) {
            return errSSLClosedGraceful;
        }

        if (errno == EINTR) {
            continue;
        }

        return errSSLClosedAbort;
    }

    *length = got;

    return noErr;
}

static OSStatus YTTunnelSSLWrite(SSLConnectionRef connection, const void *data, size_t *length) {
    int fd = (int)(intptr_t)connection;

    if (!YTTunnelWriteAll(fd, data, *length)) {
        *length = 0;
        return errSSLClosedAbort;
    }

    return noErr;
}


#pragma mark - Запас соединений

/**
 * Соединение, оставшееся открытым после ответа.
 *
 * Новое соединение через туннель — это TCP внутри WireGuard и рукопожатие
 * TLS поверх него: три-четыре круга до сервера, а на плохой связи, с
 * повторами пакетов, — секунды. Превью главной — десятки запросов к одному
 * i.ytimg.com, и без запаса каждый платил эту цену заново.
 */
@interface YTTunnelLink : NSObject {
@public
    int fd;
    SSLContextRef ssl;

    /** Порт SOCKS туннеля: туннель переподключился — соединение уже чужое. */
    uint16_t socks;

    NSTimeInterval idleSince;
}
- (void)drop;
@end

@implementation YTTunnelLink

- (id)init {
    self = [super init];

    if (self != nil) {
        fd = -1;
    }

    return self;
}

- (void)drop {
    if (ssl != NULL) {
        SSLClose(ssl);
        CFRelease(ssl);
        ssl = NULL;
    }

    if (fd >= 0) {
        close(fd);
        fd = -1;
    }
}

- (void)dealloc {
    [self drop];
}

@end

/** Ключ запаса → NSMutableArray соединений, свежие в конце. */
static NSMutableDictionary *YTTunnelIdle = nil;

/**
 * Соединение ещё годно: сервер его не закрыл и ничего не прислал без спроса.
 *
 * Подглядываем в сокет, не ожидая: закрытое отдаёт 0, живое и молчащее —
 * EAGAIN. Всё остальное — непонятное состояние, лучше открыть новое.
 */
static BOOL YTTunnelLinkAlive(YTTunnelLink *link) {
    if (link->ssl != NULL) {
        size_t buffered = 0;

        if (SSLGetBufferedReadSize(link->ssl, &buffered) == noErr && buffered > 0) {
            return NO;
        }
    }

    uint8_t probe;
    ssize_t n = recv(link->fd, &probe, 1, MSG_PEEK | MSG_DONTWAIT);

    return n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK);
}

static YTTunnelLink *YTTunnelTakeLink(NSString *key, uint16_t socks) {
    NSMutableArray *dead = [NSMutableArray array];
    YTTunnelLink *found = nil;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    @synchronized ([YTTunnelLink class]) {
        NSMutableArray *list = [YTTunnelIdle objectForKey:key];

        while ([list count] > 0) {
            YTTunnelLink *link = [list lastObject];

            [list removeLastObject];

            if (link->socks == socks && now - link->idleSince < YTTunnelIdleLimit &&
                YTTunnelLinkAlive(link)) {
                found = link;
                break;
            }

            [dead addObject:link];
        }
    }

    // Закрываем вне замка: SSLClose пишет в сокет.
    for (YTTunnelLink *link in dead) {
        [link drop];
    }

    return found;
}

static void YTTunnelKeepLink(NSString *key, YTTunnelLink *link) {
    NSMutableArray *dead = [NSMutableArray array];

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    link->idleSince = now;

    @synchronized ([YTTunnelLink class]) {
        if (YTTunnelIdle == nil) {
            YTTunnelIdle = [[NSMutableDictionary alloc] init];
        }

        // Заодно выметаем залежавшиеся и оставшиеся от прежнего туннеля.
        for (NSString *other in [YTTunnelIdle allKeys]) {
            NSMutableArray *list = [YTTunnelIdle objectForKey:other];

            for (NSInteger i = (NSInteger)[list count] - 1; i >= 0; i--) {
                YTTunnelLink *old = [list objectAtIndex:(NSUInteger)i];

                if (old->socks != link->socks || now - old->idleSince >= YTTunnelIdleLimit) {
                    [dead addObject:old];
                    [list removeObjectAtIndex:(NSUInteger)i];
                }
            }

            if ([list count] == 0) {
                [YTTunnelIdle removeObjectForKey:other];
            }
        }

        NSMutableArray *list = [YTTunnelIdle objectForKey:key];

        if (list == nil) {
            list = [NSMutableArray array];
            [YTTunnelIdle setObject:list forKey:key];
        }

        [list addObject:link];

        while ([list count] > YTTunnelIdlePerHost) {
            [dead addObject:[list objectAtIndex:0]];
            [list removeObjectAtIndex:0];
        }
    }

    for (YTTunnelLink *old in dead) {
        [old drop];
    }
}

/** Начало непонятного ответа — в журнал: по нему видно, что пришло. */
static NSString *YTTunnelPreview(NSData *data) {
    NSUInteger length = MIN([data length], (NSUInteger)48);
    const uint8_t *bytes = [data bytes];

    NSMutableString *text = [NSMutableString string];
    NSMutableString *hex = [NSMutableString string];

    for (NSUInteger i = 0; i < length; i++) {
        uint8_t c = bytes[i];

        [text appendFormat:@"%c", (c >= 0x20 && c < 0x7F) ? c : '.'];

        if (i < 12) {
            [hex appendFormat:@"%02x ", c];
        }
    }

    return [NSString stringWithFormat:@"%lu байт, %@| %@",
            (unsigned long)[data length], hex, text];
}


#pragma mark - Загрузка

typedef enum {
    YTChunkSize = 0,
    YTChunkData,
    YTChunkDataEnd,
    YTChunkTrailer,
    YTChunkDone
} YTChunkState;

@interface YTTunnelLoad : NSObject
- (id)initWithProtocol:(id)protocol;
- (void)start;
- (void)stop;
@end

@implementation YTTunnelLoad {
    id _protocol;
    id _client;
    NSURLRequest *_request;

    NSThread *_clientThread;
    NSArray *_modes;

    volatile int32_t _stopped;

    int _fd;
    SSLContextRef _ssl;

    /** Причина неудачного чтения: истёк предел ожидания или обрыв. */
    BOOL _timedOut;

    /** Порт SOCKS и ключ запаса: «https://host:port». */
    uint16_t _socks;
    NSString *_linkKey;

    /** Соединение взято из запаса, а не открыто заново. */
    BOOL _reused;

    /** От сервера пришёл хоть байт ответа: повторять запрос уже нельзя. */
    BOOL _heard;

    /** Ответ дочитан до конца; клиенту сказать об этом — после запаса. */
    BOOL _finished;

    /** Соединение после ответа можно вернуть в запас. */
    BOOL _reusable;

    /** Рукопожатие не дождалось сервера за YTTunnelHandshakeLimit. */
    BOOL _stalled;

    // Разбор тела.
    BOOL _chunked;
    YTChunkState _chunkState;
    unsigned long long _chunkLeft;
    NSMutableData *_chunkLine;

    BOOL _gzip;
    BOOL _zReady;
    z_stream _z;
}

- (id)initWithProtocol:(id)protocol {
    self = [super init];

    if (self != nil) {
        _protocol = protocol;
        _client = [protocol client];
        _request = [[protocol request] copy];
        _fd = -1;
    }

    return self;
}

- (void)dealloc {
    if (_zReady) {
        inflateEnd(&_z);
    }
}

- (void)start {
    _clientThread = [NSThread currentThread];

    /**
     * Ответы клиенту — на его же поток и в его же режиме цикла.
     *
     * Так требует NSURLProtocol: клиента зовут на том потоке, где позвали
     * startLoading. Режим берём нынешний и вдобавок общие — UIWebView
     * крутит свой цикл не всегда в режиме по умолчанию.
     */
    NSMutableArray *modes = [NSMutableArray arrayWithObject:NSRunLoopCommonModes];
    NSString *mode = [[NSRunLoop currentRunLoop] currentMode];

    if (mode != nil && ![mode isEqualToString:NSRunLoopCommonModes]) {
        [modes addObject:mode];
    }

    _modes = modes;

    NSThread *worker = [[NSThread alloc] initWithTarget:self
                                               selector:@selector(work)
                                                 object:nil];

    [worker setStackSize:256 * 1024];
    [worker start];
}

- (void)stop {
    _stopped = 1;

    OSMemoryBarrier();

    // Разбудить рабочий поток, если он ждёт сети.
    int fd = _fd;

    if (fd >= 0) {
        shutdown(fd, SHUT_RDWR);
    }

    _protocol = nil;
    _client = nil;
}

#pragma mark Ответы клиенту

- (void)post:(SEL)selector with:(id)argument {
    if (_stopped) {
        return;
    }

    [self performSelector:selector
                 onThread:_clientThread
               withObject:argument
            waitUntilDone:NO
                    modes:_modes];
}

- (void)deliverResponse:(NSURLResponse *)response {
    if (_stopped || _client == nil) {
        return;
    }

    /**
     * Хранить в кеше — можно. Решает всё равно тот, кто спросил:
     * YTHttp отвечает на willCacheResponse: сам, и видео в дисковый кеш
     * не попадёт, а превью — как и без туннеля.
     */
    [_client URLProtocol:_protocol
      didReceiveResponse:response
      cacheStoragePolicy:NSURLCacheStorageAllowed];
}

- (void)deliverData:(NSData *)data {
    if (_stopped || _client == nil) {
        return;
    }

    [_client URLProtocol:_protocol didLoadData:data];
}

- (void)deliverFinish:(id)unused {
    if (_stopped || _client == nil) {
        return;
    }

    [_client URLProtocolDidFinishLoading:_protocol];
}

- (void)deliverError:(NSError *)error {
    if (_stopped || _client == nil) {
        return;
    }

    [_client URLProtocol:_protocol didFailWithError:error];
}

- (void)deliverRedirect:(NSArray *)pair {
    if (_stopped || _client == nil) {
        return;
    }

    [_client URLProtocol:_protocol
  wasRedirectedToRequest:[pair objectAtIndex:0]
        redirectResponse:[pair objectAtIndex:1]];
}

- (NSError *)errorWithCode:(NSInteger)code text:(NSString *)text {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    [info setObject:text forKey:NSLocalizedDescriptionKey];

    if ([_request URL] != nil) {
        [info setObject:[_request URL] forKey:@"NSErrorFailingURLKey"];
    }

    return [NSError errorWithDomain:YTTunnelErrorDomain code:code userInfo:info];
}

#pragma mark Рабочий поток

- (void)work {
    @autoreleasepool {
        NSError *error = [self run];

        if (error != nil) {
            NSLog(@"[YouTube/Туннель] %@ %@: %@", [_request HTTPMethod],
                  [[_request URL] host], [error localizedDescription]);

            [self post:@selector(deliverError:) with:error];
        }

        /**
         * Ответ дочитан чисто — соединение в запас, и только потом клиенту
         * «готово»: его следующий запрос к тому же узлу тогда уже застанет
         * соединение открытым.
         */
        if (error == nil && _reusable && !_stopped && _fd >= 0) {
            YTTunnelLink *link = [[YTTunnelLink alloc] init];

            link->ssl = _ssl;
            link->socks = _socks;
            _ssl = NULL;

            link->fd = _fd;
            _fd = -1;

            YTTunnelKeepLink(_linkKey, link);
        }

        if (_finished) {
            [self post:@selector(deliverFinish:) with:nil];
        }

        [self dropConnection];
    }
}

- (void)dropConnection {
    int fd = _fd;

    // Сперва забываем: stop с другого потока не должен тронуть чужой сокет
    // с тем же номером.
    _fd = -1;
    OSMemoryBarrier();

    if (_ssl != NULL) {
        SSLClose(_ssl);
        CFRelease(_ssl);
        _ssl = NULL;
    }

    if (fd >= 0) {
        close(fd);
    }
}

/**
 * Туннель — сейчас или, если обход ещё подключается, когда поднимется.
 *
 * 0 — туннеля нет и не будет в пределах ожидания.
 */
- (uint16_t)waitForTunnel {
    uint16_t socks = [YTWarp socksPort];

    NSTimeInterval waited = 0;

    while (socks == 0 && [YTWarp isConnecting] && !_stopped && waited < YTTunnelWaitLimit) {
        usleep(200 * 1000);
        waited += 0.2;

        socks = [YTWarp socksPort];
    }

    if (waited >= 1 && !_stopped) {
        NSLog(@"[YouTube/Туннель] %@: туннель ждали %.0f с%@", [[_request URL] host], waited,
              socks != 0 ? @"" : @" и не дождались");
    }

    return socks;
}

/** Всё от соединения до последнего байта. nil — дошло до конца или остановлено. */
- (NSError *)run {
    NSURL *url = [_request URL];
    NSString *host = [url host];
    NSString *scheme = [[url scheme] lowercaseString];

    BOOL secure = [scheme isEqualToString:@"https"];

    uint16_t port = [url port] != nil
        ? (uint16_t)[[url port] unsignedShortValue]
        : (secure ? 443 : 80);

    _socks = [self waitForTunnel];

    if (_stopped) {
        return nil;
    }

    if (_socks == 0) {
        return [self errorWithCode:NSURLErrorCannotConnectToHost
                              text:YTLoc(@"Обход блокировок не подключён")];
    }

    _linkKey = [NSString stringWithFormat:@"%@://%@:%u", secure ? @"https" : @"http",
                [host lowercaseString], port];

    /**
     * Предел ожидания — у каждого чтения и записи, а не на весь ответ:
     * видео течёт минутами, а замереть вправе не дольше, чем просил
     * запрос. Совсем без предела поток ждал бы вечно.
     */
    NSTimeInterval timeout = [_request timeoutInterval];

    if (timeout <= 0 || timeout > 120) {
        timeout = 60;
    }

    /**
     * Повтор — только пока сервер не сказал ни байта.
     *
     * Соединение из запаса могло тихо умереть — тогда просто берём другое.
     * Свежее умирает в туннеле (см. YTTunnelHandshakeLimit) — открываем
     * новое, всего до трёх. Истёкший предел самого запроса не повторяем:
     * запрос и так прождал всё, что ему было отпущено.
     */
    NSUInteger fresh = 0;

    for (;;) {
        _stalled = NO;

        NSError *error = [self attemptHost:host port:port secure:secure timeout:timeout];

        if (error == nil || _stopped) {
            return _stopped ? nil : error;
        }

        if (!_reused) {
            fresh++;
        }

        BOOL again = !_heard &&
            (_reused || (fresh < YTTunnelFreshAttempts && (!_timedOut || _stalled)));

        [self dropConnection];

        if (!again) {
            return error;
        }

        NSLog(@"[YouTube/Туннель] %@ %@: %@ — %@", [_request HTTPMethod], host,
              _stalled ? @"сервер молчит" : [error localizedDescription],
              _reused ? @"соединение из запаса устарело, открываю новое"
                      : [NSString stringWithFormat:@"открываю новое (%lu/%lu)",
                         (unsigned long)fresh + 1, (unsigned long)YTTunnelFreshAttempts]);

        _timedOut = NO;
    }
}

- (void)applyTimeout:(NSTimeInterval)timeout {
    struct timeval limit;

    limit.tv_sec = (time_t)timeout;
    limit.tv_usec = 0;

    setsockopt(_fd, SOL_SOCKET, SO_RCVTIMEO, &limit, sizeof(limit));
    setsockopt(_fd, SOL_SOCKET, SO_SNDTIMEO, &limit, sizeof(limit));
}

/** Одна попытка: соединение (из запаса или новое), запрос, ответ. */
- (NSError *)attemptHost:(NSString *)host port:(uint16_t)port secure:(BOOL)secure
                 timeout:(NSTimeInterval)timeout {
    _heard = NO;
    _reusable = NO;
    _finished = NO;

    YTTunnelLink *link = YTTunnelTakeLink(_linkKey, _socks);

    _reused = (link != nil);

    if (link != nil) {
        _ssl = link->ssl;
        link->ssl = NULL;

        _fd = link->fd;
        link->fd = -1;

        [self applyTimeout:timeout];
    } else {
        NSError *failure = [self openHost:host port:port secure:secure timeout:timeout];

        if (failure != nil || _stopped) {
            return failure;
        }
    }

    if (_stopped) {
        return nil;
    }

    // --- Запрос.
    NSData *head = [self requestHeadWithHost:host port:port secure:secure];
    NSData *body = [self requestBody];

    if (![self send:head] || ([body length] > 0 && ![self send:body])) {
        return _stopped ? nil : [self errorWithCode:NSURLErrorNetworkConnectionLost
                                               text:YTLoc(@"Соединение оборвалось")];
    }

    // --- Ответ.
    return [self readResponse];
}

/** Новое соединение: локальный SOCKS5, CONNECT по имени, TLS. */
- (NSError *)openHost:(NSString *)host port:(uint16_t)port secure:(BOOL)secure
              timeout:(NSTimeInterval)timeout {
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);

    if (fd < 0) {
        return [self errorWithCode:NSURLErrorCannotConnectToHost text:@"socket()"];
    }

    _fd = fd;

    int one = 1;

    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    [self applyTimeout:timeout];

    struct sockaddr_in local;

    memset(&local, 0, sizeof(local));
    local.sin_len = sizeof(local);
    local.sin_family = AF_INET;
    local.sin_port = htons(_socks);
    local.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (connect(fd, (struct sockaddr *)&local, sizeof(local)) != 0) {
        return [self errorWithCode:NSURLErrorCannotConnectToHost
                              text:YTLoc(@"Обход блокировок не подключён")];
    }

    if (_stopped) {
        return nil;
    }

    if (!YTTunnelSocksConnect(fd, host, port)) {
        return [self errorWithCode:NSURLErrorCannotConnectToHost
                              text:YTLoc(@"Туннель не довёл до сервера")];
    }

    if (_stopped) {
        return nil;
    }

    // --- TLS до сервера, с проверкой сертификата до запроса.
    if (secure) {
        // Короткий срок — только на рукопожатие (см. YTTunnelHandshakeLimit).
        NSTimeInterval limit = MIN(timeout, YTTunnelHandshakeLimit);

        [self applyTimeout:limit];

        NSTimeInterval began = [NSDate timeIntervalSinceReferenceDate];
        NSError *failure = [self handshakeWithHost:host];

        if (failure != nil) {
            NSTimeInterval spent = [NSDate timeIntervalSinceReferenceDate] - began;

            _stalled = !_stopped && spent >= limit - 0.5;

            return failure;
        }

        [self applyTimeout:timeout];
    }

    return nil;
}

- (NSError *)handshakeWithHost:(NSString *)host {
    _ssl = SSLCreateContext(kCFAllocatorDefault, kSSLClientSide, kSSLStreamType);

    if (_ssl == NULL) {
        return [self errorWithCode:NSURLErrorSecureConnectionFailed text:@"SSLCreateContext"];
    }

    const char *name = [host UTF8String];

    SSLSetIOFuncs(_ssl, YTTunnelSSLRead, YTTunnelSSLWrite);
    SSLSetConnection(_ssl, (SSLConnectionRef)(intptr_t)_fd);
    SSLSetPeerDomainName(_ssl, name, strlen(name));

    /**
     * Возобновление сессии: второе и следующие рукопожатия с тем же узлом
     * идут в один круг, без цепочки сертификатов и без её проверки.
     *
     * Проверку это не обходит: сессия попадает в кеш, только когда
     * рукопожатие дошло до конца, а до конца оно доходит лишь после того,
     * как сертификат прошёл проверку ниже.
     */
    const char *peer = [_linkKey UTF8String];

    SSLSetPeerID(_ssl, peer, strlen(peer));
    SSLSetProtocolVersionMin(_ssl, kTLSProtocol1);
    SSLSetProtocolVersionMax(_ssl, kTLSProtocol12);

    /**
     * Рукопожатие останавливается на проверке сервера — и тут проверяем мы.
     *
     * Сама SecureTransport на старых iOS отвергла бы цепочку Google (корней
     * GTS там нет), поэтому проверяет YTServerTrustIsValid — та же, что
     * у YTHttp, со своими корнями. И проверяет **до** отправки запроса:
     * в заголовках едет токен учётной записи.
     */
    SSLSetSessionOption(_ssl, kSSLSessionOptionBreakOnServerAuth, true);

    OSStatus status;

    // Предохранитель, как у автора в AWGHTTPSTransport: рукопожатие
    // не должно крутиться вечно, что бы ни вернула SecureTransport.
    int rounds = 0;

    do {
        if (++rounds > 64 || _stopped) {
            status = errSSLClosedAbort;
            break;
        }

        status = SSLHandshake(_ssl);

        if (status == errSSLServerAuthCompleted) {
            SecTrustRef trust = NULL;

            if (SSLCopyPeerTrust(_ssl, &trust) != noErr || trust == NULL) {
                return [self errorWithCode:NSURLErrorServerCertificateUntrusted
                                      text:YTLoc(@"Сервер не предъявил сертификат")];
            }

#ifdef YT_INSECURE_TLS
            // Отладочная сборка: как и в YTHttp, проверка снята целиком.
            NSLog(@"[YouTube/Туннель] !!! ПРОВЕРКА СЕРТИФИКАТОВ ОТКЛЮЧЕНА: %@", host);
            BOOL valid = YES;
#else
            BOOL valid = YTServerTrustIsValid(trust, host);
#endif

            CFRelease(trust);

            if (!valid) {
                return [self errorWithCode:NSURLErrorServerCertificateUntrusted
                                      text:YTLoc(@"Сертификат сервера не прошёл проверку")];
            }
        }
    } while (status == errSSLServerAuthCompleted || status == errSSLWouldBlock);

    if (status != noErr) {
        return _stopped ? nil : [self errorWithCode:NSURLErrorSecureConnectionFailed
                                               text:YTLoc(@"Защищённое соединение не установилось")];
    }

    return nil;
}

#pragma mark Запрос

/**
 * Заголовок запроса по образцу NSURLConnection.
 *
 * То, что NSURLConnection добавляет сам, приходится добавлять самим:
 * куки из общего хранилища (на них держится вход в браузере), язык,
 * Accept. Сжатие — gzip, распаковываем сами: ответы InnerTube сжимаются
 * раз в десять, а через туннель каждый байт дороже.
 *
 * `Connection: keep-alive` — соединение после ответа остаётся открытым
 * и ждёт в запасе следующего запроса к тому же узлу (см. YTTunnelLink).
 */
- (NSData *)requestHeadWithHost:(NSString *)host port:(uint16_t)port secure:(BOOL)secure {
    NSURL *url = [_request URL];

    // Путь — как есть, в процентах: -path раскодировал бы его.
    NSString *path = (__bridge_transfer NSString *)CFURLCopyPath((__bridge CFURLRef)url);

    if ([path length] == 0) {
        path = @"/";
    }

    NSString *query = [url query];

    if ([query length] > 0) {
        path = [path stringByAppendingFormat:@"?%@", query];
    }

    NSString *method = [_request HTTPMethod] ?: @"GET";

    NSMutableString *head = [NSMutableString stringWithFormat:@"%@ %@ HTTP/1.1\r\n", method, path];

    BOOL defaultPort = (secure && port == 443) || (!secure && port == 80);

    [head appendFormat:@"Host: %@\r\n", defaultPort
        ? host : [NSString stringWithFormat:@"%@:%u", host, port]];

    NSDictionary *fields = [_request allHTTPHeaderFields];
    NSSet *ours = [NSSet setWithObjects:@"host", @"connection", @"proxy-connection",
                   @"keep-alive", @"accept-encoding", @"content-length",
                   @"transfer-encoding", @"te", @"upgrade", nil];

    BOOL hasAgent = NO;
    BOOL hasAccept = NO;
    BOOL hasLanguage = NO;
    BOOL hasCookie = NO;

    for (NSString *name in fields) {
        NSString *lower = [name lowercaseString];

        if ([ours containsObject:lower]) {
            continue;
        }

        if ([lower isEqualToString:@"user-agent"]) { hasAgent = YES; }
        if ([lower isEqualToString:@"accept"]) { hasAccept = YES; }
        if ([lower isEqualToString:@"accept-language"]) { hasLanguage = YES; }
        if ([lower isEqualToString:@"cookie"]) { hasCookie = YES; }

        [head appendFormat:@"%@: %@\r\n", name, [fields objectForKey:name]];
    }

    if (!hasCookie && [_request HTTPShouldHandleCookies]) {
        NSArray *cookies = [[NSClassFromString(@"NSHTTPCookieStorage") sharedHTTPCookieStorage]
            cookiesForURL:url];

        if ([cookies count] > 0) {
            NSDictionary *cookieFields =
                [NSClassFromString(@"NSHTTPCookie") requestHeaderFieldsWithCookies:cookies];

            NSString *cookie = [cookieFields objectForKey:@"Cookie"];

            if ([cookie length] > 0) {
                [head appendFormat:@"Cookie: %@\r\n", cookie];
            }
        }
    }

    if (!hasAgent) {
        NSDictionary *info = [[NSBundle mainBundle] infoDictionary];

        [head appendFormat:@"User-Agent: %@/%@ CFNetwork\r\n",
            [info objectForKey:@"CFBundleName"] ?: @"Troubadour",
            [info objectForKey:@"CFBundleVersion"] ?: @"1"];
    }

    if (!hasAccept) {
        [head appendString:@"Accept: */*\r\n"];
    }

    if (!hasLanguage) {
        NSArray *languages = [NSLocale preferredLanguages];

        if ([languages count] > 0) {
            [head appendFormat:@"Accept-Language: %@\r\n", [languages objectAtIndex:0]];
        }
    }

    NSData *body = [self requestBody];
    NSString *upper = [method uppercaseString];

    if ([body length] > 0 || [upper isEqualToString:@"POST"] ||
        [upper isEqualToString:@"PUT"] || [upper isEqualToString:@"PATCH"]) {
        [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long)[body length]];
    }

    [head appendString:@"Accept-Encoding: gzip\r\n"];
    [head appendString:@"Connection: keep-alive\r\n\r\n"];

    return [head dataUsingEncoding:NSUTF8StringEncoding];
}

/**
 * Тело запроса: HTTPBody или поток.
 *
 * UIWebView отдаёт тело POST потоком, а не данными; читаем его целиком —
 * запросы у нас маленькие. Прочитанное запоминаем: поток читается один раз.
 */
- (NSData *)requestBody {
    static char key;

    NSData *cached = objc_getAssociatedObject(self, &key);

    if (cached != nil) {
        return cached;
    }

    NSData *body = [_request HTTPBody];

    if (body == nil && [_request HTTPBodyStream] != nil) {
        NSInputStream *stream = [_request HTTPBodyStream];
        NSMutableData *collected = [NSMutableData data];
        uint8_t buffer[16384];

        [stream open];

        for (;;) {
            NSInteger n = [stream read:buffer maxLength:sizeof(buffer)];

            if (n <= 0) {
                break;
            }

            [collected appendBytes:buffer length:(NSUInteger)n];
        }

        [stream close];

        body = collected;
    }

    body = body ?: [NSData data];

    objc_setAssociatedObject(self, &key, body, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    return body;
}

#pragma mark Ввод-вывод

- (BOOL)send:(NSData *)data {
    if (_ssl != NULL) {
        size_t written = 0;
        const uint8_t *bytes = [data bytes];
        size_t left = [data length];

        while (left > 0) {
            written = 0;

            OSStatus status = SSLWrite(_ssl, bytes, left, &written);

            if (status != noErr && status != errSSLWouldBlock) {
                return NO;
            }

            bytes += written;
            left -= written;
        }

        return YES;
    }

    return YTTunnelWriteAll(_fd, [data bytes], [data length]);
}

/** Сколько-то байт; 0 — конец, -1 — обрыв (причина — в _timedOut). */
- (NSInteger)receive:(uint8_t *)buffer max:(size_t)max {
    if (_ssl != NULL) {
        for (;;) {
            size_t processed = 0;

            OSStatus status = SSLRead(_ssl, buffer, max, &processed);

            if (processed > 0) {
                return (NSInteger)processed;
            }

            if (status == errSSLClosedGraceful || status == errSSLClosedNoNotify) {
                return 0;
            }

            if (status == errSSLWouldBlock) {
                continue;
            }

            _timedOut = (errno == EAGAIN || errno == EWOULDBLOCK);

            return -1;
        }
    }

    for (;;) {
        ssize_t n = recv(_fd, buffer, max, 0);

        if (n >= 0) {
            return (NSInteger)n;
        }

        if (errno == EINTR) {
            continue;
        }

        _timedOut = (errno == EAGAIN || errno == EWOULDBLOCK);

        return -1;
    }
}

- (NSError *)lostError {
    if (_timedOut) {
        return [self errorWithCode:NSURLErrorTimedOut text:YTLoc(@"Сервер не ответил")];
    }

    return [self errorWithCode:NSURLErrorNetworkConnectionLost text:YTLoc(@"Соединение оборвалось")];
}

#pragma mark Ответ

- (NSError *)readResponse {
    NSMutableData *pending = [NSMutableData data];
    uint8_t buffer[32768];

    for (;;) {
        // --- Заголовки (пропуская промежуточные 1xx).
        NSRange end = NSMakeRange(NSNotFound, 0);

        while ((end = [pending rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4]
                                   options:0
                                     range:NSMakeRange(0, [pending length])]).location == NSNotFound) {
            if ([pending length] > YTTunnelHeadLimit) {
                NSLog(@"[YouTube/Туннель] Заголовки без конца: %@", YTTunnelPreview(pending));

                return [self errorWithCode:NSURLErrorBadServerResponse
                                      text:YTLoc(@"Сервер ответил не по-человечески")];
            }

            NSInteger n = [self receive:buffer max:sizeof(buffer)];

            if (_stopped) {
                return nil;
            }

            if (n <= 0) {
                return n == 0
                    ? [self errorWithCode:NSURLErrorNetworkConnectionLost
                                     text:YTLoc(@"Соединение оборвалось")]
                    : [self lostError];
            }

            _heard = YES;

            [pending appendBytes:buffer length:(NSUInteger)n];
        }

        NSString *head = [[NSString alloc] initWithData:[pending subdataWithRange:NSMakeRange(0, end.location)]
                                               encoding:NSISOLatin1StringEncoding];

        NSData *rest = [pending subdataWithRange:NSMakeRange(end.location + 4,
                                                             [pending length] - end.location - 4)];

        NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
        NSArray *status = [[lines objectAtIndex:0] componentsSeparatedByString:@" "];

        if ([status count] < 2 || ![[status objectAtIndex:0] hasPrefix:@"HTTP/"]) {
            NSLog(@"[YouTube/Туннель] Непонятный ответ%@: %@",
                  _reused ? @" (соединение из запаса)" : @"", YTTunnelPreview(pending));

            return [self errorWithCode:NSURLErrorBadServerResponse
                                  text:YTLoc(@"Сервер ответил не по-человечески")];
        }

        NSInteger code = [[status objectAtIndex:1] integerValue];

        if (code >= 100 && code < 200) {
            pending = [NSMutableData dataWithData:rest];
            continue;
        }

        return [self handleStatus:code
                          version:[status objectAtIndex:0]
                            lines:lines
                             rest:rest];
    }
}

/** «content-type» → «Content-Type», как делает NSURLConnection. */
static NSString *YTTunnelCanonicalName(NSString *name) {
    NSArray *parts = [[name lowercaseString] componentsSeparatedByString:@"-"];
    NSMutableArray *fixed = [NSMutableArray arrayWithCapacity:[parts count]];

    for (NSString *part in parts) {
        [fixed addObject:[part length] > 0
            ? [[[part substringToIndex:1] uppercaseString] stringByAppendingString:[part substringFromIndex:1]]
            : part];
    }

    return [fixed componentsJoinedByString:@"-"];
}

- (NSError *)handleStatus:(NSInteger)code
                  version:(NSString *)version
                    lines:(NSArray *)lines
                     rest:(NSData *)rest {
    NSURL *url = [_request URL];

    // Имена — как у NSURLConnection; одноимённые склеиваются через запятую.
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];

    for (NSUInteger i = 1; i < [lines count]; i++) {
        NSString *line = [lines objectAtIndex:i];
        NSRange colon = [line rangeOfString:@":"];

        if (colon.location == NSNotFound || colon.location == 0) {
            continue;
        }

        NSString *name = YTTunnelCanonicalName([[line substringToIndex:colon.location]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]);
        NSString *value = [[line substringFromIndex:colon.location + 1]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        NSString *before = [headers objectForKey:name];

        [headers setObject:(before != nil ? [NSString stringWithFormat:@"%@, %@", before, value] : value)
                    forKey:name];
    }

    // Куки — в общее хранилище, как сделал бы NSURLConnection.
    NSString *setCookie = [headers objectForKey:@"Set-Cookie"];

    if ([setCookie length] > 0 && [_request HTTPShouldHandleCookies]) {
        NSArray *cookies = [NSClassFromString(@"NSHTTPCookie")
            cookiesWithResponseHeaderFields:[NSDictionary dictionaryWithObject:setCookie
                                                                        forKey:@"Set-Cookie"]
                                     forURL:url];

        if ([cookies count] > 0) {
            [[NSClassFromString(@"NSHTTPCookieStorage") sharedHTTPCookieStorage]
                setCookies:cookies forURL:url mainDocumentURL:[_request mainDocumentURL]];
        }
    }

    NSString *transfer = [[headers objectForKey:@"Transfer-Encoding"] lowercaseString];
    NSString *encoding = [[headers objectForKey:@"Content-Encoding"] lowercaseString];

    /**
     * Проверки на nil — не для порядка.
     *
     * Сообщение nil возвращает нулевой NSRange, то есть location 0, а не
     * NSNotFound. Без проверки любой ответ без Transfer-Encoding — картинки,
     * скрипт плеера — считался кусочным, и его тело разбиралось как размеры
     * кусков: «Куски не разобрались», пустые превью, нет видео.
     */
    _chunked = transfer != nil && [transfer rangeOfString:@"chunked"].location != NSNotFound;
    _gzip = [encoding isEqualToString:@"gzip"] || [encoding isEqualToString:@"x-gzip"];

    long long length = -1;

    if (!_chunked && [headers objectForKey:@"Content-Length"] != nil) {
        length = [[headers objectForKey:@"Content-Length"] longLongValue];
    }

    /**
     * Можно ли вернуть соединение в запас, когда тело кончится.
     *
     * У HTTP/1.1 соединение живёт, пока сервер не сказал «close»; у 1.0 —
     * только если сказал «keep-alive».
     */
    NSString *connection = [[headers objectForKey:@"Connection"] lowercaseString];

    BOOL keepAlive = [version isEqualToString:@"HTTP/1.1"]
        ? (connection == nil || [connection rangeOfString:@"close"].location == NSNotFound)
        : (connection != nil && [connection rangeOfString:@"keep-alive"].location != NSNotFound);

    // То, что разобрали сами, клиенту уже не указ.
    [headers removeObjectForKey:@"Transfer-Encoding"];

    if (_gzip) {
        [headers removeObjectForKey:@"Content-Encoding"];
        [headers removeObjectForKey:@"Content-Length"];
    }

    NSHTTPURLResponse *response = [[NSClassFromString(@"NSHTTPURLResponse") alloc]
        initWithURL:url statusCode:code HTTPVersion:version headerFields:headers];

    // --- Перенаправление: клиент заведёт новый запрос, он придёт к нам же.
    NSString *location = [headers objectForKey:@"Location"];

    if ((code == 301 || code == 302 || code == 303 || code == 307 || code == 308) &&
        [location length] > 0) {
        NSURL *target = [NSURL URLWithString:location relativeToURL:url];

        if (target != nil) {
            NSMutableURLRequest *next = [_request mutableCopy];

            [next setURL:[target absoluteURL]];

            // 303 — всегда GET; 301 и 302 после POST — тоже, как у браузеров.
            NSString *method = [[_request HTTPMethod] uppercaseString];

            if (code == 303 || ((code == 301 || code == 302) && [method isEqualToString:@"POST"])) {
                [next setHTTPMethod:@"GET"];
                [next setHTTPBody:nil];
                [next setHTTPBodyStream:nil];
                [next setValue:nil forHTTPHeaderField:@"Content-Type"];
            }

            [self post:@selector(deliverRedirect:)
                  with:[NSArray arrayWithObjects:next, response, nil]];

            return nil;
        }
    }

    [self post:@selector(deliverResponse:) with:response];

    BOOL bodyless = [[[_request HTTPMethod] uppercaseString] isEqualToString:@"HEAD"] ||
                    code == 204 || code == 304 || length == 0;

    if (bodyless) {
        _reusable = keepAlive;
        _finished = YES;
        return nil;
    }

    if (_gzip) {
        memset(&_z, 0, sizeof(_z));

        // 16 + MAX_WBITS: обёртка gzip, а не голый deflate.
        if (inflateInit2(&_z, 16 + MAX_WBITS) != Z_OK) {
            return [self errorWithCode:NSURLErrorCannotDecodeContentData
                                  text:YTLoc(@"Ответ не распаковался")];
        }

        _zReady = YES;
    }

    _chunkState = YTChunkSize;
    _chunkLine = [NSMutableData data];

    long long left = length;

    // Сперва то, что пришло вместе с заголовками.
    NSData *first = rest;
    uint8_t buffer[32768];

    for (;;) {
        const uint8_t *bytes;
        size_t count;

        if (first != nil) {
            bytes = [first bytes];
            count = [first length];
            first = nil;
        } else {
            NSInteger n = [self receive:buffer max:sizeof(buffer)];

            if (_stopped) {
                return nil;
            }

            if (n < 0) {
                return [self lostError];
            }

            if (n == 0) {
                // Конец соединения — конец тела, если длина не обещала большего.
                if (left > 0 || (_chunked && _chunkState != YTChunkDone)) {
                    return [self errorWithCode:NSURLErrorNetworkConnectionLost
                                          text:YTLoc(@"Соединение оборвалось")];
                }

                // Конец отмечен закрытием — соединения больше нет.
                _finished = YES;
                return nil;
            }

            bytes = buffer;
            count = (size_t)n;
        }

        // Лишнее сверх обещанной длины — сервер сбился, соединению веры нет.
        BOOL excess = NO;

        if (left >= 0 && (long long)count > left) {
            count = (size_t)left;
            excess = YES;
        }

        NSError *failure = [self consume:bytes length:count];

        if (failure != nil) {
            return failure;
        }

        if (left >= 0) {
            left -= (long long)count;
        }

        if (left == 0 || (_chunked && _chunkState == YTChunkDone)) {
            _reusable = keepAlive && !excess;
            _finished = YES;
            return nil;
        }
    }
}

/** Кусок сырого тела → разбивка на куски → распаковка → клиенту. */
- (NSError *)consume:(const uint8_t *)bytes length:(size_t)length {
    if (length == 0) {
        return nil;
    }

    NSMutableData *plain = [NSMutableData data];

    if (_chunked) {
        if (![self dechunk:bytes length:length into:plain]) {
            NSLog(@"[YouTube/Туннель] Куски не разобрались: %@",
                  YTTunnelPreview([NSData dataWithBytes:bytes length:length]));

            return [self errorWithCode:NSURLErrorBadServerResponse
                                  text:YTLoc(@"Сервер ответил не по-человечески")];
        }
    } else {
        [plain appendBytes:bytes length:length];
    }

    if ([plain length] == 0) {
        return nil;
    }

    NSData *out = plain;

    if (_gzip) {
        NSMutableData *inflated = [NSMutableData data];

        if (![self inflate:[plain bytes] length:[plain length] into:inflated]) {
            return [self errorWithCode:NSURLErrorCannotDecodeContentData
                                  text:YTLoc(@"Ответ не распаковался")];
        }

        out = inflated;
    }

    if ([out length] > 0) {
        [self post:@selector(deliverData:) with:out];
    }

    return nil;
}

- (BOOL)inflate:(const uint8_t *)bytes length:(size_t)length into:(NSMutableData *)out {
    uint8_t buffer[32768];

    _z.next_in = (Bytef *)bytes;
    _z.avail_in = (uInt)length;

    // Пока выход заполняется целиком — во входе ещё есть что распаковывать.
    do {
        _z.next_out = buffer;
        _z.avail_out = sizeof(buffer);

        int rc = inflate(&_z, Z_NO_FLUSH);

        if (rc == Z_NEED_DICT || rc == Z_DATA_ERROR || rc == Z_MEM_ERROR || rc == Z_STREAM_ERROR) {
            return NO;
        }

        size_t produced = sizeof(buffer) - _z.avail_out;

        if (produced > 0) {
            [out appendBytes:buffer length:produced];
        }

        if (rc == Z_STREAM_END) {
            break;
        }
    } while (_z.avail_out == 0);

    return YES;
}

/**
 * Разбивка на куски (chunked) — по мере прихода, а не целиком.
 *
 * Подача видео течёт одним ответом минутами, и копить его до конца
 * нельзя: плеер ждёт первые куски сразу.
 */
- (BOOL)dechunk:(const uint8_t *)bytes length:(size_t)length into:(NSMutableData *)out {
    size_t i = 0;

    while (i < length && _chunkState != YTChunkDone) {
        if (_chunkState == YTChunkData) {
            size_t take = (size_t)MIN((unsigned long long)(length - i), _chunkLeft);

            [out appendBytes:bytes + i length:take];

            i += take;
            _chunkLeft -= take;

            if (_chunkLeft == 0) {
                _chunkState = YTChunkDataEnd;
            }

            continue;
        }

        // Остальные состояния читают строку до перевода.
        uint8_t c = bytes[i++];

        if (c != '\n') {
            if (c != '\r') {
                [_chunkLine appendBytes:&c length:1];
            }

            if ([_chunkLine length] > 1024) {
                return NO;
            }

            continue;
        }

        NSString *line = [[NSString alloc] initWithData:_chunkLine encoding:NSISOLatin1StringEncoding];

        [_chunkLine setLength:0];

        if (_chunkState == YTChunkSize) {
            // Размер в шестнадцатеричном виде; после «;» — расширения, они не нужны.
            unsigned long long size = strtoull([line UTF8String], NULL, 16);

            if (size == 0) {
                _chunkState = YTChunkTrailer;
            } else {
                _chunkLeft = size;
                _chunkState = YTChunkData;
            }
        } else if (_chunkState == YTChunkDataEnd) {
            _chunkState = YTChunkSize;
        } else if (_chunkState == YTChunkTrailer) {
            if ([line length] == 0) {
                _chunkState = YTChunkDone;
            }
        }
    }

    return YES;
}

@end


#pragma mark - Подкласс NSURLProtocol

static char YTTunnelLoadKey;

static BOOL YTTunnelCanHandle(NSURLRequest *request) {
    // Подключается — тоже берём: запрос дождётся туннеля (waitForTunnel).
    if (![YTWarp isActive] && ![YTWarp isConnecting]) {
        return NO;
    }

    NSURL *url = [request URL];
    NSString *scheme = [[url scheme] lowercaseString];

    if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) {
        return NO;
    }

    return [YTWarp shouldRouteHost:[url host]];
}

@implementation YTTunnelProtocol

+ (void)install {
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        Class base = NSClassFromString(@"NSURLProtocol");

        if (base == Nil) {
            NSLog(@"[YouTube/Туннель] NSURLProtocol не найден — перехвата не будет");
            return;
        }

        Class protocol = objc_allocateClassPair(base, "YTTunnelURLProtocol", 0);

        if (protocol == Nil) {
            return;
        }

        Class meta = object_getClass(protocol);

        // Типы — через @encode: BOOL на armv7 это char, а на arm64 — bool.
        NSString *canInit = [NSString stringWithFormat:@"%s@:@", @encode(BOOL)];

        class_addMethod(meta, @selector(canInitWithRequest:),
            imp_implementationWithBlock(^BOOL(id me, NSURLRequest *request) {
                return YTTunnelCanHandle(request);
            }), [canInit UTF8String]);

        class_addMethod(meta, @selector(canonicalRequestForRequest:),
            imp_implementationWithBlock(^id(id me, NSURLRequest *request) {
                return request;
            }), "@@:@");

        class_addMethod(protocol, @selector(startLoading),
            imp_implementationWithBlock(^(id me) {
                YTTunnelLoad *load = [[YTTunnelLoad alloc] initWithProtocol:me];

                objc_setAssociatedObject(me, &YTTunnelLoadKey, load,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);

                [load start];
            }), "v@:");

        class_addMethod(protocol, @selector(stopLoading),
            imp_implementationWithBlock(^(id me) {
                YTTunnelLoad *load = objc_getAssociatedObject(me, &YTTunnelLoadKey);

                [load stop];

                objc_setAssociatedObject(me, &YTTunnelLoadKey, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }), "v@:");

        objc_registerClassPair(protocol);

        [base registerClass:protocol];

        NSLog(@"[YouTube/Туннель] Перехватчик запросов зарегистрирован");
    });
}

@end
