#import "YTStrings.h"

#import "YTSettings.h"

/**
 * Языки, которые приложение знает. Порядок — тот, в каком они показаны
 * в настройках: сперва те, на которых говорят его пользователи, дальше
 * по распространённости.
 */
static NSArray *YTLanguageList(void) {
    static NSArray *list = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        list = [[NSArray alloc] initWithObjects:
            [NSDictionary dictionaryWithObjectsAndKeys:@"ru", @"code", @"Русский", @"title", nil],
            [NSDictionary dictionaryWithObjectsAndKeys:@"en", @"code", @"English", @"title", nil],
            [NSDictionary dictionaryWithObjectsAndKeys:@"uk", @"code", @"Українська", @"title", nil],
            [NSDictionary dictionaryWithObjectsAndKeys:@"pl", @"code", @"Polski", @"title", nil],
            [NSDictionary dictionaryWithObjectsAndKeys:@"de", @"code", @"Deutsch", @"title", nil],
            [NSDictionary dictionaryWithObjectsAndKeys:@"fr", @"code", @"Français", @"title", nil],
            [NSDictionary dictionaryWithObjectsAndKeys:@"es", @"code", @"Español", @"title", nil],
            [NSDictionary dictionaryWithObjectsAndKeys:@"it", @"code", @"Italiano", @"title", nil],
            [NSDictionary dictionaryWithObjectsAndKeys:@"pt", @"code", @"Português", @"title", nil],
            [NSDictionary dictionaryWithObjectsAndKeys:@"zh", @"code", @"中文", @"title", nil],
            [NSDictionary dictionaryWithObjectsAndKeys:@"ja", @"code", @"日本語", @"title", nil],
            [NSDictionary dictionaryWithObjectsAndKeys:@"ar", @"code", @"العربية", @"title", nil],
            [NSDictionary dictionaryWithObjectsAndKeys:@"fa", @"code", @"فارسی", @"title", nil],
            nil];
    });

    return list;
}

static NSDictionary *YTTable = nil;
static NSString *YTTableCode = nil;

/**
 * Какой язык взять у системы.
 *
 * `preferredLanguages` отдаёт коды вида `ru`, `en-US`, `zh-Hans` — берём
 * от них голову до дефиса и смотрим, знаем ли такой. Не знаем — английский:
 * он ближе к незнакомому языку, чем русский, на котором приложение написано.
 */
static NSString *YTSystemLanguage(void) {
    NSArray *preferred = [NSLocale preferredLanguages];

    for (NSString *tag in preferred) {
        NSString *code = [[tag componentsSeparatedByString:@"-"] objectAtIndex:0];

        code = [code lowercaseString];

        for (NSDictionary *language in YTLanguageList()) {
            if ([[language objectForKey:@"code"] isEqualToString:code]) {
                return code;
            }
        }
    }

    return @"en";
}

@implementation YTStrings

+ (NSArray *)languages {
    return YTLanguageList();
}

+ (NSString *)current {
    NSString *chosen = [YTSettings interfaceLanguage];

    return [chosen length] > 0 ? chosen : YTSystemLanguage();
}

+ (void)reset {
    @synchronized (YTLanguageList()) {
        YTTable = nil;
        YTTableCode = nil;
    }
}

+ (BOOL)isRightToLeft {
    NSString *code = [self current];

    return [code isEqualToString:@"ar"] || [code isEqualToString:@"fa"];
}

/**
 * Таблица нынешнего языка; для русского — пустая.
 *
 * Читается один раз и живёт до смены языка. Перевод — обычный JSON,
 * а не `.strings`: разбирать его умеет сама система (`NSJSONSerialization`
 * есть с iOS 5), тогда как `.strings` пришлось бы читать как plist
 * и следить за кодировкой.
 */
+ (NSDictionary *)table {
    NSString *code = [self current];

    @synchronized (YTLanguageList()) {
        if (YTTable != nil && [YTTableCode isEqualToString:code]) {
            return YTTable;
        }
    }

    NSDictionary *table = nil;

    if (![code isEqualToString:@"ru"]) {
        NSString *path = [[NSBundle mainBundle] pathForResource:code
                                                         ofType:@"json"
                                                    inDirectory:@"lang"];

        NSData *data = [path length] > 0 ? [NSData dataWithContentsOfFile:path] : nil;

        if ([data length] > 0) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];

            if ([parsed isKindOfClass:[NSDictionary class]]) {
                table = parsed;
            }
        }

        if (table == nil) {
            NSLog(@"[YouTube/Язык] Перевод «%@» не прочитан, остаёмся на русском", code);
        }
    }

    if (table == nil) {
        table = [NSDictionary dictionary];
    }

    @synchronized (YTLanguageList()) {
        YTTable = table;
        YTTableCode = [code copy];
    }

    return table;
}

@end

NSString *YTLoc(NSString *russian) {
    if ([russian length] == 0) {
        return russian;
    }

    NSString *translated = [[YTStrings table] objectForKey:russian];

    // Нет перевода — отдаём исходную строку: пусть будет по-русски,
    // но будет.
    return [translated length] > 0 ? translated : russian;
}

NSString *YTLocF(NSString *russian, ...) {
    va_list arguments;
    va_start(arguments, russian);

    NSString *result = [[NSString alloc] initWithFormat:YTLoc(russian)
                                              arguments:arguments];

    va_end(arguments);

    return result;
}
