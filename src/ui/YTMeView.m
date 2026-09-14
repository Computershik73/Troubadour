#import "YTSimpleScreens.h"

#import "YTStrings.h"

#import "YTAccountSheet.h"
#import "YTApi.h"
#import "YTDownloads.h"
#import "YTAuth.h"
#import "YTImageLoader.h"
#import "YTMetrics.h"
#import "YTSettings.h"
#import "YTRoundedImageView.h"
#import "YTSkin.h"
#import "YTTheme.h"
#import "YTUtil.h"
#import "YTVideoItem.h"

/**
 * Числа — из Me.xaml.
 *
 *     строка сверху   Height="44", Margin="16,0,16,4";
 *                     лупа 38×38 со значком 22, шестерёнка 38×38 со значком 24,
 *                     между ними 6
 *     профиль         Margin="16,6,16,16"; кружок 60; текст с отступом 12;
 *                     имя 20 SemiBold, ниже собачка 12 secondary
 *     «История»       Margin="16,0,16,8", 18 SemiBold со стрелкой
 *     полоса истории  карточка 160 с отступом 16; превью 160×90;
 *                     плашка 4×1, скругление 4, фон #D1000000, подпись 10 SemiBold
 */
static const CGFloat YTMeBar = 44;
static const CGFloat YTMeAvatar = 60;
static const CGFloat YTHistoryCard = 160;
static const CGFloat YTHistoryThumb = 90;


#pragma mark - Карточка истории

@interface YTHistoryTile : YTTappableView

- (void)bind:(YTVideoItem *)item;

/** Превью берётся отдельно — только у карточек, попавших на глаза. */
- (void)loadThumbIfNeeded;

/** Перекрашивает подписи; зовётся при смене темы. */
- (void)applyTheme;

@end

@implementation YTHistoryTile {
    YTRoundedImageView *_thumb;
    YTPillView *_badgePill;
    UILabel *_badge;
    UILabel *_title;
    UILabel *_subtitle;
    YTVideoItem *_item;

    /** Ссылка на превью и признак того, что за ним уже ходили. */
    NSString *_thumbUrl;
    BOOL _thumbAsked;

    /** Полоска просмотра — та же, что на карточках ленты. */
    UIView *_watchedTrack;
    UIView *_watchedFill;
    double _watchedShare;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    [self setHighlights:NO];

    [self setBackgroundColor:[UIColor clearColor]];
    [self setOpaque:NO];
    [self setContentMode:UIViewContentModeRedraw];

    _thumb = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];

    // Скругление то же, что у карточек ленты: `CornerRadius="8"`
    // в оригинале задан один на все превью.
    [_thumb setCornerRadius:YTThumbRadius];
    [self addSubview:_thumb];

    _badgePill = [[YTPillView alloc] initWithFrame:CGRectZero];
    [_badgePill setCornerRadius:4];
    [self addSubview:_badgePill];

    _watchedTrack = [[UIView alloc] initWithFrame:CGRectZero];
    [_watchedTrack setUserInteractionEnabled:NO];
    [self addSubview:_watchedTrack];

    _watchedFill = [[UIView alloc] initWithFrame:CGRectZero];
    [_watchedFill setUserInteractionEnabled:NO];
    [self addSubview:_watchedFill];

    _badge = YTLabel(YTFontSemiBold(10), [UIColor whiteColor], 1);
    [_badge setTextAlignment:NSTextAlignmentCenter];
    [self addSubview:_badge];

    // `FontSize="13"` у названия и `11` у подписи — числа из Me.xaml.
    _title = YTLabel(YTFontRegular(13), [YTTheme primaryText], 2);
    [self addSubview:_title];

    _subtitle = YTLabel(YTFontRegular(11), [YTTheme secondaryText], 1);
    [self addSubview:_subtitle];

    __weak YTHistoryTile *weakSelf = self;

    [self setOnTap:^{
        YTHistoryTile *tile = weakSelf;

        if (tile == nil || tile->_item == nil) {
            return;
        }

        if ([tile->_item isPlaylist]) {
            [YTNav openPlaylist:tile->_item.playlistId title:tile->_item.title];
        } else {
            [YTNav openVideo:tile->_item.videoId title:tile->_item.title];
        }
    }];

    return self;
}

