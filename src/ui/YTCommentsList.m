#import "YTSimpleScreens.h"

#import "YTStrings.h"

#import <QuartzCore/QuartzCore.h>

#import "YTApi.h"
#import "YTAuth.h"
#import "YTWebAuth.h"
#import "YTImageLoader.h"
#import "YTMetrics.h"
#import "YTRoundedImageView.h"
#import "YTSettingsSheet.h"
#import "YTTheme.h"
#import "YTUtil.h"

/**
 * Числа панели — из `CommentsBottomSheetPanel` в Video.xaml.
 *
 * Панель прижата к низу, подложка `AppDividerBrush`, скругление 15,
 * высота 400, отступы 10 по бокам и 6 снизу. Выезжает снизу: в разметке
 * у неё `TranslateTransform Y="410"`, то есть спрятана она чуть ниже
 * собственной высоты.
 */
static const CGFloat YTSheetHeight = 400;
static const CGFloat YTSheetSide = 10;
static const CGFloat YTSheetBottom = 6;
static const CGFloat YTSheetRadius = 15;

/** Полоса захвата: сама область 40 в высоту, ручка 40×4. */
static const CGFloat YTSheetGrip = 40;

/**
 * Поле ввода под списком — по образцу нынешнего YouTube для iOS.
 *
 * В UWP-оригинале его нет вовсе: та версия комментарии только читает,
 * и переносить оттуда нечего. Поэтому вид взят у современного клиента,
 * где строка устроена так: кружок автора, за ним поле-«таблетка» во всю
 * оставшуюся ширину, а справа — стрелка отправки, и появляется она
 * только когда есть что отправлять.
 *
 * Числа: кружок 32, строка 36 с полями по 8, скругление в половину
 * высоты (таблетка), стрелка 32×32. Над строкой — волосяная черта,
 * отделяющая её от списка.
 */
static const CGFloat YTComposerAvatar = 32;
static const CGFloat YTComposerRow = 36;
static const CGFloat YTComposerPad = 8;
static const CGFloat YTComposerHeight = YTComposerRow + YTComposerPad * 2;
static const CGFloat YTComposerGap = 10;
static const CGFloat YTComposerSend = 32;

/** Отступ текста внутри таблетки. */
static const CGFloat YTComposerInset = 14;


#pragma mark - Строка комментария

/**
 * Раскладка из шаблона панели: кружок 36 с отступом 10 сверху,
 * автор жирным цветом secondary, время 12 muted с отступом 8,
 * текст 14 с отступом 4 сверху, перенос по словам. Между строками
 * `Margin="0,10,0,10"`.
 */
@interface YTCommentCell : UITableViewCell

+ (CGFloat)heightFor:(NSDictionary *)comment width:(CGFloat)width;

- (void)bind:(NSDictionary *)comment;

@end

@implementation YTCommentCell {
    YTRoundedImageView *_avatar;
    UILabel *_author;
    UILabel *_time;
    UILabel *_text;

    /** Ответ ли это и не строка ли это «Ответы (N)». */
    BOOL _reply;
    BOOL _repliesRow;

    /** Запись чата — узкая строка одной лентой. */
    BOOL _chat;
}

/** Отступ ответа от левого края — на ширину кружка с зазором. */
static const CGFloat YTReplyIndent = 30;

/** Строка «Ответы (N)» и сами ответы помечены в записи этими ключами. */
static NSString *const YTRepliesRowKey = @"repliesRow";
static NSString *const YTReplyKey = @"isReply";

/**
 * Продолжение ветки — стоит у последнего привезённого ответа.
 *
 * Ветка приезжает страницами, как и сам перечень. Метку следующей
 * страницы держит хвостовой ответ: показался он — значит, ветку читают,
 * и остальные ответы нужны. Так ветка догружается прокруткой, а не
 * обрывается на первой пачке.
 */
static NSString *const YTMoreRepliesKey = @"moreReplies";

/** Запись чата: у неё своя, узкая строка. */
static NSString *const YTChatKey = @"isChat";

/**
 * Строка чата: имя и текст идут одной лентой, как в оригинале.
 *
 * Имя серым, текст обычным цветом — но одной строкой, чтобы перенос уходил
 * под имя, а не под текст. На iOS 6 и новее это делает `attributedText`;
 * на пятой его нет, и там строка выходит одноцветной. Заводить ради этого
 * два ярлыка нельзя: тогда перенос ляжет иначе, и лента развалится.
 */
+ (id)chatLine:(NSDictionary *)item font:(UIFont *)font {
    NSString *author = [item objectForKey:@"author"] ?: @"";
    NSString *text = [item objectForKey:@"text"] ?: @"";
    NSString *whole = [NSString stringWithFormat:@"%@  %@", author, text];

    if (![UILabel instancesRespondToSelector:@selector(setAttributedText:)]) {
        return whole;
    }

    NSMutableAttributedString *line =
        [[NSMutableAttributedString alloc] initWithString:whole];

    [line addAttribute:NSFontAttributeName value:font
                 range:NSMakeRange(0, [whole length])];

    [line addAttribute:NSForegroundColorAttributeName value:[YTTheme primaryText]
                 range:NSMakeRange(0, [whole length])];

    [line addAttribute:NSForegroundColorAttributeName value:[YTTheme secondaryText]
                 range:NSMakeRange(0, [author length])];

    return line;
}

+ (NSString *)chatPlainLine:(NSDictionary *)item {
    return [NSString stringWithFormat:@"%@  %@",
        ([item objectForKey:@"author"] ?: @""),
        ([item objectForKey:@"text"] ?: @"")];
}

+ (CGFloat)textWidthFor:(CGFloat)width {
    // Ширина панели минус её поля (16 слева и справа) и колонка кружка.
    return width - 32 - 36 - 10;
}

+ (CGFloat)textWidthFor:(CGFloat)width reply:(BOOL)reply {
    return [self textWidthFor:width] - (reply ? YTReplyIndent : 0);
}

+ (CGFloat)heightFor:(NSDictionary *)comment width:(CGFloat)width {
    /**
     * Строка чата низкая: кружок 24, лента текста и по шесть точек полей.
     * У комментария строка выше — там имя стоит отдельной строкой над
     * текстом, а здесь всё в одну ленту.
     */
    if ([comment objectForKey:YTChatKey] != nil) {
        CGFloat room = width - 32 - 24 - 8;

        CGFloat textHeight = YTTextHeight([self chatPlainLine:comment],
                                          YTFontRegular(14), room, 8);

        return MAX(24, textHeight) + 12;
    }

    // Строка «Ответы (N)» — одна строка текста с полями.
    if ([comment objectForKey:YTRepliesRowKey] != nil) {
        return ceil([YTFontSemiBold(13) lineHeight]) + 16;
    }

    CGFloat authorHeight = ceil([YTFontBold(15) lineHeight]);

    /**
     * Двенадцать строк, а не сколько придёт.
     *
     * Высота меряется через CoreText, и без ограничения одно полотно
     * в несколько тысяч знаков считается секундами — приложение при этом
     * снимается системой по таймауту. В оригинале ограничения нет, но там
     * раскладка текста дешевле.
     */
    BOOL reply = ([comment objectForKey:YTReplyKey] != nil);

    CGFloat textHeight = YTTextHeight([comment objectForKey:@"text"],
                                      YTFontRegular(14),
                                      [self textWidthFor:width reply:reply], 12);

    CGFloat block = MAX(36, authorHeight + 4 + textHeight);

    return 10 + block + 10;
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    self = [super initWithStyle:style reuseIdentifier:identifier];

    if (self == nil) {
        return nil;
    }

    [self setSelectionStyle:UITableViewCellSelectionStyleNone];
    [self setBackgroundColor:[UIColor clearColor]];
    [[self contentView] setBackgroundColor:[UIColor clearColor]];

    // Ячейку таблица создаёт с высотой по умолчанию и лишь потом выдаёт
    // настоящую; обрезка по краям съела бы текст, оказавшийся ниже.
    [self setClipsToBounds:NO];
    [[self contentView] setClipsToBounds:NO];

    _avatar = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];
    [_avatar setCircular:YES];
    [[self contentView] addSubview:_avatar];

    _author = YTLabel(YTFontBold(15), [YTTheme secondaryText], 1);
    [[self contentView] addSubview:_author];

    _time = YTLabel(YTFontRegular(12), [YTTheme mutedText], 1);
    [_time setTextAlignment:NSTextAlignmentRight];
    [[self contentView] addSubview:_time];

    _text = YTLabel(YTFontRegular(14), [YTTheme primaryText], 12);
    [[self contentView] addSubview:_text];

    return self;
}

