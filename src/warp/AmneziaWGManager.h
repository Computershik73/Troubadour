//
//  AmneziaWGManager.h
//  YouTube
//
//  High-level manager for AmneziaWG tunnels. Owns the current config, starts/stops
//  the tunnel, and exposes a SOCKS5 endpoint for the rest of the app.
//

#import <Foundation/Foundation.h>
#import "AWGTunnel.h"

@class AWGConfig;

extern NSString * const kAmneziaWGStatusDidChangeNotification;

@interface AmneziaWGManager : NSObject <AWGTunnelDelegate>

+ (instancetype)sharedManager;

@property (nonatomic, readonly) AWGTunnelState state;
@property (nonatomic, readonly) BOOL isConnected;
@property (nonatomic, readonly) uint16_t socksPort;
// Когда текущий туннель последний раз принял данные (см. AWGTunnel.lastDataAt).
@property (nonatomic, readonly) NSTimeInterval lastDataAt;
// Желаемый порт SOCKS5 для новых туннелей (0 — любой).
@property (nonatomic, assign) uint16_t preferredSOCKSPort;
// Передаётся новым туннелям (см. AWGTunnel.keepRadioAwake).
@property (nonatomic, assign) BOOL keepRadioAwake;
// Режим utun: передаётся текущему и новым туннелям (см. AWGTunnel).
@property (atomic, copy) AWGRawPacketHandler rawPacketHandler;
@property (nonatomic, readonly) AWGConfig *currentConfig;
@property (nonatomic, copy, readonly) NSString *statusDescription;
@property (nonatomic, copy, readonly) NSString *lastError;

// Persisted configs (stored in NSUserDefaults)
@property (nonatomic, strong, readonly) NSArray *savedConfigs;
@property (nonatomic, assign, readonly) NSInteger activeIndex;

- (void)addConfig:(AWGConfig *)config;
- (void)removeConfigAtIndex:(NSUInteger)index;
- (void)removeAllConfigs;
// Удалить конфиги, для которых test вернул YES; активный остаётся активным
// (и не удаляется), без переподключения.
- (void)removeConfigsPassingTest:(BOOL (^)(AWGConfig *config))test;
- (void)selectConfigAtIndex:(NSUInteger)index;

// Connection control
- (void)connectWithCompletion:(void(^)(BOOL success, NSString *  errorMsg))completion;
- (void)disconnect;
- (void)reconnect;

// Config generation helpers
+ (AWGConfig *)generateConfigWithPrivateKey:(NSString * )privateKey
                                peerPublicKey:(NSString *)peerPublicKey
                                     endpoint:(NSString *)endpoint
                                       junkCount:(NSUInteger)jc
                                        junkMin:(NSUInteger)jmin
                                        junkMax:(NSUInteger)jmax;

// Registers a fresh Cloudflare WARP identity, stores the resulting config and
// selects it. Completion runs on the main thread.
- (void)generateWarpConfigWithCompletion:(void(^)(BOOL success, NSString *errorMsg))completion;

// Troubadour: точка входа WARP, до которой в этой сети уже дошло рукопожатие
// (несущий, через который идёт регистрация). Если задана, новая личность
// подключается через неё, а не через адрес из ответа Cloudflare: тот бывает
// вне известных диапазонов WARP (104.16.x) и в сетях с ТСПУ не отвечает.
// Любая точка WARP принимает любой зарегистрированный ключ.
@property (atomic, copy) NSString *provenEndpoint;

// Install the WARP identity shipped with the app and connect. No network needed
// to set it up, so it works where registration is blocked outright.
- (void)useBundledSeedWithCompletion:(void(^)(BOOL success, NSString *errorMsg))completion;

// Сменить эндпоинт активного конфига и сохранить (без переподключения).
- (void)setEndpointForCurrentConfig:(NSString *)endpoint;

// Move the active config to another anycast endpoint and reconnect.
- (void)rotateEndpointAndReconnect;

// Whether YouTube traffic should go through AmneziaWG right now.
- (BOOL)shouldRouteTrafficForHost:(NSString *)host;

// Системный режим: отдать перенаправленного pf клиента текущему туннелю.
// NO — туннеля нет (fd тогда закрывает вызывающий).
- (BOOL)adoptTransparentClient:(int)fd host:(NSString *)host port:(uint16_t)port;

// HTTP-прокси: то же, что adoptTransparentClient, но с ответами клиенту и
// первыми данными для сервера (см. AWGTunnel).
- (BOOL)adoptProxiedClient:(int)fd host:(NSString *)host port:(uint16_t)port
                   okReply:(NSData *)okReply failReply:(NSData *)failReply
               initialData:(NSData *)initialData;

- (BOOL)relayProxiedClientInline:(int)fd host:(NSString *)host port:(uint16_t)port
                         okReply:(NSData *)okReply failReply:(NSData *)failReply
                     initialData:(NSData *)initialData;

// Режим utun: пакет от ядра в текущий туннель (молча теряется, если его нет).
- (void)sendRawIPPacket:(const uint8_t *)bytes length:(size_t)length;
- (void)sendRawIPPackets:(const AWGRawPacket *)packets count:(size_t)count;
// Режим одного потока (см. AWGTunnel.utunFd). -1 — выключить.
@property (nonatomic, assign) int utunFd;
// Привязать UDP-сокет текущего туннеля к интерфейсу. NO — туннеля нет.
- (BOOL)bindTunnelToInterfaceIndex:(unsigned)index;

// DNS-запрос через текущий туннель; nil — туннеля нет или нет ответа.
- (NSData *)relayDNSQuery:(NSData *)query;

// Resolve through the live tunnel. Returns nil when there is no tunnel.
- (NSString *)resolveHostThroughTunnel:(NSString *)host;

@end
