#import "YTUtil.h"

#import "YTStrings.h"

#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>

#import "YTHttp.h"
#import "YTMetrics.h"
#import "YTTheme.h"

// Карточка нужна целиком: у неё спрашивают и ролик, и пропуск на ленту.
#import "YTVideoItem.h"

/**
 * Подписи конструкторов экранов, которые YTNav открывает по имени класса.
 *
 * Категория без реализации: тела этих методов лежат в самих экранах, а здесь
 * нужны только подписи — чтобы компилятор знал, что и куда передаётся.
 * Без этого пришлось бы звать через performSelector:, а он на неизвестном
 * селекторе даёт предупреждение и не умеет возвращать значение с нужным
 * временем жизни под ARC.
 */
@interface NSObject (YTScreenConstructors)
- (id)initWithVideoId:(NSString *)videoId title:(NSString *)title;
- (id)initWithVideoId:(NSString *)videoId
                title:(NSString *)title
             playlist:(NSString *)playlistId;
- (id)initWithChannelId:(NSString *)channelId title:(NSString *)title;
- (id)initWithPlaylistId:(NSString *)playlistId title:(NSString *)title;
- (id)initWithItem:(id)item;
- (void)selectTab:(NSInteger)index;
@end

/**
 * Своя очередь, а не глобальная: запросов немного, но каждый ждёт ответа
 * сети, и на глобальной очереди GCD в ответ на это заводит всё новые потоки.
 * На iPhone 4 — одно ядро — это заметно спокойнее.
 */
static dispatch_queue_t YTWorkQueue(void) {
    static dispatch_queue_t queue = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        queue = dispatch_queue_create("ru.computershik.troubadour.work", DISPATCH_QUEUE_CONCURRENT);
    });

    return queue;
}

void YTAsync(dispatch_block_t work) {
    dispatch_async(YTWorkQueue(), ^{
        @autoreleasepool {
            work();
        }
    });
}

void YTMain(dispatch_block_t work) {
    if ([NSThread isMainThread]) {
        work();
        return;
    }

    dispatch_async(dispatch_get_main_queue(), work);
}

CGFloat YTStatusBarHeight(void) {
    CGRect frame = [[UIApplication sharedApplication] statusBarFrame];

    // Меньшая сторона: в landscape ширина и высота меняются местами.
    return MIN(frame.size.height, frame.size.width);
}

/**
 * Оба свойства зовём через objc_msgSend, а не по имени: wantsFullScreenLayout
 * из новых SDK убрали, automaticallyAdjustsScrollViewInsets в старых ещё нет,
 * и написать оба вызова прямо значит не собраться ни там, ни там. Приведение
 * обязательное: на arm64 objc_msgSend объявлен без списка аргументов, и без
 * приведения логическое значение уйдёт не тем путём, каким его прочтут.
 */
static void YTSetFlag(id target, SEL selector, BOOL value) {
    if (![target respondsToSelector:selector]) {
        return;
    }

    void (*set)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
    set(target, selector, value);
}

void YTUseFullScreenLayout(UIViewController *controller) {
    YTSetFlag(controller, @selector(setWantsFullScreenLayout:), YES);
    YTSetFlag(controller, @selector(setAutomaticallyAdjustsScrollViewInsets:), NO);
}


@implementation YTGeneration

- (NSInteger)next {
    @synchronized (self) {
        _current++;
        return _current;
    }
}

- (BOOL)isCurrent:(NSInteger)generation {
    @synchronized (self) {
        return generation == _current;
    }
}

@end


#pragma mark - Нажимаемый вид

@implementation YTTappableView {
    UIColor *_restingColor;
    UILongPressGestureRecognizer *_hold;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self != nil) {
        _highlights = YES;
    }

    return self;
}

/**
 * Распознаватель заводится вместе с обработчиком, а не в `init`: у видов
 * без долгого нажатия он лишний, а лишний распознаватель на карточке
 * списка задерживает её собственные касания.
 */
