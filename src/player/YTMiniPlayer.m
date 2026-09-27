#import "YTMiniPlayer.h"

#import <QuartzCore/QuartzCore.h>

#import "YTHlsProxy.h"
#import "YTMetrics.h"
#import "YTNowPlaying.h"
#import "YTTheme.h"
#import "YTUtil.h"

/** Числа из `MiniPlayer.cs`: окно, отступ от краёв, кнопки. */
static const CGFloat YTMiniWidth = 220;
static const CGFloat YTMiniHeight = 124;
static const CGFloat YTMiniMargin = 10;
static const CGFloat YTMiniButton = 32;

/**
 * Пределы размера при разведении пальцев.
 *
 * Меньше ста шестидесяти окно перестаёт быть окном — в нём не разобрать
 * ни кадра, ни кнопок; больше `CompactWidth` из оригинала (360) оно
 * закрывает половину экрана телефона, и проще уже развернуть страницу.
 */
static const CGFloat YTMiniMinWidth = 160;
static const CGFloat YTMiniMaxWidth = 360;

/**
 * Правила для распознавателей окна: касания по кнопкам им не отдаются.
 *
 * **Без этого кнопки окна не работают на iOS 5.** Распознаватели висят
 * на окне, а кнопки лежат внутри него — ниже по дереву. С iOS 6 UIKit
 * разводит их сам: касание, которое берёт на себя `UIControl`,
 * надвидовому распознавателю уже не достаётся. На пятой такого правила
 * нет — распознаватель забирает касание себе и, поскольку
 * `cancelsTouchesInView` включён по умолчанию, отменяет доставку кнопке.
 * Нажатие по «✕» уходит в пустоту, а окно вместо закрытия разворачивается
 * обратно в страницу: срабатывает нажатие по окну.
 *
 * Ровно та же беда была у пульта на странице ролика и лечится тем же —
 * см. `gestureRecognizer:shouldReceiveTouch:` в `YTPlayerViewController`.
 *
 * Отдельным объектом, а не самим классом: здесь всё — методы класса,
 * но получателем распознавателя класс быть не может, ссылка на него
 * слабая, а классы под ARC слабыми ссылками не держатся.
 */
@interface YTMiniRules : NSObject <UIGestureRecognizerDelegate>
@end

@implementation YTMiniRules

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
       shouldReceiveTouch:(UITouch *)touch {
    UIView *hit = [touch view];

    while (hit != nil) {
        if ([hit isKindOfClass:[UIControl class]]) {
            return NO;
        }

        hit = [hit superview];
    }

    return YES;
}

@end

static YTMiniRules *YTMiniGuard = nil;

/** Что страница свёрнутого ролика умеет услышать при закрытии окна. */
@protocol YTMiniOwnerClosing <NSObject>
- (void)miniPlayerWillClose;
@end

static UIView *YTMiniHost = nil;
static UIView *YTMiniVideo = nil;
static AVPlayer *YTMiniAVPlayer = nil;
static AVPlayerLayer *YTMiniLayer = nil;
static UIButton *YTMiniClose = nil;
static UIButton *YTMiniPlayPause = nil;
static UILabel *YTMiniTitle = nil;
static NSString *YTMiniVideoId = nil;
static NSString *YTMiniTitleText = nil;

/** Страница свёрнутого ролика — её возвращают по нажатию, а не строят заново. */
static UIViewController *YTMiniOwner = nil;

/** Отвязан ли слой от плеера — то есть были ли мы в фоне. */
static BOOL YTMiniDetached = NO;

/** Куда человек перетащил окно и какой ширины растянул. */
static CGPoint YTMiniOrigin = {0, 0};
static CGFloat YTMiniUserWidth = 0;
static BOOL YTMiniMoved = NO;

@implementation YTMiniPlayer

+ (BOOL)isActive {
    return YTMiniHost != nil && YTMiniAVPlayer != nil;
}

+ (NSString *)videoId {
    return YTMiniVideoId;
}

