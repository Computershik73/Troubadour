#import "YTFeedViews.h"

#import "YTImageLoader.h"
#import "YTMetrics.h"
#import "YTRoundedImageView.h"
#import "YTSettings.h"
#import "YTSkin.h"
#import "YTTheme.h"
#import "YTUtil.h"
#import "YTVideoItem.h"

/** Отступ между превью и строкой с автором — `Margin="0,12,0,0"`. */
static const CGFloat YTCardMetaTop = 12;

/** Между кружком и текстом — `Margin="10,0,0,0"`. */
static const CGFloat YTCardMetaGap = 10;

/** Между названием и метаданными — `Margin="0,4,0,0"`. */
static const CGFloat YTCardTextGap = 4;


#pragma mark - Карточка

@implementation YTVideoCard {
    YTTappableView *_touch;
    YTRoundedImageView *_thumb;
    UIView *_watchedTrack;
    UIView *_watchedFill;
    double _watchedShare;

    YTPillView *_durationPill;
    UILabel *_duration;
    YTRoundedImageView *_avatar;
    UILabel *_title;
    UILabel *_meta;

    YTVideoItem *_item;
}

+ (CGFloat)thumbHeightForWidth:(CGFloat)width {
    // 16:9 — пропорция превью YouTube; `Stretch="UniformToFill"` в оригинале
    // вписывает картинку в место именно такой формы.
    return floor(width * 9.0 / 16.0);
}

/**
 * У вертикального ролика превью само вертикальное — 9:16.
 *
 * Вписанное в место под 16:9, оно обрезалось по бокам, и от кадра
 * оставалась узкая полоса посередине: в выдаче поиска по Shorts это
 * было видно на каждой карточке.
 */
+ (CGFloat)thumbHeightForWidth:(CGFloat)width portrait:(BOOL)portrait {
    if (!portrait) {
        return [self thumbHeightForWidth:width];
    }

    return floor(width * 16.0 / 9.0);
}

