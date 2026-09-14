#import "YTSkin.h"

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

@implementation YTSkin

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

        NSString *doubled = [folder stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@@2x.png", name]];

        if (scale > 1.5 && [files fileExistsAtPath:doubled]) {
            return [UIImage imageWithContentsOfFile:doubled];
        }

        NSString *plain = [folder stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.png", name]];

        if ([files fileExistsAtPath:plain]) {
            return [UIImage imageWithContentsOfFile:plain];
        }
    }

    return nil;
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

+ (void)paintBar:(UIView *)view {
    if (view == nil) {
        return;
    }

    if (![self isClassic]) {
        [view setBackgroundColor:[YTTheme background]];

        return;
    }

    CGFloat height = [view bounds].size.height;

    if (height <= 0) {
        [view setBackgroundColor:[YTTheme surface]];

        return;
    }

    /**
     * Готовая картинка набора — если её принесли.
     *
     * Растягивается по середине: у полос той эпохи рисунок был именно
     * таким — края со своими волосками, середина тянется.
     */
    UIImage *ready = [self assetNamed:@"bar"];

    if (ready != nil) {
        [view setBackgroundColor:[UIColor colorWithPatternImage:ready]];

        return;
    }

    UIColor *top = nil;
    UIColor *bottom = nil;
    UIColor *hair = nil;
    UIColor *under = nil;

    [self barTop:&top bottom:&bottom hair:&hair under:&under];

    UIImage *paint = YTVerticalGradient(height, top, bottom, hair, under);

    if (paint != nil) {
        [view setBackgroundColor:[UIColor colorWithPatternImage:paint]];
    }
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
        UIColor *top = nil;
        UIColor *bottom = nil;
        UIColor *hair = nil;
        UIColor *under = nil;

        [self barTop:&top bottom:&bottom hair:&hair under:&under];

        UIImage *paint = YTVerticalGradient(bar, top, bottom, hair, under);

        [paint drawInRect:CGRectMake(0, 0, size.width, bar)];
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
        UIColor *top = nil;
        UIColor *bottom = nil;
        UIColor *hair = nil;
        UIColor *under = nil;

        [self barTop:&top bottom:&bottom hair:&hair under:&under];

        UIImage *paint = YTVerticalGradient(tabs, top, bottom, hair, nil);

        [paint drawInRect:CGRectMake(0, tabsTop, size.width, tabs)];
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