/** Куда класть окно: поверх содержимого корневого контроллера. */
+ (UIView *)hostView {
    UIWindow *window = [[UIApplication sharedApplication] keyWindow];

    return [[window rootViewController] view] ?: window;
}

+ (void)build {
    if (YTMiniHost != nil) {
        return;
    }

    YTMiniHost = [[UIView alloc] initWithFrame:CGRectZero];

    [YTMiniHost setBackgroundColor:[UIColor blackColor]];
    [[YTMiniHost layer] setCornerRadius:6];
    [YTMiniHost setClipsToBounds:YES];

    /**
     * Тень — не украшение: окно висит поверх лент, и без неё его край
     * теряется на тёмной карточке.
     */
    [[YTMiniHost layer] setShadowColor:[[UIColor blackColor] CGColor]];
    [[YTMiniHost layer] setShadowOpacity:0.4f];
    [[YTMiniHost layer] setShadowRadius:6];
    [[YTMiniHost layer] setShadowOffset:CGSizeMake(0, 2)];
    [YTMiniHost setClipsToBounds:NO];

    YTMiniVideo = [[UIView alloc] initWithFrame:CGRectZero];

    [YTMiniVideo setBackgroundColor:[UIColor blackColor]];
    [[YTMiniVideo layer] setCornerRadius:6];
    [YTMiniVideo setClipsToBounds:YES];
    [YTMiniHost addSubview:YTMiniVideo];

    YTMiniTitle = YTLabel(YTFontRegular(11), [UIColor whiteColor], 1);

    [YTMiniTitle setBackgroundColor:[UIColor colorWithWhite:0 alpha:0.55f]];
    [YTMiniHost addSubview:YTMiniTitle];

    YTMiniPlayPause = [self roundButton:@"pl_pause" action:@selector(togglePlay)];
    YTMiniClose = [self roundButton:nil action:@selector(close)];

    [YTMiniClose setTitle:@"✕" forState:UIControlStateNormal];
    [[YTMiniClose titleLabel] setFont:YTFontRegular(15)];
    [YTMiniClose setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

    [YTMiniHost addSubview:YTMiniPlayPause];
    [YTMiniHost addSubview:YTMiniClose];

    YTMiniGuard = [[YTMiniRules alloc] init];

    // Нажатие по окну — вернуться к странице ролика.
    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(restore)];

    [tap setDelegate:YTMiniGuard];
    [YTMiniHost addGestureRecognizer:tap];

    /**
     * Перетаскивание одним пальцем и разведение двумя — как в оригинале,
     * где окно `Popup` тоже и таскают, и растягивают.
     *
     * Оба распознавателя живут рядом с нажатием: нажатие срабатывает
     * только когда палец не поехал, так что разнимать их не нужно.
     */
    UIPanGestureRecognizer *drag =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];

    [drag setDelegate:YTMiniGuard];
    [YTMiniHost addGestureRecognizer:drag];

    UIPinchGestureRecognizer *pinch =
        [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinched:)];

    [pinch setDelegate:YTMiniGuard];
    [YTMiniHost addGestureRecognizer:pinch];

    /**
     * Уход в фон: слой отвязывается от плеера, а плеер играет дальше.
     *
     * Без этого система останавливает воспроизведение, как только слой
     * уходит с экрана: видеодорожка есть, а показывать её негде.
     * Отвязанному плееру всё равно — он продолжает выдавать звук, и это
     * ровно то, что нужно для фонового прослушивания. У страницы ролика
     * то же самое сделано своим обработчиком.
     */
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidEnterBackgroundNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        [YTMiniLayer setPlayer:nil];

        YTMiniDetached = YES;
    }];

    /**
     * Возврат: слой делается заново, а не оживляется прежний.
     *
     * Пока приложение было в фоне, система выбросила его содержимое,
     * и `setPlayer:` на опустевшем слое кадра не заводит — в окне
     * оставался бы чёрный прямоугольник с работающим звуком. То же
     * самое и по той же причине сделано на странице ролика.
     */
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        [self remakeLayer];
    }];
}