- (void)setOnHold:(dispatch_block_t)block {
    _onHold = [block copy];

    if (_onHold != nil && _hold == nil) {
        _hold = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(held:)];

        [self addGestureRecognizer:_hold];
    }
}

/**
 * Распознаватель отменяет касания вида, поэтому `touchesEnded:` после
 * него не придёт и обычное нажатие само собой не засчитается — как
 * и положено: долгое нажатие это другое действие, а не второе к тому же.
 */
- (void)held:(UILongPressGestureRecognizer *)gesture {
    if ([gesture state] != UIGestureRecognizerStateBegan) {
        return;
    }

    [self restore];

    if (_onHold != nil) {
        _onHold();
    }
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (!_highlights) {
        return;
    }

    _restingColor = [self backgroundColor];
    [self setBackgroundColor:[YTTheme surfaceHover]];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    [self restore];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    [self restore];

    // Нажатие засчитывается только если палец отпустили внутри — как у кнопки.
    UITouch *touch = [touches anyObject];
    CGPoint point = [touch locationInView:self];

    if (!CGRectContainsPoint([self bounds], point)) {
        return;
    }

    if (_onTap != nil) {
        _onTap();
    }
}

- (void)restore {
    if (!_highlights) {
        return;
    }

    [self setBackgroundColor:_restingColor];
    _restingColor = nil;
}

@end


#pragma mark - Потяните, чтобы обновить

/** Дальше какого оттягивания считаем, что список просят обновить. */
static const CGFloat YTRefreshThreshold = 64;

@implementation YTRefreshHeader {
    __weak UIScrollView *_scrollView;
    dispatch_block_t _action;
    YTLoadingRing *_ring;
    UILabel *_label;
    BOOL _refreshing;
}