- (void)bind:(NSDictionary *)comment {
    // Цвета берутся при каждой привязке: ячейки переживают смену темы.
    [_avatar setPlaceholderColor:[YTTheme avatarPlaceholder]];
    [_author setTextColor:[YTTheme secondaryText]];
    [_time setTextColor:[YTTheme mutedText]];
    [_text setTextColor:[YTTheme primaryText]];

    _reply = ([comment objectForKey:YTReplyKey] != nil);
    _repliesRow = ([comment objectForKey:YTRepliesRowKey] != nil);
    _chat = ([comment objectForKey:YTChatKey] != nil);

    /**
     * Чат: кружок поменьше, имени и времени отдельной строкой нет —
     * всё уходит в одну ленту, как в оригинале.
     */
    if (_chat) {
        [_avatar setHidden:NO];
        [_author setHidden:YES];
        [_time setHidden:YES];
        [_text setHidden:NO];

        [_text setFont:YTFontRegular(14)];
        [_text setNumberOfLines:8];

        id line = [[self class] chatLine:comment font:YTFontRegular(14)];

        if ([line isKindOfClass:[NSString class]]) {
            [_text setText:line];
        } else {
            [_text setAttributedText:line];
        }

        NSString *avatar = [comment objectForKey:@"avatar"];

        [_avatar setImage:nil];

        if ([avatar length] > 0) {
            [YTImageLoader loadInto:_avatar url:avatar targetWidth:24];
        }

        [self setNeedsLayout];

        return;
    }

    /**
     * Строка ветки — одна подпись синим цветом ссылки, без кружка
     * и времени. Отдельного класса ячейки ради неё заводить не стали:
     * поля те же, разница только в том, что показано.
     */
    if (_repliesRow) {
        [_avatar setHidden:YES];
        [_time setHidden:YES];
        [_text setHidden:YES];

        [_author setHidden:NO];
        [_author setFont:YTFontSemiBold(13)];
        [_author setTextColor:[YTTheme accentBlue]];
        [_author setText:[comment objectForKey:@"title"]];

        [self setNeedsLayout];

        return;
    }

    [_avatar setHidden:NO];
    [_time setHidden:NO];
    [_text setHidden:NO];

    [_author setFont:YTFontBold(15)];

    [_author setText:[comment objectForKey:@"author"]];
    [_time setText:[comment objectForKey:@"published"]];
    [_text setText:[comment objectForKey:@"text"]];

    [YTImageLoader loadInto:_avatar
                        url:[comment objectForKey:@"avatar"]
                targetWidth:36];

    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat width = [[self contentView] bounds].size.width;

    if (width <= 0) {
        return;
    }

    CGFloat authorHeight = ceil([[_author font] lineHeight]);

    if (_chat) {
        CGFloat room = width - 32 - 24 - 8;

        [_avatar setFrame:CGRectMake(16, 6, 24, 24)];

        [_text setFrame:CGRectMake(16 + 24 + 8, 6, room,
                                   [self bounds].size.height - 12)];

        return;
    }

    if (_repliesRow) {
        [_author setFrame:CGRectMake(YTReplyIndent, 8,
                                     width - YTReplyIndent, authorHeight)];

        return;
    }

    CGFloat indent = _reply ? YTReplyIndent : 0;
    CGFloat textWidth = [[self class] textWidthFor:width + 32 reply:_reply];
    CGFloat left = indent + 36 + 10;
    CGFloat timeWidth = 90;

    [_avatar setFrame:CGRectMake(indent, 10, 36, 36)];

    [_author setFrame:CGRectMake(left, 10, textWidth - timeWidth - 8, authorHeight)];
    [_time setFrame:CGRectMake(left + textWidth - timeWidth, 10, timeWidth, authorHeight)];

    CGFloat textHeight = YTTextHeight([_text text], [_text font], textWidth, 12);

    [_text setFrame:CGRectMake(left, 10 + authorHeight + 4, textWidth, textHeight)];
}

@end


#pragma mark - Панель

@interface YTCommentsSheet () <UITableViewDataSource, UITableViewDelegate,
                               UIGestureRecognizerDelegate, UITextFieldDelegate>
@end

@implementation YTCommentsSheet {
    UIView *_panel;
    UIView *_grip;
    YTTappableView *_gripArea;
    UITableView *_table;
    YTStatusView *_status;

    /** Поле ввода с кнопкой — показывается, только если писать дают. */
    UIView *_composer;
    UIView *_composerLine;
    YTRoundedImageView *_composerAvatar;
    UIView *_pill;
    YTTextField *_input;
    UIButton *_send;

    /** Кружок свой, и берётся он один раз за сеанс панели. */
    BOOL _avatarAsked;

    /** Ролик и метка, которой сервер разрешает в него писать. */
    NSString *_videoId;
    NSString *_createParams;

    /** Идёт отправка — второе нажатие не принимаем. */
    BOOL _sending;

    /** Говорили ли уже про вход в браузере — раз за открытие панели. */
    BOOL _warnedAboutLogin;

    /** Насколько панель поднята клавиатурой. */
    CGFloat _keyboardLift;

    NSString *_token;

    NSMutableArray *_items;

    /** Чат трансляции: метка следующей страницы и таймер опроса. */
    NSString *_chatToken;
    NSTimer *_chatTimer;

    /** Шапка чата: заголовок, счётчик зрителей, выбор фильтра и крестик. */
    UILabel *_heading;
    UILabel *_viewers;
    UIButton *_filterButton;
    UIButton *_closeButton;

    /** Закреплённое сообщение над списком. */
    UIView *_banner;
    UILabel *_bannerText;

    /** Метки фильтров и какой сейчас выбран. */
    NSArray *_chatFilters;
    NSUInteger _chatFilter;
    YTPager *_pager;
    YTGeneration *_generation;

    /** Высоты считаются один раз и держатся здесь. */
    NSMutableArray *_heights;
    CGFloat _measuredWidth;

    /** Идёт ли сейчас загрузка ветки — второе нажатие не принимаем. */
    BOOL _loadingReplies;

    /** Место панели в покое и признак того, что её сейчас тянут. */
    CGRect _place;
    BOOL _dragging;

    /** Нажатие мимо панели — его и только его отбирает делегат. */
    UITapGestureRecognizer *_tap;

    /**
     * Что сейчас пишут: новый комментарий, ответ или правку своего.
     *
     * Строка ввода одна на все три — как и в нынешнем клиенте, где
     * ответ пишется в том же поле, только над ним появляется полоска
     * «отвечаете такому-то». Заводить второе поле незачем: разговор
     * с сервером у них разный, а набор текста один и тот же.
     */
    NSInteger _mode;
    NSString *_modeParams;
    NSDictionary *_modeItem;

    /** Полоска над полем: что делаем и как это отменить. */
    UIView *_modeBar;
    UILabel *_modeLabel;
    UIButton *_modeCancel;

    /** Лист «ответить/изменить» и запись, ради которой он открыт. */
    YTSettingsSheet *_actions;

    BOOL _open;
}

/** Значения `_mode`. */
enum {
    YTComposeNew = 0,
    YTComposeReply = 1,
    YTComposeEdit = 2
};

