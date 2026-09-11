#import "YTShellViewController.h"

#import "YTStrings.h"

#import "YTAccountSheet.h"
#import "YTApi.h"
#import "YTAuth.h"
#import "YTHomeView.h"
#import "YTImageLoader.h"
#import "YTMetrics.h"
#import "YTRoundedImageView.h"
#import "YTSettings.h"
#import "YTSimpleScreens.h"
#import "YTTheme.h"
#import "YTUtil.h"

#pragma mark - Нижняя панель

/**
 * Кнопка раздела: значок 24×24 и подпись 12 точек под ним.
 *
 * Порт Tabbar.xaml: `StackPanel Orientation="Vertical"` с `Image Width="24"
 * Height="24"` и `TextBlock FontSize="12"`, всё по центру. Подпись всегда
 * цвета `AppPrimaryTextBrush` — в оригинале она не тускнеет у невыбранных
 * разделов, различие несёт только значок (обычный и `-active`).
 */
@interface YTTabButton : YTTappableView

@property (nonatomic, copy) NSString *iconName;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) BOOL selected;

/** Кружок аккаунта вместо значка — как `AccountAvatarEllipse` в оригинале. */
- (void)setAvatarUrl:(NSString *)url;

@end

@implementation YTTabButton {
    UIImageView *_icon;
    YTRoundedImageView *_avatar;
    UILabel *_label;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    // Подсветку не рисуем: в оригинале у кнопок панели прозрачный фон
    // и никакого состояния нажатия.
    [self setHighlights:NO];

    _icon = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_icon setContentMode:UIViewContentModeScaleAspectFit];
    [_icon setUserInteractionEnabled:NO];
    [self addSubview:_icon];

    _label = YTLabel(YTFontRegular(12), [YTTheme primaryText], 1);
    [_label setTextAlignment:NSTextAlignmentCenter];
    [self addSubview:_label];

    return self;
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    [_label setText:title];
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    [self applyTheme];
}

- (void)setIconName:(NSString *)iconName {
    _iconName = [iconName copy];
    [self applyTheme];
}

- (void)setAvatarUrl:(NSString *)url {
    if ([url length] == 0) {
        [_avatar setHidden:YES];
        [_icon setHidden:NO];
        return;
    }

    if (_avatar == nil) {
        _avatar = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];
        [_avatar setCircular:YES];
        [_avatar setPlaceholderColor:[YTTheme avatarPlaceholder]];
        [self addSubview:_avatar];

        [self setNeedsLayout];
    }

    [_avatar setHidden:NO];
    [_icon setHidden:YES];

    [YTImageLoader loadInto:_avatar url:url targetWidth:24];
}

/**
 * Цвета и значок назначаются здесь, а не в конструкторе: панель переживает
 * смену темы, и взятый однажды набор так и остался бы прежним.
 */
- (void)applyTheme {
    [_label setTextColor:[YTTheme primaryText]];

    NSString *name = _selected
        ? [_iconName stringByAppendingString:@"_on"]
        : _iconName;

    [_icon setImage:YTIcon(name)];
}

- (void)layoutSubviews {
    CGRect box = [self bounds];

    // 24 точки значок, подпись сразу под ним; в оригинале между ними
    // `Margin="0,0,0,0"`, то есть отступа нет вовсе.
    CGFloat labelHeight = 14;
    CGFloat total = 24 + labelHeight;
    CGFloat top = (box.size.height - total) / 2;

    CGRect iconBox = CGRectMake((box.size.width - 24) / 2, top, 24, 24);

    [_icon setFrame:iconBox];
    [_avatar setFrame:iconBox];

    [_label setFrame:CGRectMake(0, top + 24, box.size.width, labelHeight)];
}

@end


#pragma mark - Оболочка

@implementation YTShellViewController {
    UIView *_navBar;
    UIImageView *_wordmark;
    YTTappableView *_notificationsButton;
    UIImageView *_notificationsIcon;
    YTTappableView *_searchButton;
    UIImageView *_searchIcon;

    UIView *_content;
    NSArray *_sections;

    UIView *_tabBarDivider;
    UIView *_tabBar;
    NSArray *_tabs;

    NSInteger _selected;
}

