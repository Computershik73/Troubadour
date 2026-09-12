#import "YTSimpleScreens.h"

#import "YTStrings.h"

#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

#import "YTApi.h"
#import "YTAuth.h"
#import "YTHlsProxy.h"
#import "YTImageLoader.h"
#import "YTMetrics.h"
#import "YTMiniPlayer.h"
#import "YTRoundedImageView.h"
#import "YTSettings.h"
#import "YTSettingsSheet.h"
#import "YTJson.h"
#import "YTStreams.h"
#import "YTTheme.h"
#import "YTUtil.h"
#import "YTVideoItem.h"
#import "YTWebAuth.h"

/**
 * Числа — из Shorts.xaml.
 *
 *     подписи     Margin="14,0,82,16";
 *                 строка канала Height="34" с отступом 6 снизу,
 *                 кружок 30 в колонке 42, имя 14 с отступом 8,
 *                 название 12
 *     кнопки      столбец справа, Margin="0,0,12,18";
 *                 кнопка 34 со значком 24, подпись 11 с отступом 2,
 *                 между кнопками 14
 *
 * Кадр здесь всегда тёмный, как и вся страница Shorts: значки в оригинале
 * берутся прямо из `Assets/Dark`, без выбора по теме, — потому что лежат
 * поверх видео, а не поверх страницы.
 */

static const CGFloat YTShortSide = 14;
static const CGFloat YTShortButtons = 82;
static const CGFloat YTShortButton = 34;
static const CGFloat YTShortIcon = 24;
static const CGFloat YTShortAvatar = 30;
static const CGFloat YTShortGap = 14;


#pragma mark - Страница

/**
 * Одна страница ленты: кадр, превью под ним и подписи поверх.
 *
 * Плеер живёт только у текущей страницы: соседние показывают превью.
 * Так же ведёт себя и оригинал, где `MediaPlayerElement` один, а остальные
 * страницы — картинки.
 */
@interface YTShortPage : UIView

@property (nonatomic, strong) YTVideoItem *item;

- (void)showThumbnail;
- (void)attachLayer:(CALayer *)layer;
- (void)setBusy:(BOOL)busy;

/** Подписи приезжают позже самой ленты — вместе с ответом `/player`. */
- (void)applyTitle:(NSString *)title channel:(NSString *)channel;

/** Три действия правого верхнего угла: поиск, качество, «ещё». */
- (void)setTopActions:(NSArray *)actions;

/** Четыре действия столбца: нравится, не нравится, комментарии, поделиться. */
- (void)setRailActions:(NSArray *)actions;

/** Подписи под кнопками; пустое значение прячет подпись. */
- (void)applyLikes:(NSString *)likes comments:(NSString *)comments;

/** Кружок автора; лента reel его не присылает, он приходит позже. */
- (void)applyAvatar:(NSString *)url;

/** Залитый значок у поставленной оценки — как у обычного ролика. */
- (void)applyLiked:(BOOL)liked disliked:(BOOL)disliked;

/** Доля проигранного, 0…1. Отрицательная прячет полосу. */
- (void)applyProgress:(CGFloat)share;

/** Высота полосы снизу — по ней узнаётся касание перемотки. */
+ (CGFloat)progressStrip;

@end

@implementation YTShortPage {
    YTRoundedImageView *_thumb;
    UIView *_videoHost;

    YTRoundedImageView *_avatar;
    UILabel *_channel;
    UILabel *_title;

    NSMutableArray *_buttons;

    UILabel *_likeCount;
    UILabel *_commentCount;

    /** Правый верхний угол: лупа, шестерёнка и «ещё». */
    NSMutableArray *_topButtons;

    UIView *_progressTrack;
    UIView *_progressFill;
    YTLoadingRing *_busy;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    _buttons = [NSMutableArray array];

    [self setBackgroundColor:YTColor(0x0F0F0F)];

    _thumb = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];
    [_thumb setPlaceholderColor:YTColor(0x0F0F0F)];
    [self addSubview:_thumb];

    _videoHost = [[UIView alloc] initWithFrame:CGRectZero];
    [_videoHost setBackgroundColor:[UIColor clearColor]];
    [_videoHost setHidden:YES];
    [self addSubview:_videoHost];

    _avatar = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];
    [_avatar setCircular:YES];
    [_avatar setPlaceholderColor:[UIColor colorWithWhite:1 alpha:0.2]];
    [self addSubview:_avatar];

    _channel = YTLabel(YTFontSemiBold(14), [UIColor whiteColor], 1);
    [self addSubview:_channel];

    _title = YTLabel(YTFontRegular(12), [UIColor whiteColor], 2);
    [self addSubview:_title];

    NSArray *icons = [NSArray arrayWithObjects:
        @"pl_like", @"pl_dislike", @"pl_comments", @"pl_send", nil];

    for (NSString *icon in icons) {
        /**
         * Каждая кнопка — нажимаемый вид с картинкой внутри, а не просто
         * картинка. Раньше это были картинки, и нажатия по ним проваливались
         * насквозь — их подбирала общая протяжка по кадру и толковала как
         * «пауза». Теперь касание останавливается на кнопке.
         */
        YTTappableView *host = [[YTTappableView alloc] initWithFrame:CGRectZero];

        [host setHighlights:NO];
        [self addSubview:host];

        UIImageView *button = [[UIImageView alloc] initWithFrame:CGRectZero];

        [button setUserInteractionEnabled:NO];
        [button setContentMode:UIViewContentModeScaleAspectFit];

        /**
         * Значок из тёмного набора, какая бы тема ни стояла.
         *
         * В `Shorts.xaml` путь зашит как `Assets/Dark/player/…` — и это
         * не небрежность: столбец лежит поверх кадра, а кадр тёмный
         * всегда. Светлый набор на нём попросту не виден.
         */
        [button setImage:YTDarkIcon(icon)];

        [host addSubview:button];
        [_buttons addObject:host];
    }

    /**
     * Подписи под кнопками — счётчики лайков и комментариев.
     *
     * Столбец кнопок стоит поверх кадра, поэтому подписи белые и мелкие,
     * как в оригинале: разобрать их надо на любом кадре, а закрывать
     * ими картинку нельзя.
     */
    _likeCount = YTLabel(YTFontRegular(10), [UIColor whiteColor], 1);
    [_likeCount setTextAlignment:NSTextAlignmentCenter];
    [self addSubview:_likeCount];

    _commentCount = YTLabel(YTFontRegular(10), [UIColor whiteColor], 1);
    [_commentCount setTextAlignment:NSTextAlignmentCenter];
    [self addSubview:_commentCount];

    /**
     * Полоса воспроизведения — тонкая, у самого низа.
     *
     * В оригинале она такая же: не элемент управления, а подсказка,
     * сколько осталось. Перемотка по ней тоже есть, но касание ловит
     * не полоса, а сам раздел: две точки высоты пальцем не взять,
     * и запас под касание там куда больше нарисованного.
     */
    _progressTrack = [[UIView alloc] initWithFrame:CGRectZero];
    [_progressTrack setBackgroundColor:[UIColor colorWithWhite:1 alpha:0.3]];
    [_progressTrack setHidden:YES];
    [self addSubview:_progressTrack];

    _progressFill = [[UIView alloc] initWithFrame:CGRectZero];
    [_progressFill setBackgroundColor:[UIColor whiteColor]];
    [_progressFill setHidden:YES];
    [self addSubview:_progressFill];

    /**
     * Правый верхний угол — `Margin="12,10,12,0"` из `Shorts.xaml`:
     * лупа 34×34 со значком 24, шестерёнка со значком 22, «ещё» со значком
     * 24, между кнопками 12. Значки тоже только тёмные.
     */
    _topButtons = [NSMutableArray array];

    NSArray *top = [NSArray arrayWithObjects:@"search", @"pl_settings", @"more", nil];

    for (NSString *icon in top) {
        YTTappableView *button = [[YTTappableView alloc] initWithFrame:CGRectZero];

        [button setHighlights:NO];

        UIImageView *glyph = [[UIImageView alloc] initWithFrame:CGRectZero];

        [glyph setContentMode:UIViewContentModeScaleAspectFit];
        [glyph setImage:YTDarkIcon(icon)];
        [glyph setUserInteractionEnabled:NO];
        [button addSubview:glyph];

        [self addSubview:button];
        [_topButtons addObject:button];
    }

    _busy = [[YTLoadingRing alloc] initWithFrame:CGRectZero];
    [self addSubview:_busy];

    return self;
}

/** Действия верхних кнопок задаёт раздел: страница о них не знает. */
- (void)setTopActions:(NSArray *)actions {
    for (NSUInteger i = 0; i < [_topButtons count] && i < [actions count]; i++) {
        [[_topButtons objectAtIndex:i] setOnTap:[actions objectAtIndex:i]];
    }
}

