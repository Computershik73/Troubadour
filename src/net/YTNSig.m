#import "YTNSig.h"

#import <UIKit/UIKit.h>

#import "YTHttp.h"
#import "YTPlayerJs.h"
#import "YTUtil.h"

/** Имена, под которыми прежняя версия хранила вырезанную функцию. */
static NSString *const YTNSigOldCodeKey = @"YTNSigCode";
static NSString *const YTNSigOldPlayerKey = @"YTNSigPlayer";

static NSString *const YTNSigUserAgent =
    @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
    @"Chrome/124.0.0.0 Safari/537.36";

/** Известная строка для проверки, что решатель и канал исправны. */
static NSString *const YTNSigSample = @"DhpWuaCJRFiGbHK";

/**
 * Сколько ждать готовности, если подготовка ещё идёт.
 *
 * На iPad 1 решатель поднимается десять-тринадцать секунд, а ждали мы
 * двенадцать: подача уходила с нерасшифрованным `n`, сервер отвечал
 * 403, и ролик уезжал на готовые адреса (журнал 27.09.2026, 12:04:28 —
 * запрос подачи, 12:04:29 — решатель готов). Там ждём дольше.
 */
static NSTimeInterval YTNSigReadyWait(void) {
    return YTTightMemory() ? 30.0 : 12.0;
}

/** Сколько ждать отчёта решателя, прежде чем счесть подготовку неудавшейся. */
static const NSTimeInterval YTNSigBootTimeout = 60.0;

/**
 * Основание 64 своими руками: `base64EncodedStringWithOptions:` появился
 * в iOS 7, а нижняя граница у нас 5.1.
 */
static NSString *YTNSigBase64(NSData *data) {
    static const char table[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    const uint8_t *bytes = [data bytes];
    NSUInteger length = [data length];
    NSMutableData *out = [NSMutableData dataWithLength:((length + 2) / 3) * 4];
    char *dest = [out mutableBytes];
    NSUInteger o = 0;

    for (NSUInteger i = 0; i < length; i += 3) {
        uint32_t chunk = (uint32_t)bytes[i] << 16;

        if (i + 1 < length) {
            chunk |= (uint32_t)bytes[i + 1] << 8;
        }

        if (i + 2 < length) {
            chunk |= (uint32_t)bytes[i + 2];
        }

        dest[o++] = table[(chunk >> 18) & 63];
        dest[o++] = table[(chunk >> 12) & 63];
        dest[o++] = (i + 1 < length) ? table[(chunk >> 6) & 63] : '=';
        dest[o++] = (i + 2 < length) ? table[chunk & 63] : '=';
    }

    return [[NSString alloc] initWithBytes:dest length:o encoding:NSASCIIStringEncoding];
}

@interface YTNSig () <UIWebViewDelegate>
@end

@implementation YTNSig {
    UIWebView *_web;

    BOOL _started;
    BOOL _ready;
    BOOL _loaded;

    /** Сборка плеера, под которую идёт или закончилась подготовка. */
    NSString *_preparedFor;

    /** Подготовка закончилась — удачей или нет; по нему ждут в `transform:`. */
    dispatch_group_t _settled;
    BOOL _pending;

    /**
     * Готовые ответы: `n` → [сборка плеера, ответ].
     *
     * Один и тот же `n` при открытии ролика расшифровывается десяток раз
     * (по разу на каждую дорожку), а после выгрузки решателя (см.
     * releaseHeavy) ради уже известного ответа поднимать его незачем.
     */
    NSMutableDictionary *_answers;

    /**
     * До какого мига решатель нужен — выгружать его раньше нельзя.
     *
     * Подъём решателя сам по себе тянет память, и на iPad 1 просьба
     * системы приходит сразу за ним. Выгрузка по ней уносила решатель
     * за миг до расшифровки: журнал 27.09.2026 — «готово» в 12:31:57.27,
     * выгружен в 12:31:57.38, «`n` не расшифрован» в 12:31:57.42, отказ
     * 403 и готовые адреса вместо подачи.
     */
    NSTimeInterval _busyUntil;
}

/** Сколько решатель считается нужным после подъёма и после расшифровки. */
static const NSTimeInterval YTNSigBusySpan = 20.0;

+ (YTNSig *)shared {
    static YTNSig *shared = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{ shared = [[YTNSig alloc] init]; });

    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _settled = dispatch_group_create();

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(releaseHeavy)
                                                     name:YTReleaseHeavyNotification
                                                   object:nil];
    }

    return self;
}