- (void)applyTheme {
    [_thumb setPlaceholderColor:[YTTheme surfaceAlt]];
    [_title setTextColor:[YTTheme cardText]];
    [_subtitle setTextColor:[YTTheme cardSecondaryText]];

    // Подложка могла смениться вместе с оформлением — перерисуемся.
    [self setNeedsDisplay];

    // `Background="#D1000000"` — плашка здесь чуть плотнее, чем в ленте.
    [_badgePill setFillColor:[UIColor colorWithWhite:0 alpha:0.82]];

    // Цвета полоски — те же, что в ленте: серая дорожка, красная доля.
    [_watchedTrack setBackgroundColor:[UIColor colorWithWhite:1 alpha:0.28]];
    [_watchedFill setBackgroundColor:YTColor(0xFF0000)];
}

/** Подложка плитки: при объёмном оформлении — выпуклый лист. */
- (void)drawRect:(CGRect)rect {
    [YTSkin drawCardInRect:CGRectInset(
        CGRectMake(0, 0, YTHistoryCard, [self bounds].size.height), 1, 1)];
}

- (void)bind:(YTVideoItem *)item {
    _item = item;

    [self applyTheme];

    [_title setText:item.title];

    /**
     * Вторая строка карточки — «автор • давность», как `Margin="0,3,0,0"`
     * подписи в Me.xaml. У подборки автора нет, там стоит пометка.
     */
    NSMutableArray *parts = [NSMutableArray array];

    if ([item.channelTitle length] > 0) { [parts addObject:item.channelTitle]; }
    if ([item.published length] > 0)    { [parts addObject:item.published]; }

    [_subtitle setText:[parts componentsJoinedByString:@" • "]];

    [_badge setText:item.duration];

    /**
     * Плашка есть у обеих полос: у ролика в ней длительность, у подборки —
     * число роликов. В Me.xaml у подборки её нет вовсе, но пустой угол
     * ничего не говорит, а счётчик — говорит.
     */
    BOOL hasDuration = [item.duration length] > 0;

    [_badge setHidden:!hasDuration];
    [_badgePill setHidden:!hasDuration];

    /**
     * Доля просмотра: у подборок её не бывает, и полоска там читалась бы
     * как «досмотрено до половины» у того, что не смотрят целиком.
     */
    _watchedShare = (item.isLive || [item isPlaylist])
        ? 0 : MAX(0.0, item.watchedShare);

    [_watchedTrack setHidden:(_watchedShare <= 0)];
    [_watchedFill setHidden:(_watchedShare <= 0)];

    /**
     * Превью здесь не запрашивается — только запоминается.
     *
     * История приходит одной страницей и бывает в сотню записей. Раньше
     * карточка бралась за картинку сразу, все разом: столько же загрузок
     * в очереди и столько же разобранных картинок в памяти. На iPhone 4
     * это заметно, а страница показывает от силы три карточки за раз.
     * Остальные подтягиваются по мере прокрутки — как на странице
     * подписок.
     */
    _thumbUrl = [item.thumbnail copy];
    _thumbAsked = NO;

    [_thumb setImage:nil];

    [self setNeedsLayout];
}

/** Просит превью, если карточка видна и за ним ещё не ходили. */
- (void)loadThumbIfNeeded {
    if (_thumbAsked || [_thumbUrl length] == 0) {
        return;
    }

    _thumbAsked = YES;

    [YTImageLoader loadInto:_thumb url:_thumbUrl targetWidth:YTHistoryCard];
}

- (void)layoutSubviews {
    /**
     * Поле под рамку — только при объёмном оформлении.
     *
     * Иначе рамка идёт впритык к превью, и лист не читается листом.
     */
    CGFloat pad = [YTSkin isClassic] ? 4 : 0;
    CGFloat inner = YTHistoryCard - pad * 2;

    [_thumb setFrame:CGRectMake(pad, pad, inner, YTHistoryThumb - pad)];

    // Плашка: `Margin="0,0,4,4"`, `Padding="4,1"`.
    CGSize text = [[_badge text] sizeWithFont:[_badge font]];

    CGFloat width = ceil(text.width) + 8;
    CGFloat height = ceil(text.height) + 2;

    CGRect badge = CGRectMake(YTHistoryCard - pad - width - 4,
                              YTHistoryThumb - height - 4, width, height);

    [_badgePill setFrame:badge];
    [_badge setFrame:badge];

    // Полоска — по нижнему краю превью, в четыре точки, как в ленте.
    if (![_watchedTrack isHidden]) {
        CGFloat bar = 4;
        CGFloat top = YTHistoryThumb - bar;

        [_watchedTrack setFrame:CGRectMake(0, top, YTHistoryCard, bar)];
        [_watchedFill setFrame:CGRectMake(0, top,
            (CGFloat)(YTHistoryCard * _watchedShare), bar)];
    }

    // `Margin="0,6,0,0"` у названия и `0,3,0,0` у подписи под ним.
    [_title setFrame:CGRectMake(pad, YTHistoryThumb + 6, inner, 34)];
    [_subtitle setFrame:CGRectMake(pad, YTHistoryThumb + 6 + 34 + 3, inner, 14)];
}