/**
 * Ориентация на iOS 5 спрашивается именно так — и по умолчанию отвечает
 * «только портрет».
 *
 * Info.plist в этом вопросе система не читает: список
 * `UISupportedInterfaceOrientations` она применяет к приложению целиком,
 * а разрешение на поворот отдельного экрана до iOS 6 берётся из этого метода,
 * и наследованная реализация разрешает один портрет. На iOS 6 и новее того же
 * вопроса нет — значение берётся из Info.plist, — поэтому промах замечается
 * только на старых устройствах.
 */
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    if (orientation == UIInterfaceOrientationPortraitUpsideDown) {
        return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad;
    }

    return YES;
}

- (void)loadView {
    YTUseFullScreenLayout(self);

    [super loadView];

    [[self view] setBackgroundColor:[YTTheme background]];

    [self buildNavBar];

    _content = [[UIView alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_content];

    [self buildTabBar];
    [self buildSections];

    [self applyTheme];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(themeChanged)
                                                 name:YTThemeChangedNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(authChanged)
                                                 name:YTAuthChangedNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(settingsChanged)
                                                 name:YTSettingsChangedNotification
                                               object:nil];

    // Строка состояния бывает вдвое выше — во время звонка или записи
    // экрана. Панель отступает на её высоту, но о самой смене высоты
    // раскладке никто не сообщает.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(statusBarFrameChanged)
                                                 name:UIApplicationDidChangeStatusBarFrameNotification
                                               object:nil];

    /**
     * При первом запуске открывается «Вы» — то есть страница входа.
     *
     * В оригинале `AccountButton_Click` при отсутствии входа ведёт
     * не на «Моё», а прямо в `Login.xaml`: пока в аккаунт не вошли,
     * вкладка «Вы» и есть страница входа. Ленты без входа наполовину
     * пусты, и показывать их первым делом бессмысленно.
     *
     * Только при первом: дальше человек сам выбирает, с чего начинать.
     */
    NSString *seen = @"YTLaunchedBefore";

    BOOL first = ![[NSUserDefaults standardUserDefaults] boolForKey:seen];

    if (first) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:seen];
    }

    [self selectTab:(first && ![YTAuth isSignedIn]) ? 3 : 0];
    [self refreshAccountIcon];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark Верхняя панель

/**
 * Порт Navbar.xaml, вертикальная раскладка: полоса высотой 56, слева
 * словесный знак высотой 32 с отступом 16, справа — колокольчик и лупа
 * по 24 точки с отступом 16 от края.
 *
 * Колокольчик в оригинале `Visibility="Collapsed"` и появляется только
 * у вошедшего — здесь так же.
 */
- (void)buildNavBar {
    _navBar = [[UIView alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_navBar];

    _wordmark = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_wordmark setContentMode:UIViewContentModeScaleAspectFit];
    [_wordmark setUserInteractionEnabled:NO];
    [_navBar addSubview:_wordmark];

    _notificationsButton = [[YTTappableView alloc] initWithFrame:CGRectZero];
    [_notificationsButton setHighlights:NO];
    [_notificationsButton setHidden:YES];
    [_navBar addSubview:_notificationsButton];

    _notificationsIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_notificationsIcon setContentMode:UIViewContentModeScaleAspectFit];
    [_notificationsIcon setUserInteractionEnabled:NO];
    [_notificationsButton addSubview:_notificationsIcon];

    _searchButton = [[YTTappableView alloc] initWithFrame:CGRectZero];
    [_searchButton setHighlights:NO];
    [_navBar addSubview:_searchButton];

    _searchIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_searchIcon setContentMode:UIViewContentModeScaleAspectFit];
    [_searchIcon setUserInteractionEnabled:NO];
    [_searchButton addSubview:_searchIcon];

    [_searchButton setOnTap:^{
        [YTNav push:[[YTSearchViewController alloc] init]];
    }];

    [_notificationsButton setOnTap:^{
        [YTNav push:[[YTNotificationsViewController alloc] init]];
    }];
}

#pragma mark Нижняя панель

/**
 * Порт Tabbar.xaml: полоса разделителя высотой 2 цвета `AppDividerBrush`,
 * под ней панель высотой 50 с четырьмя равными колонками.
 */