- (void)setRailActions:(NSArray *)actions {
    for (NSUInteger i = 0; i < [_buttons count] && i < [actions count]; i++) {
        [[_buttons objectAtIndex:i] setOnTap:[actions objectAtIndex:i]];
    }
}

+ (CGFloat)progressStrip {
    return 28;
}

- (void)applyProgress:(CGFloat)share {
    BOOL known = (share >= 0);

    [_progressTrack setHidden:!known];
    [_progressFill setHidden:!known];

    if (!known) {
        return;
    }

    CGRect box = [self bounds];
    CGFloat height = 2;
    CGFloat top = box.size.height - height;

    [_progressTrack setFrame:CGRectMake(0, top, box.size.width, height)];
    [_progressFill setFrame:CGRectMake(0, top,
                                       box.size.width * MIN(MAX(share, 0), 1), height)];
}

- (void)applyAvatar:(NSString *)url {
    if ([url length] == 0) {
        return;
    }

    [YTImageLoader loadInto:_avatar url:url targetWidth:YTShortAvatar];
}

- (void)applyLiked:(BOOL)liked disliked:(BOOL)disliked {
    if ([_buttons count] < 2) {
        return;
    }

    UIView *like = [_buttons objectAtIndex:0];
    UIView *dislike = [_buttons objectAtIndex:1];

    [(UIImageView *)[[like subviews] objectAtIndex:0]
        setImage:YTDarkIcon(liked ? @"pl_like_on" : @"pl_like")];

    [(UIImageView *)[[dislike subviews] objectAtIndex:0]
        setImage:YTDarkIcon(disliked ? @"pl_dislike_on" : @"pl_dislike")];
}

- (void)applyLikes:(NSString *)likes comments:(NSString *)comments {
    [_likeCount setText:likes];
    [_commentCount setText:comments];

    [self setNeedsLayout];
}

- (void)setItem:(YTVideoItem *)item {
    _item = item;

    // «Shorts» — это не название, а заглушка, которой лента помечает
    // ролик без подписи: в оригинале `Title = "Shorts"` ставится ровно
    // до того, как придёт настоящее название.
    [_title setText:[item.title isEqualToString:@"Shorts"] ? @"" : item.title];
    [_channel setText:item.channelTitle];

    /**
     * Ширина берётся у экрана, а не у своих границ: привязка случается
     * до первой раскладки, границы тогда нулевые, и загрузчик просил
     * у CDN картинку нулевой ширины — то есть самую мелкую, `default.jpg`
     * 120×90, а декодер с потолком в ноль пикселей не разбирал и её.
     */
    [YTImageLoader loadInto:_thumb
                        url:item.thumbnail
                targetWidth:[[UIScreen mainScreen] bounds].size.width];
    [YTImageLoader loadInto:_avatar url:item.channelThumbnail targetWidth:YTShortAvatar];

    [self showThumbnail];
}

- (void)applyTitle:(NSString *)title channel:(NSString *)channel {
    if ([title length] > 0) {
        [_title setText:title];
        _item.title = title;
    }

    if ([channel length] > 0) {
        [_channel setText:channel];
        _item.channelTitle = channel;
    }
}

- (void)showThumbnail {
    [_videoHost setHidden:YES];
    [_thumb setHidden:NO];

    for (CALayer *layer in [[[_videoHost layer] sublayers] copy]) {
        [layer removeFromSuperlayer];
    }
}

- (void)attachLayer:(CALayer *)layer {
    for (CALayer *old in [[[_videoHost layer] sublayers] copy]) {
        [old removeFromSuperlayer];
    }

    [layer setFrame:[_videoHost bounds]];
    [[_videoHost layer] addSublayer:layer];

    [_videoHost setHidden:NO];

    /**
     * Превью остаётся под кадром, а не убирается.
     *
     * Кадр теперь вписывается целиком, и у горизонтального ролика сверху
     * и снизу остаются поля. Пустые они выглядят провалами; превью же
     * растянуто на всё место и заполняет их — тем самым, что и было
     * видно до запуска. Поверх него ложится сам кадр, так что подмены
     * не заметно.
     */
}

- (void)setBusy:(BOOL)busy {
    if (busy) {
        [_busy start];
    } else {
        [_busy stop];
    }

    [_busy setHidden:!busy];
}

- (void)layoutSubviews {
    CGRect box = [self bounds];

    [_thumb setFrame:box];
    [_videoHost setFrame:box];

    for (CALayer *layer in [[_videoHost layer] sublayers]) {
        [layer setFrame:[_videoHost bounds]];
    }

    [_busy setFrame:CGRectMake(box.size.width / 2 - 18, box.size.height / 2 - 18, 36, 36)];

    // Кнопки идут справа налево, с отступом 12 между ними.
    CGFloat side = 34;
    CGFloat right = box.size.width - 12;
    // `Margin="12,10,…"` в оригинале отмерян от края страницы, а строка
    // состояния на Shorts прозрачная и кадр под неё уходит. Поэтому
    // отступ небольшой: кнопки должны стоять высоко, а не под шапкой.
    CGFloat top = YTStatusBarHeight() + 2;

    for (NSInteger i = [_topButtons count] - 1; i >= 0; i--) {
        YTTappableView *button = [_topButtons objectAtIndex:(NSUInteger)i];

        [button setFrame:CGRectMake(right - side, top, side, side)];

        // Значок 24 по центру ячейки; у шестерёнки в оригинале 22.
        CGFloat glyph = (i == 1) ? 22 : 24;

        [[[button subviews] objectAtIndex:0]
            setFrame:CGRectMake((side - glyph) / 2, (side - glyph) / 2, glyph, glyph)];

        right -= side + 12;
    }

    // Столбец кнопок справа: `Margin="0,0,12,18"`.
    CGFloat x = box.size.width - 12 - YTShortButton;
    CGFloat y = box.size.height - 18 - YTShortButton;

    for (NSInteger i = [_buttons count] - 1; i >= 0; i--) {
        YTTappableView *button = [_buttons objectAtIndex:(NSUInteger)i];

        /**
         * Со счётчиком значок поднимается в верхнюю часть ячейки,
         * а подпись занимает нижнюю: иначе она наползла бы на соседнюю
         * кнопку — промежуток между ними всего четырнадцать точек.
         */
        UILabel *count = nil;

        if (i == 0) { count = _likeCount; }
        else if (i == 2) { count = _commentCount; }

        BOOL titled = ([[count text] length] > 0);

        CGFloat iconTop = titled ? 0 : (YTShortButton - YTShortIcon) / 2;

        // Хозяин занимает всю ячейку — по нему и попадают пальцем;
        // значок сидит внутри и касаний не берёт.
        [button setFrame:CGRectMake(x, y, YTShortButton, YTShortButton)];

        [[[button subviews] objectAtIndex:0]
            setFrame:CGRectMake((YTShortButton - YTShortIcon) / 2,
                                iconTop, YTShortIcon, YTShortIcon)];

        if (titled) {
            [count setFrame:CGRectMake(x - 6, y + YTShortIcon + 1,
                                       YTShortButton + 12, 12)];
        }

        y -= YTShortButton + YTShortGap;
    }

    // Подписи: `Margin="14,0,82,16"`.
    CGFloat textRight = box.size.width - YTShortButtons;
    CGFloat textWidth = textRight - YTShortSide;

    CGFloat titleHeight = 32;
    CGFloat bottom = box.size.height - 16;

    [_title setFrame:CGRectMake(YTShortSide, bottom - titleHeight, textWidth, titleHeight)];

    CGFloat rowTop = bottom - titleHeight - 6 - YTShortButton;

    [_avatar setFrame:CGRectMake(YTShortSide, rowTop + (YTShortButton - YTShortAvatar) / 2,
                                 YTShortAvatar, YTShortAvatar)];

    // Колонка кружка — 42, подпись начинается с отступом 8 внутри неё.
    [_channel setFrame:CGRectMake(YTShortSide + 42 + 8, rowTop,
                                  textWidth - 42 - 8, YTShortButton)];
}

@end


#pragma mark - Раздел

@interface YTShortsView () <UIScrollViewDelegate>
@end

@interface YTShortsView () <UIGestureRecognizerDelegate>
@end