+ (YTRefreshHeader *)attachedTo:(UIScrollView *)scrollView action:(dispatch_block_t)action {
    YTRefreshHeader *header =
        [[YTRefreshHeader alloc] initWithFrame:CGRectMake(0, -YTRefreshThreshold,
                                                          scrollView.bounds.size.width,
                                                          YTRefreshThreshold)];

    header->_scrollView = scrollView;
    header->_action = [action copy];

    [header setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
    [scrollView addSubview:header];

    return header;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    [self setBackgroundColor:[UIColor clearColor]];
    [self setUserInteractionEnabled:NO];

    _ring = [[YTLoadingRing alloc] initWithFrame:CGRectMake(0, 0, 24, 24)];
    [self addSubview:_ring];

    _label = YTLabel(YTFontRegular(12), [YTTheme mutedText], 1);
    [_label setTextAlignment:NSTextAlignmentCenter];
    [_label setText:YTLoc(@"Потяните, чтобы обновить")];
    [self addSubview:_label];

    return self;
}

- (BOOL)isRefreshing {
    return _refreshing;
}

- (void)layoutSubviews {
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;

    [_ring setFrame:CGRectMake(width / 2 - 12, height / 2 - 20, 24, 24)];
    [_label setFrame:CGRectMake(0, height / 2 + 8, width, 16)];
}

/**
 * Ставит шапку над содержимым по нынешней ширине списка.
 *
 * Ширина берётся здесь, а не при рождении: список к тому времени ещё не
 * разложен, и его ширина — ноль. Растягивающая маска от нулевой ширины
 * не спасает — делить не на что, и шапка остаётся нулевой навсегда.
 * Так и было: потянуть список получалось, обновление шло, а показать
 * это было нечем — ни кольца, ни подписи не видно.
 */
- (void)placeAboveContent {
    CGFloat width = [_scrollView bounds].size.width;

    if (width <= 0 || width == [self frame].size.width) {
        return;
    }

    [self setFrame:CGRectMake(0, -YTRefreshThreshold, width, YTRefreshThreshold)];
}

- (void)followScroll {
    [self placeAboveContent];

    if (_refreshing) {
        return;
    }

    CGFloat pulled = -[_scrollView contentOffset].y - [_scrollView contentInset].top;

    [_label setText:pulled >= YTRefreshThreshold
        ? YTLoc(@"Отпустите, чтобы обновить")
        : YTLoc(@"Потяните, чтобы обновить")];
}

- (void)releaseScroll {
    if (_refreshing) {
        return;
    }

    CGFloat pulled = -[_scrollView contentOffset].y - [_scrollView contentInset].top;

    if (pulled < YTRefreshThreshold) {
        return;
    }

    _refreshing = YES;

    /**
     * Оттянули список — значит, просят сходить в сеть. Кеш ответов при
     * этом надо снять, иначе просьба ничего не значит.
     *
     * Ленты держатся в памяти две минуты — ради переходов между
     * разделами, чтобы мегабайт не выкачивался заново на каждое касание
     * вкладки. Но обновление по жесту попадало в тот же кеш и получало
     * **тот же самый ответ**: колечко крутилось, список не менялся
     * и даже не мигал. Со стороны это неотличимо от «жест не работает».
     *
     * Снимаем весь кеш, а не одну запись: какой именно запрос сейчас
     * повторится, шапка не знает и знать не должна, а жест этот редкий
     * и намеренный — лишняя пара запросов дешевле несбывшейся просьбы.
     */
    [YTHttp dropMemoryCache];

    [_label setText:YTLoc(@"Обновляем…")];
    [_ring start];

    // Держим список оттянутым, пока идёт обновление, — иначе индикатор
    // уехал бы за край сразу после отпускания.
    UIEdgeInsets insets = [_scrollView contentInset];
    insets.top += YTRefreshThreshold;

    [UIView animateWithDuration:0.2 animations:^{
        [_scrollView setContentInset:insets];
    }];

    if (_action != nil) {
        _action();
    }
}

- (void)finish {
    if (!_refreshing) {
        return;
    }

    _refreshing = NO;
    [_ring stop];

    UIEdgeInsets insets = [_scrollView contentInset];
    insets.top -= YTRefreshThreshold;

    [UIView animateWithDuration:0.2 animations:^{
        [_scrollView setContentInset:insets];
    }];
}

@end


#pragma mark - Переходы

static UINavigationController *YTNavControllerRef = nil;

@implementation YTNav

+ (UINavigationController *)controller {
    return YTNavControllerRef;
}

+ (void)setController:(UINavigationController *)controller {
    YTNavControllerRef = controller;
}

+ (void)push:(UIViewController *)screen {
    if (screen == nil) {
        return;
    }

    [YTNavControllerRef pushViewController:screen animated:YES];
}

+ (void)pop {
    [YTNavControllerRef popViewControllerAnimated:YES];
}

+ (BOOL)contains:(UIViewController *)screen {
    if (screen == nil) {
        return NO;
    }

    return [[YTNavControllerRef viewControllers] containsObject:screen];
}

+ (void)popTo:(UIViewController *)screen {
    if (![self contains:screen]) {
        return;
    }

    [YTNavControllerRef popToViewController:screen animated:YES];
}

/**
 * Открытие ролика и канала идёт через рантайм, а не прямой ссылкой на класс.
 *
 * Причина не в системе, а в устройстве проекта: карточку показывают полдюжины
 * экранов, и все они лежат «ниже» плеера — если бы каждый импортировал
 * YTPlayerViewController, а тот, в свою очередь, карточки похожих, получился
 * бы круг из заголовков. Имя класса строкой этот узел развязывает.
 */
+ (void)openVideo:(NSString *)videoId title:(NSString *)title {
    [self openVideo:videoId title:title playlist:nil];
}

+ (void)openVideo:(NSString *)videoId
            title:(NSString *)title
         playlist:(NSString *)playlistId {
    if ([videoId length] == 0) {
        return;
    }

    Class player = NSClassFromString(@"YTPlayerViewController");

    if (player == nil) {
        NSLog(@"[YouTube/Навигация] Нет класса плеера");
        return;
    }

    UIViewController *screen = [[player alloc] initWithVideoId:videoId
                                                          title:title
                                                       playlist:playlistId];

    [self push:screen];
}

+ (void)openShort:(YTVideoItem *)item {
    if ([[item videoId] length] == 0) {
        return;
    }

    /**
     * Класс листалки берётся по имени — по той же причине, что и класс
     * плеера выше: карточку показывают полдюжины экранов, и прямой импорт
     * замкнул бы заголовки в круг.
     */
    Class screen = NSClassFromString(@"YTShortsScreen");

    if (screen == nil) {
        NSLog(@"[YouTube/Навигация] Нет класса листалки — открываем страницей");

        [self openVideo:[item videoId] title:[item title]];

        return;
    }

    [self push:[[screen alloc] initWithItem:item]];
}

+ (void)selectTab:(NSInteger)index {
    /**
     * Оболочка — самый нижний экран стопки. Возвращаемся к ней и просим
     * переключить раздел; если сейчас открыт ролик или поиск, они при этом
     * закрываются — как и должно быть при переходе в другой раздел.
     */
    UIViewController *shell = [[YTNavControllerRef viewControllers] count] > 0
        ? [[YTNavControllerRef viewControllers] objectAtIndex:0]
        : nil;

    if (![shell respondsToSelector:@selector(selectTab:)]) {
        return;
    }

    [YTNavControllerRef popToRootViewControllerAnimated:YES];
    [shell selectTab:index];
}

+ (void)openChannel:(NSString *)channelId title:(NSString *)title {
    if ([channelId length] == 0) {
        return;
    }

    Class channel = NSClassFromString(@"YTChannelViewController");

    if (channel == nil) {
        return;
    }

    UIViewController *screen = [[channel alloc] initWithChannelId:channelId title:title];

    [self push:screen];
}

+ (void)openPlaylist:(NSString *)playlistId title:(NSString *)title {
    if ([playlistId length] == 0) {
        return;
    }

    Class playlist = NSClassFromString(@"YTPlaylistViewController");

    if (playlist == nil) {
        return;
    }

    UIViewController *screen = [[playlist alloc] initWithPlaylistId:playlistId title:title];

    [self push:screen];
}

@end


@implementation YTNavigationController

/**
 * Системный жест «назад от левого края» отключается.
 *
 * Полоса навигации у нас скрыта, шапку каждый экран рисует сам, и кнопка
 * возврата стоит у самого левого края — то есть ровно в той полосе,
 * где живёт этот жест. Он перехватывает касание первым, а довести
 * переход до конца при скрытой полосе не может: нажатие пропадает
 * впустую, и человеку кажется, что кнопка мертва.
 *
 * Появился жест в iOS 7, поэтому спрашиваем, прежде чем трогать:
 * на пятой и шестой такого свойства нет вовсе.
 */
- (void)viewDidLoad {
    [super viewDidLoad];

    if (![self respondsToSelector:@selector(interactivePopGestureRecognizer)]) {
        return;
    }

    id gesture = [self interactivePopGestureRecognizer];

    [gesture setEnabled:NO];
}

/**
 * Все три вопроса переадресуются верхнему экрану.
 *
 * shouldAutorotateToInterfaceOrientation: — путь iOS 5, остальные два — iOS 6
 * и новее. Если верхний экран о себе ничего не говорит, отвечаем как обычная
 * стопка: наследованное поведение и есть «разрешено всё, что объявлено
 * в Info.plist».
 */
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    UIViewController *top = [self topViewController];

    if (top != nil) {
        return [top shouldAutorotateToInterfaceOrientation:orientation];
    }

    return [super shouldAutorotateToInterfaceOrientation:orientation];
}