@end


#pragma mark - Раздел

/**
 * Согласие следить за прокруткой объявлено здесь, а не в заголовке:
 * наружу оно никому не нужно, а заголовок общий на полдюжины экранов.
 */
@interface YTMeView () <UIScrollViewDelegate>
@end

@implementation YTMeView {
    UIScrollView *_page;

    YTTappableView *_searchButton;
    UIImageView *_searchIcon;
    YTTappableView *_settingsButton;
    UIImageView *_settingsIcon;

    YTRoundedImageView *_avatar;
    UILabel *_name;
    UILabel *_handle;

    /** Накладка для выбора канала: сам список — в `YTAccountSheet`. */
    YTTappableView *_profileTouch;

    YTTappableView *_historyHeader;
    UILabel *_historyTitle;
    UIScrollView *_historyStrip;
    NSMutableArray *_tiles;

    /**
     * Полоса истории дописывается на ходу, как и вертикальные списки:
     * первая страница — полтора десятка карточек, и, докрутив до конца,
     * человек упирался в стену там, где история продолжается.
     */
    NSMutableArray *_historyItems;
    YTPager *_historyPager;

    UILabel *_playlistsTitle;

    /**
     * Полки под заголовками разделов.
     *
     * Отдельными видами, а не фоном у самих заголовков: у «Плейлистов»
     * заголовок — обычная подпись, и подвид внутри неё закрыл бы текст,
     * а у остальных двух он лежит в нажимаемом виде. Один приём на все
     * три проще, чем два разных.
     */
    YTSkinShelfView *_historyShelf;
    YTSkinShelfView *_playlistsShelf;
    YTSkinShelfView *_downloadsShelf;
    UIScrollView *_playlistsStrip;
    NSMutableArray *_playlistTiles;

    /**
     * Полоса «Скачанные» — третья, под плейлистами.
     *
     * От двух соседних отличается тем, что не ходит в сеть вовсе:
     * и записи, и превью лежат на устройстве. Поэтому она показывается
     * и без входа, и без связи — единственная на этой вкладке.
     */
    YTTappableView *_downloadsHeader;
    UILabel *_downloadsTitle;
    UIScrollView *_downloadsStrip;
    NSMutableArray *_downloadTiles;

    /**
     * Вход показывается прямо здесь, а не отдельным экраном.
     *
     * В оригинале `AccountButton_Click` при отсутствии входа открывает
     * `Login.xaml` вместо `Me.xaml`: вкладка «Моё» и есть страница входа,
     * пока в аккаунт не вошли.
     */
    YTLoginView *_login;

    YTGeneration *_generation;
    YTRefreshHeader *_refresh;
    BOOL _loaded;

    /** Прятали ли Shorts, когда страница набиралась. */
    BOOL _hidShorts;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    _tiles = [NSMutableArray array];
    _playlistTiles = [NSMutableArray array];
    _historyItems = [NSMutableArray array];
    _historyPager = [[YTPager alloc] init];
    _generation = [[YTGeneration alloc] init];

    [self setBackgroundColor:[YTTheme background]];

    _page = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [_page setDelegate:self];

    // Без этого страница, уместившаяся на экран целиком, не оттягивается
    // вовсе — а значит, и обновить её нечем.
    [_page setAlwaysBounceVertical:YES];

    [self addSubview:_page];

    __weak YTMeView *weakSelf = self;

    /**
     * Потянуть страницу — перечитать её.
     *
     * Просмотренный ролик попадает в историю не в ту же секунду: отметка
     * уходит служебным запросом, а полоса набрана заранее и сама
     * не обновляется. Пока обновить её можно было только сменой вкладки
     * туда-обратно, да и то не всегда — страница читается один раз
     * за открытие.
     */
    _refresh = [YTRefreshHeader attachedTo:_page action:^{
        [weakSelf refreshPage];
    }];

    _searchButton = [[YTTappableView alloc] initWithFrame:CGRectZero];
    [_searchButton setHighlights:NO];
    [_searchButton setOnTap:^{
        [YTNav push:[[YTSearchViewController alloc] init]];
    }];
    [_page addSubview:_searchButton];

    _searchIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_searchIcon setContentMode:UIViewContentModeScaleAspectFit];
    [_searchIcon setUserInteractionEnabled:NO];
    [_searchButton addSubview:_searchIcon];

    _settingsButton = [[YTTappableView alloc] initWithFrame:CGRectZero];
    [_settingsButton setHighlights:NO];
    [_settingsButton setOnTap:^{
        [YTNav push:[[YTSettingsViewController alloc] init]];
    }];
    [_page addSubview:_settingsButton];

    _settingsIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_settingsIcon setContentMode:UIViewContentModeScaleAspectFit];
    [_settingsIcon setUserInteractionEnabled:NO];
    [_settingsButton addSubview:_settingsIcon];

    _avatar = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];
    [_avatar setCircular:YES];
    [_page addSubview:_avatar];

    _name = YTLabel(YTFontSemiBold(20), [YTTheme primaryText], 1);
    [_page addSubview:_name];

    _handle = YTLabel(YTFontRegular(12), [YTTheme secondaryText], 1);
    [_page addSubview:_handle];

    /**
     * По кружку с именем открывается выбор канала.
     *
     * У одной учётной записи Google каналов бывает несколько — личный,
     * бренд-каналы, детский, — и какой из них считать своим, сервер
     * решает сам. Решает не всегда так, как ждёт человек, поэтому выбор
     * отдан ему.
     */
    _profileTouch = [[YTTappableView alloc] initWithFrame:CGRectZero];
    [_profileTouch setHighlights:NO];
    [_page addSubview:_profileTouch];

    {
        __weak YTMeView *weakSelf = self;

        [_profileTouch setOnTap:^{ [weakSelf pickAccount]; }];
    }

    _historyHeader = [[YTTappableView alloc] initWithFrame:CGRectZero];
    [_historyHeader setHighlights:NO];
    [_page addSubview:_historyHeader];

    // Стрелка в заголовке не для красоты: по нему открывается вся история,
    // как `HistoryHeader_Click` в оригинале.
    [_historyHeader setOnTap:^{
        [YTNav push:[[YTHistoryViewController alloc] init]];
    }];

    /**
     * Полка ложится **под** заголовок.
     *
     * Заголовок к этому мигу уже добавлен на страницу, и обычное
     * добавление положило бы полку поверх него: подписи «История»
     * и «Скачанные» пропали под ней целиком.
     */
    _historyShelf = [[YTSkinShelfView alloc] initWithFrame:CGRectZero];
    [_page insertSubview:_historyShelf belowSubview:_historyHeader];

    _historyTitle = YTLabel(YTFontSemiBold(18), [YTTheme primaryText], 1);
    [_historyTitle setText:YTLoc(@"История  ›")];
    [_historyHeader addSubview:_historyTitle];

    _historyStrip = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [_historyStrip setShowsHorizontalScrollIndicator:NO];
    [_historyStrip setDelegate:self];
    [_page addSubview:_historyStrip];

    /**
     * Полоса «Плейлисты» — вторая такая же в Me.xaml, ниже истории:
     * заголовок 18 SemiBold с теми же отступами и карточки 160 без плашки
     * длительности (у подборки её нет, там пометка).
     */
    _playlistsShelf = [[YTSkinShelfView alloc] initWithFrame:CGRectZero];
    [_page addSubview:_playlistsShelf];

    _playlistsTitle = YTLabel(YTFontSemiBold(18), [YTTheme primaryText], 1);
    [_playlistsTitle setText:YTLoc(@"Плейлисты")];
    [_page addSubview:_playlistsTitle];

    _playlistsStrip = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [_playlistsStrip setShowsHorizontalScrollIndicator:NO];
    [_playlistsStrip setDelegate:self];
    [_page addSubview:_playlistsStrip];

    _downloadTiles = [NSMutableArray array];

    _downloadsHeader = [[YTTappableView alloc] initWithFrame:CGRectZero];
    [_downloadsHeader setHighlights:NO];
    [_page addSubview:_downloadsHeader];

    // Стрелка означает то же, что у истории: по заголовку открывается всё.
    [_downloadsHeader setOnTap:^{
        [YTNav push:[[YTDownloadsViewController alloc] init]];
    }];

    _downloadsShelf = [[YTSkinShelfView alloc] initWithFrame:CGRectZero];
    [_page insertSubview:_downloadsShelf belowSubview:_downloadsHeader];

    _downloadsTitle = YTLabel(YTFontSemiBold(18), [YTTheme primaryText], 1);
    [_downloadsTitle setText:YTLoc(@"Скачанные  ›")];
    [_downloadsHeader addSubview:_downloadsTitle];

    _downloadsStrip = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [_downloadsStrip setShowsHorizontalScrollIndicator:NO];
    [_downloadsStrip setDelegate:self];
    [_page addSubview:_downloadsStrip];

    // Полоса живёт своей жизнью: загрузка идёт в фоне и сообщает о себе.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(rebuildDownloads)
                                                 name:YTDownloadsChangedNotification
                                               object:nil];

    _login = [[YTLoginView alloc] initWithFrame:CGRectZero];
    [self addSubview:_login];

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

