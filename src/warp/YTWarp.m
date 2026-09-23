#import "YTWarp.h"

#import <UIKit/UIKit.h>
#import <libkern/OSAtomic.h>

#import "AmneziaWGManager.h"
#import "DanteFixer.h"
#import "DanteNetworkProbe.h"
#import "YTHttp.h"
#import "YTSettings.h"
#import "YTStrings.h"
#import "YTTunnelProtocol.h"

NSString *const YTWarpChangedNotification = @"YTWarpChanged";

/*
 * Сторож — числа автора Dante-WARP (DanteDaemon.m): раз в двадцать секунд,
 * перечинка после двух неудачных проверок подряд, повтор через минуту
 * после сбоя и через пять — в сети с белым списком: там до Cloudflare
 * не дотянуться, пока сеть не сменится.
 */
static const NSTimeInterval YTWarpWatchInterval = 20.0;
static const int YTWarpWatchMaxFailures = 2;
static const NSTimeInterval YTWarpRetryAfterFailure = 60.0;
static const NSTimeInterval YTWarpRetryInRestricted = 300.0;

/*
 * Предложение: столько неудач к YouTube за такое время. Одна-две — это
 * ещё не блокировка, а обычный обрыв; три подряд без единой удачи между
 * ними — уже повод спросить.
 */
static const NSUInteger YTWarpOfferFailures = 3;
static const NSTimeInterval YTWarpOfferWindow = 90.0;

/** Для перехватчика: работает ли туннель и на каком порту. */
static volatile int32_t YTWarpActiveFlag = 0;
static volatile int32_t YTWarpPortValue = 0;

/** Обход включён и подключается: перехватчик придерживает запросы. */
static volatile int32_t YTWarpConnectingFlag = 0;

/** Предлагать больше не нужно: предложили, включили или отказались. */
static volatile int32_t YTWarpOfferSettled = 0;

@interface YTWarp () <UIAlertViewDelegate>
@end

@implementation YTWarp {
    NSTimer *_watch;
    int _watchFailures;
    BOOL _watchBusy;

    /** Когда и в какой сети начали последнюю попытку. */
    NSTimeInterval _attemptAt;
    NSString *_attemptNetwork;

    DanteFixerState _lastState;

    // Предложение.
    NSUInteger _failures;
    NSTimeInterval _firstFailureAt;
    UIAlertView *_offer;

    /** Включили из предложения: сказать, если не заработает. */
    BOOL _reportOutcome;
}

+ (YTWarp *)shared {
    static YTWarp *one = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{ one = [[YTWarp alloc] init]; });

    return one;
}

#pragma mark - Запуск

+ (void)launch {
    NSLog(@"[YouTube/WARP] Обход блокировок: код Dante-WARP, "
          @"автор https://github.com/qwertyu1opz");

    [YTTunnelProtocol install];

    YTWarp *warp = [self shared];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    [center addObserver:warp
               selector:@selector(somethingChanged)
                   name:kDanteFixerDidUpdateNotification
                 object:nil];

    // Менеджер туннеля сообщает о себе со своих потоков — пересаживаемся сами.
    [center addObserver:warp
               selector:@selector(somethingChanged)
                   name:kAmneziaWGStatusDidChangeNotification
                 object:nil];

    /**
     * Вернулись из фона — проверяем туннель сразу, не дожидаясь сторожа.
     *
     * Пока приложение спало, его UDP-сокет молчал, и сервер WARP мог
     * забыть сессию. Первый же запрос тогда ушёл бы в мёртвый туннель.
     */
    [center addObserver:warp
               selector:@selector(watchTick)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];

    if ([YTSettings usesWarp]) {
        YTWarpOfferSettled = 1;

        [warp start];
    }
}

#pragma mark - Включение

+ (BOOL)isEnabled {
    return [YTSettings usesWarp];
}

