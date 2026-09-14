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
            @"popular_guide", @"tab_home",
            @"popular_guide_selected", @"tab_home_on",
            @"subscriptions_guide", @"tab_subs",
            @"subscriptions_guide_selected", @"tab_subs_on",
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

+ (UIImage *)iconNamed:(NSString *)name dark:(BOOL)dark {
    if (![self isClassic] || [name length] == 0) {
        return nil;
    }

    NSString *theirs = [[self iconMap] objectForKey:name];

    if (theirs == nil) {
        return nil;
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

    if (fabs([found size].width - want.width) < 0.5 &&
        fabs([found size].height - want.height) < 0.5) {
        @synchronized (YTSkinCache()) {
            [YTSkinCache() setObject:found forKey:key];
        }

        return found;
    }

    CGFloat scale = [[UIScreen mainScreen] respondsToSelector:@selector(scale)]
        ? [[UIScreen mainScreen] scale] : 1.0;

    UIGraphicsBeginImageContextWithOptions(want, NO, scale);

    // Вписываем целиком, сохраняя пропорции: иначе квадратный значок
    // в прямоугольном месте растянулся бы.
    CGFloat ratio = MIN(want.width / [found size].width,
                        want.height / [found size].height);

    CGSize fit = CGSizeMake(floor([found size].width * ratio),
                            floor([found size].height * ratio));

    [found drawInRect:CGRectMake(floor((want.width - fit.width) / 2),
                                 floor((want.height - fit.height) / 2),
                                 fit.width, fit.height)];

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
