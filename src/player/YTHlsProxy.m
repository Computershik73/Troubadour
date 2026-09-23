#import "YTHlsProxy.h"

#import "YTApi.h"

#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

#import "YTHttp.h"
#import "YTMp4.h"
#import "YTSabr.h"
#import "YTStreams.h"
#import "YTTsMuxer.h"

/** Один сэмпл, готовый к укладке в TS. */
/** Шкала дорожки нужна, чтобы двигать время эфира на свою ось. */
@interface YTPendingSample : NSObject

@property (nonatomic, strong) NSData *data;
@property (nonatomic, assign) uint64_t pts;
@property (nonatomic, assign) uint64_t dts;
@property (nonatomic, assign) BOOL isVideo;
@property (nonatomic, assign) BOOL keyframe;

/** Время в секундах — по нему сэмплы обеих дорожек сливаются в один ряд. */
@property (nonatomic, assign) double seconds;

/** Тиков в секунде у этой дорожки: без неё время не подвинуть. */
@property (nonatomic, assign) uint32_t scale;

@end

@implementation YTPendingSample
@end


/** Сегмент плейлиста: какие фрагменты дорожек в него входят. */
@interface YTSegmentPlan : NSObject

@property (nonatomic, assign) double start;
@property (nonatomic, assign) double duration;
@property (nonatomic, assign) BOOL isLast;
@property (nonatomic, strong) YTSidxEntry *videoFragment;
@property (nonatomic, strong) NSArray *audioFragments;

@end

@implementation YTSegmentPlan
@end


@implementation YTHlsProxy {
    int _socket;
    uint16_t _port;
    NSThread *_thread;

    YTFormat *_video;
    YTFormat *_audio;

    /** Откуда брать свежие ссылки и когда их брали в прошлый раз. */
    NSDictionary *(^_urlRefresher)(void);
    NSTimeInterval _refreshedAt;

    /** Адреса до обновления — по ним узнаётся дорожка отказавшего куска. */
    NSString *_staleVideoUrl;
    NSString *_staleAudioUrl;

    YTTrackInit *_videoInit;
    YTTrackInit *_audioInit;

    NSArray *_segments;
    NSString *_playlist;
    NSTimeInterval _duration;

    /**
     * Метка текущего воспроизведения.
     *
     * Входит в адреса и проверяется при выдаче: прежний плеер, отпущенный
     * не мгновенно, продолжает просить сегменты, и без метки он получал бы
     * куски уже другого ролика.
     */
    NSUInteger _session;

    /** Адрес склеенного потока, если играем его через передатчик. */
    NSString *_relay;

    /** Объясняли ли уже отказ 403 — второй раз незачем. */
    BOOL _explained;

    /** Отказ случился из-за сменившегося выхода в сеть. */
    BOOL _refusedByAddress;

    /** Подача, если играем через неё. */
    YTSabr *_sabr;

    /** Разобранные заголовки дорожек подачи. */
    YTTrackInit *_sabrVideoInit;
    YTTrackInit *_sabrAudioInit;

    /**
     * Чьи SPS/PPS сейчас в `_sabrVideoInit`.
     *
     * Сервер понижает качество на ходу, когда сеть не тянет, и шлёт
     * новый заголовок. Прежде разобранный заголовок брался один раз и
     * держался до конца, и кадры новой дорожки склеивались со старым
     * описанием: на переходе 1080p→720p геометрия расходилась сильнее
     * всего, и картинка сыпалась до ближайшего явного кадра — оттого
     * «лечилось перемоткой». По этому номеру видно, что заголовок пора
     * перечитать.
     */
    NSInteger _sabrVideoInitItag;

    /** Сколько длится один видеофрагмент подачи, секунды. */
    NSTimeInterval _sabrStep;
    NSInteger _sabrCount;

    /**
     * Настоящие границы фрагментов — из карты `sidx`, если она пришла.
     *
     * `_sabrStarts` — начало каждого куска, `_sabrSpans` — его длина,
     * обе по номеру куска. Пока их нет, куски считаются равными
     * по средней длине, и это стоило двух поломок подряд: сперва
     * расхождения номеров, потом повторов и рывков.
     */
    NSArray *_sabrStarts;
    NSArray *_sabrSpans;

    /**
     * Какой дорожкой отдан плееру каждый кусок: номер куска → itag.
     * И дорожка, которая сейчас на экране (0 — ещё не знаем).
     *
     * Под замком класса, не под `_lock`: пишется из сборки куска, а та
     * держит замок подачи — взять там `_lock` значило бы рисковать
     * встречной блокировкой.
     */
    NSMutableDictionary *_shownItags;
    NSInteger _shownItag;

    /** Разобранные заголовки дорожек: itag → YTTrackInit. */
    NSMutableDictionary *_sabrInits;

    /** Полная длина склеенного потока, как её объявила раздача. */
    long long _relayTotal;

    /** Длительность склеенного потока, если её сказал сервер. */
    NSTimeInterval _relayDuration;

    /**
     * Номер последней передачи склеенного потока.
     *
     * Перемотка не закрывает прежнее соединение вежливо — плеер просто
     * бросает его и открывает новое. Брошенная передача при этом
     * продолжает тянуть куски с раздачи, и несколько перемоток подряд
     * оставляют несколько таких потоков, делящих канал. Снаружи это
     * выглядит зависанием: нужный кусок идёт последним в очереди.
     *
     * Поэтому у каждой передачи свой номер, и та, чей номер устарел,
     * прекращает работу на ближайшем витке.
     */
    NSUInteger _relayTicket;

    /** Последний собранный сегмент — см. выдачу сегмента. */
    NSData *_lastSegment;
    NSInteger _lastSegmentIndex;

    NSObject *_lock;

    /** Показываем ли идущую трансляцию: у неё плейлист живой. */
    BOOL _sabrLive;


    /** Своя ось времени эфира: номер куска — его начало на ней. */
    NSMutableDictionary *_liveTimeline;

    /** Куда доросла эта ось, с. */
    NSTimeInterval _liveClock;

    /** Готовые строки списка эфира: он только растёт. */
    NSMutableArray *_liveLines;

    /** Первый и последний кусок, попавшие в список. */
    NSInteger _liveFirst;
    NSInteger _liveLast;

    /** Самый длинный кусок списка — для `TARGETDURATION`. */
    NSTimeInterval _liveLongest;

    /** Последний кусок эфира, который забрал плеер. */
    NSInteger _liveServed;

    /** Принёс ли последний запрос качалки хоть что-нибудь. */
    BOOL _liveGot;

    /** Когда эфир последний раз приносил кусок. */
    NSTimeInterval _liveFedAt;

    /** Трансляция завершена — список закрыт, качалка уходит. */
    BOOL _liveEnded;

    /** Пустых ответов подряд. */
    NSInteger _liveEmpties;

    /** Когда последний раз перезапускали подачу у края. */
    NSTimeInterval _liveRestartAt;

    /** С какого мгновения ждём сплошной ряд, чтобы начать список. */
    NSTimeInterval _liveStartWaitAt;

    /** Дыра в списке: с какого мгновения ждём опоздавший кусок и после какого. */
    NSTimeInterval _liveGapAt;
    NSInteger _liveGapAfter;

    /** Докуда набрано за всё время показа: только вперёд, через все подмены. */
    NSTimeInterval _liveFilledEver;

    /** Окно замера хода: стенные часы и время показа на его начало. */
    NSTimeInterval _liveRateWall;
    NSTimeInterval _liveRateMedia;

    /** Сколько замеров кряду набранное отстаёт от края и не нагоняет. */
    NSInteger _liveLagRuns;

    /** Предыдущий замер: когда он был и докуда было набрано. */
    NSTimeInterval _liveLagAt;
    NSTimeInterval _liveLagFilled;


}

+ (YTHlsProxy *)shared {
    static YTHlsProxy *shared = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{ shared = [[YTHlsProxy alloc] init]; });

    return shared;
}

- (id)init {
    self = [super init];

    if (self != nil) {
        _socket = -1;
        _lock = [[NSObject alloc] init];
    }

    return self;
}

#pragma mark Сервер

- (BOOL)ensureListening {
    /**
     * Весь подъём — под замком, от проверки до запуска приёмного круга.
     *
     * Звали это место с разных потоков: подача, петля склеенного потока,
     * обычный путь по диапазонам. Проверка «сокет жив?» и создание нового
     * шли врозь, и два потока успевали пройти проверку оба. Дальше каждый
     * создавал свой сокет, а переменная доставалась одному — второй так
     * и оставался висеть ничей. Хуже: сосед, зайдя следом, закрывал
     * по этой переменной уже **чужой**, только что созданный описатель.
     *
     * Наружу это выходило именно тем, что мы ловили: порт вроде поднят,
     * а `accept` на нём отвечает «Bad file descriptor», и ролик
     * не открывается, пока порт не подняли заново.
     *
     * Случалось это на переходах — смене ролика, смене качества,
     * пролистывании Shorts, — то есть ровно там, где два открытия
     * накладываются друг на друга.
     */
    @synchronized (_lock) {
        return [self openPort];
    }
}

- (BOOL)reviveListenerKeepingPort {
    @synchronized (_lock) {
        if (_socket >= 0 && [self stillListening]) {
            return YES;
        }

        uint16_t was = _port;

        if (![self openPort]) {
            return NO;
        }

        BOOL same = (_port == was);

        NSLog(@"[YouTube/Прокси] Слушатель поднят после сна, порт %@",
              same ? @"прежний — играем дальше"
                   : @"новый — придётся пересобрать");

        return same;
    }
}

- (BOOL)openPort {
    if (_socket >= 0 && [self stillListening]) {
        return YES;
    }

    /**
     * Сокет был, да весь вышел.
     *
     * Номер описателя остаётся в переменной, даже если сам описатель
     * закрылся или кончились свободные, — и тогда мы отдаём плееру адрес,
     * по которому никто не слушает. Со стороны это выглядит как «не
     * удалось подключиться к серверу»: ролик не открывается вовсе,
     * хотя подача уже набрана и лежит наготове.
     */
    /**
     * Номер прежнего порта запоминаем — попробуем занять его же.
     *
     * В плейлисте, который держит плеер, адреса кусков записаны вместе
     * с номером порта. Подняв слушателя на другом номере, мы получаем
     * живой прокси, к которому никто не придёт: плеер продолжит стучаться
     * по-старому и не дождётся. Так и выглядит возврат с заблокированного
     * экрана — «Соединение не принято», а дальше тишина.
     */
    uint16_t previous = 0;

    if (_socket >= 0) {
        NSLog(@"[YouTube/Прокси] Порт %u больше не слушает — поднимаем заново", _port);

        previous = _port;

        close(_socket);

        _socket = -1;
        _port = 0;
    }

    _socket = socket(AF_INET, SOCK_STREAM, 0);

    if (_socket < 0) {
        NSLog(@"[YouTube/Прокси] Сокет не создан");
        return NO;
    }

    int yes = 1;

    setsockopt(_socket, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in address;

    memset(&address, 0, sizeof(address));

    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    /**
     * Первый раз номер выбирает система: фиксированный рано или поздно
     * окажется занят, а нам всё равно, какой именно — адрес мы отдаём
     * плееру сами. А вот **второй** раз просим прежний: по нему к нам
     * придёт плеер, переживший сон приложения.
     */
    address.sin_port = htons(previous);

    BOOL bound = (bind(_socket, (struct sockaddr *)&address, sizeof(address)) == 0);

    /**
     * Прежний номер мог не отдаться: система держит его ещё немного
     * после закрытия. Тогда берём любой — воспроизведение всё равно
     * придётся пересобрать, и новый плейлист будет уже с новым номером.
     */
    if (!bound && previous != 0) {
        NSLog(@"[YouTube/Прокси] Прежний порт %u не отдали — берём любой", previous);

        address.sin_port = 0;

        bound = (bind(_socket, (struct sockaddr *)&address, sizeof(address)) == 0);
    }

    if (!bound || listen(_socket, 8) < 0) {
        NSLog(@"[YouTube/Прокси] Не удалось занять порт");

        close(_socket);
        _socket = -1;

        return NO;
    }

    socklen_t size = sizeof(address);

    if (getsockname(_socket, (struct sockaddr *)&address, &size) == 0) {
        _port = ntohs(address.sin_port);
    }

    NSLog(@"[YouTube/Прокси] Слушаем 127.0.0.1:%u", _port);

    /**
     * Приёмный круг получает свой описатель значением, а не через
     * переменную. Иначе прежний круг, проснувшись после закрытия своего
     * сокета, продолжил бы принимать на новом — и их стало бы два.
     */
    _thread = [[NSThread alloc] initWithTarget:self
                                      selector:@selector(acceptLoop:)
                                        object:[NSNumber numberWithInt:_socket]];

    [_thread setName:@"ru.computershik.troubadour.proxy"];
    [_thread start];

    return YES;
}

/** Жив ли слушающий сокет: закрытый описатель отвечает ошибкой. */
- (BOOL)stillListening {
    int listening = 0;
    socklen_t size = sizeof(listening);

    if (getsockopt(_socket, SOL_SOCKET, SO_ACCEPTCONN, &listening, &size) != 0) {
        return NO;
    }

    return listening != 0;
}

- (void)acceptLoop:(NSNumber *)handle {
    int listener = [handle intValue];

    while (YES) {
        @autoreleasepool {
            int client = accept(listener, NULL, NULL);

            if (client < 0) {
                /**
                 * Порт сменили — этому кругу здесь больше нечего делать.
                 * Новый уже поднят вместе с новым сокетом.
                 */
                if (_socket != listener) {
                    return;
                }

                if (_socket < 0) {
                    return;
                }

                /**
                 * Передышка после отказа — и она здесь не вежливость.
                 *
                 * Голое `continue` превращает любую устойчивую ошибку
                 * в бесконечный холостой круг: описатели кончились —
                 * `accept` отвечает отказом сразу же, круг повторяется
                 * миллионы раз в секунду, процессор занят целиком.
                 * Со стороны это видно как разом подешевевшее
                 * воспроизведение: сборка сегмента вместо секунды
                 * занимает шесть.
                 *
                 * Заодно жалуемся в журнал — но не чаще раза в секунду,
                 * иначе журнал сам станет причиной беды.
                 */
                int failure = errno;

                if (failure != EINTR && failure != ECONNABORTED) {
                    NSLog(@"[YouTube/Прокси] Соединение не принято: %s", strerror(failure));
                }

                // Свой же описатель закрыт — круг отработал, уходим.
                if (failure == EBADF) {
                    return;
                }

                usleep(200 * 1000);

                continue;
            }

            /**
             * Запись в закрытый с той стороны сокет по умолчанию убивает
             * процесс сигналом SIGPIPE. Плеер отпускается при смене
             * качества и при уходе с экрана — ровно тогда, когда мы ему
             * дописываем сегмент. Сигнал заглушён на всё приложение
             * в YTAppDelegate, здесь — то же самое на каждом соединении.
             */
            int yes = 1;

            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));

            /**
             * Сроки на чтение и запись.
             *
             * Без них зависшая запись — плеер набрал буфер и перестал
             * читать — держала бы этот поток намертво. Обслуживание идёт
             * на своих потоках, но повиснуть насовсем всё равно нельзя.
             */
            struct timeval timeout;

            timeout.tv_sec = 20;
            timeout.tv_usec = 0;

            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

            // Каждое соединение обслуживается отдельно: пока собирается
            // один сегмент, плеер уже просит следующий.
            [NSThread detachNewThreadSelector:@selector(serveClient:)
                                     toTarget:self
                                   withObject:[NSNumber numberWithInt:client]];
        }
    }
}

- (void)serveClient:(NSNumber *)handle {
    @autoreleasepool {
        int client = [handle intValue];

        /**
         * Сторож на случай, если описатель всё же закроют дважды.
         *
         * Закрытый номер система выдаёт заново, и второе закрытие
         * попадает уже по чужому — в худшем случае по слушающему сокету.
         * Своими силами такое не отличить от исправной работы, поэтому
         * если номера вдруг совпали, лучше громко сказать об этом
         * в журнал, чем молча уронить приём соединений.
         */
        if (client == _socket) {
            NSLog(@"[YouTube/Прокси] Описатель %d — он же слушающий; "
                  @"соединение не обслуживаем", client);

            return;
        }

        char buffer[2048];

        ssize_t read = recv(client, buffer, sizeof(buffer) - 1, 0);

        if (read <= 0) {
            close(client);
            return;
        }

        buffer[read] = '\0';

        NSString *request = [NSString stringWithUTF8String:buffer];
        NSString *path = [self pathFromRequest:request];

        if (path == nil) {
            [self send:client status:@"400 Bad Request" type:@"text/plain" body:nil];
            close(client);
            return;
        }

        [self handlePath:path client:client request:request];

        close(client);
    }
}

- (NSString *)pathFromRequest:(NSString *)request {
    if ([request length] == 0) {
        return nil;
    }

    NSArray *parts = [request componentsSeparatedByString:@" "];

    if ([parts count] < 2) {
        return nil;
    }

    return [parts objectAtIndex:1];
}

- (void)send:(int)client status:(NSString *)status type:(NSString *)type body:(NSData *)body {
    [self send:client status:status type:type body:body
        ranged:NO start:0 total:(long long)[body length]];
}

