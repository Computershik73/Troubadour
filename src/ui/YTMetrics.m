#import "YTMetrics.h"

#import "YTText.h"
#import "YTSkin.h"
#import "YTTheme.h"

const CGFloat YTTabBarHeight   = 50;
const CGFloat YTTabBarDivider  = 2;
const CGFloat YTNavBarHeight   = 56;
const CGFloat YTChipsBarHeight = 48;
const CGFloat YTChipHeight     = 36;
const CGFloat YTChipRadius     = 9;
const CGFloat YTChipPadding    = 14;
const CGFloat YTFeedPadding    = 8;
const CGFloat YTCardSpacing    = 16;
const CGFloat YTThumbRadius    = 8;
const CGFloat YTCardAvatar     = 36;
const CGFloat YTCardWidth      = 360;

#pragma mark Шрифты

/**
 * Начертание по имени, с откатом на системное.
 *
 * Откат нужен не для красоты: если файл шрифта почему-либо не зарегистрируется
 * (не тот путь в UIAppFonts, обрезанная связка), `fontWithName:` вернёт nil,
 * а подпись с nil-шрифтом на iOS 5 не рисуется вовсе — экран остаётся пустым.
 * Лучше чужой шрифт, чем пустой экран.
 */
static UIFont *YTFont(NSString *name, CGFloat size, BOOL heavy) {
    UIFont *font = [UIFont fontWithName:name size:size];

    if (font != nil) {
        return font;
    }

    return heavy ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
}

UIFont *YTFontRegular(CGFloat size)  { return YTFont(@"Roboto-Regular",  size, NO);  }
UIFont *YTFontMedium(CGFloat size)   { return YTFont(@"Roboto-Medium",   size, NO);  }
UIFont *YTFontSemiBold(CGFloat size) { return YTFont(@"Roboto-SemiBold", size, YES); }
UIFont *YTFontBold(CGFloat size)     { return YTFont(@"Roboto-Bold",     size, YES); }

#pragma mark Значки

static NSMutableDictionary *YTIconCache(void) {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{ cache = [[NSMutableDictionary alloc] init]; });

    return cache;
}

void YTIconCacheDrop(void) {
    @synchronized (YTIconCache()) {
        [YTIconCache() removeAllObjects];
    }
}

/**
 * Ищет файл под нужную плотность и собирает картинку с явным масштабом.
 *
 * Порядок перебора — от плотности экрана вниз: на «тройке» сперва @3x,
 * потом @2x, потом обычный. Так значок никогда не пропадает целиком, даже
 * если какого-то варианта в связке не оказалось, — он просто окажется
 * чуть мягче.
 */
static UIImage *YTLoadImage(NSString *base) {
    CGFloat screenScale = 1;

    // `scale` у экрана появился в iOS 4; проверка оставлена на случай
    // запуска на чём-то ещё более старом, куда мы формально не целимся.
    if ([[UIScreen mainScreen] respondsToSelector:@selector(scale)]) {
        screenScale = [[UIScreen mainScreen] scale];
    }

    NSInteger start = (NSInteger)ceil(screenScale);
    if (start < 1) { start = 1; }
    if (start > 3) { start = 3; }

    for (NSInteger scale = start; scale >= 1; scale--) {
        NSString *name = scale > 1
            ? [NSString stringWithFormat:@"%@@%ldx", base, (long)scale]
            : base;

        NSString *path = [[NSBundle mainBundle] pathForResource:name
                                                         ofType:@"png"
                                                    inDirectory:@"Assets"];
        if (path == nil) {
            continue;
        }

        // Масштаб проставляется явно. `imageWithContentsOfFile:` выводит его
        // из имени файла, и для файла в подкаталоге связки на старых системах
        // это срабатывает не всегда: значок приезжал бы вчетверо крупнее
        // места. Здесь масштаб известен точно — мы его и ставим.
        UIImage *raw = [UIImage imageWithContentsOfFile:path];
        if (raw == nil) {
            continue;
        }

        if ([UIImage respondsToSelector:@selector(imageWithCGImage:scale:orientation:)]) {
            return [UIImage imageWithCGImage:[raw CGImage]
                                       scale:scale
                                 orientation:UIImageOrientationUp];
        }

        return raw;
    }

    NSLog(@"[YouTube/Значки] Не найден значок %@", base);

    return nil;
}

UIImage *YTImage(NSString *name) {
    if ([name length] == 0) {
        return nil;
    }

    @synchronized (YTIconCache()) {
        UIImage *cached = [YTIconCache() objectForKey:name];
        if (cached != nil) {
            return cached;
        }

        UIImage *image = YTLoadImage(name);
        if (image != nil) {
            [YTIconCache() setObject:image forKey:name];
        }

        return image;
    }
}