/** Ставит окну новый слой того же плеера — после возврата из фона. */
+ (void)remakeLayer {
    if (!YTMiniDetached || YTMiniAVPlayer == nil) {
        return;
    }

    YTMiniDetached = NO;

    [YTMiniLayer removeFromSuperlayer];

    YTMiniLayer = [AVPlayerLayer playerLayerWithPlayer:YTMiniAVPlayer];

    [YTMiniLayer setVideoGravity:AVLayerVideoGravityResizeAspect];
    [YTMiniLayer setFrame:[YTMiniVideo bounds]];
    [[YTMiniVideo layer] addSublayer:YTMiniLayer];

    NSLog(@"[YouTube/Мини] Вернулись из фона — поверхность пересоздана");
}

/** Круглая кнопка на полупрозрачной подложке — как в оригинале. */
+ (UIButton *)roundButton:(NSString *)icon action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];

    [button setBackgroundColor:[UIColor colorWithWhite:0 alpha:120.0f / 255.0f]];
    [[button layer] setCornerRadius:YTMiniButton / 2];

    if (icon != nil) {
        [button setImage:YTDarkIcon(icon) forState:UIControlStateNormal];
    }

    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    return button;
}

+ (UIViewController *)owner {
    return YTMiniOwner;
}

+ (void)showWithPlayer:(AVPlayer *)player
                 layer:(AVPlayerLayer *)layer
               videoId:(NSString *)videoId
                 title:(NSString *)title
                 owner:(UIViewController *)owner {
    if (player == nil) {
        return;
    }

    [self build];

    YTMiniAVPlayer = player;
    YTMiniLayer = layer;
    YTMiniVideoId = [videoId copy];
    YTMiniTitleText = [title copy];
    YTMiniOwner = owner;

    [YTMiniTitle setText:title];

    if (layer != nil) {
        [[YTMiniVideo layer] addSublayer:layer];
    }

    UIView *host = [self hostView];

    [host addSubview:YTMiniHost];
    [host bringSubviewToFront:YTMiniHost];

    [self place];
    [self refreshPlayIcon];

    [self takeRemoteCommands];

    NSLog(@"[YouTube/Мини] Свёрнут ролик %@", videoId);
}

/**
 * Забирает кнопки замка себе: страницы ролика на виду больше нет, а звук
 * идёт из нашего плеера — значит, и распоряжаться им нам.
 */
+ (void)takeRemoteCommands {
    [YTNowPlaying takeCommandsPlay:^{
        if (![self isPlaying]) {
            [self togglePlay];
        }
    } pause:^{
        if ([self isPlaying]) {
            [self togglePlay];
        }
    } skip:^(NSTimeInterval seconds) {
        [self skipBy:seconds];
    } seekTo:^(NSTimeInterval seconds) {
        [self seekTo:seconds];
    }];
}

/** Сдвиг по ролику кнопками замка — на те же секунды, что и на странице. */
+ (void)skipBy:(NSTimeInterval)seconds {
    if (YTMiniAVPlayer == nil) {
        return;
    }

    NSTimeInterval now = CMTimeGetSeconds([YTMiniAVPlayer currentTime]);

    if (isnan(now) || isinf(now)) {
        return;
    }

    [self seekTo:now + seconds];
}

/** Перетаскивание ползунка на замке. */
+ (void)seekTo:(NSTimeInterval)seconds {
    if (YTMiniAVPlayer == nil) {
        return;
    }

    /**
     * Допуск в полсекунды — тот же, что на странице: точный прыжок велит
     * плееру собрать именно тот кадр, а это самое хрупкое место на
     * неспешном железе.
     */
    [YTMiniAVPlayer seekToTime:CMTimeMakeWithSeconds(MAX((NSTimeInterval)0, seconds), 600)
               toleranceBefore:CMTimeMakeWithSeconds(0.5, 600)
                toleranceAfter:CMTimeMakeWithSeconds(0.5, 600)];

    [YTNowPlaying refreshWithPlayer:YTMiniAVPlayer
                           duration:[[YTHlsProxy shared] duration]];
}