- (void)send:(int)client
      status:(NSString *)status
        type:(NSString *)type
        body:(NSData *)body
      ranged:(BOOL)ranged
       start:(long long)start
       total:(long long)total {
    NSMutableString *extra = [NSMutableString string];

    // О поддержке диапазонов говорим всегда: без этого заголовка плеер
    // и не подумает их просить, а с ним перемотка не тянет сегмент заново.
    [extra appendString:@"Accept-Ranges: bytes\r\n"];

    if (ranged) {
        [extra appendFormat:@"Content-Range: bytes %lld-%lld/%lld\r\n",
            start, start + (long long)[body length] - 1, total];
    }

    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 %@\r\n"
        @"Content-Type: %@\r\n"
        @"Content-Length: %lu\r\n"
        @"%@"
        @"Connection: close\r\n"
        @"\r\n",
        status, type, (unsigned long)[body length], extra];

    NSData *headData = [head dataUsingEncoding:NSUTF8StringEncoding];

    if (![self writeAll:client data:headData]) {
        return;
    }

    if ([body length] > 0) {
        [self writeAll:client data:body];
    }
}

- (BOOL)writeAll:(int)client data:(NSData *)data {
    const uint8_t *bytes = [data bytes];
    NSUInteger remaining = [data length];

    while (remaining > 0) {
        ssize_t written = send(client, bytes, remaining, 0);

        if (written <= 0) {
            // Получатель отвалился — это обычное дело при смене качества
            // и уходе с экрана, шуметь в журнале незачем.
            return NO;
        }

        bytes += written;
        remaining -= (NSUInteger)written;
    }

    return YES;
}

#pragma mark Разбор запроса

/**
 * Разбирает `Range: bytes=start-end`.
 *
 * Отвечать на такой запрос кодом 200 и всем телом нельзя: плеер просил
 * кусок, получил целое, и дальше его учёт байтов расходится с нашим.
 * Именно так это и выглядело снаружи — первая перемотка ещё проходит,
 * а потом плеер встаёт и не отмирает, пока его не пересоздать.
 */
- (BOOL)parseRange:(NSString *)request start:(long long *)start end:(long long *)end {
    NSRange marker = [request rangeOfString:@"Range: bytes="
                                    options:NSCaseInsensitiveSearch];

    if (marker.location == NSNotFound) {
        return NO;
    }

    NSString *tail = [request substringFromIndex:marker.location + marker.length];
    NSRange line = [tail rangeOfString:@"\r\n"];

    if (line.location != NSNotFound) {
        tail = [tail substringToIndex:line.location];
    }

    NSArray *parts = [tail componentsSeparatedByString:@"-"];

    if ([parts count] == 0) {
        return NO;
    }

    *start = [[parts objectAtIndex:0] longLongValue];

    // Верхняя граница необязательна: «bytes=1234-» значит «до конца».
    *end = ([parts count] > 1 && [[parts objectAtIndex:1] length] > 0)
        ? [[parts objectAtIndex:1] longLongValue]
        : -1;

    return YES;
}

/** Отдаёт готовый сегмент целиком либо запрошенным куском. */
- (void)sendSegment:(NSData *)segment client:(int)client request:(NSString *)request {
    long long start = 0;
    long long end = -1;

    if (![self parseRange:request start:&start end:&end]) {
        [self send:client
            status:@"200 OK"
              type:@"video/mp2t"
              body:segment
            ranged:NO
             start:0
             total:[segment length]];
        return;
    }

    long long total = (long long)[segment length];

    if (start < 0 || start >= total) {
        [self send:client status:@"416 Requested Range Not Satisfiable"
              type:@"text/plain" body:nil ranged:NO start:0 total:total];
        return;
    }

    if (end < 0 || end >= total) {
        end = total - 1;
    }

    NSData *slice = [segment subdataWithRange:
        NSMakeRange((NSUInteger)start, (NSUInteger)(end - start + 1))];

    [self send:client
        status:@"206 Partial Content"
          type:@"video/mp2t"
          body:slice
        ranged:YES
         start:start
         total:total];
}

- (void)handlePath:(NSString *)path client:(int)client request:(NSString *)request {
    NSArray *parts = [path componentsSeparatedByString:@"/"];

    // Ожидаем «/<сессия>/p.m3u8» либо «/<сессия>/s/<номер>.ts».
    if ([parts count] < 3) {
        [self send:client status:@"404 Not Found" type:@"text/plain" body:nil];
        return;
    }

    NSUInteger session = (NSUInteger)[[parts objectAtIndex:1] integerValue];

    NSString *playlist = nil;
    NSArray *segments = nil;

    /**
     * Всё состояние потока забирается **разом, под замком**, и дальше
     * работа идёт по этому снимку. Читать поля объекта по ходу сборки
     * нельзя: смена качества или переход к другому ролику заменяют их
     * в любой момент, а сборка идёт на своём потоке.
     */
    YTFormat *video = nil;
    YTFormat *audio = nil;
    YTTrackInit *videoInit = nil;
    YTTrackInit *audioInit = nil;

    @synchronized (_lock) {
        if (session != _session) {
            // Просит прежний плеер — отвечаем отказом, но не ошибкой:
            // он всё равно вот-вот будет отпущен.
            [self send:client status:@"410 Gone" type:@"text/plain" body:nil];
            return;
        }

        playlist = _playlist;
        segments = _segments;

        video = _video;
        audio = _audio;
        videoInit = _videoInit;
        audioInit = _audioInit;
    }

    NSString *tail = [parts objectAtIndex:2];

    if ([tail isEqualToString:@"r.mp4"]) {
        [self relay:client request:request];
        return;
    }

    if ([tail isEqualToString:@"p.m3u8"]) {
        NSLog(@"[YouTube/Прокси] Запрошен плейлист");

        /**
         * У эфира плейлист живёт ровно до следующего запроса.
         *
         * Плеер перечитывает его сам, и каждый раз должен видеть новые
         * куски: старый список для трансляции — это остановка показа
         * через полминуты.
         */
        if (_sabrLive && _sabr != nil) {
            NSString *fresh = [self livePlaylistFor:_sabr];

            if ([fresh length] > 0) {
                playlist = fresh;

                @synchronized (_lock) {
                    _playlist = fresh;
                }
            }
        }

        [self send:client
            status:@"200 OK"
              type:@"application/vnd.apple.mpegurl"
              body:[playlist dataUsingEncoding:NSUTF8StringEncoding]];
        return;
    }

    if ([parts count] >= 4 && [tail isEqualToString:@"s"]) {
        NSInteger index = [[[parts objectAtIndex:3] stringByDeletingPathExtension] integerValue];

        /**
         * У подачи списка кусков нет — она отдаёт их по номеру, — так что
         * проверяем границы только там, где список есть.
         */
        if (index < 0 || (_sabr == nil && index >= (NSInteger)[segments count])) {
            [self send:client status:@"404 Not Found" type:@"text/plain" body:nil];
            return;
        }

        NSTimeInterval started = CFAbsoluteTimeGetCurrent();

        NSData *segment = nil;
        BOOL cached = NO;

        /**
         * Последний собранный сегмент держим наготове.
         *
         * После перемотки плеер нередко просит один и тот же сегмент
         * дважды — сперва небольшим диапазоном, чтобы заглянуть в начало,
         * потом целиком. Без этого каждый такой заход заново качает
         * мегабайты по сети и заново их перекладывает.
         */
        @synchronized (_lock) {
            if (_lastSegment != nil && _lastSegmentIndex == index) {
                segment = _lastSegment;
                cached = YES;
            }
        }

        if (segment == nil && _sabr != nil) {
            segment = [self buildSabrSegment:index];
        }

        if (segment == nil && [segments count] > 0) {
            segment = [self buildSegment:[segments objectAtIndex:index]
                                   index:index
                                   video:video
                                   audio:audio
                               videoInit:videoInit
                               audioInit:audioInit];

            if (segment != nil) {
                @synchronized (_lock) {
                    _lastSegment = segment;
                    _lastSegmentIndex = index;
                }
            }
        }

        if (segment == nil) {
            [self send:client status:@"500 Internal Server Error" type:@"text/plain" body:nil];
            return;
        }

        NSLog(@"[YouTube/Прокси] Сегмент %ld: %lu КБ за %ld мс%@",
              (long)index, (unsigned long)([segment length] / 1024),
              (long)((CFAbsoluteTimeGetCurrent() - started) * 1000),
              cached ? @" (из памяти)" : @"");

        // Отметка для качалки: докуда плеер дошёл на самом деле.
        @synchronized (_lock) {
            if (_sabrLive && index + 1 > _liveServed) {
                _liveServed = index + 1;
            }
        }

        [self sendSegment:segment client:client request:request];
        return;
    }

    [self send:client status:@"404 Not Found" type:@"text/plain" body:nil];
}

/**
 * Отдаёт кусок склеенного потока, спросив его у раздачи.
 *
 * Плеер, узнав полную длину, просит сразу весь остаток — в живом прогоне
 * это был один запрос на 11.4 МБ. Отдать ему меньше запрошенного нельзя:
 * три коротких ответа подряд, и он объявляет поток негодным. Поэтому
 * **обещаем всё, что просили**, а из сети тянем по куску и сразу пишем
 * в сокет — в памяти в каждый миг лежит мегабайт, а не одиннадцать.
 */
- (void)relay:(int)client request:(NSString *)request {
    NSString *remote = nil;

    @synchronized (_lock) {
        remote = _relay;
    }

    NSUInteger mine = 0;

    @synchronized (_lock) {
        if ([_relay length] == 0) {
            remote = nil;
        }

        _relayTicket++;
        mine = _relayTicket;
    }

    if ([remote length] == 0) {
        [self send:client status:@"404 Not Found" type:@"text/plain" body:nil];
        return;
    }

    long long start = 0;
    long long end = -1;

    [self parseRange:request start:&start end:&end];

    if (start < 0) {
        start = 0;
    }

    // Шаг чтения из сети; подобран под память iPhone 4.
    const long long step = 1024 * 1024;

    /**
     * Первый кусок берём сразу: из его `Content-Range` узнаётся полная
     * длина, без которой нечего писать в заголовок ответа.
     */
    NSData *first = [self relayFetch:remote from:start to:start + step - 1];

    if (![self relayIsCurrent:mine]) {
        return;
    }

    if ([first length] == 0) {
        [self send:client status:@"502 Bad Gateway" type:@"text/plain" body:nil];
        return;
    }

    long long total = _relayTotal;

    if (total <= 0) {
        total = start + (long long)[first length];
    }

    if (end < start || end >= total) {
        end = total - 1;
    }

    long long length = end - start + 1;

    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 206 Partial Content\r\n"
        @"Content-Type: video/mp4\r\n"
        @"Content-Length: %lld\r\n"
        @"Content-Range: bytes %lld-%lld/%lld\r\n"
        @"Accept-Ranges: bytes\r\n"
        @"Connection: close\r\n"
        @"\r\n",
        length, start, end, total];

    if (![self writeAll:client data:[head dataUsingEncoding:NSUTF8StringEncoding]]) {
        return;
    }

    /**
     * Насколько мы вправе убежать вперёд — в байтах на секунду.
     *
     * AVFoundation, получив обычный mp4, качает его целиком и как можно
     * быстрее: в живом прогоне это 178 запросов подряд, по мегабайту
     * каждые полторы секунды, до самого конца ролика. Смотрят при этом
     * первую минуту. После перемотки всё начинается заново с нового
     * места, а прежняя закачка успела съесть канал.
     *
     * Поэтому идём не быстрее, чем нужно: держим запас в минуту видео
     * сверх того, что уже проиграно по времени. Плееру мы по-прежнему
     * обещаем весь запрошенный кусок — просто отдаём его не рывком.
     * Длительности не знаем — не придерживаем вовсе.
     */
    double bytesPerSecond = (_relayDuration > 0 && total > 0)
        ? (double)total / _relayDuration
        : 0;

    const NSTimeInterval lead = 60.0;

    NSTimeInterval began = CFAbsoluteTimeGetCurrent();

    long long at = start;
    NSData *piece = first;

    first = nil;

    while (at <= end) {
        /**
         * Своя корзина на каждый кусок — иначе часовой ролик убьёт
         * приложение.
         *
         * Внутри витка рождаются временные объекты: ответ сети, его тело,
         * заголовки. Без своей корзины они копятся до конца метода,
         * а метод здесь живёт всё воспроизведение. На ролике в полгигабайта
         * это пятьсот мегабайт, которые никто не отпускает, — и система
         * снимает приложение за расход памяти.
         */
        @autoreleasepool {
            if (![self relayIsCurrent:mine]) {
                return;
            }

            /**
             * Придержка. Ждём короткими шагами, а не одним сном: за это
             * время плеер может перемотать, и тогда ждать уже нечего.
             */
            while (bytesPerSecond > 0) {
                NSTimeInterval sent = (double)(at - start) / bytesPerSecond;
                NSTimeInterval spent = CFAbsoluteTimeGetCurrent() - began;

                if (sent <= spent + lead) {
                    break;
                }

                usleep(200 * 1000);

                if (![self relayIsCurrent:mine]) {
                    return;
                }
            }

            if (piece == nil) {
                piece = [self relayFetch:remote from:at to:MIN(at + step - 1, end)];

                if ([piece length] == 0) {
                    // Дописать нечем: плеер увидит обрыв и попросит заново.
                    return;
                }
            }

            // Последний кусок может прийти длиннее, чем осталось обещанного.
            if (at + (long long)[piece length] - 1 > end) {
                piece = [piece subdataWithRange:NSMakeRange(0, (NSUInteger)(end - at + 1))];
            }

            if (![self writeAll:client data:piece]) {
                return;
            }

            at += (long long)[piece length];
            piece = nil;
        }
    }
}

/**
 * Кусок склеенного потока из сети; попутно запоминает полную длину
 * ресурса, объявленную в `Content-Range`.
 */
/**
 * Не сменил ли плеер соединение и не закрыт ли поток вовсе, пока мы
 * тянули кусок.
 */
- (BOOL)relayIsCurrent:(NSUInteger)ticket {
    @synchronized (_lock) {
        return (ticket == _relayTicket && [_relay length] > 0);
    }
}

- (NSData *)relayFetch:(NSString *)remote from:(long long)from to:(long long)to {
    NSMutableURLRequest *outgoing =
        YTRequest(remote, NSURLRequestReloadIgnoringLocalCacheData, 30.0);

    if (outgoing == nil) {
        return nil;
    }

    [outgoing setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", from, to]
    forHTTPHeaderField:@"Range"];

    [outgoing setValue:[YTApi mediaUserAgent] forHTTPHeaderField:@"User-Agent"];
    [outgoing setHTTPShouldHandleCookies:NO];

    YTHttpResponse *response = [YTHttp send:outgoing bodyLimit:0 caching:NO];

    if (![response isSuccessful] || [response.body length] == 0) {
        NSLog(@"[YouTube/Прокси] Склеенный поток %lld-%lld не забрался: код %ld%@",
              from, to, (long)response.statusCode, [YTStreams signatureNote:remote]);

        [self explainRefusal:response.statusCode url:remote];

        return nil;
    }

    long long total = [self totalFromContentRange:response];

    if (total > 0) {
        _relayTotal = total;
    }

    return response.body;
}

/** Полная длина ресурса из заголовка `Content-Range: bytes a-b/total`. */
- (long long)totalFromContentRange:(YTHttpResponse *)response {
    NSString *value = nil;

    // Регистр заголовка сервер выбирает сам, поэтому ищем без оглядки
    // на него, а не по точному ключу.
    for (NSString *key in response.headers) {
        if ([key caseInsensitiveCompare:@"Content-Range"] == NSOrderedSame) {
            value = [response.headers objectForKey:key];
            break;
        }
    }

    NSRange slash = [value rangeOfString:@"/" options:NSBackwardsSearch];

    if (slash.location == NSNotFound) {
        return 0;
    }

    return [[value substringFromIndex:slash.location + 1] longLongValue];
}

- (NSString *)relayUrl:(NSString *)remote duration:(NSTimeInterval)duration {
    [self close];

    if ([remote length] == 0) {
        return nil;
    }

    if (![self ensureListening]) {
        return nil;
    }

    @synchronized (_lock) {
        _relay = [remote copy];
        _relayDuration = duration;
        _session++;
    }

    NSLog(@"[YouTube/Прокси] Передатчик склеенного потока поднят");

    return [NSString stringWithFormat:@"http://127.0.0.1:%u/%lu/r.mp4",
            _port, (unsigned long)_session];
}

#pragma mark Скачивание кусков