UIImage *YTTintedImage(UIImage *picture, UIColor *color) {
    if (picture == nil || color == nil) {
        return picture;
    }

    CGSize size = [picture size];

    if (size.width <= 0 || size.height <= 0) {
        return picture;
    }

    /**
     * Рисуем в отдельном слое и заливаем через режим `SourceIn`.
     *
     * Значки у нас одноцветные с прозрачным фоном, поэтому исходная
     * картинка годится трафаретом как есть: заливка ложится ровно туда,
     * где были непрозрачные точки, и края остаются мягкими.
     */
    UIGraphicsBeginImageContextWithOptions(size, NO, [picture scale]);

    CGContextRef context = UIGraphicsGetCurrentContext();

    CGRect box = CGRectMake(0, 0, size.width, size.height);

    [picture drawInRect:box];

    CGContextSetBlendMode(context, kCGBlendModeSourceIn);
    CGContextSetFillColorWithColor(context, [color CGColor]);
    CGContextFillRect(context, box);

    UIImage *painted = UIGraphicsGetImageFromCurrentImageContext();

    UIGraphicsEndImageContext();

    return painted ?: picture;
}

UIImage *YTIcon(NSString *name) {
    if ([name length] == 0) {
        return nil;
    }

    /**
     * Оформление вправе подменить значок.
     *
     * Точка одна на всё приложение — оттого один набор и меняет весь
     * облик разом, не трогая ни одного экрана. Нет подмены — берём своё,
     * как и раньше.
     */
    UIImage *skinned = [YTSkin iconNamed:name dark:[YTTheme isDark]];

    if (skinned != nil) {
        return skinned;
    }

    // Набор выбирается по теме — то же, что делал ThemeAsset.Path в UWP.
    NSString *full = [NSString stringWithFormat:@"%@%@",
                      name, [YTTheme isDark] ? @"_dark" : @"_light"];

    return YTImage(full);
}

UIImage *YTDarkIcon(NSString *name) {
    if ([name length] == 0) {
        return nil;
    }

    UIImage *skinned = [YTSkin iconNamed:name dark:YES];

    if (skinned != nil) {
        return skinned;
    }

    return YTImage([name stringByAppendingString:@"_dark"]);
}

#pragma mark Размеры

NSInteger YTColumnsForWidth(CGFloat width) {
    /**
     * `ItemsWrapGrid ItemWidth="360" MaximumRowsOrColumns="3"` из Home.xaml:
     * сколько карточек шириной 360 помещается, столько и колонок, но
     * не больше трёх.
     *
     * Ширина здесь — уже за вычетом отступов списка, поэтому считать нужно
     * от неё, а не от экрана: на телефоне 320 точек за вычетом 8+8 остаётся
     * 304, и это честно одна колонка.
     */
    NSInteger columns = (NSInteger)floor(width / YTCardWidth);

    /**
     * На широком экране считаем не по 360, а по 300 точек.
     *
     * Число 360 из оригинала выведено для экранов Windows 10 Mobile —
     * от 480 до 720 точек, — и там три колонки набирались только
     * на самых широких. Планшет в это правило не укладывается вовсе:
     * у iPad mini в альбомной ориентации доступно чуть больше тысячи
     * точек, буквальное правило даёт две колонки, карточка выходит
     * в полтысячи точек шириной, и на экран помещается ровно две штуки.
     *
     * Поэтому от восьмисот точек берётся мера поменьше. Три колонки
     * на тысяче — это по 336 точек на карточку: чуть уже, чем задумано
     * в оригинале, но заметно крупнее, чем на телефоне, где карточка
     * занимает все триста с небольшим.
     *
     * Потолок в три колонки остаётся: `MaximumRowsOrColumns="3"`.
     */
    if (width >= 800) {
        columns = (NSInteger)floor(width / 300.0);
    }

    if (columns < 1) { columns = 1; }
    if (columns > 3) { columns = 3; }

    return columns;
}

#pragma mark Текст