/** Текущая ширина окна: растянутая человеком либо обычная. */
+ (CGFloat)currentWidth {
    if (YTMiniUserWidth > 0) {
        return YTMiniUserWidth;
    }

    return YTMiniWidth;
}

/**
 * Правый нижний угол над полосой вкладок — пока окно не двигали.
 * Стоит человеку его перетащить, и место запоминается за ним.
 */
+ (void)place {
    UIView *host = [self hostView];
    CGRect box = [host bounds];

    CGFloat width = [self currentWidth];
    CGFloat height = floor(width * YTMiniHeight / YTMiniWidth);

    CGFloat left;
    CGFloat top;

    if (YTMiniMoved) {
        left = YTMiniOrigin.x;
        top = YTMiniOrigin.y;
    } else {
        left = box.size.width - width - YTMiniMargin;
        top = box.size.height - height - YTMiniMargin - YTTabBarHeight;
    }

    // За край не пускаем ни при перетаскивании, ни при повороте экрана.
    left = MIN(MAX(left, YTMiniMargin), MAX(YTMiniMargin, box.size.width - width - YTMiniMargin));
    top = MIN(MAX(top, YTMiniMargin), MAX(YTMiniMargin, box.size.height - height - YTMiniMargin));

    YTMiniOrigin = CGPointMake(left, top);

    [YTMiniHost setFrame:CGRectMake(left, top, width, height)];
    [YTMiniVideo setFrame:[YTMiniHost bounds]];

    if (YTMiniLayer != nil) {
        [YTMiniLayer setFrame:[YTMiniVideo bounds]];
    }

    [YTMiniPlayPause setFrame:CGRectMake(4, 4, YTMiniButton, YTMiniButton)];
    [YTMiniClose setFrame:CGRectMake(width - YTMiniButton - 4, 4,
                                     YTMiniButton, YTMiniButton)];

    [YTMiniTitle setFrame:CGRectMake(0, height - 20, width, 20)];
}

+ (void)dragged:(UIPanGestureRecognizer *)gesture {
    CGPoint move = [gesture translationInView:[self hostView]];

    YTMiniMoved = YES;
    YTMiniOrigin = CGPointMake(YTMiniOrigin.x + move.x, YTMiniOrigin.y + move.y);

    [gesture setTranslation:CGPointZero inView:[self hostView]];

    [self place];
}

+ (void)pinched:(UIPinchGestureRecognizer *)gesture {
    CGFloat width = [self currentWidth] * [gesture scale];

    YTMiniUserWidth = MIN(MAX(width, YTMiniMinWidth), YTMiniMaxWidth);

    /**
     * Множитель сбрасывается на каждом шаге: иначе он копится от начала
     * жеста, и окно улетает в предел с первого же движения.
     */
    [gesture setScale:1];

    /**
     * Растёт окно от того угла, за который его держат, — то есть влево
     * и вверх, если оно стоит справа внизу. Проще всего этого добиться,
     * оставив на месте правый нижний угол.
     */
    if (YTMiniMoved) {
        CGRect frame = [YTMiniHost frame];
        CGFloat height = floor(YTMiniUserWidth * YTMiniHeight / YTMiniWidth);

        YTMiniOrigin = CGPointMake(CGRectGetMaxX(frame) - YTMiniUserWidth,
                                   CGRectGetMaxY(frame) - height);
    }

    [self place];
}

+ (void)refreshPlayIcon {
    BOOL playing = ([YTMiniAVPlayer rate] > 0);

    [YTMiniPlayPause setImage:YTDarkIcon(playing ? @"pl_pause" : @"pl_play")
                     forState:UIControlStateNormal];
}

+ (BOOL)isPlaying {
    return [YTMiniAVPlayer rate] > 0;
}

+ (void)togglePlay {
    if (YTMiniAVPlayer == nil) {
        return;
    }

    if ([YTMiniAVPlayer rate] > 0) {
        [YTMiniAVPlayer pause];
    } else {
        [YTMiniAVPlayer play];
    }

    [self refreshPlayIcon];

    // Карточка на замке показывает ход того же плеера — обновляем и её.
    [YTNowPlaying refreshWithPlayer:YTMiniAVPlayer
                           duration:[[YTHlsProxy shared] duration]];
}