/** Высота полоски над полем — она есть только в режиме ответа и правки. */
static const CGFloat YTComposerModeBar = 26;

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    _items = [NSMutableArray array];

    _heights = [NSMutableArray array];
    _pager = [[YTPager alloc] init];
    _generation = [[YTGeneration alloc] init];

    [self setHidden:YES];

    // Подложка прозрачная: панель занимает низ, а кадр над ней остаётся
    // видимым и играет — в оригинале так же.
    [self setBackgroundColor:[UIColor clearColor]];

    _panel = [[UIView alloc] initWithFrame:CGRectZero];
    [_panel setBackgroundColor:[YTTheme divider]];
    [[_panel layer] setCornerRadius:YTSheetRadius];
    [_panel setClipsToBounds:YES];
    [self addSubview:_panel];

    __weak YTCommentsSheet *weakSelf = self;

    /**
     * Оснастка чата ставится **после** самой панели, а не до неё.
     *
     * Стояла до — и это была прямая ошибка: `addSubview:` звался у ещё
     * не созданного `_panel`, то есть у nil. Objective-C на такое молчит,
     * и заголовок, счётчик, фильтр, крестик и закреплённое сообщение
     * просто не попадали на экран ни в одной сборке. Место под шапку
     * раскладка при этом отводила — отсюда пустая полоса под ручкой
     * и срезанная первая запись.
     */
    _heading = YTLabel(YTFontBold(17), [YTTheme primaryText], 1);
    [_heading setHidden:YES];
    [_panel addSubview:_heading];

    _viewers = YTLabel(YTFontRegular(13), [YTTheme mutedText], 1);
    [_viewers setHidden:YES];
    [_panel addSubview:_viewers];

    /**
     * Фильтр — это подзаголовок под словом «Чат», как в оригинале:
     * «Все сообщения · 1,9 тыс.». Отдельной широкой кнопки там нет,
     * и заводить её значит городить своё поверх знакомого вида.
     */
    _filterButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [[_filterButton titleLabel] setFont:YTFontRegular(13)];
    [_filterButton setTitleColor:[YTTheme secondaryText] forState:UIControlStateNormal];
    [[_filterButton titleLabel] setTextAlignment:NSTextAlignmentLeft];
    [_filterButton setContentHorizontalAlignment:UIControlContentHorizontalAlignmentLeft];
    [_filterButton addTarget:self
                      action:@selector(switchChatFilter)
            forControlEvents:UIControlEventTouchUpInside];
    [_filterButton setHidden:YES];
    [_panel addSubview:_filterButton];

    _closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [[_closeButton titleLabel] setFont:YTFontRegular(22)];
    [_closeButton setTitle:@"✕" forState:UIControlStateNormal];
    [_closeButton setTitleColor:[YTTheme primaryText] forState:UIControlStateNormal];
    [_closeButton addTarget:self
                     action:@selector(close)
           forControlEvents:UIControlEventTouchUpInside];
    [_closeButton setHidden:YES];
    [_panel addSubview:_closeButton];

    /**
     * Закреплённое сообщение — плашкой над списком, как в оригинале.
     * Его присылает отдельное действие и оно живёт, пока автор не снимет.
     */
    _banner = [[YTPillView alloc] initWithFrame:CGRectZero];
    [(YTPillView *)_banner setCornerRadius:10];
    [(YTPillView *)_banner setFillColor:[YTTheme surfaceAlt]];
    [_banner setHidden:YES];
    [_panel addSubview:_banner];

    _bannerText = YTLabel(YTFontRegular(13), [YTTheme primaryText], 2);
    [_banner addSubview:_bannerText];

    _gripArea = [[YTTappableView alloc] initWithFrame:CGRectZero];
    [_gripArea setHighlights:NO];
    [_gripArea setOnTap:^{ [weakSelf close]; }];
    [_panel addSubview:_gripArea];

    // Ручка 40×4 со скруглением 2 по центру полосы захвата.
    _grip = [[UIView alloc] initWithFrame:CGRectZero];
    [_grip setBackgroundColor:[UIColor grayColor]];
    [[_grip layer] setCornerRadius:2];
    [_grip setUserInteractionEnabled:NO];
    [_gripArea addSubview:_grip];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    [_table setDataSource:self];
    [_table setDelegate:self];
    [_table setSeparatorStyle:UITableViewCellSeparatorStyleNone];
    [_table setBackgroundColor:[UIColor clearColor]];
    [_table setBackgroundView:nil];
    [_panel addSubview:_table];

    /**
     * Долгое нажатие по записи — «ответить» и «изменить».
     *
     * На самом списке, а не на ячейках: ячейки переиспользуются, и вешать
     * распознаватель на каждую значило бы следить за десятком вместо
     * одного. Прокрутке он не мешает — она начинается раньше, чем
     * набегает полсекунды, и жест не успевает засчитаться.
     */
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(commentHeld:)];

    [_table addGestureRecognizer:hold];

    _status = [[YTStatusView alloc] initWithFrame:CGRectZero];
    [_panel addSubview:_status];

    [self buildComposer];

    /**
     * Клавиатура закрывает собой ровно то, что мы поднимаем ради неё.
     *
     * Панель прижата к низу экрана, и поле ввода в ней — самое нижнее,
     * что есть: без сдвига человек печатал бы вслепую. Поэтому на время
     * набора панель уезжает вверх на высоту клавиатуры.
     */
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardShown:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardHidden:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];

    // Нажатие мимо панели — закрыть; дальше нажатие не идёт.
    _tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)];

    [_tap setDelegate:self];
    [self addGestureRecognizer:_tap];

    // Протяжка вниз по панели — тоже закрытие.
    UIPanGestureRecognizer *swipe =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];

    [swipe setDelegate:self];
    [_panel addGestureRecognizer:swipe];

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Поле ввода

/**
 * Строка ввода под списком: поле и кнопка «Отправить».
 *
 * Прячется по умолчанию и показывается только тогда, когда страница
 * комментариев привезла метку `createParams`. Так задумано: метка и есть
 * ответ сервера на вопрос «можно ли сюда писать», и рисовать поле там,
 * где отправка всё равно не пройдёт, — обманывать.
 */
- (void)buildComposer {
    _composer = [[UIView alloc] initWithFrame:CGRectZero];
    [_composer setHidden:YES];
    [_panel addSubview:_composer];

    // Волосяная черта над строкой — граница между списком и вводом.
    _composerLine = [[UIView alloc] initWithFrame:CGRectZero];
    [_composer addSubview:_composerLine];

    _composerAvatar = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];
    [_composerAvatar setCircular:YES];
    [_composer addSubview:_composerAvatar];

    _pill = [[UIView alloc] initWithFrame:CGRectZero];
    [[_pill layer] setCornerRadius:YTComposerRow / 2];
    [_pill setClipsToBounds:YES];
    [_composer addSubview:_pill];

    /**
     * Полоска над полем — «отвечаете такому-то» либо «правите своё».
     *
     * Без неё режим не виден вовсе: поле то же самое, и человек, начав
     * ответ, через минуту уже не помнит, кому он его пишет. Крестик
     * справа возвращает к обычному комментарию.
     */
    _modeBar = [[UIView alloc] initWithFrame:CGRectZero];
    [_modeBar setHidden:YES];
    [_composer addSubview:_modeBar];

    _modeLabel = YTLabel(YTFontRegular(12), [YTTheme secondaryText], 1);
    [_modeBar addSubview:_modeLabel];

    _modeCancel = [UIButton buttonWithType:UIButtonTypeCustom];

    [_modeCancel setTitle:@"✕" forState:UIControlStateNormal];
    [[_modeCancel titleLabel] setFont:YTFontRegular(14)];
    [_modeCancel addTarget:self
                    action:@selector(cancelMode)
          forControlEvents:UIControlEventTouchUpInside];

    [_modeBar addSubview:_modeCancel];

    /**
     * Поле не обычное, а `YTTextField`, и это не украшение.
     *
     * До iOS 7 поле без рамки прижимает строку к верхнему краю — на
     * шестёрке подсказка почти касается верха таблетки. Для строки поиска
     * это давно решено подклассом; здесь я взял обычное поле и получил
     * ровно тот же перекос, который в проекте уже был разобран и описан.
     */
    _input = [[YTTextField alloc] initWithFrame:CGRectZero];

    [_input setDelegate:self];
    [_input setFont:YTFontRegular(14)];
    [_input setBorderStyle:UITextBorderStyleNone];
    [_input setReturnKeyType:UIReturnKeySend];
    [_input setAutocorrectionType:UITextAutocorrectionTypeYes];
    [_input setBackgroundColor:[UIColor clearColor]];

    /**
     * Цвет приглашения задаётся не атрибутами, а рисованием.
     *
     * `attributedPlaceholder` есть только с iOS 6, а нужный ему
     * `NSForegroundColorAttributeName` при нижней границе 5.1 становится
     * слабым символом — ровно та ловушка, о которой написано в README.
     * Поэтому `YTTextField` рисует приглашение сам, и цвет ему даётся
     * через `placeholderColor` в `applyComposerTheme`.
     */
    [_pill addSubview:_input];

    /**
     * Стрелка отправки, а не слово.
     *
     * Значок в наборе уже есть — `pl_send`, тот же, которым помечена
     * «Поделиться»: у нынешнего YouTube это одна и та же стрелка.
     * Отдельного рисунка заводить не пришлось.
     */
    _send = [UIButton buttonWithType:UIButtonTypeCustom];

    [_send setImage:YTIcon(@"pl_send") forState:UIControlStateNormal];
    [_send addTarget:self
              action:@selector(sendComment)
    forControlEvents:UIControlEventTouchUpInside];

    [_composer addSubview:_send];

    /**
     * Стрелка живёт по набранному тексту.
     *
     * У нынешнего клиента она не торчит без дела: пока поле пустое,
     * отправлять нечего, и её нет. `UIControlEventEditingChanged`
     * приходит на каждую букву — этого довольно.
     */
    [_input addTarget:self
               action:@selector(inputChanged)
     forControlEvents:UIControlEventEditingChanged];

    [self applyComposerTheme];
    [self updateSendState];
}

- (void)applyComposerTheme {
    [_composerLine setBackgroundColor:[YTTheme surfaceAlt]];

    [_composerAvatar setPlaceholderColor:[YTTheme avatarPlaceholder]];

    /**
     * Таблетка на `surface`, а не на `surfaceHover`.
     *
     * Подложка панели — `divider`, и в тёмной теме это тот же `0x222222`,
     * что и `surfaceHover`: таблетка сливалась с фоном начисто, поле ввода
     * выглядело просто строкой текста. `surface` отличается от подложки
     * в обеих темах — 0x272727 против 0x222222 и 0xF2F2F2 против 0xE5E5E5.
     */
    [_pill setBackgroundColor:[YTTheme surface]];

    [_input setTextColor:[YTTheme primaryText]];
    [_input setPlaceholder:YTLoc(@"Добавьте комментарий")];

    /**
     * Приглашение — приглушённым цветом темы, а не системным серым.
     *
     * Системный взят под светлую тему, и на тёмной таблетке он сливался
     * с ней почти начисто: поле выглядело пустым, и что в него вообще
     * пишут, было не угадать.
     */
    [_input setPlaceholderColor:[YTTheme secondaryText]];

    [_send setImage:YTIcon(@"pl_send") forState:UIControlStateNormal];
}

- (void)inputChanged {
    [self updateSendState];
}