+ (void)setEnabled:(BOOL)enabled {
    YTWarp *warp = [self shared];

    if (enabled == [YTSettings usesWarp]) {
        if (enabled) {
            [warp retryNow];
        }

        return;
    }

    [YTSettings setUsesWarp:enabled];

    NSLog(@"[YouTube/WARP] Обход блокировок %@", enabled ? @"включён" : @"выключен");

    if (enabled) {
        YTWarpOfferSettled = 1;

        [warp start];
    } else {
        [warp stop];
    }
}

+ (void)retry {
    [[self shared] retryNow];
}

- (void)start {
    [_watch invalidate];

    _watch = [NSTimer scheduledTimerWithTimeInterval:YTWarpWatchInterval
                                              target:self
                                            selector:@selector(watchTick)
                                            userInfo:nil
                                             repeats:YES];

    [self fix];
}

- (void)stop {
    [_watch invalidate];
    _watch = nil;

    _reportOutcome = NO;

    [[DanteFixer sharedFixer] stop];

    [self somethingChanged];
}

- (void)retryNow {
    if (![YTSettings usesWarp]) {
        return;
    }

    if ([DanteFixer sharedFixer].state == DanteFixerStateRunning) {
        return;
    }

    [self fix];
}

/**
 * Одна попытка: сеть проверить, туннель поднять, проверить его.
 *
 * Всё это делает DanteFixer автора, на своей очереди. Здесь только
 * запоминаем, когда и где пробовали, — по этому сторож решает, пора ли
 * пробовать снова.
 */
- (void)fix {
    _attemptAt = [NSDate timeIntervalSinceReferenceDate];
    _attemptNetwork = [DanteNetworkProbe networkKey];

    /**
     * На Wi-Fi не даём радио засыпать, пока идут данные, — как у автора.
     *
     * На iPhone 4 с iOS 5 энергосбережение Wi-Fi добавляет к каждому
     * ответу 50–120 мс, и видео через туннель грузится рывками. В сотовой
     * сети этого не нужно, а батарею такой пинг ест.
     */
    [AmneziaWGManager sharedManager].keepRadioAwake = ![_attemptNetwork hasPrefix:@"сотовая"];

    NSLog(@"[YouTube/WARP] Подключаю обход (сеть %@)", _attemptNetwork);

    [[DanteFixer sharedFixer] fixInternet];

    [self somethingChanged];
}

#pragma mark - Состояние

+ (BOOL)isActive {
    return YTWarpActiveFlag != 0;
}

+ (uint16_t)socksPort {
    return (uint16_t)YTWarpPortValue;
}

+ (BOOL)isConnecting {
    return YTWarpConnectingFlag != 0;
}

- (void)somethingChanged {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self somethingChanged]; });
        return;
    }

    DanteFixer *fixer = [DanteFixer sharedFixer];
    AmneziaWGManager *manager = [AmneziaWGManager sharedManager];

    BOOL active = [YTSettings usesWarp] &&
                  fixer.state == DanteFixerStateFixed &&
                  manager.isConnected && manager.socksPort > 0;

    int32_t port = active ? (int32_t)manager.socksPort : 0;

    if ((active ? 1 : 0) != YTWarpActiveFlag || port != YTWarpPortValue) {
        NSLog(@"[YouTube/WARP] %@", active
            ? [NSString stringWithFormat:@"Туннель работает, SOCKS5 127.0.0.1:%d", port]
            : @"Туннеля нет — запросы идут напрямую");
    }

    /**
     * Подключение идёт — запросы к YouTube ждут туннель.
     *
     * Напрямую они в этой сети всё равно не пройдут: каждый висел свои
     * двадцать пять секунд и падал, а туннель тем временем уже поднимался.
     */
    BOOL connecting = !active && [YTSettings usesWarp] &&
                      fixer.state == DanteFixerStateRunning;

    YTWarpPortValue = port;
    OSMemoryBarrier();
    YTWarpActiveFlag = active ? 1 : 0;
    YTWarpConnectingFlag = connecting ? 1 : 0;
    OSMemoryBarrier();

    if (fixer.state != _lastState) {
        _lastState = fixer.state;

        if (fixer.state == DanteFixerStateFixed) {
            _watchFailures = 0;
        }

        if (_reportOutcome && fixer.state == DanteFixerStateFailed) {
            _reportOutcome = NO;

            [self tellFailure:fixer.restrictedNetwork];
        } else if (fixer.state == DanteFixerStateFixed) {
            _reportOutcome = NO;
        }
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:YTWarpChangedNotification
                                                        object:nil];
}

