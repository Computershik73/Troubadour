#import "YTSimpleScreens.h"

#import "YTStrings.h"

#import <QuartzCore/QuartzCore.h>

#import "YTApi.h"
#import "YTAuth.h"
#import "YTFeedViews.h"
#import "YTImageLoader.h"
#import "YTMetrics.h"
#import "YTSettings.h"
#import "YTRoundedImageView.h"
#import "YTTheme.h"
#import "YTUtil.h"
#import "YTVideoItem.h"

/**
 * Полоса каналов — из Subscriptions.xaml и кода, который её наполняет.
 *
 *     ScrollViewer  Height="120", Margin="0,10,0,20", Padding="16,0,16,0"
 *     кнопка        Width=100, Margin="0,0,12,0"
 *     кружок        80×80
 *     подпись       12, Margin="0,8,0,0"
 *
 * Полоса **уезжает вместе с лентой**, а не висит над ней: в оригинале весь
 * раздел — одна вертикальная `ScrollViewer`, и полоса просто первый её
 * элемент. Здесь для этого она отдана таблице как шапка — только так
 * UITableView прокручивает чужой вид заодно со своими строками.
 *
 * Числа, однако, меньше исходных: там кружок 80 при ширине плитки 100 —
 * на телефоне Windows это четыре плитки в ряд, а в 320 точках экрана
 * iPhone 4 их влезает три, и кружки выходят непомерными. Здесь 56:
 * пять плиток в ряд, как полосе для беглого выбора и подобает.
 */
static const CGFloat YTStripHeight = 96;
static const CGFloat YTStripTop = 10;
static const CGFloat YTStripBottom = 16;
static const CGFloat YTChannelWidth = 72;
static const CGFloat YTChannelGap = 10;
static const CGFloat YTChannelAvatar = 56;


#pragma mark - Плитка канала

@interface YTChannelTile : YTTappableView

- (void)bind:(NSDictionary *)channel;

/** Берёт кружок канала — только для видимых плиток. */
- (void)loadAvatarIfNeeded;

/**
 * Нажатие открывает не страницу канала, а его ролики в этой же ленте —
 * так же, как `SubscriptionButton_Click` в оригинале: он зовёт
 * `LoadChannelVideosAsync` и подменяет содержимое списка, никуда не уходя.
 */
- (void)setOnPick:(void (^)(NSString *channelId))onPick;

/** Отмечает открытый сейчас канал. */
- (void)setPicked:(BOOL)picked;

@end

@implementation YTChannelTile {
    NSString *_thumbnail;
    BOOL _loaded;
    YTRoundedImageView *_avatar;
    UIImageView *_mark;
    UILabel *_title;
    NSString *_channelId;
    void (^_onPick)(NSString *channelId);
}

- (void)setOnPick:(void (^)(NSString *channelId))onPick {
    _onPick = [onPick copy];
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    [self setHighlights:NO];

    _avatar = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];
    [_avatar setCircular:YES];
    [self addSubview:_avatar];

    /**
     * Значок внутри кружка — только у плитки «Все».
     *
     * Своего кружка у неё нет и быть не может: это не канал. Пустой серый
     * круг ничего не говорил, а рядом с чужими лицами читался как канал
     * без аватарки. Значок подписок из полосы вкладок — то же, что и она
     * означает: все подписки разом.
     */
    _mark = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_mark setContentMode:UIViewContentModeScaleAspectFit];
    [_mark setUserInteractionEnabled:NO];
    [_mark setHidden:YES];
    [self addSubview:_mark];

    _loaded = NO;

    _title = YTLabel(YTFontRegular(12), [YTTheme primaryText], 2);
    [_title setTextAlignment:NSTextAlignmentCenter];
    [self addSubview:_title];

    __weak YTChannelTile *weakSelf = self;

    [self setOnTap:^{
        YTChannelTile *tile = weakSelf;

        if (tile != nil && tile->_onPick != nil) {
            tile->_onPick(tile->_channelId);
        }
    }];

    return self;
}