/**
 * Список каналов. Сам список — в `YTAccountSheet`: его открывают ещё
 * и с кружка в нижней панели, а показывать один и тот же список двумя
 * разными способами значило бы чинить его потом дважды.
 */
- (void)pickAccount {
    [YTAccountSheet openIn:self];
}

/**
 * Вход, выход и смена канала случаются на чужом потоке.
 *
 * Вход по QR-коду завершается в опросе, который идёт своим ходом, и
 * оповещение приходит оттуда же. Обновлять по нему виды напрямую нельзя:
 * UIKit из чужого потока — это не «иногда мигает», а падение либо
 * потерянная перерисовка. Второе мы и видели: полоса вкладок обновлялась
 * позже, своим чередом, а страница «Вы» так и оставалась с QR-кодом,
 * хотя вход уже был засчитан.
 */
- (void)authChanged {
    YTMain(^{
        _loaded = NO;

        [self activate];
    });
}

/**
 * Перечитываем, только если сменился отсев Shorts.
 *
 * Здесь это заметнее, чем в лентах: в истории просмотров вертикальных
 * роликов обычно больше всего, и полоса без перечитывания осталась бы
 * ровно такой, какой была.
 */
- (void)settingsChanged {
    BOOL hides = [YTSettings hidesShorts];

    if (hides == _hidShorts) {
        return;
    }

    _hidShorts = hides;

    YTMain(^{
        _loaded = NO;

        [self activate];
    });
}