/**
 * Память кончается — решатель выгружается.
 *
 * Веб-вид решателя держит весь скрипт плеера, исполненный целиком: два
 * с половиной мегабайта исходника и всё, что движок JavaScript из них
 * построил. На iPad 1 (256 МБ на всё) это одна из самых крупных частей
 * приложения, а нужен он только в миг расшифровки нового адреса —
 * всё остальное время он просто лежит. Журнал 27.09.2026: решатель
 * поднялся, полторы минуты пролежал без дела, система дважды попросила
 * памяти, ничего не получила — и сняла приложение при выходе плеера
 * из полноэкранного режима.
 *
 * Поднимается заново сам, при следующей расшифровке: скрипт лежит
 * в кеше на диске, сеть не нужна. Идущую подготовку не трогаем.
 */
- (void)releaseHeavy {
    if (_web == nil) {
        return;
    }

    NSTimeInterval wait;

    @synchronized (self) {
        wait = _busyUntil - [NSDate timeIntervalSinceReferenceDate];
    }

    if (wait > 0) {
        NSLog(@"[YouTube/Ключ] Памяти мало, но решатель нужен прямо сейчас — выгрузим через %.0f с",
              wait);

        [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                 selector:@selector(releaseHeavy)
                                                   object:nil];

        [self performSelector:@selector(releaseHeavy) withObject:nil afterDelay:wait + 0.5];

        return;
    }

    @synchronized (self) {
        if (_pending) {
            return;
        }

        _started = NO;
        _ready = NO;
    }

    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(bootTimedOut)
                                               object:nil];

    UIWebView *web = _web;

    _web = nil;
    _loaded = NO;

    [web setDelegate:nil];
    [web stopLoading];

    // Пустая страница — чтобы движок отпустил скрипт, не дожидаясь,
    // когда веб-вид дойдёт до освобождения.
    [web loadHTMLString:@"" baseURL:nil];
    [web removeFromSuperview];

    NSLog(@"[YouTube/Ключ] Решатель выгружен, поднимем, когда понадобится (занято %.0f МБ)",
          YTResidentMegabytes());
}

- (void)streamStarted {
    @synchronized (self) {
        _busyUntil = 0;
    }

    if (!YTTightMemory()) {
        return;
    }

    YTMain(^{
        if (_web == nil) {
            return;
        }

        NSLog(@"[YouTube/Ключ] Ролик пошёл — решатель больше не нужен, с памятью тесно");

        [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                 selector:@selector(releaseHeavy)
                                                   object:nil];

        // Пара секунд — на расшифровку, если она ещё не дошла до конца.
        [self performSelector:@selector(releaseHeavy) withObject:nil afterDelay:2.0];
    });
}

- (void)streamOpening {
    if (!YTTightMemory()) {
        return;
    }

    @synchronized (self) {
        _busyUntil = 0;
    }

    YTMain(^{
        if (_web == nil) {
            return;
        }

        NSLog(@"[YouTube/Ключ] Плеер поднимается — решатель уходит, с памятью тесно");

        [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                 selector:@selector(releaseHeavy)
                                                   object:nil];

        [self releaseHeavy];
    });
}

#pragma mark Подготовка

- (void)prepare {
    [self prepareForced:NO];
}

- (void)prepareForced:(BOOL)force {
    @synchronized (self) {
        if (_started && !force) {
            // Уже поднят или поднимается — зовут, значит, скоро понадобится.
            NSTimeInterval soon = [NSDate timeIntervalSinceReferenceDate] + YTNSigBusySpan;

            if (_ready && _busyUntil < soon) {
                _busyUntil = soon;
            }

            return;
        }

        _started = YES;
        _ready = NO;

        if (!_pending) {
            _pending = YES;
            dispatch_group_enter(_settled);
        }
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSString *player = [YTPlayerJs playerId];

        if ([player length] == 0) {
            [self finish:nil line:@"[YouTube/Ключ] Сборка плеера неизвестна — расшифровка `n` не добыта"];

            return;
        }

        @synchronized (self) {
            _preparedFor = player;
        }

        NSData *script = [self obtainScript:player];

        if ([script length] == 0) {
            [self finish:player line:@"[YouTube/Ключ] Расшифровка `n` не добыта"];

            return;
        }

        NSString *solver = [self solverText];

        if ([solver length] == 0) {
            [self finish:player line:@"[YouTube/Ключ] Решатель не прочитался из пакета"];

            return;
        }

        NSString *payload = YTNSigBase64(script);

        YTMain(^{ [self install:solver payload:payload]; });
    });
}

