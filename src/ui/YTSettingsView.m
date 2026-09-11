#import "YTSimpleScreens.h"

#import "YTStrings.h"

#import <QuartzCore/QuartzCore.h>

#import "YTAuth.h"
#import "YTWebAuth.h"
#import "YTPoToken.h"
#import "YTMetrics.h"
#import "YTAppIconView.h"
#import "YTSettings.h"
#import "YTStreams.h"
#import "YTTheme.h"
#import "YTUtil.h"
#import "YTLog.h"

/**
 * Числа — из Settings.xaml, один в один.
 *
 *     содержимое     Padding="0,12,0,82"
 *     заголовок      «Настройки» 22 SemiBold, Margin="18,0,18,22"
 *     раздел         17 Bold, Margin="18,22,18,10"
 *     строка         Height="52", Margin="18,0,18,0";
 *                    значок 23×23, подпись 16 с отступом 18 от значка,
 *                    значение 13 secondary справа, стрелка 14 при 0.6
 *     строка-тумблер Height="62"; подпись 16, пояснение 12 secondary
 *                    с отступом 2 сверху; дорожка 46×26 со скруглением 13,
 *                    кружок 20 с отступом 3, сдвиг во включённом 20
 *     лист выбора    Margin="10,0,10,10", скругление 15, фон AppDividerBrush;
 *                    полоса захвата 34 с ручкой 38×4, заголовок 15 SemiBold
 *                    с отступом 12 снизу, строка 42, текст 14
 */
static const CGFloat YTSetSide = 18;
static const CGFloat YTSetRow = 52;
static const CGFloat YTSetToggleRow = 62;
static const CGFloat YTSetIcon = 23;
static const CGFloat YTSetChevron = 14;
static const CGFloat YTSetTrackWidth = 46;
static const CGFloat YTSetTrackHeight = 26;
static const CGFloat YTSetKnob = 20;
static const CGFloat YTSetKnobInset = 3;
static const CGFloat YTSetSectionTop = 22;
static const CGFloat YTSetSectionBottom = 10;

static const CGFloat YTSheetSide = 10;
static const CGFloat YTSheetRadius = 15;
static const CGFloat YTSheetGrip = 34;
static const CGFloat YTSheetOption = 42;


#pragma mark - Строка настроек

/**
 * Одна строка. Все три вида — переход, значение и тумблер — это один класс
 * с разным набором видимых частей: в оригинале они тоже отличаются только
 * содержимым `Grid` внутри одинаковой кнопки.
 */
@interface YTSettingsRow : YTTappableView

- (void)setIconName:(NSString *)name;
- (void)setLabelText:(NSString *)text;
- (void)setHintText:(NSString *)text;
- (void)setValueText:(NSString *)text;

/** Тумблер вместо значения со стрелкой. */
- (void)useToggle;
- (void)setToggleOn:(BOOL)on;

- (CGFloat)preferredHeight;
- (void)applyTheme;

@end

@implementation YTSettingsRow {
    NSString *_iconName;

    UIImageView *_icon;
    UILabel *_label;
    UILabel *_hint;
    UILabel *_value;
    UIImageView *_chevron;

    UIView *_track;
    UIView *_knob;

    BOOL _showsToggle;
    BOOL _toggleOn;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    [self setHighlights:YES];

    _icon = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_icon setContentMode:UIViewContentModeScaleAspectFit];
    [self addSubview:_icon];

    _label = YTLabel(YTFontRegular(16), [YTTheme primaryText], 1);
    [self addSubview:_label];

    _hint = YTLabel(YTFontRegular(12), [YTTheme secondaryText], 1);
    [self addSubview:_hint];

    _value = YTLabel(YTFontRegular(13), [YTTheme secondaryText], 1);
    [_value setTextAlignment:NSTextAlignmentRight];
    [self addSubview:_value];

    _chevron = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_chevron setContentMode:UIViewContentModeScaleAspectFit];
    [_chevron setAlpha:0.6];
    [self addSubview:_chevron];

    _track = [[UIView alloc] initWithFrame:CGRectZero];
    [[_track layer] setCornerRadius:YTSetTrackHeight / 2];
    [_track setHidden:YES];
    [self addSubview:_track];

    _knob = [[UIView alloc] initWithFrame:CGRectZero];
    [[_knob layer] setCornerRadius:YTSetKnob / 2];
    [_knob setHidden:YES];
    [self addSubview:_knob];

    return self;
}

- (BOOL)hasHint {
    return [[_hint text] length] > 0;
}

- (BOOL)hasValue {
    return [[_value text] length] > 0;
}

- (CGFloat)preferredHeight {
    return [self hasHint] ? YTSetToggleRow : YTSetRow;
}

- (void)setIconName:(NSString *)name {
    _iconName = [name copy];

    [_icon setImage:YTIcon(name)];
}

- (void)setLabelText:(NSString *)text {
    [_label setText:text];
}

- (void)setHintText:(NSString *)text {
    [_hint setText:text];
    [_hint setHidden:[text length] == 0];

    [self setNeedsLayout];
}

- (void)setValueText:(NSString *)text {
    [_value setText:text];
    [_chevron setHidden:_showsToggle || [text length] == 0];

    [self setNeedsLayout];
}