CGFloat YTTextHeight(NSString *text, UIFont *font, CGFloat width, NSInteger maxLines) {
    if ([text length] == 0 || font == nil || width <= 0) {
        return 0;
    }

    CGFloat line = [font lineHeight];

    /**
     * Потолок «без ограничения» — большое число, а не `CGFLOAT_MAX`.
     *
     * На armv7 `CGFloat` — это `float`, и `CGFLOAT_MAX` там 3.4e38.
     * Внутри замера над этим числом ещё считают, и любое сложение выводит
     * его в бесконечность; бесконечность возвращается наружу высотой,
     * из неё делается рамка подписи, а рисование такой рамки роняет
     * CoreText без единой нашей строки в отчёте. Ста тысяч точек хватит
     * любому тексту, какой мы показываем.
     */
    CGFloat limit = maxLines > 0 ? line * maxLines + 1 : 100000;

    // Перенос по словам, а не усечение: усечение нужно самой подписи, чтобы
    // поставить многоточие в последней строке, а при измерении оно только
    // мешает посчитать, сколько строк выйдет.
    CGSize size = [text sizeWithFont:font
                   constrainedToSize:CGSizeMake(width, limit)
                       lineBreakMode:NSLineBreakByWordWrapping];

    if (maxLines > 0 && size.height > line * maxLines) {
        return line * maxLines;
    }

    // Заведомо конечная величина: не бесконечность и не NaN, что бы там
    // ни насчитали. Такое число дальше становится рамкой подписи, а с
    // негодной рамкой рисование текста падает.
    if (!isfinite(size.height) || size.height < 0) {
        return 0;
    }

    return ceil(size.height);
}

/**
 * Обрезает текст, не разрывая символов.
 *
 * `substringToIndex:` считает в кодовых единицах UTF-16, а эмодзи и прочее
 * за пределами основной таблицы занимают две таких единицы. Резать между
 * ними нельзя: получается половина пары, строка перестаёт быть правильным
 * UTF-16, и CoreText на ней падает. Поэтому граница отодвигается к началу
 * ближайшего целого символа.
 */
NSString *YTClampText(NSString *text, NSUInteger limit) {
    if ([text length] <= limit) {
        return text;
    }

    NSRange whole = [text rangeOfComposedCharacterSequenceAtIndex:limit];

    return [[text substringToIndex:whole.location] stringByAppendingString:@"…"];
}


/**
 * Подпись, которая не падает от битой строки.
 *
 * Главный присмотр стоит у входа — при разборе ответа сервера, — но текст
 * попадает в подпись и не оттуда: из настроек, из сохранённого имени,
 * из чужой строки в будущем коде. Проверка здесь обычному тексту ничего
 * не стоит и закрывает эти пути разом.
 */
@interface YTSafeLabel : UILabel
@end

@implementation YTSafeLabel

- (void)setText:(NSString *)text {
    [super setText:YTSafeText(text)];
}

@end

UILabel *YTLabel(UIFont *font, UIColor *color, NSInteger lines) {
    UILabel *label = [[YTSafeLabel alloc] initWithFrame:CGRectZero];

    [label setFont:font];
    [label setTextColor:color];
    [label setBackgroundColor:[UIColor clearColor]];
    [label setNumberOfLines:lines];
    [label setLineBreakMode:lines == 1 ? NSLineBreakByTruncatingTail
                                       : NSLineBreakByWordWrapping];

    // Подписи ничего не принимают: нажатие должно доставаться карточке,
    // внутри которой они лежат. У UILabel этот флаг и так снят, но у нас
    // он проставлен везде явно — чтобы правило было видно в коде.
    [label setUserInteractionEnabled:NO];

    return label;
}

#pragma mark Общие виды

@implementation YTBadgeLabel

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self != nil) {
        _padding = UIEdgeInsetsMake(2, 6, 2, 6);

        [self setFont:YTFontMedium(12)];
        [self setTextColor:[UIColor whiteColor]];
        [self setBackgroundColor:[UIColor clearColor]];
        [self setTextAlignment:NSTextAlignmentCenter];
        [self setUserInteractionEnabled:NO];
    }

    return self;
}

- (void)setText:(NSString *)text {
    [super setText:YTSafeText(text)];
}

- (CGSize)badgeSize {
    NSString *text = [self text];

    if ([text length] == 0) {
        return CGSizeZero;
    }

    CGSize size = [text sizeWithFont:[self font]];

    return CGSizeMake(ceil(size.width) + _padding.left + _padding.right,
                      ceil(size.height) + _padding.top + _padding.bottom);
}

