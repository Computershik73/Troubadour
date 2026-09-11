#import "YTSettings.h"

#import "YTStrings.h"

#import "YTImageLoader.h"
#import "YTStreams.h"

NSString *const YTSettingsChangedNotification = @"YTSettingsChanged";

static NSString *const YTLanguageKey = @"YTLanguage";
static NSString *const YTPreferredHeightKey = @"YTPreferredHeight";
static NSString *const YTThumbnailWidthKey = @"YTThumbnailWidth";
static NSString *const YTDeliveryKey = @"YTDelivery";
static NSString *const YTShortsHeightKey = @"YTShortsHeight";
static NSString *const YTChannelIconsKey = @"YTChannelIcons";
static NSString *const YTAlternateIconKey = @"YTAlternateIcon";
static NSString *const YTAutoFullscreenKey = @"YTAutoFullscreen";
static NSString *const YTAutoplayQueueKey = @"YTAutoplayQueue";
static NSString *const YTAutoplayShortsKey = @"YTAutoplayShorts";
static NSString *const YTSubtitleOffsetKey = @"YTSubtitleOffset";
static NSString *const YTSubtitlePlaceKey = @"YTSubtitlePlace";
static NSString *const YTSubtitlePlaceXKey = @"YTSubtitlePlaceX";
static NSString *const YTInterfaceLanguageKey = @"YTInterfaceLanguage";
static NSString *const YTSixtyFramesKey = @"YTSixtyFrames";
static NSString *const YTHideShortsKey = @"YTHideShorts";

/**
 * Ключ, которого нет в хранилище, и ключ со значением 0 в NSUserDefaults
 * неразличимы: `integerForKey:` отвечает нулём в обоих случаях. Для
 * переключателей, у которых «по умолчанию включено», этого мало, поэтому
 * они хранятся числом со сдвигом: 0 — не спрашивали, 1 — выключено,
 * 2 — включено.
 */
static BOOL YTFlag(NSString *key, BOOL fallback) {
    NSInteger stored = [[NSUserDefaults standardUserDefaults] integerForKey:key];

    if (stored == 0) {
        return fallback;
    }

    return stored == 2;
}

static void YTSetFlag(NSString *key, BOOL value) {
    [[NSUserDefaults standardUserDefaults] setInteger:(value ? 2 : 1) forKey:key];
}

static void YTNotifyChanged(void) {
    [[NSUserDefaults standardUserDefaults] synchronize];

    [[NSNotificationCenter defaultCenter] postNotificationName:YTSettingsChangedNotification
                                                        object:nil];
}

@implementation YTSettings

#pragma mark Язык

/**
 * Язык самого приложения — надписей на его экранах.
 *
 * Это не то же, что язык ниже: тот говорит YouTube, на каком языке
 * присылать названия и подписи в ответах (`hl`), и от языка приложения
 * не зависит. Их и правда хотят порознь: смотреть ролики по-русски,
 * а приложение держать на английском — обычное дело.
 *
 * Пусто — как в системе.
 */
+ (NSString *)interfaceLanguage {
    NSString *saved = [[NSUserDefaults standardUserDefaults]
        stringForKey:YTInterfaceLanguageKey];

    return saved ?: @"";
}

+ (void)setInterfaceLanguage:(NSString *)code {
    [[NSUserDefaults standardUserDefaults] setObject:(code ?: @"")
                                              forKey:YTInterfaceLanguageKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    YTNotifyChanged();
}

+ (NSString *)language {
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:YTLanguageKey];

    return saved ?: @"";
}

+ (void)setLanguage:(NSString *)language {
    [[NSUserDefaults standardUserDefaults] setObject:(language ?: @"")
                                              forKey:YTLanguageKey];

    YTNotifyChanged();
}

/**
 * Список перенесён из `Localization.SupportedLanguages` вместе с порядком:
 * сперва латиница по алфавиту, затем кириллица, затем письменности Азии.
 * Хранится парами «код для hl» / «как называется на самом этом языке» —
 * названия не переводятся, ровно как в оригинале.
 */