- (void)useToggle {
    _showsToggle = YES;

    [_track setHidden:NO];
    [_knob setHidden:NO];
    [_chevron setHidden:YES];

    [self setNeedsLayout];
}

- (void)setToggleOn:(BOOL)on {
    _toggleOn = on;

    [self applyTheme];
    [self setNeedsLayout];
}

- (void)applyTheme {
    [_icon setImage:YTIcon(_iconName)];
    [_chevron setImage:YTIcon(@"pl_skip")];

    [_label setTextColor:[YTTheme primaryText]];
    [_hint setTextColor:[YTTheme secondaryText]];
    [_value setTextColor:[YTTheme secondaryText]];

    /**
     * Цвета дорожки — из `UpdateChannelIconsToggleVisual`: включённая
     * красится в `AppPrimaryTextBrush`, выключенная — в `AppMutedTextBrush`.
     * Кружок всегда `ToggleKnobBrush`, то есть цвет, обратный основному
     * тексту: на белой дорожке тёмный, на тёмной белый.
     */
    [_track setBackgroundColor:_toggleOn ? [YTTheme primaryText] : [YTTheme mutedText]];
    [_knob setBackgroundColor:[YTTheme isDark] ? YTColor(0x202124) : [UIColor whiteColor]];
}

- (void)layoutSubviews {
    CGRect box = [self bounds];
    CGFloat middle = box.size.height / 2;

    [_icon setFrame:CGRectMake(YTSetSide, middle - YTSetIcon / 2, YTSetIcon, YTSetIcon)];

    CGFloat textLeft = YTSetSide + YTSetIcon + YTSetSide;
    CGFloat right = box.size.width - YTSetSide;

    if (_showsToggle) {
        CGFloat trackLeft = right - YTSetTrackWidth;

        [_track setFrame:CGRectMake(trackLeft, middle - YTSetTrackHeight / 2,
                                    YTSetTrackWidth, YTSetTrackHeight)];

        // Сдвиг включённого кружка — `OnOffset = 20` из Settings.xaml.cs.
        CGFloat offset = _toggleOn ? YTSetKnob : 0;

        [_knob setFrame:CGRectMake(trackLeft + YTSetKnobInset + offset,
                                   middle - YTSetKnob / 2, YTSetKnob, YTSetKnob)];

        // `Margin="18,0,12,0"` у текста в строке с тумблером.
        right = trackLeft - 12;
    } else if ([self hasValue]) {
        [_chevron setFrame:CGRectMake(right - YTSetChevron, middle - YTSetChevron / 2,
                                      YTSetChevron, YTSetChevron)];

        // `MaxWidth="110"` у значения и `Margin="6,0,0,0"` у стрелки.
        CGFloat valueWidth = MIN((CGFloat)110, (right - YTSetChevron - 6) - textLeft - 8);

        [_value setFrame:CGRectMake(right - YTSetChevron - 6 - valueWidth,
                                    middle - 10, valueWidth, 20)];

        right = right - YTSetChevron - 6 - valueWidth - 8;
    }

    CGFloat width = MAX((CGFloat)0, right - textLeft);

    if ([self hasHint]) {
        // Подпись и пояснение — стопкой по центру, отступ между ними 2.
        [_label setFrame:CGRectMake(textLeft, middle - 19, width, 20)];
        [_hint setFrame:CGRectMake(textLeft, middle + 3, width, 16)];
    } else {
        [_label setFrame:CGRectMake(textLeft, middle - 11, width, 22)];
        [_hint setFrame:CGRectZero];
    }
}

@end


#pragma mark - Лист выбора

/**
 * Выдвижной лист с вариантами — порт `ThemeBottomSheetPanel` и его близнецов
 * (язык, качество, качество превью). В оригинале это четыре одинаковых
 * `Border` с разной начинкой; здесь один класс, которому передают заголовок
 * и список.
 */
@interface YTChoiceSheet : UIView

- (void)showInView:(UIView *)host
             title:(NSString *)title
           options:(NSArray *)titles
          selected:(NSInteger)selected
            picked:(void (^)(NSInteger index))picked;

@end

