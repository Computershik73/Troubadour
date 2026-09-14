#import "YTSimpleScreens.h"

#import "YTStrings.h"

#import "YTApi.h"
#import "YTAuth.h"
#import "YTFeedViews.h"
#import "YTImageLoader.h"
#import "YTMetrics.h"
#import "YTRoundedImageView.h"
#import "YTSkin.h"
#import "YTTheme.h"
#import "YTUtil.h"
#import "YTVideoItem.h"

/**
 * Числа — из History.xaml.
 *
 *     содержимое   Padding="16,16,16,20"
 *     заголовок    «История» 28 SemiBold, Margin="0,12,0,16"
 *     день         18 SemiBold, Margin="0,0,0,10"
 *     карточка     превью 160×90, между строками 12; текст с отступом 12:
 *                  название 14 в три строки, автор 12 с отступом 4
 *     плашка       Padding="4,1", CornerRadius="4", 10 SemiBold, поле 5
 */
static const CGFloat YTHiSide = 16;
static const CGFloat YTHiThumbWidth = 160;
static const CGFloat YTHiThumbHeight = 90;
static const CGFloat YTHiGap = 12;
static const CGFloat YTHiRowGap = 12;
static const CGFloat YTHiDayHeight = 18 + 10;


#pragma mark - Карточка

/**
 * Лежачая карточка истории.
 *
 * Отдельная от карточек ленты: там карточка стоячая и во всю ширину,
 * здесь превью слева и текст справа — как в оригинале, где это разные
 * шаблоны, а не один с настройками.
 */
@interface YTHistoryCard : YTTappableView

- (void)bind:(YTVideoItem *)item;
- (void)loadThumbIfNeeded;
- (void)applyTheme;

+ (CGFloat)heightForWidth:(CGFloat)width item:(YTVideoItem *)item;

@end

@implementation YTHistoryCard {
    YTVideoItem *_item;
    NSString *_thumbUrl;
    BOOL _thumbAsked;

    YTRoundedImageView *_thumb;
    YTPillView *_badgePill;
    UILabel *_badge;
    UILabel *_title;
    UILabel *_subtitle;

    /**
     * Полоска просмотра — та же, что на карточках ленты.
     *
     * Здесь она уместнее всего: история — это и есть список того, что
     * начато и брошено, и «докуда досмотрел» тут первый вопрос. А доля
     * приходит в том же ответе, что и сама запись: отдельного запроса
     * не нужно.
     */
    UIView *_watchedTrack;
    UIView *_watchedFill;
    double _watchedShare;
}

/** Ширина колонки с текстом при заданной ширине карточки. */
+ (CGFloat)textWidthFor:(CGFloat)width {
    return width - YTHiThumbWidth - YTHiGap;
}

+ (CGFloat)heightForWidth:(CGFloat)width item:(YTVideoItem *)item {
    CGFloat textWidth = [self textWidthFor:width];

    CGFloat titleHeight = YTTextHeight(item.title, YTFontRegular(14), textWidth, 3);
    CGFloat block = titleHeight + 4 + 15;

    // Превью — нижняя граница высоты: текст короче него не сжимает строку.
    return MAX(YTHiThumbHeight, block);
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    [self setHighlights:NO];

    _thumb = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];
    [_thumb setCornerRadius:YTThumbRadius];
    [self addSubview:_thumb];

    _badgePill = [[YTPillView alloc] initWithFrame:CGRectZero];
    [_badgePill setCornerRadius:4];
    [self addSubview:_badgePill];

    _badge = YTLabel(YTFontSemiBold(10), [UIColor whiteColor], 1);
    [_badge setTextAlignment:NSTextAlignmentCenter];
    [self addSubview:_badge];

    _title = YTLabel(YTFontRegular(14), [YTTheme primaryText], 3);
    [self addSubview:_title];

    _subtitle = YTLabel(YTFontRegular(12), [YTTheme secondaryText], 1);
    [self addSubview:_subtitle];

    _watchedTrack = [[UIView alloc] initWithFrame:CGRectZero];
    [_watchedTrack setUserInteractionEnabled:NO];
    [self addSubview:_watchedTrack];

    _watchedFill = [[UIView alloc] initWithFrame:CGRectZero];
    [_watchedFill setUserInteractionEnabled:NO];
    [self addSubview:_watchedFill];

    __weak YTHistoryCard *weakSelf = self;

    [self setOnTap:^{
        YTHistoryCard *card = weakSelf;

        if (card == nil || card->_item == nil) {
            return;
        }

        [YTNav openVideo:card->_item.videoId title:card->_item.title];
    }];

    return self;
}