/**
 * Показывать ли стрелку — и не дёргать ли раскладку зря.
 *
 * Ширина таблетки зависит от того, есть стрелка или нет, поэтому
 * перекладывать надо только на смене состояния, а не на каждую букву.
 */
- (void)updateSendState {
    BOOL ready = !_sending && [[_input text] length] > 0;

    if ([_send isHidden] == !ready) {
        return;
    }

    [_send setHidden:!ready];

    [self layoutComposer];
}

/** Кружок, таблетка, стрелка — слева направо. */
/** Высота строки ввода: с полоской режима она выше. */
- (CGFloat)composerHeight {
    return YTComposerHeight + (_mode == YTComposeNew ? 0 : YTComposerModeBar);
}

- (void)layoutComposer {
    CGFloat width = [_composer bounds].size.width;

    [_composerLine setFrame:CGRectMake(0, 0, width, 0.5)];

    CGFloat top = YTComposerPad;

    if (_mode != YTComposeNew) {
        [_modeBar setFrame:CGRectMake(0, 2, width, YTComposerModeBar)];

        [_modeLabel setFrame:CGRectMake(0, 0, width - YTComposerSend,
                                        YTComposerModeBar)];

        [_modeCancel setFrame:CGRectMake(width - YTComposerSend, 0,
                                         YTComposerSend, YTComposerModeBar)];

        top += YTComposerModeBar;
    }

    [_composerAvatar setFrame:CGRectMake(0, top + (YTComposerRow - YTComposerAvatar) / 2,
                                         YTComposerAvatar, YTComposerAvatar)];

    CGFloat left = YTComposerAvatar + YTComposerGap;

    // Стрелка забирает себе правый край — но только когда показана.
    CGFloat taken = [_send isHidden] ? 0 : YTComposerSend + YTComposerGap;

    [_pill setFrame:CGRectMake(left, top, width - left - taken, YTComposerRow)];

    [_input setFrame:CGRectMake(YTComposerInset, 0,
                                [_pill bounds].size.width - YTComposerInset * 2,
                                YTComposerRow)];

    [_send setFrame:CGRectMake(width - YTComposerSend,
                               top + (YTComposerRow - YTComposerSend) / 2,
                               YTComposerSend, YTComposerSend)];
}

/**
 * Свой кружок в строке ввода — как у нынешнего клиента.
 *
 * Спрашивается один раз и в фоне: `accountProfile` ходит в сеть, а строка
 * должна появиться сразу, не дожидаясь ответа. Не ответил — остаётся
 * заглушка, и это не беда.
 */
- (void)loadComposerAvatar {
    if (_avatarAsked) {
        return;
    }

    _avatarAsked = YES;

    YTAsync(^{
        NSDictionary *profile = [YTApi accountProfile];

        NSString *avatar = [profile objectForKey:@"avatar"];

        if ([avatar length] == 0) {
            return;
        }

        YTMain(^{
            [YTImageLoader loadInto:_composerAvatar
                                url:avatar
                        targetWidth:YTComposerAvatar];
        });
    });
}

/**
 * Показывать ли поле — по входу, а не по метке.
 *
 * Сначала было наоборот: поле появлялось, только когда страница
 * комментариев привезла `createParams`. Замысел был честный — не рисовать
 * того, что всё равно не отправится, — но на деле он прятал поле почти
 * всегда. Комментарии читаются WEB-клиентом, а подписывает его только
 * браузерная сессия; у вошедшего одним кодом устройства запрос уходит
 * анонимным, и метки в ответе не бывает **никогда**. То есть поле не
 * показывалось ровно тем, у кого вход как раз есть.
 *
 * Поэтому решает вход: есть чем представиться — поле есть. Метку,
 * если её не прислали вместе со списком, спросит сама отправка
 * (`postComment:` умеет добыть её отдельно, и первым спрашивает
 * TV-клиента). Так человек хотя бы видит, куда писать, и получает
 * внятный отказ вместо пустого места.
 */
- (void)updateComposer {
    BOOL signedIn = [YTAuth isSignedIn] || [YTWebAuth isSignedIn];

    BOOL allowed = signedIn && [_videoId length] > 0;

    [_composer setHidden:!allowed];

    if (allowed) {
        [self loadComposerAvatar];
    } else {
        [_input resignFirstResponder];
    }

    /**
     * Почему поля нет — строкой в журнал.
     *
     * Без неё «поля не видно» неотличимо от «панель не открылась»
     * и от «сборка не та»: на устройстве не видно ни того, ни другого.
     */
    NSLog(@"[YouTube/Комментарий] Поле ввода: %@ (вход: токен %@, сессия %@, "
          @"метка %@, ролик %@)",
          allowed ? @"показано" : @"скрыто",
          [YTAuth isSignedIn] ? @"есть" : @"нет",
          [YTWebAuth isSignedIn] ? @"есть" : @"нет",
          [_createParams length] > 0 ? @"пришла со списком" : @"спросим при отправке",
          [_videoId length] > 0 ? _videoId : @"не передан");

    [self setNeedsLayout];
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    [self sendComment];

    return NO;
}

#pragma mark - Ответ и правка

/**
 * Долгое нажатие по записи — что с ней можно сделать.
 *
 * Нажатием коротким уже занята полоска «показать ответы», и вешать
 * туда же второе значение нельзя. Долгое здесь и уместно: действие
 * это не частое, и случайно его не сделаешь.
 */
- (void)commentHeld:(UILongPressGestureRecognizer *)gesture {
    if ([gesture state] != UIGestureRecognizerStateBegan) {
        return;
    }

    NSIndexPath *path = [_table indexPathForRowAtPoint:[gesture locationInView:_table]];

    if (path == nil || (NSUInteger)[path row] >= [_items count]) {
        return;
    }

    NSDictionary *item = [_items objectAtIndex:(NSUInteger)[path row]];

    // Полоска «показать ответы» — не запись, с ней делать нечего.
    if ([item objectForKey:YTRepliesRowKey] != nil) {
        return;
    }

    NSString *reply = [item objectForKey:@"replyParams"];
    NSString *edit = [item objectForKey:@"editParams"];

    NSMutableArray *rows = [NSMutableArray array];

    __weak YTCommentsSheet *weakSelf = self;

    if ([reply length] > 0) {
        [rows addObject:[YTSheetRow command:@"pl_send"
                                      title:YTLoc(@"Ответить")
                                     action:^{
            [weakSelf beginMode:YTComposeReply item:item params:reply];
        }]];
    }

    /**
     * «Изменить» показывается только там, где сервер дал метку правки.
     *
     * Своего перечня «чьё это» у нас нет, а сверять имя канала ненадёжно:
     * имена повторяются, и человек с тем же именем получил бы кнопку,
     * которая всё равно кончится отказом. Метку же сервер даёт только
     * автору — она и есть ответ.
     */
    if ([edit length] > 0) {
        [rows addObject:[YTSheetRow command:@"pl_settings"
                                      title:YTLoc(@"Изменить")
                                     action:^{
            [weakSelf beginMode:YTComposeEdit item:item params:edit];
        }]];
    }

    if ([rows count] == 0) {
        return;
    }

    if (_actions == nil) {
        _actions = [[YTSettingsSheet alloc] initWithDark:NO];
    }

    [_actions setTitle:YTLoc(@"Комментарий") rows:rows];
    [_actions openIn:self];
}

- (void)beginMode:(NSInteger)mode
             item:(NSDictionary *)item
           params:(NSString *)params {
    [_actions close];

    _mode = mode;
    _modeParams = [params copy];
    _modeItem = item;

    if (mode == YTComposeEdit) {
        [_modeLabel setText:YTLoc(@"Правка своего комментария")];

        // Правят уже написанное — значит, оно и должно стоять в поле.
        [_input setText:[item objectForKey:@"text"]];
    } else {
        NSString *author = [item objectForKey:@"author"];

        [_modeLabel setText:YTLocF(@"Ответ %@",
            [author length] > 0 ? author : YTLoc(@"на комментарий"))];

        [_input setText:@""];
    }

    [_modeBar setHidden:NO];

    [self applyComposerTheme];
    [self updateSendState];
    [self setNeedsLayout];

    [_input becomeFirstResponder];
}

- (void)cancelMode {
    if (_mode == YTComposeNew) {
        return;
    }

    _mode = YTComposeNew;
    _modeParams = nil;
    _modeItem = nil;

    [_modeBar setHidden:YES];
    [_input setText:@""];

    [self updateSendState];
    [self setNeedsLayout];
}