@implementation YTChoiceSheet {
    UIView *_backdrop;
    UIView *_panel;
    UIView *_grip;
    UILabel *_title;

    /**
     * Строки лежат в прокручиваемом виде, а не прямо в панели.
     *
     * Раньше они лежали в самой панели, а та обрезала всё, что не влезло:
     * языков восемь десятков, помещалась дюжина, и до остальных было
     * не добраться никак. Список в оригинале тоже прокручивается —
     * там это `ScrollViewer` внутри листа.
     */
    UIScrollView *_list;

    NSMutableArray *_rows;
    void (^_picked)(NSInteger index);
    CGFloat _panelHeight;

    /** Пока лист тянут вниз пальцем, раскладка его не двигает. */
    BOOL _dragging;
    CGRect _place;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    _rows = [NSMutableArray array];

    _backdrop = [[UIView alloc] initWithFrame:CGRectZero];
    [_backdrop setBackgroundColor:[UIColor colorWithWhite:0 alpha:0.4]];
    [self addSubview:_backdrop];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismiss)];

    [_backdrop addGestureRecognizer:tap];

    _panel = [[UIView alloc] initWithFrame:CGRectZero];
    [[_panel layer] setCornerRadius:YTSheetRadius];
    [_panel setClipsToBounds:YES];
    [self addSubview:_panel];

    _grip = [[UIView alloc] initWithFrame:CGRectZero];
    [_grip setBackgroundColor:[UIColor grayColor]];
    [[_grip layer] setCornerRadius:2];
    [_panel addSubview:_grip];

    _title = YTLabel(YTFontSemiBold(15), [YTTheme primaryText], 1);
    [_panel addSubview:_title];

    _list = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [_list setShowsVerticalScrollIndicator:NO];
    [_panel addSubview:_list];

    /**
     * Свайп вниз закрывает лист — так же, как панель настроек у плеера.
     *
     * Тянуть можно за полосу захвата всегда, а за сам список — только
     * когда он домотан доверху: иначе жест закрытия отбирал бы прокрутку
     * у списка, до конца которого ещё листать и листать.
     */
    UIPanGestureRecognizer *drag =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];

    [_panel addGestureRecognizer:drag];

    return self;
}

- (void)dragged:(UIPanGestureRecognizer *)gesture {
    CGFloat shift = [gesture translationInView:self].y;

    if ([gesture state] == UIGestureRecognizerStateBegan) {
        CGFloat where = [gesture locationInView:_panel].y;

        _dragging = (where <= YTSheetGrip) || ([_list contentOffset].y <= 0);
    }

    if (!_dragging) {
        return;
    }

    // Вверх лист не тянется: он и так у края.
    if (shift < 0) {
        shift = 0;
    }

    CGRect moved = _place;

    moved.origin.y += shift;

    [_panel setFrame:moved];

    if ([gesture state] != UIGestureRecognizerStateEnded &&
        [gesture state] != UIGestureRecognizerStateCancelled) {
        return;
    }

    _dragging = NO;

    // Протянули больше трети высоты — закрываем; иначе лист встаёт назад.
    if (shift > _panelHeight / 3) {
        [self dismiss];

        return;
    }

    [UIView animateWithDuration:0.18 animations:^{
        [_panel setFrame:_place];
    }];
}

- (void)showInView:(UIView *)host
             title:(NSString *)title
           options:(NSArray *)titles
          selected:(NSInteger)selected
            picked:(void (^)(NSInteger index))picked {
    _picked = [picked copy];

    [_panel setBackgroundColor:[YTTheme divider]];
    [_title setTextColor:[YTTheme primaryText]];
    [_title setText:title];

    for (UIView *row in _rows) {
        [row removeFromSuperview];
    }

    [_rows removeAllObjects];

    for (NSUInteger i = 0; i < [titles count]; i++) {
        YTTappableView *row = [[YTTappableView alloc] initWithFrame:CGRectZero];

        [row setHighlights:YES];

        UILabel *text = YTLabel(YTFontRegular(14), [YTTheme primaryText], 1);

        [text setText:[titles objectAtIndex:i]];
        [row addSubview:text];

        // `FontIcon Glyph=""` — галочка; в наборе Roboto ей
        // соответствует обычный знак ✓ того же размера 18.
        UILabel *check = YTLabel(YTFontRegular(18), [YTTheme primaryText], 1);

        [check setText:@"✓"];
        [check setTextAlignment:NSTextAlignmentRight];
        [check setHidden:(NSInteger)i != selected];
        [row addSubview:check];

        __weak YTChoiceSheet *weakSelf = self;
        NSInteger index = (NSInteger)i;

        [row setOnTap:^{
            YTChoiceSheet *sheet = weakSelf;

            if (sheet == nil) {
                return;
            }

            void (^chosen)(NSInteger) = sheet->_picked;

            [sheet dismiss];

            if (chosen != nil) {
                chosen(index);
            }
        }];

        [_list addSubview:row];
        [_rows addObject:row];
    }

    /**
     * Высота листа в оригинале задана числом на каждый вид (230 у темы,
     * 430 у языка). Здесь она считается по числу строк и ограничена
     * сверху: языков восемь десятков, и лист во весь экран был бы
     * не листом, а страницей.
     */
    CGFloat content = YTSheetGrip + 20 + 12 + [_rows count] * (YTSheetOption + 2) + 16;
    CGFloat limit = [host bounds].size.height * 0.7;

    _panelHeight = MIN(content, limit);

    [self setFrame:[host bounds]];
    [host addSubview:self];

    [self layoutIfNeeded];

    // Лист выезжает снизу — как `AnimateThemeBottomSheet` в оригинале.
    CGRect target = [_panel frame];
    CGRect start = target;

    start.origin.y = [self bounds].size.height;

    [_panel setFrame:start];
    [_backdrop setAlpha:0];

    [UIView animateWithDuration:0.22 animations:^{
        [_panel setFrame:target];
        [_backdrop setAlpha:1];
    }];
}

- (void)dismiss {
    CGRect gone = [_panel frame];

    gone.origin.y = [self bounds].size.height;

    [UIView animateWithDuration:0.18 animations:^{
        [_panel setFrame:gone];
        [_backdrop setAlpha:0];
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
    }];
}