- (BOOL)shouldAutorotate {
    UIViewController *top = [self topViewController];

    if ([top respondsToSelector:@selector(shouldAutorotate)]) {
        return [top shouldAutorotate];
    }

    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIViewController *top = [self topViewController];

    if ([top respondsToSelector:@selector(supportedInterfaceOrientations)]) {
        return [top supportedInterfaceOrientations];
    }

    return [super supportedInterfaceOrientations];
}

@end


#pragma mark - Кольцо ожидания

@implementation YTLoadingRing {
    CAShapeLayer *_arc;
    BOOL _running;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    [self setBackgroundColor:[UIColor clearColor]];
    [self setUserInteractionEnabled:NO];

    _arc = [CAShapeLayer layer];

    [_arc setFillColor:NULL];
    [_arc setLineCap:kCALineCapRound];
    [[self layer] addSublayer:_arc];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect box = [self bounds];
    CGFloat side = MIN(box.size.width, box.size.height);
    CGFloat width = MAX(2, side / 10);
    CGFloat radius = (side - width) / 2;

    [_arc setFrame:box];
    [_arc setLineWidth:width];

    /**
     * Путь — полная окружность; видимую часть вырезают `strokeStart`
     * и `strokeEnd`. Дуга при этом не рисуется заново каждый кадр:
     * обе доли меняет сама Core Animation, а это работа для видеоядра,
     * не для процессора. На iPhone 4 разница ощутима, а кольцо как раз
     * и показывается тогда, когда процессор занят разбором ответа.
     */
    CGMutablePathRef path = CGPathCreateMutable();

    CGPathAddArc(path, NULL,
                 box.size.width / 2, box.size.height / 2, radius,
                 -M_PI_2, -M_PI_2 + M_PI * 2, NO);

    [_arc setPath:path];
    CGPathRelease(path);
}

