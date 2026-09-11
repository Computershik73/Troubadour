#import "YTSimpleScreens.h"

#import "YTStrings.h"

#import <QuartzCore/QuartzCore.h>

#import "YTApi.h"
#import "YTFeedViews.h"
#import "YTImageLoader.h"
#import "YTMetrics.h"
#import "YTRoundedImageView.h"
#import "YTSettingsSheet.h"
#import "YTTheme.h"
#import "YTUtil.h"
#import "YTVideoItem.h"

/**
 * Числа — из Channel.xaml.
 *
 *     содержимое   Padding="0,8,0,24"
 *     шапка        баннер Height="110", CornerRadius="10", Margin="12,0,12,0"
 *     профиль      Margin="12,12,12,0"; кружок 64; текст с отступом 10:
 *                  название 20 SemiBold в две строки, собачка 11,
 *                  статистика 11 с отступом 3
 *     описание     11, Margin="12,12,12,0", «Ещё» 11 с отступом 3
 *     подписка     Margin="12,12,12,12", Height="40", CornerRadius="20", 14
 *     вкладки      Margin="18,2,12,8", Height="48"; надпись 15,
 *                  полоска 2 под выбранной, между вкладками 16
 */
static const CGFloat YTChSide = 12;
static const CGFloat YTChBanner = 110;
static const CGFloat YTChAvatar = 64;
static const CGFloat YTChSubscribe = 40;
static const CGFloat YTChTabs = 48;
static const CGFloat YTChTabGap = 16;


#pragma mark - Вкладка

@interface YTChannelTab : YTTappableView

- (void)setTitle:(NSString *)title;
- (void)setSelected:(BOOL)selected;
- (CGFloat)preferredWidth;
- (void)applyTheme;

@end

@implementation YTChannelTab {
    UILabel *_title;
    UIView *_indicator;
    BOOL _selected;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    [self setHighlights:NO];

    _title = YTLabel(YTFontSemiBold(15), [YTTheme primaryText], 1);
    [_title setTextAlignment:NSTextAlignmentCenter];
    [self addSubview:_title];

    _indicator = [[UIView alloc] initWithFrame:CGRectZero];
    [self addSubview:_indicator];

    return self;
}

- (void)setTitle:(NSString *)title {
    [_title setText:title];
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;

    [self applyTheme];
}

- (void)applyTheme {
    // Невыбранная вкладка в оригинале не тусклее, а без полоски: цвет
    // подписи там `AppPrimaryTextBrush` у обеих.
    [_title setTextColor:_selected ? [YTTheme primaryText] : [YTTheme secondaryText]];
    [_indicator setBackgroundColor:_selected ? [YTTheme primaryText] : [UIColor clearColor]];
}

- (CGFloat)preferredWidth {
    // `MinWidth="58"` плюс место под саму надпись.
    CGSize text = [[_title text] sizeWithFont:[_title font]];

    return MAX((CGFloat)58, ceil(text.width) + 8);
}

- (void)layoutSubviews {
    CGRect box = [self bounds];

    [_title setFrame:CGRectMake(0, 0, box.size.width, box.size.height - 2)];
    [_indicator setFrame:CGRectMake(0, box.size.height - 2, box.size.width, 2)];
}

@end


#pragma mark - Шапка

/**
 * Всё, что стоит над списком роликов. Отдельным видом — потому что список
 * это UITableView, и его шапка задаётся одним видом целиком.
 */
@interface YTChannelHeader : UIView

@property (nonatomic, copy) void (^onTabPicked)(NSInteger index);
@property (nonatomic, copy) dispatch_block_t onSubscribeTapped;
@property (nonatomic, copy) dispatch_block_t onDescriptionTapped;

- (void)bind:(NSDictionary *)channel;
- (void)selectTab:(NSInteger)index;

/** Ставит разделы по списку от сервера и отмечает выбранный. */
- (void)applySections:(NSArray *)sections selected:(NSInteger)selected;

/** Положение кнопки подписки: подписан ли и какие оповещения выбраны. */
- (void)applySubscribed:(BOOL)subscribed notifications:(NSInteger)notifications;

- (CGFloat)heightForWidth:(CGFloat)width;
- (void)applyTheme;

@end

