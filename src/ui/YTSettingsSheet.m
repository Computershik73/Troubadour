#import "YTSettingsSheet.h"

#import "YTStrings.h"

#import <QuartzCore/QuartzCore.h>

#import "YTImageLoader.h"
#import "YTMetrics.h"
#import "YTRoundedImageView.h"
#import "YTTheme.h"
#import "YTUtil.h"

/** Числа `SettingsBottomSheetPanel` из Video.xaml. */
static const CGFloat YTSheetSide = 10;
static const CGFloat YTSheetRadius = 15;
static const CGFloat YTSheetGrip = 40;
static const CGFloat YTSheetPad = 20;
static const CGFloat YTSheetRowHeight = 44;

/**
 * Строка канала выше обычной: в ней кружок и две подписи.
 *
 * Числа не из оригинала — там этого списка нет вовсе. Взяты по соседям:
 * кружок 36, как у автора комментария, и высота, при которой две строки
 * текста стоят с теми же полями, что одна в обычной строке.
 */
static const CGFloat YTSheetAccountHeight = 56;
static const CGFloat YTSheetAccountPhoto = 36;

/** `Margin="0,0,0,4"` у каждой строки — просвет между ними. */
static const CGFloat YTSheetRowGap = 4;

/** Просвет между подписью со сведениями и самим текстом. */
static const CGFloat YTSheetNoteGap = 10;
static const CGFloat YTSheetIcon = 24;
static const CGFloat YTSheetChevron = 16;
static const CGFloat YTSheetCheck = 28;

@implementation YTSheetRow

+ (YTSheetRow *)section:(NSString *)icon
                  title:(NSString *)title
                  value:(NSString *)value
                 action:(dispatch_block_t)action {
    YTSheetRow *row = [[YTSheetRow alloc] init];

    row.icon = icon;
    row.title = title;
    row.value = value;
    row.chevron = YES;
    row.action = action;

    return row;
}

+ (YTSheetRow *)command:(NSString *)icon
                  title:(NSString *)title
                 action:(dispatch_block_t)action {
    YTSheetRow *row = [self section:icon title:title value:nil action:action];

    row.chevron = NO;

    return row;
}

+ (YTSheetRow *)note:(NSString *)text {
    YTSheetRow *row = [[YTSheetRow alloc] init];

    row.title = text;
    row.isNote = YES;

    return row;
}

+ (YTSheetRow *)choice:(NSString *)title
                picked:(BOOL)picked
                action:(dispatch_block_t)action {
    YTSheetRow *row = [[YTSheetRow alloc] init];

    row.title = title;
    row.checkable = YES;
    row.checked = picked;
    row.action = action;

    return row;
}

+ (YTSheetRow *)account:(NSString *)title
               subtitle:(NSString *)subtitle
                 avatar:(NSString *)avatar
                 picked:(BOOL)picked
                 action:(dispatch_block_t)action {
    YTSheetRow *row = [[YTSheetRow alloc] init];

    row.title = title;
    row.subtitle = subtitle;
    row.avatar = avatar;
    row.checked = picked;
    row.action = action;

    return row;
}

+ (YTSheetRow *)back:(dispatch_block_t)action {
    return [self command:@"pl_back" title:YTLoc(@"Назад") action:action];
}

@end


@interface YTSettingsSheet () <UIGestureRecognizerDelegate>
@end

@implementation YTSettingsSheet {
    BOOL _dark;
    BOOL _open;

    YTPillView *_panel;
    YTTappableView *_gripHost;
    UIView *_grip;
    UILabel *_title;
    UIScrollView *_list;
    UILabel *_body;

    /** Подпись над сплошным текстом: просмотры и дата у описания. */
    UILabel *_note;

    NSMutableArray *_rows;

    /**
     * Место панели в покое — то, куда она возвращается, если протяжку
     * вниз не довели до закрытия. Считается при раскладке: во время
     * самой протяжки рамка панели уже смещена, и брать её оттуда поздно.
     */
    CGRect _place;

    /** Тянут ли панель прямо сейчас — раскладка в это время не мешает. */
    BOOL _dragging;

    /** Нажатие мимо панели — его и только его отбирает делегат. */
    UITapGestureRecognizer *_tap;
}