/**
 * Подготовка закончилась. `_ready` к этому моменту уже выставлен,
 * если удалась; здесь только отпускаем ждущих и пишем строку.
 */
- (void)finish:(NSString *)player line:(NSString *)line {
    if (line != nil) {
        NSLog(@"%@", line);
    }

    @synchronized (self) {
        if (player == nil) {
            // Сборку не узнали — следующий вызов попробует снова.
            _started = NO;
        }

        if (_pending) {
            _pending = NO;
            dispatch_group_leave(_settled);
        }
    }
}

/** Текст решателя из пакета. */
- (NSString *)solverText {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"nsig" ofType:@"js"];

    if (path == nil) {
        return nil;
    }

    return [NSString stringWithContentsOfFile:path
                                     encoding:NSUTF8StringEncoding
                                        error:NULL];
}

- (NSString *)scriptPath:(NSString *)player {
    NSString *directory = [NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES) lastObject];

    return [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"player-%@.js", player]];
}

/**
 * Скрипт плеера — из кеша либо из сети.
 *
 * Берётся сборка TV-плеера: именно на неё ссылается страница `/tv`,
 * откуда мы узнаём номер, и она на полмегабайта легче обычной.
 * Если её не отдали — обычная, из которой берётся `signatureTimestamp`.
 * Расшифровка `n` в них одна и та же.
 */
- (NSData *)obtainScript:(NSString *)player {
    NSString *path = [self scriptPath:player];
    NSData *stored = [NSData dataWithContentsOfFile:path];

    if ([stored length] > 0) {
        NSLog(@"[YouTube/Ключ] Скрипт плеера %@ прочитан из кеша (%lu КБ)",
              player, (unsigned long)([stored length] / 1024));

        return stored;
    }

    NSArray *addresses = @[
        [NSString stringWithFormat:
            @"https://www.youtube.com/s/player/%@/tv-player-ias.vflset/tv-player-ias.js",
            player],
        [NSString stringWithFormat:
            @"https://www.youtube.com/s/player/%@/player_ias.vflset/en_US/base.js",
            player],
    ];

    for (NSString *address in addresses) {
        NSMutableURLRequest *request =
            YTRequest(address, NSURLRequestUseProtocolCachePolicy, 60.0);

        if (request == nil) {
            continue;
        }

        [request setValue:YTNSigUserAgent forHTTPHeaderField:@"User-Agent"];
        [request setHTTPShouldHandleCookies:NO];

        YTHttpResponse *response = [YTHttp send:request bodyLimit:0 caching:NO];

        if (![response isSuccessful] || [response.body length] == 0) {
            NSLog(@"[YouTube/Ключ] Скрипт плеера не прочитался: код %ld",
                  (long)response.statusCode);

            continue;
        }

        NSLog(@"[YouTube/Ключ] Скрипт плеера %@ скачан (%lu КБ)",
              player, (unsigned long)([response.body length] / 1024));

        [self store:response.body player:player];

        return response.body;
    }

    return nil;
}

/** Кладёт скрипт в кеш и убирает скрипты прежних сборок. */
- (void)store:(NSData *)body player:(NSString *)player {
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *path = [self scriptPath:player];
    NSString *directory = [path stringByDeletingLastPathComponent];

    for (NSString *name in [files contentsOfDirectoryAtPath:directory error:NULL]) {
        if ([name hasPrefix:@"player-"] && [name hasSuffix:@".js"]) {
            [files removeItemAtPath:[directory stringByAppendingPathComponent:name]
                              error:NULL];
        }
    }

    if (![body writeToFile:path atomically:YES]) {
        NSLog(@"[YouTube/Ключ] Скрипт плеера не сохранился");
    }

    // Остатки прежнего способа — вырезанная функция в настройках.
    NSUserDefaults *settings = [NSUserDefaults standardUserDefaults];

    [settings removeObjectForKey:YTNSigOldCodeKey];
    [settings removeObjectForKey:YTNSigOldPlayerKey];
}