- (void)start {
    [self setHidden:NO];

    // Цвет берётся здесь, а не в конструкторе: кольцо переживает смену темы
    // так же, как ячейки списка.
    [_arc setStrokeColor:[[YTTheme loadingRing] CGColor]];

    if (_running) {
        return;
    }

    _running = YES;

    /**
     * Числа — из `AndroidLoadingRing.xaml.cs`, оттуда же и повадка дуги:
     *
     *     MinSweepAngle            44°
     *     MaxSweepAngle           278°
     *     SweepCycleSeconds      1.35
     *     RotationDegreesPerSecond 160
     *
     * Половину круга голова дуги убегает вперёд и дуга растёт, вторую
     * половину хвост её догоняет и дуга укорачивается. Назад ничего
     * не отматывается никогда — «it never reverses, only the tail
     * catches the head», как сказано в оригинале.
     *
     * В долях окружности: 44/360 = 0.122, 278/360 = 0.772. К концу круга
     * хвост уходит вперёд на 278−44 = 234°, то есть на 0.65 оборота —
     * ровно на столько же обязан довернуться слой, иначе на стыке кругов
     * дуга прыгала бы назад.
     */
    CAKeyframeAnimation *sweep =
        [CAKeyframeAnimation animationWithKeyPath:@"strokeEnd"];

    [sweep setValues:[NSArray arrayWithObjects:
        [NSNumber numberWithDouble:0.122],
        [NSNumber numberWithDouble:0.772],
        [NSNumber numberWithDouble:0.772],
        nil]];

    CAKeyframeAnimation *tail =
        [CAKeyframeAnimation animationWithKeyPath:@"strokeStart"];

    [tail setValues:[NSArray arrayWithObjects:
        [NSNumber numberWithDouble:0.0],
        [NSNumber numberWithDouble:0.0],
        [NSNumber numberWithDouble:0.65],
        nil]];

    NSArray *times = [NSArray arrayWithObjects:
        [NSNumber numberWithDouble:0.0],
        [NSNumber numberWithDouble:0.5],
        [NSNumber numberWithDouble:1.0],
        nil];

    // `EaseInOut` из оригинала: разгон и торможение на каждой половине.
    NSArray *easing = [NSArray arrayWithObjects:
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut],
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut],
        nil];

    [sweep setKeyTimes:times];
    [tail setKeyTimes:times];
    [sweep setTimingFunctions:easing];
    [tail setTimingFunctions:easing];

    [sweep setDuration:1.35];
    [tail setDuration:1.35];
    [sweep setRepeatCount:HUGE_VALF];
    [tail setRepeatCount:HUGE_VALF];

    /**
     * Поворот — лесенкой, а не ровной прямой, и вот почему.
     *
     * Видимая дуга начинается в точке `поворот + strokeStart`. За круг
     * `strokeStart` доходит до 0.65 оборота, а на стыке падает обратно
     * в ноль — и если поворот в этот миг не подрастёт ровно на те же
     * 0.65, дуга прыгнет назад. Именно это и было видно: кольцо
     * докручивалось и обрывалось в начало.
     *
     * В оригинале это записано как `cycleIndex * TailAdvancePerCycle` —
     * приступок на каждом стыке поверх ровного хода 160°/с. Здесь то же
     * самое выражено ключевыми точками: время стыка названо дважды,
     * значения в них разные, и Core Animation делает приступок.
     *
     * Считаем сразу на четыре круга: 4 × (0.6 + 0.65) = 5 оборотов
     * ровно. На последнем стыке падение `strokeStart` и возврат поворота
     * складываются в целых пять оборотов — то есть ни во что, и круг
     * замыкается без шва.
     */
    CAKeyframeAnimation *spin =
        [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];

    NSArray *turns = [NSArray arrayWithObjects:
        [NSNumber numberWithDouble:0.00 * 2 * M_PI],
        [NSNumber numberWithDouble:0.60 * 2 * M_PI],
        [NSNumber numberWithDouble:1.25 * 2 * M_PI],
        [NSNumber numberWithDouble:1.85 * 2 * M_PI],
        [NSNumber numberWithDouble:2.50 * 2 * M_PI],
        [NSNumber numberWithDouble:3.10 * 2 * M_PI],
        [NSNumber numberWithDouble:3.75 * 2 * M_PI],
        [NSNumber numberWithDouble:4.35 * 2 * M_PI],
        nil];

    [spin setValues:turns];

    [spin setKeyTimes:[NSArray arrayWithObjects:
        [NSNumber numberWithDouble:0.00],
        [NSNumber numberWithDouble:0.25],
        [NSNumber numberWithDouble:0.25],
        [NSNumber numberWithDouble:0.50],
        [NSNumber numberWithDouble:0.50],
        [NSNumber numberWithDouble:0.75],
        [NSNumber numberWithDouble:0.75],
        [NSNumber numberWithDouble:1.00],
        nil]];

    [spin setCalculationMode:kCAAnimationLinear];
    [spin setDuration:5.4];
    [spin setRepeatCount:HUGE_VALF];

    // Без этого поворот сбрасывается при уходе экрана в фон и обратно.
    [spin setRemovedOnCompletion:NO];
    [sweep setRemovedOnCompletion:NO];
    [tail setRemovedOnCompletion:NO];

    [_arc addAnimation:spin forKey:@"spin"];
    [_arc addAnimation:sweep forKey:@"sweep"];
    [_arc addAnimation:tail forKey:@"tail"];
}

