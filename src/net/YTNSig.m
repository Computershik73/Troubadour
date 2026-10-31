#import "YTNSig.h"

#import <UIKit/UIKit.h>

#import "YTHttp.h"
#import "YTJSEngine.h"
#import "YTPlayerJs.h"
#import "YTQuickJS.h"
#import "YTUtil.h"
#import "YTMemoryCensus.h"

/** Сколько подъёмов в голом JavaScriptCore подряд оборвалось на полпути. */
static NSString *const YTNSigBareInterruptedKey = @"YTNSigBareInterrupted";

/** То же для QuickJS. */
static NSString *const YTNSigQuickInterruptedKey = @"YTNSigQuickInterrupted";

/** Сборка плеера, к которой относятся эти счёты. */
static NSString *const YTNSigBarePlayerKey = @"YTNSigBarePlayer";

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

    /** Решатель в движке без веб-вида — QuickJS или JavaScriptCore (см. bootBare:). */
    id<YTScriptEngine> _js;

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

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(memoryCensus:)
                                                     name:YTMemoryCensusNotification
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
    if (![self holdsSolver]) {
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

    id<YTScriptEngine> engine = nil;

    @synchronized (self) {
        engine = _js;
        _js = nil;
    }

    /**
     * Движок отпускаем с фоновой очереди: освобождение кучи в десятки
     * мегабайт на iPad 1 занимает заметное время, а ждать его главному
     * потоку незачем.
     */
    if (engine != nil) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            [engine class];
        });
    }

    [self dropWebView];

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
        if (![self holdsSolver]) {
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
        if (![self holdsSolver]) {
            return;
        }

        NSLog(@"[YouTube/Ключ] Плеер поднимается — решатель уходит, с памятью тесно");

        [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                 selector:@selector(releaseHeavy)
                                                   object:nil];

        [self releaseHeavy];
    });
}

/** Отпускает веб-вид решателя, если он есть. Только с главного потока. */
- (void)dropWebView {
    UIWebView *web = _web;

    if (web == nil) {
        return;
    }

    @synchronized (self) {
        _web = nil;
    }

    _loaded = NO;

    [web setDelegate:nil];
    [web stopLoading];

    // Пустая страница — чтобы движок отпустил скрипт, не дожидаясь,
    // когда веб-вид дойдёт до освобождения.
    [web loadHTMLString:@"" baseURL:nil];
    [web removeFromSuperview];
}

/** Строка решателя в переписи памяти. */
- (void)memoryCensus:(NSNotification *)note {
    id<YTScriptEngine> engine;
    BOOL web;

    @synchronized (self) {
        engine = _js;
        web = (_web != nil);
    }

    NSString *state = (engine != nil) ? [engine censusNote]
                    : web ? @"в веб-виде" : @"выгружен";

    [[[note userInfo] objectForKey:YTMemoryCensusNotesKey] addObject:
        [@"решатель n " stringByAppendingString:state]];
}

/** Поднят ли решатель — в веб-виде или в движке без него. */
- (BOOL)holdsSolver {
    @synchronized (self) {
        return _web != nil || _js != nil;
    }
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

        if ([self bootBare:script solver:solver player:player]) {
            return;
        }

        NSString *payload = YTNSigBase64(script);

        YTMain(^{ [self install:solver payload:payload]; });
    });
}

/**
 * Решатель без веб-вида: сперва во встроенном QuickJS (YTQuickJS), потом
 * в голом движке системы (YTJSEngine).
 *
 * Тот же `nsig.js`, но без WebCore и без HTML-страницы: скрипт плеера идёт
 * в движок прямо из файла, без base64 и без копии в разметке. Чего плееру
 * не хватает от браузера, даёт `nsig-env.js`. На компьютере этим путём
 * три сборки плеера (67288f35, cbcfbf2f, dce23b30) дали те же ответы, что
 * веб-вид на iPad, а QuickJS — те же, что JavaScriptCore (11a45ffb).
 *
 * QuickJS первым из-за памяти: его куча в своей зоне и при выгрузке
 * возвращается вся, а у JavaScriptCore iOS 5/6 из 31 МБ возвращались 5.
 *
 * Не вышло нигде — пишем, на чём, и поднимаем веб-вид, как прежде.
 */
- (BOOL)bootBare:(NSData *)script solver:(NSString *)solver player:(NSString *)player {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"nsig-env" ofType:@"js"];
    NSString *env = (path != nil)
        ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL]
        : nil;

    if ([env length] == 0) {
        return NO;
    }

    NSUserDefaults *settings = [NSUserDefaults standardUserDefaults];

    // Счёт ведётся на сборку плеера: с новой сборкой пробуем снова.
    if (![[settings stringForKey:YTNSigBarePlayerKey] isEqualToString:player]) {
        [settings setInteger:0 forKey:YTNSigQuickInterruptedKey];
        [settings setInteger:0 forKey:YTNSigBareInterruptedKey];
        [settings setObject:player forKey:YTNSigBarePlayerKey];
    }

    BOOL booted = [self guarded:YTNSigQuickInterruptedKey name:@"QuickJS" boot:^BOOL {
        YTQuickJS *engine = [YTQuickJS engine];

        // Байткод — рядом со скриптом плеера и уходит вместе с ним (см. store:).
        [engine setBytecodePath:[[[self scriptPath:player] stringByDeletingPathExtension]
                                    stringByAppendingPathExtension:@"qjs"]];

        return [self bootBareChecked:script env:env solver:solver player:player
                              engine:engine name:@"QuickJS"];
    }];

    if (booted || ![YTJSEngine available]) {
        return booted;
    }

    return [self guarded:YTNSigBareInterruptedKey name:@"JavaScriptCore" boot:^BOOL {
        return [self bootBareChecked:script env:env solver:solver player:player
                              engine:[YTJSEngine engine] name:@"JavaScriptCore"];
    }];
}

