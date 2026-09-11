#import "YTHomeView.h"

#import "YTStrings.h"

#import "YTApi.h"
#import "YTAuth.h"
#import "YTFeedViews.h"
#import "YTSimpleScreens.h"
#import "YTMetrics.h"
#import "YTSettings.h"
#import "YTTheme.h"
#import "YTUtil.h"
#import "YTVideoItem.h"

@interface YTHomeView () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation YTHomeView {
    UIScrollView *_chipsBar;
    NSMutableArray *_chips;

    UITableView *_table;
    YTStatusView *_status;
    YTRefreshHeader *_refresh;
    YTLoadingRing *_bottomRing;

    /** Ряды карточек: массив массивов YTVideoItem. */
    NSMutableArray *_rows;
    NSMutableArray *_items;

    /**
     * Показывать ли карточки-заглушки вместо ленты.
     *
     * Так же в оригинале: пока лента не пришла, на её месте стоит
     * `SkeletonCardsList` — серые макеты карточек. Если сервер ответил,
     * но роликов не прислал, они просто остаются: своего сообщения
     * на этот случай в UWP-версии нет.
     */
    BOOL _skeleton;

    /**
     * Показывать ли подсказку «поищите видео» вместо ленты.
     *
     * Порт `SuggestionsSection` из Home.xaml: заголовок «Популярные
     * запросы» и восемь готовых запросов, каждый открывает поиск.
     * В оригинале эта секция и занимает место ленты, когда показывать
     * нечего, — невошедшему YouTube нередко не отдаёт ни одного ролика.
     */
    BOOL _suggestions;

    YTPager *_pager;
    YTGeneration *_generation;

    NSArray *_categories;
    NSInteger _selectedCategory;

    /** Набор выбранной таблетки, если она листает ленту, а не поиск. */
    NSString *_categoryParams;

    NSInteger _columns;
    CGFloat _laidOutWidth;

    BOOL _loaded;

    /** От чьего имени набрана нынешняя лента — см. `authChanged`. */
    NSString *_identityMark;

    /** Прятали ли Shorts, когда лента набиралась. */
    BOOL _hidShorts;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    _rows = [NSMutableArray array];
    _items = [NSMutableArray array];
    _chips = [NSMutableArray array];
    _pager = [[YTPager alloc] init];
    _generation = [[YTGeneration alloc] init];
    _columns = 1;
    _selectedCategory = 0;

    [self setBackgroundColor:[YTTheme background]];

    _chipsBar = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [_chipsBar setShowsHorizontalScrollIndicator:NO];
    [_chipsBar setShowsVerticalScrollIndicator:NO];
    [self addSubview:_chipsBar];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    [_table setDataSource:self];
    [_table setDelegate:self];
    [_table setSeparatorStyle:UITableViewCellSeparatorStyleNone];
    [_table setBackgroundColor:[YTTheme background]];
    [self addSubview:_table];

    // Подложку таблицы на iOS 5 задаёт отдельный вид, а не цвет: иначе
    // сквозь неё просвечивает белое.
    [_table setBackgroundView:nil];