- (void)stop {
    _running = NO;

    [_arc removeAllAnimations];
    [self setHidden:YES];
}

@end


#pragma mark - Состояние экрана

@implementation YTStatusView {
    YTLoadingRing *_ring;
    UIImageView *_picture;
    UILabel *_title;
    UILabel *_hint;
    YTPillView *_buttonFill;
    UIButton *_button;
    dispatch_block_t _actionBlock;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    [self setBackgroundColor:[UIColor clearColor]];
    [self setUserInteractionEnabled:NO];

    _ring = [[YTLoadingRing alloc] initWithFrame:CGRectMake(0, 0, 42, 42)];
    [self addSubview:_ring];

    _picture = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_picture setContentMode:UIViewContentModeScaleAspectFit];
    [_picture setHidden:YES];
    [self addSubview:_picture];

    // 22 SemiBold и 16 Regular — размеры из OfflinePanel в Home.xaml.
    _title = YTLabel(YTFontSemiBold(22), [YTTheme primaryText], 0);
    [_title setTextAlignment:NSTextAlignmentCenter];
    [self addSubview:_title];

    _hint = YTLabel(YTFontRegular(16), [YTTheme secondaryText], 0);
    [_hint setTextAlignment:NSTextAlignmentCenter];
    [self addSubview:_hint];

    [self setHidden:YES];

    return self;
}