- (void)layoutSubviews {
    CGRect box = [self bounds];

    [_backdrop setFrame:box];

    CGFloat width = box.size.width - YTSheetSide * 2;

    _place = CGRectMake(YTSheetSide, box.size.height - _panelHeight - YTSheetSide,
                        width, _panelHeight);

    // Пока лист тянут пальцем, место ему задаёт палец, а не раскладка.
    if (!_dragging) {
        [_panel setFrame:_place];
    }

    [_grip setFrame:CGRectMake((width - 38) / 2, YTSheetGrip / 2 - 2, 38, 4)];

    // `Margin="16,0,16,16"` у начинки листа.
    [_title setFrame:CGRectMake(16, YTSheetGrip, width - 32, 20)];

    CGFloat top = YTSheetGrip + 20 + 12;

    // Список занимает всё, что осталось под заголовком, и прокручивается.
    [_list setFrame:CGRectMake(0, top, width, MAX((CGFloat)0, _panelHeight - top - 16))];

    [_list setContentSize:CGSizeMake(width, [_rows count] * (YTSheetOption + 2))];

    for (NSUInteger i = 0; i < [_rows count]; i++) {
        UIView *row = [_rows objectAtIndex:i];

        [row setFrame:CGRectMake(16, i * (YTSheetOption + 2),
                                 width - 32, YTSheetOption)];

        NSArray *parts = [row subviews];

        if ([parts count] == 2) {
            [[parts objectAtIndex:0] setFrame:CGRectMake(0, 0, width - 32 - 30, YTSheetOption)];
            [[parts objectAtIndex:1] setFrame:CGRectMake(width - 32 - 24, 0, 24, YTSheetOption)];
        }
    }
}

@end


#pragma mark - Экран

@implementation YTSettingsViewController {
    UIView *_bar;
    UIButton *_back;

    UIScrollView *_page;
    UILabel *_pageTitle;

    NSMutableArray *_pieces;

    UILabel *_accountSection;
    YTSettingsRow *_poToken;

    /** Поглядывает за состоянием, пока страница открыта. */
    NSTimer *_watch;
    YTSettingsRow *_webLogin;
    YTSettingsRow *_logout;
    YTSettingsRow *_interfaceLanguage;
    YTSettingsRow *_language;
    YTSettingsRow *_theme;
    YTSettingsRow *_appIcon;
    YTSettingsRow *_quality;
    YTSettingsRow *_delivery;
    YTSettingsRow *_thumbnails;
    YTSettingsRow *_sixtyFrames;
    YTSettingsRow *_channelIcons;
    YTSettingsRow *_autoFullscreen;
    YTSettingsRow *_autoplayQueue;
    YTSettingsRow *_autoplayShorts;
    YTSettingsRow *_hideShorts;
    YTSettingsRow *_about;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    if (orientation == UIInterfaceOrientationPortraitUpsideDown) {
        return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad;
    }

    return YES;
}

- (UILabel *)sectionTitled:(NSString *)title {
    UILabel *label = YTLabel(YTFontBold(17), [YTTheme primaryText], 1);

    [label setText:title];
    [_page addSubview:label];
    [_pieces addObject:label];

    return label;
}

- (YTSettingsRow *)rowWithIcon:(NSString *)icon
                         label:(NSString *)label
                        action:(dispatch_block_t)action {
    YTSettingsRow *row = [[YTSettingsRow alloc] initWithFrame:CGRectZero];

    [row setIconName:icon];
    [row setLabelText:label];
    [row setOnTap:action];

    [_page addSubview:row];
    [_pieces addObject:row];

    return row;
}

- (void)loadView {
    YTUseFullScreenLayout(self);

    [super loadView];

    _pieces = [NSMutableArray array];

    [[self view] setBackgroundColor:[YTTheme background]];

    /**
     * Шапка с кнопкой возврата. В оригинале её нет: там Settings — такая же
     * страница с `Navbar` и `Tabbar`, и назад уводит аппаратная кнопка,
     * которой на iPhone не бывает. Стрелка повторяет ту, что стоит в поиске.
     */
    _bar = [[UIView alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_bar];

    _back = [UIButton buttonWithType:UIButtonTypeCustom];
    [[_back titleLabel] setFont:YTFontRegular(24)];
    [_back setTitle:@"‹" forState:UIControlStateNormal];
    [_back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_back];

    _page = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_page];

    _pageTitle = YTLabel(YTFontSemiBold(22), [YTTheme primaryText], 1);
    [_pageTitle setText:YTLoc(@"Настройки")];
    [_page addSubview:_pageTitle];

    [self buildRows];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refresh)
                                                 name:YTThemeChangedNotification
                                               object:nil];
}

/**
 * Собирает строки экрана.
 *
 * Отдельным методом, а не прямо в загрузке вида: после смены языка
 * надписи нужно построить заново, а собраны они здесь все разом.
 */