- (void)sendComment {
    NSString *text = [_input text];

    if (_sending || [text length] == 0) {
        return;
    }

    if (_mode != YTComposeNew) {
        [self sendMode:text];

        return;
    }

    /**
     * Метки нет и сессии браузера нет — идти в сеть незачем: ответ
     * известен заранее, а человеку нужен не отказ, а место, куда пойти.
     */
    if ([_createParams length] == 0 && ![YTWebAuth isSignedIn]) {
        [self showBrowserLoginNeeded:nil];

        return;
    }

    _sending = YES;

    // Стрелка уходит на время отправки: второе нажатие всё равно
    // не принимается, и мигать ею незачем.
    [self updateSendState];

    [_input resignFirstResponder];

    NSString *video = [_videoId copy];
    NSString *params = [_createParams copy];

    // Токен панели — тот самый, которым взят список. Метка лежит в панели,
    // и с ним она стоит одного запроса вместо двух.
    NSString *token = [_token copy];

    NSInteger generation = [_generation current];

    YTAsync(^{
        NSString *reason = nil;

        BOOL sent = [YTApi postComment:text video:video params:params
                                 token:token reason:&reason];

        YTMain(^{
            _sending = NO;

            [self updateSendState];

            /**
             * Панель успели закрыть или открыть на другом ролике —
             * показывать нечего и вставлять некуда.
             */
            if (![_generation isCurrent:generation]) {
                return;
            }

            if (!sent) {
                [self showSendFailure:reason];

                return;
            }

            [_input setText:@""];

            [self updateSendState];
            [self insertOwnComment:text];
        });
    });
}

/**
 * Отправка ответа либо правки.
 *
 * Отдельно от обычного комментария только тем, куда уходит запрос;
 * всё вокруг — блокировка второго нажатия, проверка поколения, показ
 * отказа словами сервера — то же самое.
 */
- (void)sendMode:(NSString *)text {
    NSInteger mode = _mode;
    NSString *params = [_modeParams copy];
    NSDictionary *item = _modeItem;

    _sending = YES;

    [self updateSendState];
    [_input resignFirstResponder];

    NSInteger generation = [_generation current];

    YTAsync(^{
        NSString *reason = nil;

        BOOL sent = (mode == YTComposeEdit)
            ? [YTApi editComment:text params:params reason:&reason]
            : [YTApi replyComment:text params:params reason:&reason];

        YTMain(^{
            _sending = NO;

            [self updateSendState];

            if (![_generation isCurrent:generation]) {
                return;
            }

            if (!sent) {
                [self showSendFailure:reason];

                return;
            }

            if (mode == YTComposeEdit) {
                [self replaceText:text in:item];
            }

            [self cancelMode];
        });
    });
}

/**
 * Поправленный текст — сразу в списке.
 *
 * Перечитывать страницу ради одной строки незачем, да и незачем вдвойне:
 * список приходит отсортированным, и правленая запись легко уехала бы
 * с глаз — человек решил бы, что правка не прошла.
 */
- (void)replaceText:(NSString *)text in:(NSDictionary *)item {
    NSUInteger at = [_items indexOfObjectIdenticalTo:item];

    if (at == NSNotFound) {
        return;
    }

    NSMutableDictionary *fixed = [NSMutableDictionary dictionaryWithDictionary:item];

    [fixed setObject:text forKey:@"text"];

    [_items replaceObjectAtIndex:at withObject:fixed];

    // Высота записи от текста и зависит — считаем её заново.
    [_heights removeAllObjects];
    [self measureFrom:0];

    [_table reloadData];
}

/**
 * Свой комментарий — сразу в начало списка, не перечитывая страницу.
 *
 * Перечитывание тут не помогло бы: страница приходит отсортированной
 * по важности, и только что написанное в её начале не появляется —
 * человек решил бы, что отправка не прошла.
 */
- (void)insertOwnComment:(NSString *)text {
    NSDictionary *profile = [YTApi accountProfile];

    NSMutableDictionary *own = [NSMutableDictionary dictionary];

    [own setObject:text forKey:@"text"];
    [own setObject:YTLoc(@"только что") forKey:@"published"];

    NSString *name = [profile objectForKey:@"name"];
    NSString *avatar = [profile objectForKey:@"avatar"];

    [own setObject:([name length] > 0 ? name : YTLoc(@"Вы")) forKey:@"author"];

    if ([avatar length] > 0) { [own setObject:avatar forKey:@"avatar"]; }

    [_items insertObject:own atIndex:0];

    CGFloat width = _measuredWidth > 0 ? _measuredWidth : [_table bounds].size.width;

    [_heights insertObject:[NSNumber numberWithDouble:
        [YTCommentCell heightFor:own width:width]] atIndex:0];

    [_status hide];

    [_table reloadData];

    [_table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]
                  atScrollPosition:UITableViewScrollPositionTop
                          animated:YES];
}

/**
 * Отказ пересказываем словами сервера, а не своими.
 *
 * В первом заходе здесь стоял готовый текст про телевизор: раз пишем
 * от имени TV-клиента, значит и отказ, наверное, из-за этого. Догадка
 * оказалась дурной услугой — она подходила к любому отказу и потому
 * не объясняла ни одного, а человеку, вошедшему через браузер, ещё и
 * советовала войти через браузер.
 *
 * Поэтому: сказал сервер что-нибудь внятное — показываем это. Промолчал —
 * говорим, что промолчал, и не сочиняем причину за него.
 */
- (void)showSendFailure:(NSString *)reason {
    /**
     * Нет сессии браузера — говорим об этом прямо, а не пересказываем
     * отказ сервера.
     *
     * Сервер в этом случае отвечает «войдите в аккаунт», и это правда,
     * но не вся: войти надо **не там**, где человек уже вошёл. Вход по
     * коду с телевизора у него жив — им читается вся лента, — и совет
     * «войдите» выглядит издевательством. Указываем то самое место
     * в настройках.
     */
    if (![YTWebAuth isSignedIn]) {
        [self showBrowserLoginNeeded:reason];

        return;
    }

    NSString *message = [reason length] > 0
        ? reason
        : YTLoc(@"YouTube отказал в отправке и причины не назвал. "
                @"Подробности — в журнале приложения.");

    UIAlertView *alert = [[UIAlertView alloc]
        initWithTitle:YTLoc(@"Комментарий не принят")
              message:message
             delegate:nil
    cancelButtonTitle:YTLoc(@"Понятно")
    otherButtonTitles:nil];

    [alert show];
}

/**
 * Окно «нужен вход в браузере».
 *
 * Разрешение на запись — `createCommentParams` — YouTube кладёт в поле
 * ввода над списком комментариев, а поле это присылают только тому, кого
 * узнали по сессии браузера. Вход по коду с телевизора для чтения годится
 * вполне, а для записи не даёт ничего: панели комментариев TV-клиенту
 * не присылают вовсе, и брать метку неоткуда. Сама же запись потом уходит
 * как раз токеном телевизора — узел записи про клиента не спрашивает.
 *
 * Поэтому окно и говорит про браузер, а не про «войдите в аккаунт»:
 * человек, читающий это, в аккаунт уже вошёл.
 */
- (void)showBrowserLoginNeeded:(NSString *)said {
    NSMutableString *message = [NSMutableString stringWithString:
        YTLoc(@"Чтобы писать комментарии, войдите в аккаунт в настройках "
              @"приложения — «Вход в браузере». Входа по коду для этого мало: "
              @"разрешение на запись YouTube выдаёт только сессии браузера.")];

    // Слово сервера, если он его сказал, — но вторым, после нашего.
    if ([said length] > 0) {
        [message appendFormat:@"\n\n%@", said];
    }

    UIAlertView *alert = [[UIAlertView alloc]
        initWithTitle:YTLoc(@"Нужен вход в браузере")
              message:message
             delegate:nil
    cancelButtonTitle:YTLoc(@"Понятно")
    otherButtonTitles:nil];

    [alert show];
}

/**
 * Предупредить заранее, а не после набранного текста.
 *
 * Узнать, что писать не дадут, лучше до того, как комментарий написан:
 * иначе труд пропадает, а окно выглядит отпиской. Показывается один раз
 * за открытие панели — повторять его на каждое касание поля назойливо.
 */
- (BOOL)textFieldShouldBeginEditing:(UITextField *)field {
    if (_warnedAboutLogin || [YTWebAuth isSignedIn] || [_createParams length] > 0) {
        return YES;
    }

    _warnedAboutLogin = YES;

    [self showBrowserLoginNeeded:nil];

    return YES;
}

#pragma mark - Клавиатура

- (void)keyboardShown:(NSNotification *)note {
    if (!_open || [_composer isHidden]) {
        return;
    }

    NSValue *box = [[note userInfo] objectForKey:UIKeyboardFrameEndUserInfoKey];

    if (box == nil) {
        return;
    }

    // Рамка приходит в координатах экрана — переводим в свои.
    CGRect keyboard = [self convertRect:[box CGRectValue] fromView:nil];

    CGFloat lift = [self bounds].size.height - keyboard.origin.y;

    if (lift < 0) { lift = 0; }

    if (lift == _keyboardLift) {
        return;
    }

    /**
     * Запоминаем, сколько клавиатура забрала, а не насколько уехать.
     *
     * Прежде здесь же и решалось: подъём обрезался до `_place.origin.y`,
     * то есть до кадра, выше которого панели хода нет. На четырёхдюймовом
     * запаса хватало, а на iPhone 4 панель занимает почти весь экран под
     * кадром — запаса сотня точек при клавиатуре в две с лишним, и остаток
     * строка ввода проводила под клавиатурой. Человек писал вслепую.
     *
     * Что с этим делать, знает раскладка: она сдвигает панель, сколько
     * есть места, а чем не хватило — укорачивает её.
     */
    _keyboardLift = lift;

    [self setNeedsLayout];

    [UIView animateWithDuration:0.25 animations:^{
        [self layoutIfNeeded];
    }];
}

