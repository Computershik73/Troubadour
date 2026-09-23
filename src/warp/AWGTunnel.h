//
//  AWGTunnel.h
//  YouTube
//
//  UDP tunnel endpoint for AmneziaWG: handshake, encrypted data path, and
//  a minimal local SOCKS5 front-end so the rest of the app can route traffic
//  through the tunnel without a kernel TUN interface.
//

#import <Foundation/Foundation.h>

@class AWGConfig;
@class AWGHandshake;

typedef NS_ENUM(NSInteger, AWGTunnelState) {
    AWGTunnelStateIdle = 0,
    AWGTunnelStateConnecting,
    AWGTunnelStateConnected,
    AWGTunnelStateReconnecting,
    AWGTunnelStateFailed
};

@protocol AWGTunnelDelegate <NSObject>
@optional
- (void)tunnelDidChangeState:(AWGTunnelState)state;
- (void)tunnelDidFailWithError:(NSError *)error;
@end

// Расшифрованный IP-пакет для ядра (режим utun). Буфер живёт только на время вызова.
typedef void (^AWGRawPacketHandler)(const uint8_t *bytes, size_t length);

// Поставить сокету самый большой буфер, который разрешает ядро (см. AWGTunnel.m).
int awg_grow_sockbuf(int fd, int opt, int want);

// Пачка пакетов за один заход на очередь отправки. На iPhone 4 переход между
// потоками на каждый пакет стоил заметную часть процессорного времени.
typedef struct { const uint8_t *bytes; size_t length; } AWGRawPacket;

@interface AWGTunnel : NSObject

@property (nonatomic, readonly) AWGTunnelState state;
@property (nonatomic, readonly) uint16_t socksPort;   // local SOCKS5 proxy port (0 when not listening)
@property (nonatomic, weak) id<AWGTunnelDelegate> delegate;
// Порт, на котором поднять SOCKS5 (0 — любой свободный). Если занят, берётся
// любой свободный: фактический порт — в socksPort.
@property (nonatomic, assign) uint16_t preferredSOCKSPort;
// Не давать Wi‑Fi засыпать, пока идёт трафик: раз в 50 мс пустой keepalive,
// если данные приходили за последние 3 с. На iPhone 4 (iOS 5) радио в
// энергосбережении добавляет 50–120 мс к каждому ответу — видео грузится
// рывками, хотя сама пропускная способность в порядке.
@property (nonatomic, assign) BOOL keepRadioAwake;
// Режим utun: входящие пакеты, не нужные своему стеку, уходят сюда.
@property (atomic, copy) AWGRawPacketHandler rawPacketHandler;
@property (nonatomic, readonly) NSTimeInterval handshakeAge;
// Когда последний раз расшифровали пакет с данными (timeIntervalSinceReferenceDate), 0 — не было.
@property (nonatomic, readonly) NSTimeInterval lastDataAt;
@property (nonatomic, readonly) uint64_t bytesSent;
@property (nonatomic, readonly) uint64_t bytesReceived;

- (instancetype)initWithConfig:(AWGConfig *)config;

// Start the UDP socket, perform the handshake, and bring up the local SOCKS5 proxy.
- (void)startWithCompletion:(void(^)(BOOL success, NSError *  error))completion;

// Tear down the socket and the SOCKS5 listener.
- (void)stop;

// Force a re-handshake (key rotation).
- (void)rotateKeys;

// Resolve a hostname over the tunnel and hand back the dotted-quad, or nil.
// The system resolver is not an option on a filtered network: its answers for
// YouTube hosts are forged or absent, which is why the direct player request
// failed with "hostname could not be found" while the tunnel resolved it fine.
- (NSString *)resolveHostThroughTunnel:(NSString *)host;

// Системный режим без SOCKS: принять уже соединённого клиента (его
// перенаправил pf) и связать его с host:port внутри туннеля. Закроет fd сам.
- (void)adoptTransparentClient:(int)fd host:(NSString *)host port:(uint16_t)port;

// HTTP-прокси: связать клиента с host:port внутри туннеля; okReply/failReply —
// ответ клиенту после соединения (nil — ничего), initialData — отправить
// серверу первым. Закроет fd сам.
- (void)adoptProxiedClient:(int)fd host:(NSString *)host port:(uint16_t)port
                   okReply:(NSData *)okReply failReply:(NSData *)failReply
               initialData:(NSData *)initialData;

// Запуск релея прямо в текущем потоке (без порождения нового NSThread)
- (void)relayProxiedClientInline:(int)fd host:(NSString *)host port:(uint16_t)port
                         okReply:(NSData *)okReply failReply:(NSData *)failReply
                     initialData:(NSData *)initialData;

- (void)relayClient:(int)clientFd host:(NSString *)host port:(uint16_t)port
            okReply:(NSData *)okReply failReply:(NSData *)failReply
        initialData:(NSData *)initialData;

// Готовый DNS-запрос (wire-формат) к резолверу через туннель; nil — нет ответа.
- (NSData *)relayDNSQuery:(NSData *)query;

// Режим utun: зашифровать и отправить готовый IPv4-пакет от ядра.
- (void)sendRawIPPacket:(const uint8_t *)bytes length:(size_t)length;
- (void)sendRawIPPackets:(const AWGRawPacket *)packets count:(size_t)count;
// Режим одного потока (iPhone 4): отдать сюда fd интерфейса utun, и чтение из
// него будет идти в том же цикле, что и чтение туннеля. На одном ядре два
// потока вытесняют друг друга; -1 — выключить.
@property (nonatomic, assign) int utunFd;
// Привязать UDP-сокет туннеля к интерфейсу (IP_BOUND_IF), чтобы он не ушёл в utun.
- (void)bindToInterfaceIndex:(unsigned)index;

// Internal interface used by AWGTCPConnection
- (void)sendTunnelPacket:(NSData *)packet;
- (void)sendTunnelPacketBytes:(const uint8_t *)bytes length:(size_t)length;
- (void)deliverData:(NSData *)data toConnection:(uint32_t)connectionID;
- (void)deliverData:(NSData *)data toFd:(int)clientFd connectionID:(uint32_t)connectionID;

@end