- (void)buildRows {
    __weak YTSettingsViewController *weakSelf = self;

    /** Аккаунт. */
    _accountSection = [self sectionTitled:YTLoc(@"Аккаунт")];

    /**
     * Вход сеансом браузера — второй, независимый от входа по коду.
     *
     * Он нужен там, где кода мало: `/player` отдаёт потоки только тому,
     * кто выглядит как вошедший браузер. Поэтому строка стоит отдельно
     * и своё состояние показывает сама.
     */
    _webLogin = [self rowWithIcon:@"qr" label:YTLoc(@"Вход в браузере") action:^{
        [weakSelf toggleWebLogin];
    }];

    /**
     * Второй вход, и его назначение стоит объяснить прямо здесь.
     *
     * Учётную запись открывает QR-код, и всё, что её требует, идёт по
     * нему. Этот вход — про другое: он оставляет куки, которыми запросы
     * доказывают, что идут от человека. Без них YouTube время от времени
     * упирается в проверку «вы не робот» и ролик не отдаёт вовсе.
     */
    [_webLogin setHintText:YTLoc(@"Нужен, когда YouTube упирается в проверку "
                                 @"«вы не робот». Вход по QR-коду её не снимает")];

    _logout = [self rowWithIcon:@"log_out" label:YTLoc(@"Выйти") action:^{
        [weakSelf signOut];
    }];

    /** Язык. */
    [self sectionTitled:YTLoc(@"Язык")];

    /**
     * Языков здесь два, и они про разное.
     *
     * Верхний — надписи самого приложения; нижний уходит в `hl` и решает,
     * на каком языке YouTube пришлёт названия роликов и подписи вроде
     * «3 часа назад». Их держат порознь намеренно: смотреть с русскими
     * подписями, а приложение видеть на английском — обычное желание.
     */
    _interfaceLanguage = [self rowWithIcon:@"languages"
                                     label:YTLoc(@"Язык приложения")
                                    action:^{
        [weakSelf pickInterfaceLanguage];
    }];

    [_interfaceLanguage setHintText:YTLoc(@"Надписи на экранах")];

    _language = [self rowWithIcon:@"languages"
                            label:YTLoc(@"Язык YouTube")
                           action:^{
        [weakSelf pickLanguage];
    }];

    [_language setHintText:YTLoc(@"Названия роликов и подписи из ответов")];

    /** Оформление. */
    [self sectionTitled:YTLoc(@"Оформление")];

    _theme = [self rowWithIcon:@"theme" label:YTLoc(@"Тема") action:^{
        [weakSelf pickTheme];
    }];

    /**
     * Значок и название на рабочем столе — своим экраном: там и выбор
     * темы, и поле для имени.
     */
    _appIcon = [self rowWithIcon:@"theme"
                           label:YTLoc(@"Значок приложения")
                          action:^{
        [YTNav push:[[YTAppIconViewController alloc] init]];
    }];

    [_appIcon setHintText:YTLoc(@"Значок из темы Anemone и своё название")];

    /** Видео. */
    [self sectionTitled:YTLoc(@"Видео")];

    _quality = [self rowWithIcon:@"pl_quality" label:YTLoc(@"Предпочитаемое качество") action:^{
        [weakSelf pickQuality];
    }];

    /**
     * Шестьдесят кадров — переключателем, а не запретом.
     *
     * На A4 и A5 такие дорожки обычно рвутся, и по умолчанию мы их
     * обходим. Но «обычно» — не «всегда»: короткий ролик в 720p60
     * старая четвёрка иногда тянет, и решать это за человека незачем.
     * На устройствах посвежее переключатель тоже есть — им бывает
     * полезно обратное, сбавить ради батареи.
     */
    _sixtyFrames = [self rowWithIcon:@"pl_quality"
                               label:YTLoc(@"Шестьдесят кадров")
                              action:^{
        [YTSettings setAllowsSixtyFrames:![YTSettings allowsSixtyFrames]];
        [weakSelf refresh];
    }];

    [_sixtyFrames setHintText:[YTSettings prefersThirtyByDevice]
        ? YTLoc(@"Плавные дорожки; на этом устройстве обычно рвутся, "
                @"поэтому по умолчанию берутся тридцать")
        : YTLoc(@"Брать плавные дорожки, когда они у ролика есть")];

    [_sixtyFrames useToggle];

    _delivery = [self rowWithIcon:@"pl_quality" label:YTLoc(@"Способ воспроизведения")
                           action:^{
        [weakSelf pickDelivery];
    }];

    _thumbnails = [self rowWithIcon:@"pl_quality" label:YTLoc(@"Качество превью") action:^{
        [weakSelf pickThumbnails];
    }];

    _channelIcons = [self rowWithIcon:@"tab_you" label:YTLoc(@"Значки каналов") action:^{
        [YTSettings setShowsChannelIcons:![YTSettings showsChannelIcons]];
        [weakSelf refresh];
    }];

    [_channelIcons setHintText:YTLoc(@"Кружок автора на карточках")];
    [_channelIcons useToggle];

    _autoFullscreen = [self rowWithIcon:@"pl_fullscreen"
                                  label:YTLoc(@"Полный экран при повороте")
                                 action:^{
        [YTSettings setAutoFullscreenInLandscape:![YTSettings autoFullscreenInLandscape]];
        [weakSelf refresh];
    }];

    [_autoFullscreen setHintText:YTLoc(@"Разворачивать кадр, когда телефон повернули")];
    [_autoFullscreen useToggle];

    _autoplayQueue = [self rowWithIcon:@"pl_skip"
                                 label:YTLoc(@"Следующий в плейлисте")
                                action:^{
        [YTSettings setAutoplayNextInQueue:![YTSettings autoplayNextInQueue]];
        [weakSelf refresh];
    }];

    [_autoplayQueue setHintText:YTLoc(@"Включать следующий ролик, когда нынешний доиграл")];
    [_autoplayQueue useToggle];

    _autoplayShorts = [self rowWithIcon:@"tab_shorts"
                                  label:YTLoc(@"Следующий Shorts")
                                 action:^{
        [YTSettings setAutoplayNextShort:![YTSettings autoplayNextShort]];
        [weakSelf refresh];
    }];

    [_autoplayShorts setHintText:YTLoc(@"Листать самому, когда ролик доиграл; иначе он повторяется")];
    [_autoplayShorts useToggle];

    _hideShorts = [self rowWithIcon:@"tab_shorts"
                              label:YTLoc(@"Скрыть Shorts")
                             action:^{
        [YTSettings setHidesShorts:![YTSettings hidesShorts]];
        [weakSelf refresh];
    }];

    [_hideShorts setHintText:YTLoc(@"Убрать вкладку, таблетку в поиске и вертикальные "
                                   @"ролики из всех лент")];
    [_hideShorts useToggle];

    /** О программе. */
    [self sectionTitled:YTLoc(@"О программе")];

    _about = [self rowWithIcon:@"info" label:YTLoc(@"Сведения") action:^{
        [YTNav push:[[YTAboutViewController alloc] init]];
    }];

    /**
     * Выдача PO-токена — не настройка, а инструмент, и стоит он здесь
     * потому, что это единственное место, куда можно нажать осознанно.
     * Обычно подготовка идёт сама, перед первым роликом; отсюда её можно
     * запустить руками и посмотреть по журналу, чем кончилось.
     */
    _poToken = [self rowWithIcon:@"info" label:YTLoc(@"PO-токен") action:^{
        [[YTPoToken shared] prepare];
    }];

    [self refresh];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)goBack {
    NSLog(@"[YouTube/Настройки] Назад");

    [YTNav pop];
}