/** Кусок дорожки по диапазону байт. */
- (NSData *)fetch:(NSString *)url from:(uint64_t)from to:(uint64_t)to {
    NSMutableURLRequest *request =
        YTRequest(url, NSURLRequestReloadIgnoringLocalCacheData, 30.0);

    if (request == nil) {
        return nil;
    }

    [request setValue:[NSString stringWithFormat:@"bytes=%llu-%llu", from, to]
   forHTTPHeaderField:@"Range"];

    /**
     * За кусками идём тем же именем, каким получили ссылку.
     *
     * Ссылка подписана под клиента — `c=ANDROID_VR` записан прямо в ней, —
     * и CDN сверяет, тем ли клиентом за ней пришли. Без своего имени
     * запрос уходил с тем, что подставляет система
     * (`YouTube/1.0 CFNetwork/672.1.15 Darwin/14.0.0`), и на первом же
     * перенаправлении дело кончалось отказом 403.
     */
    [request setValue:[YTApi mediaUserAgent] forHTTPHeaderField:@"User-Agent"];

    /**
     * Куки к кускам не прикладываем. Сеанс Google живёт на youtube.com,
     * а куски лежат на googlevideo.com — чужом для него домене; посылать
     * туда что-либо от аккаунта незачем, а лишний заголовок на запросе,
     * подписанном для другого клиента, — повод для отказа.
     */
    [request setHTTPShouldHandleCookies:NO];

    /**
     * Кеширование выключено: куски видео весят мегабайты, не повторяются
     * и вытесняли бы из дискового кеша превью, ради которых он и заведён.
     */
    YTHttpResponse *response = [YTHttp send:request bodyLimit:0 caching:NO];

    /**
     * Один повтор при обрыве.
     *
     * Связь на телефоне рвётся посреди тела, и тогда заголовки уже
     * пришли (код 206, «часть содержимого»), а байтов не хватает —
     * успехом это не считается. Отказ сервера так лечить бессмысленно,
     * а обрыв лечится ровно повтором; отличаются они кодом, поэтому
     * повторяем только там, где сервер был не против.
     */
    if (![response isSuccessful] && response.statusCode >= 200 &&
        response.statusCode < 400) {
        NSLog(@"[YouTube/Прокси] Кусок %llu-%llu оборвался — повторяем", from, to);

        response = [YTHttp send:request bodyLimit:0 caching:NO];
    }

    if (![response isSuccessful]) {
        NSLog(@"[YouTube/Прокси] Кусок %llu-%llu не забрался: код %ld%@",
              from, to, (long)response.statusCode, [YTStreams signatureNote:url]);

        [self explainRefusal:response.statusCode url:url];

        /**
         * Отказ 403 при том же выходе в сеть лечится новой ссылкой.
         *
         * Так себя ведут готовые адреса: сразу после прыжка в дальнюю
         * часть ролика раздача отказывает в куске, который минуту назад
         * отдала бы без вопросов. Спрашиваем `/player` заново и повторяем
         * ровно один раз — если и свежая ссылка отказала, дело не в ней.
         */
        if (response.statusCode == 403) {
            NSString *fresh = [self refreshedUrlFor:url];

            if ([fresh length] > 0 && ![fresh isEqualToString:url]) {
                NSLog(@"[YouTube/Прокси] Повторяем кусок %llu-%llu по свежей ссылке",
                      from, to);

                return [self fetchOnce:fresh from:from to:to];
            }
        }

        return nil;
    }

    return response.body;
}

/**
 * Тот же запрос, но без второго круга обновления: свежую ссылку пробуем
 * единожды, иначе при затяжном отказе прокси ходил бы по кругу.
 */
- (NSData *)fetchOnce:(NSString *)url from:(uint64_t)from to:(uint64_t)to {
    NSMutableURLRequest *request =
        YTRequest(url, NSURLRequestReloadIgnoringLocalCacheData, 30.0);

    if (request == nil) {
        return nil;
    }

    [request setValue:[NSString stringWithFormat:@"bytes=%llu-%llu", from, to]
   forHTTPHeaderField:@"Range"];

    [request setValue:[YTApi mediaUserAgent] forHTTPHeaderField:@"User-Agent"];
    [request setHTTPShouldHandleCookies:NO];

    YTHttpResponse *response = [YTHttp send:request bodyLimit:0 caching:NO];

    if (![response isSuccessful]) {
        NSLog(@"[YouTube/Прокси] И свежая ссылка отказала: код %ld%@",
              (long)response.statusCode, [YTStreams signatureNote:url]);

        return nil;
    }

    return response.body;
}

- (void)setUrlRefresher:(NSDictionary *(^)(void))refresher {
    @synchronized (_lock) {
        _urlRefresher = [refresher copy];
        _refreshedAt = 0;
    }
}

/**
 * Свежий адрес для той же дорожки; nil, если обновить нечем.
 *
 * Обновление общее на обе дорожки — `/player` отвечает сразу обо всех, —
 * и не чаще раза в десять секунд: сегменты собираются в несколько
 * потоков, и на один отказ пришлась бы стая одинаковых запросов.
 */
- (NSString *)refreshedUrlFor:(NSString *)url {
    NSDictionary *(^refresher)(void) = nil;

    @synchronized (_lock) {
        // Кто-то уже обновил — берём то, что лежит, ничего не спрашивая.
        if (CFAbsoluteTimeGetCurrent() - _refreshedAt < 10.0) {
            return [self freshTwinOf:url];
        }

        refresher = _urlRefresher;
    }

    if (refresher == nil) {
        return nil;
    }

    NSDictionary *fresh = refresher();

    @synchronized (_lock) {
        _refreshedAt = CFAbsoluteTimeGetCurrent();

        NSString *video = [fresh objectForKey:@"video"];
        NSString *audio = [fresh objectForKey:@"audio"];

        /**
         * Прежние адреса запоминаем: по ним потом узнаётся, чей это был
         * кусок. Сравнивать с нынешними поздно — их только что заменили.
         */
        _staleVideoUrl = [_video.url copy];
        _staleAudioUrl = [_audio.url copy];

        if ([video length] > 0) { _video.url = video; }
        if ([audio length] > 0) { _audio.url = audio; }

        NSLog(@"[YouTube/Прокси] Ссылки обновлены: видео %@, звук %@",
              [video length] > 0 ? @"есть" : @"нет",
              [audio length] > 0 ? @"есть" : @"нет");

        return [self freshTwinOf:url];
    }
}

/** Нынешний адрес той дорожки, которой принадлежал отказавший кусок. */
- (NSString *)freshTwinOf:(NSString *)url {
    if ([url length] == 0) {
        return nil;
    }

    if ([url isEqualToString:_staleVideoUrl] ||
        (_video != nil && [url isEqualToString:_video.url])) {

        return _video.url;
    }

    if ([url isEqualToString:_staleAudioUrl] ||
        (_audio != nil && [url isEqualToString:_audio.url])) {

        return _audio.url;
    }

    return nil;
}

/** Кусок по строковым границам из ответа /player. */
- (NSData *)fetch:(NSString *)url rangeStart:(NSString *)start end:(NSString *)end {
    if ([start length] == 0 || [end length] == 0) {
        return nil;
    }

    return [self fetch:url
                  from:(uint64_t)[start longLongValue]
                    to:(uint64_t)[end longLongValue]];
}

/**
 * Объясняет отказ 403, если сумеет.
 *
 * Пустой 403 от раздачи не говорит ничего: так выглядит и просроченная
 * ссылка, и чужой PO-токен, и — чаще всего на устройстве за раздающим
 * пулом адресов — сменившийся выход в сеть. Последнее отличимо: спросим
 * адрес заново и сравним с тем, что записан в ссылке.
 *
 * Делается это один раз за запуск: объяснение нужно человеку, а не
 * плееру, и повторять его на каждом куске незачем.
 */
- (void)explainRefusal:(NSInteger)status url:(NSString *)url {
    if (status != 403) {
        return;
    }

    @synchronized (_lock) {
        if (_explained) {
            return;
        }

        _explained = YES;
    }

    NSRange found = [url rangeOfString:@"&ip="];

    if (found.location == NSNotFound) {
        return;
    }

    NSString *signed_ = [url substringFromIndex:NSMaxRange(found)];
    NSRange stop = [signed_ rangeOfString:@"&"];

    if (stop.location != NSNotFound) {
        signed_ = [signed_ substringToIndex:stop.location];
    }

    NSString *now = [YTApi probeSeenIp];

    if ([now length] == 0) {
        NSLog(@"[YouTube/Прокси] Ссылка подписана на %@; свежий адрес узнать не вышло",
              signed_);
        return;
    }

    if ([now isEqualToString:signed_]) {
        NSLog(@"[YouTube/Прокси] Выход в сеть тот же (%@) — отказ не из-за адреса", now);
    } else {
        NSLog(@"[YouTube/Прокси] Выход в сеть сменился: ссылка подписана на %@, "
              @"а сейчас мы %@ — раздача отказывает именно поэтому", signed_, now);

        @synchronized (_lock) {
            _refusedByAddress = YES;
        }
    }
}

#pragma mark Подготовка

- (NSString *)openWithSabr:(YTSabr *)sabr {
    [self close];

    if (sabr == nil || ![self ensureListening]) {
        return nil;
    }

    YTTrackInit *videoInit = [YTMp4 parseInit:[sabr videoInit]];
    YTTrackInit *audioInit = [YTMp4 parseInit:[sabr audioInit]];

    if (videoInit == nil || ![videoInit isVideo]) {
        NSLog(@"[YouTube/Прокси] Заголовок видеодорожки подачи не разобран");

        return nil;
    }

    if (audioInit == nil) {
        NSLog(@"[YouTube/Прокси] Заголовок звука подачи не разобран — играем без звука");
    }

    if (sabr.liveMode) {
        return [self openLiveWithSabr:sabr
                            videoInit:videoInit
                            audioInit:audioInit];
    }

    NSInteger count = [sabr videoSegmentCount];
    NSTimeInterval total = [sabr duration];

    /**
     * Карта фрагментов — она приходит в заголовке дорожки.
     *
     * Это `sidx`, тот самый бокс, по которому работает обычный путь:
     * у каждого фрагмента там своя длительность. Подача присылает его
     * вместе с `ftyp` и `moov` в начальном сегменте — то есть всё
     * нужное у нас было с самого начала, а мы делили ролик на равные
     * куски по средней длине.
     *
     * Из-за этого плейлист обещал плееру одно, а фрагменты содержали
     * другое: к середине ролика расхождение доходило до полуминуты.
     * Сперва это ломало перемотку (нужный фрагмент «не приходил»),
     * а когда фрагмент стали искать по времени — пошли повторы: один
     * и тот же фрагмент попадал в два куска подряд, и картинку
     * откидывало назад, а звук расходился.
     *
     * С настоящей картой номер куска и номер фрагмента совпадают
     * тождественно, а границы кусков — с границами фрагментов.
     */
    uint32_t indexScale = 0;

    NSArray *map = [YTMp4 parseSidx:[sabr videoInit] firstOffset:0 timescale:&indexScale];

    NSMutableArray *starts = nil;
    NSMutableArray *spans = nil;

    if ([map count] > 0 && indexScale > 0) {
        starts = [NSMutableArray arrayWithCapacity:[map count]];
        spans = [NSMutableArray arrayWithCapacity:[map count]];

        NSTimeInterval at = 0;

        for (YTSidxEntry *entry in map) {
            NSTimeInterval span = (NSTimeInterval)entry.duration / (NSTimeInterval)indexScale;

            if (span <= 0) {
                starts = nil;
                spans = nil;

                break;
            }

            [starts addObject:[NSNumber numberWithDouble:at]];
            [spans addObject:[NSNumber numberWithDouble:span]];

            at += span;
        }

        if ([starts count] > 0) {
            NSLog(@"[YouTube/Прокси] Карта фрагментов из заголовка: %lu кусков, "
                  @"всего %.0f с (подача обещала %ld и %.0f с)",
                  (unsigned long)[starts count], at, (long)count, total);

            count = (NSInteger)[starts count];

            // Длительность ролика тоже берём по карте: она точнее.
            if (at > 0) {
                total = at;
            }
        }
    }

    /**
     * Длина куска — средняя, а не длина первого фрагмента.
     *
     * Первый фрагмент годится только когда сервер режет ровно; у
     * вертикальных роликов он режет как попало — встречаются и три
     * секунды, и почти семь. Взяв три, плейлист обещал плееру 65 × 3 =
     * 195 секунд там, где ролик длится 296: последняя сотня секунд
     * оказывалась за объявленным концом, и хвост либо заикался,
     * либо не игрался вовсе.
     *
     * Среднее в сумме даёт ровно длительность ролика, а расхождение
     * с настоящими границами плееру безразлично: дорожки он сводит
     * по временным меткам внутри кусков, а не по строкам плейлиста.
     */
    NSTimeInterval step = (count > 0 && total > 0)
        ? total / (NSTimeInterval)count
        : [sabr videoSegmentDuration:1];

    if (count <= 0 || step <= 0) {
        NSLog(@"[YouTube/Прокси] Подача не сказала, сколько фрагментов и какой длины");

        return nil;
    }

    NSMutableString *playlist = [NSMutableString string];

    /**
     * Объявленный потолок длины куска — по самому длинному, а не по среднему.
     *
     * Плейлист обязан обещать не меньше, чем в нём есть: со средней длиной
     * 4.35 с и настоящим куском в 7 с обещание оказывалось ложью, а плеер
     * такую верстку вправе и не принять.
     */
    NSTimeInterval longest = step;

    for (NSNumber *span in spans) {
        longest = MAX(longest, [span doubleValue]);
    }

    [playlist appendString:@"#EXTM3U\n#EXT-X-VERSION:3\n"];
    // То же заявление о независимости кусков, что и у второго сборщика.
    [playlist appendString:@"#EXT-X-INDEPENDENT-SEGMENTS\n"];
    [playlist appendFormat:@"#EXT-X-TARGETDURATION:%ld\n", (long)(longest + 0.999)];
    [playlist appendString:@"#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"];

    @synchronized (_lock) {
        _sabr = sabr;
        _sabrVideoInit = videoInit;
        _sabrVideoInitItag = [sabr videoInitItag];
        _sabrAudioInit = audioInit;
        _sabrStep = step;
        _sabrCount = count;
        _sabrStarts = [starts copy];
        _sabrSpans = [spans copy];
        _duration = total;
        _session++;
    }

    for (NSInteger i = 0; i < count; i++) {
        // Длина куска — настоящая, если карта есть; средняя, если нет.
        NSTimeInterval span = ([_sabrSpans count] > (NSUInteger)i)
            ? [[_sabrSpans objectAtIndex:i] doubleValue]
            : step;

        [playlist appendFormat:@"#EXTINF:%.3f,\n/%lu/s/%ld.ts\n",
            span, (unsigned long)_session, (long)i];
    }

    [playlist appendString:@"#EXT-X-ENDLIST\n"];

    @synchronized (_lock) {
        _playlist = playlist;
    }

    NSLog(@"[YouTube/Прокси] Подача готова: %ld кусков по %.1f с, всего %.0f с, "
          @"звук %@", (long)count, step, total, audioInit != nil ? @"есть" : @"НЕТ");

    return [self playbackUrlWithVideo:videoInit audio:audioInit frames:0];
}

/**
 * Начало куска на **нашей** оси времени.
 *
 * Своя ось нужна эфиру по двум причинам, и обе видны в журналах.
 *
 * Первая: время трансляции у сервера отсчитано от начала вещания и
 * измеряется миллионами секунд — 7 190 150-я секунда, то есть три
 * месяца. В MPEG-TS время показа занимает 33 бита при частоте 90 кГц,
 * а это чуть больше суток; всё, что дальше, укладывается туда с
 * переполнением, и однажды непременно перескакивает через край.
 * Плеер на таком месте отматывает показ назад.
 *
 * Вторая: сервер изредка пропускает куски и продолжает со своего
 * нынешнего места. На настоящей оси это дыра, и плеер встаёт, ожидая
 * пропущенного. На нашей же дыры нет вовсе: куски ложатся подряд,
 * один за другим, и пропуск виден лишь как склейка в кадре — так же,
 * как выглядит непрерывный поток на Android, где плеер получает байты
 * подряд и ничего не знает о том, что между ними было.
 *
 * Ось растёт вместе со списком: длины кусков в ней те же, что в
 * `EXTINF`, поэтому часы плеера и наши совпадают.
 */
- (NSTimeInterval)liveStartFor:(NSInteger)sequence span:(NSTimeInterval)span {
    @synchronized (_lock) {
        if (_liveTimeline == nil) {
            _liveTimeline = [NSMutableDictionary dictionary];
            _liveClock = 10.0;
        }

        NSNumber *known = [_liveTimeline objectForKey:
            [NSNumber numberWithInteger:sequence]];

        if (known != nil) {
            return [known doubleValue];
        }

        NSTimeInterval start = _liveClock;

        _liveClock += (span > 0 ? span : 5.0);

        [_liveTimeline setObject:[NSNumber numberWithDouble:start]
                          forKey:[NSNumber numberWithInteger:sequence]];

        return start;
    }
}

/**
 * Плейлист идущей трансляции — список, который только растёт.
 *
 * Это перенос андроидной работы с эфиром на здешние понятия, и стоит
 * объяснить, почему именно так.
 *
 * На Android плеер тянет байты из нашего источника сам: берёт кусок
 * за куском с самого начала набранного и идёт вперёд ровно с той
 * скоростью, с какой смотрит человек. Здесь же плеер ходит за кусками
 * по HTTP, и место, с которого он начнёт, задаёт **вид плейлиста**.
 * Обычный живой список — окно из последних кусков, и по правилам HLS
 * плеер встаёт за три куска до его конца, то есть вплотную к краю.
 * Отсюда и шло всё зло: набранное вначале с запасом мы тут же
 * проигрывали, наш запрос уходил всё дальше от того места, докуда
 * снята трансляция, и на разнице примерно в минуту сервер переставал
 * отвечать вовсе. В журнале это выглядело так: «просим с 7188711 с,
 * край 7188641 с» — и семьдесят секунд тишины, ровно пока край
 * не догонит просьбу.
 *
 * `EXT-X-PLAYLIST-TYPE:EVENT` описывает как раз андроидный случай:
 * список от начала записи, куски из него не пропадают, а плеер
 * начинает с первого и идёт подряд. Тогда показ отстаёт от края ровно
 * на столько, сколько мы успели набрать вперёд, — и это отставание
 * не тает, а работает запасом. Просьба же остаётся у самого хвоста
 * набранного, то есть всегда внутри того, что сервер отдаёт.
 *
 * Раз куски из списка не пропадают, держим не сам список, а готовые
 * строки: подача старые фрагменты из памяти выбрасывает, и спрашивать
 * у неё длину куска, отданного пять минут назад, уже поздно.
 */