+ (CGFloat)heightForWidth:(CGFloat)width item:(YTVideoItem *)item {
    CGFloat titleHeight = ceil([YTFontMedium(14) lineHeight]);
    CGFloat metaHeight = ceil([YTFontRegular(12) lineHeight]);

    /**
     * Высота считается один раз и хранится в строке списка, а не пересчётом
     * на каждый запрос: таблица спрашивает высоту всех строк при каждом
     * обновлении, а лента дописывается страницами. Здесь считать нечего —
     * обе подписи в одну строку, — но правило то же.
     */
    CGFloat text = titleHeight + YTCardTextGap + metaHeight;

    // Кружок 36 бывает выше двух строк текста — берём большее.
    CGFloat metaBlock = MAX(text, YTCardAvatar);

    return [self thumbHeightForWidth:width portrait:item.isShort]
         + YTCardMetaTop + metaBlock;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    /**
     * Карточка рисует свою подложку сама — значит, сама и прозрачна.
     *
     * `UIViewContentModeRedraw` здесь по той же причине, что и у
     * таблетки: без него UIKit при смене размера растянул бы готовую
     * картинку, а у выпуклого листа кромка в одну точку — растянутая,
     * она расплылась бы.
     */
    [self setBackgroundColor:[UIColor clearColor]];
    [self setOpaque:NO];
    [self setContentMode:UIViewContentModeRedraw];

    _touch = [[YTTappableView alloc] initWithFrame:CGRectZero];

    // Подсветку не рисуем: в оригинале карточка это Button со сплошь
    // прозрачным шаблоном (CardButtonStyle), без состояния нажатия.
    [_touch setHighlights:NO];
    [self addSubview:_touch];

    _thumbRadius = YTThumbRadius;

    _thumb = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];
    [_thumb setCornerRadius:_thumbRadius];
    [_touch addSubview:_thumb];

    /**
     * Плашка длительности — подложка и подпись раздельно.
     *
     * В разметке это `Border` с `TextBlock` внутри, и здесь так же.
     * Раньше это был один `UILabel`, рисовавший себе фон в `drawRect:`,
     * — приём рабочий, но `UILabel` с переопределённым `drawRect:`
     * на разных версиях iOS ведёт себя по-разному, и подписи не было
     * видно вовсе. Двумя видами надёжнее и ближе к оригиналу.
     */
    /**
     * Полоска просмотра по нижнему краю кадра.
     *
     * Кладётся до плашки длительности: та лежит в том же углу, и полоска
     * не должна её перекрывать.
     */
    _watchedTrack = [[UIView alloc] initWithFrame:CGRectZero];
    [_watchedTrack setUserInteractionEnabled:NO];
    [_touch addSubview:_watchedTrack];

    _watchedFill = [[UIView alloc] initWithFrame:CGRectZero];
    [_watchedFill setUserInteractionEnabled:NO];
    [_touch addSubview:_watchedFill];

    _durationPill = [[YTPillView alloc] initWithFrame:CGRectZero];
    [_durationPill setCornerRadius:4];
    [_durationPill setFillColor:[YTTheme badge]];
    [_touch addSubview:_durationPill];

    _duration = YTLabel(YTFontMedium(12), [UIColor whiteColor], 1);
    [_duration setTextAlignment:NSTextAlignmentCenter];
    [_touch addSubview:_duration];

    _avatar = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];
    [_avatar setCircular:YES];
    [_touch addSubview:_avatar];

    _title = YTLabel(YTFontMedium(14), [YTTheme primaryText], 1);
    [_touch addSubview:_title];

    _meta = YTLabel(YTFontRegular(12), [YTTheme mutedText], 1);
    [_touch addSubview:_meta];

    __weak YTVideoCard *weakSelf = self;

    [_touch setOnTap:^{
        YTVideoCard *card = weakSelf;

        if (card == nil || card->_item == nil) {
            return;
        }

        /**
         * Карточка без ролика и без подборки — это канал: так приходят
         * результаты поиска с фильтром «Каналы». Открывается он своим
         * экраном.
         */
        if ([card->_item.videoId length] == 0 &&
            [card->_item.playlistId length] == 0 &&
            [card->_item.channelId length] > 0) {
            [YTNav openChannel:card->_item.channelId title:card->_item.title];

            return;
        }

        // Карточка без ролика — это подборка целиком, и открывается она
        // своим экраном. Карточка с роликом, но с идентификатором подборки,
        // — это микс: открывается ролик, а подборка едет с ним очередью.
        if ([card->_item isPlaylist]) {
            [YTNav openPlaylist:card->_item.playlistId title:card->_item.title];
        } else if (card->_item.isShort) {
            /**
             * Вертикальный ролик открывается листалкой, а не страницей.
             *
             * Обычная страница для него неудобна: кадр 9:16 занимает
             * половину экрана, а листать соседние ролики нечем. В оригинале
             * из выдачи открывается именно лента, начинающаяся с выбранного.
             */
            [YTNav openShort:card->_item];
        } else {
            [YTNav openVideo:card->_item.videoId
                       title:card->_item.title
                    playlist:card->_item.playlistId
                    resumeAt:card->_item.resumeAt];
        }
    }];

    return self;
}

- (void)setThumbRadius:(CGFloat)thumbRadius {
    _thumbRadius = thumbRadius;
    [_thumb setCornerRadius:thumbRadius];
}

/**
 * Подложка карточки.
 *
 * Пусто при обычном оформлении — карточка там и была без фона, лежала
 * прямо на странице. При объёмном рисуется выпуклый лист; отступ в точку
 * оставлен тени, иначе она обрезалась бы по краю вида.
 */
- (void)drawRect:(CGRect)rect {
    [YTSkin drawCardInRect:CGRectInset([self bounds], 1, 1)];
}

