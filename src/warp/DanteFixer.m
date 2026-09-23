//
//  DanteFixer.m
//  Dante
//

#import "DanteFixer.h"
#import "DanteNetworkProbe.h"
#import "AmneziaWGManager.h"
#import "AWGConfig.h"
#import "AWGWarpRegistrar.h"
#import "DebugLog.h"

NSString * const kDanteFixerDidUpdateNotification = @"DanteFixerDidUpdate";

// Сколько случайных verified-сидов пробуем, прежде чем идти регистрировать
// новую WARP-личность.
static const NSUInteger kDanteSeedAttempts = 6;
// Таймаут ожидания коннекта одного кандидата.
static const NSTimeInterval kDanteConnectTimeout = 20.0;

@interface DanteFixer ()
@property (nonatomic, readwrite) DanteFixerState state;
@property (nonatomic, readwrite, copy) NSString *statusLine;
@property (nonatomic, readwrite, copy) NSString *logText;
@property (nonatomic, readwrite, copy) NSString *proxyAddress;
@property (nonatomic, readwrite) BOOL whitelistMode;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) BOOL forceRegistration;
// Пока YES, удачная проверка туннеля не объявляет «починено» (промежуточный
// туннель только для регистрации своей личности).
@property (nonatomic, assign) BOOL holdFixed;
@end

@implementation DanteFixer {
    // Номер запуска починки. Отменённый или устаревший запуск (его номер уже
    // не текущий) не трогает состояние: иначе он, дойдя до конца после
    // «Стоп», объявлял «починено» или затирал следующий запуск.
    NSUInteger _generation, _activeGeneration;
    BOOL _restrictedNetwork;
    dispatch_queue_t _queue;
}

+ (instancetype)sharedFixer {
    static DanteFixer *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[DanteFixer alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("org.dante.fixer", NULL);
        _state = DanteFixerStateIdle;
        _statusLine = @"Готов к работе";
        _logText = @"";
    }
    return self;
}

#pragma mark - Публичное API

- (void)fixWithFreshIdentity {
    if (_state == DanteFixerStateRunning) return;
    _forceRegistration = YES;
    [self fixInternet];
}

- (BOOL)cancelled {
    return _cancelled || _activeGeneration != _generation;
}

- (void)fixInternet {
    if (_state == DanteFixerStateRunning) return;
    _state = DanteFixerStateRunning;
    _cancelled = NO;
    NSUInteger gen = ++_generation;
    _proxyAddress = nil;
    _logText = @"";
    [self log:@"=== Dante: начинаю починку ==="];
    DCon(@"fixd: repair start");
    [self notify:@"Проверяю сеть…"];
    dispatch_async(_queue, ^{
        self->_activeGeneration = gen;
        [self runFix];
    });
}

- (void)cancel {
    [self stop];
}

- (void)stop {
    BOOL wasRunning = _state == DanteFixerStateRunning;
    _cancelled = YES;
    ++_generation;                 // идущий запуск стал устаревшим
    [[AmneziaWGManager sharedManager] disconnect];
    // Кнопка отвечает сразу: фоновый запуск доработает сам, но состояние
    // уже не тронет (см. cancelled).
    _state = DanteFixerStateIdle;
    _proxyAddress = nil;
    [self notify:wasRunning ? @"Отменено" : @"Выключено"];
    DCon(wasRunning ? @"fixd: cancelled" : @"fixd: stopped");
}

- (void)markBroken:(NSString *)reason {
    if (_state != DanteFixerStateFixed) return;
    _state = DanteFixerStateFailed;
    _proxyAddress = nil;
    [self log:reason];
    [self notify:@"Связь пропала"];
    DCon(@"wdog: link lost, rearm");
}

#pragma mark - Основной цикл (фоновая очередь)