- (NSString *)livePlaylistFor:(YTSabr *)sabr {
    NSArray *sequences = [sabr videoSequences];

    NSMutableArray *fresh = [NSMutableArray array];

    for (NSNumber *number in sequences) {
        NSInteger sequence = [number integerValue];

        NSTimeInterval span = [sabr videoSegmentDuration:sequence];

        /**
         * Кусок без длины в список не идёт.
         *
         * У самого свежего длина ещё неизвестна: её вычисляют
         * по расстоянию до следующего, а следующего пока нет.
         */
        if (span > 0) {
            [fresh addObject:[NSArray arrayWithObjects:
                number, [NSNumber numberWithDouble:span], nil]];
        }
    }

    @synchronized (_lock) {
        /**
         * Начало списка выбираем по сплошному ряду, а не по первому пришедшему.
         *
         * Куски приходят вразнобой, и первым нередко является самый новый.
         * Журнал 54, начало показа: сперва №3135027 (от начала записи),
         * потом №3143663 — то есть сам край, — и только за ним сервер
         * досылает 3143660, 3143661, 3143662. Записав в список 3143663,
         * мы закрыли дорогу всем трём: они ниже последнего записанного.
         * Плееру достался один сегмент, и он полторы минуты перечитывал
         * список с нулём в буфере. Журнал 52 — то же самое.
         *
         * Поэтому пока список пуст, ждём, чтобы собрался сплошной ряд из
         * трёх кусков, и начинаем с его **первого** номера. Заодно это
         * отсекает одинокий кусок от начала записи: в ряд он не встанет.
         * Две секунды на ожидание — если ряда так и нет, берём что есть,
         * иначе показ не начнётся вовсе.
         */
        if (_liveLast == 0 && [fresh count] > 0) {
            NSInteger runStart = 0;
            NSInteger runLength = 0;
            NSInteger bestStart = 0;
            NSInteger bestLength = 0;
            NSInteger previous = 0;

            for (NSArray *pair in fresh) {
                NSInteger sequence = [[pair objectAtIndex:0] integerValue];

                if (previous != 0 && sequence == previous + 1) {
                    runLength++;
                } else {
                    runStart = sequence;
                    runLength = 1;
                }

                if (runLength >= bestLength) {
                    bestStart = runStart;
                    bestLength = runLength;
                }

                previous = sequence;
            }

            if (_liveStartWaitAt <= 0) {
                _liveStartWaitAt = [NSDate timeIntervalSinceReferenceDate];
            }

            /**
             * Ждём сплошной ряд дольше — двух секунд мало.
             *
             * Журнал 65 показал цену спешки. К третьей секунде у нас был
             * ровно один свежий кусок (№3152661), список начался с него, а
             * сервер следом досылал №3152658 — ниже начала, и наш же список
             * его отбрасывал. Так четырнадцать раз подряд: показ отдал один
             * сегмент в 22:02:04 и следующий только в 22:02:44. Сорок секунд
             * простоя на ровном месте, при живой подаче.
             *
             * Шесть секунд ожидания стоят дешевле: сервер за это время
             * успевает досыпать соседей, ряд собирается, и список начинается
             * с самого нижнего из них — тогда ничего не пропадает.
             */
            BOOL waited =
                ([NSDate timeIntervalSinceReferenceDate] - _liveStartWaitAt > 6.0);

            if (bestLength < 3 && !waited) {
                return nil;
            }

            /**
             * Ряд так и не собрался — берём самый нижний кусок у края.
             *
             * Одинокий кусок от начала записи (сервер иногда отдаёт его
             * первым ответом) в счёт не идёт: он на много часов ниже
             * остальных. Отсекаем всё, что дальше двух минут от свежего.
             */
            if (bestLength < 3 && [fresh count] > 0) {
                NSInteger newest = [[[fresh lastObject] objectAtIndex:0] integerValue];
                NSInteger lowest = newest;

                for (NSArray *pair in fresh) {
                    NSInteger candidate = [[pair objectAtIndex:0] integerValue];

                    if (newest - candidate <= 24 && candidate < lowest) {
                        lowest = candidate;
                    }
                }

                bestStart = lowest;
            }

            if (bestStart > 0) {
                NSLog(@"[YouTube/Прокси] Эфир: начинаем список с №%ld "
                      @"(сплошных кусков %ld)", (long)bestStart, (long)bestLength);

                _liveLast = bestStart - 1;
            }
        }

        /**
         * Резерв кусков «про запас» отменён — он ничего не даёт.
         *
         * В 1.4-113 я придержал десяток кусков, не показывая их плееру, в
         * надежде удвоить укрытие. Журнал 62 показал, что вышло ровно
         * наоборот: три с половиной минуты подача идеальна (отставание
         * минус пять, набранное растёт в реальном времени), а запас у
         * плеера всё это время десять-пятнадцать секунд вместо пятидесяти.
         *
         * Причина проста, и я сам её выводил раньше, да не применил:
         * расстояние от живого края до места показа — **одна сумма**, и
         * она либо лежит у нас непоказанной, либо у плеера в буфере.
         * Придерживая куски, я не добавил укрытия, а переложил секунды из
         * буфера плеера себе в карман. Хуже того: плеер защищён своим
         * буфером сам, без нас, а наш «резерв» помогает только пока мы
         * успеваем его выкладывать — то есть ровно тогда, когда помощь и
         * не нужна.
         */
        for (NSArray *pair in fresh) {
            NSInteger sequence = [[pair objectAtIndex:0] integerValue];
            NSTimeInterval span = [[pair objectAtIndex:1] doubleValue];

            if (_liveLast != 0 && sequence <= _liveLast) {
                continue;
            }

            /**
             * В список кладём только подряд — опоздавшего ждём.
             *
             * Куски приходят не по порядку. Журнал 52, начало показа:
             * 09:02:02.872 пришёл №3143301 (это сам край), а 09:02:03.384
             * — №3143298, то есть на три куска раньше. Список у нас
             * append-only, и, записав сперва 3143301, мы закрыли дорогу
             * всему, что лежит раньше: 3143298, 3143299 и 3143300 были
             * отброшены навсегда. Плееру досталcя один сегмент, и дальше
             * он полторы минуты перечитывал список, в котором ничего не
             * появлялось, с нулём в буфере.
             *
             * Порядок в списке переставить нельзя — такова природа HLS.
             * Значит надо не торопиться: пока дыра свежая, ждём опоздавший
             * кусок, он обычно приходит через полсекунды. И только если
             * его нет восемь секунд, признаём дыру настоящей и шагаем
             * через неё — время у показа своё, разрыва он не заметит.
             */
            if (_liveLast != 0 && sequence > _liveLast + 1) {
                NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

                if (_liveGapAt <= 0 || _liveGapAfter != _liveLast) {
                    _liveGapAt = now;
                    _liveGapAfter = _liveLast;
                }

                if (now - _liveGapAt < 8.0) {
                    break;
                }

                NSLog(@"[YouTube/Прокси] Эфир: куска №%ld нет восемь секунд — "
                      @"переступаем, в списке дальше №%ld",
                      (long)(_liveLast + 1), (long)sequence);

                _liveGapAt = 0;
                _liveGapAfter = 0;
            }

            if (_liveLines == nil) {
                _liveLines = [NSMutableArray array];
            }

            if (_liveFirst == 0) {
                _liveFirst = sequence;
            }

            /**
             * Разрыва здесь нет и быть не может.
             *
             * Пропущенные сервером куски не оставляют дыры во времени:
             * оно у эфира своё, и куски ложатся в него подряд (см.
             * `liveStartFor:span:`). Прежде на этом месте стоял
             * `#EXT-X-DISCONTINUITY`, и каждый пропуск стоил плееру
             * перезапуска раскодирования — долгая подгрузка на ровном
             * месте.
             */

            [_liveLines addObject:[NSString stringWithFormat:
                @"#EXTINF:%.3f,\n/%lu/s/%ld.ts\n",
                span, (unsigned long)_session, (long)(sequence - 1)]];

            _liveLast = sequence;
            _liveLongest = MAX(_liveLongest, span);
        }

        if ([_liveLines count] == 0) {
            return nil;
        }

        NSMutableString *playlist = [NSMutableString string];

        [playlist appendString:@"#EXTM3U\n#EXT-X-VERSION:3\n"];
        [playlist appendString:@"#EXT-X-PLAYLIST-TYPE:EVENT\n"];
        [playlist appendString:@"#EXT-X-INDEPENDENT-SEGMENTS\n"];
        [playlist appendFormat:@"#EXT-X-TARGETDURATION:%ld\n",
            (long)(_liveLongest + 0.999)];
        [playlist appendFormat:@"#EXT-X-MEDIA-SEQUENCE:%ld\n",
            (long)(_liveFirst - 1)];

        for (NSString *line in _liveLines) {
            [playlist appendString:line];
        }

        /**
         * Конец трансляции — конец списка.
         *
         * Без этой строки плеер считает эфир идущим: стоит у края,
         * перечитывает список каждые три секунды и, дождавшись хоть
         * чего-нибудь, порой заводит звук с последнего куска заново.
         * С ней он доигрывает набранное и останавливается как у записи.
         */
        if (_liveEnded) {
            [playlist appendString:@"#EXT-X-ENDLIST\n"];
        }

        return playlist;
    }
}

/**
 * Готовит показ эфира.
 *
 * Списка кусков наперёд здесь нет и быть не может: трансляцию снимают
 * прямо сейчас. Поэтому плейлист не составляется один раз, как у записи,
 * а пересобирается на каждый запрос — из того, что подача успела набрать.
 */
/**
 * Меняем подачу под показом, не трогая ни плеер, ни список.
 *
 * Журналы 41, 42, 45 и 48 говорят одно и то же: застрявшую подачу эфира
 * оживляет **только новый `/player`** — новый адрес и новый PO-токен.
 * Пересадка сессии с тем же адресом (сброс печенья) двух минут подряд не
 * помогала: журнал 48, с 07:48:34 по 07:50:30 буфер сползал 45 → 0, и
 * ничего не менялось, пока в 07:50:30 не пришёл свежий `/player`. После
 * него набранное прыгнуло с 15711710 на 15711805 — девяносто пять секунд
 * показа за десять секунд, — и буфер встал на пятьдесят.
 *
 * Беда была в том, что новый `/player` у нас добывался только жёстким
 * перезапуском, а тот пересобирает плеер: картинка дёргается, последний
 * кусок играет заново. Я сперва поднял его порог до двух минут, чтобы не
 * рвать показ, — и тем самым заставил человека ждать эту минуту с нулём
 * в буфере.
 *
 * Здесь это разделено. Новую подачу берём, а плееру не говорим ничего:
 * список `_liveLines`, ось времени `_liveTimeline` и отданное `_liveServed`
 * остаются как были, потому что ось у нас своя и к номерам куска у
 * источника не привязана. Для плеера просто продолжают дописываться
 * сегменты — он ничего не замечает.
 */
- (YTSabr *)liveSabr {
    @synchronized (_lock) {
        return _sabrLive ? _sabr : nil;
    }
}

- (BOOL)renewLiveSabr:(YTSabr *)sabr {
    if (sabr == nil || ![sabr liveMode]) {
        return NO;
    }

    YTTrackInit *videoInit = [YTMp4 parseInit:[sabr videoInit]];
    YTTrackInit *audioInit = [YTMp4 parseInit:[sabr audioInit]];

    if (videoInit == nil || ![videoInit isVideo]) {
        NSLog(@"[YouTube/Прокси] Новая подача без заголовка видео — оставляем старую");

        return NO;
    }

    NSUInteger session = 0;

    @synchronized (_lock) {
        if (!_sabrLive || _liveEnded) {
            return NO;
        }

        /**
         * Новая подача начинает оттуда, где мы стоим, а не за минуту до
         * края: всё до этой отметки у раздачи уже есть и в список внесено.
         */
        if (_liveFilledEver > 0) {
            [sabr setLiveStartHint:MAX(0.0, _liveFilledEver - 10.0)];
        }

        _sabr = sabr;
        _sabrVideoInit = videoInit;
        _sabrVideoInitItag = [sabr videoInitItag];

        if (audioInit != nil) {
            _sabrAudioInit = audioInit;
        }

        // Здоровье считаем заново; список, ось времени и отданное не трогаем.
        _liveEmpties = 0;
        _liveRestartAt = 0;
        _liveRateWall = 0;
        _liveRateMedia = 0;
        _liveLagRuns = 0;
        _liveLagAt = 0;
        _liveLagFilled = 0;
        _liveFedAt = [NSDate timeIntervalSinceReferenceDate];

        /**
         * Номер сессии не меняем — иначе показ обрывается.
         *
         * В адресах плейлиста и сегментов зашит именно он, а раздача
         * запросы с чужим номером отвергает (см. разбор пути). Подмена в
         * 1.4-100 номер увеличивала, и после неё плеер терял сразу всё:
         * и свой плейлист, и все уже выданные адреса. В журнале 50 это
         * читается буквально — три минуты ровного хода, подмена, и буфер
         * уже не поднимается никогда, сколько ни чини подачу.
         *
         * Старую качалку отставляет проверка `sabr == _sabr`: подачу мы
         * подменили, значит её `sabr` чужой, и она уйдёт сама на первом
         * же витке. Номер сессии для этого не нужен.
         */
        session = _session;
    }

    NSLog(@"[YouTube/Прокси] Эфир: подача заменена на свежую, показ не тронут");

    [NSThread detachNewThreadSelector:@selector(pumpLive:)
                             toTarget:self
                           withObject:@[sabr, @(session)]];

    return YES;
}

- (NSString *)openLiveWithSabr:(YTSabr *)sabr
                     videoInit:(YTTrackInit *)videoInit
                     audioInit:(YTTrackInit *)audioInit {
    @synchronized (_lock) {
        _sabr = sabr;
        _sabrVideoInit = videoInit;
        _sabrVideoInitItag = [sabr videoInitItag];
        _sabrAudioInit = audioInit;
        _sabrLive = YES;
        _duration = 0;
        _liveLines = nil;
        _liveTimeline = nil;
        _liveClock = 0;
        _liveEmpties = 0;
        _liveRestartAt = 0;
        _liveRateWall = 0;
        _liveRateMedia = 0;
        _liveLagRuns = 0;
        _liveLagAt = 0;
        _liveLagFilled = 0;
        _liveEnded = NO;
        _liveFedAt = [NSDate timeIntervalSinceReferenceDate];
        _liveFirst = 0;
        _liveLast = 0;
        _liveLongest = 0;
        _liveServed = 0;
        _liveFilledEver = 0;
        _liveGapAt = 0;
        _liveGapAfter = 0;
        _liveStartWaitAt = 0;
        _session++;
    }

    /**
     * Назад за запасом не ходим.
     *
     * Здесь стоял отступ на полминуты от края — по образцу Android.
     * На деле ни одна из проверенных трансляций назад не отдаёт:
     * сервер на просьбу «с 7246820 с» невозмутимо присылал тот же
     * первый кусок, и так восемь раз — семь лишних мегабайт и три
     * секунды до начала показа. Запас эфиру даёт сам вид списка
     * (`EVENT`): плеер начинает с первого набранного и идёт подряд.
     */
    /**
     * Запас набираем ДО начала показа — потом его уже не нарастить.
     *
     * Это главный вывод всей возни с эфиром. Запас у плеера — свойство
     * старта: сколько набрали до первого кадра, столько и будет держаться.
     * Журнал 67: старт дал пятьдесят секунд, и восемь минут стояло
     * пятьдесят. Журнал 68: старт дал двадцать, и восемь минут стояло
     * двадцать три, ровной полкой.
     *
     * Вырастить его на ходу нельзя, и это не лень, а арифметика. У края
     * сервер отдаёт ровно один кусок за такт нарезки, то есть подача идёт
     * в реальном времени: сколько взяли, столько плеер и проиграл. А
     * пересадка назад не помогает — там лежит уже проигранное, список
     * append-only, и плееру оно не нужно. Проверено в журнале 68: набор
     * запаса сработал восемь раз и не поднял буфер ни на секунду.
     *
     * Значит ждём до старта, пока не наберётся десяток кусков подряд.
     * Позади края они уже нарезаны и приходят пачками, так что это
     * секунды, а не минуты. Потолок ожидания — восемь секунд: лучше
     * начать с тем, что есть, чем не начать вовсе.
     */
    NSTimeInterval begun = [NSDate timeIntervalSinceReferenceDate];
    NSString *playlist = nil;

    for (int wait = 0; wait < 24; wait++) {
        playlist = [self livePlaylistFor:sabr];

        /**
         * Считаем сегменты в самом списке, а не куски в хранилище.
         *
         * На этом я и промахнулся в 1.4-128: порог смотрел на общее число
         * кусков, а плееру достаётся только сплошной ряд. Журнал 73: в
         * хранилище лежали 4436, 4433, 4434 — три штуки, порог считал их
         * достаточными, — а подряд шли лишь два, и список открылся на
         * десяти секундах.
         *
         * Дальше сервер, отдав первые три куска за шесть секунд, замолчал
         * почти на девять (приходы: 1,5 / 2,7 / 5,8, потом ничего до 14,4).
         * Десяти секунд запаса на такую паузу не хватает — отсюда ноль на
         * пятнадцатой секунде показа. Двадцать секунд её переживают.
         */
        NSUInteger ready = 0;

        if (playlist != nil) {
            NSRange from = NSMakeRange(0, [playlist length]);

            while (from.length > 0) {
                NSRange hit = [playlist rangeOfString:@"#EXTINF" options:0 range:from];

                if (hit.location == NSNotFound) {
                    break;
                }

                ready++;

                NSUInteger next = hit.location + hit.length;
                from = NSMakeRange(next, [playlist length] - next);
            }
        }
        NSTimeInterval spent = [NSDate timeIntervalSinceReferenceDate] - begun;

        /**
         * Четыре куска — и в путь. Остальное доберём на ходу.
         *
         * Четыре куска это двадцать секунд запаса: хватает, чтобы плеер не
         * упёрся в ноль, пока приходят следующие. Дольше четырёх секунд не
         * ждём — начало показа важнее.
         *
         * А дальше запас растёт сам, и это видно в журнале 72: ноль на
         * старте, 32,7 через сорок секунд, 40,0 ещё через тринадцать.
         * Работает это потому, что набирать мы начинаем далеко позади края
         * (см. `YTLiveCushion`): впереди лежит уже нарезанное, сервер отдаёт
         * его пачками по три-четыре куска за ответ, то есть быстрее
         * реального времени, — и разница идёт в запас, пока мы не догоним
         * край. Догнав, запас перестаёт расти, но к тому времени он уже
         * набран.
         *
         * Двумя кусками начинать нельзя — это и была подгрузка в журнале 72:
         * список открылся на двух, плеер проел их быстрее, чем пришли
         * следующие, и сел на ноль. Двух мало, восьми ждать долго, четыре
         * в самый раз.
         */
        if (playlist != nil && (ready >= 4 || spent > 4.0)) {
            break;
        }

        NSTimeInterval from = [sabr liveNextTime];

        if (from <= 0) {
            from = [sabr liveHeadSeconds] > 0
                ? [sabr liveHeadSeconds] : [sabr liveStartSeconds];
        }

        if (![sabr requestMoreFrom:from]) {
            [NSThread sleepForTimeInterval:0.25];
        }
    }

    playlist = [self livePlaylistFor:sabr];

    if (playlist == nil) {
        NSLog(@"[YouTube/Прокси] Эфир: кусков так и не набралось");

        return nil;
    }

    @synchronized (_lock) {
        _playlist = playlist;
    }

    NSLog(@"[YouTube/Прокси] Эфир готов, звук %@",
          audioInit != nil ? @"есть" : @"НЕТ");

    [NSThread detachNewThreadSelector:@selector(pumpLive:)
                             toTarget:self
                           withObject:@[sabr, @(_session)]];

    return [self playbackUrlWithVideo:videoInit audio:audioInit frames:0];
}

