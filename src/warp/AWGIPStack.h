//
//  AWGIPStack.h
//  YouTube
//
//  Minimal IPv4/TCP stack for AmneziaWG. Converts local SOCKS5 streams into
//  real IP packets the server can route, and back.
//

#import <Foundation/Foundation.h>

@class AWGTunnel;

typedef NS_ENUM(uint8_t, AWGIPProtocol) {
    AWGIPProtocolTCP = 6,
    AWGIPProtocolUDP = 17
};

@interface AWGIPStack : NSObject

@property (nonatomic, readonly) NSString *localIPv4;
@property (nonatomic, readonly) NSString *localIPv6;

- (instancetype)initWithTunnel:(AWGTunnel *)tunnel localIPv4:(NSString *)ipv4 localIPv6:(NSString *)ipv6;

// Resolver reached THROUGH the tunnel. The system resolver is useless here:
// on a filtered network its answers are forged, and it would leak the lookup
// outside the tunnel even when they are not. Defaults to 1.1.1.1.
@property (nonatomic, copy) NSString *dnsServerIPv4;

// Tunnel MTU, used to advertise a TCP MSS the tunnel can actually carry.
@property (nonatomic, assign) NSUInteger tunnelMTU;

// Resolve a hostname over the tunnel. Returns the address in network byte
// order, or 0. Answers are cached for the life of the tunnel.
- (uint32_t)resolveIPv4:(NSString *)host;

// Переслать готовый DNS-запрос (как есть, в wire-формате) резолверу через
// туннель по UDP и вернуть ответ, или nil по таймауту. Нужен для DNS-over-TCP
// от системы: WARP не пропускает TCP на :53, а UDP-DNS в туннеле работает.
- (NSData *)relayDNSQuery:(NSData *)query timeout:(NSTimeInterval)timeout;

// Create a TCP connection and return its connection ID.
- (uint32_t)openTCPToHost:(NSString *)host port:(uint16_t)port;

// Block until the three-way handshake completes. Without this the caller can
// start writing while the connection is still in synSent, and sendTCPData:
// drops those bytes on the floor.
- (BOOL)waitForConnection:(uint32_t)connectionID timeout:(NSTimeInterval)timeout;

// Send a payload inside an existing connection.
- (void)sendTCPData:(NSData *)data connectionID:(uint32_t)connectionID;

// Close a connection.
- (void)closeTCPConnection:(uint32_t)connectionID;

// Закрыть пачку входящих пакетов: отдать накопленные данные клиентам и
// отправить отложенные ACK. Туннель зовёт это, вычитав сокет за один раз.
- (void)flushPendingWork;
@property (atomic, assign) BOOL hasPendingWork;

// Пакет адресован соединению или DNS-запросу этого стека? Остальное в
// режиме utun отдаётся ядру. Можно звать из любого потока.
- (BOOL)claimsIncomingPacket:(const uint8_t *)bytes length:(size_t)len;

// Called by the tunnel when a decrypted IP packet arrives.
- (void)handleIPPacket:(NSData *)packet;
- (void)handleIPPacketBytes:(const uint8_t *)bytes length:(size_t)len;

- (void)setClientFd:(int)fd forConnectionID:(uint32_t)connID;
// Закрыть соединение и дождаться, пока клиенту отдано всё, что уже пришло.
// После возврата сокет клиента можно закрывать: запись в него больше не будет.
- (void)closeTCPConnectionAndDrain:(uint32_t)connID;
// Сколько байт программы ещё ждёт отправки: по этому числу читающий поток
// притормаживает, иначе программа набивает наш буфер и меряет его, а не сеть.
- (NSUInteger)sendBacklogForConnection:(uint32_t)connID;

// Called by the stack when it wants to emit a packet into the tunnel.
- (void)sendIPPacket:(NSData *)packet;

@end