- (id)initWithDark:(BOOL)dark {
    self = [super initWithFrame:CGRectZero];

    if (self == nil) {
        return nil;
    }

    _dark = dark;
    _rows = [NSMutableArray array];

    // `OverlayGrid` — `#80000000`, нажатие по нему закрывает панель.
    [self setBackgroundColor:[UIColor colorWithWhite:0 alpha:0.5]];
    [self setHidden:YES];

    _panel = [[YTPillView alloc] initWithFrame:CGRectZero];

    [_panel setCornerRadius:YTSheetRadius];
    [_panel setFillColor:[self panelColor]];

    /**
     * Взаимодействие приходится включать обратно.
     *
     * `YTPillView` только рисует и потому рождается с выключенным
     * `userInteractionEnabled`. Здесь она держит строки, и с выключенным
     * флагом нажатия проваливались бы сквозь неё на затемнение, а оно
     * закрывает панель: по любой строке она просто закрывалась.
     */
    [_panel setUserInteractionEnabled:YES];
    [self addSubview:_panel];

    /**
     * Полоса захвата — `Rectangle Width="40" Height="4"` серым по центру
     * области высотой 40. Тянуть панель пальцем нельзя, но нажатие по
     * этой области закрывает её, как `SettingsDragArea_Tapped`.
     */
    _gripHost = [[YTTappableView alloc] initWithFrame:CGRectZero];

    [_gripHost setHighlights:NO];

    __weak YTSettingsSheet *weakSelf = self;

    [_gripHost setOnTap:^{ [weakSelf close]; }];
    [_panel addSubview:_gripHost];

    _grip = [[UIView alloc] initWithFrame:CGRectZero];

    [_grip setBackgroundColor:[UIColor grayColor]];
    [[_grip layer] setCornerRadius:2];
    [_grip setUserInteractionEnabled:NO];
    [_gripHost addSubview:_grip];

    _title = YTLabel(YTFontSemiBold(16), [self primaryColor], 1);
    [_panel addSubview:_title];

    _list = [[UIScrollView alloc] initWithFrame:CGRectZero];

    [_list setShowsVerticalScrollIndicator:NO];
    [_panel addSubview:_list];

    // Нажатие мимо панели — закрыть, как по `OverlayGrid`.
    _tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)];

    [_tap setDelegate:self];
    [self addGestureRecognizer:_tap];

    /**
     * Протяжка вниз по самой панели — тоже закрытие.
     *
     * Панель выезжает снизу, и убрать её тем же движением обратно —
     * первое, что приходит в голову. Распознаватель висит на панели,
     * а не на затемнении: тянуть надо именно её.
     */
    UIPanGestureRecognizer *swipe =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];

    [swipe setDelegate:self];
    [_panel addGestureRecognizer:swipe];

    return self;
}

/** Протяжка живёт рядом с прокруткой списка, а не вместо неё. */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

/**
 * Панель едет за пальцем вниз и закрывается, если её увели достаточно
 * далеко или отпустили на ходу. Иначе возвращается на место.
 */
- (void)dragged:(UIPanGestureRecognizer *)gesture {
    /**
     * Откуда начали — с полосы захвата или со списка. Со списка тянем
     * только когда он уже наверху, иначе протяжка отнимала бы у него
     * прокрутку. То же правило у панели комментариев.
     */
    if ([gesture state] == UIGestureRecognizerStateBegan) {
        CGFloat where = [gesture locationInView:_panel].y;

        _dragging = (where <= YTSheetGrip) || ([_list contentOffset].y <= 0);

        return;
    }

    if (!_dragging) {
        return;
    }

    CGFloat shift = [gesture translationInView:self].y;

    // Вверх панель не тянется: там её место, выше ехать некуда.
    if (shift < 0) {
        shift = 0;
    }

    if ([gesture state] == UIGestureRecognizerStateChanged) {
        // Список придерживаем наверху — иначе он уедет вместе с панелью.
        [_list setContentOffset:CGPointZero];

        [_panel setFrame:CGRectOffset(_place, 0, shift)];

        return;
    }

    if ([gesture state] != UIGestureRecognizerStateEnded &&
        [gesture state] != UIGestureRecognizerStateCancelled) {
        return;
    }

    _dragging = NO;

    CGFloat speed = [gesture velocityInView:self].y;

    // Треть высоты панели либо заметный бросок вниз — закрываем.
    if (shift > _place.size.height / 3 || speed > 600) {
        [self close];

        return;
    }

    [UIView animateWithDuration:0.2 animations:^{
        [_panel setFrame:_place];
    }];
}

