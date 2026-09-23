//
//  AmneziaWGManager.m
//  YouTube
//

#import "AmneziaWGManager.h"
#import "AWGConfig.h"
#import "AWGCrypto.h"
#import "AWGWarpRegistrar.h"
#import "Constants.h"
#import "DebugLog.h"

NSString * const kAmneziaWGStatusDidChangeNotification = @"AmneziaWGStatusDidChangeNotification";

static NSString * const kAWGConfigsKey   = @"awg_configs_key";
static NSString * const kAWGActiveIndexKey = @"awg_active_index_key";
static NSString * const kAWGEnabledKey   = @"awg_enabled_key";

@interface AmneziaWGManager ()
@property (nonatomic, strong) AWGTunnel *tunnel;
@property (nonatomic, assign) AWGTunnelState state;
@property (nonatomic, strong) NSMutableArray *configs;
@property (nonatomic, assign) NSInteger activeIndex;
@property (nonatomic, copy) NSString *lastError;
@property (nonatomic, assign) BOOL seedUpgradeAttempted;
@property (nonatomic, assign) BOOL connectInFlight;
@property (nonatomic, strong) NSMutableArray *pendingConnectCompletions;
@end

@implementation AmneziaWGManager

+ (instancetype)sharedManager {
    static AmneziaWGManager *s_instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_instance = [[AmneziaWGManager alloc] init];
    });
    return s_instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _utunFd = -1;
        _state = AWGTunnelStateIdle;
        _configs = [NSMutableArray array];
        _activeIndex = 0;
        [self loadConfigs];

        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        _activeIndex = [ud integerForKey:kAWGActiveIndexKey];
        if (_activeIndex < 0 || _activeIndex >= (NSInteger)_configs.count) _activeIndex = 0;

        // Registering a private identity saved it but never selected it, so the
        // app kept coming up on the bundled seed — an exit address shared by
        // every copy of this build, which is exactly the kind of address
        // YouTube answers with "sign in to confirm you're not a bot". Prefer
        // our own identity whenever one is saved.
        NSInteger mine = [self indexOfNewestPrivateIdentity];
        if (mine >= 0 && [self isBundledSeedConfig:_configs[_activeIndex]]) {
            _activeIndex = mine;
            [ud setInteger:_activeIndex forKey:kAWGActiveIndexKey];
            [ud synchronize];
            DLog(@"[AWG] switching off the bundled seed onto our own identity (#%ld)", (long)mine);
        }

        /*
         * Troubadour: самопроизвольного подключения при первом обращении нет.
         *
         * У автора менеджер сам поднимал туннель, едва к нему обратились,
         * и флаг «включено» по умолчанию стоял в YES. В приложении обход
         * включает человек, а подключением ведает YTWarp через DanteFixer.
         */
    }
    return self;
}

#pragma mark - Config persistence

- (void)loadConfigs {
    NSData *data = [[NSUserDefaults standardUserDefaults] objectForKey:kAWGConfigsKey];
    if (!data) return;
    NSArray *arr = [NSKeyedUnarchiver unarchiveObjectWithData:data];
    if ([arr isKindOfClass:[NSArray class]]) {
        _configs = [NSMutableArray arrayWithArray:arr];
    }
}

- (void)saveConfigs {
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:_configs];
    [[NSUserDefaults standardUserDefaults] setObject:data forKey:kAWGConfigsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSArray *)savedConfigs {
    return [_configs copy];
}

- (void)addConfig:(AWGConfig *)config {
    if (!config) return;
    [_configs addObject:config];
    [self saveConfigs];
    [[NSNotificationCenter defaultCenter] postNotificationName:kAmneziaWGStatusDidChangeNotification object:self];
}