/**
 * Страховка: подъём, оборвавшийся дважды подряд, — больше не пробуем.
 *
 * Упади движок посреди подъёма (или сними система приложение за память),
 * отметка о начатом подъёме останется, и после второго такого раза
 * решатель идёт к следующему движку, а не падает при каждом ролике.
 */
- (BOOL)guarded:(NSString *)key name:(NSString *)name boot:(BOOL (^)(void))boot {
    NSUserDefaults *settings = [NSUserDefaults standardUserDefaults];
    NSInteger interrupted = [settings integerForKey:key];

    if (interrupted >= 2) {
        static NSMutableSet *told = nil;

        @synchronized ([YTNSig class]) {
            if (told == nil) {
                told = [NSMutableSet set];
            }

            if (![told containsObject:key]) {
                [told addObject:key];

                NSLog(@"[YouTube/Ключ] Подъём в %@ дважды оборвался — обходимся без него", name);
            }
        }

        return NO;
    }

    [settings setInteger:interrupted + 1 forKey:key];
    [settings synchronize];

    BOOL booted = boot();

    // Дошли до конца сами, удачно или нет, — подъём не оборвался.
    [settings setInteger:0 forKey:key];
    [settings synchronize];

    return booted;
}

- (BOOL)bootBareChecked:(NSData *)script
                    env:(NSString *)env
                 solver:(NSString *)solver
                 player:(NSString *)player
                 engine:(id<YTScriptEngine>)engine
                   name:(NSString *)name {
    NSTimeInterval started = [NSDate timeIntervalSinceReferenceDate];
    double before = YTResidentMegabytes();

    if (engine == nil) {
        NSLog(@"[YouTube/Ключ] %@ не дал контекста", name);

        return NO;
    }

    NSString *error = nil;

    [engine evaluate:env error:&error];

    if (error == nil) {
        [engine evaluate:solver error:&error];
    }

    if (error == nil && ![engine setGlobal:@"__ytText" utf8:script]) {
        error = @"скрипт плеера не лёг в движок";
    }

    NSString *report = nil;

    if (error == nil) {
        report = [engine evaluate:
            @"(function(){var r;try{r=YTSolver.boot(__ytText);}"
            @"catch(e){r='решатель упал: '+e;}__ytText=null;return r;})()"
                            error:&error];

        // Исходник плеера и его копия с крючком больше не нужны.
        [engine collect];
    }

    if (![report hasPrefix:@"ok "]) {
        NSLog(@"[YouTube/Ключ] В %@ решатель не завёлся (плеер %@): %@",
              name, player, report ?: (error ?: @"пустой отчёт"));

        return NO;
    }

    NSString *sample = [self evaluate:YTNSigSample in:engine];

    if ([sample length] == 0 || [sample isEqualToString:YTNSigSample]) {
        NSLog(@"[YouTube/Ключ] В %@ расшифровка не отвечает (%@)",
              name, [report substringFromIndex:3]);

        return NO;
    }

    @synchronized (self) {
        _js = engine;
        _ready = YES;
        _busyUntil = [NSDate timeIntervalSinceReferenceDate] + YTNSigBusySpan;
    }

    // Веб-вид от прежней неудачи держать незачем: расшифровка теперь здесь.
    YTMain(^{ [self dropWebView]; });

    [self finish:player line:[NSString stringWithFormat:
        @"[YouTube/Ключ] Готово без веб-вида, в %@: расшифровка `n` заведена, плеер %@, %@ "
        @"(проверка: %@ → %@), за %.1f с, память %.0f → %.0f МБ",
        name, player, [report substringFromIndex:3], YTNSigSample, sample,
        [NSDate timeIntervalSinceReferenceDate] - started, before, YTResidentMegabytes()]];

    return YES;
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

/** Кладёт скрипт в кеш и убирает скрипты прежних сборок вместе с их байткодом. */
- (void)store:(NSData *)body player:(NSString *)player {
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *path = [self scriptPath:player];
    NSString *directory = [path stringByDeletingLastPathComponent];
    NSSet *kinds = [NSSet setWithObjects:@"js", @"qjs", @"part", nil];

    for (NSString *name in [files contentsOfDirectoryAtPath:directory error:NULL]) {
        if ([name hasPrefix:@"player-"] && [kinds containsObject:[name pathExtension]]) {
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
        UIWebView *web = [[UIWebView alloc] initWithFrame:CGRectMake(-500, -500, 100, 100)];

        [web setHidden:YES];
        [web setDelegate:self];

        [[[UIApplication sharedApplication] keyWindow] addSubview:web];

        // Под замком: `holdsSolver` читает его с любого потока.
        @synchronized (self) {
            _web = web;
        }
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

/** `YTn` в движке без веб-вида; nil, если ответа нет. */
- (NSString *)evaluate:(NSString *)n in:(id<YTScriptEngine>)engine {
    NSString *result = [engine evaluate:[NSString stringWithFormat:
        @"(function(){try{return window.YTn(%@)||'';}catch(e){return '';}})()",
        [self quote:n]] error:NULL];

    return ([result length] > 0) ? result : nil;
}

/** `YTn` — в движке без веб-вида, если он поднят, иначе на главном потоке в веб-виде. */
- (NSString *)evaluate:(NSString *)n {
    id<YTScriptEngine> engine = nil;

    @synchronized (self) {
        engine = _js;
    }

    if (engine != nil) {
        return [self evaluate:n in:engine];
    }

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
