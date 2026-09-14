#import "YTTheme.h"

#import "YTSkin.h"
#import "YTStrings.h"

NSString *const YTThemeChangedNotification = @"YTThemeChanged";

NSString *const YTThemeSystem = @"system";
NSString *const YTThemeLight  = @"light";
NSString *const YTThemeDark   = @"dark";

static NSString *const YTThemeKey = @"yt_theme";

UIColor *YTColor(uint32_t argb) {
    // Без альфы в старшем байте — значит, цвет непрозрачный. Так записано
    // большинство значений в App.xaml: #0F0F0F, #272727 и прочие.
    CGFloat alpha = (argb & 0xFF000000u) != 0 ? ((argb >> 24) & 0xFF) / 255.0 : 1.0;

    return [UIColor colorWithRed:((argb >> 16) & 0xFF) / 255.0
                           green:((argb >> 8) & 0xFF) / 255.0
                            blue:(argb & 0xFF) / 255.0
                           alpha:alpha];
}

@implementation YTTheme

+ (NSString *)mode {
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:YTThemeKey];

    if ([saved isEqualToString:YTThemeLight] || [saved isEqualToString:YTThemeDark]) {
        return saved;
    }

    return YTThemeSystem;
}

+ (void)setMode:(NSString *)mode {
    if (mode == nil) {
        mode = YTThemeSystem;
    }

    [[NSUserDefaults standardUserDefaults] setObject:mode forKey:YTThemeKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    [[NSNotificationCenter defaultCenter] postNotificationName:YTThemeChangedNotification
                                                        object:nil];
}

+ (NSString *)titleForMode:(NSString *)mode {
    if ([mode isEqualToString:YTThemeLight]) {
        return YTLoc(@"Светлая");
    }

    if ([mode isEqualToString:YTThemeDark]) {
        return YTLoc(@"Тёмная");
    }

    return YTLoc(@"Как в системе");
}

+ (BOOL)isDark {
    NSString *mode = [self mode];

    if ([mode isEqualToString:YTThemeLight]) {
        return NO;
    }

    if ([mode isEqualToString:YTThemeDark]) {
        return YES;
    }

    /**
     * «Как в системе».
     *
     * Спросить систему можно только начиная с iOS 13 — до неё ночного режима
     * не существует вовсе. Спрашивается он через рантайм: `userInterfaceStyle`
     * в SDK 9.3 не объявлен, а прямая ссылка на несуществующий на iOS 5
     * селектор компилятору не понравится.
     *
     * Там, где спросить не у кого, ответ — «тёмная». Это не произвол:
     * в UWP-версии `RequestedTheme` по умолчанию тоже тёмный, и все семь
     * снимков экрана в её README сделаны в темноте.
     */
    UIView *probe = [[UIView alloc] initWithFrame:CGRectZero];
    SEL selector = NSSelectorFromString(@"traitCollection");

    if ([probe respondsToSelector:selector]) {
        id traits = [probe valueForKey:@"traitCollection"];
        SEL styleSelector = NSSelectorFromString(@"userInterfaceStyle");

        if ([traits respondsToSelector:styleSelector]) {
            NSNumber *style = [traits valueForKey:@"userInterfaceStyle"];

            // 1 — светлая, 2 — тёмная, 0 — «не указано».
            if ([style integerValue] == 1) {
                return NO;
            }

            if ([style integerValue] == 2) {
                return YES;
            }
        }
    }

    return YES;
}

#pragma mark Фирменные цвета

+ (UIColor *)brandRed {
    return YTColor(0xFF0000);
}

+ (UIColor *)accentBlue {
    return YTColor(0x3EA6FF);
}

#pragma mark Палитра App.xaml

/**
 * Оформление меняет палитру, а не только рисунок.
 *
 * У скевоморфного оформления той эпохи фон под карточками не белый,
 * а светлый серо-голубой: белым была сама карточка, и именно на этой
 * разнице держалось ощущение «листы лежат на столе». Сделай мы фон
 * белым, никакие градиенты на полосах его бы не создали.
 *
 * Значения — из «Руководства по интерфейсу» той поры: фон групповой
 * таблицы #C8CDD4, разделители #A9ABAE, вторичный текст #4C566C.
 */
+ (UIColor *)background {
    if ([YTSkin isClassic]) {
        return [self isDark] ? YTColor(0x1B1B1B) : YTColor(0xC8CDD4);
    }

    return [self isDark] ? YTColor(0x0F0F0F) : YTColor(0xFFFFFF);
}

+ (UIColor *)surface {
    if ([YTSkin isClassic]) {
        return [self isDark] ? YTColor(0x2A2A2A) : YTColor(0xFFFFFF);
    }

    return [self isDark] ? YTColor(0x272727) : YTColor(0xF2F2F2);
}

+ (UIColor *)surfaceAlt {
    if ([YTSkin isClassic]) {
        return [self isDark] ? YTColor(0x202020) : YTColor(0xEDEFF2);
    }

    return [self isDark] ? YTColor(0x1A1A1A) : YTColor(0xF7F7F7);
}

+ (UIColor *)surfaceHover {
    if ([YTSkin isClassic]) {
        return [self isDark] ? YTColor(0x343434) : YTColor(0xDCE0E6);
    }

    return [self isDark] ? YTColor(0x222222) : YTColor(0xE8E8E8);
}

+ (UIColor *)primaryText {
    if ([YTSkin isClassic]) {
        return [self isDark] ? YTColor(0xF2F2F2) : YTColor(0x000000);
    }

    return [self isDark] ? YTColor(0xFFFFFF) : YTColor(0x0F0F0F);
}

+ (UIColor *)secondaryText {
    if ([YTSkin isClassic]) {
        return [self isDark] ? YTColor(0xA5A5A5) : YTColor(0x4C566C);
    }

    return [self isDark] ? YTColor(0xAAAAAA) : YTColor(0x606060);
}

+ (UIColor *)mutedText {
    if ([YTSkin isClassic]) {
        return [self isDark] ? YTColor(0x8A8A8A) : YTColor(0x6D7480);
    }

    return [self isDark] ? YTColor(0x888888) : YTColor(0x777777);
}

+ (UIColor *)divider {
    if ([YTSkin isClassic]) {
        return [self isDark] ? YTColor(0x0B0B0B) : YTColor(0xA9ABAE);
    }

    return [self isDark] ? YTColor(0x222222) : YTColor(0xE5E5E5);
}

+ (UIColor *)videoPlaceholder {
    return [self isDark] ? YTColor(0x000000) : YTColor(0xCECECE);
}

+ (UIColor *)avatarPlaceholder {
    if ([YTSkin isClassic]) {
        return [self isDark] ? YTColor(0x3A3A3A) : YTColor(0xB9BEC6);
    }

    return [self isDark] ? YTColor(0x333333) : YTColor(0xD9D9D9);
}

+ (UIColor *)loadingRing {
    return [self isDark] ? YTColor(0xFFFFFF) : YTColor(0x000000);
}

+ (UIColor *)primaryActionBackground {
    return [self isDark] ? YTColor(0xF1F1F1) : YTColor(0x0F0F0F);
}

+ (UIColor *)primaryActionForeground {
    return [self isDark] ? YTColor(0x0F0F0F) : YTColor(0xFFFFFF);
}

+ (UIColor *)badge {
    return YTColor(0xCC000000);
}

+ (UIColor *)barText {
    return [YTSkin isClassic] ? YTColor(0xF5F5F5) : [self primaryText];
}

+ (UIStatusBarStyle)statusBarStyle {
    // На тёмном фоне нужны светлые значки. UIStatusBarStyleLightContent
    // существует с iOS 5.0 — ровно с нашей нижней границы.
    //
    // У объёмного оформления полоса тёмная в обеих темах — значит и
    // значки системы над ней всегда светлые.
    return ([self isDark] || [YTSkin isClassic])
        ? UIStatusBarStyleLightContent : UIStatusBarStyleDefault;
}

@end