- (void)removeConfigsPassingTest:(BOOL (^)(AWGConfig *config))test {
    AWGConfig *active = self.currentConfig;
    NSMutableIndexSet *doomed = [NSMutableIndexSet indexSet];
    [_configs enumerateObjectsUsingBlock:^(AWGConfig *c, NSUInteger i, BOOL *stop) {
        if (c != active && test(c)) [doomed addIndex:i];
    }];
    if (doomed.count == 0) return;
    [_configs removeObjectsAtIndexes:doomed];
    NSUInteger idx = active ? [_configs indexOfObjectIdenticalTo:active] : NSNotFound;
    _activeIndex = (idx == NSNotFound) ? 0 : (NSInteger)idx;
    [[NSUserDefaults standardUserDefaults] setInteger:_activeIndex forKey:kAWGActiveIndexKey];
    [self saveConfigs];
}

- (void)removeConfigAtIndex:(NSUInteger)index {
    if (index >= _configs.count) return;
    [_configs removeObjectAtIndex:index];
    if (_activeIndex >= (NSInteger)_configs.count) _activeIndex = 0;
    [self saveConfigs];
    [[NSNotificationCenter defaultCenter] postNotificationName:kAmneziaWGStatusDidChangeNotification object:self];
}

- (void)removeAllConfigs {
    [self disconnect];
    [_configs removeAllObjects];
    _activeIndex = 0;
    self.seedUpgradeAttempted = NO;
    [self saveConfigs];
    DLog(@"[AWG] all saved configs cleared");
    [[NSNotificationCenter defaultCenter] postNotificationName:kAmneziaWGStatusDidChangeNotification object:self];
}

- (BOOL)isBundledSeedConfig:(AWGConfig *)config {
    return [config.label hasPrefix:@"WARP (вшитый"];
}

// The most recently registered identity, or -1 when we only have seeds.
- (NSInteger)indexOfNewestPrivateIdentity {
    for (NSInteger i = (NSInteger)_configs.count - 1; i >= 0; i--) {
        if (![self isBundledSeedConfig:_configs[i]]) return i;
    }
    return -1;
}

// Once a private identity is live, the shared bundled one is only clutter —
// and leaving it selectable invites connecting on everyone else's keys.
- (void)pruneBundledSeeds {
    // Keeping the active config unconditionally meant that if a seed was
    // active, the seed survived and stayed selected forever.
    NSInteger mine = [self indexOfNewestPrivateIdentity];
    if (mine >= 0 && [self isBundledSeedConfig:self.currentConfig]) {
        _activeIndex = mine;
    }
    AWGConfig *active = self.currentConfig;
    NSMutableArray *kept = [NSMutableArray array];
    for (AWGConfig *c in _configs) {
        if (c != active && [self isBundledSeedConfig:c]) continue;
        [kept addObject:c];
    }
    if (kept.count == _configs.count) return;
    NSUInteger removed = _configs.count - kept.count;
    [_configs setArray:kept];
    _activeIndex = (NSInteger)[_configs indexOfObject:active];
    if (_activeIndex == (NSInteger)NSNotFound) _activeIndex = 0;
    [[NSUserDefaults standardUserDefaults] setInteger:_activeIndex forKey:kAWGActiveIndexKey];
    [self saveConfigs];
    DLog(@"[AWG] pruned %lu bundled seed config(s)", (unsigned long)removed);
}