- (void)buildTabBar {
    _tabBarDivider = [[UIView alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_tabBarDivider];

    _tabBar = [[UIView alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_tabBar];

    NSArray *icons = [NSArray arrayWithObjects:
        @"tab_home", @"tab_shorts", @"tab_subs", @"tab_you", nil];

    /**
     * Подписи по-русски, как и всюду: ключом перевода служит русская
     * строка. Прежде здесь стояли английские — и оттого по-русски панель
     * так и оставалась английской: для русского таблицы нет вовсе, ключ
     * возвращается как есть. В оригинале подписи переведены
     * (`Loc_Home_Text` и соседние), английскими они там не бывают.
     *
     * «Shorts» — имя собственное и не переводится нигде, включая
     * оригинал: в ресурсах всех языков там ровно это слово.
     */
    NSArray *titles = [NSArray arrayWithObjects:
        YTLoc(@"Главная"), @"Shorts", YTLoc(@"Подписки"), YTLoc(@"Вы"), nil];

    NSMutableArray *buttons = [NSMutableArray array];

    __weak YTShellViewController *weakSelf = self;

    for (NSUInteger i = 0; i < [icons count]; i++) {
        YTTabButton *button = [[YTTabButton alloc] initWithFrame:CGRectZero];

        [button setIconName:[icons objectAtIndex:i]];
        [button setTitle:[titles objectAtIndex:i]];

        NSInteger index = (NSInteger)i;

        [button setOnTap:^{ [weakSelf tabPressed:index]; }];

        /**
         * Список каналов — с кружка в панели, нажатием подольше.
         *
         * Он и есть тот кружок, на который жмут: в официальном клиенте
         * учётные записи переключают именно отсюда, а у нас список
         * висел на кружке страницы «Вы» — на строке, до которой ещё
         * нужно догадаться дойти. Обычное нажатие остаётся переходом
         * в раздел, иначе панель перестала бы быть панелью.
         */
        if (index == 3) {
            [button setOnHold:^{ [weakSelf pickAccount]; }];
        }

        [_tabBar addSubview:button];
        [buttons addObject:button];
    }

    _tabs = buttons;
}

#pragma mark Разделы

- (void)buildSections {
    _sections = [NSArray arrayWithObjects:
        [[YTHomeView alloc] initWithFrame:CGRectZero],
        [[YTShortsView alloc] initWithFrame:CGRectZero],
        [[YTSubscriptionsView alloc] initWithFrame:CGRectZero],
        [[YTMeView alloc] initWithFrame:CGRectZero],
        nil];

    for (UIView *section in _sections) {
        [section setHidden:YES];
        [_content addSubview:section];
    }
}

/**
 * Нажатие по кнопке панели.
 *
 * Обычно это переход в раздел. Но повторное нажатие по «Вы», когда
 * раздел и так открыт, никуда не ведёт — переходить некуда, — и вот его
 * мы отдаём списку каналов: так до него добираются и те, кто про долгое
 * нажатие не знает.
 */
/** Показывать ли вкладку с этим номером. Вторая — Shorts. */
- (BOOL)tabShown:(NSUInteger)index {
    return !(index == 1 && [YTSettings hidesShorts]);
}

/**
 * Настройки сменились — возможно, спрятали Shorts.
 *
 * Уйти с вкладки, которую только что убрали, надо самим: иначе человек
 * остался бы смотреть раздел, кнопки к которому уже нет, и вернуться
 * на него потом не смог бы.
 */
- (void)settingsChanged {
    if (_selected == 1 && ![self tabShown:1]) {
        [self selectTab:0];
    }

    [[self view] setNeedsLayout];
}

- (void)tabPressed:(NSInteger)index {
    if (index == 3 && _selected == 3) {
        [self pickAccount];

        return;
    }

    [self selectTab:index];
}

- (void)pickAccount {
    [YTAccountSheet openIn:[self view]];
}

- (void)selectTab:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)[_sections count]) {
        return;
    }

    _selected = index;

    for (NSUInteger i = 0; i < [_sections count]; i++) {
        BOOL active = ((NSInteger)i == index);
        UIView *section = [_sections objectAtIndex:i];

        [section setHidden:!active];
        [[_tabs objectAtIndex:i] setSelected:active];

        /**
         * Уходящий раздел предупреждается об этом, если ему есть что
         * остановить. Нужно ровно одному — Shorts: прокси потоков один
         * на приложение, и оставленный играть ролик оборвал бы следующий,
         * а звук продолжал бы идти поверх другого раздела.
         */
        if (!active && [section respondsToSelector:@selector(deactivate)]) {
            [section performSelector:@selector(deactivate)];
        }
    }

    /**
     * Верхняя панель есть не у всех разделов.
     *
     * В оригинале она принадлежит `Home.xaml`; у Shorts кадр идёт во весь
     * экран, а у «Моё» своя строка с лупой и шестерёнкой внутри самого
     * раздела — поэтому общая панель там прячется, и раздел занимает
     * освободившееся место.
     */
    BOOL wantsNavBar = (index == 0 || index == 2);

    [_navBar setHidden:!wantsNavBar];

    // Shorts идут поверх нижней панели: кадр во весь экран, как в оригинале.
    [[self view] setNeedsLayout];

    // Раздел мог быть ни разу не открыт — просим его загрузиться.
    UIView *section = [_sections objectAtIndex:index];

    if ([section respondsToSelector:@selector(activate)]) {
        [section performSelector:@selector(activate)];
    }
}