+ (NSArray *)languageOptions {
    static NSArray *options = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        NSArray *flat = [NSArray arrayWithObjects:
            @"af", @"Afrikaans",
            @"az", @"Azərbaycan",
            @"id", @"Bahasa Indonesia",
            @"ms", @"Bahasa Malaysia",
            @"bs", @"Bosanski",
            @"ca", @"Català",
            @"cs", @"Čeština",
            @"da", @"Dansk",
            @"de", @"Deutsch",
            @"et", @"Eesti",
            @"en-IN", @"English (India)",
            @"en-GB", @"English (UK)",
            @"en", @"English (US)",
            @"es", @"Español (España)",
            @"es-419", @"Español (Latinoamérica)",
            @"es-US", @"Español (US)",
            @"eu", @"Euskara",
            @"fil", @"Filipino",
            @"fr", @"Français",
            @"fr-CA", @"Français (Canada)",
            @"gl", @"Galego",
            @"hr", @"Hrvatski",
            @"zu", @"IsiZulu",
            @"is", @"Íslenska",
            @"it", @"Italiano",
            @"sw", @"Kiswahili",
            @"lv", @"Latviešu valoda",
            @"lt", @"Lietuvių",
            @"hu", @"Magyar",
            @"nl", @"Nederlands",
            @"no", @"Norsk",
            @"uz", @"O‘zbek",
            @"pl", @"Polski",
            @"pt-PT", @"Português",
            @"pt", @"Português (Brasil)",
            @"ro", @"Română",
            @"sq", @"Shqip",
            @"sk", @"Slovenčina",
            @"sl", @"Slovenščina",
            @"sr-Latn", @"Srpski",
            @"fi", @"Suomi",
            @"sv", @"Svenska",
            @"vi", @"Tiếng Việt",
            @"tr", @"Türkçe",
            @"be", @"Беларуская",
            @"bg", @"Български",
            @"ky", @"Кыргызча",
            @"kk", @"Қазақ Тілі",
            @"mk", @"Македонски",
            @"mn", @"Монгол",
            @"ru", @"Русский",
            @"sr", @"Српски",
            @"uk", @"Українська",
            @"el", @"Ελληνικά",
            @"hy", @"Հայերեն",
            @"ne", @"नेपाली",
            @"mr", @"मराठी",
            @"hi", @"हिन्दी",
            @"as", @"অসমীয়া",
            @"bn", @"বাংলা",
            @"pa", @"ਪੰਜਾਬੀ",
            @"gu", @"ગુજરાતી",
            @"or", @"ଓଡ଼ିଆ",
            @"ta", @"தமிழ்",
            @"te", @"తెలుగు",
            @"kn", @"ಕನ್ನಡ",
            @"ml", @"മലയാളം",
            @"si", @"සිංහල",
            @"th", @"ภาษาไทย",
            @"lo", @"ລາວ",
            @"my", @"ဗမာ",
            @"ka", @"ქართული",
            @"am", @"አማርኛ",
            @"km", @"ខ្មែរ",
            @"zh-CN", @"中文 (简体)",
            @"zh-TW", @"中文 (繁體)",
            @"zh-HK", @"中文 (香港)",
            @"ja", @"日本語",
            @"ko", @"한국어",
            nil];

        NSMutableArray *list = [NSMutableArray array];

        for (NSUInteger i = 0; i + 1 < [flat count]; i += 2) {
            [list addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                [flat objectAtIndex:i], @"code",
                [flat objectAtIndex:i + 1], @"title", nil]];
        }

        options = [list copy];
    });

    return options;
}

+ (NSString *)languageTitle:(NSString *)code {
    if ([code length] == 0) {
        return YTLoc(@"Как в системе");
    }

    for (NSDictionary *option in [self languageOptions]) {
        if ([[option objectForKey:@"code"] isEqualToString:code]) {
            return [option objectForKey:@"title"];
        }
    }

    return code;
}

#pragma mark Видео

+ (NSInteger)preferredHeight {
    return [[NSUserDefaults standardUserDefaults] integerForKey:YTPreferredHeightKey];
}

+ (void)setPreferredHeight:(NSInteger)height {
    [[NSUserDefaults standardUserDefaults] setInteger:height forKey:YTPreferredHeightKey];

    YTNotifyChanged();
}

/**
 * Высоты те же, что в списке выбора качества у плеера, и в том же порядке:
 * «Авто» сверху, дальше от большего к меньшему.
 */