@implementation YTChannelHeader {
    YTRoundedImageView *_banner;
    YTRoundedImageView *_avatar;
    UILabel *_title;
    UILabel *_handle;
    UILabel *_stats;
    UILabel *_description;

    YTPillView *_subscribe;
    UILabel *_subscribeText;
    YTTappableView *_subscribeTouch;

    YTTappableView *_descriptionTouch;
    UILabel *_descriptionMore;

    UIImageView *_bellIcon;
    UIImageView *_bellChevron;
    BOOL _subscribed;

    NSMutableArray *_tabs;

    /** Полоса разделов прокручивается: в ширину телефона они не встают. */
    UIScrollView *_tabsBar;

    BOOL _hasBanner;
    CGFloat _descriptionHeight;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    _tabs = [NSMutableArray array];

    _banner = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];
    [_banner setCornerRadius:10];
    [self addSubview:_banner];

    _avatar = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];
    [_avatar setCircular:YES];
    [self addSubview:_avatar];

    _title = YTLabel(YTFontSemiBold(20), [YTTheme primaryText], 2);
    [self addSubview:_title];

    _handle = YTLabel(YTFontRegular(11), [YTTheme secondaryText], 1);
    [self addSubview:_handle];

    _stats = YTLabel(YTFontRegular(11), [YTTheme secondaryText], 1);
    [self addSubview:_stats];

    /**
     * Описание — две строки, под ними «Ещё»: нажатие открывает панель
     * с полным текстом, как `DescriptionButton` в оригинале. Область
     * нажатия одна на обе подписи, поэтому они лежат в ней.
     */
    _descriptionTouch = [[YTTappableView alloc] initWithFrame:CGRectZero];
    [_descriptionTouch setHighlights:NO];
    [self addSubview:_descriptionTouch];

    __weak YTChannelHeader *weakSelf = self;

    [_descriptionTouch setOnTap:^{
        YTChannelHeader *header = weakSelf;

        if (header != nil && header.onDescriptionTapped != nil) {
            header.onDescriptionTapped();
        }
    }];

    _description = YTLabel(YTFontRegular(11), [YTTheme secondaryText], 2);
    [_descriptionTouch addSubview:_description];

    _descriptionMore = YTLabel(YTFontSemiBold(11), [YTTheme primaryText], 1);
    [_descriptionMore setText:YTLoc(@"Ещё")];
    [_descriptionTouch addSubview:_descriptionMore];

    _subscribe = [[YTPillView alloc] initWithFrame:CGRectZero];
    [_subscribe setCornerRadius:20];
    [self addSubview:_subscribe];

    _subscribeText = YTLabel(YTFontSemiBold(14), [YTTheme primaryActionForeground], 1);
    [_subscribeText setTextAlignment:NSTextAlignmentCenter];
    [_subscribeText setText:YTLoc(@"Подписаться")];
    [self addSubview:_subscribeText];

    /**
     * Колокольчик и стрелка внутри кнопки — как на странице ролика
     * и как в разметке оригинала: значок 22, стрелка 16 с отступом 6.
     */
    _bellIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_bellIcon setContentMode:UIViewContentModeScaleAspectFit];
    [_bellIcon setUserInteractionEnabled:NO];
    [_bellIcon setHidden:YES];
    [self addSubview:_bellIcon];

    _bellChevron = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_bellChevron setImage:YTIcon(@"down_arrow")];
    [_bellChevron setContentMode:UIViewContentModeScaleAspectFit];
    [_bellChevron setUserInteractionEnabled:NO];
    [_bellChevron setHidden:YES];
    [self addSubview:_bellChevron];

    /**
     * Накладка нажатия. У неподписанного она оформляет подписку,
     * у подписанного открывает панель оповещений — решает владелец шапки.
     */
    _subscribeTouch = [[YTTappableView alloc] initWithFrame:CGRectZero];
    [_subscribeTouch setHighlights:NO];

    {
        __weak YTChannelHeader *weakSelf = self;

        [_subscribeTouch setOnTap:^{
            YTChannelHeader *header = weakSelf;

            if (header != nil && header.onSubscribeTapped != nil) {
                header.onSubscribeTapped();
            }
        }];
    }

    [self addSubview:_subscribeTouch];

    /**
     * Полоса разделов пуста до ответа: какие они у канала, знает только
     * сервер. Их может не быть вовсе — у канала без роликов и Shorts нет.
     */
    _tabsBar = [[UIScrollView alloc] initWithFrame:CGRectZero];

    [_tabsBar setShowsHorizontalScrollIndicator:NO];
    [self addSubview:_tabsBar];

    return self;
}