- (void)bind:(NSDictionary *)channel {
    _channelId = [channel objectForKey:@"channelId"];

    // Цвета берутся при каждой привязке: плитки переживают смену темы.
    [_avatar setPlaceholderColor:[YTTheme avatarPlaceholder]];
    [_title setTextColor:[YTTheme primaryText]];

    [_title setText:[channel objectForKey:@"title"]];

    /**
     * Кружок здесь **не** грузится, и это главное.
     *
     * Подписок бывает под тысячу, плитка создаётся на каждую, и загрузка
     * при привязке ставила в очередь тысячу картинок разом. Загрузчик
     * тянет их по две за раз, по полсекунды на штуку, — очередь выходила
     * на десять минут, и всё это время превью самих роликов ждали позади
     * кружков каналов, до которых человек, скорее всего, никогда
     * не долистает. Отсюда и «аватарки только у первых нескольких».
     *
     * Грузятся теперь только те, что видны: за это отвечает
     * `loadAvatarIfNeeded`, а зовёт его полоса при прокрутке.
     */
    _thumbnail = [[channel objectForKey:@"thumbnail"] copy];
    _loaded = NO;

    [_avatar setImage:nil];

    // Плитка «Все» — единственная без канала: у неё вместо кружка значок.
    BOOL isAll = [_channelId length] == 0;

    [_mark setHidden:!isAll];

    if (isAll) {
        [_mark setImage:YTIcon(@"tab_subs_on")];
    }

    [self setNeedsLayout];
}

/** Подтягивает кружок, если плитка видна и он ещё не взят. */
- (void)loadAvatarIfNeeded {
    if (_loaded || [_thumbnail length] == 0) {
        return;
    }

    _loaded = YES;

    [YTImageLoader loadInto:_avatar
                        url:_thumbnail
                targetWidth:YTChannelAvatar];
}

- (void)setPicked:(BOOL)picked {
    // Выбранный канал выделяется насыщенностью подписи: своего состояния
    // у кнопки канала в оригинале нет, а отличать открытый как-то нужно.
    [_title setFont:picked ? YTFontSemiBold(12) : YTFontRegular(12)];
    [_title setTextColor:picked ? [YTTheme primaryText] : [YTTheme secondaryText]];
}

- (void)layoutSubviews {
    CGFloat width = [self bounds].size.width;

    [_avatar setFrame:CGRectMake((width - YTChannelAvatar) / 2, 0,
                                 YTChannelAvatar, YTChannelAvatar)];

    // Значок вписан в кружок с полем: во всю ширину он смотрелся бы
    // не значком, а картинкой канала.
    CGFloat side = round(YTChannelAvatar * 0.5f);

    [_mark setFrame:CGRectMake((width - side) / 2,
                               (YTChannelAvatar - side) / 2, side, side)];

    [_title setFrame:CGRectMake(0, YTChannelAvatar + 8, width, 28)];
}

@end


#pragma mark - Раздел

@interface YTSubscriptionsView () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation YTSubscriptionsView {
    UIScrollView *_strip;
    NSMutableArray *_tiles;
    NSArray *_channels;

    /** Открытый сейчас канал; пусто — общая лента всех подписок. */
    NSString *_channelFilter;
    CGFloat _stripWidth;

    UITableView *_table;
    YTStatusView *_status;

    NSMutableArray *_items;
    NSMutableArray *_rows;

    YTPager *_pager;
    YTGeneration *_generation;

    /**
     * У полосы каналов своё поколение, и это не мелочь.
     *
     * `activate` запускает загрузку каналов, а следом — загрузку ленты,
     * и та начинает новое поколение. Ответ со списком каналов приходил
     * уже «устаревшим» и выбрасывался целиком: в журнале каналы находились
     * («каналов найдено: 954»), а полосы на экране не было ни разу.
     */
    YTGeneration *_stripGeneration;

    NSInteger _columns;
    CGFloat _laidOutWidth;
    BOOL _loaded;