/** Возврат к странице: окно прячется, а плеер уходит вместе с ней. */
+ (void)restore {
    NSString *videoId = YTMiniVideoId;

    if ([videoId length] == 0) {
        return;
    }

    /**
     * Возвращаем ту самую страницу, которую свернули.
     *
     * Она цела: описание разобрано, похожие набраны, плейлист и место
     * в нём известны. Открыв вместо неё новую, всё это пришлось бы брать
     * из сети сызнова, а плейлист терялся совсем — о нём знала только
     * прежняя страница, и в `openVideo:` его передать нечем.
     *
     * Запасной ход остаётся: если страницы почему-то нет, открываем
     * ролик обычным путём.
     */
    if (YTMiniOwner != nil) {
        /**
         * Страница может **уже стоять** в стопке — тогда к ней возвращаются,
         * а не толкают её ещё раз.
         *
         * Так выходит при переходе на канал со страницы ролика: страница
         * остаётся под каналом и ждёт возврата, а плеер тем временем
         * живёт в мини-окне. Положить один и тот же вид в стопку дважды
         * нельзя — UIKit на это отвечает падением.
         */
        if ([YTNav contains:YTMiniOwner]) {
            [YTNav popTo:YTMiniOwner];
        } else {
            [YTNav push:YTMiniOwner];
        }

        return;
    }

    [YTNav openVideo:videoId title:YTMiniTitleText];
}

+ (AVPlayer *)adoptPlayer {
    AVPlayer *player = YTMiniAVPlayer;

    YTMiniAVPlayer = nil;
    YTMiniVideoId = nil;
    YTMiniOwner = nil;

    [YTMiniHost removeFromSuperview];

    return player;
}

+ (AVPlayerLayer *)adoptLayer {
    AVPlayerLayer *layer = YTMiniLayer;

    YTMiniLayer = nil;

    [layer removeFromSuperlayer];

    return layer;
}

/** Забыть, куда его таскали, — при закрытии и при новом сворачивании. */
+ (void)forgetPlacement {
    YTMiniMoved = NO;
    YTMiniUserWidth = 0;
}

+ (void)close {
    /**
     * Странице — что просмотр кончился: запись о нём закрывается
     * последним отрезком. Без этого ролик, закрытый из окна, уходил
     * в историю одной отметкой «0…0 с», а просмотренное после неё
     * не доходило до сервера вовсе (журнал 27.09.2026).
     */
    if ([YTMiniOwner respondsToSelector:@selector(miniPlayerWillClose)]) {
        [(id<YTMiniOwnerClosing>)YTMiniOwner miniPlayerWillClose];
    }

    [YTMiniAVPlayer pause];

    /**
     * Наблюдателей снимает сама страница — до того, как плеер уйдёт.
     *
     * Здесь плеер освобождается, и система на iOS 8 и новее проверяет,
     * не остался ли на нём кто-нибудь подписан. Оставшийся наблюдатель
     * означает падение с «был освобождён, пока на нём ещё висели
     * наблюдатели»; страница снимает своих в `detachPlayerObservers`,
     * но если её к этому мигу уже нет, звать некого — потому и просим
     * заранее, при сворачивании.
     */
    [YTMiniLayer removeFromSuperlayer];
    [YTMiniHost removeFromSuperview];

    YTMiniAVPlayer = nil;
    YTMiniLayer = nil;
    YTMiniVideoId = nil;
    YTMiniTitleText = nil;
    YTMiniOwner = nil;

    [self forgetPlacement];

    /**
     * Петлю гасим здесь же: свёрнутый ролик — единственное, что её
     * держало, и без этого она продолжила бы качать куски в пустоту.
     */
    [[YTHlsProxy shared] close];

    // Играть больше нечему — снимаем и карточку, и кнопки на замке.
    [YTNowPlaying clear];
    [YTNowPlaying releaseCommands];

    NSLog(@"[YouTube/Мини] Закрыт");
}

@end