@implementation YTShortsView {
    UIScrollView *_pager;
    NSMutableArray *_pages;
    NSMutableArray *_items;

    YTStatusView *_status;
    YTGeneration *_generation;

    AVPlayer *_player;

    id _timeObserver;

    /**
     * Сторож застревания: кадр стоит, а плеер играет — значит, идёт набор.
     *
     * Отдельным таймером, а не наблюдателем плеера: тот срабатывает
     * по движению времени, а застревание — это как раз его остановка.
     */
    NSTimer *_stallTimer;
    NSTimeInterval _stallSeen;
    NSTimeInterval _stalledFor;
    BOOL _stalled;

    /** Сколько брошенных кадров уже отмечено в журнале. */
    NSInteger _droppedSeen;

    YTCommentsSheet *_commentsSheet;

    /** Панель настроек за шестерёнкой — та же, что у обычного ролика. */
    YTSettingsSheet *_settings;
    NSInteger _settingsPage;

    /** Выбранная озвучка и скорость — как на странице ролика. */
    NSString *_audioTrack;

    /** Ответ `/player` нынешнего ролика — из него берётся перечень озвучек. */
    NSDictionary *_playerJson;
    float _rate;



    /** Токены комментариев по роликам — чтобы не ходить за ними дважды. */
    NSMutableDictionary *_commentTokens;

    /** Что мы поставили каждому ролику: `like`, `dislike` или ничего. */
    NSMutableDictionary *_ratings;

    /** Сколько раз подряд ссылку отвергли из-за сменившегося выхода. */
    NSInteger _refusalRetries;
    BOOL _warnedAboutAddress;

    /**
     * Окно о проверке «вы не робот» — тоже один раз за заход, и с ним
     * приходится держать ссылку: у `UIAlertView` получатель нажатий
     * не удерживается, а лента может уйти с экрана, пока окно висит.
     * Освобождённый получатель — это падение при нажатии.
     */
    BOOL _warnedAboutGate;
    UIAlertView *_gateAlert;

    AVPlayerLayer *_playerLayer;

    /**
     * Короткая надпись поверх ленты. Живёт у ленты, а не у страницы:
     * страниц три, и они переиспользуются под разные ролики.
     */
    UILabel *_notice;

    NSString *_sequence;
    NSInteger _current;
    BOOL _loaded;

    /** Был ли вход, когда о нём спрашивали в прошлый раз. */
    /** От чьего имени набрана нынешняя лента — см. `authChanged`. */
    NSString *_identityMark;
    BOOL _loadingMore;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    _pages = [NSMutableArray array];
    _items = [NSMutableArray array];
    _generation = [[YTGeneration alloc] init];
    _commentTokens = [NSMutableDictionary dictionary];
    _ratings = [NSMutableDictionary dictionary];
    _current = -1;
    _rate = 1.0f;

    [self setBackgroundColor:YTColor(0x0F0F0F)];

    /**
     * Касания ловит раздел целиком, а не страница: страниц три, они
     * переиспользуются под разные ролики, и вешать распознаватель
     * на каждую значило бы следить за тремя вместо одного.
     */
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(tapped:)];

    [tap setDelegate:self];
    [self addGestureRecognizer:tap];


    _pager = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [_pager setPagingEnabled:YES];
    [_pager setShowsVerticalScrollIndicator:NO];
    [_pager setDelegate:self];
    [self addSubview:_pager];

    _status = [[YTStatusView alloc] initWithFrame:CGRectZero];
    [self addSubview:_status];

    _identityMark = [[YTApi identityMark] copy];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(authChanged)
                                                 name:YTAuthChangedNotification
                                               object:nil];

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [self stop];

    [_gateAlert setDelegate:nil];
}

/**
 * Вход, выход и смена канала меняют ленту: без учётной записи она общая,
 * с ней — подобранная, и у каждого канала своя. Набранное прежде не
 * годится ни в ту сторону, ни в другую, а держалось оно до перезапуска:
 * раздел загружается один раз и больше за лентой не ходит.
 *
 * Уведомление приходит и без настоящей смены — его шлёт заодно загрузка
 * профиля сразу за восстановлением сохранённого входа, — поэтому
 * сверяемся с тем, что было. Примету даёт `identityMark`: сверки с одним
 * лишь «вошли ли» на смену канала не хватало, вход при ней не меняется.
 */
- (void)authChanged {
    NSString *now = [YTApi identityMark];

    if ([now isEqualToString:_identityMark]) {
        return;
    }

    _identityMark = [now copy];

    if (!_loaded) {
        return;
    }

    [self stop];

    [_generation next];

    _loaded = NO;
    _current = -1;
    _sequence = nil;

    [_items removeAllObjects];
    [_commentTokens removeAllObjects];
    [_ratings removeAllObjects];

    [self rebuild];

    // Раздел не на виду — за новой лентой сходим, когда его откроют.
    if ([self window] != nil) {
        [self activate];
    }
}

#pragma mark Загрузка

- (void)activate {
    /**
     * У раздела свой плеер — свёрнутое окно здесь лишнее.
     *
     * Петля у приложения одна: первый же ролик ленты отберёт её у
     * свёрнутого, и тот замолчал бы посреди кадра, оставшись висеть
     * поверх ленты. Закрываем сразу, не дожидаясь этого.
     */
    if ([YTMiniPlayer isActive]) {
        NSLog(@"[YouTube/Мини] Открыты Shorts — закрываем окно");

        [YTMiniPlayer close];
    }

    if (_loaded) {
        [self playCurrent];
        return;
    }

    _loaded = YES;

    NSInteger generation = [_generation next];

    [_status showBusy];

    YTAsync(^{
        NSDictionary *feed = [YTApi shorts:nil];

        YTMain(^{
            if (![_generation isCurrent:generation]) {
                return;
            }

            NSArray *items = [feed objectForKey:@"items"];

            [_items removeAllObjects];
            [_items addObjectsFromArray:items];

            _sequence = [feed objectForKey:@"sequence"];

            if ([_items count] == 0) {
                _loaded = NO;

                [_status showOffline:YTLoc(@"Shorts не загрузились")
                                hint:YTLoc(@"Проверьте подключение и попробуйте снова")
                         actionTitle:YTLoc(@"Повторить")
                              action:^{
                    [self activate];
                }];

                return;
            }

            [_status hide];
            [self rebuild];

            _current = -1;

            [self showPage:0];
        });
    });
}

/**
 * Открывает ленту, начинающуюся с названного ролика.
 *
 * Пропуск (`sequence`) приходит вместе с карточкой Shorts из выдачи
 * поиска: с ним сервер отдаёт ленту, где выбранный ролик стоит первым.
 * Без пропуска показываем хотя бы его самого — лента тогда не поедет
 * дальше, но открыть ролик всё равно лучше, чем ничего.
 */
- (void)startWithItem:(YTVideoItem *)item {
    if (item == nil) {
        return;
    }

    /**
     * Свёрнутое окно закрываем по той же причине, что и при входе
     * в раздел: петля потоков у приложения одна, и первый же ролик
     * ленты отобрал бы её у окна.
     */
    if ([YTMiniPlayer isActive]) {
        NSLog(@"[YouTube/Мини] Открыты Shorts — закрываем окно");

        [YTMiniPlayer close];
    }

    [self stop];

    NSInteger generation = [_generation next];

    _loaded = YES;
    _current = -1;
    _sequence = nil;

    [_items removeAllObjects];
    [_commentTokens removeAllObjects];
    [_ratings removeAllObjects];

    // Выбранный ролик показываем сразу, не дожидаясь ленты вокруг него.
    [_items addObject:item];

    [_status hide];
    [self rebuild];
    [self showPage:0];

    NSString *pass = item.shortsSequence;

    if ([pass length] == 0) {
        return;
    }

    YTAsync(^{
        NSDictionary *feed = [YTApi shorts:pass];

        YTMain(^{
            if (![_generation isCurrent:generation]) {
                return;
            }

            NSArray *items = [feed objectForKey:@"items"];

            if ([items count] == 0) {
                return;
            }

            /**
             * Первым в ответе стоит тот же ролик, что мы уже показали, —
             * заменяем список целиком, чтобы он не задвоился, и остаёмся
             * на первой странице.
             */
            [_items removeAllObjects];
            [_items addObjectsFromArray:items];

            _sequence = [feed objectForKey:@"sequence"];

            [self rebuild];

            if (![[[_items objectAtIndex:0] videoId] isEqualToString:item.videoId]) {
                /**
                 * Сервер начал ленту не с нашего ролика — ставим его
                 * первым сами: человек нажал именно на него.
                 */
                [_items insertObject:item atIndex:0];

                [self rebuild];
            }

            _current = -1;

            [self showPage:0];
        });
    });
}

/**
 * Раздел ушёл с виду — воспроизведение прекращается.
 *
 * Иначе звук продолжал бы идти поверх другого раздела.
 */
- (void)deactivate {
    [self stop];

    if (_current >= 0 && _current < (NSInteger)[_pages count]) {
        [[_pages objectAtIndex:(NSUInteger)_current] showThumbnail];
    }
}

/**
 * Касание: по полосе внизу — перемотка, по кадру — пауза и продолжение.
 */