- (void)activate {
    if (_loaded) {
        return;
    }

    _loaded = YES;

    /**
     * Профиль и история существуют только у вошедшего. Строка с лупой
     * и шестерёнкой остаётся всегда: настройки нужны и без входа.
     */
    BOOL signedIn = [YTAuth isSignedIn];

    [_login setHidden:signedIn];
    [_page setHidden:!signedIn];

    if (signedIn) {
        [_login deactivate];
    } else {
        [_login activate];
    }

    [_avatar setHidden:!signedIn];
    [_name setHidden:!signedIn];
    [_handle setHidden:!signedIn];
    [_historyHeader setHidden:!signedIn];
    [_historyStrip setHidden:!signedIn];
    [_playlistsTitle setHidden:!signedIn];
    [_playlistsStrip setHidden:!signedIn];

    /**
     * Скачанное строится до всякой сети и независимо от неё.
     *
     * Две полосы выше ждут ответа сервера, эта — не ждёт ничего:
     * перечень и превью лежат на диске. Поэтому она и заполняется
     * здесь, до проверок и до запросов.
     */
    [self rebuildDownloads];

    if (!signedIn) {
        [_refresh finish];
        [self setNeedsLayout];

        return;
    }

    NSInteger generation = [_generation next];

    YTAsync(^{
        NSDictionary *profile = [YTApi accountProfile];
        NSDictionary *history = [YTApi history:nil];
        NSArray *playlists = [YTApi myPlaylists];

        YTMain(^{
            if (![_generation isCurrent:generation]) {
                return;
            }

            [_refresh finish];

            /**
             * Имя и собачка — из `accountItem`, как `ApplyProfile`
             * в Me.xaml.cs. Собачка есть не у всякого аккаунта: у канала
             * без выбранного адреса её нет, и строка под именем в оригинале
             * тогда прячется.
             */
            NSString *name = [profile objectForKey:@"name"];
            NSString *handle = [profile objectForKey:@"handle"];
            NSString *avatar = [profile objectForKey:@"avatar"];

            [_name setText:[name length] > 0 ? name : YTLoc(@"Без имени")];

            if ([handle length] > 0) {
                [_handle setText:[handle hasPrefix:@"@"]
                    ? handle
                    : [@"@" stringByAppendingString:handle]];
            }

            [_handle setHidden:[handle length] == 0];

            if ([avatar length] > 0) {
                [YTImageLoader loadInto:_avatar url:avatar targetWidth:YTMeAvatar];
            }

            [_historyItems removeAllObjects];
            [_historyItems addObjectsFromArray:[history objectForKey:@"items"]];

            [_historyPager reset];
            [_historyPager setToken:[history objectForKey:@"continuation"]];

            [self rebuildHistory:_historyItems];
            [self rebuildPlaylists:playlists];
        });
    });
}