/**
 * Ставит разделы по списку от сервера.
 *
 * Списком в коде их держать нельзя: у разных каналов набор разный —
 * у одного нет Shorts, у другого есть «Релизы», — а метки `params`
 * к ним и вовсе непрозрачные, вычислить их нельзя.
 */
- (void)applySections:(NSArray *)sections selected:(NSInteger)selected {
    for (YTChannelTab *tab in _tabs) {
        [tab removeFromSuperview];
    }

    [_tabs removeAllObjects];

    for (NSUInteger i = 0; i < [sections count]; i++) {
        YTChannelTab *tab = [[YTChannelTab alloc] initWithFrame:CGRectZero];

        [tab setTitle:[[sections objectAtIndex:i] objectForKey:@"title"]];
        [tab setSelected:(NSInteger)i == selected];

        __weak YTChannelHeader *weakSelf = self;
        NSInteger index = (NSInteger)i;

        [tab setOnTap:^{
            YTChannelHeader *header = weakSelf;

            if (header != nil && header.onTabPicked != nil) {
                header.onTabPicked(index);
            }
        }];

        [_tabsBar addSubview:tab];
        [_tabs addObject:tab];
    }

    [self setNeedsLayout];
}

/**
 * Заполняет шапку ответом.
 *
 * Вызывается на каждый раздел, а не только на первый: ответы разделов
 * шапку повторяют. Но повторяют не всегда полностью — поэтому пустое
 * поле ничего не затирает, иначе при переходе по разделам пропадали бы
 * то подложка, то описание.
 */
- (void)bind:(NSDictionary *)channel {
    NSString *banner = [channel objectForKey:@"banner"];

    if ([banner length] > 0) {
        _hasBanner = YES;

        [_banner setHidden:NO];
        [YTImageLoader loadInto:_banner url:banner targetWidth:[self bounds].size.width];
    }

    NSString *avatar = [channel objectForKey:@"avatar"];

    if ([avatar length] > 0) {
        [YTImageLoader loadInto:_avatar url:avatar targetWidth:YTChAvatar];
    }

    [self set:_title from:channel key:@"title"];
    [self set:_handle from:channel key:@"handle"];
    [self set:_stats from:channel key:@"subscribers"];
    [self set:_description from:channel key:@"description"];

    [_descriptionMore setHidden:([[_description text] length] == 0)];

    [self applyTheme];
    [self setNeedsLayout];
}

/** Ставит подпись, если поле в ответе есть: пустое — не затирает. */
- (void)set:(UILabel *)label from:(NSDictionary *)channel key:(NSString *)key {
    NSString *text = [channel objectForKey:key];

    if ([text length] > 0) {
        [label setText:text];
    }
}

- (void)selectTab:(NSInteger)index {
    for (NSUInteger i = 0; i < [_tabs count]; i++) {
        [[_tabs objectAtIndex:i] setSelected:(NSInteger)i == index];
    }
}

- (void)applySubscribed:(BOOL)subscribed notifications:(NSInteger)notifications {
    _subscribed = subscribed;

    // Подписанному — приглушённая подложка и обычный текст, как в оригинале.
    [_subscribeText setText:subscribed ? YTLoc(@"Вы подписаны") : YTLoc(@"Подписаться")];
    [_subscribeText setTextColor:subscribed ? [YTTheme secondaryText]
                                            : [YTTheme primaryActionForeground]];
    [_subscribe setFillColor:subscribed ? [YTTheme surface]
                                        : [YTTheme primaryActionBackground]];

    [_bellIcon setHidden:!subscribed];
    [_bellChevron setHidden:!subscribed];

    NSString *icon = @"notifications";

    if (notifications == YTNotificationsAll)  { icon = @"notifications_all"; }
    if (notifications == YTNotificationsNone) { icon = @"notifications_none"; }

    [_bellIcon setImage:YTIcon(icon)];

    [self setNeedsLayout];
}

- (void)applyTheme {
    [_banner setPlaceholderColor:[YTTheme surfaceAlt]];
    [_avatar setPlaceholderColor:[YTTheme avatarPlaceholder]];

    [_title setTextColor:[YTTheme primaryText]];
    [_handle setTextColor:[YTTheme secondaryText]];
    [_stats setTextColor:[YTTheme secondaryText]];
    [_description setTextColor:[YTTheme secondaryText]];
    [_descriptionMore setTextColor:[YTTheme primaryText]];

    [_subscribe setFillColor:[YTTheme primaryActionBackground]];
    [_subscribeText setTextColor:[YTTheme primaryActionForeground]];

    for (YTChannelTab *tab in _tabs) {
        [tab applyTheme];
    }
}

