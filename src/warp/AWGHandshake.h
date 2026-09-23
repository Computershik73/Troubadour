//
//  AWGHandshake.h
//  YouTube
//
//  WireGuard Noise_IKpsk2 handshake with AmneziaWG obfuscation.
//

#import <Foundation/Foundation.h>

@class AWGConfig;

typedef NS_ENUM(NSInteger, AWGHandshakeState) {
    AWGHandshakeStateIdle = 0,
    AWGHandshakeStateInitSent,
    AWGHandshakeStateEstablished,
    AWGHandshakeStateFailed
};

// Wire sizes, fixed by the protocol.
extern const NSUInteger kAWGInitiationLength;   // 148
extern const NSUInteger kAWGResponseLength;     // 92
extern const NSUInteger kAWGTransportHeaderLen; // 16

@interface AWGHandshake : NSObject

@property (nonatomic, readonly) AWGHandshakeState state;
@property (nonatomic, readonly) uint32_t localIndex;     // our sender index
@property (nonatomic, readonly) uint32_t remoteIndex;    // peer's sender index (after handshake)

// Transport keys established after a successful handshake
@property (nonatomic, readonly) NSData *sendingKey;
@property (nonatomic, readonly) NSData *receivingKey;

- (instancetype)initWithConfig:(AWGConfig *)config;

// Drop session state so a fresh initiation can be built (key rotation).
- (void)reset;

// The datagrams to send, in order: the I1..I5 signature packets, then Jc junk
// packets, then the handshake initiation (prefixed with S1 junk when set).
// AmneziaWG expects these as SEPARATE UDP packets, never concatenated.
- (NSArray *)buildInitiationDatagrams;

// Process a received Handshake Response. Returns YES on success and fills
// sendingKey / receivingKey.
- (BOOL)processResponse:(NSData *)packet error:(NSError **)error;

// Whether the current state machine considers the session live.
@property (nonatomic, readonly) BOOL isEstablished;

#pragma mark - Transport framing

// 16-byte data-packet header: obfuscated type H4, the peer's receiver index,
// and the counter — plus the WARP reserved bytes when the config carries them.
- (NSData *)transportHeaderWithCounter:(uint64_t)counter;
- (size_t)writeTransportHeader:(uint8_t *)outHeader counter:(uint64_t)counter;

// Validates a received data packet's header. Returns the payload offset
// (kAWGTransportHeaderLen) and fills outCounter, or NSNotFound if it is not
// a transport packet for this session.
- (NSUInteger)transportPayloadOffsetForPacket:(NSData *)packet counter:(uint64_t *)outCounter;
- (NSUInteger)transportPayloadOffsetForBytes:(const uint8_t *)bytes length:(size_t)length counter:(uint64_t *)outCounter;

// 12-byte ChaCha20-Poly1305 nonce for a transport counter: 4 zero bytes then
// the counter little-endian.
+ (void)transportNonce:(uint8_t *)out12 forCounter:(uint64_t)counter;

@end
