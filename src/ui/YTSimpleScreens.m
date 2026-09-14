#import "YTSimpleScreens.h"

#import "YTStrings.h"

#import <objc/runtime.h>

#import "YTApi.h"
#import "YTFeedViews.h"
#import "YTImageLoader.h"
#import "YTMetrics.h"
#import "YTRoundedImageView.h"
#import "YTSettings.h"
#import "YTSkin.h"
#import "YTTheme.h"
#import "YTUtil.h"
#import "YTVideoItem.h"

#pragma mark - Заглушка раздела

@implementation YTStubSectionView {
    UILabel *_label;
}

- (id)initWithFrame:(CGRect)frame title:(NSString *)title {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    [self setBackgroundColor:[YTTheme background]];

    _label = YTLabel(YTFontRegular(15), [YTTheme mutedText], 0);
    [_label setTextAlignment:NSTextAlignmentCenter];
    [_label setText:title];
    [self addSubview:_label];

    return self;
}

- (id)initWithFrame:(CGRect)frame {
    return [self initWithFrame:frame title:YTLoc(@"Раздел ещё не перенесён")];
}

- (void)activate {
}

- (void)applyTheme {
    [self setBackgroundColor:[YTTheme background]];
    [_label setTextColor:[YTTheme mutedText]];
}

- (void)layoutSubviews {
    CGRect box = [self bounds];

    [_label setFrame:CGRectMake(24, box.size.height / 2 - 40, box.size.width - 48, 80)];
}

@end


#pragma mark - Поиск

/**
 * Нужно ли двигать строку в поле ввода самим.
 *
 * До iOS 7 штатное поле без рамки прижимает текст к верхнему краю —
 * на iPhone 5 с iOS 6 строка почти касается верха подложки. С iOS 7
 * система ставит её по центру сама, и вмешиваться незачем.
 */
static BOOL YTFieldNeedsCentring(void) {
    static BOOL needs = NO;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        needs = ([[[UIDevice currentDevice] systemVersion] floatValue] < 7.0);
    });

    return needs;
}

/**
 * Поле ввода, которое само держит строку посередине на старых системах.
 *
 * Настройкой `contentVerticalAlignment` там не помочь: поле считает высоту
 * строки по метрикам шрифта, а Roboto у нас свой, испечённый, и его метрики
 * системному расчёту не по нраву. Поэтому место строки задаём сами: берём
 * предложенное системой (в нём уже учтён отступ слева) и двигаем по середине
 * высоты поля.
 *
 * Делать это **везде** оказалось нельзя. Вместе с местом мы задавали и
 * высоту — ровно в одну строку по метрикам шрифта, — а на iOS 9 и новее
 * этого мало: система рисует текст в отведённом прямоугольнике и всё,
 * что не поместилось, обрезает. Обрезалось целиком: поле выглядело пустым
 * и при наборе, и с подсказкой, будто текст слился с подложкой.
 */
@implementation YTTextField

- (CGRect)centered:(CGRect)rect {
    if (!YTFieldNeedsCentring()) {
        return rect;
    }

    CGFloat line = ceil([[self font] lineHeight]);
    CGFloat height = [self bounds].size.height;

    if (line <= 0 || line >= height) {
        return rect;
    }

    rect.origin.y = floor((height - line) / 2);
    rect.size.height = line;

    return rect;
}

- (CGRect)textRectForBounds:(CGRect)bounds {
    return [self centered:[super textRectForBounds:bounds]];
}

- (CGRect)editingRectForBounds:(CGRect)bounds {
    return [self centered:[super editingRectForBounds:bounds]];
}

- (CGRect)placeholderRectForBounds:(CGRect)bounds {
    return [self centered:[super placeholderRectForBounds:bounds]];
}

/**
 * Приглашение рисуется своими руками — ради цвета.
 *
 * Это единственный способ, одинаковый на всех наших системах:
 * `attributedPlaceholder` есть только с iOS 6, а на 5.1 нужный ему
 * `NSForegroundColorAttributeName` — слабый символ, и обращение к нему
 * валит приложение при запуске, а не при показе поля.
 *
 * Прямоугольник приходит уже готовый — из `placeholderRectForBounds:`,
 * то есть с нашим же выравниванием по середине.
 */