/**
 * Качалка эфира: сама просит подачу, пока идёт трансляция.
 *
 * Здесь и лежала разница с Android, из-за которой эфир останавливался
 * через несколько секунд. Там плеер тянет байты из нашего источника
 * сам, непрерывно, и «проси ещё» получается само собой — внутри того же
 * цикла чтения. Здесь плеер ходит к нам за кусками по HTTP, и между
 * двумя кусками нас никто не тревожит.
 *
 * Получался замкнутый круг: новый кусок не появится в плейлисте, пока
 * мы не попросим подачу, — а просим мы только когда плеер спросит кусок,
 * которого в плейлисте нет. В журнале это видно дословно: плеер каждые
 * две с половиной секунды перечитывал плейлист, тот не рос, и через
 * полминуты наш же присмотр решал, что сеть не тянет, и опускал
 * качество: 720p, 480p, 360p, 240p.
 *
 * Поэтому у трансляции просит отдельная нить — раз в секунду, с живого
 * края. Замок берём тот же, что и сборка куска: у подачи своего нет,
 * а словари фрагментов общие.
 *
 * Живёт нить ровно столько, сколько живёт эта сессия прокси: сменился
 * ролик или качество — метка не совпадёт, и нить уйдёт сама.
 */
- (void)pumpLive:(NSArray *)pair {
    YTSabr *sabr = [pair objectAtIndex:0];
    NSUInteger session = [[pair objectAtIndex:1] unsignedIntegerValue];

    NSTimeInterval saidAt = 0;

    while (YES) {
        @autoreleasepool {
            BOOL mine = NO;

            @synchronized (_lock) {
                mine = (session == _session && sabr == _sabr && _sabrLive && !_liveEnded);
            }

            if (!mine) {
                return;
            }

            /**
             * Дальше плеера не убегаем: не больше шести кусков сверх того,
             * что он забрал, и считаем по сплошному ряду — иначе дыра
             * оборачивается взаимным затором.
             */
            NSInteger served = 0;

            @synchronized (_lock) {
                served = _liveServed;
            }

            NSArray *held = nil;

            @synchronized (sabr) {
                held = [sabr videoSequences];
            }

            NSInteger ahead = 0;

            for (NSNumber *number in held) {
                if ([number integerValue] == served + ahead + 1) {
                    ahead++;
                }
            }

            /**
             * Запас держим в двадцать кусков (сто секунд),
             * а не в шесть: у края подача идёт ровно в реальном времени,
             * и всё, что не набрано заранее, потом не набрать. Разбор —
             * в `YTSabr.m`, где набирается запас (`YTLiveCushion`).
             */
            if (served > 0 && ahead >= 20) {
                [NSThread sleepForTimeInterval:1.0];

                continue;
            }

            /**
             * Сеть — без замка подачи.
             *
             * Замок нужен подготовке запроса и разбору ответа: они правят
             * общие словари. Самой сети он не нужен, а держать его на ней
             * значило ставить сборку куска для плеера в очередь за чужим
             * HTTP-запросом — секунды задержки на каждом куске и на первом
             * кадре эфира.
             */
            NSTimeInterval from = 0;
            NSUInteger before = 0;
            NSUInteger liveBefore = 0;
            NSMutableURLRequest *request = nil;

            @synchronized (sabr) {
                from = [sabr liveNextTime];

                if (from <= 0) {
                    from = [sabr liveHeadSeconds] > 0
                        ? [sabr liveHeadSeconds] : [sabr liveStartSeconds];
                }

                before = [sabr delivered];
                liveBefore = [sabr received];
                request = [sabr prepareRequestFrom:from];
            }

            YTHttpResponse *response = (request != nil) ? [sabr perform:request] : nil;

            BOOL got = NO;
            BOOL alive = NO;

            @synchronized (sabr) {
                if (response != nil) {
                    [sabr absorb:response];
                }

                got = ([sabr delivered] > before);

                /**
                 * Жизнь подачи считаем по всему пришедшему, включая
                 * повторы: отмотка назад — обычный ход сервера у эфира
                 * (разбор в `YTSabr.m`, у счётчика `_received`). Прежде
                 * повтор шёл за молчание, и мы рвали живую сессию.
                 */
                alive = ([sabr received] > liveBefore);

                NSTimeInterval filledNow = [sabr liveFilledSeconds];

                @synchronized (_lock) {
                    _liveFilledEver = MAX(_liveFilledEver, filledNow);
                }
            }

            _liveGot = got;

            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

            if (alive) {
                _liveEmpties = 0;

                @synchronized (_lock) {
                    _liveFedAt = now;
                }
            }

            /**
             * Сторож по ходу времени: отстаём — пересаживаемся, пока запас есть.
             *
             * Подсказал человек: «делай эту долгую подгрузку заранее». Журнал
             * 43 показал, отчего прежний сторож опаздывал. Он ждал молчания в
             * восемь секунд, а беда приходила иначе: куски **шли**, только
             * вдвое медленнее нужного — интервал с 5,0 с пополз на 10,0 с.
             * Молчания в восемь секунд при этом не случалось, запас таял
             * (8 → 6 → 2 → 1 кусок), и сессию мы заводили заново уже на
             * пустом буфере. Отсюда и то, что видел человек: перезапуск,
             * последний кусок, а за ним долгая подгрузка.
             *
             * Мерило поэтому не молчание, а ход времени: на сколько секунд
             * показа продвинулось набранное за столько-то секунд по стенным
             * часам. Живой эфир нарезается в реальном времени, значит
             * отставание набранного от часов — это и есть убыль запаса, и
             * видна она сразу, а не когда буфер кончился. Считаем по
             * полуминуте и требуем не меньше четырёх пятых хода.
             *
             * Так и выходит «подгрузка заранее»: её покрывает запас — на то
             * он и набран, — и показ остановки не видит.
             *
             * Молчание в восемь секунд оставляем вторым поводом: обрыв бывает
             * и резким, ждать полминуты замера в этом случае незачем.
             */
            NSTimeInterval mediaNow = [sabr liveFilledSeconds];

            if (_liveRateWall <= 0 || mediaNow < _liveRateMedia) {
                _liveRateWall = now;
                _liveRateMedia = mediaNow;
            }

            /**
             * Второй сторож, по просьбе человека: «буфер меньше порога и
             * убывает уже несколько секунд подряд».
             *
             * Прямо буфер плеера нам не виден — он живёт в AVPlayer. Зато
             * видно равноценное: насколько набранное отстало от края.
             * В здоровом ходу это пять-десять секунд (кусок нарезается
             * пять секунд, и мы идём вплотную). Всё, что больше, — уже
             * потерянные секунды запаса, и видно их сразу.
             *
             * Про «сколько секунд подряд»: беру три замера кряду. Такт
             * опроса у нас около двух секунд, значит речь о шести-семи
             * секундах — заведомо больше одного куска (пять секунд), так
             * что одна запоздавшая пачка сторожа не поднимет, а настоящее
             * отставание он заметит через шесть секунд, а не через минуту.
             */
            NSTimeInterval headNow = [sabr liveHeadSeconds];
            NSTimeInterval lag = (headNow > 0 && mediaNow > 0)
                ? headNow - mediaNow : 0.0;

            /**
             * Отставания мало — нужно, чтобы оно ещё и **не сокращалось**.
             *
             * На этом я сломал начало показа в 1.4-93. Начинаем мы нарочно
             * за девяносто секунд до края, значит отставание там девяносто
             * и есть — по замыслу. Сторож видел превышение порога, через
             * три замера рвал сессию, и так по кругу: буфер умирал через
             * семь секунд после начала. А ведь в те секунды всё шло как
             * надо — набранное нагоняло край пачками, быстрее часов.
             *
             * Потому считаем замер дурным только если набранное за это
             * время продвинулось медленнее стенных часов. Нагоняем —
             * сторож молчит, сколько бы ни было отставание; стоим или
             * сползаем — он считает и на третьем замере пересаживает.
             * Это же и есть «буфер убывает несколько секунд подряд»,
             * только выраженное в том, что нам видно.
             */
            BOOL slipping = NO;

            if (_liveLagAt > 0) {
                NSTimeInterval wallStep = now - _liveLagAt;
                NSTimeInterval mediaStep = mediaNow - _liveLagFilled;

                slipping = (wallStep > 0.5 && mediaStep < wallStep * 0.9);
            }

            if (_liveLagAt <= 0 || now - _liveLagAt > 0.5) {
                _liveLagAt = now;
                _liveLagFilled = mediaNow;
            }

            if (lag > 25.0 && slipping) {
                _liveLagRuns++;
            } else if (!slipping || lag <= 25.0) {
                _liveLagRuns = 0;
            }

            BOOL losing = (_liveLagRuns >= 3);

            if (losing) {
                NSLog(@"[YouTube/Прокси] Эфир: набранное отстало от края на "
                      @"%.0f с и не нагоняет третий замер кряду — пересаживаемся",
                      lag);
            }

            if (!losing && now - _liveRateWall >= 30.0) {
                NSTimeInterval wallRun = now - _liveRateWall;
                NSTimeInterval mediaRun = mediaNow - _liveRateMedia;

                losing = (mediaRun < wallRun * 0.8);

                if (losing) {
                    NSLog(@"[YouTube/Прокси] Эфир: за %.0f с набрали только "
                          @"%.0f с показа — пересаживаемся заранее",
                          wallRun, mediaRun);
                }

                _liveRateWall = now;
                _liveRateMedia = mediaNow;
            }

            if ((losing || (!alive && now - _liveFedAt > 8.0))
                && now - _liveRestartAt > 15.0) {
                /**
                 * Заводим сессию заново — это и лечит.
                 *
                 * Журнал 42: паузу на сто пятьдесят семь секунд оборвал лишь
                 * полный перезапуск потока, чья новая сессия попросила край
                 * минус девяносто пять и сразу заиграла со здоровым запасом.
                 * Сто тридцать семь секунд из них мы гонялись за краем, потому
                 * что моя же правка 1.4-86 глушила перезапуск, пока приходит
                 * часть №69. Глушилка снята: свежая сессия, попросив позади
                 * края, оживляет показ немедленно (журналы 41 и 42).
                 */
                _liveEmpties = 0;
                _liveRestartAt = now;
                _liveRateWall = 0;
                _liveLagRuns = 0;
                _liveLagAt = 0;

                @synchronized (sabr) {
                    [sabr restartSession];
                }
            }

            if (!got && now - saidAt > 10.0) {
                saidAt = now;

                NSLog(@"[YouTube/Прокси] Эфир молчит: просим с %.0f с, "
                      @"край %.0f с, сервер просит ждать %lld мс",
                      from, [sabr liveHeadSeconds], [sabr backoffMs]);
            }
        }

        /**
         * Принесли — спрашиваем снова сразу: сервер отдаёт по куску
         * за ответ, и догнать его можно лишь спрашивая чаще, чем он
         * нарезает. Пусто — выжидаем такт, но не дольше двух секунд.
         */
        NSTimeInterval wait = [sabr backoffMs] / 1000.0;

        [NSThread sleepForTimeInterval:
            /**
             * Паузу, которую просит сервер, исполняем целиком.
             *
             * Журнал 90: в правилах нам приходит `4=5000` — «подожди пять
             * секунд», — а браузеру этого поля не шлют вовсе. Разница в
             * такте: он спрашивает раз в пять секунд, по куску, а мы, обрезав
             * паузу двумя секундами, долбили сервер каждые две. Медиана
             * промежутка у нас 2,35 с против 4,98 с у браузера. Сервер
             * прямо просил нас перестать — а мы не слушали.
             */
            _liveGot ? 0.3 : MIN(6.0, MAX(0.5, wait))];
    }
}

/**
 * Что отдать плееру — список кусков.
 *
 * Здесь недолго стоял ещё и сводный плейлист: тот, что называет
 * разрешение, кодеки и битрейт. Затея не прижилась. AVFoundation на
 * iOS 6 его не принимала — «Поток не открылся» на каждом заходе, — и
 * показ держался на запасном ходе: увидев отказ, мы пересоздавали
 * плеер с простым списком. Пересоздание же начинало ролик сначала,
 * и смена качества посреди просмотра возвращала к нулевой секунде.
 *
 * Украшение того не стоило: размер картинки панель узнаёт у самой
 * дорожки, а плееру он для показа не нужен.
 */
- (NSString *)playbackUrlWithVideo:(YTTrackInit *)videoInit
                             audio:(YTTrackInit *)audioInit
                            frames:(NSInteger)frames {
    return [NSString stringWithFormat:@"http://127.0.0.1:%u/%lu/p.m3u8",
            _port, (unsigned long)_session];
}

- (BOOL)isLive {
    @synchronized (_lock) {
        return _sabrLive && !_liveEnded;
    }
}

- (NSTimeInterval)liveLagSeconds {
    @synchronized (_lock) {
        if (!_sabrLive || _sabr == nil) {
            return 0;
        }

        NSTimeInterval head = [_sabr liveHeadSeconds];

        return (head > 0 && _liveFilledEver > 0) ? head - _liveFilledEver : 0;
    }
}

/**
 * Докуда набрано — по памяти раздачи, а не по нынешней подаче.
 *
 * Спрашивать у подачи нельзя: при подмене она новая, её отметка начинается
 * с нуля, и ход мгновенно выглядит отброшенным назад. Сторож на это
 * отзывался новой подменой, та — новой подачей, и круг кормил сам себя.
 * Журналы 49 и 50 показывают его одинаково: набранное болтается
 * (15714880 → 15714805 → 15714870), а буфер под этим стекает к нулю.
 *
 * Потому помним наибольшее за всё время показа: куски от смены подачи
 * никуда не делись.
 */
- (NSTimeInterval)liveFilledSeconds {
    @synchronized (_lock) {
        return _liveFilledEver;
    }
}

- (NSTimeInterval)liveStarvedSeconds {
    @synchronized (_lock) {
        if (!_sabrLive || _liveEnded) {
            return 0;
        }


        return [NSDate timeIntervalSinceReferenceDate] - _liveFedAt;
    }
}

- (void)endLive {
    @synchronized (_lock) {
        if (!_sabrLive || _liveEnded) {
            return;
        }

        _liveEnded = YES;
    }

    NSLog(@"[YouTube/Прокси] Эфир завершён — список закрыт");
}

- (BOOL)hasAudio {
    @synchronized (_lock) {
        return _sabrAudioInit != nil || _audioInit != nil;
    }
}

/**
 * Собирает кусок для плеера из фрагментов подачи.
 *
 * Нарезка у дорожек разная — видео по 5.5 с, звук по 10, — поэтому
 * к видеофрагменту добавляются все звуковые, попадающие в его границы
 * хотя бы частью. Ровно так же поступает и обычный путь, только там
 * границы берутся из карты `sidx`.
 */
