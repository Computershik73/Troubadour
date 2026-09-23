//
//  DanteNetworkProbe.h
//  Dante
//
//  Сетевые пробы для чинителя интернета. :
//  - детектор «белых списков»: TCP-connect к 1.1.1.1/1.0.0.1/8.8.8.8:443
//    с таймаутом 350 мс; если все недоступны — сеть урезана;
//  - верификация туннеля: GET http://1.1.1.1/cdn-cgi/trace через локальный
//    SOCKS5, который поднимает AWGTunnel.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, DNNetworkKind) {
    DNNetworkOpen = 0,     // наружу пускают, WARP может подняться
    DNNetworkRestricted,   // отвечают лишь отдельные адреса — белый список
    DNNetworkOffline       // не отвечает никто
};

@interface DanteNetworkProbe : NSObject

// Отпечаток сети: пускают ли наружу. Результат кэшируется на 30 с для той же
// сети. Блокирующий вызов (до ~5 с), дергать из фонового потока.
+ (DNNetworkKind)fingerprintNetwork;

// Чем эта сеть отличается от других: Wi-Fi — по шлюзу, сотовая — по интерфейсу.
// По смене ключа служба понимает, что устройство перешло в другую сеть.
+ (NSString *)networkKey;

// YES, если все опорные хосты недоступны (режим белых списков).
// Блокирующий вызов, дергать из фонового потока.
+ (BOOL)detectWhitelistMode;

// Проверка живости туннеля через его SOCKS5-порт: SOCKS5 CONNECT к
// 1.1.1.1:80, GET /cdn-cgi/trace, ждём HTTP 200 и маркер "warp=" в теле.
+ (BOOL)verifyTunnelOnSOCKSPort:(uint16_t)port timeout:(NSTimeInterval)timeout;

// То же, но вернуть тело ответа trace (colo=, ip=, warp=…); nil — туннель не ответил.
+ (NSString *)traceOnSOCKSPort:(uint16_t)port timeout:(NSTimeInterval)timeout;

// Случайное имя из SNI-ресурса бандла (white.sni, proven_ru.sni, ...).
+ (NSString *)randomSNIFromResource:(NSString *)name;

@end