    _bottomRing = [[YTLoadingRing alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
    [_bottomRing stop];

    _status = [[YTStatusView alloc] initWithFrame:CGRectZero];
    [self addSubview:_status];

    __weak YTHomeView *weakSelf = self;

    _refresh = [YTRefreshHeader attachedTo:_table action:^{
        [weakSelf reload];
    }];

    // Запоминается до подписки: иначе первое же уведомление сошло бы
    // за смену и перечитало бы только что набранную ленту.
    _identityMark = [[YTApi identityMark] copy];
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

- (void)activate {
    if (_loaded) {
        return;
    }

    _loaded = YES;

    [self loadCategories];
    [self reload];
}

/**
 * Вход, выход и смена канала меняют ленту, но не всякое уведомление
 * означает, что и правда поменялось: его шлёт в том числе загрузка
 * профиля сразу за восстановлением сохранённого входа. Поэтому
 * сверяемся с тем, что было.
 *
 * Сверялись здесь с одним лишь «вошли ли», и на этом лента при смене
 * канала не обновлялась вовсе: вход как был, так и оставался. Примету
 * даёт `identityMark` — она меняется и от смены канала тоже.
 */
- (void)authChanged {
    NSString *now = [YTApi identityMark];

    if ([now isEqualToString:_identityMark]) {
        return;
    }

    _identityMark = [now copy];

    if (_loaded) {
        [self reload];
    }
}

/**
 * Настройки сменились — перечитываем, но только если сменилось то,
 * что влияет на набранное.
 *
 * Уведомление приходит на **любую** настройку, вплоть до частоты кадров
 * и ширины превью, а перечитывание ленты — это запрос на мегабайт.
 * Поэтому сверяемся с прежним значением: отсев Shorts меняет состав
 * ленты, всё остальное — нет.
 *
 * Ответ при этом чаще всего берётся из памяти (ленты живут там две
 * минуты), так что перечитывание выходит почти бесплатным: заново
 * идёт разбор, а он-то нам и нужен.
 */
- (void)settingsChanged {
    BOOL hides = [YTSettings hidesShorts];

    if (hides == _hidShorts) {
        return;
    }

    _hidShorts = hides;

    if (_loaded) {
        [self reload];
    }
}

#pragma mark Категории

- (void)loadCategories {
    // Список свой, а не с сервера — как `GetHomeCategoriesAsync`
    // в оригинале. Ходить за ним никуда не нужно.
    _categories = [YTApi homeCategories];

    [self rebuildChips];
}

- (void)rebuildChips {
    for (UIView *chip in _chips) {
        [chip removeFromSuperview];
    }

    [_chips removeAllObjects];

    __weak YTHomeView *weakSelf = self;

    for (NSUInteger i = 0; i < [_categories count]; i++) {
        NSDictionary *entry = [_categories objectAtIndex:i];

        YTChipView *chip = [[YTChipView alloc] initWithFrame:CGRectZero];

        [chip setTitle:[entry objectForKey:@"title"]];
        [chip setSelected:((NSInteger)i == _selectedCategory)];

        NSInteger index = (NSInteger)i;

        [chip setOnTap:^{ [weakSelf selectCategory:index]; }];

        [_chipsBar addSubview:chip];
        [_chips addObject:chip];
    }

    [self layoutChips];
}

- (void)selectCategory:(NSInteger)index {
    if (index == _selectedCategory) {
        return;
    }

    _selectedCategory = index;

    for (NSUInteger i = 0; i < [_chips count]; i++) {
        [[_chips objectAtIndex:i] setSelected:((NSInteger)i == index)];
    }

    [self reload];
}

- (void)layoutChips {
    // Padding="12,6,12,6" и Margin="0,0,8,0" между таблетками — из Home.xaml.
    CGFloat x = 12;

    for (YTChipView *chip in _chips) {
        CGFloat width = [chip widthForTitle];

        [chip setFrame:CGRectMake(x, 6, width, YTChipHeight)];

        x += width + 8;
    }

    [_chipsBar setContentSize:CGSizeMake(x + 4, YTChipsBarHeight)];
}

#pragma mark Загрузка

- (void)reload {
    NSInteger generation = [_generation next];

    [_pager reset];

    if ([_items count] == 0) {
        // Вместо кольца ожидания — макеты карточек, как в оригинале.
        _skeleton = YES;

        /**
         * Призыв поискать — только для тех, кому ленты не полагается.
         *
         * Он остаётся с прошлой загрузки, и снимался лишь тогда, когда
         * приходила новая лента. А между входом в учётную запись и её
         * приходом — секунды: всё это время под заголовком «Популярные
         * запросы» лежал прежний список запросов, хотя лента уже
         * грузилась. Начинаем заново — значит, и с чистого места.
         */
        _suggestions = NO;

        [_table setTableHeaderView:nil];
        [_status hide];
        [_table reloadData];
    }

    /**
     * Выбранная таблетка — это поиск, а не другая лента.
     *
     * `GetHomeCategoryVideosAsync` в оригинале так и делает: у первой
     * («Все») запроса нет, и тогда показываются рекомендации, у остальных
     * выполняется обычный анонимный поиск по английской строке.
     */
    NSString *query = nil;
    NSString *params = nil;

    if (_selectedCategory > 0 && _selectedCategory < (NSInteger)[_categories count]) {
        NSDictionary *picked = [_categories objectAtIndex:_selectedCategory];

        query = [picked objectForKey:@"query"];
        params = [picked objectForKey:@"params"];
    }

    // Набор запоминаем: продолжение спрашивается у того же источника.
    _categoryParams = [params copy];

    YTAsync(^{
        NSDictionary *feed = [query length] > 0
            ? [YTApi search:query continuation:nil]
            : ([params length] > 0
                ? [YTApi chipFeed:params continuation:nil]
                : [YTApi homeFeedWithParams:nil continuation:nil]);

        YTMain(^{
            if (![_generation isCurrent:generation]) {
                return;
            }

            [_refresh finish];

            NSArray *items = [feed objectForKey:@"items"];

            if ([items count] == 0) {
                /**
                 * Пустой ответ прежде отбрасывался, если в списке уже
                 * что-то лежало: считалось, что это помеха, а набранное
                 * лучше сохранить.
                 *
                 * У смены канала это выходит боком. Свежесозданный канал
                 * ленты не имеет вовсе — сервер отвечает подсказкой
                 * «поищите что-нибудь» и ни одним роликом, — и на экране
                 * оставался список **прежнего** канала. Со стороны это
                 * читается как «переключение не сработало», хотя оно
                 * сработало.
                 *
                 * Поэтому решает не то, есть ли у нас старое, а то, был ли
                 * ответ. Ответ пришёл и пуст — значит, так и есть, и старое
                 * надо убрать: оно чужое. Ответа не было вовсе — это отказ
                 * сети, и вот тогда прежний список остаётся на месте, ему
                 * ничего не противоречит.
                 */
                if (feed == nil && [_items count] > 0) {
                    [self showOffline];

                    return;
                }

                /**
                 * Три разных случая, и путать их нельзя.
                 *
                 * Не вошли — ленты нет и не может быть: в оригинале
                 * `GetRecommendationsPageAsync` при пустом токене сразу
                 * возвращает пустую страницу, рекомендовать некому.
                 * На её месте показывается призыв поискать —
                 * `SuggestionsSection` из Home.xaml.
                 */
                if (![YTAuth isSignedIn]) {
                    _skeleton = NO;
                    _suggestions = YES;

                    [self showSuggestionsHeader];
                    [_table reloadData];

                    return;
                }

                /**
                 * Вошли, но ответа не было вовсе — это отказ сети.
                 * «Нет подключения» при живой сети уводит в сторону надолго,
                 * поэтому решает не пустота списка, а то, дошёл ли ответ.
                 */
                if (feed == nil) {
                    _skeleton = NO;
                    _suggestions = NO;

                    [_table setTableHeaderView:nil];
                    [_table reloadData];
                    [self showOffline];

                    return;
                }

                /**
                 * Вошли, ответ дошёл и пуст — у канала просто нет ленты.
                 *
                 * Так бывает у свежесозданного: рекомендовать ему нечего,
                 * пока он ничего не смотрел и ни на кого не подписан.
                 * Прежде здесь навсегда оставались макеты карточек, будто
                 * лента всё грузится, — а грузиться было нечему.
                 */
                _skeleton = NO;
                _suggestions = NO;

                [_items removeAllObjects];
                [_pager setToken:nil];

                [self rebuildRows];
                [_table setTableHeaderView:nil];
                [_table reloadData];

                [self showEmptyFeed];

                return;
            }

            _skeleton = NO;
            _suggestions = NO;

            [_table setTableHeaderView:nil];
            [_status hide];

            [_items removeAllObjects];
            [_items addObjectsFromArray:items];

            [_pager setToken:[feed objectForKey:@"continuation"]];

            [self rebuildRows];
            [_table reloadData];
            [_table setContentOffset:CGPointZero animated:NO];
        });
    });
}

/**
 * Ленты нет — и это ответ сервера, а не поломка.
 *
 * Слова свои: сервер на этот случай присылает `feedNudgeRenderer`,
 * но лежит в нём подсказка для большого экрана телевизора, со своими
 * кнопками, и вынимать оттуда одну строку значило бы показать половину
 * чужой мысли.
 */
- (void)showEmptyFeed {
    __weak YTHomeView *weakSelf = self;

    [_status showOffline:YTLoc(@"Пока рекомендовать нечего")
                    hint:YTLoc(@"У этого канала ещё нет истории просмотров "
                               @"и подписок — посмотрите что-нибудь, и лента "
                               @"появится")
             actionTitle:YTLoc(@"Обновить")
                  action:^{ [weakSelf reload]; }];
}

- (void)showOffline {
    __weak YTHomeView *weakSelf = self;

    // Тексты и вид — из OfflinePanel в Home.xaml.
    [_status showOffline:YTLoc(@"Нет подключения к интернету")
                    hint:YTLoc(@"Похоже, мы не можем загрузить для вас видео")
             actionTitle:YTLoc(@"Повторить")
                  action:^{ [weakSelf reload]; }];
}

- (void)loadNextPage {
    NSInteger generation = [_generation current];
    NSString *token = [_pager token];

    [_bottomRing start];

    // Продолжение спрашивается у того же источника, что и первая страница:
    // у выбранной таблетки это поиск, у «Всех» — рекомендации.
    // У таблетки с набором продолжение листает ленту, а не поиск.
    BOOL searching = (_selectedCategory > 0 && [_categoryParams length] == 0);
    NSString *params = [_categoryParams copy];

    YTAsync(^{
        NSDictionary *feed = searching
            ? [YTApi search:nil continuation:token]
            : ([params length] > 0
                ? [YTApi chipFeed:params continuation:token]
                : [YTApi homeFeedWithParams:nil continuation:token]);

        YTMain(^{
            [_pager finish];
            [_bottomRing stop];

            if (![_generation isCurrent:generation]) {
                return;
            }

            NSArray *items = [feed objectForKey:@"items"];

            if ([items count] == 0) {
                [_pager setToken:nil];
                return;
            }

            [_pager setToken:[feed objectForKey:@"continuation"]];

            /**
             * Последний ряд мог быть неполным: на планшете в ряду три
             * места, а страница кончается на любом числе роликов.
             * `rebuildRows` дополнит его новыми, но таблица об этом
             * не узнает — она перерисовывает только то, что ей назвали.
             *
             * Оттого в сетке и оставались пропуски: ряд с двумя
             * карточками из трёх так и висел с дыркой, хотя третья
             * давно приехала. Такой ряд перечитываем отдельно.
             */
            NSUInteger before = [_rows count];

            BOOL lastPartial = (before > 0 &&
                [[_rows objectAtIndex:before - 1] count] < (NSUInteger)_columns);

            [_items addObjectsFromArray:items];
            [self rebuildRows];

            NSUInteger firstNewRow = before;

            /**
             * Дописываем вставкой, а не `reloadData`: перезагрузка выбрасывает
             * все ячейки разом и собирает видимые заново, и на iPhone 4 это
             * видно рывком — а подгрузка как раз тем и занимается, что
             * происходит посреди прокрутки.
             */
            NSMutableArray *paths = [NSMutableArray array];

            for (NSUInteger i = firstNewRow; i < [_rows count]; i++) {
                [paths addObject:[NSIndexPath indexPathForRow:i inSection:0]];
            }

            [_table beginUpdates];

            if ([paths count] > 0) {
                [_table insertRowsAtIndexPaths:paths
                              withRowAnimation:UITableViewRowAnimationNone];
            }

            if (lastPartial) {
                [_table reloadRowsAtIndexPaths:[NSArray arrayWithObject:
                    [NSIndexPath indexPathForRow:(before - 1) inSection:0]]
                              withRowAnimation:UITableViewRowAnimationNone];
            }

            [_table endUpdates];
        });
    });
}

/**
 * Раскладывает карточки по рядам под текущее число колонок.
 *
 * Пересобирается заново при смене числа колонок: иначе после поворота
 * планшета ряды по два раскладывались бы по трём местам, и треть каждого
 * пустовала бы.
 */
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

/** Сколько рядов заглушек показать — с запасом на экран. */
- (NSInteger)skeletonRowCount {
    CGFloat height = [YTSkeletonRowCell heightForWidth:[self bounds].size.width
                                               columns:_columns];

    if (height <= 0) {
        return 0;
    }

    return (NSInteger)ceil([self bounds].size.height / height) + 1;
}

/**
 * Готовые запросы — те же восемь, что в `trendingSuggestions` оригинала,
 * и в том же порядке.
 */
+ (NSArray *)trendingQueries {
    static NSArray *queries = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        queries = [[NSArray alloc] initWithObjects:
            YTLoc(@"Музыкальные видео"),
            YTLoc(@"Игровые моменты"),
            YTLoc(@"Кулинарные рецепты"),
            YTLoc(@"Обзоры технологий"),
            YTLoc(@"Трейлеры фильмов"),
            YTLoc(@"Спортивные моменты"),
            YTLoc(@"Комедийные скетчи"),
            YTLoc(@"Сделай сам"),
            nil];
    });

    return queries;
}

/**
 * Заголовок секции — `TextBlock` над `ListView` в разметке, а не строка
 * списка: `Padding="16,8"` у секции, 15 SemiBold, `Margin="0,0,0,12"`.
 *
 * Цвет здесь белый числом, а не кистью темы: в оригинале у него
 * `Foreground="White"`.
 */
- (void)showSuggestionsHeader {
    CGFloat width = [self bounds].size.width;
    CGFloat titleHeight = ceil([YTFontSemiBold(15) lineHeight]);

    UIView *header = [[UIView alloc] initWithFrame:
        CGRectMake(0, 0, width, 8 + titleHeight + 12)];

    [header setBackgroundColor:[YTTheme background]];

    UILabel *title = YTLabel(YTFontSemiBold(15), [UIColor whiteColor], 1);

    [title setText:YTLoc(@"Популярные запросы")];
    [title setFrame:CGRectMake(16, 8, width - 32, titleHeight)];

    [header addSubview:title];

    [_table setTableHeaderView:header];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (_suggestions) {
        return (NSInteger)[[YTHomeView trendingQueries] count];
    }

    return _skeleton ? [self skeletonRowCount] : (NSInteger)[_rows count];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path {
    if (_suggestions) {
        // `MinHeight="48"` у ListViewItem.
        return 48;
    }

    if (_skeleton) {
        return [YTSkeletonRowCell heightForWidth:[self bounds].size.width
                                         columns:_columns];
    }

    NSArray *row = [_rows objectAtIndex:[path row]];

    if ([row count] == 0) {
        return 0;
    }

    CGFloat available = [self bounds].size.width - YTFeedPadding * 2;
    CGFloat cardWidth = floor((available - YTCardSpacing * (_columns - 1)) / _columns);

    CGFloat height = 0;

    for (YTVideoItem *item in row) {
        height = MAX(height, [YTVideoCard heightForWidth:cardWidth item:item]);
    }

    // Между рядами — тот же отступ, что у карточки снизу (`Margin="0,0,0,16"`).
    return height + YTCardSpacing;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)path {
    if (_suggestions) {
        static NSString *suggestionId = @"suggestion";

        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:suggestionId];

        if (cell == nil) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:suggestionId];

            [cell setSelectionStyle:UITableViewCellSelectionStyleNone];

            /**
             * Значок и подпись — свои, а не штатный `textLabel`.
             *
             * Штатную подпись ячейка раскладывает сама, и значок,
             * поставленный рядом, ложится прямо на неё. В разметке это
             * сетка из двух колонок: `FontIcon` шириной по содержимому
             * и текст, а не картинка поверх текста.
             */
            UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectZero];