- (NSData *)buildSabrSegment:(NSInteger)index {
    YTSabr *sabr = nil;
    YTTrackInit *videoInit = nil;
    YTTrackInit *audioInit = nil;

    @synchronized (_lock) {
        sabr = _sabr;
        videoInit = _sabrVideoInit;
        audioInit = _sabrAudioInit;
    }

    if (sabr == nil) {
        return nil;
    }

    /**
     * Сменилась дорожка — перечитываем её заголовок.
     *
     * Сервер понижает качество на ходу, и с новой дорожкой приходят
     * новые SPS/PPS. Разобранный заголовок брался единожды, при запуске,
     * и кадры новой дорожки шли через старое описание кодека — картинка
     * рассыпалась. Сверяемся по номеру: совпал — ничего не делаем,
     * разошёлся — разбираем свежий и запоминаем, чей он теперь.
     *
     * Под общим замком, не под замком подачи: правим здесь только своё
     * разобранное поле, а `[sabr videoInit]` лишь читаем.
     */
    NSInteger liveItag = [sabr videoInitItag];

    if (liveItag != 0 && liveItag != _sabrVideoInitItag) {
        YTTrackInit *fresh = [YTMp4 parseInit:[sabr videoInit]];

        if (fresh != nil && [fresh isVideo]) {
            @synchronized (_lock) {
                _sabrVideoInit = fresh;
                _sabrVideoInitItag = liveItag;
            }

            videoInit = fresh;

            NSLog(@"[YouTube/Прокси] Дорожка сменилась на itag %ld — "
                  @"заголовок перечитан", (long)liveItag);
        }
    }

    NSInteger sequence = index + 1;

    /**
     * Вся работа с подачей — под её собственным замком.
     *
     * Прокси обслуживает каждое соединение своим потоком, а плеер при
     * смене качества просит куски внахлёст: два потока разом звали
     * подачу и правили одни и те же словари фрагментов. Приложение
     * от этого падало — не всегда, а когда повезёт совпасть.
     *
     * Замок берётся на всю сборку куска, а не на отдельные обращения:
     * между «есть ли фрагмент» и «взять фрагмент» другой поток успел бы
     * всё сбросить прыжком.
     */
    /**
     * У эфира ждём фрагмент **до** замка, а не под ним.
     *
     * Замок подачи один на всех, и качалка берёт его же. Задержись
     * сборка внутри — качалке не пройти, а ждём мы как раз того, что
     * принесёт она: получилось бы, что кусок ждёт сам себя.
     *
     * Обычно ждать не приходится вовсе: в плейлист попадают только
     * куски с известной длиной, а длина берётся из расстояния до
     * следующего — значит следующий уже пришёл. Ожидание здесь на случай
     * заминки в сети.
     */
    if ([sabr liveMode]) {
        for (NSInteger attempt = 0; attempt < 40; attempt++) {
            BOOL here = NO;

            @synchronized (sabr) {
                here = ([sabr videoSegment:sequence] != nil);
            }

            if (here) {
                break;
            }

            [NSThread sleepForTimeInterval:0.25];
        }
    }

    @synchronized (sabr) {
        return [self buildSabrSegment:index
                             sequence:sequence
                                 sabr:sabr
                            videoInit:videoInit
                            audioInit:audioInit];
    }
}

/**
 * Докуда звук идёт без разрывов, считая от указанного мига.
 *
 * Фрагменты просматриваются по возрастанию номера — так же они идут
 * и по времени. Разрыв обрывает счёт: то, что лежит за ним, куску
 * не поможет, его всё равно нечем склеить.
 */
/**
 * Сообщает ли подача времена звуковых фрагментов.
 *
 * Пока фрагментов нет вовсе, ответ утвердительный: проверять нечего,
 * и ждать их стоит. А вот когда фрагменты есть, а времён у них нет,
 * рассуждать о непрерывности звука бессмысленно — ни один из них
 * не «покрывает» ничего, и ожидание лишь тратит запросы впустую.
 */
- (BOOL)audioTimesKnownIn:(YTSabr *)sabr {
    NSArray *keys = [sabr audioSequences];

    if ([keys count] == 0) {
        return YES;
    }

    for (NSNumber *key in keys) {
        if ([sabr audioSegmentDuration:[key integerValue]] > 0) {
            return YES;
        }
    }

    return NO;
}

/**
 * Номер видеофрагмента, накрывающего это время; 0 — такого нет.
 *
 * «Накрывает» — то есть время попадает в объявленные им границы. Если
 * ни один не попал, берётся ближайший начавшийся раньше, но не далее
 * шага: у фрагментов иногда нет объявленной длины, и тогда судить
 * можно только по началу. Дальше шага искать нельзя — так подсунулся бы
 * фрагмент из совсем другого места ролика.
 */
- (NSInteger)videoSequenceAt:(NSTimeInterval)time in:(YTSabr *)sabr {
    NSInteger nearest = 0;
    NSTimeInterval nearestStart = -HUGE_VAL;

    for (NSNumber *key in [sabr videoSequences]) {
        NSInteger n = [key integerValue];

        NSTimeInterval start = [sabr videoSegmentStart:n];
        NSTimeInterval length = [sabr videoSegmentDuration:n];

        if (length > 0 && start <= time + 0.05 && start + length > time + 0.05) {
            return n;
        }

        if (start <= time + 0.05 && start > nearestStart) {
            nearestStart = start;
            nearest = n;
        }
    }

    if (nearest != 0 && time - nearestStart <= _sabrStep) {
        return nearest;
    }

    return 0;
}

- (NSTimeInterval)audioCoverIn:(YTSabr *)sabr from:(NSTimeInterval)from {
    NSTimeInterval covered = from;

    for (NSNumber *key in [sabr audioSequences]) {
        NSInteger n = [key integerValue];

        NSTimeInterval start = [sabr audioSegmentStart:n];
        NSTimeInterval end = start + [sabr audioSegmentDuration:n];

        if (end <= covered + 0.01) {
            continue;
        }

        if (start > covered + 0.05) {
            break;
        }

        covered = end;
    }

    return covered;
}

/**
 * Ждёт звук на время куска — столько же, сколько ждали видео.
 *
 * Прежде ожидание было только за видеофрагментом: пришёл он — кусок
 * собирается, а звука в нём столько, сколько случайно оказалось под
 * рукой. Обычно хватало: звук приходит теми же ответами и заранее.
 * Но стоило видеофрагментам оказаться в памяти с прошлого круга —
 * а после повтора ролика так и есть, — как кусок собирался мгновенно
 * и молча: спрашивать сервер было незачем, картинка ведь уже была.
 *
 * Попыток немного: если звука у ролика дальше просто нет, сервер
 * ответит пустотой, и настаивать бессмысленно.
 */
- (void)waitAudio:(YTSabr *)sabr
             from:(NSTimeInterval)from
               to:(NSTimeInterval)to
            index:(NSInteger)index {
    /**
     * У эфира звук приносит качалка — вместе с картинкой, тем же
     * ответом. Просить его отсюда значит увести подачу назад по времени
     * ради куска, который и так в пути.
     */
    if ([sabr liveMode]) {
        return;
    }

    for (NSInteger attempt = 0; attempt < 4; attempt++) {
        if ([self audioCoverIn:sabr from:from] >= to - 0.05) {
            return;
        }

        if (![sabr requestMoreFrom:from]) {
            break;
        }
    }

    NSTimeInterval covered = [self audioCoverIn:sabr from:from];

    if (covered < to - 0.05) {
        NSLog(@"[YouTube/Прокси] Звука для куска %ld набрано %.1f с из %.1f",
              (long)index, covered - from, to - from);
    }
}

- (NSData *)buildSabrSegment:(NSInteger)index
                    sequence:(NSInteger)sequence
                        sabr:(YTSabr *)sabr
                   videoInit:(YTTrackInit *)videoInit
                   audioInit:(YTTrackInit *)audioInit {

    /**
     * Место куска на оси плейлиста — равные шаги, и только они.
     *
     * Плеер знает ролик именно так: длительность и число кусков известны
     * заранее, а длины отдельных фрагментов — нет, поэтому плейлист
     * нарезан поровну. Настоящие же фрагменты бывают и по три секунды,
     * и по семь.
     */
    /**
     * Где кусок стоит на оси плейлиста и какой фрагмент ему полагается.
     *
     * С картой `sidx` и то и другое известно точно: границы кусков в
     * плейлисте — это и есть границы фрагментов, а номер фрагмента равен
     * номеру куска плюс один. Тогда искать по времени не нужно вовсе,
     * и ни повторов, ни пропусков быть не может.
     *
     * Без карты остаётся прежнее: равные куски по средней длине
     * и поиск подходящего фрагмента по времени.
     */
    BOOL mapped = ([_sabrStarts count] > (NSUInteger)index);

    NSTimeInterval slot = mapped
        ? [[_sabrStarts objectAtIndex:index] doubleValue]
        : (NSTimeInterval)index * _sabrStep;

    /**
     * У эфира место куска берём у него самого, а не считаем по номеру.
     *
     * Карты фрагментов у трансляции нет, и без неё время считалось как
     * «номер, умноженный на среднюю длину». У записи номера начинаются
     * с единицы, и это сходится; у эфира они идут от начала вещания —
     * триста сорок восемь тысяч, — и произведение давало полтора
     * миллиона секунд, то есть двое суток позади живого края. В журнале
     * это «просьба с 1519425 с слишком далеко позади».
     *
     * Номер куска в плейлисте эфира — это номер фрагмента минус один,
     * так его и спрашиваем: у самой подачи, по разметке.
     */
    if ([sabr liveMode]) {
        // Не знаем времени — ставим ноль: счёт по номеру куска
        // у трансляции даёт полтора миллиона секунд, а не время.
        slot = [sabr videoSegmentStart:(index + 1)];
    }

    /**
     * Ждём, пока подача принесёт фрагмент, покрывающий это время.
     *
     * Именно время, а не номер. Раньше кусок с номером N требовал
     * фрагмента с номером N+1 — и на коротком ролике это сходилось,
     * а на длинном расходилось тем сильнее, чем дальше от начала:
     * к четырёхсотой секунде десятиминутного ролика разница доходила
     * до полуминуты. Плеер просил кусок сорок четвёртый, мы ждали
     * фрагмент сорок пятый, сервер на просьбу «дай с 235-й секунды»
     * присылал сорок шестой и следующие — и нужного не приходило
     * никогда. В журнале это «Подача не дала кусок 44», а на экране —
     * перемотка, возвращающая в начало: первый прыжок ещё попадал,
     * второй уже нет.
     */
    NSInteger found = 0;

    for (NSInteger attempt = 0; attempt < 6; attempt++) {
        if (mapped || [sabr liveMode]) {
            found = ([sabr videoSegment:sequence] != nil) ? sequence : 0;
        } else {
            found = [self videoSequenceAt:slot in:sabr];
        }

        if (found != 0) {
            break;
        }

        /**
         * Просим не только с нужного мига, но и раньше него.
         *
         * Бывает, что на просьбу «дай с 96-й секунды» сервер отвечает
         * вовсе пустотой — ни фрагмента, ни отказа, только правила
         * следующего запроса. Так было у одного из тестеров: два пустых
         * ответа подряд, «Подача не дала кусок 18», перемотка встала.
         * Отступ на шаг-другой назад сдвигает начало отдачи, и нужный
         * фрагмент приезжает вместе с соседями.
         */
        /**
         * У эфира сборка не правит подачу — просит одна качалка.
         *
         * Всё, что ниже, — приёмы для записи: отступить на шаг назад,
         * начать ряд заново, подождать живого края. Трансляции они
         * не лечат, а калечат: каждый отступ читался подачей как прыжок
         * в прошлое и сбрасывал набранное, вместе с ним рушилось окно
         * плейлиста, плеер просил старые куски — и круг замыкался.
         * Ровно это и стоит в журнале: три «набранное сброшено» подряд,
         * а между ними наше же «спускаемся сами» до 240p.
         *
         * Ждать здесь тоже нечего: ожидание было снаружи, до замка.
         */
        /**
         * У эфира ждём: отказать плееру нельзя ни в одном сегменте.
         *
         * Прежде здесь стоял безусловный `break` — одна попытка, и если
         * куска нет, плееру уходила пустота. Журнал 55 показал цену:
         * после такого отказа AVPlayer **перестаёт запрашивать плейлист
         * вовсе**. В 10:42:04 отдан последний сегмент, и за следующие две
         * минуты ни одного обращения к списку — при том что подача к
         * 10:44:22 уже была здорова (отставание минус пять, набранное
         * растёт). Показ лежал мёртвым рядом с работающей подачей.
         *
         * Поэтому ждём, пока качалка донесёт: полсекунды на попытку,
         * шесть попыток — три секунды. Это много меньше того, что плеер
         * терпит, и несравнимо дешевле его отказа.
         */
        if ([sabr liveMode]) {
            [NSThread sleepForTimeInterval:0.5];

            continue;
        }

        NSTimeInterval ask = slot - (NSTimeInterval)MAX(0, attempt - 1) * _sabrStep;

        if (ask < 0) {
            ask = 0;
        }

        /**
         * Второй заход — с чистого листа.
         *
         * Первый мог уйти впустую: сервер шлёт лишь то, чего у нас,
         * по его сведениям, нет, а сведения эти мы сообщаем сами. Кусок,
         * однажды полученный и потом выброшенный из памяти, для сервера
         * остаётся у нас — и на просьбу он отвечает пустотой.
         *
         * Так и выглядел повтор вертикального ролика: куски с нулевого
         * по десятый «не дала подача», а игрались только последние два —
         * те, что ещё лежали в памяти.
         */
        if (attempt == 1) {
            [sabr rewindTo:ask];
        }

        /**
         * У эфира не торопим сервер: ждём, пока кусок снимут.
         *
         * Сервер в каждом ответе говорит, докуда снята трансляция.
         * Просить дальше этого места бессмысленно — ответ придёт пустой,
         * а после нескольких пустых источник счёл бы кусок потерянным
         * и перешагнул через него: картинка дёргалась бы на ровном месте.
         *
         * Подождав, всё равно спрашиваем: край обновляется только
         * ответом, и молчаливое ожидание превратилось бы в вечное.
         */
        NSTimeInterval head = [sabr liveHeadSeconds];

        if ([sabr liveMode] && head > 0 && ask > head) {
            NSTimeInterval wait = MIN(ask - head, 5.0);

            NSLog(@"[YouTube/Прокси] Эфир: %.0f с ещё не снято (край %.0f) — "
                  @"ждём %.0f с", ask, head, wait);

            [NSThread sleepForTimeInterval:wait];
        }

        BOOL got = [sabr requestMoreFrom:ask];

        /**
         * Нужное могло приехать и не нашим запросом.
         *
         * Плеер просит куски внахлёст, и соседний поток мог получить
         * этот фрагмент раньше — тогда наш ответ пуст, а фрагмент есть.
         * Без этой проверки мы честно ждали четверть секунды впустую,
         * и в журнале появлялось «подача промолчала» там, где всё как раз
         * пришло.
         */
        BOOL here = mapped
            ? ([sabr videoSegment:sequence] != nil)
            : ([self videoSequenceAt:slot in:sabr] != 0);

        if (got || here) {
            continue;
        }

        /**
         * Сервер мог не отказать, а попросить обновиться.
         *
         * Просьба «возьми ответ /player заново» приходит вместо медиа, и
         * пока её не выполнят, подача не даст ни байта: сколько ни
         * спрашивай, ответы будут пустыми. Снаружи это встающий посреди
         * ролика плеер — ровно то, что было в журнале у одного из
         * проверявших: полминуты игралось, потом пошли «подача
         * промолчала» подряд и перемотки без ответа по десять секунд.
         *
         * Обновление стоит одного обращения к `/player`, поэтому пробуем
         * сразу и без паузы: удалось — следующий круг спросит уже по
         * свежему адресу.
         */
        if ([sabr needsReload] && [YTStreams renewSabr:sabr]) {
            continue;
        }

        /**
         * Пустой ответ — не приговор. Сервер вправе попросить подождать,
         * и просьба лежит в правилах следующего запроса; своей же
         * догадкой в четверть секунды пользуемся, когда он молчит.
         *
         * Без этой паузы два повтора уходили подряд за полторы десятых
         * секунды, получали ту же пустоту, и перемотка не доезжала:
         * «Подача не дала кусок 63».
         */
        NSTimeInterval pause = MAX(0.25, [sabr backoff]);

        NSLog(@"[YouTube/Прокси] Подача промолчала — ждём %.0f мс "
              @"и спрашиваем снова (попытка %ld)",
              pause * 1000.0, (long)(attempt + 1));

        [NSThread sleepForTimeInterval:pause];

        // Сдаёмся, только если и отступы, и ожидание ничего не дали.
        if (attempt >= 4) {
            break;
        }
    }

    /**
     * Так и нет — берём ближайший, какой есть. Но пустоту не отдаём.
     *
     * У эфира ось времени наша, и что именно лежит в сегменте, плеер не
     * проверяет: он проверяет, что сегмент **есть**. Потеря пары секунд
     * содержимого не стоит ничего, а отказ стоит всего показа — см.
     * журнал 55 и ожидание выше.
     */
    if (found == 0 && [sabr liveMode]) {
        NSInteger nearest = 0;

        for (NSNumber *number in [sabr videoSequences]) {
            NSInteger candidate = [number integerValue];

            if (candidate >= sequence && (nearest == 0 || candidate < nearest)) {
                nearest = candidate;
            }
        }

        if (nearest != 0) {
            NSLog(@"[YouTube/Прокси] Эфир: куска №%ld нет — отдаём ближайший №%ld",
                  (long)sequence, (long)nearest);

            found = nearest;
        }
    }

    NSData *video = (found != 0) ? [sabr videoSegment:found] : nil;

    if (video == nil) {
        NSLog(@"[YouTube/Прокси] Подача не дала кусок %ld (время %.1f с)",
              (long)index, slot);

        /**
         * Кусок не добыт — значит, играть больше нечем.
         *
         * Плеер этого не узнаёт: мы отвечаем ему пустотой, он ждёт, и
         * снаружи это застывший кадр с перемоткой, которая не доезжает.
         * Поэтому говорим вслух — слушатель переведёт просмотр на
         * готовые адреса с того же места, а они у нас чаще всего есть:
         * лежат в том же ответе, из которого взята подача.
         *
         * Сказать полезно даже тогда, когда подача сама по себе жива:
         * дело может быть не в ней, а в том, что сервер после прыжка
         * отвечает одними правилами и куска не даёт вовсе, — на такое
         * ждать бессмысленно.
         */
        /**
         * У эфира на готовые адреса не уходим — там смерть.
         *
         * Для записи это разумный запасной путь: те же дорожки лежат
         * прямыми ссылками в том же ответе. У трансляции их нет —
         * журнал 53, 09:24:19: «Подача потеряна — доигрываем готовыми
         * адресами», и сразу за этим «Заголовок видеодорожки не
         * разобран», порт поднимается заново, показ кончился. То есть
         * один неподанный сегмент убивал живой эфир целиком, при
         * живой же подаче: в тот миг буфер был ещё сорок секунд.
         *
         * У эфира пропуск одного сегмента ничего не стоит: ось времени
         * наша, список идёт дальше, качалка принесёт следующие. Поэтому
         * просто молчим и отвечаем пустотой на эту одну просьбу.
         */
        if (![sabr liveMode]) {
            [[NSNotificationCenter defaultCenter] postNotificationName:YTSabrLostNotification
                                                                object:nil];
        }

        return nil;
    }

    /**
     * Если фрагмент оказался далеко от места в плейлисте — скажем об этом.
     *
     * Небольшое расхождение неизбежно: куски плейлиста равны, фрагменты
     * нет. А вот большое означает, что подача прислала не то, и по этой
     * строке видно, насколько мы промахнулись.
     */
    if (![sabr liveMode] && fabs([sabr videoSegmentStart:found] - slot) > _sabrStep) {
        NSLog(@"[YouTube/Прокси] Кусок %ld (%.1f с) собран из фрагмента №%ld (%.1f с)",
              (long)index, slot, (long)found, [sabr videoSegmentStart:found]);
    }

    // Дальше всё считается от найденного фрагмента, а не от нашей догадки.
    sequence = found;

    /**
     * Заголовок — того фрагмента, из которого собираем, а не последний
     * пришедший.
     *
     * Сервер спускается на другую дорожку, пока плеер ещё не доиграл
     * прежнюю, и её фрагменты, собранные с новым описанием кодека,
     * рассыпались бы. Заодно запоминаем, какой дорожкой ушёл кусок, —
     * по этому плеер узнает, когда дойдёт до смены (trackChangeAt:).
     */
    NSInteger fragmentItag = [sabr videoSegmentItag:found];

    if (fragmentItag > 0 && fragmentItag != _sabrVideoInitItag) {
        YTTrackInit *own = [self parsedInitForItag:fragmentItag sabr:sabr];

        if (own != nil) {
            videoInit = own;
        }
    }

    if (fragmentItag > 0 && ![sabr liveMode]) {
        @synchronized ([YTHlsProxy class]) {
            if (_shownItags == nil) {
                _shownItags = [[NSMutableDictionary alloc] init];
            }

            [_shownItags setObject:[NSNumber numberWithInteger:fragmentItag]
                            forKey:[NSNumber numberWithInteger:index]];
        }
    }

    NSMutableArray *samples = [NSMutableArray array];

    if (![self collectData:video init:videoInit isVideo:YES into:samples]) {
        return nil;
    }

    NSUInteger videoSamples = [samples count];

    if (audioInit != nil) {
        /**
         * Окно куска. Объявленному времени верим, когда оно есть, —
         * но есть оно не всегда: у части ответов подачи заголовки
         * фрагментов приходят вовсе без времён. Тогда окно считается
         * по средней длине куска, как и всё остальное в такой ответе.
         *
         * Пустого окна быть не должно ни при каких данных: `to == from`
         * отсекает **любой** звуковой фрагмент, и кусок уходит к плееру
         * немым, ничем себя не выдав.
         */
        /**
         * Границы берутся у самого фрагмента, который мы отдаём: звук
         * должен лечь ровно под ту картинку, что в куске, а не под то
         * место плейлиста, куда она встанет.
         */
        NSTimeInterval from = [sabr videoSegmentStart:sequence];
        NSTimeInterval span = [sabr videoSegmentDuration:sequence];

        /**
         * Чего не сказала подача, скажет карта: у неё длина каждого
         * фрагмента есть всегда, а у заголовков бывает и без времён.
         */
        if (span <= 0 && [_sabrSpans count] > (NSUInteger)index) {
            span = [[_sabrSpans objectAtIndex:index] doubleValue];
        }

        if (span <= 0) {
            span = _sabrStep;
        }

        NSTimeInterval need = from + span;
        NSTimeInterval to = need;

        /**
         * Последний кусок записи забирает хвост звука целиком: за ним
         * ничего нет.
         *
         * У эфира последнего куска не бывает, а `_sabrCount` у него
         * нулевой — и это правило срабатывало на **каждом** куске:
         * в окно попадал весь звук, набранный вперёд, и следующий кусок
         * брал его же снова. Звук шёл по кругу при ровной картинке;
         * чем больше запас над плеером, тем длиннее круг. Именно так
         * и звучало после того, как запас подняли до шести кусков.
         */
        if (![sabr liveMode] && index + 1 >= _sabrCount) {
            to = HUGE_VAL;
        }

        /**
         * Ждём звук — но лишь когда по объявленным временам можно
         * судить, набран он или нет. Без времён считать нечего: ожидание
         * всё равно кончится ничем, а четыре лишних запроса к подаче
         * задержат кусок на секунды.
         */
        if ([self audioTimesKnownIn:sabr]) {
            [self waitAudio:sabr from:from to:need index:index];
        }

        /**
         * Берутся все фрагменты, которые с куском **пересекаются**,
         * а внутри них — только кадры, попавшие в его время.
         *
         * Целый фрагмент отдавать нельзя ни так, ни этак. Отдать обоим
         * соседям — звук зацикливается: он вдвое длиннее куска и играет
         * дважды подряд. Отдать одному первому — в куске оказывается
         * десять секунд звука вместо обещанных пяти с половиной, а в
         * следующем ни одной, и часы плеера уходят вперёд на разницу.
         *
         * Ровно так же поступает и обычный путь; там об этом сказано
         * в `planSegments:`.
         */
        for (NSNumber *key in [sabr audioSequences]) {
            NSInteger n = [key integerValue];

            NSTimeInterval start = [sabr audioSegmentStart:n];
            NSTimeInterval length = [sabr audioSegmentDuration:n];

            /**
             * Точка отсчёта — та, что объявила подача.
             *
             * По ней же считается и перекрытие с куском парой строк выше,
             * так что окно и кадры меряются одной меркой. Внутреннему
             * времени звукового фрагмента верить нельзя: у вертикальных
             * роликов оно отсчитано от своего начала и с видео расходится.
             */
            if (length > 0) {
                if (start + length <= from || start >= to) {
                    continue;
                }

                [self collectData:[sabr audioSegment:n]
                             init:audioInit
                          isVideo:NO
                             from:from
                               to:to
                           anchor:start
                             into:samples];

                continue;
            }

            /**
             * Времени подача не объявила — пусть фрагмент говорит за себя
             * сам. Кадры отберёт то же окно, только считанное по его
             * внутренним часам: лишнего в кусок всё равно не попадёт,
             * а немым он не уйдёт.
             */
            [self collectData:[sabr audioSegment:n]
                         init:audioInit
                      isVideo:NO
                         from:from
                           to:to
                       anchor:-1
                         into:samples];
        }
    }

    /**
     * Отданное забываем. Сегмент собран, байты фрагментов больше
     * не нужны, а весят они мегабайтами: без этого память растёт
     * до самого конца ролика и устройство снимает приложение —
     * особенно заметно на 1080p, где кусок весит под три мегабайта.
     *
     * Отступаем на кусок назад: плеер иногда просит один и тот же
     * сегмент дважды, заглянув сперва в начало.
     */
    /**
     * У эфира отступаем не на кусок, а на полминуты.
     *
     * Показ у нас идёт на минуту с лишним позади края — это и есть запас.
     * Значит между тем, что уже собрано для плеера, и тем, что качалка
     * тянет впереди, лежит десяток кусков, и выбрасывать их по одному
     * шагу позади текущего опасно: плеер иногда возвращается, а список
     * обещает сегменты заранее. Журнал 53 показал цену промаха —
     * «Подача не дала кусок 3143559», и показ кончился.
     */
    NSTimeInterval keepBack = [sabr liveMode] ? 30.0 : _sabrStep;

    [sabr forgetBefore:MAX(0.0, [sabr videoSegmentStart:sequence] - keepBack)];

    /**
     * Немой кусок — заметить сразу.
     *
     * Звук у дорожки есть, а в кусок не попало ни кадра: значит, он
     * потерялся у нас, между подачей и склейкой. Снаружи это выглядит
     * как «картинка идёт, звука нет» — и без такой строки искать
     * приходится от самого начала. Так однажды и было: подача перестала
     * объявлять время фрагментов полями 11 и 12, окно куска схлопнулось
     * в точку, и звук отсеивался целиком.
     */
    if (audioInit != nil && [samples count] == videoSamples) {
        NSLog(@"[YouTube/Прокси] Кусок %ld собран без звука: %lu кадров видео, "
              @"звуковых фрагментов под рукой %lu",
              (long)index, (unsigned long)videoSamples,
              (unsigned long)[[sabr audioSequences] count]);
    }

    /**
     * Переводим кусок на свою ось времени.
     *
     * Всё, что выше, считалось по настоящему времени трансляции — по нему
     * отбирались кадры и сходились дорожки. Плееру же отдаём своё: куски
     * подряд, от десятой секунды. Почему — сказано у `liveStartFor:span:`.
     */
    if ([sabr liveMode]) {
        NSTimeInterval real = [sabr videoSegmentStart:sequence];
        NSTimeInterval mine = [self liveStartFor:sequence
                                            span:[sabr videoSegmentDuration:sequence]];

        if (real > 0) {
            for (YTPendingSample *sample in samples) {
                uint32_t scale = sample.scale > 0 ? sample.scale : 90000;

                int64_t shift = (int64_t)((real - mine) * (double)scale);

                sample.pts = (sample.pts > (uint64_t)shift)
                    ? sample.pts - shift : 0;
                sample.dts = (sample.dts > (uint64_t)shift)
                    ? sample.dts - shift : 0;
                sample.seconds -= (real - mine);
            }
        }
    }

    return [self muxSamples:samples
                      index:index
                  videoInit:videoInit
                  audioInit:audioInit];
}