/**
 * Касание по кнопке — дело кнопки, а не общей протяжки.
 *
 * Распознаватель висит на всём разделе и без этой проверки съедал
 * нажатия по столбцу и по верхним кнопкам, толкуя их как «пауза».
 */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
       shouldReceiveTouch:(UITouch *)touch {
    /**
     * Пока открыта панель, лента касаний не берёт вовсе.
     *
     * Панель забирает нажатие себе, но распознаватель ленты висит на всём
     * разделе — а такой получает касание независимо от того, в какой из
     * вложенных видов оно попало. Панель закрывалась, и тем же нажатием
     * ролик вставал на паузу. Проверять надо здесь: у панели нет способа
     * отговорить чужой распознаватель.
     */
    if ([_commentsSheet isOpen] || [_settings isOpen]) {
        return NO;
    }

    UIView *view = [touch view];

    while (view != nil && view != self) {
        if ([view isKindOfClass:[YTTappableView class]]) {
            return NO;
        }

        view = [view superview];
    }

    return YES;
}


- (void)tapped:(UITapGestureRecognizer *)tap {
    if (_player == nil) {
        return;
    }

    CGPoint point = [tap locationInView:self];
    CGFloat bottom = [_pager frame].origin.y + [_pager frame].size.height;

    if (point.y >= bottom - [YTShortPage progressStrip] && point.y <= bottom) {
        NSTimeInterval length = CMTimeGetSeconds([[_player currentItem] duration]);

        if (length > 0 && !isnan(length)) {
            CGFloat share = point.x / [self bounds].size.width;

            [_player seekToTime:
                CMTimeMakeWithSeconds(length * MIN(MAX(share, 0), 1), 600)];
        }

        return;
    }

    if ([_player rate] > 0) {
        [_player pause];
    } else if (_rate > 0 && _rate != 1.0f) {
        [_player setRate:_rate];
    } else {
        [_player play];
    }
}

/** Кружок ожидания у текущей страницы. */
- (void)showBusy:(BOOL)busy {
    if (_current < 0 || _current >= (NSInteger)[_pages count]) {
        return;
    }

    [[_pages objectAtIndex:(NSUInteger)_current] setBusy:busy];
}

- (void)startStallWatch {
    [self stopStallWatch];

    // Минус единица — чтобы первый же обход счёл кадр сдвинувшимся:
    // ноль на ноль похож на застревание, а это просто начало.
    _stallSeen = -1;
    _stalledFor = 0;
    _droppedSeen = 0;

    _stallTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                   target:self
                                                 selector:@selector(watchStall)
                                                 userInfo:nil
                                                  repeats:YES];
}

- (void)stopStallWatch {
    [_stallTimer invalidate];
    _stallTimer = nil;

    if (_stalled) {
        _stalled = NO;

        [self showBusy:NO];
    }
}

/**
 * Полсекунды без движения при играющем плеере — это набор, а не пауза:
 * пауза видна по `rate`, и её мы не трогаем.
 */
- (void)watchStall {
    if (_player == nil) {
        return;
    }

    NSTimeInterval now = CMTimeGetSeconds([_player currentTime]);

    if (isnan(now) || isinf(now) || now < 0) {
        now = 0;
    }

    [self reportDroppedFrames];

    BOOL playing = ([_player rate] > 0);
    BOOL moved = (now > _stallSeen + 0.01);

    _stallSeen = now;

    if (!playing || moved) {
        _stalledFor = 0;

        if (_stalled) {
            _stalled = NO;

            [self showBusy:NO];
        }

        return;
    }

    _stalledFor += 0.25;

    if (_stalledFor >= 0.5 && !_stalled) {
        _stalled = YES;

        [self showBusy:YES];
    }
}

/**
 * Сколько кадров плеер выбросил, не успев их показать.
 *
 * Отставание картинки от звука и застревание набора выглядят одинаково,
 * а лечатся по-разному: набор ждут, а с брошенными кадрами ждать нечего —
 * не успевает разборщик. Число берётся из журнала самого плеера
 * (`numberOfDroppedVideoFrames` есть с iOS 4.3) и пишется в наш журнал,
 * чтобы одно от другого отличалось по записи, а не на глаз.
 */
- (void)reportDroppedFrames {
    AVPlayerItem *item = [_player currentItem];
    AVPlayerItemAccessLog *log = [item accessLog];

    NSArray *events = [log events];

    if ([events count] == 0) {
        return;
    }

    NSInteger dropped = 0;

    for (AVPlayerItemAccessLogEvent *event in events) {
        if ([event numberOfDroppedVideoFrames] > 0) {
            dropped += [event numberOfDroppedVideoFrames];
        }
    }

    if (dropped <= _droppedSeen) {
        return;
    }

    NSLog(@"[YouTube/Shorts] Брошено кадров: %ld (было %ld) — разборщик "
          @"не успевает за временем",
          (long)dropped, (long)_droppedSeen);

    _droppedSeen = dropped;
}

/** Двигает полосу проигранного у текущей страницы. */
- (void)refreshProgress {
    if (_current < 0 || _current >= (NSInteger)[_pages count]) {
        return;
    }

    YTShortPage *page = [_pages objectAtIndex:(NSUInteger)_current];

    NSTimeInterval length = CMTimeGetSeconds([[_player currentItem] duration]);
    NSTimeInterval now = CMTimeGetSeconds([_player currentTime]);

    if (length <= 0 || isnan(length) || isnan(now)) {
        [page applyProgress:-1];

        return;
    }

    [page applyProgress:(CGFloat)(now / length)];
}

- (void)stop {
    /**
     * Метка поколения двигается всегда, даже если играть ещё нечего:
     * ролик мог набираться в этот самый миг, и его запуск надо отменить.
     */
    [_generation next];

    [self stopStallWatch];

    // `deactivate` приходит всем незанятым разделам при каждом
    // переключении, в том числе тем, что ни разу не открывали.
    if (_player == nil) {
        return;
    }

    [[NSNotificationCenter defaultCenter]
        removeObserver:self
                  name:AVPlayerItemDidPlayToEndTimeNotification
                object:nil];

    [_player pause];

    if (_timeObserver != nil) {
        [_player removeTimeObserver:_timeObserver];

        _timeObserver = nil;
    }

    _player = nil;
    _playerLayer = nil;

    // Петлю тоже гасим: иначе она продолжит качать куски уже отпущенного
    // ролика и поделит канал со следующим.
    [[YTHlsProxy shared] close];
}

- (void)loadMore {
    if (_loadingMore || [_sequence length] == 0) {
        return;
    }

    _loadingMore = YES;

    NSInteger generation = [_generation current];
    NSString *sequence = _sequence;

    YTAsync(^{
        NSDictionary *feed = [YTApi shorts:sequence];

        YTMain(^{
            _loadingMore = NO;

            if (![_generation isCurrent:generation]) {
                return;
            }

            NSArray *items = [feed objectForKey:@"items"];

            if ([items count] == 0) {
                NSLog(@"[YouTube/Shorts] Лента кончилась: страница пуста, "
                      @"всего роликов %lu", (unsigned long)[_items count]);

                _sequence = nil;
                return;
            }

            _sequence = [feed objectForKey:@"sequence"];

            NSLog(@"[YouTube/Shorts] Страница: +%lu, всего %lu, продолжение %@",
                  (unsigned long)[items count],
                  (unsigned long)([_items count] + [items count]),
                  [_sequence length] > 0 ? @"есть" : @"НЕТ — дальше не листаем");

            [_items addObjectsFromArray:items];
            [self rebuild];
        });
    });
}

- (void)rebuild {
    while ([_pages count] < [_items count]) {
        YTShortPage *page = [[YTShortPage alloc] initWithFrame:CGRectZero];

        __weak YTShortsView *weakSelf = self;

        [page setRailActions:[NSArray arrayWithObjects:
            (dispatch_block_t)^{ [weakSelf rate:@"like"]; },
            (dispatch_block_t)^{ [weakSelf rate:@"dislike"]; },
            (dispatch_block_t)^{ [weakSelf openComments]; },
            (dispatch_block_t)^{ [weakSelf shareCurrent]; },
            nil]];

        [page setTopActions:[NSArray arrayWithObjects:
            (dispatch_block_t)^{ [YTNav push:[[YTSearchViewController alloc] init]]; },
            (dispatch_block_t)^{ [weakSelf pickQuality]; },
            (dispatch_block_t)^{ [weakSelf shareCurrent]; },
            nil]];

        [_pager addSubview:page];
        [_pages addObject:page];
    }

    for (NSUInteger i = 0; i < [_pages count]; i++) {
        YTShortPage *page = [_pages objectAtIndex:i];

        if (i >= [_items count]) {
            [page setHidden:YES];
            continue;
        }

        [page setHidden:NO];
        [page setItem:[_items objectAtIndex:i]];
    }

    [self setNeedsLayout];
}

#pragma mark Воспроизведение

- (void)showPage:(NSInteger)index {
    if (index == _current || index < 0 || index >= (NSInteger)[_items count]) {
        return;
    }

    if (_current >= 0 && _current < (NSInteger)[_pages count]) {
        [[_pages objectAtIndex:(NSUInteger)_current] showThumbnail];
    }

    _current = index;

    [self playCurrent];

    // Ближе трёх до конца — просим следующую страницу ленты.
    if ([_items count] - index <= 3) {
        [self loadMore];
    }
}