            [icon setTag:101];
            [icon setContentMode:UIViewContentModeScaleAspectFit];
            [[cell contentView] addSubview:icon];

            UILabel *label = YTLabel(YTFontRegular(14), [YTTheme primaryText], 1);

            [label setTag:102];
            [[cell contentView] addSubview:label];
        }

        [cell setBackgroundColor:[YTTheme background]];
        [[cell contentView] setBackgroundColor:[YTTheme background]];

        CGFloat width = [self bounds].size.width;

        /**
         * Отступы складываются из двух: `Padding="16,8"` у секции
         * и `Padding="12,8"` у самой строки. Значок 16, между ним
         * и текстом `Margin="16,0,0,0"`.
         */
        UIImageView *icon = (UIImageView *)[[cell contentView] viewWithTag:101];

        [icon setImage:YTIcon(@"search")];
        [icon setFrame:CGRectMake(28, (48 - 16) / 2, 16, 16)];

        UILabel *label = (UILabel *)[[cell contentView] viewWithTag:102];

        [label setTextColor:[YTTheme primaryText]];
        [label setText:[[YTHomeView trendingQueries] objectAtIndex:[path row]]];
        [label setFrame:CGRectMake(60, 0, width - 60 - 28, 48)];

        return cell;
    }

    if (_skeleton) {
        static NSString *skeletonId = @"skeleton";

        YTSkeletonRowCell *cell = [tableView dequeueReusableCellWithIdentifier:skeletonId];

        if (cell == nil) {
            cell = [[YTSkeletonRowCell alloc] initWithStyle:UITableViewCellStyleDefault
                                            reuseIdentifier:skeletonId];
        }

        [cell bindColumns:_columns];

        return cell;
    }

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

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    if (!_suggestions) {
        return;
    }

    NSString *query = [[YTHomeView trendingQueries] objectAtIndex:[path row]];

    [YTNav push:[[YTSearchViewController alloc] initWithQuery:query]];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [_refresh followScroll];

    if (!_skeleton && [_pager claimOn:scrollView]) {
        [self loadNextPage];
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    [_refresh releaseScroll];
}