- (void)rebuildHistory:(NSArray *)items {
    while ([_tiles count] < [items count]) {
        YTHistoryTile *tile = [[YTHistoryTile alloc] initWithFrame:CGRectZero];

        [_historyStrip addSubview:tile];
        [_tiles addObject:tile];
    }

    for (NSUInteger i = 0; i < [_tiles count]; i++) {
        YTHistoryTile *tile = [_tiles objectAtIndex:i];

        if (i >= [items count]) {
            [tile setHidden:YES];
            continue;
        }

        [tile setHidden:NO];
        [tile bind:[items objectAtIndex:i]];

        // `Margin="0,0,16,0"` между карточками, отступ 16 слева у полосы.
        [tile setFrame:CGRectMake(16 + (YTHistoryCard + 16) * i, 0,
                                  YTHistoryCard, YTHistoryThumb + 57)];
    }

    [_historyStrip setContentSize:
        CGSizeMake(16 + (YTHistoryCard + 16) * [items count],
                   YTHistoryThumb + 57)];

    NSLog(@"[YouTube/Аккаунт] История: записей %lu, карточек %lu",
          (unsigned long)[items count], (unsigned long)[_tiles count]);

    [self loadVisibleThumbsIn:_historyStrip tiles:_tiles];

    [self setNeedsLayout];
}

/**
 * Просит превью у карточек, попавших в видимую часть полосы, плюс одна
 * вперёд и одна назад — чтобы при прокрутке картинка успевала приехать.
 */