- (void)layoutSubviews {
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;

    [_ring setFrame:CGRectMake(width / 2 - 21, height / 2 - 21, 42, 42)];

    if ([_picture isHidden]) {
        // Просто сообщение — по центру, без картинки и кнопки.
        [_title setFrame:CGRectMake(24, height / 2 - 40, width - 48, 80)];
        [_hint setFrame:CGRectZero];

        return;
    }

    /**
     * Раскладка повторяет OfflinePanel: картинка 170, отступ 20, заголовок,
     * отступ 8, пояснение шириной не больше 340, отступ 22, кнопка.
     * Всё вместе прижато к центру по вертикали.
     */
    CGFloat pictureSide = 170;
    CGFloat textWidth = MIN(340, width - 64);

    CGFloat titleHeight = YTTextHeight([_title text], [_title font], textWidth, 0);
    CGFloat hintHeight = YTTextHeight([_hint text], [_hint font], textWidth, 0);
    CGFloat buttonHeight = _button != nil ? 44 : 0;

    CGFloat total = pictureSide + 20 + titleHeight + 8 + hintHeight
                  + (buttonHeight > 0 ? 22 + buttonHeight : 0);

    /**
     * Не помещается — уступает картинка, а не текст.
     *
     * Панель эта родом с большого экрана, и высота её частей там взята
     * с запасом. На iPhone 4 под лентой остаётся чуть больше трёхсот
     * точек, и стоит пояснению занять три строки, как столбик перестаёт
     * влезать: прежде он просто прижимался к верхнему краю и уходил
     * за нижний — заголовок оказывался под полосой категорий, а кнопка
     * за экраном. Прокрутки у панели нет и заводить её ради сообщения
     * незачем.
     *
     * Поэтому ужимаем картинку: она здесь украшение, а заголовок,
     * пояснение и кнопка — то, ради чего панель показана. Совсем
     * маленькую убираем вовсе, чтобы не оставлять пятно вместо рисунка.
     */
    if (total > height) {
        pictureSide -= (total - height);

        if (pictureSide < 56) {
            pictureSide = 0;
        }

        total = pictureSide + (pictureSide > 0 ? 20 : 0) + titleHeight + 8 + hintHeight
              + (buttonHeight > 0 ? 22 + buttonHeight : 0);
    }

    CGFloat y = (height - total) / 2;
    if (y < 0) { y = 0; }

    /**
     * Пустая рамка вместо `setHidden:` — нарочно: скрытой картинкой
     * помечен **другой** вид панели, простое сообщение по центру, и,
     * спрятав её здесь, мы на следующем проходе ушли бы в ту ветку.
     */
    [_picture setFrame:CGRectMake((width - pictureSide) / 2, y, pictureSide, pictureSide)];

    if (pictureSide > 0) {
        y += pictureSide + 20;
    }

    [_title setFrame:CGRectMake((width - textWidth) / 2, y, textWidth, titleHeight)];
    y += titleHeight + 8;

    [_hint setFrame:CGRectMake((width - textWidth) / 2, y, textWidth, hintHeight)];
    y += hintHeight + 22;

    if (_button != nil) {
        // MinWidth="150", Padding="18,8" — из шаблона кнопки в Home.xaml.
        // Ширина подписи меряется старым sizeWithFont:: intrinsicContentSize
        // появился только в iOS 6.
        CGSize titleSize = [[_button titleForState:UIControlStateNormal]
            sizeWithFont:[[_button titleLabel] font]];

        CGFloat buttonWidth = MAX(150, ceil(titleSize.width) + 36);

        CGRect box = CGRectMake((width - buttonWidth) / 2, y, buttonWidth, buttonHeight);

        [_buttonFill setFrame:box];
        [_button setFrame:box];
    }
}

- (void)showBusy {
    [self setHidden:NO];
    [self setUserInteractionEnabled:NO];

    [_picture setHidden:YES];
    [_title setText:nil];
    [_hint setText:nil];
    [_buttonFill setHidden:YES];
    [_button setHidden:YES];

    [_ring start];
}