/**
 * Заводит веб-вид и загружает в него страницу с решателем и скриптом
 * плеера.
 *
 * Скрипт передаётся в base64 внутри строкового литерала: так в разметку
 * не попадает ни `</script>`, ни иной знак, способный сбить разбор
 * страницы. Сам решатель запускается не отсюда, а по готовности
 * страницы — на ещё не поднятой странице исполнять нечего.
 */
- (void)install:(NSString *)solver payload:(NSString *)payload {
    _loaded = NO;

    if (_web == nil) {
        _web = [[UIWebView alloc] initWithFrame:CGRectMake(-500, -500, 100, 100)];

        [_web setHidden:YES];
        [_web setDelegate:self];

        [[[UIApplication sharedApplication] keyWindow] addSubview:_web];
    }

    NSMutableString *html = [NSMutableString stringWithCapacity:
        [solver length] + [payload length] + 256];

    [html appendString:@"<html><head><meta charset=\"utf-8\"><script>"];
    [html appendString:solver];
    [html appendString:@"</script></head><body><script>window.__p=\""];
    [html appendString:payload];
    [html appendString:@"\";</script></body></html>"];

    [_web loadHTMLString:html baseURL:[NSURL URLWithString:@"https://www.youtube.com"]];

    /**
     * Сторож: если страница так и не отчиталась — ни удачей, ни
     * отказом, — ждущие отпускаются, чтобы каждое воспроизведение
     * не простаивало по `YTNSigReadyWait`.
     */
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(bootTimedOut)
                                               object:nil];

    [self performSelector:@selector(bootTimedOut)
               withObject:nil
               afterDelay:YTNSigBootTimeout];
}

- (void)bootTimedOut {
    BOOL pending;
    NSString *player;

    @synchronized (self) {
        pending = _pending;
        player = _preparedFor;
    }

    if (pending) {
        [self finish:player line:[NSString stringWithFormat:
            @"[YouTube/Ключ] Решатель не отчитался за %.0f с", YTNSigBootTimeout]];
    }
}

/** Страница поднялась — запускаем решатель и читаем его отчёт. */
- (void)boot {
    NSString *player;

    @synchronized (self) {
        player = _preparedFor;
    }

    NSString *report = [_web stringByEvaluatingJavaScriptFromString:
        @"(function(){var r;try{r=YTSolver.bootBase64(window.__p);}"
        @"catch(e){r='решатель упал: '+e;}window.__p=null;return r;})()"];

    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(bootTimedOut)
                                               object:nil];

    if (![report hasPrefix:@"ok "]) {
        [self finish:player line:[NSString stringWithFormat:
            @"[YouTube/Ключ] Решатель не завёлся (плеер %@): %@",
            player, [report length] > 0 ? report : @"пустой отчёт"]];

        return;
    }

    /**
     * Самопроверка на известной строке — тем же путём, которым пойдут
     * настоящие значения. Тем же плеером она даёт один и тот же ответ
     * где угодно, и строку можно сверить с эталоном.
     */
    NSString *sample = [self evaluate:YTNSigSample];

    if ([sample length] == 0 || [sample isEqualToString:YTNSigSample]) {
        [self finish:player line:[NSString stringWithFormat:
            @"[YouTube/Ключ] Расшифровка не отвечает (%@)", [report substringFromIndex:3]]];

        return;
    }

    @synchronized (self) {
        _ready = YES;
        _busyUntil = [NSDate timeIntervalSinceReferenceDate] + YTNSigBusySpan;
    }

    [self finish:player line:[NSString stringWithFormat:
        @"[YouTube/Ключ] Готово: расшифровка `n` заведена, плеер %@, %@ "
        @"(проверка: %@ → %@)", player, [report substringFromIndex:3],
        YTNSigSample, sample]];
}

#pragma mark UIWebViewDelegate

- (void)webViewDidFinishLoad:(UIWebView *)webView {
    if (_loaded) {
        return;
    }

    _loaded = YES;

    NSLog(@"[YouTube/Ключ] Страница решателя поднялась");

    [self boot];
}

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error {
    NSString *player;

    @synchronized (self) {
        player = _preparedFor;
    }

    [self finish:player line:[NSString stringWithFormat:
        @"[YouTube/Ключ] Страница решателя: ошибка %@", [error localizedDescription]]];
}