#pragma mark Состояние

/**
 * Пока страница открыта, две строки поглядываем: вход в сеть и PO-токен.
 *
 * Обе показывают не настройку, а состояние, и оно меняется само:
 * чеканщик поднимается несколько секунд после запуска. Прежде значение
 * ставилось один раз, при сборке страницы, — и человек, зашедший сюда
 * сразу после запуска, навсегда видел «PO-токен: нет», хотя тот давно
 * готов. Раз в секунду — не расход: два обращения к полю.
 */
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    [self refreshLive];

    [_watch invalidate];

    _watch = [NSTimer scheduledTimerWithTimeInterval:1.0
                                              target:self
                                            selector:@selector(refreshLive)
                                            userInfo:nil
                                             repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];

    [_watch invalidate];

    _watch = nil;
}

- (void)refreshLive {
    [_webLogin setValueText:[YTWebAuth isSignedIn] ? YTLoc(@"Выполнен") : YTLoc(@"Нет")];
    [_poToken setValueText:[[YTPoToken shared] isReady] ? YTLoc(@"Готов") : YTLoc(@"Нет")];
}

- (void)refresh {
    [[self view] setBackgroundColor:[YTTheme background]];
    [_bar setBackgroundColor:[YTTheme background]];
    [_page setBackgroundColor:[YTTheme background]];

    [_back setTitleColor:[YTTheme primaryText] forState:UIControlStateNormal];
    [_pageTitle setTextColor:[YTTheme primaryText]];

    for (id piece in _pieces) {
        if ([piece isKindOfClass:[UILabel class]]) {
            [(UILabel *)piece setTextColor:[YTTheme primaryText]];
        } else {
            [(YTSettingsRow *)piece applyTheme];
        }
    }

    // Выход показывается только вошедшему — вместе со своим заголовком:
    // раздел из одного пункта, и без пункта в нём ничего не остаётся.
    BOOL signedIn = [YTAuth isSignedIn];

    [_logout setHidden:!signedIn];

    // Раздел виден, если есть хоть один вход — или если можно войти.
    [_accountSection setHidden:NO];

    [_webLogin setValueText:[YTWebAuth isSignedIn] ? YTLoc(@"Выполнен") : YTLoc(@"Нет")];
    [_poToken setValueText:[[YTPoToken shared] isReady] ? YTLoc(@"Готов") : YTLoc(@"Нет")];

    [_language setValueText:[YTSettings languageTitle:[YTSettings language]]];
    [_interfaceLanguage setValueText:[self interfaceLanguageTitle]];
    [_theme setValueText:[YTTheme titleForMode:[YTTheme mode]]];
    [_quality setValueText:[YTSettings qualityTitle:[YTSettings preferredHeight]]];
    [_delivery setValueText:[YTSettings deliveryTitle:[YTSettings delivery]]];

    // Подсказка меняется вместе с выбором: разница между путями
    // не та вещь, которую стоит угадывать по названию.
    [_delivery setHintText:[YTSettings deliveryHint:[YTSettings delivery]]];
    [_thumbnails setValueText:[YTSettings thumbnailTitle:[YTSettings thumbnailWidth]]];

    [_sixtyFrames setToggleOn:[YTSettings allowsSixtyFrames]];
    [_channelIcons setToggleOn:[YTSettings showsChannelIcons]];
    [_autoFullscreen setToggleOn:[YTSettings autoFullscreenInLandscape]];
    [_autoplayQueue setToggleOn:[YTSettings autoplayNextInQueue]];
    [_autoplayShorts setToggleOn:[YTSettings autoplayNextShort]];
    [_hideShorts setToggleOn:[YTSettings hidesShorts]];

    /**
     * Спрятали Shorts — прячем и настройку их автолистания: она
     * относится к разделу, которого больше нет, и висела бы пунктом,
     * ничего не меняющим.
     */
    [_autoplayShorts setHidden:[YTSettings hidesShorts]];

    [[self view] setNeedsLayout];
}