- (void)showMessage:(NSString *)message {
    [self setHidden:NO];
    [self setUserInteractionEnabled:NO];

    [_ring stop];

    [_picture setHidden:YES];
    [_buttonFill setHidden:YES];
    [_button setHidden:YES];

    // Цвет назначается здесь, вместе с текстом: вид переживает смену темы.
    [_title setFont:YTFontRegular(14)];
    [_title setTextColor:[YTTheme mutedText]];
    [_title setText:message];
    [_hint setText:nil];

    _actionBlock = nil;

    [self setNeedsLayout];
}

- (void)showOffline:(NSString *)title
               hint:(NSString *)hint
        actionTitle:(NSString *)actionTitle
             action:(dispatch_block_t)action {
    [self setHidden:NO];
    [self setUserInteractionEnabled:YES];

    [_ring stop];

    [_picture setImage:YTImage(@"failed_loading")];
    [_picture setHidden:NO];

    [_title setFont:YTFontSemiBold(22)];
    [_title setTextColor:[YTTheme primaryText]];
    [_title setText:title];

    [_hint setTextColor:[YTTheme secondaryText]];
    [_hint setText:hint];

    if ([actionTitle length] > 0 && action != NULL) {
        if (_button == nil) {
            _buttonFill = [[YTPillView alloc] initWithFrame:CGRectZero];
            [_buttonFill setCornerRadius:22];
            [self addSubview:_buttonFill];

            _button = [UIButton buttonWithType:UIButtonTypeCustom];
            [_button addTarget:self
                        action:@selector(actionTapped)
              forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:_button];
        }

        // Кнопка «Повторить» в оригинале голубая (#3EA6FF) с подписью
        // цвета PrimaryActionForeground — единственное место, где заливка
        // задана числом, а не кистью темы.
        [_buttonFill setFillColor:[YTTheme accentBlue]];
        [_buttonFill setHidden:NO];

        [[_button titleLabel] setFont:YTFontSemiBold(16)];
        [_button setTitle:actionTitle forState:UIControlStateNormal];
        [_button setTitleColor:[YTTheme primaryActionForeground] forState:UIControlStateNormal];
        [_button setHidden:NO];

        _actionBlock = [action copy];
    } else {
        [_buttonFill setHidden:YES];
        [_button setHidden:YES];
        _actionBlock = nil;
    }

    [self setNeedsLayout];
}

- (void)actionTapped {
    if (_actionBlock != nil) {
        _actionBlock();
    }
}

- (void)hide {
    [self setHidden:YES];
    [_ring stop];

    [_buttonFill setHidden:YES];
    [_button setHidden:YES];

    _actionBlock = nil;
}

@end


#pragma mark - Страницы

@implementation YTPager {
    BOOL _busy;
}

- (BOOL)hasMore {
    return [_token length] > 0;
}

- (void)reset {
    _token = nil;
    _busy = NO;
}

- (BOOL)claimOn:(UIScrollView *)scrollView {
    if (_busy || ![self hasMore]) {
        return NO;
    }

    CGFloat height = [scrollView bounds].size.height;
    CGFloat bottom = [scrollView contentSize].height - height;

    // Экран запаса: страница успевает доехать до того, как список кончится
    // под пальцем.
    if (bottom <= 0 || [scrollView contentOffset].y < bottom - height) {
        return NO;
    }

    _busy = YES;

    return YES;
}

- (BOOL)claimSidewaysOn:(UIScrollView *)scrollView {
    if (_busy || ![self hasMore]) {
        return NO;
    }

    CGFloat width = [scrollView bounds].size.width;
    CGFloat edge = [scrollView contentSize].width - width;

    // Тот же запас в экран, только вбок.
    if (edge <= 0 || [scrollView contentOffset].x < edge - width) {
        return NO;
    }

    _busy = YES;

    return YES;
}

- (void)finish {
    _busy = NO;
}

@end