- (void)drawPlaceholderInRect:(CGRect)rect {
    NSString *text = [self placeholder];

    if ([text length] == 0) {
        return;
    }

    if (_placeholderColor == nil) {
        [super drawPlaceholderInRect:rect];

        return;
    }

    UIFont *font = [self font] ?: [UIFont systemFontOfSize:14];

    [_placeholderColor set];

    CGSize size = [text sizeWithFont:font];

    // По середине прямоугольника: до iOS 7 он выше строки.
    CGFloat y = rect.origin.y + floor((rect.size.height - size.height) / 2);

    if (y < rect.origin.y) {
        y = rect.origin.y;
    }

    [text drawInRect:CGRectMake(rect.origin.x, y, rect.size.width, size.height)
            withFont:font
       lineBreakMode:NSLineBreakByTruncatingTail];
}

@end


@interface YTSearchViewController () <UITableViewDataSource, UITableViewDelegate,
                                      UITextFieldDelegate>
@end

@implementation YTSearchViewController {
    UIView *_bar;
    UIButton *_back;
    UITextField *_field;

    UITableView *_table;
    YTStatusView *_status;

    NSMutableArray *_items;
    NSMutableArray *_rows;

    YTPager *_pager;
    YTGeneration *_generation;

    NSString *_query;
    NSString *_initialQuery;
    NSInteger _columns;
    CGFloat _laidOutWidth;

    /**
     * Страница подсказок — порт `Searching.xaml`.
     *
     * Пока строка ввода в работе, вместо выдачи показывается список:
     * пустая строка — история запросов, набранная — подсказки Google.
     * Оба списка одинаковы по устройству, разнятся значком слева
     * и наличием крестика справа.
     */
    UITableView *_hints;
    NSMutableArray *_suggestions;
    NSMutableArray *_history;
    BOOL _suggesting;

    /** Полоса фильтров: видео, Shorts, каналы, подборки. */
    UIScrollView *_chipsBar;
    NSMutableArray *_chips;
    YTSearchKind _kind;

    YTGeneration *_hintGeneration;

    /** Показывались ли уже: клавиатура полагается только первому разу. */
    BOOL _appearedOnce;
}

/** Имя настройки и предел — те же, что в оригинале. */
static NSString *const YTSearchHistoryKey = @"YTSearchHistory";
static const NSUInteger YTSearchHistoryLimit = 200;