- (void)bind:(YTVideoItem *)item {
    _item = item;

    /**
     * Цвета назначаются здесь, вместе с данными, а не в конструкторе.
     *
     * Ячейки живут в пуле переработки и смену темы переживают: `reloadData`
     * их не пересоздаёт, а перепривязывает. Цвет, взятый однажды при
     * создании, так и остался бы прежним, и в темноте подписи оказались бы
     * тёмными на тёмном.
     */
    [_title setTextColor:[YTTheme primaryText]];
    [_meta setTextColor:[YTTheme mutedText]];

    [_thumb setPlaceholderColor:[YTTheme surfaceAlt]];
    [_avatar setPlaceholderColor:[YTTheme avatarPlaceholder]];

    [_title setText:item.title];
    [_meta setText:[item metadataLine]];

    /**
     * Докуда досмотрен: своя запись, сервер этого не присылает.
     * У эфиров и подборок просмотра нет — полоску не показываем.
     */
    /**
     * Долю просмотра берём только у сервера.
     *
     * Своё хранилище было временной подпоркой, пока я считал, что
     * TV-клиенту этого не присылают. Присылают — и в «Истории», и в
     * «Подписках», и в рекомендациях. Сервер знает о просмотрах со всех
     * устройств человека, а хранилище знало только о здешних и вдобавок
     * расходилось с ним.
     */
    _watchedShare = (item.isLive || [item.playlistId length] > 0)
        ? 0 : MAX(0.0, item.watchedShare);

    /**
     * Объём карточке даёт собственная отрисовка, а не цвет слоя.
     *
     * Цветом и каймой лист не сделаешь: нужны тень, отлив и светлая
     * кромка — всё это рисуется разом в `drawRect:` ниже. Здесь только
     * просим перерисоваться: оформление могло смениться, пока ячейка
     * лежала в пуле.
     */
    [self setNeedsDisplay];

    [_watchedTrack setBackgroundColor:[UIColor colorWithWhite:1 alpha:0.28]];
    [_watchedFill setBackgroundColor:YTColor(0xFF0000)];

    [_watchedTrack setHidden:(_watchedShare <= 0)];
    [_watchedFill setHidden:(_watchedShare <= 0)];

    // Плашка одинакова в обеих темах: она лежит поверх кадра, а не поверх
    // страницы, и её фон задан числом (#CC000000), а не кистью темы.
    [_durationPill setFillColor:[YTTheme badge]];

    [_duration setText:item.duration];

    BOOL hasDuration = [item.duration length] > 0;

    [_duration setHidden:!hasDuration];
    [_durationPill setHidden:!hasDuration];

    // Кружок автора можно выключить в настройках — `ChannelIconsToggleButton`.
    BOOL hasAvatar = [item.channelThumbnail length] > 0 && [YTSettings showsChannelIcons];

    [_avatar setHidden:!hasAvatar];

    // Ширина превью известна только после раскладки, поэтому загрузку
    // заказываем оттуда — там же, где считается место под картинку.
    [self setNeedsLayout];

    if (hasAvatar) {
        [YTImageLoader loadInto:_avatar url:item.channelThumbnail targetWidth:YTCardAvatar];
    } else {
        [YTImageLoader loadInto:_avatar url:nil targetWidth:YTCardAvatar];
    }
}

- (void)layoutSubviews {
    CGRect box = [self bounds];

    [_touch setFrame:box];

    CGFloat width = box.size.width;
    CGFloat thumbHeight = [[self class] thumbHeightForWidth:width
                                                   portrait:_item.isShort];

    [_thumb setFrame:CGRectMake(0, 0, width, thumbHeight)];

    /**
     * Полоска просмотра — по нижнему краю кадра, в четыре точки: так же,
     * как в оригинале. Скруглению кадра она не мешает: у превью радиус
     * небольшой, и полоска в него вписывается.
     */
    if (![_watchedTrack isHidden]) {
        CGFloat bar = 4;
        CGFloat top = thumbHeight - bar;

        [_watchedTrack setFrame:CGRectMake(0, top, width, bar)];
        [_watchedFill setFrame:CGRectMake(0, top,
                                          (CGFloat)(width * _watchedShare), bar)];
    }

    /**
     * Ширину превью называет сама карточка, и она же по этому числу просит
     * картинку. Иначе легко разъехаться: загрузчик уменьшает кадр под
     * названное число, и если оно не совпадает с местом на экране, картинка
     * либо мылит, либо зря занимает память.
     */
    if (_item != nil) {
        [YTImageLoader loadInto:_thumb url:_item.thumbnail targetWidth:width];
    }

    /**
     * Плашка длительности: снизу справа с отступом 8 от краёв превью.
     * Поля вокруг подписи — `Padding="6,2"` из шаблона.
     */
    CGSize text = [[_duration text] sizeWithFont:[_duration font]];

    CGFloat badgeWidth = ceil(text.width) + 12;
    CGFloat badgeHeight = ceil(text.height) + 4;

    CGRect badge = CGRectMake(width - badgeWidth - 8,
                              thumbHeight - badgeHeight - 8,
                              badgeWidth, badgeHeight);

    [_durationPill setFrame:badge];
    [_duration setFrame:badge];

    CGFloat y = thumbHeight + YTCardMetaTop;
    CGFloat textLeft = 0;

    if (![_avatar isHidden]) {
        [_avatar setFrame:CGRectMake(0, y, YTCardAvatar, YTCardAvatar)];
        textLeft = YTCardAvatar + YTCardMetaGap;
    }

    CGFloat textWidth = width - textLeft;

    CGFloat titleHeight = ceil([[_title font] lineHeight]);
    CGFloat metaHeight = ceil([[_meta font] lineHeight]);

    [_title setFrame:CGRectMake(textLeft, y, textWidth, titleHeight)];
    [_meta setFrame:CGRectMake(textLeft, y + titleHeight + YTCardTextGap,
                               textWidth, metaHeight)];
}

