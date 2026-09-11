#import "YTPlayerJs.h"

#import "YTHttp.h"

/** Имена, под которыми запомнены число и сборка, из которой оно взято. */
static NSString *const YTStsKey = @"YTSignatureTimestamp";
static NSString *const YTStsPlayerKey = @"YTSignatureTimestampPlayer";

static NSString *const YTStsUserAgent =
    @"Mozilla/5.0 (SMART-TV; LINUX; Tizen 5.0) AppleWebKit/537.36 (KHTML, like Gecko) "
    @"Version/5.0 TV Safari/537.36";

@implementation YTPlayerJs

static NSInteger YTCachedSts = 0;
static NSString *YTCachedStsPlayer = nil;
static NSString *YTCachedPlayerId = nil;

/** Тело запроса к сети под именем TV-клиента. */
+ (NSData *)fetch:(NSString *)url range:(NSString *)range {
    NSMutableURLRequest *request =
        YTRequest(url, NSURLRequestUseProtocolCachePolicy, 30.0);

    if (request == nil) {
        return nil;
    }

    [request setValue:YTStsUserAgent forHTTPHeaderField:@"User-Agent"];

    if ([range length] > 0) {
        [request setValue:range forHTTPHeaderField:@"Range"];
    }

    /**
     * Без кук. Страница `/tv` и скрипт плеера — общие для всех, аккаунт
     * тут ни при чём, а лишние заголовки на статике только повод
     * для отказа.
     */
    [request setHTTPShouldHandleCookies:NO];

    YTHttpResponse *response = [YTHttp send:request bodyLimit:0 caching:NO];

    return [response isSuccessful] ? response.body : nil;
}

/**
 * Номер сборки плеера со страницы `/tv`.
 *
 * Со страницы приходит адрес **TV-плеера** (`tv-player-ias.js`), а нужны
 * нам другие сборки того же номера: `player_ias` ради
 * `signatureTimestamp` и `player_ias_tce` ради расшифровки `n`. Поэтому
 * из адреса берётся только номер, а имя файла подставляется своё.
 */
+ (NSString *)scanPlayerId {
    NSData *page = [self fetch:@"https://www.youtube.com/tv" range:@"bytes=0-262143"];

    /**
     * Latin-1, а не UTF-8, и это важно.
     *
     * Кусок, отрезанный по числу байт, почти наверняка рассекает
     * многобайтовый знак, и UTF-8 на таком возвращает nil — весь разбор
     * молча превращается в «не нашли». Latin-1 не отвергает ни одного
     * байта, а ищем мы только латиницу.
     */
    NSString *text = [[NSString alloc] initWithData:page encoding:NSISOLatin1StringEncoding];

    if ([text length] == 0) {
        return nil;
    }

    /**
     * Ищем `/s/player/<версия>/<что-то>.vflset/<что-то>.js`. Разбирать
     * страницу целиком незачем: адрес встречается в ней первым же
     * упоминанием плеера.
     */
    NSRange marker = [text rangeOfString:@"/s/player/"];

    if (marker.location == NSNotFound) {
        return nil;
    }

    NSString *tail = [text substringFromIndex:marker.location];
    NSRange stop = [tail rangeOfString:@".js"];

    if (stop.location == NSNotFound || stop.location > 200) {
        return nil;
    }

    NSString *path = [tail substringToIndex:NSMaxRange(stop)];

    // В разметке адрес приходит с экранированными косыми.
    path = [path stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];

    NSArray *parts = [path componentsSeparatedByString:@"/"];

    // «/s/player/<номер>/…» — номер третий по счёту после пустого начала.
    return ([parts count] > 3) ? [parts objectAtIndex:3] : nil;
}

+ (NSString *)playerId {
    @synchronized ([YTPlayerJs class]) {
        if ([YTCachedPlayerId length] > 0) {
            return YTCachedPlayerId;
        }
    }

    NSString *found = [self scanPlayerId];

    if ([found length] == 0) {
        return nil;
    }

    @synchronized ([YTPlayerJs class]) {
        YTCachedPlayerId = [found copy];
    }

    return found;
}

+ (void)forgetPlayerId {
    @synchronized ([YTPlayerJs class]) {
        if ([YTCachedPlayerId length] == 0) {
            return;
        }

        NSLog(@"[YouTube/Ключ] Забыли сборку плеера %@ — перечитаем", YTCachedPlayerId);

        YTCachedPlayerId = nil;
    }
}

/** Адрес обычной сборки плеера — в ней лежит `signatureTimestamp`. */
+ (NSString *)playerScriptUrl {
    NSString *identifier = [self playerId];

    if ([identifier length] == 0) {
        return nil;
    }

    return [NSString stringWithFormat:
        @"https://www.youtube.com/s/player/%@/player_ias.vflset/en_US/base.js",
        identifier];
}