/**
 * Панель настроек — та же, что у обычного ролика.
 *
 * В оригинале это `ShortsSettingsSheet` из `Shorts.xaml`: карточка той же
 * формы, что на странице видео, только всегда тёмная — она лежит поверх
 * кадра. Разделы оттуда же: качество, скорость, озвучка; субтитры
 * добавлены заодно, чтобы панель совпадала со страницей ролика.
 */
/**
 * Озвучки: у подачи свой перечень, у готовых дорожек — свой.
 *
 * Раньше здесь стоял только перечень подачи, и это было верно, пока
 * вертикальные ходили одной ею. Теперь путей два, и на готовых дорожках
 * тот перечень остался бы от прошлого ролика — меню показывало бы
 * чужие озвучки. То же устройство, что и на странице ролика.
 */
- (NSArray *)audioTracks {
    NSArray *fromSabr = [YTStreams sabrAudioTracks];

    if ([fromSabr count] > 1) {
        return fromSabr;
    }

    return [YTStreams audioTracksIn:[YTStreams formatsFrom:_playerJson]];
}

- (void)pickQuality {
    if (_settings == nil) {
        /**
         * Панель — по теме приложения, а не всегда тёмная.
         *
         * В разметке оригинала у неё жёстко записаны `#222222` и белые
         * подписи: там панель лежит поверх кадра, и о светлой теме речи
         * не шло. На деле в светлой теме это выглядит чужим — панель
         * такая же, как на странице ролика, и вести себя должна так же.
         */
        _settings = [[YTSettingsSheet alloc] initWithDark:NO];
    }

    _settingsPage = 0;

    [self buildSettings];
    [_settings openIn:self];
}

- (void)openSettingsPage:(NSInteger)page {
    _settingsPage = page;

    [self buildSettings];
}

- (void)buildSettings {
    __weak YTShortsView *weakSelf = self;

    NSMutableArray *rows = [NSMutableArray array];

    if (_settingsPage == 0) {
        [rows addObject:[YTSheetRow section:@"pl_quality"
                                     title:YTLoc(@"Качество")
                                     value:[YTSettings qualityTitle:[YTSettings shortsHeight]]
                                    action:^{ [weakSelf openSettingsPage:1]; }]];

        [rows addObject:[YTSheetRow section:@"pl_speed"
                                     title:YTLoc(@"Скорость воспроизведения")
                                     value:[self rateTitle]
                                    action:^{ [weakSelf openSettingsPage:2]; }]];

        // Озвучка — только когда её есть из чего выбрать, как в оригинале.
        if ([[self audioTracks] count] > 1) {
            [rows addObject:[YTSheetRow section:@"pl_speed"
                                         title:YTLoc(@"Аудиодорожка")
                                         value:nil
                                        action:^{ [weakSelf openSettingsPage:3]; }]];
        }

        // Как и у обычного ролика: у этих двух строк подписи справа нет.
        [rows addObject:[YTSheetRow section:@"pl_comments"
                                     title:YTLoc(@"Субтитры")
                                     value:nil
                                    action:^{ [weakSelf openSettingsPage:4]; }]];
    } else {
        [rows addObject:[YTSheetRow back:^{ [weakSelf openSettingsPage:0]; }]];
    }

    if (_settingsPage == 1) {
        NSInteger current = [YTSettings shortsHeight];

        for (NSNumber *number in [YTSettings qualityOptions]) {
            NSInteger height = [number integerValue];

            [rows addObject:[YTSheetRow choice:[YTSettings qualityTitle:height]
                                        picked:(height == current)
                                        action:^{ [weakSelf pickHeight:height]; }]];
        }
    }

    if (_settingsPage == 2) {
        // Только обычная скорость и ниже — по той же причине, что
        // на странице ролика: ускорение поток не принимает и встаёт.
        NSArray *rates = [NSArray arrayWithObjects:
            [NSNumber numberWithFloat:0.25f], [NSNumber numberWithFloat:0.5f],
            [NSNumber numberWithFloat:0.75f], [NSNumber numberWithFloat:1.0f], nil];

        for (NSNumber *number in rates) {
            float rate = [number floatValue];

            [rows addObject:[YTSheetRow choice:[self titleForRate:rate]
                                        picked:(rate == _rate)
                                        action:^{ [weakSelf pickRate:rate]; }]];
        }
    }

    if (_settingsPage == 3) {
        for (NSDictionary *track in [self audioTracks]) {
            NSString *identifier = [track objectForKey:@"id"];
            BOOL picked = ([_audioTrack length] == 0)
                ? [[track objectForKey:@"default"] boolValue]
                : [identifier isEqualToString:_audioTrack];

            [rows addObject:[YTSheetRow choice:[track objectForKey:@"title"]
                                        picked:picked
                                        action:^{ [weakSelf pickAudioTrack:identifier]; }]];
        }
    }

    if (_settingsPage == 4) {
        // Как и у обычного ролика: список есть, показывать его нечем.
        [rows addObject:[YTSheetRow choice:YTLoc(@"Пока недоступны") picked:NO action:nil]];
    }

    [_settings setTitle:(_settingsPage == 0 ? nil : [self settingsPageTitle])
                   rows:rows];
}

- (NSString *)settingsPageTitle {
    switch (_settingsPage) {
        case 1:  return YTLoc(@"Качество");
        case 2:  return YTLoc(@"Скорость воспроизведения");
        case 3:  return YTLoc(@"Аудиодорожка");
        case 4:  return YTLoc(@"Субтитры");
        default: return YTLoc(@"Настройки");
    }
}

- (NSString *)titleForRate:(float)rate {
    if (rate == 1.0f) {
        return YTLoc(@"Обычная");
    }

    // Убираем лишний ноль: «1.5×», а не «1.50×».
    NSString *number = [NSString stringWithFormat:@"%.2f", rate];

    while ([number hasSuffix:@"0"]) {
        number = [number substringToIndex:[number length] - 1];
    }

    if ([number hasSuffix:@"."]) {
        number = [number substringToIndex:[number length] - 1];
    }

    return [number stringByAppendingString:@"×"];
}

- (NSString *)rateTitle {
    return [self titleForRate:_rate];
}

- (NSString *)trackTitle {
    for (NSDictionary *track in [self audioTracks]) {
        BOOL picked = ([_audioTrack length] == 0)
            ? [[track objectForKey:@"default"] boolValue]
            : [[track objectForKey:@"id"] isEqualToString:_audioTrack];

        if (picked) {
            return [track objectForKey:@"title"];
        }
    }

    return YTLoc(@"По умолчанию");
}

/** Качество вертикальных роликов — своя настройка, как в оригинале. */
- (void)pickHeight:(NSInteger)height {
    [_settings close];

    if (height == [YTSettings shortsHeight]) {
        return;
    }

    [YTSettings setShortsHeight:height];

    /**
     * Выше меры устройства — предупреждаем, но исполняем.
     *
     * A4 (iPhone 4, iPod touch 4, iPad 1) разбирает H.264 не выше уровня
     * 3.1, то есть 720p. Дать ему 1080p можно, и он даже покажет картинку,
     * но разбирать её будет медленнее, чем идёт время: звук держится
     * своего хода, а кадры отстают всё сильнее к концу ролика. Ни буфер,
     * ни ожидание тут не помогут — не успевает сам разборщик.
     */
    if (height > 0 && [YTStreams isBeyondDevice:height]) {
        NSLog(@"[YouTube/Shorts] Выбрано %ldp — выше меры устройства (%ldp); "
              @"картинка будет отставать от звука",
              (long)height, (long)[YTStreams deviceMaxHeight]);

        [self showNotice:YTLocF(@"%ldp выше меры устройства — картинка будет отставать",
                                (long)height)];
    }

    // Перезапускаем текущий ролик: качество меняется только новым потоком.
    [self stop];
    [self playCurrent];
}

/**
 * Короткая надпись поверх ленты — на две секунды, как на странице ролика.
 */
- (void)showNotice:(NSString *)text {
    if (_notice == nil) {
        _notice = YTLabel(YTFontRegular(13), [UIColor whiteColor], 2);

        [_notice setTextAlignment:NSTextAlignmentCenter];
        [_notice setBackgroundColor:[UIColor colorWithWhite:0 alpha:0.8]];
        [[_notice layer] setCornerRadius:14];
        [_notice setClipsToBounds:YES];
        [_notice setAlpha:0];

        [self addSubview:_notice];
    }

    [_notice setText:text];

    CGRect box = [self bounds];
    CGFloat width = MIN(box.size.width - 48, (CGFloat)280);

    [_notice setFrame:CGRectMake((box.size.width - width) / 2,
                                 box.size.height - 140, width, 44)];

    [self bringSubviewToFront:_notice];

    [UIView animateWithDuration:0.2 animations:^{ [_notice setAlpha:1]; }];

    [self performSelector:@selector(hideNotice) withObject:nil afterDelay:2.4];
}

