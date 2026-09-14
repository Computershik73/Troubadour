#import "YTSkin.h"

#import "YTMetrics.h"
#import "YTStrings.h"
#import "YTTheme.h"

NSString *const YTSkinFlat = @"flat";
NSString *const YTSkinClassic = @"ios6";

static NSString *const YTSkinKey = @"yt_skin";

/**
 * Вертикальный градиент в картинку шириной в точку.
 *
 * Ширина в одну точку — не экономия, а способ: такой картинкой красят
 * фон (`colorWithPatternImage:`), и она размножается по горизонтали сама,
 * во всю ширину полосы, какой бы та ни была. По вертикали размножения
 * не происходит: высота картинки ровно в высоту полосы.
 */
static UIImage *YTVerticalGradient(CGFloat height,
                                   UIColor *top,
                                   UIColor *bottom,
                                   UIColor *hairTop,
                                   UIColor *hairBottom) {
    if (height <= 0) {
        return nil;
    }

    CGFloat scale = [[UIScreen mainScreen] respondsToSelector:@selector(scale)]
        ? [[UIScreen mainScreen] scale] : 1.0;

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(1, height), NO, scale);

    CGContextRef context = UIGraphicsGetCurrentContext();

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();

    NSArray *colors = [NSArray arrayWithObjects:
        (id)[top CGColor], (id)[bottom CGColor], nil];

    CGGradientRef gradient = CGGradientCreateWithColors(space,
        (__bridge CFArrayRef)colors, NULL);

    CGContextDrawLinearGradient(context, gradient,
                                CGPointMake(0, 0), CGPointMake(0, height), 0);

    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);

    CGFloat hair = 1.0 / scale;

    if (hairTop != nil) {
        CGContextSetFillColorWithColor(context, [hairTop CGColor]);
        CGContextFillRect(context, CGRectMake(0, 0, 1, hair));
    }

    if (hairBottom != nil) {
        CGContextSetFillColorWithColor(context, [hairBottom CGColor]);
        CGContextFillRect(context, CGRectMake(0, height - hair, 1, hair));
    }

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();

    UIGraphicsEndImageContext();

    return image;
}

/**
 * Подобранные значки живут в памяти до смены оформления.
 *
 * Спрашивают их на каждой привязке ячейки — по десятку раз на экран
 * прокрутки, — а стоит подбор недёшево: поиск файла, чтение, перерисовка
 * под наш размер. Считать это заново на каждый кадр прокрутки нельзя.
 */
static NSMutableDictionary *YTSkinCache(void) {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{ cache = [[NSMutableDictionary alloc] init]; });

    return cache;
}

/**
 * Подложка полосы: знает только одно — как себя нарисовать.
 *
 * Живёт первым подвидом внутри самой полосы и тянется вместе с ней.
 * `UIViewContentModeRedraw` здесь обязателен: без него UIKit при смене
 * размера растянул бы прежнюю картинку вместо того, чтобы позвать
 * рисование заново, и волоски по краям расплылись бы.
 */
@interface YTSkinBarBacking : UIView
@end

@implementation YTSkinBarBacking

- (void)drawRect:(CGRect)rect {
    [YTSkin drawBarInRect:[self bounds]];
}

@end


@implementation YTSkinShelfView

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self != nil) {
        [self setBackgroundColor:[UIColor clearColor]];
        [self setOpaque:NO];
        [self setUserInteractionEnabled:NO];
        [self setContentMode:UIViewContentModeRedraw];
    }

    return self;
}

- (void)drawRect:(CGRect)rect {
    [YTSkin drawHeaderInRect:[self bounds]];
}

@end


@implementation YTSkin

+ (void)dropCache {
    @synchronized (YTSkinCache()) {
        [YTSkinCache() removeAllObjects];
    }
}

+ (NSString *)current {
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:YTSkinKey];

    return [saved isEqualToString:YTSkinClassic] ? YTSkinClassic : YTSkinFlat;
}

+ (void)setCurrent:(NSString *)skin {
    [[NSUserDefaults standardUserDefaults]
        setObject:([skin isEqualToString:YTSkinClassic] ? YTSkinClassic : YTSkinFlat)
           forKey:YTSkinKey];

    [[NSUserDefaults standardUserDefaults] synchronize];

    NSLog(@"[YouTube/Оформление] Выбрано: %@", [self titleFor:skin]);

    [self dropCache];

    [[NSNotificationCenter defaultCenter]
        postNotificationName:YTThemeChangedNotification object:nil];
}

+ (BOOL)isClassic {
    return [[self current] isEqualToString:YTSkinClassic];
}

+ (NSArray *)options {
    return [NSArray arrayWithObjects:YTSkinFlat, YTSkinClassic, nil];
}

+ (NSString *)titleFor:(NSString *)skin {
    return [skin isEqualToString:YTSkinClassic]
        ? YTLoc(@"Как в iOS 6") : YTLoc(@"Обычное");
}

+ (NSString *)hintFor:(NSString *)skin {
    return [skin isEqualToString:YTSkinClassic]
        ? YTLoc(@"Объёмное оформление той эпохи: градиенты на полосах, "
                @"фаски у кнопок, светлый фон под карточками")
        : YTLoc(@"Плоское, как у нынешнего YouTube");
}