- (id)initWithQuery:(NSString *)query {
    self = [super init];

    if (self != nil) {
        _initialQuery = [query copy];
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
    [YTSkin paintBar:_bar];
    [[self view] addSubview:_bar];

    _back = [UIButton buttonWithType:UIButtonTypeCustom];
    [[_back titleLabel] setFont:YTFontRegular(24)];
    [_back setTitle:@"‹" forState:UIControlStateNormal];
    [_back setTitleColor:[YTTheme barText] forState:UIControlStateNormal];
    [_back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_back];

    /**
     * Поле ввода на подложке `AppDividerBrush` со скруглением 5 —
     * так оно выглядит в горизонтальной раскладке Navbar.xaml.
     */
    _field = [[YTTextField alloc] initWithFrame:CGRectZero];

    [_field setFont:YTFontRegular(14)];
    [_field setReturnKeyType:UIReturnKeySearch];
    [_field setDelegate:self];
    [_field setBorderStyle:UITextBorderStyleNone];
    [_field setAutocorrectionType:UITextAutocorrectionTypeNo];
    [[_field layer] setCornerRadius:5];

    // Текст вплотную к краю подложки читается плохо — отступ, как
    // `Padding="12,0"` у поля в оригинале.
    UIView *pad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];

    [_field setLeftView:pad];
    [_field setLeftViewMode:UITextFieldViewModeAlways];

    [self paintField];

    [_bar addSubview:_field];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    [_table setDataSource:self];
    [_table setDelegate:self];
    [_table setSeparatorStyle:UITableViewCellSeparatorStyleNone];
    [_table setBackgroundColor:[YTTheme background]];
    [_table setBackgroundView:nil];
    [[self view] addSubview:_table];

    /**
     * Полоса фильтров. В оригинале это `SearchContentType` — четыре
     * вида искомого; переключение перезапрашивает выдачу с другой
     * пометкой `params`.
     */
    _chips = [NSMutableArray array];
    _chipsBar = [[UIScrollView alloc] initWithFrame:CGRectZero];

    [_chipsBar setShowsHorizontalScrollIndicator:NO];
    [[self view] addSubview:_chipsBar];

    NSArray *names = [NSArray arrayWithObjects:
        YTLoc(@"Видео"), @"Shorts", YTLoc(@"Каналы"), YTLoc(@"Плейлисты"), nil];

    for (NSUInteger i = 0; i < [names count]; i++) {
        /**
         * Таблетка Shorts не заводится вовсе, если их прячут.
         *
         * Прячется, а не отключается: номер таблетки — это `YTSearchKind`,
         * и пропуск здесь сдвинул бы нумерацию у следующих. Поэтому вместо
         * пропуска кладём в массив пустое место — тогда `pickKind:` и отбор
         * по номеру остаются верными без единой поправки.
         */
        if (i == (NSUInteger)YTSearchShorts && [YTSettings hidesShorts]) {
            [_chips addObject:[NSNull null]];

            continue;
        }

        YTChipView *chip = [[YTChipView alloc] initWithFrame:CGRectZero];

        [chip setTitle:[names objectAtIndex:i]];

        __weak YTSearchViewController *weakSelf = self;
        NSInteger index = (NSInteger)i;

        [chip setOnTap:^{ [weakSelf pickKind:index]; }];

        // Первая таблетка — «Видео»: она же и есть выбор по умолчанию.
        [chip setSelected:(i == 0)];
        [chip applyState];

        [_chipsBar addSubview:chip];
        [_chips addObject:chip];
    }

    /** Список подсказок и истории поверх выдачи. */
    _suggestions = [NSMutableArray array];
    _history = [NSMutableArray array];
    _hintGeneration = [[YTGeneration alloc] init];

    _hints = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];

    [_hints setDataSource:self];
    [_hints setDelegate:self];
    [_hints setSeparatorStyle:UITableViewCellSeparatorStyleNone];
    [_hints setBackgroundColor:[YTTheme background]];
    [_hints setBackgroundView:nil];
    [_hints setHidden:YES];
    [[self view] addSubview:_hints];

    [self loadHistory];

    _status = [[YTStatusView alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_status];

    if ([_initialQuery length] > 0) {
        [_field setText:_initialQuery];

        _query = [_initialQuery copy];

        [self runSearch];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    /**
     * Клавиатура — только при первом появлении экрана.
     *
     * `viewDidAppear:` зовётся и на возврате: посмотрел ролик, нажал
     * «назад» — и экран появляется снова. Клавиатура при этом вылезала
     * сама, а вместе с ней открывался список подсказок, который прячет
     * выдачу. Со стороны это выглядело так, будто возврат стирает
     * найденное: карточки исчезали, хотя никуда не девались.
     *
     * Показать клавиатуру стоит один раз — тому, кто пришёл сюда набирать.
     * Вернувшемуся нужна выдача, а не ввод.
     */
    if (_appearedOnce) {
        return;
    }

    _appearedOnce = YES;

    // С готовым запросом клавиатура не нужна: результаты уже грузятся.
    if ([_initialQuery length] == 0) {
        [_field becomeFirstResponder];
    }
}

- (void)goBack {
    [_field resignFirstResponder];
    [YTNav pop];
}

/**
 * Красит поле ввода по теме — и текст, и подсказку.
 *
 * Подсказку приходится задавать самим. Свой цвет система выбирает под
 * светлое оформление, а приложение собрано старым набором средств и
 * тёмной темы для системы как бы не имеет: на iOS 13 и новее серое
 * слово «Поиск» оказывалось серым на тёмно-сером, и разглядеть его было
 * почти нельзя. Наш цвет для второстепенных надписей на обеих темах
 * читается ровно.
 */
- (void)paintField {
    [_field setTextColor:[YTTheme primaryText]];
    [_field setBackgroundColor:[YTTheme divider]];

    NSString *hint = YTLoc(@"Поиск");

    /**
     * Цветную подсказку понимают с iOS 6. На пятой остаётся обычная —
     * там и тёмной темы у системы нет, а наша светлая ей не помеха.
     */
    if (![_field respondsToSelector:@selector(setAttributedPlaceholder:)]) {
        [_field setPlaceholder:hint];

        return;
    }

    NSDictionary *look = [NSDictionary dictionaryWithObject:[YTTheme secondaryText]
                                                     forKey:NSForegroundColorAttributeName];

    [_field setAttributedPlaceholder:
        [[NSAttributedString alloc] initWithString:hint attributes:look]];
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    [field resignFirstResponder];

    _query = [[field text] copy];

    [self rememberQuery:_query];
    [self showHints:NO];
    [self runSearch];

    return YES;
}

- (void)textFieldDidBeginEditing:(UITextField *)field {
    [self showHints:YES];
    [self refreshHints];
}

- (BOOL)textField:(UITextField *)field
        shouldChangeCharactersInRange:(NSRange)range
        replacementString:(NSString *)string {
    // Подсказки просим по тому, что будет в поле **после** правки:
    // само поле обновится уже после нашего ответа.
    NSString *text = [[field text] stringByReplacingCharactersInRange:range
                                                           withString:string];

    [self showHints:YES];
    [self askSuggestions:text];

    return YES;
}

#pragma mark Подсказки и история

- (void)showHints:(BOOL)show {
    _suggesting = show;

    [_hints setHidden:!show];
    [_table setHidden:show];
    [_chipsBar setHidden:show || [_query length] == 0];

    if (show) {
        [_status hide];
    }

    [[self view] setNeedsLayout];
}

/** Пустое поле — история, набранное — подсказки. */
- (void)refreshHints {
    if ([[_field text] length] == 0) {
        [_suggestions removeAllObjects];
        [_hints reloadData];

        return;
    }

    [self askSuggestions:[_field text]];
}

- (void)askSuggestions:(NSString *)text {
    if ([text length] == 0) {
        [_suggestions removeAllObjects];
        [_hints reloadData];

        return;
    }

    NSInteger generation = [_hintGeneration next];

    YTAsync(^{
        NSArray *found = [YTApi searchSuggestions:text];

        YTMain(^{
            if (![_hintGeneration isCurrent:generation]) {
                return;
            }

            [_suggestions removeAllObjects];
            [_suggestions addObjectsFromArray:found];

            [_hints reloadData];
        });
    });
}

- (void)loadHistory {
    NSArray *saved = [[NSUserDefaults standardUserDefaults]
        arrayForKey:YTSearchHistoryKey];

    [_history removeAllObjects];

    if (saved != nil) {
        [_history addObjectsFromArray:saved];
    }
}

- (void)saveHistory {
    [[NSUserDefaults standardUserDefaults] setObject:_history
                                              forKey:YTSearchHistoryKey];
}

/** Запрос уходит в начало списка; повтор не задваивается. */
- (void)rememberQuery:(NSString *)text {
    if ([text length] == 0) {
        return;
    }

    [_history removeObject:text];
    [_history insertObject:text atIndex:0];

    while ([_history count] > YTSearchHistoryLimit) {
        [_history removeLastObject];
    }

    [self saveHistory];
}

- (void)forgetQueryAt:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)[_history count]) {
        return;
    }

    [_history removeObjectAtIndex:(NSUInteger)index];

    [self saveHistory];
    [_hints reloadData];
}