- (void)keyboardHidden:(NSNotification *)note {
    if (_keyboardLift == 0) {
        return;
    }

    _keyboardLift = 0;

    [self setNeedsLayout];

    [UIView animateWithDuration:0.2 animations:^{
        [self layoutIfNeeded];
    }];
}

/**
 * Ставит панель на её место. Само место считается в `layoutSubviews` —
 * там же, где и всё, что внутри: укороченной панели содержимое надо
 * перекладывать, а не только двигать рамку.
 */
- (void)layoutPanel {
    [_panel setFrame:_place];
}

#pragma mark -

- (BOOL)isOpen {
    return _open;
}

- (void)openWithLiveChat:(NSString *)token
                   items:(NSArray *)seen
                   video:(NSString *)videoId
                 viewers:(NSString *)viewers
                 filters:(NSArray *)filters {
    if (_open) {
        return;
    }

    _open = YES;
    _videoId = [videoId copy];
    _chatToken = [token copy];

    // Писать в чат пока не умеем — поле ввода прячем.
    _createParams = nil;
    _warnedAboutLogin = NO;

    [_composer setHidden:YES];
    [_input resignFirstResponder];

    [_heading setText:YTLoc(@"Чат")];
    [_heading setHidden:NO];

    /**
     * Счётчик идёт через точку после фильтра — «Все сообщения · 1,9 тыс.».
     * Само число даёт описание ролика: у эфира там смотрящие сейчас.
     */
    [_viewers setText:([viewers length] > 0
        ? [NSString stringWithFormat:@"· %@", viewers] : @"")];

    [_viewers setHidden:([viewers length] == 0)];

    [_closeButton setHidden:NO];

    /**
     * Фильтры: «все сообщения» и «интересные».
     *
     * Порядок у подменю всегда один — сперва «интересные», потом «все», —
     * и по умолчанию сервер даёт первый. Нам нужен второй: человек просил
     * видеть все сообщения, а не отобранные. Поэтому и метку берём вторую,
     * а не ту, что пришла с описанием ролика.
     */
    _chatFilters = filters;
    _chatFilter = ([filters count] > 1) ? 1 : 0;

    if ([_chatFilters count] > 1) {
        NSString *own = [[_chatFilters objectAtIndex:_chatFilter] objectForKey:@"token"];

        if ([own length] > 0) {
            _chatToken = [own copy];
        }
    }

    [self showChatFilterTitle];

    [_banner setHidden:YES];

    /**
     * Чистим всё, что осталось от комментариев, — и это не про порядок,
     * а про рабочее.
     *
     * Список хранит высоты строк в `_heights`, листалку в `_pager` и
     * метку страницы в `_token`. Оставленные от прежнего разговора, они
     * дают перепутанные высоты и попытку долистать чужую страницу — и
     * панель выглядит нераскрытой, хотя записи в ней есть.
     */
    _token = nil;

    [_generation next];

    [_items removeAllObjects];
    [_heights removeAllObjects];
    [_pager reset];

    if ([seen count] > 0) {
        [_items addObjectsFromArray:seen];
    }

    [self setHidden:NO];
    [self setNeedsLayout];
    [self layoutIfNeeded];

    CGRect shown = [_panel frame];
    CGRect hidden = shown;

    hidden.origin.y += YTSheetHeight + 10;

    [_panel setFrame:hidden];

    [UIView animateWithDuration:0.25 animations:^{
        [_panel setFrame:shown];
    }];

    [_table reloadData];

    if ([_items count] > 0) {
        [_status hide];
        [self scrollChatToEnd];
    } else {
        [_status showBusy];
    }

    [self pollChat];
}

/**
 * Берёт очередную страницу чата и дописывает её снизу.
 *
 * Прокрутку двигаем вниз только если человек и так стоял внизу: иначе
 * он читает старое, а список уезжает у него из-под пальца.
 */
- (void)pollChat {
    NSString *token = [_chatToken copy];

    if (!_open || [token length] == 0) {
        return;
    }

    __weak YTCommentsSheet *weakSelf = self;

    YTAsync(^{
        NSDictionary *page = [YTApi liveChat:token];

        YTMain(^{
            YTCommentsSheet *sheet = weakSelf;

            if (sheet == nil) {
                return;
            }

            [sheet applyChat:page after:token];
        });
    });
}

- (void)applyChat:(NSDictionary *)page after:(NSString *)asked {
    if (!_open || ![asked isEqualToString:_chatToken]) {
        return;
    }

    NSTimeInterval wait = 10.0;

    if (page != nil) {
        NSString *next = [page objectForKey:@"token"];

        if ([next length] > 0) {
            _chatToken = [next copy];
        }

        NSNumber *said = [page objectForKey:@"wait"];

        if (said != nil) {
            wait = [said doubleValue];
        }

        NSDictionary *pinned = [page objectForKey:@"banner"];

        if (pinned != nil) {
            NSString *who = [pinned objectForKey:@"author"];
            NSString *what = [pinned objectForKey:@"text"];

            [_bannerText setText:([who length] > 0
                ? [NSString stringWithFormat:@"%@: %@", who, what]
                : what)];

            [_banner setHidden:NO];

            [self setNeedsLayout];
        }

        NSArray *fresh = [page objectForKey:@"items"];

        if ([fresh count] > 0) {
            BOOL atEnd = [self chatIsAtEnd];

            [_items addObjectsFromArray:fresh];

            // Держим три сотни записей: старое всё равно уже прочитано.
            while ([_items count] > 300) {
                [_items removeObjectAtIndex:0];
            }

            [_status hide];
            [_table reloadData];

            if (atEnd) {
                [self scrollChatToEnd];
            }
        }
    }

    if ([_items count] == 0) {
        [_status showMessage:YTLoc(@"В чате пока тихо")];
    }

    [_chatTimer invalidate];

    _chatTimer = [NSTimer scheduledTimerWithTimeInterval:MAX(2.0, wait)
                                                  target:self
                                                selector:@selector(pollChat)
                                                userInfo:nil
                                                 repeats:NO];
}

/**
 * Пишет на кнопке название нынешнего фильтра.
 *
 * Названия свои, а не серверные: второй фильтр сервер зовёт просто «Чат»,
 * что рядом с заголовком «Чат» ничего не объясняет.
 */
- (void)showChatFilterTitle {
    if ([_chatFilters count] < 2) {
        [_filterButton setHidden:YES];

        return;
    }

    NSString *title = (_chatFilter == 0)
        ? YTLoc(@"Интересные сообщения")
        : YTLoc(@"Все сообщения");

    [_filterButton setTitle:title forState:UIControlStateNormal];
    [_filterButton setHidden:NO];

    [self setNeedsLayout];
}

/**
 * Переключает фильтр и начинает разговор заново.
 *
 * Именно заново: у каждого фильтра свой поток, и дописывать отобранное
 * к полному было бы мешаниной с повторами.
 */
- (void)switchChatFilter {
    if ([_chatFilters count] < 2) {
        return;
    }

    _chatFilter = (_chatFilter + 1) % [_chatFilters count];

    NSString *token = [[_chatFilters objectAtIndex:_chatFilter] objectForKey:@"token"];

    if ([token length] == 0) {
        return;
    }

    [_chatTimer invalidate];

    _chatTimer = nil;
    _chatToken = [token copy];

    [_items removeAllObjects];
    [_heights removeAllObjects];
    [_table reloadData];

    [_status showBusy];
    [self showChatFilterTitle];
    [self pollChat];
}

- (BOOL)chatIsAtEnd {
    CGFloat bottom = [_table contentOffset].y + [_table bounds].size.height;

    return (bottom >= [_table contentSize].height - 40.0);
}

- (void)scrollChatToEnd {
    NSUInteger count = [_items count];

    if (count == 0) {
        return;
    }

    [_table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)(count - 1)
                                                      inSection:0]
                  atScrollPosition:UITableViewScrollPositionBottom
                          animated:NO];
}

- (void)openWithToken:(NSString *)token {
    [self openWithToken:token page:nil video:nil];
}

- (void)openWithToken:(NSString *)token page:(NSDictionary *)page {
    [self openWithToken:token page:page video:nil];
}