@end


#pragma mark - Ряд карточек

@implementation YTFeedRowCell {
    NSMutableArray *_cards;
    NSArray *_items;
    NSInteger _columns;
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    self = [super initWithStyle:style reuseIdentifier:identifier];

    if (self == nil) {
        return nil;
    }

    _cards = [NSMutableArray array];
    _columns = 1;

    [self setSelectionStyle:UITableViewCellSelectionStyleNone];
    [self setBackgroundColor:[UIColor clearColor]];
    [[self contentView] setBackgroundColor:[UIColor clearColor]];

    /**
     * Обрезку по краям снимаем — и это не мелочь.
     *
     * Ячейку таблица создаёт с высотой по умолчанию и лишь потом выдаёт ей
     * настоящую. Если карточки разложены к этому моменту, всё, что ниже
     * временной высоты, оказывается за границей `contentView`, а тот
     * на новых системах обрезает по умолчанию. Наружу это выходит так:
     * прокрутил ленту — у части карточек остались одни превью, а название,
     * кружок канала и метаданные пропали. Они никуда не делись, их обрезало.
     *
     * Само собой это не чинится: `contentView` потом вырастает, но
     * перерисовки уже не будет — ячейка считает, что ей нечего менять.
     */
    [self setClipsToBounds:NO];
    [[self contentView] setClipsToBounds:NO];

    return self;
}

- (void)bindRow:(NSArray *)items width:(CGFloat)width columns:(NSInteger)columns {
    [self setBackgroundColor:[YTTheme background]];
    [[self contentView] setBackgroundColor:[YTTheme background]];

    _items = items;
    _columns = MAX(1, columns);

    // Карточки не пересоздаются, а переиспользуются: ряд может стать
    // шире или уже при повороте, но их число меняется редко.
    while ([_cards count] < [items count]) {
        YTVideoCard *card = [[YTVideoCard alloc] initWithFrame:CGRectZero];

        [[self contentView] addSubview:card];
        [_cards addObject:card];
    }

    for (NSUInteger i = 0; i < [_cards count]; i++) {
        YTVideoCard *card = [_cards objectAtIndex:i];

        if (i >= [items count]) {
            [card setHidden:YES];
            continue;
        }

        [card setHidden:NO];
        [card bind:[items objectAtIndex:i]];
    }

    [self setNeedsLayout];
}

/**
 * Размеры считаются здесь, а не в `bindRow:`.
 *
 * Разница в том, когда известна настоящая ширина: привязка случается
 * раньше, чем таблица выдаст ячейке её размер, и посчитанные тогда рамки
 * относятся к чужому размеру. Здесь ширина уже настоящая.
 */
- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat width = [[self contentView] bounds].size.width;

    if (width <= 0) {
        return;
    }

    CGFloat available = width - YTFeedPadding * 2;
    CGFloat cardWidth = floor((available - YTCardSpacing * (_columns - 1)) / _columns);

    if (cardWidth <= 0) {
        return;
    }

    for (NSUInteger i = 0; i < [_cards count] && i < [_items count]; i++) {
        YTVideoCard *card = [_cards objectAtIndex:i];

        CGFloat height = [YTVideoCard heightForWidth:cardWidth
                                                item:[_items objectAtIndex:i]];

        [card setFrame:CGRectMake(YTFeedPadding + (cardWidth + YTCardSpacing) * i, 0,
                                  cardWidth, height)];
    }
}

@end


#pragma mark - Ряд заглушек

@implementation YTSkeletonRowCell {
    NSMutableArray *_slots;
    NSInteger _columns;
}