/**
 * Высота шапки считается заранее: `tableHeaderView` сам её не подберёт,
 * ему нужен готовый размер.
 */
- (CGFloat)heightForWidth:(CGFloat)width {
    CGFloat y = 8;

    if (_hasBanner) {
        y += YTChBanner;
    }

    y += 12;

    CGFloat textWidth = width - YTChSide - YTChAvatar - 10 - YTChSide;
    CGFloat titleHeight = YTTextHeight([_title text], [_title font], textWidth, 2);

    CGFloat profile = MAX(YTChAvatar, titleHeight + 2 + 14 + 3 + 14);

    y += profile;

    _descriptionHeight = YTTextHeight([_description text], [_description font],
                                      width - YTChSide * 2, 2);

    if (_descriptionHeight > 0) {
        // Под описанием строка «Ещё» с отступом 3 — она есть всегда,
        // потому что панель показывает текст целиком, а здесь он обрезан.
        y += 12 + _descriptionHeight + 3 + 14;
    }

    y += 12 + YTChSubscribe + 12;

    // Пока разделы не пришли, полосы нет и места под неё не занимаем.
    if ([_tabs count] > 0) {
        y += YTChTabs + 8;
    }

    return y;
}

- (void)layoutSubviews {
    CGFloat width = [self bounds].size.width;
    CGFloat y = 8;

    if (_hasBanner) {
        [_banner setFrame:CGRectMake(YTChSide, y, width - YTChSide * 2, YTChBanner)];

        y += YTChBanner;
    } else {
        [_banner setFrame:CGRectZero];
    }

    y += 12;

    [_avatar setFrame:CGRectMake(YTChSide, y, YTChAvatar, YTChAvatar)];

    CGFloat textLeft = YTChSide + YTChAvatar + 10;
    CGFloat textWidth = width - textLeft - YTChSide;

    CGFloat titleHeight = YTTextHeight([_title text], [_title font], textWidth, 2);

    CGFloat block = titleHeight + 2 + 14 + 3 + 14;
    CGFloat top = y + MAX((CGFloat)0, (YTChAvatar - block) / 2);

    [_title setFrame:CGRectMake(textLeft, top, textWidth, titleHeight)];
    [_handle setFrame:CGRectMake(textLeft, top + titleHeight + 2, textWidth, 14)];
    [_stats setFrame:CGRectMake(textLeft, top + titleHeight + 2 + 14 + 3, textWidth, 14)];

    y += MAX(YTChAvatar, block);

    if (_descriptionHeight > 0) {
        CGFloat block = _descriptionHeight + 3 + 14;

        y += 12;

        [_descriptionTouch setFrame:CGRectMake(YTChSide, y, width - YTChSide * 2, block)];
        [_description setFrame:CGRectMake(0, 0, width - YTChSide * 2, _descriptionHeight)];
        [_descriptionMore setFrame:CGRectMake(0, _descriptionHeight + 3,
                                              width - YTChSide * 2, 14)];

        y += block;
    } else {
        [_descriptionTouch setFrame:CGRectZero];
    }

    y += 12;

    CGRect pill = CGRectMake(YTChSide, y, width - YTChSide * 2, YTChSubscribe);

    [_subscribe setFrame:pill];
    [_subscribeTouch setFrame:pill];

    if (_subscribed) {
        /**
         * Подпись, колокольчик и стрелка стоят посередине как одно целое:
         * кнопка здесь во всю ширину, и прижимать значки к краю не к чему.
         */
        CGFloat textWidth = ceil([[_subscribeText text]
            sizeWithFont:[_subscribeText font]].width);

        CGFloat block = textWidth + 8 + 22 + 6 + 16;
        CGFloat left = pill.origin.x + (pill.size.width - block) / 2;

        [_subscribeText setFrame:CGRectMake(left, y, textWidth, YTChSubscribe)];

        [_bellIcon setFrame:CGRectMake(left + textWidth + 8,
                                       y + (YTChSubscribe - 22) / 2, 22, 22)];

        [_bellChevron setFrame:CGRectMake(left + textWidth + 8 + 22 + 6,
                                          y + (YTChSubscribe - 16) / 2, 16, 16)];
    } else {
        [_subscribeText setFrame:pill];
    }

    y += YTChSubscribe + 12;

    /**
     * `Margin="18,2,12,8"` у полосы разделов. Сама полоса прокручивается:
     * их у канала бывает под десяток, и в ширину телефона они не встают.
     */
    [_tabsBar setFrame:[_tabs count] > 0
        ? CGRectMake(0, y, width, YTChTabs) : CGRectZero];

    CGFloat x = 18;

    for (YTChannelTab *tab in _tabs) {
        CGFloat tabWidth = [tab preferredWidth];

        [tab setFrame:CGRectMake(x, 2, tabWidth, YTChTabs - 4)];

        x += tabWidth + YTChTabGap;
    }

    [_tabsBar setContentSize:CGSizeMake(x + 12 - YTChTabGap, YTChTabs)];
}