+ (NSString *)statusText {
    if (![YTSettings usesWarp]) {
        return YTLoc(@"Выключен");
    }

    DanteFixer *fixer = [DanteFixer sharedFixer];

    switch (fixer.state) {
        case DanteFixerStateFixed:
            return [self isActive] ? YTLoc(@"Работает") : YTLoc(@"Подключаюсь…");

        case DanteFixerStateFailed:
            if (fixer.restrictedNetwork) {
                return YTLoc(@"Белый список");
            }

            // Автор так и называет этот исход (DanteFixer.m, «Нет связи»).
            if ([fixer.statusLine isEqualToString:@"Нет связи"]) {
                return YTLoc(@"Нет сети");
            }

            return YTLoc(@"Не вышло");

        default:
            return YTLoc(@"Подключаюсь…");
    }
}

#pragma mark - Сторож

/**
 * Сторож — порт watchdogTick из службы автора, без того, что нужно было
 * только ей (правила pf, utun, сканер точек входа).
 */
- (void)watchTick {
    if (![YTSettings usesWarp]) {
        return;
    }

    DanteFixer *fixer = [DanteFixer sharedFixer];

    if (fixer.state == DanteFixerStateRunning) {
        return;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    if (fixer.state == DanteFixerStateFailed || fixer.state == DanteFixerStateIdle) {
        NSString *network = [DanteNetworkProbe networkKey];

        BOOL changed = _attemptNetwork != nil && ![network isEqualToString:_attemptNetwork];

        NSTimeInterval wait = fixer.restrictedNetwork ? YTWarpRetryInRestricted
                                                      : YTWarpRetryAfterFailure;

        if (changed || now - _attemptAt >= wait) {
            NSLog(@"[YouTube/WARP] Сторож: %@ — пробую снова", changed
                ? [NSString stringWithFormat:@"сеть сменилась (%@ → %@)", _attemptNetwork, network]
                : @"прошлая попытка не удалась");

            [self fix];
        }

        return;
    }

    if (fixer.state != DanteFixerStateFixed || _watchBusy) {
        return;
    }

    /**
     * Данные идут прямо сейчас — туннель жив, пробный запрос не нужен.
     *
     * Автор пишет, почему это важно: под полной нагрузкой (видео) проба
     * не успевала, и сторож перечинивал туннель посреди просмотра.
     */
    AmneziaWGManager *manager = [AmneziaWGManager sharedManager];

    NSTimeInterval lastData = manager.lastDataAt;

    if (lastData > 0 && now - lastData < 3.0) {
        _watchFailures = 0;
        return;
    }

    _watchBusy = YES;

    uint16_t port = manager.socksPort;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL alive = port > 0 && [DanteNetworkProbe verifyTunnelOnSOCKSPort:port timeout:6.0];

        dispatch_async(dispatch_get_main_queue(), ^{
            _watchBusy = NO;

            if (fixer.state != DanteFixerStateFixed || ![YTSettings usesWarp]) {
                return;
            }

            if (alive) {
                _watchFailures = 0;

                // Менеджер мог сам переподключиться на другой порт.
                [self somethingChanged];
                return;
            }

            _watchFailures++;

            NSLog(@"[YouTube/WARP] Сторож: туннель не отвечает (%d/%d)",
                  _watchFailures, YTWarpWatchMaxFailures);

            if (_watchFailures >= YTWarpWatchMaxFailures) {
                _watchFailures = 0;

                [fixer markBroken:@"Туннель перестал отвечать — перечиниваю"];

                [self fix];
            }
        });
    });
}