#pragma mark Картинки набора

+ (UIImage *)assetNamed:(NSString *)name {
    if ([name length] == 0 || ![self isClassic]) {
        return nil;
    }

    NSString *skin = [self current];

    /**
     * Свой каталог человека — первым.
     *
     * Принесённый набор должен перекрывать встроенный, а не наоборот:
     * иначе положить своё было бы некуда.
     */
    NSString *library = [NSSearchPathForDirectoriesInDomains(
        NSLibraryDirectory, NSUserDomainMask, YES) lastObject];

    NSArray *roots = [NSArray arrayWithObjects:
        [library stringByAppendingPathComponent:@"Skins"],
        [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Skins"],
        nil];

    CGFloat scale = [[UIScreen mainScreen] respondsToSelector:@selector(scale)]
        ? [[UIScreen mainScreen] scale] : 1.0;

    NSFileManager *files = [NSFileManager defaultManager];

    for (NSString *root in roots) {
        NSString *folder = [root stringByAppendingPathComponent:skin];

        /**
         * Двойной размер зовётся `_2x`, а не `@2x`.
         *
         * Так подписаны файлы в наборе; собачку UIKit подставляет сам
         * только своим ресурсам, а эти лежат отдельной папкой и ищутся
         * руками. Обе записи проверяем — набор может прийти и с собачкой.
         */
        if (scale > 1.5) {
            NSArray *doubles = [NSArray arrayWithObjects:
                [NSString stringWithFormat:@"%@@2x.png", name],
                [NSString stringWithFormat:@"%@_2x.png", name], nil];

            for (NSString *twice in doubles) {
                NSString *path = [folder stringByAppendingPathComponent:twice];

                if ([files fileExistsAtPath:path]) {
                    UIImage *raw = [UIImage imageWithContentsOfFile:path];

                    /**
                     * Картинку двойного размера надо объявить таковой.
                     *
                     * `imageWithContentsOfFile:` считает масштаб по имени,
                     * а имя тут без собачки — и картинка вышла бы вдвое
                     * крупнее задуманного.
                     */
                    if (raw != nil && [raw respondsToSelector:@selector(CGImage)]) {
                        return [UIImage imageWithCGImage:[raw CGImage]
                                                   scale:2.0
                                             orientation:UIImageOrientationUp];
                    }

                    return raw;
                }
            }
        }

        NSString *plain = [folder stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.png", name]];

        if ([files fileExistsAtPath:plain]) {
            return [UIImage imageWithContentsOfFile:plain];
        }
    }

    return nil;
}

#pragma mark Значки

/**
 * Чем в наборе зовётся то, что у нас зовётся так.
 *
 * Пары подобраны по смыслу, а не по буквам: `tab_you` — это раздел
 * учётной записи, и в наборе ему отвечает `account_guide`. Чего в наборе
 * нет вовсе — вертикальных роликов, например, — того здесь и нет:
 * такой значок останется нашим, и это лучше, чем подставить похожий.
 */
+ (NSDictionary *)iconMap {
    static NSDictionary *map = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        map = [NSDictionary dictionaryWithObjectsAndKeys:
            @"play", @"pl_play",
            @"pause", @"pl_pause",
            @"replay", @"pl_replay",
            @"like_watch", @"pl_like",
            @"like_watch_selected", @"pl_like_on",
            @"dislike_watch", @"pl_dislike",
            @"dislike_watch_selected", @"pl_dislike_on",
            @"fullscreen_portrait", @"pl_fullscreen",
            @"smallscreen", @"pl_exit_fullscreen",
            @"collapse", @"pl_collapse",
            @"back_arrow", @"pl_back",
            @"settings_guide", @"pl_settings",
            @"cc", @"languages",
            @"action_watch", @"share",
            @"search", @"search",
            @"search_voice", @"microphone",
            @"logo", @"ytlogo",
            /**
             * Домик в наборе зовётся `subscriptions_guide`.
             *
             * Имя обманчиво, а рисунок нет: там домик, и это «Главная».
             * Я поверил имени и поставил домик подпискам, а звёздочку
             * «Популярное» — главной; на экране они и оказались наоборот.
             * Подпискам достались двое — `people_guide`: ближе по смыслу
             * в этом наборе ничего нет.
             */
            @"subscriptions_guide", @"tab_home",
            @"subscriptions_guide_selected", @"tab_home_on",
            /**
             * Подпискам — список с уголком воспроизведения.
             *
             * Сперва стояли двое (`people_guide`), и это читалось как
             * «люди», а не «каналы, на которые я подписан». Домик, который
             * в наборе зовётся `subscriptions_guide`, занят главной: в том
             * приложении лента подписок и была главной, у нас это разные
             * разделы.
             */
            @"playlists_guide", @"tab_subs",
            @"playlists_guide_selected", @"tab_subs_on",

            /**
             * Вертикальных роликов в ту пору не было, колокольчика тоже.
             *
             * Ближайшее по смыслу для Shorts — «Кино и анимация»:
             * хлопушка. Уведомлениям в наборе не отвечает ничего, и
             * подставлять им красную точку или пузырь значило бы менять
             * смысл значка ради вида. Такие значки остаются нашими,
             * но получают рельеф — см. `embossed:`.
             */
            @"entertainment_guide", @"tab_shorts",
            @"entertainment_guide_selected", @"tab_shorts_on",
            @"account_guide", @"tab_you",
            @"account_guide_selected", @"tab_you_on",
            @"history_guide", @"pl_download",
            @"unsubscribe", @"unsubscribe",
            @"artist_info", @"info",
            @"feed_error", @"failed_loading",
            nil];
    });

    return map;
}