/**
 * Ищет число прямо в байтах, без превращения файла в строку.
 *
 * `base.js` — почти три мегабайта; NSString из него на старом устройстве
 * стоил бы вдвое дороже самих данных и всё это ради пяти цифр. Искомое
 * имя целиком из латиницы, так что сравнение идёт побайтно.
 *
 * 0, если имени в файле нет.
 */
+ (NSInteger)stsIn:(NSData *)data {
    static const char needle[] = "signatureTimestamp";
    const NSUInteger needleLength = sizeof(needle) - 1;

    const char *bytes = (const char *)[data bytes];
    NSUInteger length = [data length];

    if (length <= needleLength) {
        return 0;
    }

    for (NSUInteger i = 0; i + needleLength < length; i++) {
        if (memcmp(bytes + i, needle, needleLength) != 0) {
            continue;
        }

        NSUInteger j = i + needleLength;

        // Между именем и числом стоит двоеточие либо знак равенства.
        while (j < length && (bytes[j] == ':' || bytes[j] == '=' ||
                              bytes[j] == ' ' || bytes[j] == '"' || bytes[j] == '\'')) {
            j++;
        }

        NSInteger value = 0;
        NSUInteger digits = 0;

        while (j < length && bytes[j] >= '0' && bytes[j] <= '9') {
            value = value * 10 + (bytes[j] - '0');
            digits++;
            j++;
        }

        if (digits > 0) {
            return value;
        }
    }

    return 0;
}

+ (NSInteger)signatureTimestamp {
    /**
     * Число запоминается **вместе со сборкой плеера**, из которой взято.
     *
     * У каждой сборки оно своё, а меняет их YouTube по нескольку раз
     * в день: за один день мы видели `b1558f06` с числом 20675,
     * `627778fa` с 20677 и `b0d2d49a` с 20676. Пока проверки не было,
     * мы продолжали просить подписи под версию, которой уже нет, —
     * ответ приходил обычный, а готовые ссылки раздача отбивала
     * отказом 403 без объяснения.
     *
     * Для расшифровки `n` такая проверка есть с самого начала; здесь
     * её просто забыли, и это стоило дня разбирательств.
     */
    NSString *player = [self playerId];

    if ([player length] == 0) {
        NSLog(@"[YouTube/Плеер] Сборка плеера не определилась");

        return 0;
    }

    NSUserDefaults *settings = [NSUserDefaults standardUserDefaults];

    @synchronized ([YTPlayerJs class]) {
        if (YTCachedSts > 0 && [YTCachedStsPlayer isEqualToString:player]) {
            return YTCachedSts;
        }
    }

    if ([[settings stringForKey:YTStsPlayerKey] isEqualToString:player]) {
        NSInteger stored = [settings integerForKey:YTStsKey];

        if (stored > 0) {
            @synchronized ([YTPlayerJs class]) {
                YTCachedSts = stored;
                YTCachedStsPlayer = [player copy];
            }

            return stored;
        }
    }

    NSString *script = [self playerScriptUrl];

    if ([script length] == 0) {
        NSLog(@"[YouTube/Плеер] Адрес плеерного скрипта не найден");

        return 0;
    }

    /**
     * Файл берётся целиком, а не кусками.
     *
     * Кусками было изящнее — читать до первого попадания и бросить, —
     * но тело приходит сжатым, и границы диапазонов живут в байтах
     * сжатого потока, а не текста. Совпасть они не могут, и вся
     * бережливость оборачивалась чтением того же файла дважды.
     * Три мегабайта один раз в несколько недель дешевле.
     */
    NSData *body = [self fetch:script range:nil];

    if ([body length] == 0) {
        NSLog(@"[YouTube/Плеер] Плеерный скрипт не прочитался");

        return 0;
    }

    NSInteger found = [self stsIn:body];

    if (found <= 0) {
        NSLog(@"[YouTube/Плеер] signatureTimestamp не найден (прочитано %lu КБ)",
              (unsigned long)([body length] / 1024));

        return 0;
    }

    NSLog(@"[YouTube/Плеер] signatureTimestamp = %ld (плеер %@, скрипт %lu КБ)",
          (long)found, player, (unsigned long)([body length] / 1024));

    @synchronized ([YTPlayerJs class]) {
        YTCachedSts = found;
        YTCachedStsPlayer = [player copy];
    }

    [settings setInteger:found forKey:YTStsKey];
    [settings setObject:player forKey:YTStsPlayerKey];
    [settings synchronize];

    return found;
}

@end