- (void)applyTheme {
    [_thumb setPlaceholderColor:[YTTheme surfaceAlt]];
    [_title setTextColor:[YTTheme primaryText]];
    [_subtitle setTextColor:[YTTheme secondaryText]];

    // `Background="#D1000000"` у плашки в History.xaml — плотнее, чем в ленте.
    [_badgePill setFillColor:[UIColor colorWithWhite:0 alpha:0.82]];

    // Цвета полоски — те же, что в ленте: серая дорожка, красная доля.
    [_watchedTrack setBackgroundColor:[UIColor colorWithWhite:1 alpha:0.28]];
    [_watchedFill setBackgroundColor:YTColor(0xFF0000)];
}

- (void)bind:(YTVideoItem *)item {
    _item = item;

    [self applyTheme];

    [_title setText:item.title];
    [_subtitle setText:item.channelTitle];

    [_badge setText:item.duration];

    BOOL hasDuration = [item.duration length] > 0;

    [_badge setHidden:!hasDuration];
    [_badgePill setHidden:!hasDuration];

    /**
     * Доля просмотра: у эфиров и подборок её не бывает, и полоска там
     * читалась бы как «досмотрено до половины» у того, что не смотрят.
     */
    _watchedShare = (item.isLive || [item.playlistId length] > 0)
        ? 0 : MAX(0.0, item.watchedShare);

    [_watchedTrack setHidden:(_watchedShare <= 0)];
    [_watchedFill setHidden:(_watchedShare <= 0)];

    /**
     * Превью только запоминается: история приходит страницами по полтора
     * десятка, но их накапливается сотня, и брать картинку сразу для всех
     * — та же беда, что была на подписках. Берёт их полоса видимого,
     * когда карточка доедет до экрана.
     */
    _thumbUrl = [item.thumbnail copy];
    _thumbAsked = NO;

    [_thumb setImage:nil];

    [self setNeedsLayout];
}

- (void)loadThumbIfNeeded {
    if (_thumbAsked || [_thumbUrl length] == 0) {
        return;
    }

    _thumbAsked = YES;

    [YTImageLoader loadInto:_thumb url:_thumbUrl targetWidth:YTHiThumbWidth];
}

- (void)layoutSubviews {
    CGFloat width = [self bounds].size.width;

    [_thumb setFrame:CGRectMake(0, 0, YTHiThumbWidth, YTHiThumbHeight)];

    // Плашка в правом нижнем углу превью: `Margin="0,0,5,5"`, `Padding="4,1"`.
    CGSize text = [[_badge text] sizeWithFont:[_badge font]];

    CGFloat badgeWidth = ceil(text.width) + 8;
    CGFloat badgeHeight = ceil(text.height) + 2;

    CGRect badge = CGRectMake(YTHiThumbWidth - badgeWidth - 5,
                              YTHiThumbHeight - badgeHeight - 5,
                              badgeWidth, badgeHeight);

    [_badgePill setFrame:badge];
    [_badge setFrame:badge];

    // Полоска — по нижнему краю превью, в четыре точки, как в ленте.
    if (![_watchedTrack isHidden]) {
        CGFloat bar = 4;
        CGFloat top = YTHiThumbHeight - bar;

        [_watchedTrack setFrame:CGRectMake(0, top, YTHiThumbWidth, bar)];
        [_watchedFill setFrame:CGRectMake(0, top,
            (CGFloat)(YTHiThumbWidth * _watchedShare), bar)];
    }

    CGFloat left = YTHiThumbWidth + YTHiGap;
    CGFloat textWidth = width - left;

    CGFloat titleHeight = YTTextHeight([_title text], [_title font], textWidth, 3);

    [_title setFrame:CGRectMake(left, 0, textWidth, titleHeight)];
    [_subtitle setFrame:CGRectMake(left, titleHeight + 4, textWidth, 15)];
}

@end


#pragma mark - Экран

@interface YTHistoryViewController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation YTHistoryViewController {
    UIView *_bar;
    UIButton *_back;
    UILabel *_barTitle;