/** Панель Shorts всегда тёмная: она лежит поверх кадра. */
- (UIColor *)panelColor {
    return _dark ? YTColor(0x222222) : [YTTheme divider];
}

- (UIColor *)primaryColor {
    return _dark ? [UIColor whiteColor] : [YTTheme primaryText];
}

- (UIColor *)secondaryColor {
    return _dark ? YTColor(0xAAAAAA) : [YTTheme secondaryText];
}

- (BOOL)isOpen {
    return _open;
}

/**
 * Нажатие мимо панели закрывает, нажатие по ней — нет.
 *
 * Распознаватель висит на всём затемнении, и без этой проверки он съедал
 * бы нажатия по самим строкам.
 */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
       shouldReceiveTouch:(UITouch *)touch {
    /**
     * Отбор касаний — только для нажатия. Протяжка живёт на самой панели,
     * и та же проверка отняла бы у неё все касания разом: делегат у обоих
     * распознавателей один.
     */
    if (gesture != _tap) {
        return YES;
    }

    UIView *view = [touch view];

    while (view != nil && view != self) {
        if (view == _panel) {
            return NO;
        }

        view = [view superview];
    }

    return YES;
}

- (void)setTitle:(NSString *)title text:(NSString *)text {
    [self setTitle:title note:nil text:text];
}

- (void)setTitle:(NSString *)title note:(NSString *)note text:(NSString *)text {
    [self setTitle:title rows:nil];

    if (_body == nil) {
        _body = YTLabel(YTFontRegular(14), [self primaryColor], 0);

        [_list addSubview:_body];
    }

    /**
     * Подпись над текстом — тем же шрифтом, что и подписи под роликами
     * в лентах: мельче основного и приглушённого цвета. Так она читается
     * как сведения о ролике, а не как первая строка описания.
     */
    if (_note == nil) {
        _note = YTLabel(YTFontRegular(12), [self secondaryColor], 0);

        [_list addSubview:_note];
    }

    [_note setTextColor:[self secondaryColor]];
    [_note setText:note];
    [_note setHidden:([note length] == 0)];

    [_body setTextColor:[self primaryColor]];
    [_body setText:text];
    [_body setHidden:NO];

    [self setNeedsLayout];
}

- (void)setTitle:(NSString *)title rows:(NSArray *)rows {
    [_title setText:title];
    [_title setHidden:([title length] == 0)];

    // Строки и сплошной текст — два разных наполнения, не вместе.
    [_body setHidden:YES];
    [_note setHidden:YES];

    for (UIView *view in _rows) {
        [view removeFromSuperview];
    }

    [_rows removeAllObjects];

    for (YTSheetRow *row in rows) {
        UIView *view = [self buildRow:row];

        [_rows addObject:view];
        [_list addSubview:view];
    }

    [self setNeedsLayout];
}

/**
 * Метка названия внутри строки.
 *
 * Строки бывают разного устройства — с кружком, с галочкой, со значком, —
 * и место названия в них своё. Метка избавляет от угадывания по порядку
 * подвидов: такой порядок меняется при первой же правке раскладки,
 * и молча.
 */
static const NSInteger YTSheetTitleTag = 7101;

/** По нему раскладка узнаёт строку-пояснение среди прочих. */
static const NSInteger YTSheetNoteTag = 7102;

- (void)retitleRowAt:(NSUInteger)index to:(NSString *)title {
    if (index >= [_rows count]) {
        return;
    }

    UIView *host = [_rows objectAtIndex:index];
    UIView *found = [host viewWithTag:YTSheetTitleTag];

    if (![found isKindOfClass:[UILabel class]]) {
        return;
    }

    UILabel *label = (UILabel *)found;

    if ([[label text] isEqualToString:title]) {
        return;
    }

    [label setText:title];

    [self setNeedsLayout];
}