@end


#pragma mark - Экран

@interface YTChannelViewController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation YTChannelViewController {
    NSString *_channelId;
    NSString *_titleText;

    /** Разделы канала так, как их перечислил сервер, и открытый сейчас. */
    NSMutableArray *_sections;
    NSInteger _section;

    UIView *_bar;
    UIButton *_back;
    UILabel *_barTitle;

    UITableView *_table;
    YTChannelHeader *_header;
    YTStatusView *_status;

    NSMutableArray *_items;
    NSMutableArray *_rows;

    YTPager *_pager;
    YTGeneration *_generation;

    NSInteger _columns;
    CGFloat _laidOutWidth;

    /** Подписка, оповещения и панель колокольчика. */
    BOOL _subscribed;
    NSInteger _notifications;
    YTSettingsSheet *_bell;

    /** Описание целиком и панель, которая его показывает. */
    NSString *_descriptionText;
    YTSettingsSheet *_descriptionSheet;

    /** Не пусто — открыт раздел «О канале», и список занят описанием. */
    NSString *_aboutText;
}

- (id)initWithChannelId:(NSString *)channelId title:(NSString *)title {
    self = [super init];

    if (self != nil) {
        _channelId = [channelId copy];
        _titleText = [title copy];
        _sections = [[NSMutableArray alloc] init];
        _section = 0;
    }

    return self;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    if (orientation == UIInterfaceOrientationPortraitUpsideDown) {
        return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad;
    }

    return YES;
}