- (NSString *)openWithVideo:(YTFormat *)video audio:(YTFormat *)audio {
    [self close];

    if (video == nil || [video.url length] == 0) {
        NSLog(@"[YouTube/Прокси] Нет видеодорожки");
        return nil;
    }

    if (![self ensureListening]) {
        return nil;
    }

    // Init-сегменты: из них берутся SPS/PPS и AudioSpecificConfig.
    NSData *videoHeader = [self fetch:video.url
                           rangeStart:video.initialRangeStart
                                  end:video.initialRangeEnd];

    YTTrackInit *videoInit = [YTMp4 parseInit:videoHeader];

    if (videoInit == nil || ![videoInit isVideo]) {
        NSLog(@"[YouTube/Прокси] Заголовок видеодорожки не разобран");
        return nil;
    }

    YTTrackInit *audioInit = nil;

    if (audio != nil && [audio.url length] > 0) {
        NSData *audioHeader = [self fetch:audio.url
                               rangeStart:audio.initialRangeStart
                                      end:audio.initialRangeEnd];

        audioInit = [YTMp4 parseInit:audioHeader];

        if (audioInit == nil) {
            NSLog(@"[YouTube/Прокси] Заголовок звука не разобран — играем без звука");
        }
    }

    // Карты фрагментов.
    uint32_t videoScale = 0;

    NSData *videoIndex = [self fetch:video.url
                          rangeStart:video.indexRangeStart
                                 end:video.indexRangeEnd];

    uint64_t videoFirst = (uint64_t)[video.indexRangeEnd longLongValue] + 1;

    NSArray *videoFragments = [YTMp4 parseSidx:videoIndex
                                   firstOffset:videoFirst
                                     timescale:&videoScale];

    if ([videoFragments count] == 0 || videoScale == 0) {
        NSLog(@"[YouTube/Прокси] Карта фрагментов видео не разобрана");
        return nil;
    }

    NSArray *audioFragments = nil;
    uint32_t audioScale = 0;

    if (audioInit != nil) {
        NSData *audioIndex = [self fetch:audio.url
                              rangeStart:audio.indexRangeStart
                                     end:audio.indexRangeEnd];

        uint64_t audioFirst = (uint64_t)[audio.indexRangeEnd longLongValue] + 1;

        audioFragments = [YTMp4 parseSidx:audioIndex
                              firstOffset:audioFirst
                                timescale:&audioScale];

        if ([audioFragments count] == 0 || audioScale == 0) {
            NSLog(@"[YouTube/Прокси] Карта фрагментов звука не разобрана — играем без звука");
            audioInit = nil;
        }
    }

    NSArray *plan = [self planSegments:videoFragments
                            videoScale:videoScale
                        audioFragments:audioFragments
                            audioScale:audioScale];

    @synchronized (_lock) {
        _video = video;
        _audio = (audioInit != nil) ? audio : nil;
        _videoInit = videoInit;
        _audioInit = audioInit;
        _segments = plan;
        _session++;

        _playlist = [self buildPlaylist:plan];
    }

    NSLog(@"[YouTube/Прокси] Готово: %lu сегментов, %.0f с, %ldp%@",
          (unsigned long)[plan count], _duration, (long)video.height,
          audioInit != nil ? @"" : @", без звука");

    return [self playbackUrlWithVideo:videoInit
                                audio:audioInit
                               frames:video.fps];
}

/**
 * Раскладывает фрагменты по сегментам плейлиста.
 *
 * Границы задаёт видео: один его фрагмент — один сегмент. Звуковые
 * фрагменты по длине с ними не совпадают — у YouTube это примерно
 * десять секунд против пяти с половиной, — поэтому сегменту достаются
 * все фрагменты, которые с ним **пересекаются**, а лишнее отсекается
 * уже по отдельным кадрам в `collectData:`.
 *
 * Кадр AAC неделим, но фрагмент — нет: в нём их под полтысячи, каждый
 * по два десятка миллисекунд, и разложить их по границе видео можно
 * с точностью до кадра. Так в сегменте оказывается ровно столько
 * звука, сколько обещано в `#EXTINF`.
 *
 * Приписывать фрагмент целиком одному куску нельзя, и это стоило
 * съехавших часов: в первом куске лежало десять секунд звука вместо
 * пяти с половиной, в следующем — ни одной, и время у плеера уходило
 * вперёд ровно на эту разницу.
 */
- (NSArray *)planSegments:(NSArray *)videoFragments
               videoScale:(uint32_t)videoScale
           audioFragments:(NSArray *)audioFragments
               audioScale:(uint32_t)audioScale {
    NSMutableArray *plan = [NSMutableArray array];

    // Начала звуковых фрагментов в секундах — считаются один раз.
    NSMutableArray *audioStarts = [NSMutableArray array];

    double running = 0;

    for (YTSidxEntry *entry in audioFragments) {
        [audioStarts addObject:[NSNumber numberWithDouble:running]];
        running += (double)entry.duration / (double)audioScale;
    }

    double videoStart = 0;
    NSUInteger audioCursor = 0;

    for (YTSidxEntry *fragment in videoFragments) {
        double duration = (double)fragment.duration / (double)videoScale;
        double videoEnd = videoStart + duration;

        BOOL isLast = (fragment == [videoFragments lastObject]);

        YTSegmentPlan *segment = [[YTSegmentPlan alloc] init];

        segment.start = videoStart;
        segment.duration = duration;
        segment.isLast = isLast;
        segment.videoFragment = fragment;

        NSMutableArray *audio = [NSMutableArray array];

        /**
         * Курсор двигается только мимо тех фрагментов, что кончились
         * раньше начала куска. Фрагмент, севший на границу, нужен обоим
         * соседям — первому концом, второму началом.
         */
        while (audioCursor < [audioStarts count]) {
            double start = [[audioStarts objectAtIndex:audioCursor] doubleValue];

            YTSidxEntry *entry = [audioFragments objectAtIndex:audioCursor];

            if (start + (double)entry.duration / (double)audioScale > videoStart) {
                break;
            }

            audioCursor++;
        }

        NSUInteger scan = audioCursor;

        while (scan < [audioStarts count]) {
            double start = [[audioStarts objectAtIndex:scan] doubleValue];

            // Последний сегмент забирает весь остаток: иначе хвост звука
            // после конца видеофрагмента пропал бы.
            if (!isLast && start >= videoEnd) {
                break;
            }

            [audio addObject:[audioFragments objectAtIndex:scan]];
            scan++;
        }

        segment.audioFragments = audio;

        [plan addObject:segment];

        videoStart = videoEnd;
    }

    _duration = videoStart;

    return plan;
}