#pragma mark Действия

- (void)signOut {
    [YTAuth signOut];
    [self refresh];
}

/** Входит сеансом браузера либо выходит из него. */
/**
 * Смена значка и названия.
 *
 * Работу делает помощник с правами root, а `uicache` зовётся уже от нас:
 * список приложений у каждого пользователя свой. Даже после него
 * SpringBoard иногда держит прежний значок в своём кеше — оттого
 * и предложение перезапустить оболочку.
 */
- (void)toggleWebLogin {
    if ([YTWebAuth isSignedIn]) {
        [YTWebAuth signOut];
        [self refresh];

        return;
    }

    __weak YTSettingsViewController *weakSelf = self;

    [YTNav push:[[YTChallengeViewController alloc] initForLoginWithDone:^{
        [weakSelf refresh];
    }]];
}

- (YTChoiceSheet *)sheet {
    return [[YTChoiceSheet alloc] initWithFrame:CGRectZero];
}

/**
 * Выбор языка надписей.
 *
 * После выбора экран настроек собирается заново — надписи на нём меняются
 * тут же. Остальные экраны берут новый язык, когда их открывают снова:
 * они строят свои подписи при рождении, и переписывать их на лету значило
 * бы держать ссылку на каждую из них. Полностью — после перезапуска.
 */
/** Название выбранного языка надписей; для «как в системе» — так и сказано. */
- (NSString *)interfaceLanguageTitle {
    NSString *chosen = [YTSettings interfaceLanguage];

    if ([chosen length] == 0) {
        return YTLoc(@"Как в системе");
    }

    for (NSDictionary *language in [YTStrings languages]) {
        if ([[language objectForKey:@"code"] isEqualToString:chosen]) {
            return [language objectForKey:@"title"];
        }
    }

    return chosen;
}

/** Собирает экран заново — после смены языка надписей. */
- (void)rebuild {
    for (id piece in _pieces) {
        [(UIView *)piece removeFromSuperview];
    }

    [_pieces removeAllObjects];

    [_pageTitle setText:YTLoc(@"Настройки")];

    [self buildRows];
    [[self view] setNeedsLayout];
}

- (void)pickInterfaceLanguage {
    NSArray *options = [YTStrings languages];

    NSMutableArray *titles = [NSMutableArray arrayWithObject:YTLoc(@"Как в системе")];
    NSMutableArray *codes = [NSMutableArray arrayWithObject:@""];

    for (NSDictionary *option in options) {
        [titles addObject:[option objectForKey:@"title"]];
        [codes addObject:[option objectForKey:@"code"]];
    }

    NSUInteger found = [codes indexOfObject:[YTSettings interfaceLanguage]];
    NSInteger selected = (found == NSNotFound) ? 0 : (NSInteger)found;

    [[self sheet] showInView:[self view]
                       title:YTLoc(@"Язык приложения")
                     options:titles
                    selected:selected
                      picked:^(NSInteger index) {
        [YTSettings setInterfaceLanguage:[codes objectAtIndex:index]];

        // Таблица перевода забывается — следующий `YTLoc` возьмёт новую.
        [YTStrings reset];

        [self rebuild];
    }];
}

- (void)pickLanguage {
    NSArray *options = [YTSettings languageOptions];

    NSMutableArray *titles = [NSMutableArray arrayWithObject:YTLoc(@"Как в системе")];
    NSMutableArray *codes = [NSMutableArray arrayWithObject:@""];

    for (NSDictionary *option in options) {
        [titles addObject:[option objectForKey:@"title"]];
        [codes addObject:[option objectForKey:@"code"]];
    }

    NSUInteger found = [codes indexOfObject:[YTSettings language]];
    NSInteger selected = (found == NSNotFound) ? 0 : (NSInteger)found;

    [[self sheet] showInView:[self view]
                       title:YTLoc(@"Язык YouTube")
                     options:titles
                    selected:selected
                      picked:^(NSInteger index) {
        [YTSettings setLanguage:[codes objectAtIndex:index]];
        [self refresh];
    }];
}