- (void)runFix {
    AmneziaWGManager *mgr = [AmneziaWGManager sharedManager];

    // 0. Сначала выясняем, дотянемся ли мы вообще до Cloudflare. В сети,
    //    которая пускает только по списку разрешённых адресов, перебор
    //    личностей и несущих занимает минуты и заведомо ничего не даст:
    //    рукопожатие WARP просто не доходит. Проверка стоит несколько секунд.
    DNNetworkKind kind = [DanteNetworkProbe fingerprintNetwork];
    if (self.cancelled) return;
    if (kind == DNNetworkRestricted) {
        _restrictedNetwork = YES;
        _state = DanteFixerStateFailed;
        [self notify:@"Белый список"];
        DCon(@"netd: filter=whitelist, cloudflare unreachable");
        [self log:@"До Cloudflare не достучаться — WARP здесь не поднимется."];
        return;
    }
    if (kind == DNNetworkOffline) {
        _restrictedNetwork = NO;
        _state = DanteFixerStateFailed;
        [self notify:@"Нет связи"];
        DCon(@"netd: no route to internet");
        [self log:@"Не отвечает вообще никто — сети нет."];
        return;
    }
    _restrictedNetwork = NO;
    DCon(@"netd: filter=none");

    // 1. Детектор белых списков ().
    self.whitelistMode = [DanteNetworkProbe detectWhitelistMode];
    [self log:self.whitelistMode
        ? @"Сеть в режиме белых списков — опорные хосты не отвечают"
        : @"Обычная фильтрация — опорные хосты доступны"];
    NSString *maskSNI = nil;
    if (self.whitelistMode) {
        maskSNI = [DanteNetworkProbe randomSNIFromResource:@"white"];
        if (maskSNI) [self log:[NSString stringWithFormat:@"Маскировочный SNI: %@", maskSNI]];
    }

    // 2. Кандидаты. Цель — СВОЯ WARP-личность.
    BOOL force = self.forceRegistration;
    self.forceRegistration = NO;
    if (!force && [self tryOwnIdentity:mgr maskSNI:maskSNI]) {
        // готово
    } else if (!self.cancelled) {
        // Своей нет (или нужна новая). Прямая регистрация под ТСПУ не проходит,
        // поэтому регистрируемся через несущий туннель — не объявляя
        // «починено». Несущие — общие ключи из APK, их сессию то и дело
        // перехватывают другие пользователи (в логе «[AWG rx] не транспорт …
        // тип 4»). Свежее рукопожатие снова делает нашу сессию текущей,
        // поэтому перед каждой попыткой переподключаемся и, если не вышло,
        // берём следующий несущий.
        [self registerThroughCarriers:mgr maskSNI:maskSNI force:force];
    }

    if (self.cancelled) {
        [self log:@"Отменено пользователем"];   // состояние уже выставил stop
        return;
    }

    if (_state == DanteFixerStateFixed) return;
    if (self.cancelled) return;

    _state = DanteFixerStateFailed;

    // Сеть проверена в начале (см. runFix): сюда попадаем, когда наружу
    // пускают, но ни один кандидат WARP не подошёл.
    [self notify:@"Не вышло"];
    [self log:@"Все кандидаты исчерпаны. Попробуйте ещё раз позже."];
    DCon(@"fixd: failed, candidates exhausted");
}

- (BOOL)restrictedNetwork { return _restrictedNetwork; }

#pragma mark - Кандидаты

// Личность, зарегистрированная нами (AWGWarpRegistrar подписывает её так).
static BOOL DanteIsOwnIdentity(AWGConfig *c) {
    return [c.label isEqualToString:@"Cloudflare WARP"];
}

- (BOOL)tryOwnIdentity:(AmneziaWGManager *)mgr maskSNI:(NSString *)maskSNI {
    NSArray *configs = mgr.savedConfigs;
    for (NSInteger i = (NSInteger)configs.count - 1; i >= 0; i--) {
        AWGConfig *c = [configs objectAtIndex:(NSUInteger)i];
        if (!DanteIsOwnIdentity(c)) continue;
        [self notify:@"Подключаю WARP…"];
        [self log:[NSString stringWithFormat:@"Кандидат: своя личность (%@, %@)",
                   c.ipv4Address, c.peerEndpoint]];
        DCon(@"warp: identity %@ -> %@", c.ipv4Address, c.peerEndpoint);
        [mgr selectConfigAtIndex:(NSUInteger)i];
        if (maskSNI) mgr.currentConfig.preferredSNI = maskSNI;
        return [self connectAndVerify:mgr];
    }
    return NO;
}