- (void)openWithToken:(NSString *)token
                 page:(NSDictionary *)page
                video:(NSString *)videoId {
    if (_open) {
        return;
    }

    _open = YES;

    _videoId = [videoId copy];

    // Состояние поля пересматривается на каждом открытии: вход мог
    // появиться уже после того, как панель показывали в прошлый раз,
    // а тот путь ниже обрывается раньше — список-то перечитывать незачем.
    [self updateComposer];

    [self setHidden:NO];
    [self setNeedsLayout];
    [self layoutIfNeeded];

    // Выезд снизу: в разметке панель спрятана на 410 точек, то есть
    // чуть ниже собственной высоты.
    CGRect shown = [_panel frame];
    CGRect hidden = shown;

    hidden.origin.y += YTSheetHeight + 10;

    [_panel setFrame:hidden];

    [UIView animateWithDuration:0.25 animations:^{
        [_panel setFrame:shown];
    }];

    if ([_token isEqualToString:token] && [_items count] > 0) {
        return;
    }

    _token = [token copy];

    // Метка принадлежит той странице, что сейчас уедет, — новую ждём
    // от новой страницы, а до неё поля ввода нет.
    _createParams = nil;

    // Новая панель — новый разговор: про вход скажем ещё раз, если надо.
    _warnedAboutLogin = NO;

    [self updateComposer];

    /**
     * Новый ролик — новое поколение, и это не украшение.
     *
     * Поколение здесь заведено с самого начала, и на него смотрят все
     * загрузки, но сдвинуть его было некому: `next` не звался ни разу,
     * и проверки выходили холостыми. Пока панель только читала, это
     * ничем не грозило — в худшем случае дописалась бы страница от
     * прежнего ролика. С отправкой цена другая: ответ на «отправлено»
     * приходит через секунды, за которые панель успевают закрыть и
     * открыть на другом ролике, и свой комментарий лёг бы в чужой список.
     */
    [_generation next];

    [_items removeAllObjects];
    [_heights removeAllObjects];
    [_pager reset];
    [_table reloadData];

    // Страница уже взята заранее — показываем её, не ходя в сеть.
    if (page != nil) {
        [self applyPage:page];

        return;
    }

    [self loadPage:token];
}

- (void)close {
    if (!_open) {
        return;
    }

    _open = NO;

    // Опрос чата живёт, только пока панель открыта.
    [_chatTimer invalidate];

    _chatTimer = nil;
    _chatToken = nil;
    _chatFilters = nil;

    [_heading setHidden:YES];
    [_viewers setHidden:YES];
    [_filterButton setHidden:YES];
    [_closeButton setHidden:YES];
    [_banner setHidden:YES];

    // Клавиатуру уводим вместе с панелью, иначе она останется висеть
    // над пустым местом, а панель поедет вниз из поднятого положения.
    [_input resignFirstResponder];

    _keyboardLift = 0;

    CGRect shown = _place;
    CGRect hidden = shown;

    hidden.origin.y += YTSheetHeight + 10;

    [_panel setFrame:shown];

    [UIView animateWithDuration:0.2
                     animations:^{ [_panel setFrame:hidden]; }
                     completion:^(BOOL finished) {
        if (!_open) {
            [self setHidden:YES];
            [_panel setFrame:shown];
        }
    }];
}

- (void)loadPage:(NSString *)token {
    NSInteger generation = [_generation current];

    if ([_items count] == 0) {
        [_status showBusy];
    }

    YTAsync(^{
        NSDictionary *page = [YTApi comments:token];

        YTMain(^{
            [_pager finish];

            if (![_generation isCurrent:generation]) {
                return;
            }

            [self applyPage:page];
        });
    });
}

/** Раскладывает страницу по списку — всё равно, взята она сейчас или заранее. */
- (void)applyPage:(NSDictionary *)page {
    NSArray *items = [page objectForKey:@"items"];

    /**
     * Метку берём с первой же страницы и дальше не трогаем: она про
     * ролик, а не про страницу, и в продолжениях её нет — поле ввода
     * сервер кладёт только в начало списка.
     */
    if ([_createParams length] == 0) {
        NSString *params = [page objectForKey:@"createParams"];

        if ([params length] > 0) {
            _createParams = [params copy];

            [self updateComposer];
        }
    }

    if ([items count] == 0 && [_items count] == 0) {
        /**
         * «Отключены» и «пока никто не написал» — разные вещи, и путать
         * их не надо: в первом случае поле ввода лишнее, во втором оно
         * как раз и нужно.
         *
         * Что именно случилось, говорит сам сервер — его надпись и
         * показываем; своей у нас нет только для той поры, когда он
         * промолчал.
         */
        NSString *said = [page objectForKey:@"disabledMessage"];

        if ([said length] > 0) {
            _createParams = nil;

            [_composer setHidden:YES];
            [_input resignFirstResponder];

            [self setNeedsLayout];
        }

        [_status showMessage:[said length] > 0 ? said : YTLoc(@"Комментариев нет")];

        return;
    }

    [_status hide];

    NSUInteger first = [_items count];

    /**
     * За комментарием с веткой ставится строка «Ответы (N)».
     * Сами ответы придут по нажатию: их метка продолжения —
     * отдельный запрос, и тянуть его для каждой ветки разом
     * значило бы десятки запросов на одну страницу.
     */
    for (NSDictionary *comment in items) {
        [_items addObject:comment];

        NSString *token = [comment objectForKey:@"replies"];

        if ([token length] == 0) {
            continue;
        }

        NSString *count = [comment objectForKey:@"replyCount"];

        NSString *title = [count length] > 0
            ? YTLocF(@"Ответы (%@)", count)
            : YTLoc(@"Ответы");

        [_items addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithBool:YES], YTRepliesRowKey,
            title, @"title",
            token, @"replies",
            nil]];
    }

    [_pager setToken:[page objectForKey:@"continuation"]];

    [self measureFrom:first];

    /**
     * Дописываем вставкой, а не перезагрузкой: список дописывается
     * посреди прокрутки, и полная перезагрузка выбрасывает все
     * ячейки разом — на старом железе это видно рывком.
     */
    if (first > 0) {
        NSMutableArray *paths = [NSMutableArray array];

        for (NSUInteger i = first; i < [_items count]; i++) {
            [paths addObject:[NSIndexPath indexPathForRow:i inSection:0]];
        }

        [_table insertRowsAtIndexPaths:paths
                      withRowAnimation:UITableViewRowAnimationNone];
    } else {
        [_table reloadData];
    }
}

/**
 * Высоты считаются один раз на комментарий.
 *
 * Таблица спрашивает высоту всех строк при каждом обновлении, а список
 * дописывается страницами: без запоминания весь уже показанный текст
 * перемерялся бы на каждую новую страницу — а это CoreText по полотну
 * в тысячи знаков.
 */
- (void)measureFrom:(NSUInteger)first {
    CGFloat width = [_table bounds].size.width;

    if (width <= 0) {
        width = [self bounds].size.width - YTSheetSide * 2 - 32;
    }

    _measuredWidth = width;

    for (NSUInteger i = first; i < [_items count]; i++) {
        CGFloat height = [YTCommentCell heightFor:[_items objectAtIndex:i] width:width];

        [_heights addObject:[NSNumber numberWithDouble:height]];
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[_items count];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path {
    NSUInteger row = (NSUInteger)[path row];

    if (row < [_heights count]) {
        return [[_heights objectAtIndex:row] doubleValue];
    }

    return 60;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)path {
    static NSString *identifier = @"comment";

    YTCommentCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];

    if (cell == nil) {
        cell = [[YTCommentCell alloc] initWithStyle:UITableViewCellStyleDefault
                                    reuseIdentifier:identifier];
    }

    [cell bind:[_items objectAtIndex:[path row]]];

    return cell;
}

/**
 * Нажатие по строке «Ответы (N)» — раскрыть ветку.
 *
 * Ответы становятся на место самой строки, с отступом слева. Второго
 * нажатия не будет: строка исчезает вместе с раскрытием.
 */
- (void)tableView:(UITableView *)tableView
        didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:NO];

    NSUInteger row = (NSUInteger)[path row];

    if (row >= [_items count]) {
        return;
    }

    NSDictionary *item = [_items objectAtIndex:row];

    if ([item objectForKey:YTRepliesRowKey] == nil || _loadingReplies) {
        return;
    }

    NSString *token = [item objectForKey:@"replies"];

    if ([token length] == 0) {
        return;
    }

    [self loadReplies:token after:item more:NO];
}

/**
 * Страница ветки — встаёт следом за той строкой, от которой пошли.
 *
 * Первая страница заменяет собой строку «Ответы (N)», следующие
 * пристраиваются за хвостом предыдущей. Метку следующей страницы
 * получает новый хвост; со старого она снимается сразу, чтобы прокрутка
 * не попросила одно и то же дважды.
 */