- (UIView *)buildRow:(YTSheetRow *)row {
    YTTappableView *host = [[YTTappableView alloc] initWithFrame:CGRectZero];

    dispatch_block_t action = row.action;

    if (action != nil) {
        [host setOnTap:^{ action(); }];
    }

    /**
     * Строка канала: кружок, имя, подпись под ним, галочка справа.
     *
     * Кружок стоит первым нарочно — по нему раскладка и узнаёт эту
     * строку среди прочих, не заводя отдельного поля с родом.
     */
    if ([row.avatar length] > 0 || [row.subtitle length] > 0) {
        YTRoundedImageView *photo =
            [[YTRoundedImageView alloc] initWithFrame:CGRectZero];

        [photo setCircular:YES];
        [photo setPlaceholderColor:[YTTheme avatarPlaceholder]];
        [photo setUserInteractionEnabled:NO];
        [host addSubview:photo];

        if ([row.avatar length] > 0) {
            [YTImageLoader loadInto:photo
                                url:row.avatar
                        targetWidth:YTSheetAccountPhoto];
        }

        UILabel *name = YTLabel(row.checked ? YTFontSemiBold(15) : YTFontRegular(15),
                                [self primaryColor], 1);

        [name setTag:YTSheetTitleTag];
        [name setText:row.title];
        [host addSubview:name];

        UILabel *under = YTLabel(YTFontRegular(12), [self secondaryColor], 1);

        [under setText:row.subtitle];
        [host addSubview:under];

        UILabel *check = YTLabel(YTFontRegular(16), [YTTheme accentBlue], 1);

        [check setText:row.checked ? @"✓" : @""];
        [check setTextAlignment:NSTextAlignmentRight];
        [host addSubview:check];

        return host;
    }

    if (row.isNote) {
        UILabel *text = YTLabel(YTFontRegular(12), [self secondaryColor], 0);

        [text setTag:YTSheetTitleTag];
        [text setText:row.title];
        [host addSubview:text];
        [host setTag:YTSheetNoteTag];
        [host setUserInteractionEnabled:NO];

        return host;
    }

    if (row.checkable) {
        /**
         * Пункт списка: столбец 28 под галочку, название рядом.
         * У выбранного оно полужирное — так же в оригинале.
         */
        UILabel *check = YTLabel(YTFontRegular(16), [self primaryColor], 1);

        [check setText:row.checked ? @"✓" : @""];
        [host addSubview:check];

        // `FontSize = 14` у пункта списка — в разделах шрифт крупнее.
        UILabel *label = YTLabel(row.checked ? YTFontSemiBold(14) : YTFontRegular(14),
                                 [self primaryColor], 1);

        [label setTag:YTSheetTitleTag];
        [label setText:row.title];
        [host addSubview:label];

        return host;
    }

    if ([row.icon length] > 0) {
        UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectZero];

        /**
         * Значок берётся по теме — и на странице ролика, и в Shorts:
         * в разметке обеих панелей стоит `Assets/player/…` без `Dark`.
         * Стрелка ниже — наоборот, всегда из `Dark`; это не описка,
         * а разные пути в оригинале, и они здесь повторены как есть.
         */
        [icon setImage:YTIcon(row.icon)];
        [icon setContentMode:UIViewContentModeScaleAspectFit];
        [icon setUserInteractionEnabled:NO];
        [host addSubview:icon];
    }

    UILabel *label = YTLabel(YTFontRegular(16), [self primaryColor], 1);

    [label setTag:YTSheetTitleTag];
    [label setText:row.title];
    [host addSubview:label];

    if ([row.value length] > 0) {
        UILabel *value = YTLabel(YTFontRegular(14), [self secondaryColor], 1);

        [value setText:row.value];
        [value setTextAlignment:NSTextAlignmentRight];
        [host addSubview:value];
    }

    if (row.chevron) {
        UIImageView *arrow = [[UIImageView alloc] initWithFrame:CGRectZero];

        [arrow setImage:(_dark ? YTDarkIcon(@"pl_skip") : YTIcon(@"pl_skip"))];
        [arrow setContentMode:UIViewContentModeScaleAspectFit];
        [arrow setAlpha:0.6f];
        [arrow setUserInteractionEnabled:NO];
        [host addSubview:arrow];
    }

    return host;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect box = [self bounds];

    CGFloat panelWidth = box.size.width - YTSheetSide * 2;
    CGFloat inner = panelWidth - YTSheetPad * 2;
    CGFloat header = ([_title isHidden] ? 0 : 20 + 16);

    CGFloat pitch = YTSheetRowHeight + YTSheetRowGap;

    CGFloat listHeight = 0;

    for (UIView *row in _rows) {
        listHeight += [self heightOfRow:row width:inner] + YTSheetRowGap;
    }

    BOOL plain = (_body != nil && ![_body isHidden]);
    BOOL noted = (_note != nil && ![_note isHidden]);

    /** Высота подписи вместе с отступом до текста; ноль, если её нет. */
    CGFloat noteHeight = 0;

    if (noted) {
        noteHeight = YTTextHeight([_note text], [_note font], inner, 0) + YTSheetNoteGap;
    }

    if (plain) {
        listHeight = noteHeight + YTTextHeight([_body text], [_body font], inner, 0);
    }

    CGFloat content = YTSheetGrip + header + listHeight + YTSheetPad;
    CGFloat panelHeight = MIN(content, box.size.height * 0.7f);

    _place = CGRectMake(YTSheetSide, box.size.height - panelHeight - YTSheetSide,
                        panelWidth, panelHeight);

    // Пока панель тянут, раскладка её не двигает — место ведёт палец.
    if (!_dragging) {
        [_panel setFrame:_place];
    }

    [_gripHost setFrame:CGRectMake(0, 0, panelWidth, YTSheetGrip)];
    [_grip setFrame:CGRectMake((panelWidth - 40) / 2, YTSheetGrip / 2 - 2, 40, 4)];

    [_title setFrame:CGRectMake(YTSheetPad, YTSheetGrip, inner, 20)];

    CGFloat top = YTSheetGrip + header;

    [_list setFrame:CGRectMake(YTSheetPad, top, inner,
                               MAX(0, panelHeight - top - YTSheetPad))];
    [_list setContentSize:CGSizeMake(inner, listHeight)];

    if (plain) {
        if (noted) {
            [_note setFrame:CGRectMake(0, 0, inner, noteHeight - YTSheetNoteGap)];
        }

        [_body setFrame:CGRectMake(0, noteHeight, inner, listHeight - noteHeight)];
    }

    CGFloat at = 0;

    for (NSUInteger i = 0; i < [_rows count]; i++) {
        UIView *row = [_rows objectAtIndex:i];

        CGFloat height = [self heightOfRow:row width:inner];

        [row setFrame:CGRectMake(0, at, inner, height)];

        [self layoutInsideRow:row width:inner];

        at += height + YTSheetRowGap;
    }
}