#pragma mark Аккаунт

- (void)authChanged {
    [self refreshAccountIcon];
}

/**
 * Кружок аккаунта в панели и колокольчик появляются только у вошедшего.
 *
 * В оригинале то же самое: `AccountAvatarEllipse` изначально
 * `Visibility="Collapsed"`, а `NotificationsButtonVertical` — тоже.
 */
- (void)refreshAccountIcon {
    BOOL signedIn = [YTAuth isSignedIn];

    [_notificationsButton setHidden:!signedIn];

    if (!signedIn) {
        [[_tabs objectAtIndex:3] setAvatarUrl:nil];
        return;
    }

    YTAsync(^{
        NSString *avatar = [YTApi accountAvatarUrl];

        YTMain(^{
            [[_tabs objectAtIndex:3] setAvatarUrl:avatar];
        });
    });
}

#pragma mark Тема и раскладка

- (void)themeChanged {
    // Набор значков меняется целиком — прежние остались бы чужого цвета.
    YTIconCacheDrop();

    [self applyTheme];

    for (UIView *section in _sections) {
        if ([section respondsToSelector:@selector(applyTheme)]) {
            [section performSelector:@selector(applyTheme)];
        }
    }
}

- (void)applyTheme {
    [[self view] setBackgroundColor:[YTTheme background]];

    [_navBar setBackgroundColor:[YTTheme background]];
    [_wordmark setImage:YTIcon(@"ytlogo")];
    [_searchIcon setImage:YTIcon(@"search")];
    [_notificationsIcon setImage:YTIcon(@"notifications")];

    [_tabBar setBackgroundColor:[YTTheme background]];
    [_tabBarDivider setBackgroundColor:[YTTheme divider]];

    for (YTTabButton *button in _tabs) {
        [button applyTheme];
    }

    [[UIApplication sharedApplication] setStatusBarStyle:[YTTheme statusBarStyle]];
}

