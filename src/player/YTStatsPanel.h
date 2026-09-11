#import <UIKit/UIKit.h>

@class AVPlayer;
@class YTSabr;

/** Всё, что нужно окну для одной строки показаний. */
@interface YTStatsSnapshot : NSObject

@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) NSDictionary *playerJson;
@property (nonatomic, strong) YTSabr *sabr;
@property (nonatomic, copy) NSString *videoId;
@property (nonatomic, strong) NSArray *heights;
@property (nonatomic, assign) CGSize viewport;
@property (nonatomic, assign) float rate;

@end

/**
 * Окно «статистика для сисадминов» — то же, что показывает сайт по
 * правой кнопке на ролике: что играет, чем закодировано, как идёт
 * сеть и сколько набрано в буфер.
 *
 * Подписи нарочно не переводятся: на сайте они тоже английские при
 * любом языке, и по ним удобно сверяться с ним же. Обновляется раз
 * в секунду, пока показано.
 *
 * Это `UIControl`, а не `UIView`, и не случайно: распознаватель нажатия
 * на сцене молчит, попав в `UIControl`, — иначе касание по окну прятало
 * бы пульт.
 */
@interface YTStatsPanel : UIControl

/** Откуда брать показания; спрашивается каждую секунду. */
@property (nonatomic, copy) YTStatsSnapshot *(^source)(void);

/** Нажали крестик. */
@property (nonatomic, copy) void (^onClose)(void);

/** Высота окна при заданной ширине. */
- (CGFloat)preferredHeight;

/** Начать обновляться / перестать. */
- (void)start;
- (void)stop;

@end