/**
 * Высота строки — по тому, что в ней стоит.
 *
 * Прежде она была одна на все: панель показывала только текстовые
 * пункты. Со строкой канала это перестало годиться — в ней кружок
 * и две подписи, — поэтому высота спрашивается у самой строки.
 */
- (CGFloat)heightOfRow:(UIView *)row width:(CGFloat)width {
    // Пояснение — во столько строк, во сколько уложится текст.
    if ([row tag] == YTSheetNoteTag) {
        UILabel *text = (UILabel *)[row viewWithTag:YTSheetTitleTag];

        return YTTextHeight([text text], [text font], width, 0) + YTSheetNoteGap;
    }

    return [[row subviews] count] > 0 &&
           [[[row subviews] objectAtIndex:0] isKindOfClass:[YTRoundedImageView class]]
        ? YTSheetAccountHeight : YTSheetRowHeight;
}

/** Раскладка внутри строки: столбцы сетки из оригинала. */
- (void)layoutInsideRow:(UIView *)row width:(CGFloat)width {
    NSArray *parts = [row subviews];

    if ([parts count] == 0) {
        return;
    }

    UIView *first = [parts objectAtIndex:0];

    if ([row tag] == YTSheetNoteTag) {
        [first setFrame:CGRectMake(0, YTSheetNoteGap / 2, width,
                                   [row bounds].size.height - YTSheetNoteGap)];

        return;
    }

    // Строка канала: кружок слева, две подписи, галочка справа.
    if ([first isKindOfClass:[YTRoundedImageView class]]) {
        CGFloat photo = YTSheetAccountPhoto;
        CGFloat gap = 12;

        [first setFrame:CGRectMake(0, (YTSheetAccountHeight - photo) / 2,
                                   photo, photo)];

        CGFloat left = photo + gap;
        CGFloat right = 28;
        CGFloat text = width - left - right;

        CGFloat nameHeight = 18;
        CGFloat underHeight = 15;
        CGFloat block = nameHeight + underHeight;

        CGFloat top = (YTSheetAccountHeight - block) / 2;

        [[parts objectAtIndex:1] setFrame:
            CGRectMake(left, top, text, nameHeight)];

        [[parts objectAtIndex:2] setFrame:
            CGRectMake(left, top + nameHeight, text, underHeight)];

        [[parts objectAtIndex:3] setFrame:
            CGRectMake(width - right, 0, right, YTSheetAccountHeight)];

        return;
    }

    // Пункт списка: галочка в столбце 28, название за ним.
    if ([parts count] == 2 && [first isKindOfClass:[UILabel class]]) {
        [first setFrame:CGRectMake(0, 0, YTSheetCheck, YTSheetRowHeight)];

        [[parts objectAtIndex:1] setFrame:
            CGRectMake(YTSheetCheck, 0, width - YTSheetCheck, YTSheetRowHeight)];

        return;
    }

    CGFloat left = 0;

    if ([first isKindOfClass:[UIImageView class]]) {
        // `Width="24" Height="24" Margin="0,0,16,0"` в оригинале.
        [first setFrame:CGRectMake(0, (YTSheetRowHeight - YTSheetIcon) / 2,
                                   YTSheetIcon, YTSheetIcon)];

        left = YTSheetIcon + 16;
    }

    CGFloat right = width;

    UIView *last = [parts lastObject];

    if ([last isKindOfClass:[UIImageView class]] && last != first) {
        // Стрелка: `Width="16" Margin="14,0,0,0"`.
        right -= YTSheetChevron;

        [last setFrame:CGRectMake(right, (YTSheetRowHeight - YTSheetChevron) / 2,
                                  YTSheetChevron, YTSheetChevron)];

        right -= 14;
    }

    UILabel *label = nil;
    UILabel *value = nil;

    for (UIView *part in parts) {
        if (![part isKindOfClass:[UILabel class]]) {
            continue;
        }

        if (label == nil) {
            label = (UILabel *)part;
        } else {
            value = (UILabel *)part;
        }
    }

    if (value != nil) {
        /**
         * Значение прижато к стрелке и берёт себе ровно столько, сколько
         * ему нужно: в оригинале это столбец `Auto`, а название — `*`.
         */
        CGSize wanted = [[value text] sizeWithFont:[value font]];
        CGFloat valueWidth = MIN(wanted.width + 8, (right - left) / 2);

        [value setFrame:CGRectMake(right - valueWidth, 0, valueWidth, YTSheetRowHeight)];

        right -= valueWidth;
    }

    [label setFrame:CGRectMake(left, 0, MAX(0, right - left), YTSheetRowHeight)];
}

- (void)openIn:(UIView *)host {
    if (_open) {
        return;
    }

    _open = YES;

    [self setFrame:[host bounds]];
    [host addSubview:self];
    [host bringSubviewToFront:self];

    [self setHidden:NO];

    /**
     * Раскладываем сразу: панель должна знать своё место, чтобы выехать
     * к нему снизу, а не появиться на нём.
     */
    [self setNeedsLayout];
    [self layoutIfNeeded];

    CGRect place = [_panel frame];
    CGRect start = place;

    start.origin.y = [self bounds].size.height;

    [_panel setFrame:start];
    [self setAlpha:0];

    [UIView animateWithDuration:0.22
                     animations:^{
        [self setAlpha:1];
        [_panel setFrame:place];
    }];
}

- (void)close {
    if (!_open) {
        return;
    }

    _open = NO;

    CGRect gone = [_panel frame];

    gone.origin.y = [self bounds].size.height;

    [UIView animateWithDuration:0.18
                     animations:^{
        [self setAlpha:0];
        [_panel setFrame:gone];
    }
                     completion:^(BOOL finished) {
        [self setHidden:YES];
        [self setAlpha:1];
        [self removeFromSuperview];
    }];
}

@end