- (void)pickKind:(NSInteger)kind {
    if (_kind == (YTSearchKind)kind) {
        return;
    }

    _kind = (YTSearchKind)kind;

    for (NSUInteger i = 0; i < [_chips count]; i++) {
        id chip = [_chips objectAtIndex:i];

        // Пустое место осталось от спрятанной таблетки Shorts.
        if (chip == [NSNull null]) {
            continue;
        }

        [chip setSelected:((NSInteger)i == kind)];
        [chip applyState];
    }

    // Число карточек в ряду у разных выдач своё — пересчитываем.
    [self applyColumns];

    [self runSearch];
}

- (void)runSearch {
    if ([_query length] == 0) {
        return;
    }

    NSInteger generation = [_generation next];

    [_pager reset];
    [_status showBusy];

    NSString *query = _query;
    YTSearchKind kind = _kind;

    YTAsync(^{
        NSDictionary *found = [YTApi search:query continuation:nil kind:kind];

        YTMain(^{
            if (![_generation isCurrent:generation]) {
                return;
            }

            NSArray *items = [found objectForKey:@"items"];

            [_items removeAllObjects];
            [_items addObjectsFromArray:items];

            [_pager setToken:[found objectForKey:@"continuation"]];

            if ([_items count] == 0) {
                [_status showMessage:YTLoc(@"Ничего не нашлось")];
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

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView == _hints) {
        return [self hintCount];
    }

    return [_rows count];
}

/** Что показываем в списке подсказок: историю либо ответ сервера. */
- (BOOL)showingHistory {
    return [[_field text] length] == 0;
}

- (NSInteger)hintCount {
    return [self showingHistory] ? (NSInteger)[_history count]
                                 : (NSInteger)[_suggestions count];
}

- (NSString *)hintAt:(NSInteger)index {
    NSArray *source = [self showingHistory] ? _history : _suggestions;

    if (index < 0 || index >= (NSInteger)[source count]) {
        return nil;
    }

    return [source objectAtIndex:(NSUInteger)index];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path {
    // `MinHeight="52"` у строки в `Searching.xaml`.
    if (tableView == _hints) {
        return 52;
    }

    // Строка канала своей высоты: кружок 56 с полями.
    if (_kind == YTSearchChannels) {
        return 76;
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

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)path {
    if (tableView == _hints) {
        return [self hintCellFor:tableView at:[path row]];
    }

    if (_kind == YTSearchChannels) {
        return [self channelCellFor:tableView at:[path row]];
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

/**
 * Строка канала в выдаче: кружок 56, имя, собачка и подписчики.
 *
 * Плиткой канал не показать — у него нет ни превью, ни длительности,
 * а нужны кружок и число подписчиков. Поэтому во вкладке «Каналы»
 * строки свои, по одной на канал.
 */
- (UITableViewCell *)channelCellFor:(UITableView *)tableView at:(NSInteger)index {
    static NSString *identifier = @"channel";

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];

    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:identifier];

        [cell setSelectionStyle:UITableViewCellSelectionStyleNone];
        [cell setBackgroundColor:[UIColor clearColor]];

        YTRoundedImageView *avatar =
            [[YTRoundedImageView alloc] initWithFrame:CGRectMake(YTFeedPadding, 10, 56, 56)];

        [avatar setCircular:YES];
        [avatar setTag:1];
        [[cell contentView] addSubview:avatar];

        UILabel *name = YTLabel(YTFontMedium(15), [YTTheme primaryText], 1);

        [name setTag:2];
        [[cell contentView] addSubview:name];

        UILabel *meta = YTLabel(YTFontRegular(12), [YTTheme mutedText], 1);

        [meta setTag:3];
        [[cell contentView] addSubview:meta];
    }

    NSArray *row = [_rows objectAtIndex:(NSUInteger)index];
    YTVideoItem *item = [row count] > 0 ? [row objectAtIndex:0] : nil;

    YTRoundedImageView *avatar = (YTRoundedImageView *)[[cell contentView] viewWithTag:1];
    UILabel *name = (UILabel *)[[cell contentView] viewWithTag:2];
    UILabel *meta = (UILabel *)[[cell contentView] viewWithTag:3];

    [avatar setPlaceholderColor:[YTTheme avatarPlaceholder]];
    [name setTextColor:[YTTheme primaryText]];
    [meta setTextColor:[YTTheme mutedText]];

    [name setText:item.title];

    // «@собачка • 763 тыс. подписчиков» — как в выдаче оригинала.
    NSMutableArray *parts = [NSMutableArray array];

    if ([item.channelTitle length] > 0) { [parts addObject:item.channelTitle]; }
    if ([item.viewCount length] > 0)    { [parts addObject:item.viewCount]; }

    [meta setText:[parts componentsJoinedByString:@" • "]];

    [YTImageLoader loadInto:avatar url:item.thumbnail targetWidth:56];

    CGFloat left = YTFeedPadding + 56 + 12;
    CGFloat width = [[self view] bounds].size.width - left - YTFeedPadding;

    [name setFrame:CGRectMake(left, 22, width, 18)];
    [meta setFrame:CGRectMake(left, 42, width, 16)];

    return cell;
}

/**
 * Строка списка подсказок — порт шаблона из `Searching.xaml`:
 * колонка 56 под значок 20×20, дальше подпись 14, а у истории справа
 * ещё крестик 48×48.
 */
- (UITableViewCell *)hintCellFor:(UITableView *)tableView at:(NSInteger)index {
    static NSString *identifier = @"hint";

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];

    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:identifier];

        [cell setSelectionStyle:UITableViewCellSelectionStyleNone];

        UIImageView *glyph = [[UIImageView alloc] initWithFrame:CGRectMake(18, 16, 20, 20)];

        [glyph setContentMode:UIViewContentModeScaleAspectFit];
        [glyph setTag:1];
        [[cell contentView] addSubview:glyph];

        UILabel *text = YTLabel(YTFontRegular(14), [YTTheme primaryText], 1);

        [text setTag:2];
        [[cell contentView] addSubview:text];

        UIButton *remove = [UIButton buttonWithType:UIButtonTypeCustom];

        [[remove titleLabel] setFont:YTFontRegular(17)];
        [remove setTitle:@"✕" forState:UIControlStateNormal];
        [remove setTag:3];
        [remove addTarget:self
                   action:@selector(removeHint:)
         forControlEvents:UIControlEventTouchUpInside];
        [[cell contentView] addSubview:remove];
    }

    BOOL history = [self showingHistory];
    CGFloat width = [tableView bounds].size.width;

    [cell setBackgroundColor:[YTTheme background]];

    UIImageView *glyph = (UIImageView *)[[cell contentView] viewWithTag:1];
    UILabel *text = (UILabel *)[[cell contentView] viewWithTag:2];
    UIButton *remove = (UIButton *)[[cell contentView] viewWithTag:3];

    // История помечена значком повтора, подсказка — лупой.
    [glyph setImage:YTIcon(history ? @"pl_replay" : @"search")];

    [text setTextColor:[YTTheme primaryText]];
    [text setText:[self hintAt:index]];
    [text setFrame:CGRectMake(56, 0, width - 56 - (history ? 48 : 12), 52)];

    [remove setHidden:!history];
    [remove setTitleColor:[YTTheme primaryText] forState:UIControlStateNormal];
    [remove setFrame:CGRectMake(width - 48, 2, 48, 48)];
    [remove setTag:3];

    // Номер строки кладём в кнопку: у неё нет иного способа узнать своё место.
    objc_setAssociatedObject(remove, @selector(removeHint:),
                             [NSNumber numberWithInteger:index],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    return cell;
}

- (void)removeHint:(UIButton *)button {
    NSNumber *index = objc_getAssociatedObject(button, @selector(removeHint:));

    [self forgetQueryAt:[index integerValue]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    // Нажатие по строке канала открывает его страницу.
    if (tableView != _hints && _kind == YTSearchChannels) {
        [tableView deselectRowAtIndexPath:path animated:NO];

        NSArray *row = [_rows objectAtIndex:(NSUInteger)[path row]];
        YTVideoItem *item = [row count] > 0 ? [row objectAtIndex:0] : nil;

        if ([item.channelId length] > 0) {
            [YTNav openChannel:item.channelId title:item.title];
        }

        return;
    }

    if (tableView != _hints) {
        return;
    }

    NSString *text = [self hintAt:[path row]];

    if ([text length] == 0) {
        return;
    }

    [_field setText:text];
    [_field resignFirstResponder];

    _query = [text copy];

    [self rememberQuery:text];
    [self showHints:NO];
    [self runSearch];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == _hints) {
        // Прокрутка подсказок — не повод просить следующую страницу выдачи.
        [_field resignFirstResponder];

        return;
    }

    if (![_pager claimOn:scrollView]) {
        return;
    }

    NSInteger generation = [_generation current];
    NSString *token = [_pager token];
    NSString *query = _query;
    YTSearchKind kind = _kind;

    YTAsync(^{
        NSDictionary *found = [YTApi search:query continuation:token kind:kind];

        YTMain(^{
            [_pager finish];

            if (![_generation isCurrent:generation]) {
                return;
            }

            NSArray *items = [found objectForKey:@"items"];

            if ([items count] == 0) {
                [_pager setToken:nil];
                return;
            }

            [_pager setToken:[found objectForKey:@"continuation"]];

            [_items addObjectsFromArray:items];

            [self rebuildRows];
            [_table reloadData];
        });
    });
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];

    CGRect bounds = [[self view] bounds];
    CGFloat top = YTStatusBarHeight();

    [_bar setFrame:CGRectMake(0, top, bounds.size.width, YTNavBarHeight)];
    [_back setFrame:CGRectMake(4, 8, 40, 40)];
    [_field setFrame:CGRectMake(48, 10, bounds.size.width - 64, 36)];

    CGFloat contentTop = top + YTNavBarHeight;

    /**
     * Полоса фильтров стоит под строкой ввода и только при показанной
     * выдаче: пока набирают запрос, под строкой список подсказок,
     * и фильтровать ещё нечего.
     */
    BOOL chipsVisible = !_suggesting && [_query length] > 0;

    [_chipsBar setHidden:!chipsVisible];

    if (chipsVisible) {
        [_chipsBar setFrame:CGRectMake(0, contentTop, bounds.size.width, YTChipsBarHeight)];

        CGFloat x = YTFeedPadding + 8;

        for (YTChipView *chip in _chips) {
            if ((id)chip == [NSNull null]) {
                continue;
            }

            CGFloat width = [chip widthForTitle];

            [chip setFrame:CGRectMake(x, (YTChipsBarHeight - YTChipHeight) / 2,
                                      width, YTChipHeight)];

            x += width + 8;
        }

        [_chipsBar setContentSize:CGSizeMake(x + YTFeedPadding + 8 - 8, YTChipsBarHeight)];

        contentTop += YTChipsBarHeight;
    }

    [_table setFrame:CGRectMake(0, contentTop, bounds.size.width,
                                bounds.size.height - contentTop)];
    [_status setFrame:[_table frame]];

    // Список подсказок занимает всё под строкой ввода, без полосы фильтров.
    [_hints setFrame:CGRectMake(0, top + YTNavBarHeight, bounds.size.width,
                                bounds.size.height - top - YTNavBarHeight)];

    if (_laidOutWidth == bounds.size.width) {
        return;
    }

    _laidOutWidth = bounds.size.width;

    if ([self applyColumns]) {
        [self rebuildRows];
    }

    [_table reloadData];
}

/**
 * Сколько карточек в ряду. Возвращает YES, если число сменилось.
 *
 * У вертикальных карточек своя мера: превью 9:16 во всю ширину телефона
 * это полтора экрана на одну карточку. Вдвое больше в ряду — и высота
 * выходит примерно как у обычной ленты.
 *
 * Каналы, наоборот, идут по одному в ряд: у них строка, а не плитка.
 */
- (BOOL)applyColumns {
    CGFloat available = [[self view] bounds].size.width - YTFeedPadding * 2;

    NSInteger columns = YTColumnsForWidth(available);

    if (_kind == YTSearchShorts) {
        columns = MAX(2, columns * 2);
    } else if (_kind == YTSearchChannels) {
        columns = 1;
    }

    if (columns == _columns) {
        return NO;
    }

    _columns = columns;

    return YES;
}

@end