    /** Прятали ли Shorts, когда лента набиралась. */
    BOOL _hidShorts;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    _tiles = [NSMutableArray array];
    _items = [NSMutableArray array];
    _rows = [NSMutableArray array];
    _pager = [[YTPager alloc] init];
    _generation = [[YTGeneration alloc] init];
    _stripGeneration = [[YTGeneration alloc] init];
    _columns = 1;

    [self setBackgroundColor:[YTTheme background]];

    _strip = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [_strip setShowsHorizontalScrollIndicator:NO];
    [_strip setShowsVerticalScrollIndicator:NO];

    // Прокрутка полосы нужна нам, чтобы подтягивать кружки видимых плиток.
    [_strip setDelegate:self];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    [_table setDataSource:self];
    [_table setDelegate:self];
    [_table setSeparatorStyle:UITableViewCellSeparatorStyleNone];
    [_table setBackgroundColor:[YTTheme background]];
    [_table setBackgroundView:nil];
    [self addSubview:_table];

    _status = [[YTStatusView alloc] initWithFrame:CGRectZero];
    [self addSubview:_status];

    _hidShorts = [YTSettings hidesShorts];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(authChanged)
                                                 name:YTAuthChangedNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(settingsChanged)
                                                 name:YTSettingsChangedNotification
                                               object:nil];

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)authChanged {
    _loaded = NO;

    [self activate];
}

/**
 * Перечитываем, только если сменился отсев Shorts.
 *
 * Уведомление приходит на любую настройку, а лента подписок — самый
 * тяжёлый ответ в приложении: у человека с сотней подписок это больше
 * мегабайта. Перечитывать её из-за смены темы или ширины превью было бы
 * расточительством.
 */
- (void)settingsChanged {
    BOOL hides = [YTSettings hidesShorts];

    if (hides == _hidShorts) {
        return;
    }

    _hidShorts = hides;

    _loaded = NO;

    [self activate];
}

- (void)activate {
    if (_loaded) {
        return;
    }

    _loaded = YES;

    /**
     * Подписки существуют только у вошедшего: `FEsubscriptions` без токена
     * отвечает пустотой. Поэтому здесь не заглушка ленты, а прямая просьба
     * войти — показывать пустой раздел было бы враньём.
     */
    if (![YTAuth isSignedIn]) {
        [_table setTableHeaderView:nil];
        [_table setHidden:YES];

        /**
         * Кнопка уводит на вкладку «Моё»: вход живёт там, а не отдельным
         * экраном — так же, как в оригинале, где `AccountButton_Click`
         * открывает `Login.xaml` вместо `Me.xaml`.
         */
        [_status showOffline:YTLoc(@"Войдите в аккаунт")
                        hint:YTLoc(@"Подписки и их свежие ролики появятся здесь после входа")
                 actionTitle:YTLoc(@"Войти")
                      action:^{
            [YTNav selectTab:3];
        }];

        return;
    }

    [_table setHidden:NO];

    [self loadChannels];
    [self loadFeed];
}

- (void)loadChannels {
    NSInteger generation = [_stripGeneration next];

    YTAsync(^{
        NSArray *channels = [YTApi subscriptions];

        YTMain(^{
            if (![_stripGeneration isCurrent:generation]) {
                return;
            }

            [self rebuildStrip:channels];
        });
    });
}