#pragma mark Раскладка

- (void)applyTheme {
    [self setBackgroundColor:[YTTheme background]];
    [_table setBackgroundColor:[YTTheme background]];
    [_chipsBar setBackgroundColor:[YTTheme background]];

    for (YTChipView *chip in _chips) {
        [chip applyState];
    }

    [_table reloadData];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect box = [self bounds];

    [_chipsBar setFrame:CGRectMake(0, 0, box.size.width, YTChipsBarHeight)];

    // Между полосой категорий и лентой — `Margin="0,0,0,8"` у CategoriesHost.
    CGFloat top = YTChipsBarHeight + 8;

    [_table setFrame:CGRectMake(0, top, box.size.width, box.size.height - top)];
    [_status setFrame:CGRectMake(0, top, box.size.width, box.size.height - top)];

    if (_laidOutWidth == box.size.width) {
        return;
    }

    _laidOutWidth = box.size.width;

    NSInteger columns = YTColumnsForWidth(box.size.width - YTFeedPadding * 2);

    if (columns == _columns) {
        /**
         * Ширина изменилась, а число колонок — нет: карточки стали шире,
         * и запомненные таблицей высоты строк перестали соответствовать
         * содержимому. Сама она об этом не узнает — высоту каждой строки
         * `UITableView` спрашивает один раз и заново только при перезагрузке.
         */
        [_table reloadData];
        return;
    }

    _columns = columns;

    [self rebuildRows];
    [_table reloadData];
}

@end