- (BOOL)tryFreshRegistration:(AmneziaWGManager *)mgr maskSNI:(NSString *)maskSNI {
    [self notify:@"Регистрирую WARP…"];
    [self log:@"Кандидат: свежая регистрация WARP (api.cloudflareclient.com)"];
    DCon(@"warp: register api.cloudflareclient.com");
    __block BOOL ok = NO;
    __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [mgr generateWarpConfigWithCompletion:^(BOOL success, NSString *errorMsg) {
        ok = success;
        err = errorMsg;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                               (int64_t)(60.0 * NSEC_PER_SEC)));
    dispatch_release(sem);
    if (!ok || !DanteIsOwnIdentity(mgr.currentConfig)) {
        [self log:[NSString stringWithFormat:@"Регистрация не удалась: %@",
                   err ?: (ok ? @"выдан только общий резерв" : @"таймаут")]];
        DCon(@"warp: register failed");
        return NO;
    }
    if (maskSNI) mgr.currentConfig.preferredSNI = maskSNI;
    if (![self connectAndVerify:mgr]) return NO;
    // Прежние свои личности больше не нужны: оставшись в списке, они снова
    // стали бы кандидатами и делили бы ключ с тем, у кого были взяты.
    [mgr removeConfigsPassingTest:^BOOL(AWGConfig *c) { return DanteIsOwnIdentity(c); }];
    [self log:[NSString stringWithFormat:@"  новая личность: %@", mgr.currentConfig.ipv4Address]];
    DCon(@"warp: registered %@", mgr.currentConfig.ipv4Address);
    return YES;
}

// Сколько несущих перебрать, прежде чем сдаться и остаться на общем ключе.
static const NSUInteger kDanteRegistrationCarriers = 5;

- (void)registerThroughCarriers:(AmneziaWGManager *)mgr maskSNI:(NSString *)maskSNI force:(BOOL)force {
    NSMutableArray *carriers = [NSMutableArray array];
    if (force && mgr.currentConfig) [carriers addObject:mgr.currentConfig];
    AWGConfig *boot = [self bootstrapConfig];
    if (boot) [carriers addObject:boot];
    [carriers addObjectsFromArray:[self verifiedSeedConfigs]];

    AWGConfig *lastWorking = nil;
    NSUInteger tried = 0;
    for (AWGConfig *carrier in carriers) {
        if (self.cancelled || tried >= kDanteRegistrationCarriers) break;
        if (maskSNI) carrier.preferredSNI = maskSNI;
        [self notify:[NSString stringWithFormat:@"WARP %lu/%lu…",
                      (unsigned long)tried + 1, (unsigned long)kDanteRegistrationCarriers]];
        [self log:[NSString stringWithFormat:@"Несущий: %@ (%@)", carrier.label, carrier.peerEndpoint]];
        DCon(@"warp: carrier %lu/%lu -> %@", (unsigned long)tried + 1,
             (unsigned long)kDanteRegistrationCarriers, carrier.peerEndpoint);
        if (![mgr.savedConfigs containsObject:carrier]) [mgr addConfig:carrier];
        [mgr selectConfigAtIndex:[mgr.savedConfigs indexOfObject:carrier]];

        self.holdFixed = YES;
        BOOL up = [self connectAndVerify:mgr];
        self.holdFixed = NO;
        if (!up) continue;
        tried++;
        lastWorking = carrier;
        if ([self tryFreshRegistration:mgr maskSNI:maskSNI]) {
            // Общие ключи больше не нужны — не копим их в настройках.
            [mgr removeConfigsPassingTest:^BOOL(AWGConfig *c) {
                return [c.label hasPrefix:@"WARP seed"] || [c.label hasPrefix:@"WARP bootstrap"];
            }];
            return;
        }
    }
    if (self.cancelled || !lastWorking) return;

    // Регистрация не вышла — работаем на том, что есть.
    [self log:@"Своя личность не получилась — остаюсь на общем ключе (под нагрузкой возможны обрывы)"];
    DCon(@"warp: fallback to shared key");
    [mgr selectConfigAtIndex:[mgr.savedConfigs indexOfObject:lastWorking]];
    if (![self connectAndVerify:mgr]) {
        [self log:@"  и общий ключ больше не отвечает"];
    }
}

#pragma mark - Подключение и верификация

- (BOOL)connectAndVerify:(AmneziaWGManager *)mgr {
    __block BOOL connected = NO;
    __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [mgr connectWithCompletion:^(BOOL success, NSString *errorMsg) {
        connected = success;
        err = errorMsg;
        dispatch_semaphore_signal(sem);
    }];
    long waited = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(kDanteConnectTimeout * NSEC_PER_SEC)));
    dispatch_release(sem);
    if (waited != 0 || !connected) {
        [self log:[NSString stringWithFormat:@"  подключение не удалось: %@",
                   waited != 0 ? @"таймаут" : (err ?: @"неизвестная ошибка")]];
        DCon(@"warp: handshake %@", waited != 0 ? @"timeout" : @"failed");
        [mgr disconnect];
        return NO;
    }

    if ([self verifyCurrentTunnel:mgr]) return YES;
    [mgr disconnect];
    return NO;
}