- (void)loadReplies:(NSString *)token
              after:(NSDictionary *)item
               more:(BOOL)more {
    _loadingReplies = YES;

    NSInteger generation = [_generation current];

    YTAsync(^{
        NSDictionary *page = [YTApi comments:token replies:YES];

        YTMain(^{
            _loadingReplies = NO;

            if (![_generation isCurrent:generation]) {
                return;
            }

            // Пока ходили в сеть, список мог смениться — ищем строку заново.
            NSUInteger at = [_items indexOfObjectIdenticalTo:item];

            if (at == NSNotFound) {
                return;
            }

            NSArray *replies = [page objectForKey:@"items"];

            NSUInteger put;

            if (more) {
                // Хвост ветки остаётся на месте — за ним и продолжаем.
                if ([item isKindOfClass:[NSMutableDictionary class]]) {
                    [(NSMutableDictionary *)item removeObjectForKey:YTMoreRepliesKey];
                }

                put = at + 1;
            } else {
                // Строка «Ответы (N)» уступает место самим ответам.
                [_items removeObjectAtIndex:at];
                [_heights removeObjectAtIndex:at];

                put = at;
            }

            NSMutableDictionary *last = nil;

            for (NSDictionary *reply in replies) {
                NSMutableDictionary *marked = [reply mutableCopy];

                [marked setObject:[NSNumber numberWithBool:YES] forKey:YTReplyKey];

                // У ответа своей ветки не бывает — метку убираем.
                [marked removeObjectForKey:@"replies"];

                [_items insertObject:marked atIndex:put];

                CGFloat height = [YTCommentCell heightFor:marked width:_measuredWidth];

                [_heights insertObject:[NSNumber numberWithDouble:height] atIndex:put];

                last = marked;

                put++;
            }

            NSString *next = [page objectForKey:@"continuation"];

            if ([next length] > 0 && last != nil) {
                [last setObject:next forKey:YTMoreRepliesKey];
            }

            NSLog(@"[YouTube/Комментарии] Ветка %@: ответов %lu, дальше %@",
                  more ? @"продолжена" : @"раскрыта",
                  (unsigned long)[replies count],
                  ([next length] > 0 && last != nil) ? @"есть" : @"нет");

            [_table reloadData];

            /**
             * Хвост мог оказаться на виду сразу — тогда за следующей
             * страницей идём, не дожидаясь прокрутки: ветка и так вся
             * на экране.
             */
            [self loadMoreRepliesInView];
        });
    });
}

/** Показался хвост раскрытой ветки — пора за её продолжением. */
- (void)loadMoreRepliesInView {
    if (_loadingReplies) {
        return;
    }

    for (NSIndexPath *path in [_table indexPathsForVisibleRows]) {
        NSUInteger row = (NSUInteger)[path row];

        if (row >= [_items count]) {
            continue;
        }

        NSDictionary *item = [_items objectAtIndex:row];

        NSString *token = [item objectForKey:YTMoreRepliesKey];

        if ([token length] > 0) {
            [self loadReplies:token after:item more:YES];

            return;
        }
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if ([_pager claimOn:scrollView]) {
        [self loadPage:[_pager token]];
    }

    [self loadMoreRepliesInView];
}

/**
 * Нажатия мимо панели проходят насквозь — к кадру под ней.
 *
 * Это и есть разница между панелью и отдельным экраном: видео остаётся
 * на месте и продолжает играть, а пульт под панелью по-прежнему
 * нажимается.
 */
/**
 * Нажатие мимо панели закрывает её и **не** идёт дальше.
 *
 * Прежде здесь стояло обратное: `hitTest:` возвращал nil на всём, что
 * мимо панели, и нажатие проваливалось к тому, что под ней. На странице
 * ролика это было незаметно, а в Shorts под панелью лежит сам кадр —
 * и каждое такое нажатие ставило ролик на паузу или снимало с неё.
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

/**
 * Протяжка вниз живёт рядом с прокруткой списка, а не вместо неё:
 * решает уже сам обработчик, по тому, откуда начали.
 */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

/**
 * Протяжка вниз — закрыть.
 *
 * Берётся она в двух местах: с полосы захвата — всегда, и со списка —
 * только когда он уже наверху. Так пролистывание комментариев не мешает
 * закрытию, а короткий список, где свободного места больше, чем строк,
 * закрывается протяжкой откуда угодно.
 */
- (void)dragged:(UIPanGestureRecognizer *)gesture {
    if ([gesture state] == UIGestureRecognizerStateBegan) {
        CGFloat where = [gesture locationInView:_panel].y;

        _dragging = (where <= YTSheetGrip) || ([_table contentOffset].y <= 0);

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
        [_table setContentOffset:CGPointZero];

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

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect bounds = [self bounds];

    CGFloat width = bounds.size.width - YTSheetSide * 2;
    CGFloat top = bounds.size.height - YTSheetBottom - YTSheetHeight;

    // Панель не выше самого экрана: на четырёхдюймовом 400 точек
    // не помещаются вместе с кадром.
    CGFloat height = YTSheetHeight;

    if (top < 0) {
        height = bounds.size.height - YTSheetBottom;
        top = 0;
    }

    /**
     * Клавиатура забирает низ экрана — уступаем ей.
     *
     * Сперва сдвигаем панель вверх, насколько есть место: выше верхнего
     * края хода нет, там кадр, и он должен остаться виден. Чем не хватило
     * — укорачиваем саму панель. Строка ввода прижата к её низу, поэтому
     * укороченная панель держит строку прямо над клавиатурой, сколько бы
     * та ни занимала. Короче становится список, а он и так прокручивается.
     */
    if (_keyboardLift > 0 && ![_composer isHidden]) {
        CGFloat shift = MIN(_keyboardLift, top);

        top -= shift;
        height -= (_keyboardLift - shift);

        /**
         * Ниже этого панель уже не панель: полоса захвата, строка ввода
         * и хотя бы намёк на список. Дальше пусть лучше клавиатура
         * закроет край, чем строка ввода схлопнется.
         */
        CGFloat least = YTSheetGrip + [self composerHeight] + 44;

        if (height < least) {
            height = least;
        }
    }

    _place = CGRectMake(YTSheetSide, top, width, height);

    if (_open && !_dragging) {
        [self layoutPanel];
    }

    [_panel setBackgroundColor:[YTTheme divider]];

    [_gripArea setFrame:CGRectMake(0, 0, width, YTSheetGrip)];
    [_grip setFrame:CGRectMake((width - 40) / 2, YTSheetGrip / 2 - 2, 40, 4)];

    // Содержимое: `Margin="16,0,16,18"`.
    CGRect content = CGRectMake(16, YTSheetGrip, width - 32, height - YTSheetGrip - 18);

    /**
     * Заголовок панели — там же, где он у оригинала: строкой под ручкой,
     * над списком. Показывается только у чата: у комментариев его не было
     * и прежде, а заводить его задним числом значит менять привычный вид
     * там, где не просили.
     */
    if (![_heading isHidden]) {
        /**
         * Шапка в две строки: сверху «Чат», под ним выбор фильтра и
         * счётчик зрителей. Крестик справа, по высоте обеих строк.
         */
        CGFloat titleHeight = ceil([[_heading font] lineHeight]);
        CGFloat subHeight = ceil([[[_filterButton titleLabel] font] lineHeight]);
        CGFloat tall = titleHeight + 2 + subHeight;

        CGFloat left = content.origin.x;
        CGFloat right = content.origin.x + content.size.width;

        [_closeButton setFrame:CGRectMake(right - 34, content.origin.y, 34, tall)];

        CGFloat room = content.size.width - 40;

        [_heading setFrame:CGRectMake(left, content.origin.y, room, titleHeight)];

        CGFloat subTop = content.origin.y + titleHeight + 2;
        CGFloat filterWidth = 0;

        if (![_filterButton isHidden]) {
            filterWidth = MIN(room * 0.7,
                [[_filterButton titleForState:UIControlStateNormal]
                    sizeWithFont:[[_filterButton titleLabel] font]].width + 2);

            [_filterButton setFrame:CGRectMake(left, subTop, filterWidth, subHeight)];
        }

        if (![_viewers isHidden]) {
            CGFloat at = left + filterWidth + (filterWidth > 0 ? 10 : 0);

            [_viewers setFrame:CGRectMake(at, subTop, MAX(0, room - (at - left)),
                                          subHeight)];
        }

        content.origin.y += tall + 10;
        content.size.height -= tall + 10;
    }

    if (![_banner isHidden]) {
        CGFloat inner = content.size.width - 20;
        CGFloat textHeight = YTTextHeight([_bannerText text],
                                          [_bannerText font], inner, 2);
        CGFloat tall = textHeight + 16;

        [_banner setFrame:CGRectMake(content.origin.x, content.origin.y,
                                     content.size.width, tall)];

        [_bannerText setFrame:CGRectMake(10, 8, inner, textHeight)];

        content.origin.y += tall + 8;
        content.size.height -= tall + 8;
    }

    /**
     * Строка ввода прижимается к низу панели и забирает себе её нижнее
     * поле — те самые 18 точек из `Margin="16,0,16,18"`.
     *
     * Сперва она стояла внутри области содержимого, и выходило криво:
     * над строкой 8 точек, под ней 8 своих плюс 18 чужих. Текст казался
     * задранным — и был задран. Поле это осталось от списка, которому
     * нужен отступ снизу; строке ввода оно ни к чему, у неё свои поля
     * сверху и снизу, и они равны.
     */
    if (![_composer isHidden]) {
        CGFloat tall = [self composerHeight];
        CGFloat top = height - tall;

        [_composer setFrame:CGRectMake(content.origin.x, top,
                                       content.size.width, tall)];

        [self applyComposerTheme];
        [self layoutComposer];

        content.size.height = top - content.origin.y;
    }

    [_table setFrame:content];
    [_status setFrame:content];

    if (_measuredWidth != content.size.width && [_items count] > 0) {
        [_heights removeAllObjects];
        [self measureFrom:0];
        [_table reloadData];
    }
}

@end