+ (CGFloat)heightForWidth:(CGFloat)width columns:(NSInteger)columns {
    UIImage *image = YTIcon(@"skeleton_video");

    if (image == nil || [image size].width <= 0) {
        return 0;
    }

    CGFloat available = width - YTFeedPadding * 2;
    CGFloat cardWidth = floor((available - YTCardSpacing * (MAX(1, columns) - 1))
                              / MAX(1, columns));

    return floor(cardWidth * [image size].height / [image size].width) + YTCardSpacing;
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    self = [super initWithStyle:style reuseIdentifier:identifier];

    if (self == nil) {
        return nil;
    }

    _slots = [NSMutableArray array];
    _columns = 1;

    [self setSelectionStyle:UITableViewCellSelectionStyleNone];
    [self setClipsToBounds:NO];
    [[self contentView] setClipsToBounds:NO];

    return self;
}

- (void)bindColumns:(NSInteger)columns {
    _columns = MAX(1, columns);

    [self setBackgroundColor:[YTTheme background]];
    [[self contentView] setBackgroundColor:[YTTheme background]];

    while ((NSInteger)[_slots count] < _columns) {
        UIImageView *slot = [[UIImageView alloc] initWithFrame:CGRectZero];

        [slot setContentMode:UIViewContentModeScaleToFill];
        [slot setUserInteractionEnabled:NO];

        [[self contentView] addSubview:slot];
        [_slots addObject:slot];
    }

    for (NSUInteger i = 0; i < [_slots count]; i++) {
        UIImageView *slot = [_slots objectAtIndex:i];

        // Значок берётся при каждой привязке: ячейки переживают смену темы.
        [slot setImage:YTIcon(@"skeleton_video")];
        [slot setHidden:((NSInteger)i >= _columns)];
    }

    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat width = [[self contentView] bounds].size.width;

    if (width <= 0) {
        return;
    }

    CGFloat available = width - YTFeedPadding * 2;
    CGFloat cardWidth = floor((available - YTCardSpacing * (_columns - 1)) / _columns);

    UIImage *image = YTIcon(@"skeleton_video");

    if (image == nil || [image size].width <= 0 || cardWidth <= 0) {
        return;
    }

    CGFloat height = floor(cardWidth * [image size].height / [image size].width);

    for (NSInteger i = 0; i < _columns && i < (NSInteger)[_slots count]; i++) {
        [[_slots objectAtIndex:i]
            setFrame:CGRectMake(YTFeedPadding + (cardWidth + YTCardSpacing) * i, 0,
                                cardWidth, height)];
    }
}

@end


#pragma mark - Таблетка категории

@implementation YTChipView {
    YTPillView *_fill;
    UILabel *_label;
    YTTappableView *_touch;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    _fill = [[YTPillView alloc] initWithFrame:CGRectZero];
    [_fill setCornerRadius:YTChipRadius];
    [self addSubview:_fill];

    _label = YTLabel(YTFontSemiBold(14), [YTTheme primaryText], 1);
    [_label setTextAlignment:NSTextAlignmentCenter];
    [self addSubview:_label];

    _touch = [[YTTappableView alloc] initWithFrame:CGRectZero];
    [_touch setHighlights:NO];
    [self addSubview:_touch];

    __weak YTChipView *weakSelf = self;

    [_touch setOnTap:^{
        YTChipView *chip = weakSelf;

        if (chip != nil && chip.onTap != nil) {
            chip.onTap();
        }
    }];

    return self;
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];

    [_label setText:title];
    [self applyState];
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    [self applyState];
}

- (void)applyState {
    // Цвета берутся при каждой привязке: полоса категорий переживает
    // смену темы так же, как ячейки списка.
    [_fill setFillColor:_selected ? [YTTheme primaryActionBackground] : [YTTheme surface]];
    [_label setTextColor:_selected ? [YTTheme primaryActionForeground] : [YTTheme primaryText]];
}

- (CGFloat)widthForTitle {
    CGSize size = [(_title ?: @"") sizeWithFont:[_label font]];

    // MinWidth="48" из CategoryChipButtonStyle.
    return MAX(48, ceil(size.width) + YTChipPadding * 2);
}

- (void)layoutSubviews {
    CGRect box = [self bounds];

    [_fill setFrame:box];
    [_label setFrame:box];
    [_touch setFrame:box];
}

@end