/**
 * Прямоугольник непустой части картинки.
 *
 * Считается по прозрачности: рисуем картинку в свой холст и ищем крайние
 * точки, где что-то есть. Холст берём небольшой — до сорока точек по
 * длинной стороне: нам нужны границы, а не подробности, и лишние
 * мегапиксели здесь только время.
 */
+ (CGRect)inkBoundsOf:(UIImage *)image {
    CGSize size = [image size];

    if (size.width <= 0 || size.height <= 0) {
        return CGRectMake(0, 0, 1, 1);
    }

    CGFloat step = MAX(size.width, size.height) / 40.0;

    if (step < 1.0) {
        step = 1.0;
    }

    NSUInteger width = (NSUInteger)ceil(size.width / step);
    NSUInteger height = (NSUInteger)ceil(size.height / step);

    if (width == 0 || height == 0) {
        return CGRectMake(0, 0, size.width, size.height);
    }

    NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();

    CGContextRef context = CGBitmapContextCreate([pixels mutableBytes],
        width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedLast);

    CGColorSpaceRelease(space);

    if (context == NULL) {
        return CGRectMake(0, 0, size.width, size.height);
    }

    CGContextDrawImage(context, CGRectMake(0, 0, width, height), [image CGImage]);
    CGContextRelease(context);

    const unsigned char *bytes = (const unsigned char *)[pixels bytes];

    NSInteger minX = (NSInteger)width;
    NSInteger minY = (NSInteger)height;
    NSInteger maxX = -1;
    NSInteger maxY = -1;

    for (NSUInteger y = 0; y < height; y++) {
        for (NSUInteger x = 0; x < width; x++) {
            if (bytes[(y * width + x) * 4 + 3] <= 8) {
                continue;
            }

            if ((NSInteger)x < minX) { minX = (NSInteger)x; }
            if ((NSInteger)x > maxX) { maxX = (NSInteger)x; }
            if ((NSInteger)y < minY) { minY = (NSInteger)y; }
            if ((NSInteger)y > maxY) { maxY = (NSInteger)y; }
        }
    }

    // Пусто целиком — вернём всё: обрезать нечего.
    if (maxX < minX || maxY < minY) {
        return CGRectMake(0, 0, size.width, size.height);
    }

    /**
     * Холст рисуется снизу вверх, а нам нужны точки сверху вниз.
     */
    CGFloat scaleX = size.width / (CGFloat)width;
    CGFloat scaleY = size.height / (CGFloat)height;

    CGFloat top = (CGFloat)((NSInteger)height - 1 - maxY) * scaleY;

    return CGRectMake((CGFloat)minX * scaleX, top,
                      (CGFloat)(maxX - minX + 1) * scaleX,
                      (CGFloat)(maxY - minY + 1) * scaleY);
}

/**
 * Наш плоский значок с рельефом — для того, чему в наборе нет пары.
 *
 * Приём той поры: сам рисунок тёмный, а под ним, со сдвигом в точку
 * вниз, его же светлая тень. Получается вдавленность — то же, чем
 * отличались значки разделов в наборе. Так колокольчик и прочее
 * новьё перестаёт выпадать из ряда.
 */
+ (UIImage *)embossed:(UIImage *)flat {
    CGSize size = [flat size];

    if (size.width <= 0 || size.height <= 0) {
        return flat;
    }

    BOOL night = [YTTheme isDark];

    CGFloat scale = [[UIScreen mainScreen] respondsToSelector:@selector(scale)]
        ? [[UIScreen mainScreen] scale] : 1.0;

    UIGraphicsBeginImageContextWithOptions(size, NO, scale);

    CGContextRef context = UIGraphicsGetCurrentContext();

    CGRect box = CGRectMake(0, 0, size.width, size.height);

    /**
     * Тень под рисунком — на точку вниз.
     *
     * На тёмной полосе она тёмная, на светлой странице светлая: в обоих
     * случаях получается вдавленный край, тот самый приём, которым
     * сделаны значки в наборе.
     */
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, 0, 1);
    CGContextSetAlpha(context, night ? 0.9 : 0.75);
    [YTTintedImage(flat, night ? YTColor(0x000000) : YTColor(0xFFFFFF))
        drawInRect:box];
    CGContextRestoreGState(context);

    /**
     * Сам рисунок — с отливом сверху вниз, а не ровной заливкой.
     *
     * Плоский белый значок рядом с выпуклыми выдаёт себя сразу; отлив
     * даёт ту же металлическую поверхность, что и у соседей. Рисунок
     * служит трафаретом: заливаем градиентом сквозь него.
     */
    CGContextSaveGState(context);
    CGContextClipToMask(context, box, [flat CGImage]);

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();

    NSArray *shades = night
        ? [NSArray arrayWithObjects:(id)[YTColor(0xFFFFFF) CGColor],
                                    (id)[YTColor(0x9A9A9A) CGColor], nil]
        : [NSArray arrayWithObjects:(id)[YTColor(0x6E6E6E) CGColor],
                                    (id)[YTColor(0x2C2C2C) CGColor], nil];

    CGGradientRef gradient = CGGradientCreateWithColors(space,
        (__bridge CFArrayRef)shades, NULL);

    CGContextDrawLinearGradient(context, gradient,
        CGPointMake(0, 0), CGPointMake(0, size.height), 0);

    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);

    CGContextRestoreGState(context);

    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();

    UIGraphicsEndImageContext();

    return result ?: flat;
}