- (void)rebuildStrip:(NSArray *)channels {
    /**
     * Первой плиткой — «Все»: возврат к общей ленте подписок.
     *
     * В оригинале возвращаться некуда и незачем — там страница подписок
     * живёт в кадре с аппаратной кнопкой «назад», а здесь, выбрав канал,
     * выйти из него было бы нечем. Плитка сделана такой же, как остальные,
     * только вместо кружка канала — подложка.
     */
    NSMutableArray *all = [NSMutableArray arrayWithObject:
        [NSDictionary dictionaryWithObjectsAndKeys:YTLoc(@"Все"), @"title", nil]];

    [all addObjectsFromArray:channels];

    channels = all;
    _channels = channels;

    while ([_tiles count] < [channels count]) {
        YTChannelTile *tile = [[YTChannelTile alloc] initWithFrame:CGRectZero];

        [_strip addSubview:tile];
        [_tiles addObject:tile];
    }

    for (NSUInteger i = 0; i < [_tiles count]; i++) {
        YTChannelTile *tile = [_tiles objectAtIndex:i];

        if (i >= [channels count]) {
            [tile setHidden:YES];
            continue;
        }

        NSDictionary *channel = [channels objectAtIndex:i];
        NSString *channelId = [channel objectForKey:@"channelId"];

        [tile setHidden:NO];
        [tile bind:channel];
        [tile setPicked:(channelId == nil)
            ? [_channelFilter length] == 0
            : [channelId isEqualToString:_channelFilter]];

        __weak YTSubscriptionsView *weakSelf = self;

        [tile setOnPick:^(NSString *picked) {
            [weakSelf pickChannel:picked];
        }];

        // `Margin="0,10,0,20"` у полосы: сверху 10, снизу 20.
        [tile setFrame:CGRectMake(16 + (YTChannelWidth + YTChannelGap) * i, YTStripTop,
                                  YTChannelWidth, YTStripHeight)];
    }

    [_strip setContentSize:CGSizeMake(16 + (YTChannelWidth + YTChannelGap) * [channels count] + 4,
                                      YTStripTop + YTStripHeight + YTStripBottom)];

    // Кружки видимых плиток — сразу, остальные по мере прокрутки.
    [self loadVisibleAvatars];

    /**
     * Шапка назначается заново — этим UITableView и узнаёт, что её высота
     * изменилась. Пустая полоса не занимает места вовсе: у невошедшего
     * и у того, у кого подписок нет, лента начинается сразу.
     */
    // Одна плитка — это только «Все»: показывать полосу не из чего.
    if ([channels count] < 2) {
        [_table setTableHeaderView:nil];
        return;
    }

    [self attachStrip];
}

/**
 * Отдаёт полосу таблице шапкой.
 *
 * Ширину приходится назначать самим и до присвоения: `UITableView` берёт
 * у шапки готовый размер и сам её не растягивает. Без этого полоса
 * получала нулевую ширину — и не показывалась вовсе.
 */
- (void)attachStrip {
    CGFloat width = [self bounds].size.width;

    if (width <= 0) {
        return;
    }

    _stripWidth = width;

    [_strip setFrame:CGRectMake(0, 0, width,
                                YTStripTop + YTStripHeight + YTStripBottom)];

    [_table setTableHeaderView:_strip];

    /**
     * Кружки берём **после** того, как полоса получила размер.
     *
     * `loadVisibleAvatars` первым делом смотрит на ширину полосы и при
     * нуле молча выходит. Стоял он выше `setFrame:`, то есть у полосы
     * шириной ноль, — и не грузил ничего. Дальше его зовёт только
     * прокрутка полосы вбок, поэтому кружки появлялись лишь у того, кто
     * догадался её потянуть, а у остальных подписки стояли пустыми.
     */
    [self loadVisibleAvatars];
}

/** Выбран канал в полосе — или «Все», и тогда возвращается общая лента. */
- (void)pickChannel:(NSString *)channelId {
    if (channelId == nil && [_channelFilter length] == 0) {
        return;
    }

    if (channelId != nil && [channelId isEqualToString:_channelFilter]) {
        return;
    }

    _channelFilter = [channelId copy];

    for (NSUInteger i = 0; i < [_tiles count] && i < [_channels count]; i++) {
        NSString *tileId = [[_channels objectAtIndex:i] objectForKey:@"channelId"];

        [[_tiles objectAtIndex:i] setPicked:(tileId == nil)
            ? [_channelFilter length] == 0
            : [tileId isEqualToString:_channelFilter]];
    }

    [self loadFeed];
}