- (void)selectConfigAtIndex:(NSUInteger)index {
    if (index >= _configs.count) return;
    _activeIndex = (NSInteger)index;
    [[NSUserDefaults standardUserDefaults] setInteger:_activeIndex forKey:kAWGActiveIndexKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (self.isConnected) [self reconnect];
}

- (AWGConfig *)currentConfig {
    if (_activeIndex >= 0 && _activeIndex < (NSInteger)_configs.count) {
        return _configs[_activeIndex];
    }
    return nil;
}

#pragma mark - Connection

- (void)connectWithCompletion:(void(^)(BOOL success, NSString *  errorMsg))completion {
    AWGConfig *cfg = self.currentConfig;
    if (!cfg) {
        self.lastError = @"Нет выбранной конфигурации AmneziaWG";
        if (completion) completion(NO, self.lastError);
        return;
    }
    // Автоконнект из init и DanteFixer могут позвать connect одновременно.
    // Второй вызов подменял _tunnel, не остановив первый до конца: осиротевший
    // туннель дожимал свой handshake, сервер перебрасывал сессию на его сокет,
    // и данные переставали доходить до туннеля, с которым работает проверка.
    @synchronized (self) {
        if (_connectInFlight) {
            if (completion) {
                if (!_pendingConnectCompletions) {
                    _pendingConnectCompletions = [NSMutableArray array];
                }
                [_pendingConnectCompletions addObject:[completion copy]];
            }
            DLog(@"[AWG] connect уже идёт — присоединяюсь к текущему");
            return;
        }
        _connectInFlight = YES;
    }
    self.lastError = nil;
    [_tunnel stop];
    _tunnel = [[AWGTunnel alloc] initWithConfig:cfg];
    _tunnel.delegate = self;
    _tunnel.preferredSOCKSPort = self.preferredSOCKSPort;
    _tunnel.keepRadioAwake = self.keepRadioAwake;
    _tunnel.rawPacketHandler = self.rawPacketHandler;
    _tunnel.utunFd = self.utunFd;
    [_tunnel startWithCompletion:^(BOOL success, NSError *  error) {
        NSArray *pending;
        @synchronized (self) {
            self.connectInFlight = NO;
            pending = [self.pendingConnectCompletions copy];
            [self.pendingConnectCompletions removeAllObjects];
        }
        if (!success) {
            self.lastError = error.localizedDescription ?: @"Неизвестная ошибка";
        }
        if (completion) completion(success, self.lastError);
        for (void(^pendingCompletion)(BOOL, NSString *) in pending) {
            pendingCompletion(success, self.lastError);
        }
    }];
}

- (void)disconnect {
    [_tunnel stop];
    self.state = AWGTunnelStateIdle;
}

- (void)reconnect {
    [self disconnect];
    [self connectWithCompletion:nil];
}

- (BOOL)isConnected {
    return _state == AWGTunnelStateConnected;
}

- (BOOL)adoptTransparentClient:(int)fd host:(NSString *)host port:(uint16_t)port {
    AWGTunnel *tunnel = _tunnel;
    if (!tunnel || tunnel.state != AWGTunnelStateConnected) return NO;
    [tunnel adoptTransparentClient:fd host:host port:port];
    return YES;
}

- (BOOL)adoptProxiedClient:(int)fd host:(NSString *)host port:(uint16_t)port
                   okReply:(NSData *)okReply failReply:(NSData *)failReply
               initialData:(NSData *)initialData {
    AWGTunnel *tunnel = _tunnel;
    if (!tunnel || tunnel.state != AWGTunnelStateConnected) return NO;
    [tunnel adoptProxiedClient:fd host:host port:port
                       okReply:okReply failReply:failReply initialData:initialData];
    return YES;
}

- (BOOL)relayProxiedClientInline:(int)fd host:(NSString *)host port:(uint16_t)port
                         okReply:(NSData *)okReply failReply:(NSData *)failReply
                     initialData:(NSData *)initialData {
    AWGTunnel *tunnel = _tunnel;
    if (!tunnel || tunnel.state != AWGTunnelStateConnected) return NO;
    [tunnel relayProxiedClientInline:fd host:host port:port
                             okReply:okReply failReply:failReply initialData:initialData];
    return YES;
}

@synthesize rawPacketHandler = _rawPacketHandler;
@synthesize utunFd = _utunFd;

- (void)setUtunFd:(int)fd {
    _utunFd = fd;
    _tunnel.utunFd = fd;
}

- (void)setRawPacketHandler:(AWGRawPacketHandler)handler {
    @synchronized (self) {
        _rawPacketHandler = [handler copy];
    }
    _tunnel.rawPacketHandler = handler;
}

- (AWGRawPacketHandler)rawPacketHandler {
    @synchronized (self) {
        return _rawPacketHandler;
    }
}

- (void)sendRawIPPacket:(const uint8_t *)bytes length:(size_t)length {
    AWGTunnel *tunnel = _tunnel;
    if (!tunnel || tunnel.state != AWGTunnelStateConnected) return;
    [tunnel sendRawIPPacket:bytes length:length];
}

- (void)sendRawIPPackets:(const AWGRawPacket *)packets count:(size_t)count {
    AWGTunnel *tunnel = _tunnel;
    if (!tunnel || tunnel.state != AWGTunnelStateConnected) return;
    [tunnel sendRawIPPackets:packets count:count];
}

- (BOOL)bindTunnelToInterfaceIndex:(unsigned)index {
    AWGTunnel *tunnel = _tunnel;
    if (!tunnel || tunnel.state != AWGTunnelStateConnected) return NO;
    [tunnel bindToInterfaceIndex:index];
    return YES;
}

- (NSData *)relayDNSQuery:(NSData *)query {
    AWGTunnel *tunnel = _tunnel;
    if (!tunnel || tunnel.state != AWGTunnelStateConnected) return nil;
    return [tunnel relayDNSQuery:query];
}

- (NSTimeInterval)lastDataAt {
    AWGTunnel *tunnel = _tunnel;
    return tunnel.state == AWGTunnelStateConnected ? tunnel.lastDataAt : 0;
}

- (uint16_t)socksPort {
    return _tunnel ? _tunnel.socksPort : 0;
}

- (NSString *)statusDescription {
    switch (_state) {
        case AWGTunnelStateConnected:    return @"Подключено";
        case AWGTunnelStateConnecting:   return @"Подключение...";
        case AWGTunnelStateReconnecting: return @"Переподключение...";
        case AWGTunnelStateFailed:       return self.lastError ?: @"Ошибка";
        default:                         return @"Отключено";
    }
}

#pragma mark - Config generation

+ (AWGConfig *)generateConfigWithPrivateKey:(NSString * )privateKey
                                peerPublicKey:(NSString *)peerPublicKey
                                     endpoint:(NSString *)endpoint
                                       junkCount:(NSUInteger)jc
                                        junkMin:(NSUInteger)jmin
                                        junkMax:(NSUInteger)jmax {
    AWGConfig *c = [AWGConfig configWithDefaults];
    if (privateKey.length > 0) {
        c.privateKey = privateKey;
        c.publicKey = [AWGCrypto base64Encode:[AWGCrypto publicKeyFromPrivateKey:[AWGCrypto base64Decode:privateKey]]];
    } else {
        NSData *priv = [AWGCrypto generatePrivateKey];
        c.privateKey = [AWGCrypto base64Encode:priv];
        c.publicKey = [AWGCrypto base64Encode:[AWGCrypto publicKeyFromPrivateKey:priv]];
    }
    c.peerPublicKey = peerPublicKey;
    c.peerEndpoint = endpoint;
    c.junkCount = jc;
    c.junkMin = jmin;
    c.junkMax = jmax;
    return c;
}

#pragma mark - Automatic config generation

- (void)generateWarpConfigWithCompletion:(void(^)(BOOL, NSString *))completion {
    __weak AmneziaWGManager *weakSelf = self;
    [AWGWarpRegistrar generateConfigWithCompletion:^(AWGConfig *config, NSError *error) {
        AmneziaWGManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!config) {
            // Registration is blocked on this network. Fall back to the identity
            // shipped with the app so the tunnel can still come up; the user can
            // retry registration later from a different network.
            DLog(@"[AWG] registration unavailable (%@)", error.localizedDescription);
            if (strongSelf.isConnected) {
                // Already tunnelled on the seed: keep what works.
                if (completion) completion(YES, nil);
                return;
            }
            config = [AWGWarpRegistrar bundledSeedConfig];
            strongSelf.lastError = nil;
        }
        DLog(@"[AWG] private identity registered: %@ via %@ (client_id %@)",
             config.ipv4Address, config.peerEndpoint, config.warpClientID ?: @"none");
        [strongSelf addConfig:config];
        [strongSelf selectConfigAtIndex:strongSelf.savedConfigs.count - 1];
        [strongSelf connectWithCompletion:^(BOOL success, NSString *errorMsg) {
            if (success) {
                [strongSelf pruneBundledSeeds];
                DLog(@"[AWG] now running on our own WARP identity");
            } else {
                DLog(@"[AWG] private identity would not connect (%@), keeping the seed", errorMsg);
            }
            if (completion) completion(success, errorMsg);
        }];
    }];
}