- (void)hideNotice {
    [UIView animateWithDuration:0.3 animations:^{ [_notice setAlpha:0]; }];
}

- (void)pickAudioTrack:(NSString *)identifier {
    [_settings close];

    if ([identifier isEqualToString:_audioTrack]) {
        return;
    }

    _audioTrack = [identifier copy];

    NSLog(@"[YouTube/Shorts] Озвучка: %@", identifier);

    [self stop];
    [self playCurrent];
}

- (void)pickRate:(float)rate {
    [_settings close];

    _rate = rate;

    /**
     * Ставим скорость только идущему плееру: `setRate:` на остановленном
     * запустил бы воспроизведение, а человек нажал на пункт меню.
     */
    if ([_player rate] > 0) {
        [_player setRate:rate];
    }
}

/** Оценка вертикального ролика — тем же путём, что и у обычного. */
- (void)rate:(NSString *)want {
    if (_current < 0 || _current >= (NSInteger)[_items count]) {
        return;
    }

    YTVideoItem *item = [_items objectAtIndex:(NSUInteger)_current];
    NSString *videoId = item.videoId;

    if ([videoId length] == 0) {
        return;
    }

    if (![YTAuth isSignedIn]) {
        NSLog(@"[YouTube/Shorts] Оценка без входа в аккаунт невозможна");

        return;
    }

    YTShortPage *page = [_pages objectAtIndex:(NSUInteger)_current];

    /**
     * Повторное нажатие снимает оценку — как и на самом YouTube.
     * Своё состояние держим по ролику: страниц три, они переиспользуются,
     * и спрашивать о нём страницу нельзя.
     */
    BOOL liked = [[_ratings objectForKey:videoId] isEqualToString:@"like"];
    BOOL disliked = [[_ratings objectForKey:videoId] isEqualToString:@"dislike"];

    BOOL already = ([want isEqualToString:@"like"] && liked) ||
                   ([want isEqualToString:@"dislike"] && disliked);

    NSString *action = already ? @"none" : want;

    /**
     * Значок меняется сразу, не дожидаясь ответа.
     *
     * Сеть тут медленная, а отказ — редкость; без этого нажатие
     * выглядело так, будто ничего не случилось, — на что вы и указали.
     * Не вышло — вернём как было.
     */
    if ([action isEqualToString:@"none"]) {
        [_ratings removeObjectForKey:videoId];
    } else {
        [_ratings setObject:action forKey:videoId];
    }

    [page applyLiked:[action isEqualToString:@"like"]
            disliked:[action isEqualToString:@"dislike"]];

    YTAsync(^{
        BOOL done = [YTApi rate:videoId as:action params:nil];

        if (!done) {
            YTMain(^{
                // Отказ — возвращаем прежний вид, чтобы не врать.
                if (liked) {
                    [_ratings setObject:@"like" forKey:videoId];
                } else if (disliked) {
                    [_ratings setObject:@"dislike" forKey:videoId];
                } else {
                    [_ratings removeObjectForKey:videoId];
                }

                [page applyLiked:liked disliked:disliked];
            });

            return;
        }

        // Счётчик перечитываем у сервера: он округляет, и прибавить
        // единицу самим значило бы соврать.
        NSDictionary *state = [YTApi watchState:videoId];

        YTMain(^{
            [page applyLikes:[state objectForKey:@"likes"]
                    comments:[state objectForKey:@"comments"]];

            // Сервер знает лучше: у него и спрашиваем, что вышло.
            NSNumber *nowLiked = [state objectForKey:@"liked"];

            if (nowLiked != nil) {
                [page applyLiked:[nowLiked boolValue]
                        disliked:[action isEqualToString:@"dislike"]];
            }
        });
    });
}

/** Комментарии — тем же листом, что и у обычного ролика. */
- (void)openComments {
    if (_current < 0 || _current >= (NSInteger)[_items count]) {
        return;
    }

    YTVideoItem *item = [_items objectAtIndex:(NSUInteger)_current];
    NSString *videoId = item.videoId;

    if ([videoId length] == 0) {
        return;
    }

    if (_commentsSheet == nil) {
        _commentsSheet = [[YTCommentsSheet alloc] initWithFrame:CGRectZero];
        [self addSubview:_commentsSheet];
    }

    [self bringSubviewToFront:_commentsSheet];
    [_commentsSheet setFrame:[self bounds]];

    /**
     * Токен приезжает вскоре после запуска ролика — тем же заходом,
     * которым приходят счётчики. Успел приехать — лист открывается
     * сразу; не успел (а нажать можно и в первую секунду) — спрашиваем
     * его здесь же.
     */
    NSString *token = [_commentTokens objectForKey:videoId];

    if ([token length] > 0) {
        [_commentsSheet openWithToken:token];

        return;
    }

    YTAsync(^{
        NSDictionary *state = [YTApi watchState:videoId];

        YTMain(^{
            NSString *fresh = [state objectForKey:@"commentsToken"];

            if ([fresh length] > 0) {
                [_commentTokens setObject:fresh forKey:videoId];
            }

            [_commentsSheet openWithToken:fresh];
        });
    });
}

/** «Ещё» — пока это «поделиться»: в оригинале за ним тот же список. */
- (void)shareCurrent {
    if (_current < 0 || _current >= (NSInteger)[_items count]) {
        return;
    }

    YTVideoItem *item = [_items objectAtIndex:(NSUInteger)_current];

    if ([item.videoId length] == 0) {
        return;
    }

    NSString *link = [@"https://youtube.com/shorts/" stringByAppendingString:item.videoId];

    Class controller = NSClassFromString(@"UIActivityViewController");

    if (controller != nil) {
        id activity = [[controller alloc]
            initWithActivityItems:[NSArray arrayWithObject:[NSURL URLWithString:link]]
            applicationActivities:nil];

        // У раздела своего контроллера нет — показываем от корневого.
        UIViewController *root =
            [[[UIApplication sharedApplication] keyWindow] rootViewController];

        [YTShare presentSheet:activity from:self in:root];

        return;
    }

    [[UIPasteboard generalPasteboard] setString:link];
}

/**
 * Окно с просьбой сменить выход в сеть. Показывается один раз за заход
 * в раздел: повторять его на каждом ролике — значит мешать, а не помогать.
 *
 * `UIAlertView` — не устаревшая небрежность: `UIAlertController`
 * появился в iOS 8, а нам нужна пятая.
 */
- (void)showAddressWarning {
    if (_warnedAboutAddress) {
        return;
    }

    _warnedAboutAddress = YES;

    UIAlertView *alert = [[UIAlertView alloc]
        initWithTitle:YTLoc(@"Раздача отказывает")
              message:YTLoc(@"YouTube привязывает ссылку на видео к адресу, "
                            @"с которого её выдали, а наш адрес меняется от "
                            @"запроса к запросу. Смените сервер VPN или "
                            @"отключите его — и попробуйте снова.")
             delegate:nil
    cancelButtonTitle:YTLoc(@"Понятно")
    otherButtonTitles:nil];

    [alert show];
}

/**
 * Окно о стене «вы не робот» — с кнопкой, которая её и снимает.
 *
 * Без него отказ по проверке выглядит как пустой чёрный ролик: лента
 * листается, а ничего не играет, и понять, что дело в проверке, можно
 * только по журналу. На странице обычного ролика для этого есть кнопка
 * поверх кадра; здесь кадр занят целиком, поэтому окно.
 *
 * Показывается один раз за заход в раздел: стена держится на всей сети
 * сразу, и повторять её на каждом ролике — значит мешать листать.
 */
- (void)showBotGateWarning {
    if (_warnedAboutGate) {
        return;
    }

    _warnedAboutGate = YES;

    BOOL web = [YTWebAuth isSignedIn];

    _gateAlert = [[UIAlertView alloc]
        initWithTitle:YTLoc(@"YouTube просит подтвердить, что вы не робот")
              message:web
                  ? YTLoc(@"Пройдите проверку — после неё ролик откроется.")
                  : YTLoc(@"Проверке мало входа по QR-коду: нужен ещё вход "
                          @"в браузере. Его же можно выполнить в настройках "
                          @"приложения, строка «Вход в браузере».")
             delegate:self
    cancelButtonTitle:YTLoc(@"Отмена")
    otherButtonTitles:web ? YTLoc(@"Пройти проверку") : YTLoc(@"Войти в браузере"), nil];

    [_gateAlert show];
}

- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index {
    if (index == [alert cancelButtonIndex]) {
        return;
    }

    NSString *videoId = nil;

    if (_current >= 0 && _current < (NSInteger)[_items count]) {
        videoId = [(YTVideoItem *)[_items objectAtIndex:(NSUInteger)_current] videoId];
    }

    __weak YTShortsView *weakSelf = self;

    // Пройденная проверка попадает в общее хранилище cookie — то же,
    // из которого их берут наши запросы, — и ролик пробуется заново.
    dispatch_block_t done = ^{ [weakSelf playCurrent]; };

    YTChallengeViewController *screen = [YTWebAuth isSignedIn]
        ? [[YTChallengeViewController alloc] initWithVideoId:videoId done:done]
        : [[YTChallengeViewController alloc] initForLoginWithDone:done];

    [YTNav push:screen];
}

- (void)playCurrent {
    if (_current < 0 || _current >= (NSInteger)[_items count]) {
        return;
    }

    [self stop];

    YTShortPage *page = [_pages objectAtIndex:(NSUInteger)_current];
    YTVideoItem *item = [_items objectAtIndex:(NSUInteger)_current];

    [page setBusy:YES];

    NSInteger generation = [_generation current];
    NSString *videoId = item.videoId;

    YTAsync(^{
        /**
         * У Shorts берётся готовый склеенный поток, а не пара дорожек:
         * так же поступает оригинал (`SelectPlayableShortUrl`). Прокси
         * с разбором DASH здесь не нужен — AVPlayer играет mp4 сам.
         *
         * Оттуда же приезжают название и автор: лента reel присылает
         * одни идентификаторы.
         */
        NSDictionary *playback = [YTApi shortsPlayback:videoId];

        /**
         * Адрес готовим здесь же, на своём потоке: и петля, и подача
         * ходят в сеть, а главному потоку этого делать нельзя.
         *
         * Даже готовый mp4 отдаём плееру через петлю. Сам он пошёл бы
         * за ним своим стеком — с системным именем, — а раздача сверяет
         * имя с клиентом, под которого подписана ссылка, и отвечает
         * отказом 403.
         */
        /**
         * Раздел мог смениться, пока мы ходили в сеть.
         *
         * Проверка стоит **до** подъёма подачи, а не только после: подача
         * — это запрос в сеть и разбор первого куска на несколько
         * мегабайт. Начинать всё это ради ролика, который уже никто
         * не смотрит, значит занять канал и память впустую, а на iPhone 4
         * и то и другое на счету.
         */
        if (![_generation isCurrent:generation]) {
            return;
        }

        NSDictionary *response = [playback objectForKey:@"player"];
        NSString *remote = [playback objectForKey:@"url"];
        NSString *local = nil;

        /**
         * Подача идёт первой, склеенный поток — запасным.
         *
         * Порядок был обратный, и вертикальные ролики от этого молчали:
         * склеенная дорожка у них есть почти всегда, мы брали её, а
         * ссылка на неё подписана на тот выход в сеть, с которого её
         * выдали. Через VPN выход меняется от запроса к запросу, и
         * раздача отвечала отказом 403 на каждом ролике подряд.
         * Подаче адрес безразличен — она и играет.
         */
        if (response != nil) {
            /**
             * Потолок берётся по убыванию частности: своя настройка
             * Shorts, за ней общая настройка качества, и лишь потом
             * мера устройства.
             *
             * Общей ступени тут прежде не было вовсе, и «Авто» у Shorts
             * означало «сколько потянет железо». Со стороны это выглядело
             * так, будто вертикальные ролики настройку качества попросту
             * не замечают: человек ставил в настройках 480p, а Shorts
             * играли в 1080p. Своя настройка при этом остаётся и главнее
             * общей — у вертикального ролика при той же высоте пикселей
             * столько же, а смотрят его чаще в дороге.
             */
            NSInteger wanted = [YTSettings shortsHeight];

            if (wanted <= 0) {
                wanted = [YTSettings preferredHeight];
            }

            NSInteger cap = (wanted > 0) ? wanted : [YTStreams deviceMaxHeight];

            /**
             * Готовые раздельные дорожки — первыми, как и на странице ролика.
             *
             * Здесь Shorts расходились с обычным плеером, и расхождение
             * стоило секунд на каждом ролике. Тот смотрит на настройку
             * доставки: есть разобранные дорожки с адресами и подача
             * не выбрана — играем ими. Вертикальные же шли подачей
             * **всегда**, настройки не спрашивая.
             *
             * Разница в цене велика, и она вся до первого кадра. У готовых
             * дорожек прокси качает только init-заголовки и карты `sidx` —
             * четыре запроса диапазонами, десяток-другой килобайт. Подача
             * же приносит заголовки **вместе с первыми фрагментами медиа**:
             * в наших журналах это 443 КБ на 480p, а на 1080p и мегабайты.
             * У десятиминутного ролика такая плата окупается, у
             * пятнадцатисекундного — нет, и платится она каждый свайп.
             *
             * Хуже того, у выбравшего в настройках готовые адреса выходило
             * совсем скверно: подача без адресов не поднималась вовсе,
             * время уходило впустую, и ролик доигрывал склеенным потоком
             * в 360p — то есть медленно **и** хуже качеством.
             */
            BOOL wantsSabr = ([YTSettings delivery] == YTDeliverySabr);

            BOOL sabrOffered =
                [YTJson textIn:[YTJson objectIn:response key:@"streamingData"]
                           key:@"serverAbrStreamingUrl"] != nil;

            _playerJson = response;

            NSArray *formats = [YTStreams formatsFrom:response];

            if ([formats count] > 0 && !(wantsSabr && sabrOffered)) {
                YTFormat *video = [YTStreams chooseVideo:formats maxHeight:cap];
                YTFormat *audio = [YTStreams chooseAudio:formats
                                          preferredTrack:_audioTrack];

                if (video != nil) {
                    if (![_generation isCurrent:generation]) {
                        return;
                    }

                    local = [[YTHlsProxy shared] openWithVideo:video audio:audio];

                    if ([local length] > 0) {
                        NSLog(@"[YouTube/Shorts] %@: играем готовыми дорожками (%ldp)",
                              videoId, (long)[video qualityTier]);
                    }
                }
            }

            YTSabr *sabr = ([local length] > 0 || !sabrOffered)
                ? nil
                : [YTStreams sabrFor:response
                           maxHeight:cap
                          audioTrack:_audioTrack];

            /**
             * `sabrFor:` ходит в сеть и стоит секунд — за это время палец
             * успевает пролистать дальше или уйти с ленты. Прокси у
             * приложения один: открыв его опоздавшей загрузкой, мы отберём
             * подачу у того, кто играет сейчас.
             */
            if (![_generation isCurrent:generation]) {
                return;
            }

            if (sabr != nil) {
                local = [[YTHlsProxy shared] openWithSabr:sabr];
            }

            /**
             * Подача поднялась, но без звука — уходим на склеенный поток.
             *
             * Подача имеет право не дать звуковую дорожку, и прокси в этом
             * случае собирает поток из одного видео: для обычного ролика
             * это лучше, чем ничего. Для вертикального — нет: у него почти
             * всегда лежит готовый склеенный mp4 со звуком внутри, и играть
             * немое кино, имея его под рукой, незачем. Ровно так и выходило
             * без входа в учётную запись: картинка есть, звука нет ни
             * в одном качестве.
             */
            if ([local length] > 0 && ![[YTHlsProxy shared] hasAudio] &&
                [remote length] > 0) {

                NSLog(@"[YouTube\\Shorts] Подача без звука — берём склеенный поток");

                [[YTHlsProxy shared] close];

                local = nil;
            }
        }

        if ([local length] == 0 && [remote length] > 0) {
            if (![_generation isCurrent:generation]) {
                return;
            }

            local = [[YTHlsProxy shared] relayUrl:remote
                                         duration:[YTStreams lengthIn:response]];
        }

        YTMain(^{
            if (![_generation isCurrent:generation] || _current < 0) {
                return;
            }

            // Пока ходили в сеть, палец мог пролистать дальше.
            if ([_pages objectAtIndex:(NSUInteger)_current] != page) {
                return;
            }

            [page setBusy:NO];

            if ([local length] == 0) {
                NSLog(@"[YouTube/Shorts] %@: потока нет", videoId);

                /**
                 * Отказ по адресу лечится новой ссылкой — но лишь пока
                 * есть надежда, что выход в сеть устоится. Три раза
                 * подряд означают, что не устоится, и дальше решать
                 * человеку.
                 */
                if ([[YTHlsProxy shared] refusedByAddress]) {
                    if (_refusalRetries < 3) {
                        _refusalRetries++;

                        NSLog(@"[YouTube/Shorts] Берём ссылку заново: адрес "
                              @"сменился (попытка %ld из 3)", (long)_refusalRetries);

                        [self playCurrent];

                        return;
                    }

                    [self showAddressWarning];

                    return;
                }

                if ([[playback objectForKey:@"botGate"] boolValue]) {
                    [self showBotGateWarning];
                }

                return;
            }

            _refusalRetries = 0;

            [page applyTitle:[playback objectForKey:@"title"]
                     channel:[playback objectForKey:@"channelTitle"]];

            /**
             * Счётчики гасим: страницы переиспользуются, и от прошлого
             * ролика на них остались бы чужие цифры. Свои приедут
             * следом, отдельным заходом.
             */
            [page applyLikes:nil comments:nil];

            _player = [AVPlayer playerWithURL:[NSURL URLWithString:local]];

            _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];

            /**
             * Кадр вписывается целиком, а не обрезается по краям.
             *
             * Стояло заполнение с обрезкой — как `UniformToFill`
             * в оригинале. Для настоящего вертикального ролика разницы
             * нет: он и так занимает окно. А вот горизонтальных среди
             * Shorts хватает, и у них обрезка съедала половину кадра —
             * причём предпросмотр той же карточки показывал его целиком,
             * так что после запуска картинка заметно «прыгала».
             */
            [_playerLayer setVideoGravity:AVLayerVideoGravityResizeAspect];

            [page attachLayer:_playerLayer];

            [[NSNotificationCenter defaultCenter]
                addObserver:self
                   selector:@selector(repeat)
                       name:AVPlayerItemDidPlayToEndTimeNotification
                     object:[_player currentItem]];

            /**
             * Полоса двигается по таймеру плеера — четыре раза в секунду.
             * Чаще незачем: полоса шириной в экран, а ролик короткий.
             */
            __block __typeof__(self) weak = self;

            _timeObserver = [_player addPeriodicTimeObserverForInterval:
                                 CMTimeMakeWithSeconds(0.25, 600)
                                                                  queue:NULL
                                                             usingBlock:^(CMTime time) {
                [weak refreshProgress];
            }];

            /**
             * Скорость восстанавливается при каждом пуске: `play` всегда
             * ставит обычную, и выбранная в панели иначе терялась бы
             * на следующем ролике.
             */
            if (_rate > 0 && _rate != 1.0f) {
                [_player setRate:_rate];
            } else {
                [_player play];
            }

            [self startStallWatch];

            // Вертикальные ролики попадают в историю тем же путём,
            // что и обычные, — служебными сигналами из ответа `/player`.
            if (response != nil) {
                YTAsync(^{ [YTApi reportWatched:response position:0]; });
            }

            // Кадр пошёл — теперь можно и за подписями.
            [self loadDetailsFor:videoId
                            page:page
                        playback:playback
                      generation:generation];
        });
    });
}