+ (UIImage *)iconNamed:(NSString *)name dark:(BOOL)dark {
    if (![self isClassic] || [name length] == 0) {
        return nil;
    }

    NSString *theirs = [[self iconMap] objectForKey:name];

    /**
     * Пары нет — берём свой значок и даём ему рельеф.
     *
     * Иначе рядом с выпуклыми значками набора наши плоские выглядели бы
     * заплатой; а подменять их чужими по принципу «похоже» — менять
     * смысл ради вида.
     */
    if (theirs == nil) {
        NSString *key = [NSString stringWithFormat:@"~%@|%d", name, dark ? 1 : 0];

        @synchronized (YTSkinCache()) {
            id kept = [YTSkinCache() objectForKey:key];

            if (kept != nil) {
                return (kept == [NSNull null]) ? nil : kept;
            }
        }

        UIImage *flat = YTImage([name stringByAppendingString:
            (dark ? @"_dark" : @"_light")]);

        UIImage *relief = (flat != nil) ? [self embossed:flat] : nil;

        @synchronized (YTSkinCache()) {
            [YTSkinCache() setObject:(relief ?: (id)[NSNull null]) forKey:key];
        }

        return relief;
    }

    NSString *key = [NSString stringWithFormat:@"%@|%d", name, dark ? 1 : 0];

    @synchronized (YTSkinCache()) {
        id kept = [YTSkinCache() objectForKey:key];

        // Пустышкой отмечаем «искали и не нашли» — иначе искали бы снова.
        if (kept != nil) {
            return (kept == [NSNull null]) ? nil : kept;
        }
    }

    /**
     * Светлый и тёмный набор — только там, где он в наборе есть.
     *
     * Значков той поры два вида всего у нескольких деталей
     * (`refresh_light` и `refresh_dark`); остальные одноцветные, и
     * подставляются в обе темы как есть.
     */
    UIImage *found = [self assetNamed:[theirs stringByAppendingString:
        (dark ? @"_dark" : @"_light")]];

    if (found == nil) {
        found = [self assetNamed:theirs];
    }

    if (found == nil) {
        @synchronized (YTSkinCache()) {
            [YTSkinCache() setObject:[NSNull null] forKey:key];
        }

        return nil;
    }

    /**
     * Размер — от нашего значка.
     *
     * Наш же и спрашиваем: `YTImage` берёт из связки без оглядки на
     * оформление, так что кольца тут не выйдет.
     */
    UIImage *ours = YTImage([name stringByAppendingString:
        (dark ? @"_dark" : @"_light")]);

    CGSize want = (ours != nil) ? [ours size] : [found size];

    if (want.width <= 0 || want.height <= 0) {
        return found;
    }

    CGFloat scale = [[UIScreen mainScreen] respondsToSelector:@selector(scale)]
        ? [[UIScreen mainScreen] scale] : 1.0;

    /**
     * Пустые поля вокруг рисунка срезаем.
     *
     * У значков набора вокруг самого рисунка остаётся прозрачная кайма —
     * иногда в треть размера. Вписав такой значок в наше место целиком,
     * мы вписываем вместе с каймой, и рисунок выходит заметно мельче
     * соседних: ровно это и было видно на полосе вкладок.
     */
    CGRect ink = [self inkBoundsOf:found];

    UIGraphicsBeginImageContextWithOptions(want, NO, scale);

    // Вписываем целиком, сохраняя пропорции: иначе квадратный значок
    // в прямоугольном месте растянулся бы.
    CGFloat ratio = MIN(want.width / ink.size.width,
                        want.height / ink.size.height);

    CGSize fit = CGSizeMake(floor(ink.size.width * ratio),
                            floor(ink.size.height * ratio));

    CGFloat left = floor((want.width - fit.width) / 2);
    CGFloat top = floor((want.height - fit.height) / 2);

    /**
     * Рисуем всю картинку, но сдвинутой и увеличенной так, чтобы на месте
     * оказалась именно её непустая часть: обрезать саму картинку дороже,
     * а результат тот же.
     */
    CGContextRef context = UIGraphicsGetCurrentContext();

    CGContextSaveGState(context);
    CGContextClipToRect(context, CGRectMake(left, top, fit.width, fit.height));

    [found drawInRect:CGRectMake(left - ink.origin.x * ratio,
                                 top - ink.origin.y * ratio,
                                 [found size].width * ratio,
                                 [found size].height * ratio)];

    CGContextRestoreGState(context);

    UIImage *sized = UIGraphicsGetImageFromCurrentImageContext();

    UIGraphicsEndImageContext();

    UIImage *result = sized ?: found;

    @synchronized (YTSkinCache()) {
        [YTSkinCache() setObject:result forKey:key];
    }

    return result;
}