- (void)loadFeed {
    NSInteger generation = [_generation next];

    [_pager reset];

    if ([_items count] == 0) {
        [_status showBusy];
    }

    NSString *filter = _channelFilter;

    YTAsync(^{
        // Выбран канал — показываем его ролики, как `LoadChannelVideosAsync`.
        NSDictionary *feed = [filter length] > 0
            ? [YTApi channel:filter tab:@"videos"]
            : [YTApi subscriptionsFeed:nil];

        YTMain(^{
            if (![_generation isCurrent:generation]) {
                return;
            }

            NSArray *items = [feed objectForKey:@"items"];

            [_items removeAllObjects];
            [_items addObjectsFromArray:items];

            [_pager setToken:[feed objectForKey:@"continuation"]];

            if ([_items count] == 0) {
                [_status showMessage:[filter length] > 0
                    ? YTLoc(@"У канала пока нет роликов")
                    : YTLoc(@"В подписках пока пусто")];
            } else {
                [_status hide];
            }

            [self rebuildRows];
            [_table reloadData];
        });
    });
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
    return (NSInteger)[_rows count];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path {
    NSArray *row = [_rows objectAtIndex:[path row]];

    CGFloat available = [self bounds].size.width - YTFeedPadding * 2;
    CGFloat cardWidth = floor((available - YTCardSpacing * (_columns - 1)) / _columns);

    CGFloat height = 0;

    for (YTVideoItem *item in row) {
        height = MAX(height, [YTVideoCard heightForWidth:cardWidth item:item]);
    }

    return height + YTCardSpacing;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)path {
    static NSString *identifier = @"row";

    YTFeedRowCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];

    if (cell == nil) {
        cell = [[YTFeedRowCell alloc] initWithStyle:UITableViewCellStyleDefault
                                    reuseIdentifier:identifier];
    }

    [cell bindRow:[_rows objectAtIndex:[path row]]
            width:[self bounds].size.width
          columns:_columns];

    return cell;
}

/**
 * Подтягивает кружки тех плиток, что видны сейчас, плюс полосу запаса
 * шириной в экран — чтобы при неспешной прокрутке они успевали прийти
 * раньше, чем плитка появится.
 */
- (void)loadVisibleAvatars {
    CGFloat width = [_strip bounds].size.width;

    if (width <= 0) {
        return;
    }

    CGFloat from = [_strip contentOffset].x - width;
    CGFloat to = [_strip contentOffset].x + width * 2;

    for (YTChannelTile *tile in _tiles) {
        if ([tile isHidden]) {
            continue;
        }

        CGRect frame = [tile frame];

        if (CGRectGetMaxX(frame) < from || frame.origin.x > to) {
            continue;
        }

        [tile loadAvatarIfNeeded];
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == _strip) {
        [self loadVisibleAvatars];

        return;
    }

    if (scrollView != _table || ![_pager claimOn:scrollView]) {
        return;
    }

    NSInteger generation = [_generation current];
    NSString *token = [_pager token];
    NSString *filter = _channelFilter;

    YTAsync(^{
        NSDictionary *feed = [filter length] > 0
            ? [YTApi browseContinuation:token]
            : [YTApi subscriptionsFeed:token];

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

- (void)applyTheme {
    [self setBackgroundColor:[YTTheme background]];
    [_table setBackgroundColor:[YTTheme background]];
    [_strip setBackgroundColor:[YTTheme background]];

    [_table reloadData];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect box = [self bounds];

    // Полоса каналов — шапка таблицы, поэтому таблица занимает всё место,
    // а полоса уезжает вверх вместе с лентой.
    [_table setFrame:box];
    [_status setFrame:box];

    // Ширина шапки задаётся не раскладкой, а присвоением: таблица берёт
    // у неё готовый размер один раз.
    if ([_table tableHeaderView] == _strip && _stripWidth != box.size.width) {
        [self attachStrip];
    }

    if (_laidOutWidth == box.size.width) {
        return;
    }

    _laidOutWidth = box.size.width;

    NSInteger columns = YTColumnsForWidth(box.size.width - YTFeedPadding * 2);

    if (columns != _columns) {
        _columns = columns;
        [self rebuildRows];
    }

    [_table reloadData];
}

@end