+ (NSInteger)shortsHeight {
    return [[NSUserDefaults standardUserDefaults] integerForKey:YTShortsHeightKey];
}

+ (void)setShortsHeight:(NSInteger)height {
    [[NSUserDefaults standardUserDefaults] setInteger:height forKey:YTShortsHeightKey];

    YTNotifyChanged();
}

+ (NSArray *)qualityOptions {
    return [NSArray arrayWithObjects:
        [NSNumber numberWithInteger:0],
        [NSNumber numberWithInteger:1080],
        [NSNumber numberWithInteger:720],
        [NSNumber numberWithInteger:480],
        [NSNumber numberWithInteger:360],
        [NSNumber numberWithInteger:240],
        [NSNumber numberWithInteger:144],
        nil];
}

+ (NSString *)qualityTitle:(NSInteger)height {
    if (height <= 0) {
        return YTLoc(@"Авто");
    }

    return [NSString stringWithFormat:@"%ldp", (long)height];
}

#pragma mark Поток

/**
 * Ноль — «не спрашивали» и «подача SABR» одновременно, и это ровно то,
 * что нужно: путь по умолчанию у нас первый в перечислении.
 */
+ (YTDelivery)delivery {
    NSInteger stored = [[NSUserDefaults standardUserDefaults] integerForKey:YTDeliveryKey];

    return (stored == YTDeliveryAndroidVr) ? YTDeliveryAndroidVr : YTDeliverySabr;
}

+ (void)setDelivery:(YTDelivery)delivery {
    [[NSUserDefaults standardUserDefaults] setInteger:delivery forKey:YTDeliveryKey];

    YTNotifyChanged();
}

+ (NSArray *)deliveryOptions {
    return [NSArray arrayWithObjects:
        [NSNumber numberWithInteger:YTDeliverySabr],
        [NSNumber numberWithInteger:YTDeliveryAndroidVr],
        nil];
}

+ (NSString *)deliveryTitle:(YTDelivery)delivery {
    return (delivery == YTDeliveryAndroidVr) ? YTLoc(@"Готовые адреса") : YTLoc(@"Подача SABR");
}

+ (NSString *)deliveryHint:(YTDelivery)delivery {
    if (delivery == YTDeliveryAndroidVr) {
        return YTLoc(@"Прямые ссылки от клиента шлема. Без входа, но чувствительны "
                     @"к смене адреса: через VPN раздача отказывает чаще");
    }

    return YTLoc(@"Как у самого YouTube: поток идёт кусками по запросу. Все "
                 @"качества и звуковые дорожки; нужен вход. Если не задастся — "
                 @"приложение само перейдёт к готовым адресам");
}

#pragma mark Превью

+ (NSInteger)thumbnailWidth {
    return [[NSUserDefaults standardUserDefaults] integerForKey:YTThumbnailWidthKey];
}

+ (void)setThumbnailWidth:(NSInteger)width {
    [[NSUserDefaults standardUserDefaults] setInteger:width forKey:YTThumbnailWidthKey];

    /**
     * Разобранные картинки больше не годятся: они сняты под прежнюю
     * ступень. Без сброса настройка не действовала бы, пока кэш сам
     * не вытеснит старое, — то есть на глаз выглядела бы сломанной.
     */
    [YTImageLoader dropCache];

    YTNotifyChanged();
}

/**
 * Ширины взяты у самих превью i.ytimg.com: `mqdefault` — 320, `hqdefault` —
 * 480, `sddefault` — 640. Придумывать промежуточные значения смысла нет,
 * других размеров сервер всё равно не отдаёт.
 */
+ (NSArray *)thumbnailOptions {
    return [NSArray arrayWithObjects:
        [NSNumber numberWithInteger:0],
        [NSNumber numberWithInteger:640],
        [NSNumber numberWithInteger:480],
        [NSNumber numberWithInteger:320],
        nil];
}

+ (NSString *)thumbnailTitle:(NSInteger)width {
    switch (width) {
        case 640: return YTLoc(@"Высокое");
        case 480: return YTLoc(@"Среднее");
        case 320: return YTLoc(@"Низкое");
    }

    return YTLoc(@"Авто");
}

#pragma mark Переключатели

+ (BOOL)showsChannelIcons {
    return YTFlag(YTChannelIconsKey, YES);
}