#pragma mark Рисование

/** Цвета полосы: сверху светлее, снизу темнее — и волоски по краям. */
+ (void)barTop:(UIColor **)top
        bottom:(UIColor **)bottom
          hair:(UIColor **)hair
         under:(UIColor **)under {
    BOOL dark = [YTTheme isDark];

    *top = dark ? YTColor(0x4A4A4A) : YTColor(0xFDFDFD);
    *bottom = dark ? YTColor(0x1C1C1C) : YTColor(0xC4C9D1);
    *hair = dark ? YTColor(0x6E6E6E) : YTColor(0xFFFFFF);
    *under = dark ? YTColor(0x000000) : YTColor(0x8A8F96);
}

/**
 * Рисует полосу в отведённом прямоугольнике.
 *
 * Отдельным методом, потому что рисовать её приходится в двух местах:
 * на самой полосе и на демо-снимке. Картинка набора — `titlebar` —
 * растягивается по высоте: рисунок у неё горизонтально однородный,
 * вертикальный отлив с волосками по краям.
 */
+ (void)drawBarInRect:(CGRect)box {
    if (box.size.height <= 0 || box.size.width <= 0) {
        return;
    }

    UIImage *ready = [self assetNamed:@"titlebar"];

    if (ready != nil) {
        [ready drawInRect:box];

        return;
    }

    UIColor *top = nil;
    UIColor *bottom = nil;
    UIColor *hair = nil;
    UIColor *under = nil;

    [self barTop:&top bottom:&bottom hair:&hair under:&under];

    UIImage *paint = YTVerticalGradient(box.size.height, top, bottom, hair, under);

    [paint drawInRect:box];
}

+ (void)paintBar:(UIView *)view {
    if (view == nil) {
        return;
    }

    YTSkinBarBacking *backing = nil;

    for (UIView *child in [view subviews]) {
        if ([child isKindOfClass:[YTSkinBarBacking class]]) {
            backing = (YTSkinBarBacking *)child;

            break;
        }
    }

    if (![self isClassic]) {
        [backing removeFromSuperview];
        [view setBackgroundColor:[YTTheme background]];

        return;
    }

    /**
     * Подложка, а не цвет фона.
     *
     * Цветом-узором полосу тоже можно покрасить, но узор готовится под
     * известную высоту, а в миг покраски её обычно ещё нет: цвета
     * назначают до раскладки. Подложка же перерисовывает себя сама,
     * когда ей меняют размер, — и высота всегда та, что на экране.
     */
    if (backing == nil) {
        backing = [[YTSkinBarBacking alloc] initWithFrame:[view bounds]];

        [backing setUserInteractionEnabled:NO];
        [backing setContentMode:UIViewContentModeRedraw];
        [backing setAutoresizingMask:UIViewAutoresizingFlexibleWidth |
                                     UIViewAutoresizingFlexibleHeight];

        [view insertSubview:backing atIndex:0];
    }

    [backing setFrame:[view bounds]];
    [backing setNeedsDisplay];

    [view setBackgroundColor:[YTTheme surface]];
}

/**
 * Скруглённый путь — общий для плашек и карточек.
 */
+ (void)pathInContext:(CGContextRef)context box:(CGRect)box radius:(CGFloat)radius {
    CGFloat r = MIN(radius, MIN(box.size.width, box.size.height) / 2);

    CGContextBeginPath(context);
    CGContextMoveToPoint(context, CGRectGetMinX(box) + r, CGRectGetMinY(box));
    CGContextAddArcToPoint(context, CGRectGetMaxX(box), CGRectGetMinY(box),
                           CGRectGetMaxX(box), CGRectGetMaxY(box), r);
    CGContextAddArcToPoint(context, CGRectGetMaxX(box), CGRectGetMaxY(box),
                           CGRectGetMinX(box), CGRectGetMaxY(box), r);
    CGContextAddArcToPoint(context, CGRectGetMinX(box), CGRectGetMaxY(box),
                           CGRectGetMinX(box), CGRectGetMinY(box), r);
    CGContextAddArcToPoint(context, CGRectGetMinX(box), CGRectGetMinY(box),
                           CGRectGetMaxX(box), CGRectGetMinY(box), r);
    CGContextClosePath(context);
}