- (void)pickTheme {
    NSArray *modes = [NSArray arrayWithObjects:
        YTThemeSystem, YTThemeLight, YTThemeDark, nil];

    NSMutableArray *titles = [NSMutableArray array];

    for (NSString *mode in modes) {
        [titles addObject:[YTTheme titleForMode:mode]];
    }

    NSUInteger found = [modes indexOfObject:[YTTheme mode]];
    NSInteger selected = (found == NSNotFound) ? 0 : (NSInteger)found;

    [[self sheet] showInView:[self view]
                       title:YTLoc(@"Тема")
                     options:titles
                    selected:selected
                      picked:^(NSInteger index) {
        [YTTheme setMode:[modes objectAtIndex:index]];
        [self refresh];
    }];
}

- (void)pickQuality {
    NSArray *heights = [YTSettings qualityOptions];
    NSMutableArray *titles = [NSMutableArray array];

    for (NSNumber *height in heights) {
        NSString *title = [YTSettings qualityTitle:[height integerValue]];

        /**
         * Ступени выше меры устройства помечаются, но остаются в списке:
         * запрещать выбор незачем — на A4 они дадут звук без картинки,
         * а на аппарате посвежее пойдут прекрасно.
         */
        if ([YTStreams isBeyondDevice:[height integerValue]]) {
            title = [title stringByAppendingString:YTLoc(@" — может не пойти")];
        }

        [titles addObject:title];
    }

    NSUInteger found = [heights indexOfObject:
        [NSNumber numberWithInteger:[YTSettings preferredHeight]]];

    NSInteger selected = (found == NSNotFound) ? 0 : (NSInteger)found;

    [[self sheet] showInView:[self view]
                       title:YTLoc(@"Качество")
                     options:titles
                    selected:selected
                      picked:^(NSInteger index) {
        [YTSettings setPreferredHeight:[[heights objectAtIndex:index] integerValue]];
        [self refresh];
    }];
}

/**
 * Выбор пути. Подсказка про каждый — прямо в списке: без неё выбирать
 * пришлось бы наугад, а разница между путями не в громкости и не в цвете.
 */
- (void)pickDelivery {
    NSArray *ways = [YTSettings deliveryOptions];
    NSMutableArray *titles = [NSMutableArray array];

    for (NSNumber *way in ways) {
        [titles addObject:[YTSettings deliveryTitle:[way integerValue]]];
    }

    NSUInteger found = [ways indexOfObject:
        [NSNumber numberWithInteger:[YTSettings delivery]]];

    NSInteger selected = (found == NSNotFound) ? 0 : (NSInteger)found;

    [[self sheet] showInView:[self view]
                       title:YTLoc(@"Способ воспроизведения")
                     options:titles
                    selected:selected
                      picked:^(NSInteger index) {
        [YTSettings setDelivery:[[ways objectAtIndex:index] integerValue]];
        [self refresh];
    }];
}

- (void)pickThumbnails {
    NSArray *widths = [YTSettings thumbnailOptions];
    NSMutableArray *titles = [NSMutableArray array];

    for (NSNumber *width in widths) {
        [titles addObject:[YTSettings thumbnailTitle:[width integerValue]]];
    }

    NSUInteger found = [widths indexOfObject:
        [NSNumber numberWithInteger:[YTSettings thumbnailWidth]]];

    NSInteger selected = (found == NSNotFound) ? 0 : (NSInteger)found;

    [[self sheet] showInView:[self view]
                       title:YTLoc(@"Качество превью")
                     options:titles
                    selected:selected
                      picked:^(NSInteger index) {
        [YTSettings setThumbnailWidth:[[widths objectAtIndex:index] integerValue]];
        [self refresh];
    }];
}


#pragma mark Раскладка

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];

    CGRect box = [[self view] bounds];
    CGFloat top = YTStatusBarHeight();

    [_bar setFrame:CGRectMake(0, top, box.size.width, YTNavBarHeight)];
    [_back setFrame:CGRectMake(4, 8, 40, 40)];

    CGFloat contentTop = top + YTNavBarHeight;

    [_page setFrame:CGRectMake(0, contentTop, box.size.width,
                               box.size.height - contentTop)];

    CGFloat width = box.size.width;

    // `Padding="0,12,0,82"` у содержимого.
    CGFloat y = 12;

    [_pageTitle setFrame:CGRectMake(YTSetSide, y, width - YTSetSide * 2, 28)];

    y += 28 + YTSetSectionTop;

    BOOL first = YES;

    for (id piece in _pieces) {
        if ([piece isKindOfClass:[UILabel class]]) {
            UILabel *section = piece;

            if ([section isHidden]) {
                [section setFrame:CGRectZero];
                continue;
            }

            // У первого раздела верхнего отступа нет: `Margin="18,0,18,10"`.
            if (!first) {
                y += YTSetSectionTop;
            }

            [section setFrame:CGRectMake(YTSetSide, y, width - YTSetSide * 2, 22)];

            y += 22 + YTSetSectionBottom;
            first = NO;

            continue;
        }

        YTSettingsRow *row = piece;

        if ([row isHidden]) {
            continue;
        }

        CGFloat height = [row preferredHeight];

        [row setFrame:CGRectMake(0, y, width, height)];

        y += height;
    }

    [_page setContentSize:CGSizeMake(width, y + 82)];
}

@end