+ (void)setShowsChannelIcons:(BOOL)shows {
    YTSetFlag(YTChannelIconsKey, shows);

    YTNotifyChanged();
}

+ (BOOL)usesAlternateIcon {
    return YTFlag(YTAlternateIconKey, NO);
}

+ (void)setUsesAlternateIcon:(BOOL)uses {
    YTSetFlag(YTAlternateIconKey, uses);

    YTNotifyChanged();
}

+ (BOOL)autoFullscreenInLandscape {
    return YTFlag(YTAutoFullscreenKey, YES);
}

+ (void)setAutoFullscreenInLandscape:(BOOL)automatic {
    YTSetFlag(YTAutoFullscreenKey, automatic);

    YTNotifyChanged();
}

+ (BOOL)autoplayNextInQueue {
    return YTFlag(YTAutoplayQueueKey, YES);
}

+ (void)setAutoplayNextInQueue:(BOOL)automatic {
    YTSetFlag(YTAutoplayQueueKey, automatic);

    YTNotifyChanged();
}

+ (double)subtitleOffset {
    NSUserDefaults *store = [NSUserDefaults standardUserDefaults];

    /**
     * Ключа нет — две секунды.
     *
     * В оригинале секунда, но там поток идёт напрямую, а у нас через
     * подачу и склейку в прокси: время у плеера отстаёт от времени
     * в дорожке ещё примерно на столько же. Две секунды — то, что
     * сходится на живом устройстве.
     */
    if ([store objectForKey:YTSubtitleOffsetKey] == nil) {
        return 2.0;
    }

    return [store doubleForKey:YTSubtitleOffsetKey];
}

+ (void)setSubtitleOffset:(double)seconds {
    if (seconds < -5) { seconds = -5; }
    if (seconds > 5) { seconds = 5; }

    [[NSUserDefaults standardUserDefaults] setDouble:seconds forKey:YTSubtitleOffsetKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (double)subtitlePlace {
    NSUserDefaults *store = [NSUserDefaults standardUserDefaults];

    // Ключа нет — понизу кадра: обычное место субтитров.
    if ([store objectForKey:YTSubtitlePlaceKey] == nil) {
        return 0.86;
    }

    return [store doubleForKey:YTSubtitlePlaceKey];
}

+ (void)setSubtitlePlace:(double)share {
    if (share < 0.05) { share = 0.05; }
    if (share > 0.95) { share = 0.95; }

    [[NSUserDefaults standardUserDefaults] setDouble:share forKey:YTSubtitlePlaceKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (double)subtitlePlaceX {
    NSUserDefaults *store = [NSUserDefaults standardUserDefaults];

    // Ключа нет — посередине.
    if ([store objectForKey:YTSubtitlePlaceXKey] == nil) {
        return 0.5;
    }

    return [store doubleForKey:YTSubtitlePlaceXKey];
}

+ (void)setSubtitlePlaceX:(double)share {
    if (share < 0.05) { share = 0.05; }
    if (share > 0.95) { share = 0.95; }

    [[NSUserDefaults standardUserDefaults] setDouble:share forKey:YTSubtitlePlaceXKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (BOOL)autoplayNextShort {
    return YTFlag(YTAutoplayShortsKey, NO);
}

+ (void)setAutoplayNextShort:(BOOL)automatic {
    YTSetFlag(YTAutoplayShortsKey, automatic);

    YTNotifyChanged();
}

+ (BOOL)hidesShorts {
    return YTFlag(YTHideShortsKey, NO);
}

+ (void)setHidesShorts:(BOOL)hides {
    YTSetFlag(YTHideShortsKey, hides);

    YTNotifyChanged();
}

+ (BOOL)prefersThirtyByDevice {
    return [YTStreams deviceDislikesSixtyFrames];
}

+ (BOOL)allowsSixtyFrames {
    // По умолчанию — то, что советует железо: на A4 и A5 не берём,
    // на остальных берём.
    return YTFlag(YTSixtyFramesKey, ![self prefersThirtyByDevice]);
}

+ (void)setAllowsSixtyFrames:(BOOL)allows {
    YTSetFlag(YTSixtyFramesKey, allows);

    YTNotifyChanged();
}

@end