+ (BOOL)drawRaisedInRect:(CGRect)box radius:(CGFloat)radius dark:(BOOL)dark {
    if (![self isClassic] || box.size.width <= 0 || box.size.height <= 0) {
        return NO;
    }

    CGContextRef context = UIGraphicsGetCurrentContext();

    if (context == NULL) {
        return NO;
    }

    /**
     * Готовая кнопка набора — если её принесли.
     *
     * `button_light` и `button_dark` нарисованы тянущимися: середина
     * ровная, торцы свои. Отдаём их UIKit целиком — он и растянет как
     * надо, а мы оставляем себе только скруглённый обрез, чтобы углы
     * совпали с нашими.
     */
    /**
     * Светлая кнопка под тёмной подписью — и наоборот.
     *
     * В наборе две кнопки: `button_light` почти белая, `button_dark`
     * почти чёрная. Выбирать между ними по одному лишь «нажата или нет»
     * нельзя: в тёмной теме подпись белая, и на белой кнопке её
     * не видно — ровно это и вышло с таблетками категорий.
     *
     * Правило простое: обычная кнопка повторяет тему, выбранная —
     * спорит с ней. Тогда подпись, которая у выбранной всегда обратного
     * цвета, остаётся читаемой в обоих случаях.
     */
    BOOL night = [YTTheme isDark];
    BOOL wantDark = (night != dark);

    UIImage *ready = [self assetNamed:(wantDark ? @"button_dark" : @"button_light")];

    CGContextSaveGState(context);
    [self pathInContext:context box:box radius:radius];
    CGContextClip(context);

    if (ready != nil) {
        CGFloat cap = floor([ready size].width / 2);

        [[ready stretchableImageWithLeftCapWidth:cap topCapHeight:0]
            drawInRect:box];

        CGContextRestoreGState(context);

        return YES;
    }

    /**
     * Своего рисунка: отлив сверху вниз, светлая линия по верхней кромке
     * и тёмная кайма кругом — три приёма, из которых и складывается
     * выпуклость в этом оформлении.
     */
    UIColor *top = wantDark ? YTColor(0x5A5A5A) : YTColor(0xFDFDFD);
    UIColor *bottom = wantDark ? YTColor(0x232323) : YTColor(0xD2D7DE);

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();

    NSArray *colors = [NSArray arrayWithObjects:
        (id)[top CGColor], (id)[bottom CGColor], nil];

    CGGradientRef gradient = CGGradientCreateWithColors(space,
        (__bridge CFArrayRef)colors, NULL);

    CGContextDrawLinearGradient(context, gradient,
        CGPointMake(0, CGRectGetMinY(box)),
        CGPointMake(0, CGRectGetMaxY(box)), 0);

    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);

    CGContextRestoreGState(context);

    CGFloat hair = 1.0 / ([[UIScreen mainScreen]
        respondsToSelector:@selector(scale)] ? [[UIScreen mainScreen] scale] : 1.0);

    CGContextSaveGState(context);
    [self pathInContext:context
                    box:CGRectInset(box, hair / 2, hair / 2)
                 radius:radius];

    CGContextSetLineWidth(context, hair);
    CGContextSetStrokeColorWithColor(context,
        [(wantDark ? YTColor(0x111111) : YTColor(0x8A8F96)) CGColor]);
    CGContextStrokePath(context);
    CGContextRestoreGState(context);

    return YES;
}

+ (BOOL)drawCardInRect:(CGRect)box {
    if (![self isClassic] || box.size.width <= 0 || box.size.height <= 0) {
        return NO;
    }

    CGContextRef context = UIGraphicsGetCurrentContext();

    if (context == NULL) {
        return NO;
    }

    BOOL night = [YTTheme isDark];

    CGFloat hair = 1.0 / ([[UIScreen mainScreen]
        respondsToSelector:@selector(scale)] ? [[UIScreen mainScreen] scale] : 1.0);

    /**
     * Карточка — выпуклая, а не просто закрашенная.
     *
     * Четыре слоя, из которых и складывается объём той поры: тень под
     * листом, отлив по самому листу сверху вниз, светлая кромка по
     * верхнему краю и тёмная кайма кругом. Раньше здесь была ровная
     * заливка с каймой — этого мало: на снимках карточки читались
     * как прямоугольники, а не как лежащие листы.
     *
     * Тень рисуем сами и только под карточкой: `shadowOffset` у слоя
     * заставил бы систему считать её на каждом кадре прокрутки, а так
     * она попадает в ту же отрисовку, что и всё остальное.
     */
    CGContextSaveGState(context);
    CGContextSetShadowWithColor(context, CGSizeMake(0, 1), 2.0,
        [(night ? YTColor(0xB0000000) : YTColor(0x60000000)) CGColor]);
    [self pathInContext:context box:box radius:6];
    CGContextSetFillColorWithColor(context, [[YTTheme surface] CGColor]);
    CGContextFillPath(context);
    CGContextRestoreGState(context);

    /**
     * Готовая подложка набора — если она к лицу теме.
     *
     * `cell_background_browse` почти белая; в тёмной теме подпись на ней
     * пропала бы, поэтому там рисуем отлив своими цветами.
     */
    UIImage *ready = night ? nil : [self assetNamed:@"cell_background_browse"];

    CGContextSaveGState(context);
    [self pathInContext:context box:box radius:6];
    CGContextClip(context);

    if (ready != nil) {
        CGFloat cap = floor([ready size].width / 2);

        [[ready stretchableImageWithLeftCapWidth:cap
                                    topCapHeight:floor([ready size].height / 2)]
            drawInRect:box];
    } else {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();

        NSArray *shades = night
            ? [NSArray arrayWithObjects:(id)[YTColor(0x3C3C3C) CGColor],
                                        (id)[YTColor(0x242424) CGColor], nil]
            : [NSArray arrayWithObjects:(id)[YTColor(0xFFFFFF) CGColor],
                                        (id)[YTColor(0xE6E9ED) CGColor], nil];

        CGGradientRef gradient = CGGradientCreateWithColors(space,
            (__bridge CFArrayRef)shades, NULL);

        CGContextDrawLinearGradient(context, gradient,
            CGPointMake(0, CGRectGetMinY(box)),
            CGPointMake(0, CGRectGetMaxY(box)), 0);

        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
    }

    // Светлая кромка по верхнему краю — свет падает сверху.
    CGContextSetFillColorWithColor(context,
        [(night ? YTColor(0x66FFFFFF) : YTColor(0xCCFFFFFF)) CGColor]);
    CGContextFillRect(context, CGRectMake(CGRectGetMinX(box), CGRectGetMinY(box),
                                          box.size.width, hair));

    CGContextRestoreGState(context);

    CGContextSaveGState(context);
    [self pathInContext:context
                    box:CGRectInset(box, hair / 2, hair / 2)
                 radius:6];
    CGContextSetLineWidth(context, hair);
    CGContextSetStrokeColorWithColor(context,
        [(night ? YTColor(0x0D0D0D) : YTColor(0x9AA0A8)) CGColor]);
    CGContextStrokePath(context);
    CGContextRestoreGState(context);

    return YES;
}