- (void)useBundledSeedWithCompletion:(void(^)(BOOL, NSString *))completion {
    AWGConfig *seed = [AWGWarpRegistrar bundledSeedConfig];
    [self addConfig:seed];
    [self selectConfigAtIndex:self.savedConfigs.count - 1];
    DLog(@"[AWG] using bundled seed: %@ via %@", seed.ipv4Address, seed.peerEndpoint);
    [self connectWithCompletion:completion];
}

- (void)setEndpointForCurrentConfig:(NSString *)endpoint {
    AWGConfig *cfg = self.currentConfig;
    if (!cfg || endpoint.length == 0) return;
    DLog(@"[AWG] endpoint выбран вручную: %@ -> %@", cfg.peerEndpoint, endpoint);
    cfg.peerEndpoint = endpoint;
    [self saveConfigs];
}

- (void)rotateEndpointAndReconnect {
    AWGConfig *cfg = self.currentConfig;
    if (!cfg) return;
    [AWGWarpRegistrar rotateEndpointForConfig:cfg];
    [self saveConfigs];
    [self reconnect];
}

#pragma mark - Traffic routing

- (BOOL)shouldRouteTrafficForHost:(NSString *)host {
    if (!self.isConnected) return NO;
    if (!host) return NO;
    NSString *h = [host lowercaseString];
    return ([h hasSuffix:@"googlevideo.com"] ||
            [h hasSuffix:@"youtube.com"] ||
            [h hasSuffix:@"ytimg.com"] ||
            [h hasSuffix:@"ggpht.com"] ||
            [h hasSuffix:@"googleapis.com"] ||
            [h hasSuffix:@"googleusercontent.com"] ||
            [h hasSuffix:@"google.com"] ||
            [h hasSuffix:@"gstatic.com"] ||
            [h hasSuffix:@"youtu.be"]);
}