- (void)drawRect:(CGRect)rect {
    if ([[self text] length] == 0) {
        return;
    }

    CGContextRef context = UIGraphicsGetCurrentContext();

    // Плашка одинакова в обеих темах: она лежит поверх кадра, а не поверх
    // страницы, и её фон задан числом (#CC000000), а не кистью темы.
    CGContextSetFillColorWithColor(context, [[YTTheme badge] CGColor]);

    CGFloat radius = 4;
    CGRect box = [self bounds];

    /**
     * Плашка уже своих полей — рисовать нечего.
     *
     * Иначе `UIEdgeInsetsInsetRect` вернёт рамку отрицательной ширины,
     * а отрисовка текста в такой рамке роняет CoreText: в отчёте видно
     * только его самого, ни одной нашей строки, — и понять, откуда взялось
     * падение, по такому отчёту нельзя. Проверка стоит копейки.
     */
    if (box.size.width <= _padding.left + _padding.right ||
        box.size.height <= _padding.top + _padding.bottom) {
        return;
    }

    CGContextBeginPath(context);
    CGContextMoveToPoint(context, CGRectGetMinX(box) + radius, CGRectGetMinY(box));
    CGContextAddArcToPoint(context, CGRectGetMaxX(box), CGRectGetMinY(box),
                           CGRectGetMaxX(box), CGRectGetMaxY(box), radius);
    CGContextAddArcToPoint(context, CGRectGetMaxX(box), CGRectGetMaxY(box),
                           CGRectGetMinX(box), CGRectGetMaxY(box), radius);
    CGContextAddArcToPoint(context, CGRectGetMinX(box), CGRectGetMaxY(box),
                           CGRectGetMinX(box), CGRectGetMinY(box), radius);
    CGContextAddArcToPoint(context, CGRectGetMinX(box), CGRectGetMinY(box),
                           CGRectGetMaxX(box), CGRectGetMinY(box), radius);
    CGContextClosePath(context);
    CGContextFillPath(context);

    [super drawTextInRect:UIEdgeInsetsInsetRect(box, _padding)];
}

@end


@implementation YTPillView

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self != nil) {
        _cornerRadius = YTChipRadius;
        _fillColor = [YTTheme surface];

        [self setBackgroundColor:[UIColor clearColor]];
        [self setOpaque:NO];

        /**
         * Перерисовка при смене размера — обязательна.
         *
         * Вид рисует себя сам в `drawRect:`, а UIKit по умолчанию при
         * смене рамки не перерисовывает, а **растягивает** уже готовую
         * картинку. Пока ширина не менялась, это незаметно; но подложка
         * оценки раздаётся вширь, когда приезжает счётчик лайков, —
         * и круглые торцы растягивались в овалы. То же самое случалось
         * с кнопкой подписки, когда «Подписаться» сменялось на «Вы
         * подписаны».
         */
        [self setContentMode:UIViewContentModeRedraw];

        // Только рисует — нажатие принимает то, внутри чего он лежит.
        // В UIKit `userInteractionEnabled` у UIView включён с рождения,
        // и вид молча забирает касание себе, никому его не передавая.
        [self setUserInteractionEnabled:NO];
    }

    return self;
}

- (void)setFillColor:(UIColor *)fillColor {
    _fillColor = fillColor;
    [self setNeedsDisplay];
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    _cornerRadius = cornerRadius;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGRect box = [self bounds];

    // Скругление не больше половины меньшей стороны: у кнопок вроде
    // «Подписаться» радиус задаётся заведомо большим числом, чтобы получились
    // полукруглые торцы, и без этой поправки дуги наложились бы друг на друга.
    CGFloat radius = MIN(_cornerRadius, MIN(box.size.width, box.size.height) / 2);

    /**
     * Объёмное оформление рисует таблетку по-своему.
     *
     * Точка одна на всё приложение: таблетками нарисованы и категории
     * на главной, и «Подписаться», и подложка блока комментариев. Тёмной
     * считаем ту, что залита цветом основного действия, — это выбранная
     * таблетка и нажатая кнопка.
     */
    UIColor *fill = _fillColor ?: [YTTheme surface];

    BOOL pressed = [fill isEqual:[YTTheme primaryActionBackground]]
                || [fill isEqual:[YTTheme primaryText]];

    /**
     * Полупрозрачные плашки — длительность на превью — кнопками не делаем.
     *
     * Они лежат поверх картинки и должны просто затемнять её под белой
     * цифрой; светлая кнопка под белой цифрой оставила бы плашку пустой.
     */
    BOOL translucent = CGColorGetAlpha([fill CGColor]) < 0.99;

    if (!translucent && [YTSkin drawRaisedInRect:box radius:radius dark:pressed]) {
        return;
    }

    CGContextSetFillColorWithColor(context, [fill CGColor]);

    CGContextBeginPath(context);
    CGContextMoveToPoint(context, CGRectGetMinX(box) + radius, CGRectGetMinY(box));
    CGContextAddArcToPoint(context, CGRectGetMaxX(box), CGRectGetMinY(box),
                           CGRectGetMaxX(box), CGRectGetMaxY(box), radius);
    CGContextAddArcToPoint(context, CGRectGetMaxX(box), CGRectGetMaxY(box),
                           CGRectGetMinX(box), CGRectGetMaxY(box), radius);
    CGContextAddArcToPoint(context, CGRectGetMinX(box), CGRectGetMaxY(box),
                           CGRectGetMinX(box), CGRectGetMinY(box), radius);
    CGContextAddArcToPoint(context, CGRectGetMinX(box), CGRectGetMinY(box),
                           CGRectGetMaxX(box), CGRectGetMinY(box), radius);
    CGContextClosePath(context);
    CGContextFillPath(context);
}

@end