#pragma mark - Маршрут

/**
 * Какие хосты идут через туннель.
 *
 * Список — авторский (AmneziaWGManager, shouldRouteTrafficForHost:), но
 * сравнение строже: у автора «google.com» совпадало и с «notgoogle.com».
 * Здесь совпадает сам домен или его поддомен.
 */
+ (BOOL)shouldRouteHost:(NSString *)host {
    if ([host length] == 0) {
        return NO;
    }

    static NSArray *domains = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        domains = [NSArray arrayWithObjects:
            @"googlevideo.com", @"youtube.com", @"ytimg.com", @"ggpht.com",
            @"googleapis.com", @"googleusercontent.com", @"google.com",
            @"gstatic.com", @"youtu.be", nil];
    });

    NSString *lower = [host lowercaseString];

    for (NSString *domain in domains) {
        if ([lower isEqualToString:domain] ||
            [lower hasSuffix:[@"." stringByAppendingString:domain]]) {
            return YES;
        }
    }

    return NO;
}

#pragma mark - Предложение

/** Язык устройства — из тех стран, где YouTube блокирует государство. */
static BOOL YTWarpCensoredLanguage(void) {
    NSArray *preferred = [NSLocale preferredLanguages];

    if ([preferred count] == 0) {
        return NO;
    }

    NSString *code = [[preferred objectAtIndex:0] lowercaseString];

    NSArray *languages = [NSArray arrayWithObjects:@"ru", @"fa", @"ar", @"zh", nil];

    for (NSString *language in languages) {
        if ([code isEqualToString:language] ||
            [code hasPrefix:[language stringByAppendingString:@"-"]] ||
            [code hasPrefix:[language stringByAppendingString:@"_"]]) {
            return YES;
        }
    }

    return NO;
}

/**
 * Похоже ли это на блокировку, а не на что-то другое.
 *
 * Считаются только отказы сети: не дождались, не соединились, оборвалось,
 * не нашли имя, не сошлось TLS. «Нет интернета вовсе» сюда не входит —
 * это не блокировка, и отмена тоже.
 */
static BOOL YTWarpLooksBlocked(NSError *error) {
    if (error == nil) {
        return NO;
    }

    switch ([error code]) {
        case NSURLErrorTimedOut:
        case NSURLErrorCannotFindHost:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorDNSLookupFailed:
        case NSURLErrorSecureConnectionFailed:
        case NSURLErrorServerCertificateUntrusted:
        case NSURLErrorServerCertificateHasBadDate:
        case NSURLErrorServerCertificateHasUnknownRoot:
        case NSURLErrorServerCertificateNotYetValid:
            return YES;

        default:
            return NO;
    }
}

+ (void)noteResponse:(YTHttpResponse *)response forRequest:(NSURLRequest *)request {
    // Дёшево выходим почти всегда: предлагать уже нечего.
    if (YTWarpOfferSettled) {
        return;
    }

    NSString *host = [[request URL] host];

    if (![self shouldRouteHost:host]) {
        return;
    }

    BOOL blocked = YTWarpLooksBlocked([response error]);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[self shared] noteBlocked:blocked host:host error:[response error]];
    });
}