#pragma mark - AWGTunnelDelegate

- (void)tunnelDidChangeState:(AWGTunnelState)state {
    self.state = state;
    [[NSNotificationCenter defaultCenter] postNotificationName:kAmneziaWGStatusDidChangeNotification object:self];

    // We are up on the identity shipped with the app, which everyone running
    // this build shares. Now that there IS a tunnel, use it to register a
    // private one — inside WireGuard the filter cannot see the request at all.
    // Derive this from what is saved rather than from a per-process flag: the
    // flag reset on every launch, so the app kept re-registering even though it
    // already had its own identity.
    BOOL havePrivateIdentity = NO;
    for (AWGConfig *c in _configs) {
        if (![self isBundledSeedConfig:c]) { havePrivateIdentity = YES; break; }
    }

    if (state == AWGTunnelStateConnected && !self.seedUpgradeAttempted && !havePrivateIdentity &&
        self.currentConfig.warpClientID.length > 0 &&
        [self isBundledSeedConfig:self.currentConfig]) {
        self.seedUpgradeAttempted = YES;
        DLog(@"[AWG] on the bundled seed — registering a private identity through the tunnel");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self generateWarpConfigWithCompletion:^(BOOL ok, NSString *err) {
                DLog(@"[AWG] seed upgrade %@%@", ok ? @"succeeded" : @"failed",
                     ok ? @"" : [NSString stringWithFormat:@": %@", err ?: @"?"]);
            }];
        });
    }
}

- (void)tunnelDidFailWithError:(NSError *)error {
    self.lastError = error.localizedDescription;
    self.state = AWGTunnelStateFailed;
    [[NSNotificationCenter defaultCenter] postNotificationName:kAmneziaWGStatusDidChangeNotification object:self];
}

- (NSString *)resolveHostThroughTunnel:(NSString *)host {
    if (!self.isConnected || !_tunnel) return nil;
    return [_tunnel resolveHostThroughTunnel:host];
}

@end