/**
 * Полка заголовка раздела — тёмная полоса с отливом.
 *
 * Такими в ту пору были заголовки групп в списках: тёмная планка во всю
 * ширину, светлая кромка сверху, тень снизу. Возвращает `NO` при обычном
 * оформлении — тогда заголовок остаётся простой строкой.
 */
+ (BOOL)drawHeaderInRect:(CGRect)box {
    if (![self isClassic] || box.size.width <= 0 || box.size.height <= 0) {
        return NO;
    }

    CGContextRef context = UIGraphicsGetCurrentContext();

    if (context == NULL) {
        return NO;
    }

    UIImage *ready = [self assetNamed:@"header_background"];

    if (ready != nil) {
        [ready drawInRect:box];

        return YES;
    }

    CGFloat hair = 1.0 / ([[UIScreen mainScreen]
        respondsToSelector:@selector(scale)] ? [[UIScreen mainScreen] scale] : 1.0);

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();

    NSArray *shades = [NSArray arrayWithObjects:
        (id)[YTColor(0x4A4A4A) CGColor], (id)[YTColor(0x232323) CGColor], nil];

    CGGradientRef gradient = CGGradientCreateWithColors(space,
        (__bridge CFArrayRef)shades, NULL);

    CGContextSaveGState(context);
    CGContextClipToRect(context, box);
    CGContextDrawLinearGradient(context, gradient,
        CGPointMake(0, CGRectGetMinY(box)),
        CGPointMake(0, CGRectGetMaxY(box)), 0);
    CGContextRestoreGState(context);

    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);

    CGContextSetFillColorWithColor(context, [YTColor(0x6E6E6E) CGColor]);
    CGContextFillRect(context, CGRectMake(CGRectGetMinX(box), CGRectGetMinY(box),
                                          box.size.width, hair));

    CGContextSetFillColorWithColor(context, [YTColor(0x0D0D0D) CGColor]);
    CGContextFillRect(context, CGRectMake(CGRectGetMinX(box),
                                          CGRectGetMaxY(box) - hair,
                                          box.size.width, hair));

    return YES;
}

+ (void)paintRaised:(UIView *)view radius:(CGFloat)radius {
    if (view == nil) {
        return;
    }

    if (![self isClassic]) {
        return;
    }

    CGFloat height = [view bounds].size.height;

    if (height <= 0) {
        return;
    }

    BOOL dark = [YTTheme isDark];

    UIImage *paint = YTVerticalGradient(height,
        dark ? YTColor(0x5A5A5A) : YTColor(0xFFFFFF),
        dark ? YTColor(0x2E2E2E) : YTColor(0xD7DBE0),
        dark ? YTColor(0x7A7A7A) : YTColor(0xFFFFFF),
        nil);

    if (paint == nil) {
        return;
    }

    [view setBackgroundColor:[UIColor colorWithPatternImage:paint]];

    [[view layer] setCornerRadius:radius];
    [[view layer] setBorderWidth:1.0 / ([[UIScreen mainScreen]
        respondsToSelector:@selector(scale)] ? [[UIScreen mainScreen] scale] : 1.0)];
    [[view layer] setBorderColor:[(dark ? YTColor(0x111111)
                                        : YTColor(0x9AA0A8)) CGColor]];
}

#pragma mark Демо-снимок