- (NSString *)buildPlaylist:(NSArray *)plan {
    double longest = 0;

    for (YTSegmentPlan *segment in plan) {
        longest = MAX(longest, segment.duration);
    }

    NSMutableString *playlist = [NSMutableString string];

    /**
     * Версия 3 — та, где длительность сегмента разрешено писать дробью.
     * Выше поднимать нечего: ничего из более новых возможностей HLS
     * мы не используем, а iOS 5 их и не понимает.
     */
    [playlist appendString:@"#EXTM3U\n"];
    [playlist appendString:@"#EXT-X-VERSION:3\n"];

    /**
     * Каждый кусок начинается сам по себе.
     *
     * У нас это правда по устройству: кусок собирается из фрагмента
     * SABR, а тот всегда открывается ключевым кадром. Заявить это
     * важно — плеер иначе считает, что войти в поток можно только
     * с начала, и отказывается вести его быстрее обычного.
     *
     * Метку понимают не все прошивки, но это неопасно: по правилам
     * HLS неизвестные строки полагается пропускать, и старые плееры
     * так и делают.
     */
    [playlist appendString:@"#EXT-X-INDEPENDENT-SEGMENTS\n"];

    [playlist appendFormat:@"#EXT-X-TARGETDURATION:%.0f\n", ceil(longest)];
    [playlist appendString:@"#EXT-X-MEDIA-SEQUENCE:0\n"];

    // Честный признак записи: без него плеер считает поток эфиром,
    // не показывает длительность и не даёт перематывать.
    [playlist appendString:@"#EXT-X-PLAYLIST-TYPE:VOD\n"];

    for (NSUInteger i = 0; i < [plan count]; i++) {
        YTSegmentPlan *segment = [plan objectAtIndex:i];

        [playlist appendFormat:@"#EXTINF:%.3f,\n", segment.duration];
        // Метка уже увеличена вызывающим — в адресах сегментов должна
        // стоять она же, иначе плеер попросит их у прошлой сессии
        // и получит «410 Gone» на первом же куске.
        [playlist appendFormat:@"/%lu/s/%lu.ts\n",
            (unsigned long)_session, (unsigned long)i];
    }

    [playlist appendString:@"#EXT-X-ENDLIST\n"];

    return playlist;
}

#pragma mark Сборка сегмента

/** Достаёт сэмплы одного фрагмента и складывает их в общий ряд. */
/**
 * Складывает сэмплы одного фрагмента; NO — фрагмент взять не удалось.
 *
 * Возвращать сюда «ну и ладно» нельзя, и это стоило обрезанного
 * воспроизведения: недокачанный кусок молча превращался в короткий
 * сегмент, плеер получал вместо полутора мегабайт двести килобайт
 * и вставал. Честный отказ лучше: плеер попросит сегмент заново.
 */
- (BOOL)collectFrom:(YTSidxEntry *)fragment
                url:(NSString *)url
               init:(YTTrackInit *)init
            isVideo:(BOOL)isVideo
               from:(NSTimeInterval)from
                 to:(NSTimeInterval)to
               into:(NSMutableArray *)samples {
    NSData *body = [self fetch:url
                          from:fragment.offset
                            to:fragment.offset + fragment.size - 1];

    return [self collectData:body
                        init:init
                     isVideo:isVideo
                        from:from
                          to:to
                        into:samples];
}

/**
 * Разбирает готовый фрагмент и складывает его сэмплы.
 *
 * Отделено от выкачивания намеренно: те же фрагменты приходят и подачей
 * SABR, уже в руках, — и разбирать их надо тем же кодом, а не вторым
 * его списком.
 */
- (BOOL)collectData:(NSData *)body
               init:(YTTrackInit *)init
            isVideo:(BOOL)isVideo
               into:(NSMutableArray *)samples {
    return [self collectData:body
                        init:init
                     isVideo:isVideo
                        from:-HUGE_VAL
                          to:HUGE_VAL
                        into:samples];
}

/**
 * То же, но берёт лишь кадры, попавшие в окно `[from, to)`.
 *
 * Окно задаёт кусок плейлиста. Звуковой фрагмент вдвое длиннее куска
 * и почти всегда лежит сразу в двух — целиком его отдавать нельзя
 * ни первому, ни второму: в первом случае звук играет дважды,
 * во втором часы плеера уходят вперёд на лишнее время.
 *
 * Границы бесконечны, когда окно не нужно: у видео фрагмент и кусок
 * это одно и то же, резать нечего.
 */
- (BOOL)collectData:(NSData *)body
               init:(YTTrackInit *)init
            isVideo:(BOOL)isVideo
               from:(NSTimeInterval)from
                 to:(NSTimeInterval)to
               into:(NSMutableArray *)samples {
    return [self collectData:body
                        init:init
                     isVideo:isVideo
                        from:from
                          to:to
                      anchor:-1
                        into:samples];
}

/**
 * То же, но время кадров отсчитывается от `anchor`, а не от того, что
 * записано внутри фрагмента.
 *
 * Понадобилось из-за подачи. Она объявляет начало каждого фрагмента
 * отдельно, в заголовке, — и у звука это объявленное время **не совпадает**
 * с `baseMediaDecodeTime` внутри самого фрагмента: у вертикальных роликов
 * звуковая дорожка приходит со своей точкой отсчёта, отстоящей от видео
 * на часы. Окно куска считается по объявленному времени, а кадры
 * отбирались по внутреннему — и не совпадал ни один: в журнале это
 * «звук 0 кадров» при живых, разобранных фрагментах.
 *
 * Отрицательный `anchor` означает «верить фрагменту» — так работает видео,
 * у которого оба времени сходятся.
 */
- (BOOL)collectData:(NSData *)body
               init:(YTTrackInit *)init
            isVideo:(BOOL)isVideo
               from:(NSTimeInterval)from
                 to:(NSTimeInterval)to
             anchor:(NSTimeInterval)anchor
               into:(NSMutableArray *)samples {
    if ([body length] == 0) {
        return NO;
    }

    YTFragment *parsed = [YTMp4 parseFragment:body init:init];

    if (parsed == nil) {
        NSLog(@"[YouTube/Прокси] Фрагмент не разобран (%@)", isVideo ? @"видео" : @"звук");
        return NO;
    }

    const uint8_t *bytes = [body bytes];
    NSUInteger length = [body length];

    uint32_t scale = init.timescale > 0 ? init.timescale : 90000;
    uint64_t time = parsed.baseMediaDecodeTime;

    /**
     * Сказано, где фрагмент лежит на общей оси, — верим сказанному.
     *
     * Внутреннее время при этом не выбрасывается: от него по-прежнему
     * считаются длительности кадров, меняется только точка отсчёта.
     */
    if (anchor >= 0) {
        time = (uint64_t)(anchor * (double)scale);
    }

    for (YTSample *sample in parsed.samples) {
        NSUInteger start = parsed.dataOffset + sample.offset;

        if (start + sample.size > length) {
            break;
        }

        double seconds = (double)time / (double)scale;

        // Не в окне — пропускаем, но время всё равно двигаем: оно
        // отмеряется от начала фрагмента подряд, без пропусков.
        if (seconds < from || seconds >= to) {
            time += sample.duration;

            continue;
        }

        YTPendingSample *pending = [[YTPendingSample alloc] init];

        pending.data = [NSData dataWithBytes:bytes + start length:sample.size];
        pending.dts = time;
        pending.scale = scale;

        /**
         * Время показа — это время декодирования плюс сдвиг из `trun`.
         * Сдвиг знаковый и может быть отрицательным; на самом первом кадре
         * это дало бы отрицательное время показа, чего в PES не выразить,
         * поэтому ниже нуля не опускаемся.
         */
        int64_t presentation = (int64_t)time + sample.compositionOffset;

        pending.pts = presentation > 0 ? (uint64_t)presentation : 0;
        pending.isVideo = isVideo;
        pending.keyframe = sample.isSync;
        pending.seconds = seconds;

        [samples addObject:pending];

        time += sample.duration;
    }

    return YES;
}

/**
 * Собирает сегмент по **снимку** состояния, а не по полям объекта.
 *
 * Это не педантизм. Поля `_video`, `_videoInit` и прочие заменяются под
 * замком в `openWithVideo:` — при смене качества, при переходе к другому
 * ролику. А сборка идёт на своём потоке и читала их напрямую: если
 * замена случалась посередине, сборка брала адрес от одной дорожки
 * и описание от другой либо натыкалась на уже обнулённое.
 *
 * Наружу это выходило пустым сегментом: скачать и разобрать нечего,
 * ошибок при этом никаких — просто ноль сэмплов. Плеер получал годный
 * ответ без единого кадра и вставал насовсем, пока его не пересоздать.
 * В журнале это видно строками «Сегмент N: 0 КБ».
 */
- (NSData *)buildSegment:(YTSegmentPlan *)plan
                   index:(NSInteger)index
                   video:(YTFormat *)video
                   audio:(YTFormat *)audio
               videoInit:(YTTrackInit *)videoInit
               audioInit:(YTTrackInit *)audioInit {
    if (video == nil || videoInit == nil) {
        NSLog(@"[YouTube/Прокси] Сегмент %ld: поток уже закрыт", (long)index);
        return nil;
    }

    NSMutableArray *samples = [NSMutableArray array];

    if (![self collectFrom:plan.videoFragment
                       url:video.url
                      init:videoInit
                   isVideo:YES
                      from:-HUGE_VAL
                        to:HUGE_VAL
                      into:samples]) {
        NSLog(@"[YouTube/Прокси] Сегмент %ld: видео не забралось", (long)index);

        return nil;
    }

    if (audioInit != nil && audio != nil) {
        // Последний кусок забирает хвост целиком: за ним ничего нет.
        NSTimeInterval to = plan.isLast ? HUGE_VAL : plan.start + plan.duration;

        for (YTSidxEntry *fragment in plan.audioFragments) {
            if (![self collectFrom:fragment
                               url:audio.url
                              init:audioInit
                           isVideo:NO
                              from:plan.start
                                to:to
                              into:samples]) {
                NSLog(@"[YouTube/Прокси] Сегмент %ld: звук не забрался", (long)index);

                return nil;
            }
        }
    }

    return [self muxSamples:samples
                      index:index
                  videoInit:videoInit
                  audioInit:audioInit];
}

/**
 * Укладывает сэмплы по времени и перекладывает в TS.
 *
 * Общая часть для обоих путей: фрагменты могут прийти хоть из сети
 * диапазонами, хоть подачей — дальше с ними делают одно и то же.
 */
- (NSData *)muxSamples:(NSMutableArray *)samples
                 index:(NSInteger)index
             videoInit:(YTTrackInit *)videoInit
             audioInit:(YTTrackInit *)audioInit {
    if ([samples count] == 0) {
        NSLog(@"[YouTube/Прокси] Сегмент %ld: ни одного сэмпла", (long)index);
        return nil;
    }

    /**
     * Сэмплы обеих дорожек укладываются вперемешку, по возрастанию времени.
     *
     * Сложить сначала всё видео, а потом весь звук было бы проще, но тогда
     * плееру пришлось бы держать в буфере целый сегмент, прежде чем он
     * получит первый кадр звука, — а на iPhone 4 это заметная задержка
     * и лишняя память.
     */
    [samples sortUsingComparator:^NSComparisonResult(YTPendingSample *a, YTPendingSample *b) {
        if (a.seconds < b.seconds) { return NSOrderedAscending; }
        if (a.seconds > b.seconds) { return NSOrderedDescending; }

        // При равном времени первым идёт видео: декодеру полезнее получить
        // кадр вместе с наборами параметров пораньше.
        if (a.isVideo == b.isVideo) { return NSOrderedSame; }

        return a.isVideo ? NSOrderedAscending : NSOrderedDescending;
    }];

    YTTsMuxer *muxer = [[YTTsMuxer alloc] initWithVideo:videoInit audio:audioInit];

    for (YTPendingSample *sample in samples) {
        if (sample.isVideo) {
            [muxer addVideoSample:sample.data
                              pts:sample.pts
                              dts:sample.dts
                         keyframe:sample.keyframe];
        } else {
            [muxer addAudioSample:sample.data pts:sample.pts];
        }
    }

    return [muxer finish];
}

#pragma mark Прочее

/** Разобранный заголовок дорожки — один раз на дорожку. */
- (YTTrackInit *)parsedInitForItag:(NSInteger)itag sabr:(YTSabr *)sabr {
    NSNumber *key = [NSNumber numberWithInteger:itag];

    @synchronized ([YTHlsProxy class]) {
        YTTrackInit *known = [_sabrInits objectForKey:key];

        if (known != nil) {
            return known;
        }
    }

    YTTrackInit *parsed = [YTMp4 parseInit:[sabr videoInitForItag:itag]];

    if (parsed == nil || ![parsed isVideo]) {
        return nil;
    }

    @synchronized ([YTHlsProxy class]) {
        if (_sabrInits == nil) {
            _sabrInits = [[NSMutableDictionary alloc] init];
        }

        [_sabrInits setObject:parsed forKey:key];
    }

    return parsed;
}

- (NSTimeInterval)trackChangeAt:(NSTimeInterval)now {
    YTSabr *sabr = nil;
    NSArray *starts = nil;
    NSTimeInterval step = 0;

    @synchronized (_lock) {
        sabr = _sabr;
        starts = _sabrStarts;
        step = _sabrStep;
    }

    if (sabr == nil) {
        return -1;
    }

    /**
     * У эфира — как было: перезавод по приходу новой дорожки.
     *
     * Ось времени там своя, запас короткий, и новая дорожка доходит
     * до показа за считанные секунды.
     */
    if ([sabr liveMode]) {
        return [sabr takeVideoTrackChanged] ? now : -1;
    }

    // Сигнал о приходе у записи не нужен — снимаем, чтобы не копился.
    [sabr takeVideoTrackChanged];

    // Какой кусок сейчас на экране.
    NSInteger index = -1;

    if ([starts count] > 0) {
        for (NSUInteger i = 0; i < [starts count]; i++) {
            if ([[starts objectAtIndex:i] doubleValue] > now + 0.05) {
                break;
            }

            index = (NSInteger)i;
        }
    } else if (step > 0) {
        index = (NSInteger)floor(now / step);
    }

    if (index < 0) {
        return -1;
    }

    NSInteger first = index;
    NSInteger itag = 0;
    NSInteger was = 0;

    @synchronized ([YTHlsProxy class]) {
        itag = [[_shownItags objectForKey:[NSNumber numberWithInteger:index]] integerValue];

        if (itag == 0 || itag == _shownItag) {
            return -1;
        }

        was = _shownItag;
        _shownItag = itag;

        // Первый кусок показа — дорожку просто запоминаем.
        if (was == 0) {
            return -1;
        }

        while (first > 0 &&
               [[_shownItags objectForKey:[NSNumber numberWithInteger:first - 1]] integerValue] == itag) {
            first--;
        }
    }

    NSTimeInterval boundary = ([starts count] > (NSUInteger)first)
        ? [[starts objectAtIndex:(NSUInteger)first] doubleValue]
        : (NSTimeInterval)first * step;

    /**
     * Дошли своим ходом — граница только что позади, с неё и играем.
     * Попали перемоткой в середину чужого участка — играем, где попали:
     * отбросить к его началу значило бы отменить перемотку.
     */
    NSTimeInterval from = (now - boundary <= 2.0) ? boundary : now;

    NSLog(@"[YouTube/Прокси] Показ дошёл до дорожки %ld (была %ld) на куске %ld — "
          @"перезавод с %.1f с", (long)itag, (long)was, (long)first, from);

    return from;
}

- (BOOL)stepDownVideo {
    YTSabr *sabr = nil;
    BOOL live = NO;

    @synchronized (_lock) {
        sabr = _sabr;
        live = _sabrLive;
    }

    /**
     * У трансляции по заминке вниз не спускаемся.
     *
     * Запас у эфира короткий по устройству — полтора-два куска, больше
     * взять неоткуда, — и всякая заминка выглядит как «набор
     * не поспевает». Прежде это принималось за медленную сеть, и показ
     * за полминуты уезжал с 720p до 240p, хотя куски шли ровно
     * и вовремя: стояло у нас другое. Разрешение при этом менялось
     * посреди плейлиста, и плеер начинал показ заново.
     *
     * Эфир лечится ожиданием, а не качеством: качалка догонит край
     * сама. Человек, если захочет, сменит качество руками.
     */
    if (live) {
        return NO;
    }

    return sabr != nil ? [sabr stepDownVideo] : NO;
}

- (BOOL)refusedByAddress {
    @synchronized (_lock) {
        return _refusedByAddress;
    }
}

- (NSTimeInterval)duration {
    return _duration;
}

- (void)close {
    // Признак эфира не должен пережить смену ролика.
    _sabrLive = NO;
    _liveTimeline = nil;
    _liveClock = 0;
    _liveLines = nil;
    _liveFirst = 0;
    _liveLast = 0;
    _liveLongest = 0;
    _liveServed = 0;

    @synchronized (_lock) {
        // Метка меняется — прежний плеер, если он ещё просит сегменты,
        // получит «410 Gone» вместо кусков нового ролика.
        _session++;

        _video = nil;
        _audio = nil;
        _videoInit = nil;
        _audioInit = nil;
        _segments = nil;
        _playlist = nil;
        _duration = 0;

        /**
         * Способ обновить ссылки принадлежит закрытому ролику и вместе
         * с ним уходит: иначе следующий отказ 403 — пусть даже у подачи
         * SABR, где ссылок вовсе нет, — спросил бы `/player` о прошлом
         * ролике и подставил его дорожки.
         */
        _urlRefresher = nil;
        _refreshedAt = 0;
        _staleVideoUrl = nil;
        _staleAudioUrl = nil;

        _lastSegment = nil;
        _lastSegmentIndex = -1;

        _relay = nil;
        _sabr = nil;
        _sabrVideoInit = nil;
        _sabrVideoInitItag = 0;
        _sabrAudioInit = nil;
        _sabrCount = 0;

        // Карта принадлежит закрытому ролику — у следующего своя.
        _sabrStarts = nil;
        _sabrSpans = nil;

        @synchronized ([YTHlsProxy class]) {
            _shownItags = nil;
            _shownItag = 0;
            _sabrInits = nil;
        }

        /**
         * Метка передачи двигается вместе со всем остальным.
         *
         * Без этого переход к другому ролику оставлял прежнюю передачу
         * работать: адрес она взяла в самом начале, себе в переменную,
         * и об отмене узнать ей неоткуда. В живом прогоне это выглядело
         * так, что куски первого ролика продолжали качаться, пока идёт
         * второй, — и оба делили канал.
         */
        _relayTicket++;
        _relayTotal = 0;
        _explained = NO;
        _refusedByAddress = NO;
    }
}

@end