- (void)loadVisibleThumbsIn:(UIScrollView *)strip tiles:(NSArray *)tiles {
    CGFloat width = [strip bounds].size.width;

    // Ширины ещё нет — полосу не разложили; подтянем после раскладки.
    if (width <= 0) {
        return;
    }

    CGFloat left = [strip contentOffset].x - YTHistoryCard;
    CGFloat right = [strip contentOffset].x + width + YTHistoryCard;

    for (YTHistoryTile *tile in tiles) {
        if ([tile isHidden]) {
            continue;
        }

        CGRect box = [tile frame];

        if (CGRectGetMaxX(box) >= left && CGRectGetMinX(box) <= right) {
            [tile loadThumbIfNeeded];
        }
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == _page) {
        [_refresh followScroll];
    } else if (scrollView == _historyStrip) {
        [self loadVisibleThumbsIn:_historyStrip tiles:_tiles];
        [self loadMoreHistory];
    } else if (scrollView == _playlistsStrip) {
        [self loadVisibleThumbsIn:_playlistsStrip tiles:_playlistTiles];
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView
                  willDecelerate:(BOOL)decelerate {
    if (scrollView == _page) {
        [_refresh releaseScroll];
    }
}

/**
 * Перечитать страницу по просьбе — то же, что открыть её заново.
 *
 * Отдельного пути для обновления нет намеренно: страница целиком
 * складывается из трёх ответов, и обновлять из них один, оставив прочие
 * от прошлого раза, значило бы держать на экране две разные минуты.
 */
- (void)refreshPage {
    _loaded = NO;

    [self activate];
}

/** Дописывает полосу истории, когда докрутили до её конца. */
- (void)loadMoreHistory {
    if (![_historyPager claimSidewaysOn:_historyStrip]) {
        return;
    }

    NSInteger generation = [_generation current];
    NSString *token = [_historyPager token];

    YTAsync(^{
        NSDictionary *page = [YTApi history:token];

        YTMain(^{
            [_historyPager finish];

            if (![_generation isCurrent:generation]) {
                return;
            }

            NSArray *items = [page objectForKey:@"items"];

            if ([items count] == 0) {
                [_historyPager setToken:nil];
                return;
            }

            [_historyPager setToken:[page objectForKey:@"continuation"]];
            [_historyItems addObjectsFromArray:items];

            [self rebuildHistory:_historyItems];
        });
    });
}

- (void)rebuildPlaylists:(NSArray *)items {
    while ([_playlistTiles count] < [items count]) {
        YTHistoryTile *tile = [[YTHistoryTile alloc] initWithFrame:CGRectZero];

        [_playlistsStrip addSubview:tile];
        [_playlistTiles addObject:tile];
    }

    for (NSUInteger i = 0; i < [_playlistTiles count]; i++) {
        YTHistoryTile *tile = [_playlistTiles objectAtIndex:i];

        if (i >= [items count]) {
            [tile setHidden:YES];
            continue;
        }

        [tile setHidden:NO];
        [tile bind:[items objectAtIndex:i]];

        [tile setFrame:CGRectMake(16 + (YTHistoryCard + 16) * i, 0,
                                  YTHistoryCard, YTHistoryThumb + 57)];
    }

    [_playlistsStrip setContentSize:
        CGSizeMake(16 + (YTHistoryCard + 16) * [items count],
                   YTHistoryThumb + 57)];

    // Пустой раздел не показывается вовсе — как `Visibility="Collapsed"`
    // у пустых полос в оригинале.
    [_playlistsTitle setHidden:[items count] == 0];
    [_playlistsStrip setHidden:[items count] == 0];

    [self loadVisibleThumbsIn:_playlistsStrip tiles:_playlistTiles];

    [self setNeedsLayout];
}

/**
 * Полоса скачанного — из перечня на диске, без единого запроса.
 *
 * Зовётся и при показе вкладки, и по оповещению загрузчика: проценты
 * на карточке недокачанного ролика двигаются сами.
 */
- (void)rebuildDownloads {
    // Одна карточка на ролик: качества спросим при открытии.
    NSArray *items = [YTDownloads videos];

    while ([_downloadTiles count] < [items count]) {
        YTDownloadTile *tile = [[YTDownloadTile alloc] initWithFrame:CGRectZero];

        [_downloadsStrip addSubview:tile];
        [_downloadTiles addObject:tile];
    }

    CGFloat card = [YTDownloadTile cardWidth];
    CGFloat height = [YTDownloadTile cardHeight];

    for (NSUInteger i = 0; i < [_downloadTiles count]; i++) {
        YTDownloadTile *tile = [_downloadTiles objectAtIndex:i];

        if (i >= [items count]) {
            [tile setHidden:YES];
            continue;
        }

        [tile setHidden:NO];
        [tile bind:[items objectAtIndex:i]];

        [tile setFrame:CGRectMake(16 + (card + 16) * i, 0, card, height)];
    }

    [_downloadsStrip setContentSize:
        CGSizeMake(16 + (card + 16) * [items count], height)];

    // Пустой раздел не показывается — как и две полосы выше.
    [_downloadsHeader setHidden:[items count] == 0];
    [_downloadsStrip setHidden:[items count] == 0];

    [self setNeedsLayout];
}

- (void)applyTheme {
    [self setBackgroundColor:[YTTheme background]];
    [_page setBackgroundColor:[YTTheme background]];

    [_searchIcon setImage:YTIcon(@"search")];
    [_settingsIcon setImage:YTIcon(@"pl_settings")];

    [_name setTextColor:[YTTheme primaryText]];
    [_handle setTextColor:[YTTheme secondaryText]];
    [_historyTitle setTextColor:[YTTheme barText]];
    [_playlistsTitle setTextColor:[YTTheme barText]];
    [_downloadsTitle setTextColor:[YTTheme barText]];

    for (YTDownloadTile *tile in _downloadTiles) {
        [tile applyTheme];
    }

    /**
     * Карточки красятся при привязке, но привязка случается один раз,
     * а тему меняют когда угодно. Без этого обхода названия оставались
     * прежнего цвета — в светлой теме белыми на белом.
     */
    for (YTHistoryTile *tile in _tiles) {
        [tile applyTheme];
    }

    for (YTHistoryTile *tile in _playlistTiles) {
        [tile applyTheme];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect box = [self bounds];

    [_page setFrame:box];

    // Значки берутся здесь: раздел переживает смену темы.
    [_searchIcon setImage:YTIcon(@"search")];
    [_settingsIcon setImage:YTIcon(@"pl_settings")];

    // `Padding="0,10,0,24"` у содержимого.
    CGFloat y = 10;

    // Строка сверху: кнопки прижаты вправо, между ними 6.
    CGFloat right = box.size.width - 16;

    [_settingsButton setFrame:CGRectMake(right - 38, y + (YTMeBar - 38) / 2, 38, 38)];
    [_settingsIcon setFrame:CGRectMake(7, 7, 24, 24)];

    [_searchButton setFrame:CGRectMake(right - 38 - 6 - 38, y + (YTMeBar - 38) / 2, 38, 38)];
    [_searchIcon setFrame:CGRectMake(8, 8, 22, 22)];

    y += YTMeBar + 4;

    // Вход занимает вкладку целиком, вместе со строкой лупы и шестерёнки:
    // в оригинале это другая страница, и своей строки у неё нет.
    [_login setFrame:box];

    if ([_avatar isHidden]) {
        return;
    }

    // Профиль: `Margin="16,6,16,16"`.
    y += 6;

    [_avatar setFrame:CGRectMake(16, y, YTMeAvatar, YTMeAvatar)];

    // Накладка выбора канала накрывает кружок вместе с именем.
    [_profileTouch setFrame:CGRectMake(16, y, [self bounds].size.width - 32, YTMeAvatar)];

    CGFloat textLeft = 16 + YTMeAvatar + 12;
    CGFloat textWidth = box.size.width - textLeft - 16;

    CGFloat nameHeight = ceil([[_name font] lineHeight]);
    CGFloat handleHeight = ceil([[_handle font] lineHeight]);
    CGFloat block = nameHeight + 3 + handleHeight;

    [_name setFrame:CGRectMake(textLeft, y + (YTMeAvatar - block) / 2, textWidth, nameHeight)];
    [_handle setFrame:CGRectMake(textLeft, y + (YTMeAvatar - block) / 2 + nameHeight + 3,
                                 textWidth, handleHeight)];

    y += YTMeAvatar + 16;

    // «История»: `Margin="16,0,16,8"`.
    CGFloat headerHeight = ceil([[_historyTitle font] lineHeight]);

    /**
     * Полка шире заголовка: она идёт во всю ширину страницы, от края
     * до края, — так планки разделов и выглядели.
     */
    [_historyShelf setFrame:CGRectMake(0, y - 4, box.size.width, headerHeight + 8)];

    [_historyHeader setFrame:CGRectMake(16, y, box.size.width - 32, headerHeight)];
    [_historyTitle setFrame:CGRectMake(0, 0, box.size.width - 32, headerHeight)];

    y += headerHeight + 8;

    CGFloat stripHeight = YTHistoryThumb + 57;

    [_historyStrip setFrame:CGRectMake(0, y, box.size.width, stripHeight)];

    // `Margin="0,0,0,20"` под полосой.
    y += stripHeight + 20;

    if (![_playlistsTitle isHidden]) {
        [_playlistsShelf setFrame:CGRectMake(0, y - 4, box.size.width, headerHeight + 8)];
        [_playlistsTitle setFrame:CGRectMake(16, y, box.size.width - 32, headerHeight)];

        y += headerHeight + 8;

        [_playlistsStrip setFrame:CGRectMake(0, y, box.size.width, stripHeight)];

        y += stripHeight + 20;
    } else {
        [_playlistsShelf setFrame:CGRectZero];
        [_playlistsTitle setFrame:CGRectZero];
        [_playlistsStrip setFrame:CGRectZero];
    }

    /**
     * «Скачанные» — третьей полосой, под плейлистами.
     *
     * Заголовок здесь не подпись, а кнопка: по нему открывается весь
     * список. Поэтому под ним накладка на всю ширину, как у истории,
     * а не голая надпись, как у плейлистов.
     */
    if (![_downloadsHeader isHidden]) {
        [_downloadsShelf setFrame:CGRectMake(0, y - 4, box.size.width, headerHeight + 8)];
        [_downloadsHeader setFrame:CGRectMake(16, y, box.size.width - 32, headerHeight)];
        [_downloadsTitle setFrame:CGRectMake(0, 0, box.size.width - 32, headerHeight)];

        y += headerHeight + 8;

        CGFloat downHeight = [YTDownloadTile cardHeight];

        [_downloadsStrip setFrame:CGRectMake(0, y, box.size.width, downHeight)];

        y += downHeight + 20;
    } else {
        [_downloadsShelf setFrame:CGRectZero];
        [_downloadsHeader setFrame:CGRectZero];
        [_downloadsStrip setFrame:CGRectZero];
    }

    [_page setContentSize:CGSizeMake(box.size.width, y + 24)];

    /**
     * Раскладка задаёт полосам ширину — только теперь видно, какие
     * карточки на глазах. До неё `loadVisibleThumbsIn:` возвращался ни
     * с чем, и без этого вызова первые превью ждали бы прокрутки.
     */
    [self loadVisibleThumbsIn:_historyStrip tiles:_tiles];
    [self loadVisibleThumbsIn:_playlistsStrip tiles:_playlistTiles];

    // Скачанному это не нужно: его превью лежат на диске и берутся
    // сразу при сборке карточки, без очереди загрузок и без сети.
}

@end