/**
 * Мини-экран: полоса сверху, карточка с превью, полоса с вкладками снизу.
 *
 * Рисуется теми же цветами, что и настоящие экраны, но не из них:
 * снимать настоящий экран ради картинки в списке значило бы собрать
 * его целиком — со всеми запросами и картинками, — чтобы показать
 * размером с ноготь.
 */
+ (UIImage *)previewFor:(NSString *)skin size:(CGSize)size {
    if (size.width <= 0 || size.height <= 0) {
        return nil;
    }

    BOOL classic = [skin isEqualToString:YTSkinClassic];
    BOOL dark = [YTTheme isDark];

    CGFloat scale = [[UIScreen mainScreen] respondsToSelector:@selector(scale)]
        ? [[UIScreen mainScreen] scale] : 1.0;

    UIGraphicsBeginImageContextWithOptions(size, YES, scale);

    CGContextRef context = UIGraphicsGetCurrentContext();

    UIColor *page = classic
        ? (dark ? YTColor(0x1B1B1B) : YTColor(0xC8CDD4))
        : (dark ? YTColor(0x0F0F0F) : YTColor(0xFFFFFF));

    UIColor *card = classic
        ? (dark ? YTColor(0x2A2A2A) : YTColor(0xFFFFFF))
        : (dark ? YTColor(0x0F0F0F) : YTColor(0xFFFFFF));

    UIColor *ink = dark ? YTColor(0xFFFFFF) : YTColor(0x1A1A1A);
    UIColor *faint = dark ? YTColor(0x555555) : YTColor(0xBFC4CB);

    CGContextSetFillColorWithColor(context, [page CGColor]);
    CGContextFillRect(context, CGRectMake(0, 0, size.width, size.height));

    CGFloat bar = floor(size.height * 0.14);

    // Верхняя полоса: у объёмного оформления с градиентом и волосками.
    if (classic) {
        [self drawBarInRect:CGRectMake(0, 0, size.width, bar)];
    } else {
        CGContextSetFillColorWithColor(context,
            [(dark ? YTColor(0x0F0F0F) : YTColor(0xFFFFFF)) CGColor]);
        CGContextFillRect(context, CGRectMake(0, 0, size.width, bar));
    }

    // Красный значок YouTube в углу полосы — он есть в обоих оформлениях.
    CGContextSetFillColorWithColor(context, [YTColor(0xFF0000) CGColor]);
    CGContextFillRect(context, CGRectMake(6, bar / 2 - 3, 16, 7));

    // Карточка: превью и две строки подписи.
    CGFloat side = classic ? 6 : 4;
    CGFloat cardTop = bar + 6;
    CGFloat cardWidth = size.width - side * 2;
    CGFloat thumb = floor(cardWidth * 0.42);

    if (classic) {
        CGContextSetFillColorWithColor(context, [card CGColor]);
        CGContextFillRect(context, CGRectMake(side, cardTop, cardWidth,
                                              thumb + 22));
        CGContextSetStrokeColorWithColor(context, [faint CGColor]);
        CGContextStrokeRect(context, CGRectMake(side + 0.5, cardTop + 0.5,
                                                cardWidth - 1, thumb + 21));
    }

    CGContextSetFillColorWithColor(context,
        [(dark ? YTColor(0x000000) : YTColor(0xB6BBC2)) CGColor]);
    CGContextFillRect(context, CGRectMake(side + (classic ? 4 : 0),
                                          cardTop + (classic ? 4 : 0),
                                          cardWidth - (classic ? 8 : 0), thumb));

    CGContextSetFillColorWithColor(context, [ink CGColor]);
    CGContextFillRect(context, CGRectMake(side + (classic ? 4 : 0),
                                          cardTop + thumb + 8,
                                          cardWidth * 0.7, 3));

    CGContextSetFillColorWithColor(context, [faint CGColor]);
    CGContextFillRect(context, CGRectMake(side + (classic ? 4 : 0),
                                          cardTop + thumb + 14,
                                          cardWidth * 0.45, 3));

    // Нижняя полоса с вкладками.
    CGFloat tabs = floor(size.height * 0.13);
    CGFloat tabsTop = size.height - tabs;

    if (classic) {
        [self drawBarInRect:CGRectMake(0, tabsTop, size.width, tabs)];
    } else {
        CGContextSetFillColorWithColor(context,
            [(dark ? YTColor(0x0F0F0F) : YTColor(0xFFFFFF)) CGColor]);
        CGContextFillRect(context, CGRectMake(0, tabsTop, size.width, tabs));

        CGContextSetFillColorWithColor(context, [faint CGColor]);
        CGContextFillRect(context, CGRectMake(0, tabsTop, size.width, 0.5));
    }

    for (NSInteger i = 0; i < 4; i++) {
        CGFloat step = size.width / 4;
        CGFloat middle = step * i + step / 2;

        CGContextSetFillColorWithColor(context,
            [(i == 0 ? ink : faint) CGColor]);
        CGContextFillRect(context, CGRectMake(middle - 4, tabsTop + tabs / 2 - 4,
                                              8, 8));
    }

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();

    UIGraphicsEndImageContext();

    return image;
}

@end