    UITableView *_table;
    YTStatusView *_status;

    /**
     * Строки списка: словарь либо с `day` (заголовок дня), либо с `item`
     * (ролик). Плоским списком, а не разделами таблицы: разделы у неё
     * прилипают к верху при прокрутке, а в оригинале заголовок дня уезжает
     * вместе с содержимым.
     */
    NSMutableArray *_rows;

    /** Уже показанные ролики — чтобы страницы не наслаивались. */
    NSMutableSet *_seen;

    /** Заголовки дней, которые уже есть в списке, и их место в нём. */
    NSMutableDictionary *_days;

    YTPager *_pager;
    YTGeneration *_generation;

    CGFloat _laidOutWidth;
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

    _rows = [NSMutableArray array];
    _seen = [NSMutableSet set];
    _days = [NSMutableDictionary dictionary];
    _pager = [[YTPager alloc] init];
    _generation = [[YTGeneration alloc] init];

    [[self view] setBackgroundColor:[YTTheme background]];

    _bar = [[UIView alloc] initWithFrame:CGRectZero];
    [YTSkin paintBar:_bar];
    [[self view] addSubview:_bar];

    _back = [UIButton buttonWithType:UIButtonTypeCustom];
    [[_back titleLabel] setFont:YTFontRegular(24)];
    [_back setTitle:@"‹" forState:UIControlStateNormal];
    [_back setTitleColor:[YTTheme primaryText] forState:UIControlStateNormal];
    [_back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_back];

    _barTitle = YTLabel(YTFontSemiBold(17), [YTTheme primaryText], 1);
    [_barTitle setText:YTLoc(@"История")];
    [_bar addSubview:_barTitle];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    [_table setDataSource:self];
    [_table setDelegate:self];
    [_table setSeparatorStyle:UITableViewCellSeparatorStyleNone];
    [_table setBackgroundColor:[YTTheme background]];
    [_table setBackgroundView:nil];
    [[self view] addSubview:_table];

    _status = [[YTStatusView alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_status];

    [self load];
}

- (void)goBack {
    [YTNav pop];
}

- (void)load {
    /**
     * Без входа истории нет вовсе — и спрашивать её не у кого. В оригинале
     * на этот случай своя строка («HistorySignIn»), а не общая ошибка сети.
     */
    if (![YTAuth isSignedIn]) {
        [_status showMessage:YTLoc(@"Войдите в аккаунт, чтобы видеть историю")];

        return;
    }

    NSInteger generation = [_generation next];

    [_pager reset];
    [_rows removeAllObjects];
    [_seen removeAllObjects];
    [_days removeAllObjects];
    [_table reloadData];
    [_status showBusy];

    YTAsync(^{
        NSDictionary *page = [YTApi historyPage:nil];

        YTMain(^{
            if (![_generation isCurrent:generation]) {
                return;
            }

            if (page == nil) {
                [_status showOffline:YTLoc(@"История не открылась")
                                hint:YTLoc(@"Проверьте подключение и попробуйте снова")
                         actionTitle:YTLoc(@"Повторить")
                              action:^{
                    [self load];
                }];

                return;
            }

            [self appendGroups:[page objectForKey:@"groups"]];
            [_pager setToken:[page objectForKey:@"continuation"]];

            if ([_rows count] == 0) {
                [_status showMessage:YTLoc(@"Смотреть пока нечего")];
            } else {
                [_status hide];
            }

            [_table reloadData];
            [self loadVisibleThumbs];
        });
    });
}

/**
 * Дописывает страницу к списку.
 *
 * День, который уже есть, не заводится заново: следующая страница нередко
 * продолжает вчерашний день, и без этого «Вчера» стояло бы в списке дважды.
 * Ролики, уже показанные, пропускаются — сервер повторяет их на стыке
 * страниц.
 */
- (void)appendGroups:(NSArray *)groups {
    for (NSDictionary *group in groups) {
        NSString *day = [group objectForKey:@"title"];
        NSArray *items = [group objectForKey:@"items"];

        NSMutableArray *fresh = [NSMutableArray array];

        for (YTVideoItem *item in items) {
            NSString *key = [item.videoId length] > 0 ? item.videoId : item.title;

            if ([key length] == 0 || [_seen containsObject:key]) {
                continue;
            }

            [_seen addObject:key];
            [fresh addObject:item];
        }

        if ([fresh count] == 0) {
            continue;
        }

        NSUInteger place = [_rows count];

        if ([day length] > 0 && [_days objectForKey:day] == nil) {
            [_days setObject:[NSNumber numberWithUnsignedInteger:place] forKey:day];
            [_rows addObject:[NSDictionary dictionaryWithObject:day forKey:@"day"]];
        }

        for (YTVideoItem *item in fresh) {
            [_rows addObject:[NSDictionary dictionaryWithObject:item forKey:@"item"]];
        }
    }
}

#pragma mark Таблица

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[_rows count];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path {
    NSDictionary *row = [_rows objectAtIndex:[path row]];

    if ([row objectForKey:@"day"] != nil) {
        return YTHiDayHeight;
    }

    CGFloat width = [[self view] bounds].size.width - YTHiSide * 2;

    return [YTHistoryCard heightForWidth:width
                                    item:[row objectForKey:@"item"]] + YTHiRowGap;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)path {
    NSDictionary *row = [_rows objectAtIndex:[path row]];
    NSString *day = [row objectForKey:@"day"];

    CGFloat width = [[self view] bounds].size.width - YTHiSide * 2;

    if (day != nil) {
        static NSString *dayIdentifier = @"day";

        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:dayIdentifier];

        if (cell == nil) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:dayIdentifier];