#pragma mark Работа

- (BOOL)isReady {
    @synchronized (self) {
        return _ready;
    }
}

/** Строка для подстановки в JavaScript — с экранированием. */
- (NSString *)quote:(NSString *)value {
    NSString *escaped = [value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];

    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];

    return [NSString stringWithFormat:@"\"%@\"", escaped];
}

/** `YTn` на главном потоке; nil, если ответа нет. */
- (NSString *)evaluate:(NSString *)n {
    __block NSString *result = nil;

    NSString *script = [NSString stringWithFormat:
        @"(function(){try{return window.YTn(%@)||'';}catch(e){return '';}})()",
        [self quote:n]];

    dispatch_block_t work = ^{
        result = [_web stringByEvaluatingJavaScriptFromString:script];
    };

    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }

    return ([result length] > 0) ? result : nil;
}

- (NSString *)transform:(NSString *)n {
    if ([n length] == 0) {
        return nil;
    }

    NSString *player = [YTPlayerJs playerId];

    @synchronized (self) {
        NSArray *known = [_answers objectForKey:n];

        if (known != nil && [player length] > 0 &&
            [[known objectAtIndex:0] isEqualToString:player]) {
            return [known objectAtIndex:1];
        }
    }

    /**
     * Ждать можно только с фоновой очереди: главный поток — тот самый,
     * на котором страница поднимается и отчитывается.
     */
    if (![NSThread isMainThread]) {
        BOOL stale;

        @synchronized (self) {
            stale = _started && [player length] > 0 && ![player isEqualToString:_preparedFor];
        }

        if (stale) {
            NSLog(@"[YouTube/Ключ] Сборка плеера сменилась на %@ — расшифровка заново", player);
        }

        [self prepareForced:stale];

        dispatch_group_wait(_settled,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(YTNSigReadyWait() * NSEC_PER_SEC)));
    }

    if (![self isReady]) {
        return nil;
    }

    @synchronized (self) {
        _busyUntil = [NSDate timeIntervalSinceReferenceDate] + YTNSigBusySpan;
    }

    NSString *result = [self evaluate:n];

    /**
     * Выгрузили между «готово» и расшифровкой — поднимаем ещё раз
     * и пробуем снова. Один раз: второй подряд — уже не случайность.
     */
    if ([result length] == 0 && ![self isReady] && ![NSThread isMainThread]) {
        NSLog(@"[YouTube/Ключ] Решатель выгрузили посреди расшифровки — поднимаем снова");

        [self prepareForced:NO];

        dispatch_group_wait(_settled,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(YTNSigReadyWait() * NSEC_PER_SEC)));

        if ([self isReady]) {
            @synchronized (self) {
                _busyUntil = [NSDate timeIntervalSinceReferenceDate] + YTNSigBusySpan;
            }

            result = [self evaluate:n];
        }
    }

    if ([result length] > 0 && [player length] > 0) {
        @synchronized (self) {
            if (_answers == nil || [_answers count] > 64) {
                _answers = [[NSMutableDictionary alloc] init];
            }

            [_answers setObject:[NSArray arrayWithObjects:player, result, nil] forKey:n];
        }
    }

    return result;
}

- (NSString *)fixUrl:(NSString *)url {
    NSRange marker = [url rangeOfString:@"&n="];

    if (marker.location == NSNotFound) {
        return url;
    }

    NSString *tail = [url substringFromIndex:NSMaxRange(marker)];
    NSRange stop = [tail rangeOfString:@"&"];

    NSString *value = (stop.location == NSNotFound)
        ? tail : [tail substringToIndex:stop.location];

    NSString *fixed = [self transform:value];

    if ([fixed length] == 0) {
        // Без расшифровки раздача отвечает 403 — пусть это будет видно.
        NSLog(@"[YouTube/Ключ] `n` не расшифрован — решатель не готов, адрес уходит как есть");

        return url;
    }

    if ([fixed isEqualToString:value]) {
        return url;
    }

    NSLog(@"[YouTube/Ключ] `n` расшифрован: %@ → %@", value, fixed);

    return [url stringByReplacingOccurrencesOfString:
        [NSString stringWithFormat:@"&n=%@", value]
                                          withString:
        [NSString stringWithFormat:@"&n=%@", fixed]];
}

@end