- (void)noteBlocked:(BOOL)blocked host:(NSString *)host error:(NSError *)error {
    if (YTWarpOfferSettled) {
        return;
    }

    if (!blocked) {
        // Удача между неудачами — значит, не блокировка, а случайность.
        if ([error code] != NSURLErrorNotConnectedToInternet) {
            _failures = 0;
        }

        return;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    if (_failures == 0 || now - _firstFailureAt > YTWarpOfferWindow) {
        _failures = 0;
        _firstFailureAt = now;
    }

    _failures++;

    NSLog(@"[YouTube/WARP] %@ не отвечает (%lu/%lu): %@", host,
          (unsigned long)_failures, (unsigned long)YTWarpOfferFailures,
          [error localizedDescription]);

    if (_failures < YTWarpOfferFailures) {
        return;
    }

    if ([YTSettings usesWarp] || [YTSettings warpOfferDeclined]) {
        YTWarpOfferSettled = 1;
        return;
    }

    if (!YTWarpCensoredLanguage()) {
        NSLog(@"[YouTube/WARP] YouTube недоступен, но язык устройства не из "
              @"блокирующих стран — обход не предлагаем");

        YTWarpOfferSettled = 1;
        return;
    }

    YTWarpOfferSettled = 1;

    /**
     * Прежде чем предлагать — убедиться, что сеть вообще работает.
     *
     * Проба автора стучится к Cloudflare и Google DNS (1.1.1.1, 8.8.8.8).
     * Отвечают — интернет есть, а YouTube нет: это и есть блокировка.
     * Не отвечает никто — сети просто нет, предлагать нечего. Отвечает
     * лишь часть — белый список, и WARP там не поднимется.
     */
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        DNNetworkKind kind = [DanteNetworkProbe fingerprintNetwork];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (kind == DNNetworkOffline) {
                NSLog(@"[YouTube/WARP] Сети нет вовсе — это не блокировка, ждём дальше");

                _failures = 0;
                YTWarpOfferSettled = 0;
                return;
            }

            if (kind == DNNetworkRestricted) {
                NSLog(@"[YouTube/WARP] Сеть пускает только по белому списку — "
                      @"WARP здесь не поднимется, не предлагаем");
                return;
            }

            [self showOffer];
        });
    });
}

- (void)showOffer {
    if ([YTSettings usesWarp] || _offer != nil) {
        return;
    }

    NSLog(@"[YouTube/WARP] Предлагаем включить обход блокировок");

    _offer = [[UIAlertView alloc]
        initWithTitle:YTLoc(@"YouTube недоступен")
              message:YTLoc(@"Похоже, в вашей сети YouTube заблокирован. Включить "
                            @"обход блокировок? Запросы к YouTube пойдут через "
                            @"Cloudflare WARP.")
             delegate:self
    cancelButtonTitle:YTLoc(@"Не сейчас")
    otherButtonTitles:YTLoc(@"Включить"), YTLoc(@"Больше не предлагать"), nil];

    [_offer show];
}

- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index {
    if (alert != _offer) {
        return;
    }

    _offer = nil;

    if (index == [alert cancelButtonIndex]) {
        NSLog(@"[YouTube/WARP] Обход: «не сейчас»");
        return;
    }

    if (index == [alert firstOtherButtonIndex]) {
        _reportOutcome = YES;

        [YTWarp setEnabled:YES];
        return;
    }

    NSLog(@"[YouTube/WARP] Обход: «больше не предлагать»");

    [YTSettings setWarpOfferDeclined:YES];
}

/** Включили из предложения, а не заработало — сказать, почему и что дальше. */
- (void)tellFailure:(BOOL)restricted {
    UIAlertView *alert = [[UIAlertView alloc]
        initWithTitle:YTLoc(@"Обход не заработал")
              message:(restricted
                  ? YTLoc(@"Эта сеть пускает наружу только по белому списку, и до "
                          @"Cloudflare не достучаться. В другой сети обход может "
                          @"заработать.")
                  : YTLoc(@"Не удалось подключиться к Cloudflare WARP. Приложение "
                          @"попробует ещё раз само; состояние видно в настройках, "
                          @"в разделе «Обход блокировок»."))
             delegate:nil
    cancelButtonTitle:YTLoc(@"Понятно")
    otherButtonTitles:nil];

    [alert show];
}

@end