            [cell setSelectionStyle:UITableViewCellSelectionStyleNone];

            UILabel *label = YTLabel(YTFontSemiBold(18), [YTTheme primaryText], 1);

            [label setTag:1];
            [[cell contentView] addSubview:label];
        }

        UILabel *label = (UILabel *)[[cell contentView] viewWithTag:1];

        [cell setBackgroundColor:[YTTheme background]];
        [label setTextColor:[YTTheme primaryText]];
        [label setText:day];
        [label setFrame:CGRectMake(YTHiSide, 0, width, 22)];

        return cell;
    }

    static NSString *identifier = @"card";

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    YTHistoryCard *card = nil;

    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:identifier];

        [cell setSelectionStyle:UITableViewCellSelectionStyleNone];

        card = [[YTHistoryCard alloc] initWithFrame:CGRectZero];

        [card setTag:1];
        [[cell contentView] addSubview:card];
    } else {
        card = (YTHistoryCard *)[[cell contentView] viewWithTag:1];
    }

    YTVideoItem *item = [row objectForKey:@"item"];

    [cell setBackgroundColor:[YTTheme background]];
    [card bind:item];
    [card setFrame:CGRectMake(YTHiSide, 0, width,
                              [YTHistoryCard heightForWidth:width item:item])];

    return cell;
}

#pragma mark Прокрутка

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self loadVisibleThumbs];

    if (![_pager claimOn:scrollView]) {
        return;
    }

    NSInteger generation = [_generation current];
    NSString *token = [_pager token];

    YTAsync(^{
        NSDictionary *page = [YTApi historyPage:token];

        YTMain(^{
            [_pager finish];

            if (![_generation isCurrent:generation]) {
                return;
            }

            NSArray *groups = [page objectForKey:@"groups"];

            if ([groups count] == 0) {
                [_pager setToken:nil];
                return;
            }

            NSUInteger before = [_rows count];

            [self appendGroups:groups];
            [_pager setToken:[page objectForKey:@"continuation"]];

            // Страница пришла, а нового в ней нет — дальше идти некуда.
            if ([_rows count] == before) {
                [_pager setToken:nil];
                return;
            }

            [_table reloadData];
            [self loadVisibleThumbs];
        });
    });
}

/** Просит превью у карточек, попавших на экран. */
- (void)loadVisibleThumbs {
    for (UITableViewCell *cell in [_table visibleCells]) {
        YTHistoryCard *card = (YTHistoryCard *)[[cell contentView] viewWithTag:1];

        if ([card isKindOfClass:[YTHistoryCard class]]) {
            [card loadThumbIfNeeded];
        }
    }
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
    [_status setFrame:[_table frame]];

    if (_laidOutWidth != box.size.width) {
        _laidOutWidth = box.size.width;

        [_table reloadData];
    }

    // После раскладки видно, какие карточки на экране: до неё у таблицы
    // ещё нет размера, и спрашивать превью было бы не у кого.
    [self loadVisibleThumbs];
}

@end