- (void)loadView {
    YTUseFullScreenLayout(self);

    [super loadView];

    _items = [NSMutableArray array];
    _rows = [NSMutableArray array];
    _pager = [[YTPager alloc] init];
    _generation = [[YTGeneration alloc] init];
    _columns = 1;

    [[self view] setBackgroundColor:[YTTheme background]];

    _bar = [[UIView alloc] initWithFrame:CGRectZero];
    [_bar setBackgroundColor:[YTTheme background]];
    [[self view] addSubview:_bar];

    _back = [UIButton buttonWithType:UIButtonTypeCustom];
    [[_back titleLabel] setFont:YTFontRegular(24)];
    [_back setTitle:@"‹" forState:UIControlStateNormal];
    [_back setTitleColor:[YTTheme primaryText] forState:UIControlStateNormal];
    [_back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_back];

    _barTitle = YTLabel(YTFontSemiBold(17), [YTTheme primaryText], 1);
    [_barTitle setText:_titleText];
    [_bar addSubview:_barTitle];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    [_table setDataSource:self];
    [_table setDelegate:self];
    [_table setSeparatorStyle:UITableViewCellSeparatorStyleNone];
    [_table setBackgroundColor:[YTTheme background]];
    [_table setBackgroundView:nil];
    [[self view] addSubview:_table];

    _header = [[YTChannelHeader alloc] initWithFrame:CGRectZero];

    __weak YTChannelViewController *weakSelf = self;

    [_header setOnTabPicked:^(NSInteger index) {
        [weakSelf pickTab:index];
    }];

    [_header setOnSubscribeTapped:^{
        [weakSelf subscribeTapped];
    }];

    [_header setOnDescriptionTapped:^{
        [weakSelf openDescription];
    }];

    _status = [[YTStatusView alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_status];

    [self load];
}

- (void)goBack {
    [YTNav pop];
}

/**
 * Нажатие по кнопке подписки — как на странице ролика: у неподписанного
 * оформляет подписку, у подписанного открывает панель оповещений,
 * где отписка одна из строк. Случайным касанием не отписаться.
 */
- (void)subscribeTapped {
    if ([_channelId length] == 0) {
        return;
    }

    if (!_subscribed) {
        [self setSubscribed:YES];
        return;
    }

    if (_bell == nil) {
        _bell = [[YTSettingsSheet alloc] initWithDark:NO];
    }

    __weak YTChannelViewController *weakSelf = self;

    NSMutableArray *rows = [NSMutableArray array];

    [rows addObject:[YTSheetRow choice:YTLoc(@"Все")
                                picked:(_notifications == YTNotificationsAll)
                                action:^{ [weakSelf pickNotifications:YTNotificationsAll]; }]];

    [rows addObject:[YTSheetRow choice:YTLoc(@"По интересам")
                                picked:(_notifications == YTNotificationsPersonalized ||
                                        _notifications == YTNotificationsUnknown)
                                action:^{ [weakSelf pickNotifications:YTNotificationsPersonalized]; }]];

    [rows addObject:[YTSheetRow choice:YTLoc(@"Нет")
                                picked:(_notifications == YTNotificationsNone)
                                action:^{ [weakSelf pickNotifications:YTNotificationsNone]; }]];

    [rows addObject:[YTSheetRow command:@"unsubscribe"
                                  title:YTLoc(@"Отменить подписку")
                                 action:^{
        [weakSelf closeBell];
        [weakSelf setSubscribed:NO];
    }]];

    [_bell setTitle:YTLoc(@"Оповещения") rows:rows];
    [_bell openIn:[self view]];
}

- (void)closeBell {
    [_bell close];
}

- (void)setSubscribed:(BOOL)wanted {
    NSString *channel = _channelId;

    _subscribed = wanted;

    [_header applySubscribed:wanted notifications:_notifications];
    [self layoutHeader];

    YTAsync(^{
        BOOL done = [YTApi setSubscribed:wanted channel:channel];

        if (done) {
            return;
        }

        // Сервер отказал — возвращаем кнопку в прежнее положение.
        YTMain(^{
            _subscribed = !wanted;

            [_header applySubscribed:_subscribed notifications:_notifications];
            [self layoutHeader];
        });
    });
}

- (void)pickNotifications:(NSInteger)state {
    [self closeBell];

    if (state == _notifications) {
        return;
    }

    NSInteger previous = _notifications;
    NSString *channel = _channelId;

    _notifications = state;

    [_header applySubscribed:_subscribed notifications:state];

    YTAsync(^{
        BOOL done = [YTApi setNotifications:state channel:channel];

        if (done) {
            return;
        }

        YTMain(^{
            _notifications = previous;

            [_header applySubscribed:_subscribed notifications:previous];
        });
    });
}

/**
 * Описание целиком — в панели снизу, как в оригинале: в шапке оно
 * обрезано двумя строками, а полный текст бывает на несколько экранов.
 */
- (void)openDescription {
    if ([_descriptionText length] == 0) {
        return;
    }

    if (_descriptionSheet == nil) {
        _descriptionSheet = [[YTSettingsSheet alloc] initWithDark:NO];
    }

    [_descriptionSheet setTitle:YTLoc(@"Описание") text:_descriptionText];
    [_descriptionSheet openIn:[self view]];
}

- (void)pickTab:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)[_sections count] || index == _section) {
        return;
    }

    _section = index;

    [_header selectTab:index];
    [self load];
}

/**
 * Запоминает разделы, перечисленные в ответе.
 *
 * Берём их один раз, с первой страницы: перечень в ответе одинаков для
 * любого раздела, но отметка «выбран» в нём чужая — она про ту страницу,
 * которую сервер прислал, а не про ту, что открыл человек.
 */
- (void)applySectionsFrom:(NSDictionary *)channel {
    if ([_sections count] > 0) {
        return;
    }

    NSArray *sections = [channel objectForKey:@"sections"];

    if ([sections count] == 0) {
        return;
    }

    [_sections addObjectsFromArray:sections];

    /**
     * «О канале» дописываем сами: раздела с таким именем сервер не отдаёт,
     * хотя в UWP-версии он есть — там его так же собирают из описания.
     */
    NSMutableDictionary *about = [NSMutableDictionary dictionary];

    [about setObject:YTLoc(@"О канале") forKey:@"title"];
    [about setObject:[NSNumber numberWithBool:YES] forKey:@"about"];
    [_sections addObject:about];

    [_header applySections:_sections selected:_section];
    [self layoutHeader];
}

/** Раздел, открытый сейчас, или `nil`, пока разделы не пришли. */
- (NSDictionary *)currentSection {
    if (_section < 0 || _section >= (NSInteger)[_sections count]) {
        return nil;
    }

    return [_sections objectAtIndex:(NSUInteger)_section];
}