- (void)statusBarFrameChanged {
    [[self view] setNeedsLayout];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];

    CGRect bounds = [[self view] bounds];
    CGFloat top = YTStatusBarHeight();

    CGFloat navHeight = [_navBar isHidden] ? 0 : YTNavBarHeight;

    [_navBar setFrame:CGRectMake(0, top, bounds.size.width, YTNavBarHeight)];

    // Словесный знак: высота 32, отступ слева 16, по центру полосы.
    UIImage *logo = [_wordmark image];
    CGFloat logoWidth = 107;

    if (logo != nil && [logo size].height > 0) {
        logoWidth = [logo size].width * 32 / [logo size].height;
    }

    [_wordmark setFrame:CGRectMake(16, (YTNavBarHeight - 32) / 2, logoWidth, 32)];

    // Справа: лупа у самого края (отступ 16), колокольчик левее неё.
    // Область нажатия шире значка — 24 точки значка плюс отступы 8,
    // как `Padding="8"` у кнопок в оригинале.
    CGFloat buttonSide = 40;
    CGFloat right = bounds.size.width - 16 - buttonSide;

    [_searchButton setFrame:CGRectMake(right, (YTNavBarHeight - buttonSide) / 2,
                                       buttonSide, buttonSide)];
    [_searchIcon setFrame:CGRectMake(8, 8, 24, 24)];

    right -= buttonSide + 4;

    [_notificationsButton setFrame:CGRectMake(right, (YTNavBarHeight - buttonSide) / 2,
                                              buttonSide, buttonSide)];
    [_notificationsIcon setFrame:CGRectMake(8, 8, 24, 24)];

    /**
     * Нижняя панель у всех разделов одинаковая, включая Shorts.
     *
     * Раньше у Shorts она лежала поверх кадра — это была догадка по снимку
     * экрана, и неверная. В `Shorts.xaml` строки сетки заданы явно:
     * `0` под шапку, `*` под содержимое и `52` под панель. То есть кадр
     * занимает место **над** ней, а не под ней.
     */
    CGFloat tabTop = bounds.size.height - YTTabBarHeight;

    [_tabBarDivider setFrame:CGRectMake(0, tabTop - YTTabBarDivider,
                                        bounds.size.width, YTTabBarDivider)];
    [_tabBar setFrame:CGRectMake(0, tabTop, bounds.size.width, YTTabBarHeight)];

    [_tabBarDivider setHidden:NO];
    [_tabBar setBackgroundColor:[YTTheme background]];

    /**
     * Скрытая вкладка не занимает места, но и не сдвигает номера.
     *
     * Убрать её из `_tabs` было бы проще на вид и хуже по существу:
     * номер вкладки здесь — это ещё и номер раздела в `_sections`,
     * а на «Вы» (третью) завязаны кружок аккаунта, список каналов
     * и переход по нажатию. Сдвинув номера, пришлось бы править все
     * эти места и помнить про них впредь. Поэтому кнопка остаётся
     * на своём месте, просто прячется.
     */
    NSUInteger shown = 0;

    for (NSUInteger i = 0; i < [_tabs count]; i++) {
        if ([self tabShown:i]) {
            shown++;
        }
    }

    if (shown == 0) {
        shown = 1;
    }

    CGFloat tabWidth = bounds.size.width / shown;
    NSUInteger place = 0;

    for (NSUInteger i = 0; i < [_tabs count]; i++) {
        YTTabButton *button = [_tabs objectAtIndex:i];

        if (![self tabShown:i]) {
            [button setHidden:YES];

            continue;
        }

        [button setHidden:NO];
        [button setFrame:CGRectMake(tabWidth * place, 0, tabWidth, YTTabBarHeight)];

        place++;
    }

    /**
     * У Shorts нет шапки, но есть строка состояния: в оригинале первая
     * строка сетки нулевой высоты, а окно телефона под шапкой системы
     * не бывает. Поэтому содержимое начинается там же, где у всех, —
     * ниже строки состояния.
     */
    CGFloat contentTop = top + navHeight;
    CGFloat contentBottom = YTTabBarHeight + YTTabBarDivider;

    [_content setFrame:CGRectMake(0, contentTop, bounds.size.width,
                                  bounds.size.height - contentTop - contentBottom)];

    for (UIView *section in _sections) {
        [section setFrame:[_content bounds]];
    }

    // Панель поверх содержимого — иначе кадр Shorts закрыл бы её.
    [[self view] bringSubviewToFront:_tabBarDivider];
    [[self view] bringSubviewToFront:_tabBar];

    /**
     * А список каналов — ещё выше.
     *
     * Он открывается с кружка в самой панели и прижат к низу окна, так
     * что панель, поднятая строкой выше, закрывала бы у него как раз
     * нижние строки — те самые каналы, ради которых его и открыли.
     */
    [YTAccountSheet raiseIn:[self view]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    [[UIApplication sharedApplication] setStatusBarStyle:[YTTheme statusBarStyle]];

    [self refreshAccountIcon];
}

@end