/**
 * Счётчики, кружок автора и метка комментариев — после запуска кадра.
 *
 * Прежде всё это добиралось до потока, внутри `shortsPlayback:`, и ролик
 * ждал двух чужих запросов: на iPhone 4 между ответом `/player`
 * и первым фрагментом уходило семь секунд из десяти. Кадру эти цифры
 * не нужны, они рисуются в столбце справа — значит, и ждать их незачем.
 */
- (void)loadDetailsFor:(NSString *)videoId
                  page:(YTShortPage *)page
              playback:(NSDictionary *)playback
            generation:(NSInteger)generation {
    YTAsync(^{
        NSDictionary *details = [YTApi shortsDetails:videoId known:playback];

        YTMain(^{
            // Пока ходили в сеть, ролик мог смениться — цифры чужие.
            if (![_generation isCurrent:generation]) {
                return;
            }

            [page applyLikes:[details objectForKey:@"likes"]
                    comments:[details objectForKey:@"comments"]];

            [page applyAvatar:[details objectForKey:@"channelThumbnail"]];

            NSString *channel = [details objectForKey:@"channelTitle"];

            if ([channel length] > 0) {
                [page applyTitle:nil channel:channel];
            }

            /**
             * Оценку с сервера ставим, только если человек не успел
             * оценить сам.
             *
             * Своя оценка приходит теперь позже кадра, а нажать можно
             * сразу — и ответ сервера, снятый до нажатия, погасил бы
             * только что залитый значок.
             */
            if ([_ratings objectForKey:videoId] == nil) {
                NSNumber *wasLiked = [details objectForKey:@"liked"];

                if ([wasLiked boolValue]) {
                    [_ratings setObject:@"like" forKey:videoId];
                }

                [page applyLiked:[wasLiked boolValue] disliked:NO];
            }

            NSString *comments = [details objectForKey:@"commentsToken"];

            if ([comments length] > 0) {
                [_commentTokens setObject:comments forKey:videoId];
            }
        });
    });
}

/**
 * Ролик доиграл — либо сначала, либо к следующему.
 *
 * По кругу — как в оригинале: Shorts там листают пальцем, а не ждут конца.
 * Но кому-то удобнее без рук, оттого переключатель в настройках; по
 * умолчанию всё та же петля.
 */
- (void)repeat {
    if ([YTSettings autoplayNextShort] &&
        _current + 1 < (NSInteger)[_items count]) {

        CGFloat height = [_pager bounds].size.height;

        if (height > 0) {
            // Через прокрутку, а не сменой страницы напрямую: так это
            // выглядит переходом, а не подменой кадра.
            [_pager setContentOffset:CGPointMake(0, height * (_current + 1))
                            animated:YES];

            [self showPage:_current + 1];

            return;
        }
    }

    [_player seekToTime:kCMTimeZero];

    if (_rate > 0 && _rate != 1.0f) {
        [_player setRate:_rate];
    } else {
        [_player play];
    }
}

#pragma mark Прокрутка

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    CGFloat height = [_pager bounds].size.height;

    if (height <= 0) {
        return;
    }

    [self showPage:(NSInteger)round([_pager contentOffset].y / height)];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) {
        [self scrollViewDidEndDecelerating:scrollView];
    }
}

#pragma mark Раскладка

- (void)applyTheme {
    // Страница Shorts тёмная в обеих темах: кадр занимает её целиком.
    [self setBackgroundColor:YTColor(0x0F0F0F)];
}

- (void)layoutSubviews {
    CGRect box = [self bounds];

    [_pager setFrame:box];
    [_status setFrame:box];

    for (NSUInteger i = 0; i < [_pages count]; i++) {
        [[_pages objectAtIndex:i] setFrame:CGRectMake(0, box.size.height * i,
                                                      box.size.width, box.size.height)];
    }

    [_pager setContentSize:CGSizeMake(box.size.width, box.size.height * [_items count])];

    /**
     * После поворота лента ставится обратно на свой ролик.
     *
     * Прокрутка помнит смещение в точках, а не в роликах: высота страницы
     * при повороте меняется, а смещение остаётся прежним — и лента
     * оказывается между двумя роликами, показывая низ одного и верх
     * другого. Со стороны это и выглядит как недокрученная страница.
     *
     * Пока палец на экране, не трогаем: там смещение ведёт человек.
     */
    if (_current < 0 || [_pager isDragging] || [_pager isDecelerating]) {
        return;
    }

    CGFloat place = box.size.height * _current;

    if (fabs([_pager contentOffset].y - place) > 0.5) {
        [_pager setContentOffset:CGPointMake(0, place) animated:NO];
    }
}

@end

/**
 * Экран листалки поверх стопки — тот, что открывается из выдачи поиска.
 *
 * Внутри та же лента, что и в разделе; отличие в том, что этот экран
 * стоит в стопке и закрывается назад к тому, из чего его открыли.
 */
@implementation YTShortsScreen {
    YTShortsView *_feed;
    YTVideoItem *_item;
    UIButton *_back;

    /** Ленту заводим один раз: возврат с чужого экрана её не сбрасывает. */
    BOOL _started;
}

- (id)initWithItem:(YTVideoItem *)item {
    self = [super init];

    if (self != nil) {
        _item = item;
    }

    return self;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return (orientation == UIInterfaceOrientationPortrait) ||
           (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad);
}

- (void)loadView {
    YTUseFullScreenLayout(self);

    [super loadView];

    [[self view] setBackgroundColor:[UIColor blackColor]];

    _feed = [[YTShortsView alloc] initWithFrame:CGRectZero];

    [[self view] addSubview:_feed];

    /**
     * Кнопка «назад» — своя: раздел в нижней панели её не имеет, ему
     * возвращаться некуда, а этому экрану нужно.
     */
    _back = [UIButton buttonWithType:UIButtonTypeCustom];

    [[_back titleLabel] setFont:YTFontRegular(28)];
    [_back setTitle:@"‹" forState:UIControlStateNormal];
    [_back setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];

    [[self view] addSubview:_back];
}

- (void)goBack {
    [YTNav pop];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    if (_started) {
        // Вернулись с чужого экрана — просто продолжаем с того же места.
        [_feed activate];

        return;
    }

    _started = YES;

    [_feed startWithItem:_item];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];

    // Уходя, гасим звук: экран из стопки уберут, а лента осталась бы играть.
    [_feed deactivate];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGRect box = [[self view] bounds];

    [_feed setFrame:box];

    [_back setFrame:CGRectMake(4, YTStatusBarHeight() + 4, 44, 44)];
}

@end