- (void)load {
    NSInteger generation = [_generation next];

    [_pager reset];
    [_items removeAllObjects];
    [_rows removeAllObjects];

    _aboutText = nil;

    [_table reloadData];
    [_status showBusy];

    NSString *channelId = _channelId;

    /**
     * «О канале» отдельного раздела на сервере не имеет: в перечне его нет,
     * а описание и числа приходят с любой страницей. Поэтому спрашиваем
     * начальную и показываем из неё только текст.
     */
    NSDictionary *section = [self currentSection];
    BOOL about = [[section objectForKey:@"about"] boolValue];
    NSString *params = about ? nil : [section objectForKey:@"params"];

    YTAsync(^{
        NSDictionary *channel = [YTApi channel:channelId params:params];

        YTMain(^{
            if (![_generation isCurrent:generation]) {
                return;
            }

            if (channel == nil) {
                [_status showOffline:YTLoc(@"Канал не открылся")
                                hint:YTLoc(@"Проверьте подключение и попробуйте снова")
                         actionTitle:YTLoc(@"Повторить")
                              action:^{
                    [self load];
                }];

                return;
            }

            NSString *title = [channel objectForKey:@"title"];

            if ([title length] > 0) {
                [_barTitle setText:title];
            }

            [_header bind:channel];
            [self applySectionsFrom:channel];

            NSString *summary = [channel objectForKey:@"description"];

            if ([summary length] > 0) {
                _descriptionText = [summary copy];
            }

            /**
             * Подписка и оповещения приходят только вошедшему: без учётной
             * записи серверу нечего сказать, и кнопка остаётся в положении
             * «Подписаться».
             */
            NSNumber *subscribed = [channel objectForKey:@"subscribed"];
            NSNumber *bell = [channel objectForKey:@"notifications"];

            if (subscribed != nil) {
                _subscribed = [subscribed boolValue];
            }

            if (bell != nil) {
                _notifications = [bell integerValue];
            }

            [_header applySubscribed:_subscribed notifications:_notifications];

            /**
             * В «О канале» списка нет вовсе — только описание. Страницу
             * дальше не дописываем: метку продолжения не запоминаем.
             */
            if (about) {
                [_pager setToken:nil];

                _aboutText = [_descriptionText copy];

                if ([_aboutText length] > 0) {
                    [_status hide];
                } else {
                    [_status showMessage:YTLoc(@"Автор ничего о себе не написал")];
                }

                [self rebuildRows];
                [self layoutHeader];
                [_table reloadData];

                return;
            }

            NSArray *items = [channel objectForKey:@"items"];

            [_items addObjectsFromArray:items];
            [_pager setToken:[channel objectForKey:@"continuation"]];

            if ([_items count] == 0) {
                [_status showMessage:YTLoc(@"Здесь пока пусто")];
            } else {
                [_status hide];
            }

            [self rebuildRows];
            [self layoutHeader];
            [_table reloadData];
        });
    });
}

- (void)layoutHeader {
    CGFloat width = [[self view] bounds].size.width;
    CGFloat height = [_header heightForWidth:width];

    [_header setFrame:CGRectMake(0, 0, width, height)];
    [_header layoutIfNeeded];

    // Присвоение шапки заново — то, чем UITableView узнаёт о новой высоте.
    [_table setTableHeaderView:_header];

    [self positionStatus];
}

/**
 * Ставит «Здесь пока пусто» и «О канале» **под** шапкой.
 *
 * Раньше эта надпись занимала всю таблицу целиком и вставала посередине
 * неё — то есть поверх кружка и кнопки подписки, потому что шапка лежит
 * в той же таблице. Считаем от нижнего края шапки, а он уезжает вместе
 * с прокруткой, оттого и пересчёт на каждый сдвиг.
 */
- (void)positionStatus {
    CGRect box = [[self view] bounds];

    CGFloat contentTop = YTStatusBarHeight() + YTNavBarHeight;
    CGFloat below = [_header frame].size.height - [_table contentOffset].y;
    CGFloat top = contentTop + MAX((CGFloat)0, below);

    [_status setFrame:CGRectMake(0, top, box.size.width,
                                 MAX((CGFloat)0, box.size.height - top))];
}

- (void)rebuildRows {
    [_rows removeAllObjects];

    NSMutableArray *current = nil;

    for (YTVideoItem *item in _items) {
        if (current == nil || [current count] >= (NSUInteger)_columns) {
            current = [NSMutableArray array];
            [_rows addObject:current];
        }

        [current addObject:item];
    }
}

