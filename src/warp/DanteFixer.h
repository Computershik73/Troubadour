//
//  DanteFixer.h
//  Dante
//
//  Оркестратор «однокнопочной починки интернета». :
//
//    1. Детектор белых списков (TCP-пробы 350 мс).
//    2. Кандидаты по приоритету:
//         last-success (сохранённый конфиг) -> bootstrap-seed
//         (warp_bootstrap.json) -> verified seeds (warp_verified_seeds.json)
//         -> свежая регистрация WARP.
//    3. Каждый кандидат: поднять туннель, проверить
//       GET http://1.1.1.1/cdn-cgi/trace через локальный SOCKS5.
//    4. Успех -> запомнить как last-success и отдать SOCKS5-порт наружу.
//
//  Перед всем этим — отпечаток сети (DanteNetworkProbe): если наружу пускают
//  лишь к отдельным адресам, WARP не поднимется в принципе, и починка
//  сразу заканчивается неудачей, не тратя минуты на перебор.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, DanteFixerState) {
    DanteFixerStateIdle = 0,
    DanteFixerStateRunning,
    DanteFixerStateFixed,
    DanteFixerStateFailed
};

// Нотификация о любом изменении; userInfo[@"message"] — строка для лога.
extern NSString * const kDanteFixerDidUpdateNotification;

@interface DanteFixer : NSObject

// Последняя попытка уткнулась в сеть с белым списком: повторять бесполезно,
// пока сеть не сменится.
@property (nonatomic, readonly) BOOL restrictedNetwork;

+ (instancetype)sharedFixer;

@property (nonatomic, readonly) DanteFixerState state;
@property (nonatomic, readonly, copy) NSString *statusLine;
@property (nonatomic, readonly, copy) NSString *logText;
// Адрес локального SOCKS5-прокси ("127.0.0.1:10808"), когда всё починено.
@property (nonatomic, readonly, copy) NSString *proxyAddress;
@property (nonatomic, readonly) BOOL whitelistMode;

- (void)fixInternet;
// Починить на НОВОЙ собственной WARP-личности: зарегистрировать её и удалить
// прежние свои (например, скопированную у YouTube — две программы с одним
// ключом отбирают друг у друга сессию).
- (void)fixWithFreshIdentity;
- (void)cancel;
// Полностью выключить: отменить починку, опустить туннель, состояние Idle.
- (void)stop;
// Туннель сдох при работающей починке — вернуться в Failed, чтобы можно
// было перезапустить fixInternet.
- (void)markBroken:(NSString *)reason;

@end