// Верификация: cdn-cgi/trace через SOCKS5 туннеля (f3() из КП ONE).
- (BOOL)verifyCurrentTunnel:(AmneziaWGManager *)mgr {
    uint16_t port = mgr.socksPort;
    for (int attempt = 1; attempt <= 2; attempt++) {
        if (self.cancelled) break;
        if ([DanteNetworkProbe verifyTunnelOnSOCKSPort:port timeout:4.0]) {
            if (self.holdFixed) {
                [self log:@"  туннель жив — использую его, чтобы зарегистрировать свою личность"];
                return YES;
            }
            if (self.cancelled) return NO;
            _proxyAddress = [NSString stringWithFormat:@"127.0.0.1:%u", port];
            _state = DanteFixerStateFixed;
            [self notify:@"Готово"];
            DCon(@"warp: tunnel verified, online");
            [self log:[NSString stringWithFormat:
                       @"  туннель жив (warp=… подтверждён). SOCKS5: %@",
                       _proxyAddress]];
            return YES;
        }
        [self log:[NSString stringWithFormat:@"  проверка %d/2 не прошла", attempt]];
        DCon(@"warp: verify %d/2 failed", attempt);
    }
    return NO;
}

#pragma mark - Источники конфигов

// warp_bootstrap.json — статическая личность на крайний случай
// (bootstrap-seed, tf.m4() из КП ONE).
- (AWGConfig *)bootstrapConfig {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"warp_bootstrap"
                                                     ofType:@"json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        [self log:@"warp_bootstrap.json не найден в бандле"];
        return nil;
    }
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                         options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;

    AWGConfig *c = [AWGConfig configWithDefaults];
    c.label = @"WARP bootstrap";
    c.privateKey = [json objectForKey:@"private_key"];
    c.publicKey = [json objectForKey:@"public_key"];
    c.peerPublicKey = [json objectForKey:@"peer_pub"];
    c.peerEndpoint = [json objectForKey:@"peer_endpoint"];
    c.ipv4Address = [NSString stringWithFormat:@"%@/32", [json objectForKey:@"ipv4"]];
    if ([json objectForKey:@"ipv6"]) {
        c.ipv6Address = [NSString stringWithFormat:@"%@/128", [json objectForKey:@"ipv6"]];
    }
    [AWGWarpRegistrar applyWarpObfuscationProfile:c];
    return c;
}

// До kDanteSeedAttempts случайных сидов из warp_verified_seeds.json.
- (NSArray *)verifiedSeedConfigs {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"warp_verified_seeds"
                                                     ofType:@"json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        [self log:@"warp_verified_seeds.json не найден в бандле"];
        return @[];
    }
    NSArray *seeds = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![seeds isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray *shuffled = [seeds mutableCopy];
    for (NSUInteger i = shuffled.count - 1; i > 0; i--) {
        [shuffled exchangeObjectAtIndex:i
                     withObjectAtIndex:arc4random_uniform((uint32_t)i + 1)];
    }

    NSMutableArray *configs = [NSMutableArray array];
    for (NSDictionary *seed in shuffled) {
        if (configs.count >= kDanteSeedAttempts) break;
        NSString *raw = [seed objectForKey:@"raw_config"];
        AWGConfig *c = [AWGConfig configFromWireguardString:raw];
        if (!c) continue;
        c.label = [NSString stringWithFormat:@"WARP seed %@",
                   [seed objectForKey:@"source_file"] ?: @"?"];
        [configs addObject:c];
    }
    return configs;
}

#pragma mark - Лог и нотификации

- (void)log:(NSString *)message {
    DLog(@"%@", message);
    @synchronized (self) {
        _logText = [_logText stringByAppendingFormat:@"%@\n", message];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:kDanteFixerDidUpdateNotification
                          object:self
                        userInfo:[NSDictionary dictionaryWithObject:message
                                                             forKey:@"message"]];
    });
}

- (void)notify:(NSString *)status {
    _statusLine = status;
    DLog(@"[статус] %@", status);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:kDanteFixerDidUpdateNotification
                          object:self
                        userInfo:nil];
    });
}

@end