#pragma mark Таблица

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    // «О канале» — одна строка со сплошным текстом, роликов там нет.
    if ([_aboutText length] > 0) {
        return 1;
    }

    return (NSInteger)[_rows count];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path {
    if ([_aboutText length] > 0) {
        return [self aboutHeight] + YTChSide * 2;
    }

    NSArray *row = [_rows objectAtIndex:[path row]];

    CGFloat available = [[self view] bounds].size.width - YTFeedPadding * 2;
    CGFloat cardWidth = floor((available - YTCardSpacing * (_columns - 1)) / _columns);

    CGFloat height = 0;

    for (YTVideoItem *item in row) {
        height = MAX(height, [YTVideoCard heightForWidth:cardWidth item:item]);
    }

    return height + YTCardSpacing;
}

/** Высота описания при нынешней ширине. */
- (CGFloat)aboutHeight {
    CGFloat width = [[self view] bounds].size.width - YTChSide * 2;

    return YTTextHeight(_aboutText, YTFontRegular(14), width, 0);
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)path {
    /**
     * Описание строкой списка, а не надписью поверх него: у иного канала
     * оно на несколько экранов, и в поле для сообщения — восемьдесят точек
     * посередине — просто не помещается.
     */
    if ([_aboutText length] > 0) {
        static NSString *aboutIdentifier = @"about";

        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:aboutIdentifier];

        /**
         * Подпись своя, а не `textLabel` ячейки: тот сам себе назначает
         * место при раскладке, и заданное нами не удержится.
         */
        if (cell == nil) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:aboutIdentifier];

            [cell setSelectionStyle:UITableViewCellSelectionStyleNone];

            UILabel *text = YTLabel(YTFontRegular(14), [YTTheme primaryText], 0);

            [text setTag:1];
            [[cell contentView] addSubview:text];
        }

        UILabel *text = (UILabel *)[[cell contentView] viewWithTag:1];

        [cell setBackgroundColor:[YTTheme background]];
        [text setTextColor:[YTTheme primaryText]];
        [text setText:_aboutText];
        [text setFrame:CGRectMake(YTChSide, YTChSide,
                                  [[self view] bounds].size.width - YTChSide * 2,
                                  [self aboutHeight])];

        return cell;
    }

    static NSString *identifier = @"row";

    YTFeedRowCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];

    if (cell == nil) {
        cell = [[YTFeedRowCell alloc] initWithStyle:UITableViewCellStyleDefault
                                    reuseIdentifier:identifier];
    }

    [cell bindRow:[_rows objectAtIndex:[path row]]
            width:[[self view] bounds].size.width
          columns:_columns];

    return cell;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self positionStatus];

    if (![_pager claimOn:scrollView]) {
        return;
    }

    NSInteger generation = [_generation current];
    NSString *token = [_pager token];

    YTAsync(^{
        NSDictionary *feed = [YTApi browseContinuation:token];

        YTMain(^{
            [_pager finish];

            if (![_generation isCurrent:generation]) {
                return;
            }

            NSArray *items = [feed objectForKey:@"items"];

            if ([items count] == 0) {
                [_pager setToken:nil];
                return;
            }

            [_pager setToken:[feed objectForKey:@"continuation"]];
            [_items addObjectsFromArray:items];

            [self rebuildRows];
            [_table reloadData];
        });
    });
}

#pragma mark Раскладка

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];

    CGRect box = [[self view] bounds];
    CGFloat top = YTStatusBarHeight();

    [_bar setFrame:CGRectMake(0, top, box.size.width, YTNavBarHeight)];
    [_back setFrame:CGRectMake(4, 8, 40, 40)];
    [_barTitle setFrame:CGRectMake(48, 8, box.size.width - 64, 40)];

    CGFloat contentTop = top + YTNavBarHeight;

    [_table setFrame:CGRectMake(0, contentTop, box.size.width,
                                box.size.height - contentTop)];

    [self positionStatus];

    if (_laidOutWidth == box.size.width) {
        return;
    }

    _laidOutWidth = box.size.width;

    NSInteger columns = YTColumnsForWidth(box.size.width - YTFeedPadding * 2);

    if (columns != _columns) {
        _columns = columns;
        [self rebuildRows];
    }

    [self layoutHeader];
    [_table reloadData];
}

@end
