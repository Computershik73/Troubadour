#import "YTStreams.h"

#import <sys/sysctl.h>

#import "YTJson.h"
#import "YTApi.h"
#import "YTNSig.h"
#import "YTPoToken.h"
#import "YTSabr.h"
#import "YTSettings.h"

NSString *const YTSabrLostNotification = @"YTSabrLost";

/**
 * Ступень качества — привычным числом, а не тем, что вышло из размеров.
 *
 * Ступени у YouTube те же, что и всюду: 144, 240, 360, 480, 720, 1080
 * и дальше. Но кадр не обязан быть 16:9, и у широкого ролика короткая
 * сторона в эти числа не попадает: 2560×1068 — это 1080p, а по размерам
 * выходит «1068p». Меню от этого пестрило небывалыми ступенями —
 * 142p, 356p, 712p, 1068p, — и человек не мог сообразить, что он выбирает.
 *
 * Поэтому подтягиваем к ближайшей привычной ступени, но только если
 * промах невелик — до восьмой доли. Так 1068 становится 1080, а всякое
 * настоящее нестандартное качество остаётся как есть: подписать его
 * чужим числом было бы враньём.
 */
static NSInteger YTCanonicalTier(NSInteger raw) {
    if (raw <= 0) {
        return raw;
    }

    static const NSInteger steps[] = {144, 240, 360, 480, 720, 1080, 1440, 2160, 4320};

    for (NSUInteger i = 0; i < sizeof(steps) / sizeof(steps[0]); i++) {
        NSInteger step = steps[i];
        NSInteger gap = raw > step ? raw - step : step - raw;

        if (gap * 8 <= step) {
            return step;
        }
    }

    return raw;
}

@implementation YTFormat

- (NSInteger)qualityTier {
    if (_width > 0 && _height > 0) {
        return YTCanonicalTier(MIN(_width, _height));
    }

    return YTCanonicalTier(_height > 0 ? _height : _width);
}

- (BOOL)isH264 {
    NSString *mime = [_mimeType lowercaseString];

    return mime != nil && [mime rangeOfString:@"avc1"].location != NSNotFound;
}

@end


@implementation YTStreams

+ (NSString *)rangeField:(NSDictionary *)format key:(NSString *)key edge:(NSString *)edge {
    return [YTJson textIn:[YTJson objectIn:format key:key] key:edge];
}

+ (NSString *)audioTrackField:(NSDictionary *)format key:(NSString *)key {
    return [YTJson textIn:[YTJson objectIn:format key:@"audioTrack"] key:key];
}

/**
 * Приписка к журналу: чем подписан адрес.
 *
 * Раздача сверяет клиента и **адрес в сети** — оба записаны в самой
 * ссылке (`c=`, `ip=`) и покрыты подписью. Если наш выход в сеть
 * сменится между тем, как мы получили ссылку, и тем, как пошли по ней
 * за видео, — это пустой отказ 403 без объяснений. Такое бывает
 * не только с VPN: раздающие пулы адресов крутят их между соединениями.
 *
 * Строчка в журнале дешевле, чем дамп трафика, и позволяет отличить
 * этот случай от отказа по токену.
 */
+ (NSString *)signatureNote:(NSString *)url {
    NSMutableString *note = [NSMutableString string];

    for (NSString *name in [NSArray arrayWithObjects:@"c", @"ip", nil]) {
        NSRange found = [url rangeOfString:
            [NSString stringWithFormat:@"&%@=", name]];

        if (found.location == NSNotFound) {
            continue;
        }

        NSString *tail = [url substringFromIndex:NSMaxRange(found)];
        NSRange stop = [tail rangeOfString:@"&"];

        if (stop.location != NSNotFound) {
            tail = [tail substringToIndex:stop.location];
        }

        [note appendFormat:@"%@%@=%@", [note length] > 0 ? @", " : @" (", name, tail];
    }

    if ([note length] > 0) {
        [note appendString:@")"];
    }

    return note;
}

/**
 * Дорожка так, как её зовёт подача: номер, время правки и метки.
 *
 * Меток `xtags` не хватало, и это стоило нескольких кругов. Один и тот
 * же номер звуковой дорожки встречается в ответе по нескольку раз —
 * это разные озвучки: оригинал, автоперевод, вариант с выравниванием
 * громкости. Различает их только `xtags`, и без них сервер отвечает
 * `sabr.no_audio_selected`: «дай мне 140» для него не просьба, а
 * загадка.
 */
+ (YTSabrFormat *)sabrFormatFrom:(NSDictionary *)format {
    YTSabrFormat *result = [YTSabrFormat formatWithItag:
        [YTJson intIn:format key:@"itag"]
                                           lastModified:
        (uint64_t)[[YTJson textIn:format key:@"lastModified"] longLongValue]];

    result.xtags = [YTJson textIn:format key:@"xtags"];
    result.height = [self tierIn:format];

    return result;
}

/**
 * Ступень качества сырой дорожки — то же правило, что и у `qualityTier`
 * разобранного формата.
 *
 * Считается по **короткой** стороне, а не по полю `height`. У ролика,
 * снятого вертикально, `height` — это длинная сторона: 1080×1920
 * подписан как «1920», хотя это 1080p. По сырой высоте выходило, что
 * у Shorts нет ни одной дорожки ниже 144p, отбор оставлял пустой список,
 * и качество выбирал сервер — выбор человека не значил ничего.
 */
+ (NSInteger)tierIn:(NSDictionary *)format {
    NSInteger width = [YTJson intIn:format key:@"width"];
    NSInteger height = [YTJson intIn:format key:@"height"];

    if (width > 0 && height > 0) {
        return YTCanonicalTier(MIN(width, height));
    }

    return YTCanonicalTier(height > 0 ? height : width);
}

/**
 * Пометки дорожки словами.
 *
 * `xtags` — это протобуф в base64: внутри пары вроде `acont=original`
 * и `lang=en`. Разбирать его по правилам незачем — нам нужны только слова,
 * а они лежат в нём открытым текстом.
 */
+ (NSString *)marksIn:(NSDictionary *)format {
    NSString *tags = [YTJson textIn:format key:@"xtags"];

    if ([tags length] == 0) {
        return @"";
    }

    NSData *raw = [YTSabr dataFromBase64Url:tags];

    if ([raw length] == 0) {
        return @"";
    }

    NSString *text = [[NSString alloc] initWithData:raw
                                           encoding:NSISOLatin1StringEncoding];

    return text ?: @"";
}

/**
 * Родная ли это дорожка — та, на которой ролик сняли.
 *
 * Различать их приходится самим. Сервер помечает «основной»
 * (`audioIsDefault`) не родную, а ту, что подходит **языку запроса**:
 * просим ответ по-русски — и основной названа русская озвучка. Человек
 * при этом просил включить ролик, а не перевести его, и слышать чужой
 * голос поверх родного не ждал.
 *
 * Настоящий признак лежит в пометках: `acont=original` у родной,
 * `acont=dubbed` у озвучек, `acont=descriptive` у дорожки с описанием
 * происходящего для незрячих. Названия дорожек («Английский
 * (оригинальная)») сервер переводит на язык запроса, поэтому они годятся
 * только запасным ходом.
 */
+ (BOOL)isOriginalTrack:(NSDictionary *)format {
    NSString *marks = [self marksIn:format];

    if ([marks rangeOfString:@"acont"].location != NSNotFound) {
        return [marks rangeOfString:@"original"].location != NSNotFound;
    }

    NSString *name = [self audioTrackField:format key:@"displayName"];

    if ([name length] == 0) {
        return NO;
    }

    return [name rangeOfString:@"ориг" options:NSCaseInsensitiveSearch].location != NSNotFound
        || [name rangeOfString:@"original" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

/**
 * Синтезированный дубляж — голос машины поверх родного.
 *
 * Пометка `acont=dubbed-auto`; у озвучки, записанной людьми, стоит
 * просто `dubbed`. Разница для слуха велика, и человек вправе сказать
 * «чужой язык — да, робота — нет».
 *
 * Запасной ход по названию: сервер переводит его на язык запроса, и
 * «(автоматический дубляж)» по-русски рядом с «(auto-dubbed)»
 * по-английски — обе строки несут одно слово, по которому и смотрим.
 */
+ (BOOL)isAutoDubbedTrack:(NSDictionary *)format {
    NSString *marks = [self marksIn:format];

    if ([marks rangeOfString:@"dubbed-auto"].location != NSNotFound) {
        return YES;
    }

    if ([marks rangeOfString:@"acont"].location != NSNotFound) {
        return NO;
    }

    NSString *name = [self audioTrackField:format key:@"displayName"];

    return [name rangeOfString:@"auto" options:NSCaseInsensitiveSearch].location != NSNotFound
        || [name rangeOfString:@"автомат" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

/**
 * Язык дорожки двумя буквами.
 *
 * Берётся из `id` — он выглядит как «ru.4» или «en-US.4», где до точки
 * стоит код языка. Запасной ход — пометка `lang=` в `xtags`.
 */
+ (NSString *)languageOfTrack:(NSDictionary *)format {
    NSString *identifier = [self audioTrackField:format key:@"id"];
    NSRange dot = [identifier rangeOfString:@"."];

    NSString *code = (dot.location != NSNotFound)
        ? [identifier substringToIndex:dot.location] : @"";

    if ([code length] == 0) {
        NSString *marks = [self marksIn:format];
        NSRange at = [marks rangeOfString:@"lang="];

        if (at.location == NSNotFound) {
            return @"";
        }

        NSUInteger from = at.location + at.length;
        NSUInteger to = from;

        while (to < [marks length]) {
            unichar letter = [marks characterAtIndex:to];

            BOOL alpha = (letter >= 'a' && letter <= 'z')
                      || (letter >= 'A' && letter <= 'Z');

            if (!alpha && letter != '-') {
                break;
            }

            to++;
        }

        code = [marks substringWithRange:NSMakeRange(from, to - from)];
    }

    return [self shortLanguage:code];
}

/** «en-US» → «en»: сравнивать языки надо по первой части. */
+ (NSString *)shortLanguage:(NSString *)code {
    NSRange dash = [code rangeOfString:@"-"];

    if (dash.location != NSNotFound) {
        code = [code substringToIndex:dash.location];
    }

    return [code lowercaseString];
}

/**
 * Дорожки, сведённые к тому, что нужно для выбора языка.
 *
 * Сам выбор ниже один на оба разбора; здесь только приведение
 * к общему виду.
 */
+ (NSArray *)trackFactsIn:(NSArray *)rawFormats {
    NSMutableArray *facts = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    for (NSDictionary *format in rawFormats) {
        if (![format isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        NSString *identifier = [self audioTrackField:format key:@"id"];

        if ([identifier length] == 0 || [seen containsObject:identifier]) {
            continue;
        }

        [seen addObject:identifier];

        [facts addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            identifier, @"id",
            [self languageOfTrack:format], @"lang",
            [NSNumber numberWithBool:[self isOriginalTrack:format]], @"original",
            [NSNumber numberWithBool:[self isAutoDubbedTrack:format]], @"auto",
            [NSNumber numberWithBool:[self isCompressedTrack:format]], @"drc",
            nil]];
    }

    return facts;
}

+ (NSArray *)trackFactsInFormats:(NSArray *)formats {
    NSMutableArray *facts = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    for (YTFormat *format in formats) {
        NSString *identifier = format.audioTrackId;

        if ([identifier length] == 0 || [seen containsObject:identifier]) {
            continue;
        }

        [seen addObject:identifier];

        [facts addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            identifier, @"id",
            format.audioLanguage ?: @"", @"lang",
            [NSNumber numberWithBool:format.audioIsOriginal], @"original",
            [NSNumber numberWithBool:format.audioIsAutoDubbed], @"auto",
            [NSNumber numberWithBool:format.audioIsCompressed], @"drc",
            nil]];
    }

    return facts;
}

/**
 * Само правило: по порядку предпочтений.
 *
 * Родная на нужном языке лучше озвучки на нём же — у ролика, снятого
 * по-русски, русская «озвучка» была бы переводом с перевода.
 */
+ (NSString *)pickTrackForMode:(NSInteger)mode among:(NSArray *)facts {
    // Дорожка одна — выбирать не из чего, и называть её незачем.
    if ([facts count] < 2) {
        return nil;
    }

    NSString *want = [self shortLanguage:[YTApi hl]];

    BOOL byDevice = (mode == YTAudioLanguageDeviceAuthored
                  || mode == YTAudioLanguageDeviceAny);

    for (NSUInteger pass = 0; byDevice && [want length] > 0 && pass < 3; pass++) {
        // Третий заход — автодубляж, и только если его разрешили.
        if (pass == 2 && mode != YTAudioLanguageDeviceAny) {
            break;
        }

        for (NSDictionary *track in facts) {
            if (![want isEqualToString:[track objectForKey:@"lang"]]) {
                continue;
            }

            if ([[track objectForKey:@"drc"] boolValue]) {
                continue;
            }

            BOOL original = [[track objectForKey:@"original"] boolValue];
            BOOL automatic = [[track objectForKey:@"auto"] boolValue];

            BOOL fits = (pass == 0) ? original
                      : (pass == 1) ? !automatic : YES;

            if (fits) {
                return [track objectForKey:@"id"];
            }
        }
    }

    /**
     * Ни правило, ни язык не сошлись — значит родная.
     *
     * Называем её прямо, а не оставляем пустоту: пустота уводит в общий
     * запасной ход, а он у подачи и у склейки разный. Одно правило —
     * один ответ.
     */
    for (NSDictionary *track in facts) {
        if ([[track objectForKey:@"original"] boolValue]
            && ![[track objectForKey:@"drc"] boolValue]) {
            return [track objectForKey:@"id"];
        }
    }

    return nil;
}

+ (NSArray *)rawFormatsIn:(NSDictionary *)playerResponse {
    return [YTJson arrayIn:[YTJson objectIn:playerResponse key:@"streamingData"]
                       key:@"adaptiveFormats"];
}

+ (NSString *)trackIdForMode:(NSInteger)mode in:(NSArray *)rawFormats {
    return [self pickTrackForMode:mode among:[self trackFactsIn:rawFormats]];
}

+ (NSString *)trackIdForMode:(NSInteger)mode inFormats:(NSArray *)formats {
    return [self pickTrackForMode:mode among:[self trackFactsInFormats:formats]];
}

/**
 * Дорожка с поджатой громкостью (`drc=1`).
 *
 * Она тоже родная, но звук в ней прижат к середине — тише громкое,
 * громче тихое. Это выбор для шумной улицы, а не то, что человек ждёт
 * по умолчанию.
 */
+ (BOOL)isCompressedTrack:(NSDictionary *)format {
    return [[self marksIn:format] rangeOfString:@"drc"].location != NSNotFound;
}

/** Есть ли у ролика родная дорожка вообще. */
+ (BOOL)hasOriginalTrackIn:(NSArray *)formats {
    for (NSDictionary *format in formats) {
        if ([YTJson objectIn:format key:@"audioTrack"] == nil) {
            continue;
        }

        if ([self isOriginalTrack:format]) {
            return YES;
        }
    }

    return NO;
}

/** Помечена ли дорожка основной — или у неё вовсе нет озвучек. */
+ (BOOL)isDefaultTrack:(NSDictionary *)format {
    NSDictionary *track = [YTJson objectIn:format key:@"audioTrack"];

    if (track == nil) {
        return YES;
    }

    id value = [track objectForKey:@"audioIsDefault"];

    return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}

/**
 * Подача от последнего удачного захода.
 *
 * Проба и добытчик — одно и то же действие, различаются лишь тем, что
 * с ним делают дальше; чтобы не разводить два почти одинаковых куска,
 * удачный заход оставляет объект здесь.
 */
static YTSabr *_lastSabr = nil;

/**
 * Откуда начать новой подаче эфира, если её берут под идущим показом.
 *
 * Первая просьба подачи делается здесь же, в `probeSabr`, ещё до того как
 * вызывающий получит её на руки, — поэтому подсказать место можно только
 * заранее. В журнале 51 это стоило дорого: подмена ставила подсказку уже
 * после того, как новая подача сходила за минуту до края, и та честно
 * перекачивала девяносто секунд, которые у раздачи давно есть. Список от
 * этого не растёт (куски с прежними номерами он пропускает), показ стоит,
 * а сторож через двадцать секунд берёт ещё одну подачу — и так по кругу.
 */
static NSTimeInterval _sabrLiveStart = 0;

/** Подача, у которой свежая перенимает отчёт о набранном. */
static YTSabr *_sabrLiveFrom = nil;

+ (YTSabr *)lastSabr {
    return _lastSabr;
}

/** Тянет ли устройство шестьдесят кадров; считается вместе с потолком. */
static BOOL _slowDevice = NO;

/** Потолок и озвучка, выбранные человеком для ближайшего захода. */
static NSInteger _sabrCap = NSIntegerMax;
static NSString *_sabrTrack = nil;

/**
 * Названа ли ступень вручную.
 *
 * При «Авто» решает сервер: мы сообщаем ему размер экрана и не мешаем
 * снижать качество, когда сеть не тянет. А названную человеком ступень
 * просим прямо — иначе выбор в меню ничего не значит.
 */
static BOOL _sabrExact = NO;

/** Что было на выбор в последнем ответе — для меню. */
/** Лестница качеств: ступень → кадры, и ступени, скрытые тумблером. */
static NSMutableDictionary *_tierFrames;

/** Кадры по номеру дорожки: 298 — это 720p60, а 136 — 720p30. */
static NSMutableDictionary *_itagFrames;
static NSArray *_sixtyOnlyTiers;

static NSArray *_lastSabrHeights = nil;
static NSArray *_lastSabrTracks = nil;

/** Ступень каждой видеодорожки по её номеру — чтобы узнать сыгранную. */
static NSMutableDictionary *_sabrTiers = nil;

/** Когда подачу обновляли в последний раз — чтобы не долбить `/player`. */
static NSTimeInterval _lastRenew = 0;

/** Сколько раз обновление подряд не удалось — после третьего перестаём. */
static NSInteger _renewFailures = 0;

/**
 * Считает неудачу обновления и, когда их набирается три, объявляет
 * подачу потерянной.
 *
 * Три — не гадание: обновление стоит запроса к `/player`, а плеер просит
 * куски без устали, и при глухом отказе в журнале выходил десяток
 * одинаковых запросов в минуту. Дальше молчать бессмысленно: слушатель
 * этого извещения переводит просмотр на готовые адреса, не теряя места.
 */
+ (void)giveUpOnSabr {
    _renewFailures++;

    if (_renewFailures < 3) {
        return;
    }

    NSLog(@"[YouTube/Подача] Обновиться не удалось трижды — подача потеряна");

    [[NSNotificationCenter defaultCenter] postNotificationName:YTSabrLostNotification
                                                        object:nil];
}

/** Адрес подачи в ответе `/player`; nil, если его там нет. */
+ (NSString *)sabrUrlIn:(NSDictionary *)playerResponse {
    return [YTJson textIn:[YTJson objectIn:playerResponse key:@"streamingData"]
                      key:@"serverAbrStreamingUrl"];
}

/** Настройки подачи оттуда же, как есть — в записи base64url. */
+ (NSString *)sabrConfigIn:(NSDictionary *)playerResponse {
    return [YTJson textIn:
        [YTJson objectIn:[YTJson objectIn:
            [YTJson objectIn:playerResponse key:@"playerConfig"]
                key:@"mediaCommonConfig"]
            key:@"mediaUstreamerRequestConfig"]
        key:@"videoPlaybackUstreamerConfig"];
}

+ (BOOL)renewSabr:(YTSabr *)sabr {
    if (sabr == nil || ![sabr needsReload]) {
        return NO;
    }

    /**
     * Если обновиться не выходит, дальше пробовать незачем.
     *
     * Каждая попытка — обращение к `/player`, а плеер просит куски
     * без устали: в журнале это выглядело как десяток запросов в минуту,
     * все с одним и тем же отказом. Три раза — и хватит.
     */
    if (_renewFailures >= 3) {
        return NO;
    }

    /**
     * Просьбу обновиться видят все потоки прокси разом — каждый на своём
     * куске. Ходить в `/player` по разу на кусок незачем: ответ один и
     * тот же, а сервер за такое отвечает всё хуже. Поэтому пропускаем
     * одного, а остальные ждут снаружи и увидят уже свежую подачу.
     */
    @synchronized ([YTStreams class]) {
        if (![sabr needsReload]) {
            return YES;
        }

        NSTimeInterval now = CFAbsoluteTimeGetCurrent();

        if (_lastRenew > 0 && now - _lastRenew < 3.0) {
            return NO;
        }

        _lastRenew = now;

        NSString *token = [sabr reloadToken];
        NSString *videoId = [sabr videoId];

        NSLog(@"[YouTube/Подача] Обновляем подачу на ходу: %@",
              [token length] > 0
                  ? [NSString stringWithFormat:@"токен %lu знаков",
                        (unsigned long)[token length]]
                  : @"токена сервер не дал, спросим по-обычному");

        NSDictionary *fresh = [YTApi refreshedPlayerResponse:videoId reloadToken:token];

        if (fresh == nil) {
            NSLog(@"[YouTube/Подача] Перезапрос на ходу не удался");

            [self giveUpOnSabr];

            return NO;
        }

        NSString *url = [self sabrUrlIn:fresh];
        NSString *config = [self sabrConfigIn:fresh];

        /**
         * Токен приняли не все.
         *
         * Просьбу обновиться шлёт подача, а выполнять её приходится тому
         * клиенту, чей это ответ, — и не всякий из них такую просьбу
         * понимает: в ответ приходит пустота без потоков вовсе. Но нам
         * нужен не именно перезапрос, а свежие адрес и настройки, и они
         * есть в обычном ответе `/player`. Спрашиваем его — тем же
         * путём, что и при открытии ролика.
         */
        if ([url length] == 0 || [config length] == 0) {
            NSLog(@"[YouTube/Подача] Перезапрос по токену пуст — спросим "
                  @"ответ обычным путём");

            NSDictionary *plain = [YTApi playerResponse:videoId];

            if (plain != nil) {
                url = [self sabrUrlIn:plain];
                config = [self sabrConfigIn:plain];
            }
        }

        if ([url length] == 0 || [config length] == 0) {
            NSLog(@"[YouTube/Подача] В свежем ответе нет ни %@ — играть нечем",
                  ([url length] == 0 && [config length] == 0)
                      ? @"адреса, ни настроек"
                      : (([url length] == 0) ? @"адреса" : @"настроек"));

            [self giveUpOnSabr];

            return NO;
        }

        [sabr adoptUrl:url config:[YTSabr dataFromBase64Url:config]];

        _renewFailures = 0;

        NSLog(@"[YouTube/Подача] Свежие адрес и настройки поставлены — "
              @"продолжаем с того же места");

        return YES;
    }
}

+ (void)probeSabr:(NSDictionary *)playerResponse {
    /**
     * Ходов два: подача имеет право ответить «твой ответ `/player`
     * устарел» и прислать токен вместо данных. Тогда берём ответ заново
     * с этим токеном и пробуем ещё раз — уже со свежими адресом
     * и настройками.
     */
    for (NSInteger attempt = 0; attempt < 2; attempt++) {
        NSString *token = [self trySabr:playerResponse];

        if ([token length] == 0) {
            return;
        }

        NSString *videoId = [YTJson textIn:
            [YTJson objectIn:playerResponse key:@"videoDetails"] key:@"videoId"];

        NSDictionary *fresh = [YTApi refreshedPlayerResponse:videoId reloadToken:token];

        if (fresh == nil) {
            NSLog(@"[YouTube/Подача] Перезапрос не удался");

            return;
        }

        NSLog(@"[YouTube/Подача] Ответ /player взят заново по токену");

        playerResponse = fresh;
    }
}

/**
 * Один заход к подаче. Возвращает токен перезапроса, если сервер его
 * просил, — иначе nil.
 */
+ (NSString *)trySabr:(NSDictionary *)playerResponse {
    NSDictionary *streaming = [YTJson objectIn:playerResponse key:@"streamingData"];

    NSString *url = [YTJson textIn:streaming key:@"serverAbrStreamingUrl"];

    NSString *config = [YTJson textIn:
        [YTJson objectIn:[YTJson objectIn:
            [YTJson objectIn:playerResponse key:@"playerConfig"]
                key:@"mediaCommonConfig"]
            key:@"mediaUstreamerRequestConfig"]
        key:@"videoPlaybackUstreamerConfig"];

    if ([url length] == 0 || [config length] == 0) {
        NSLog(@"[YouTube/Подача] Нечем начать: %@%@",
              [url length] == 0 ? @"нет адреса" : @"",
              [config length] == 0 ? @" нет настроек" : @"");
        return nil;
    }

    /**
     * Выбираем то же, что выбрал бы демуксер: H.264 не выше названного
     * потолка и обычный AAC.
     *
     * Раньше здесь стояло «не выше 720» — число, а не потолок. Выбор
     * человека в первый запрос не попадал вовсе, а сервер дальше держится
     * той дорожки, которую ему назвали: качество можно было переключать
     * сколько угодно, картинка не менялась.
     */
    NSDictionary *video = nil;
    NSDictionary *lowest = nil;
    NSDictionary *audio = nil;

    for (NSDictionary *format in [YTJson arrayIn:streaming key:@"adaptiveFormats"]) {
        NSString *mime = [YTJson textIn:format key:@"mimeType"];

        if ([mime rangeOfString:@"avc1"].location != NSNotFound) {
            NSInteger tier = [self tierIn:format];

            // Дорожка без размеров ни с чем не сравнивается — пропускаем.
            if (tier <= 0) {
                continue;
            }

            /**
             * Шестьдесят кадров старому железу не по силам.
             *
             * A4 и A5 не тянут их ни в каком размере: декодер не успевает,
             * и по журналу это видно прямой строкой — «брошено кадров».
             * Высота тут ни при чём, поэтому и потолок не помогает: 720p60
             * тяжелее, чем 1080p30. Такие дорожки просто не рассматриваем,
             * пока есть хоть одна тридцатикадровая.
             */
            if ([self prefersThirtyFrames] && [YTJson intIn:format key:@"fps"] > 31) {
                continue;
            }

            /**
             * При равной высоте берём ту, что чаще кадрами.
             *
             * У одной и той же ступени бывает две дорожки: 720p30
             * (itag 136) и 720p60 (298), 1080p30 (137) и 1080p60 (299).
             * Прежде побеждала та, что раньше в списке, а список ведёт
             * сервер — и на 720p выходило тридцать кадров при включённой
             * настройке «шестьдесят кадров». Человек её включил не для
             * того, чтобы смотреть тридцать.
             *
             * Обратный случай — когда шестидесятикадровые запрещены —
             * сюда не доходит вовсе: такие дорожки отброшены выше.
             */
            NSInteger frames = [YTJson intIn:format key:@"fps"];

            BOOL better = (video == nil)
                || (tier > [self tierIn:video])
                || (tier == [self tierIn:video] &&
                    frames > [YTJson intIn:video key:@"fps"]);

            if (tier <= _sabrCap && better) {
                video = format;
            }

            // Про запас: у ролика может не быть ничего ниже потолка.
            if (lowest == nil || tier < [self tierIn:lowest]) {
                lowest = format;
            }
        } else if ([mime rangeOfString:@"mp4a"].location != NSNotFound) {
            /**
             * Из нескольких озвучек берём ту, что сервер пометил
             * основной, а не первую попавшуюся: первой в списке нередко
             * идёт автоперевод на английский, и слушать ролик пришлось бы
             * не на его языке.
             */
            if (audio == nil ||
                ([self isDefaultTrack:format] && ![self isDefaultTrack:audio])) {
                audio = format;
            }
        }
    }

    /**
     * Ниже потолка не нашлось ничего — берём самое мелкое, что есть.
     * Человек просил «не выше», и ближайшее снизу тут единственное,
     * чем можно ответить честно.
     */
    if (video == nil) {
        video = lowest;
    }

    if (video == nil || audio == nil) {
        NSLog(@"[YouTube/Подача] Подходящих дорожек нет");
        return nil;
    }

    NSString *videoId = [YTJson textIn:
        [YTJson objectIn:playerResponse key:@"videoDetails"] key:@"videoId"];

    NSLog(@"[YouTube/Подача] Пробуем: видео itag %ld (%ldp, %ld кадр/с), звук itag %ld, "
          @"потолок %@",
          (long)[YTJson intIn:video key:@"itag"],
          (long)[self tierIn:video],
          (long)[YTJson intIn:video key:@"fps"],
          (long)[YTJson intIn:audio key:@"itag"],
          _sabrCap == NSIntegerMax
              ? @"нет"
              : [NSString stringWithFormat:@"%ldp", (long)_sabrCap]);

    YTSabr *sabr = [[YTSabr alloc] initWithUrl:url
                                        config:[YTSabr dataFromBase64Url:config]
                                       videoId:videoId
                                       poToken:[[YTPoToken shared] tokenFor:videoId]];

    /**
     * Говорим подаче, какую ступень мы просим, — но только если её
     * назвал человек.
     *
     * При «Авто» не называем ничего: пусть сервер смотрит на размер
     * экрана и распоряжается сам, в том числе снижает качество, когда
     * сеть не тянет. Ради этого подача и затевалась.
     */
    [sabr setWantedHeight:_sabrExact ? [self tierIn:video] : 0];

    /**
     * Перечисляем подаче **все** дорожки ролика, а не только выбранные:
     * так делает рабочий образец, и выбор остаётся за сервером.
     */
    NSMutableArray *allVideo = [NSMutableArray array];
    NSMutableArray *everyVideo = [NSMutableArray array];
    NSMutableArray *everyAudio = [NSMutableArray array];
    NSMutableArray *allAudio = [NSMutableArray array];

    /**
     * В список идёт то, что устройство умеет **разобрать**, — H.264
     * и AAC, — но без потолка по высоте.
     *
     * Кодек ограничить обязательно: получив все дорожки подряд, сервер
     * выбрал VP9 с Opus в контейнере WebM, а наш разборщик mp4 честно
     * прочитал в них EBML и выдал мусор вместо боксов.
     *
     * Высоту — нет: потолок устройства это совет, а не запрет, и человек
     * вправе выбрать выше своей меры. Предупреждение он получит, а вот
     * права выбора лишаться не должен.
     */
    NSMutableSet *tiers = [NSMutableSet set];
    NSMutableArray *tracks = [NSMutableArray array];
    NSMutableSet *seenTracks = [NSMutableSet set];

    _sabrTiers = [NSMutableDictionary dictionary];

    /**
     * Есть ли у ролика родная дорожка — узнаём наперёд.
     *
     * Отбор идёт по одной дорожке за раз, а решение «брать родную» имеет
     * смысл, только когда родная вообще названа. У ролика без озвучек
     * пометок нет вовсе, и отбор по ним оставил бы нас без звука.
     */
    BOOL nativeVoice = [self hasOriginalTrackIn:
        [YTJson arrayIn:streaming key:@"adaptiveFormats"]];

    /**
     * Язык дорожки — по правилу из настроек, и оно главнее запасных ходов.
     *
     * Пусто в ответе означает «правило ни на чём не остановилось»:
     * человек просил оригинал, нужного языка у ролика нет или дорожка
     * вообще одна. Тогда всё идёт как прежде.
     */
    NSString *byLanguage = ([_sabrTrack length] > 0) ? _sabrTrack
        : [self trackIdForMode:[YTSettings playbackAudioLanguage]
                            in:[YTJson arrayIn:streaming key:@"adaptiveFormats"]];

    if ([byLanguage length] > 0 && [_sabrTrack length] == 0) {
        NSLog(@"[YouTube/Подача] Язык звука по настройке: дорожка %@", byLanguage);
    }

    NSMutableArray *ladder = [NSMutableArray array];

    for (NSDictionary *format in [YTJson arrayIn:streaming key:@"adaptiveFormats"]) {
        NSString *mime = [YTJson textIn:format key:@"mimeType"];

        if ([mime rangeOfString:@"avc1"].location != NSNotFound) {
            NSInteger tier = [self tierIn:format];

            // Лестницу запоминаем до отбора: в ней и скрытые ступени.
            [ladder addObject:[NSArray arrayWithObjects:
                [NSNumber numberWithInteger:tier],
                [NSNumber numberWithInteger:[YTJson intIn:format key:@"fps"]], nil]];

            // То же правило, что и при выборе: шестидесятикадровых
            // на слабом железе не предлагаем и серверу.
            if ([self prefersThirtyFrames] && [YTJson intIn:format key:@"fps"] > 31) {
                continue;
            }

            if (tier > 0) {
                [tiers addObject:[NSNumber numberWithInteger:tier]];

                /**
                 * Заодно запоминаем ступень каждой дорожки по её номеру.
                 *
                 * На подаче выбирает сервер, и узнать, что он в итоге
                 * прислал, можно только по номеру дорожки из заголовка.
                 * Без этой таблицы меню качества показывало бы желаемое
                 * вместо действительного.
                 */
                [_sabrTiers setObject:[NSNumber numberWithInteger:tier]
                               forKey:[NSNumber numberWithInteger:
                                          [YTJson intIn:format key:@"itag"]]];

                /**
                 * И частоту по номеру — ради журнала.
                 *
                 * По ступени её не узнать: у эфира 720p бывает и в
                 * тридцати кадрах (136), и в шестидесяти (298), а в
                 * записи о присланном куске лежит только номер.
                 */
                if (_itagFrames == nil) {
                    _itagFrames = [NSMutableDictionary dictionary];
                }

                [_itagFrames setObject:[NSNumber numberWithInteger:
                                           [YTJson intIn:format key:@"fps"]]
                                forKey:[NSNumber numberWithInteger:
                                           [YTJson intIn:format key:@"itag"]]];
            }

            /**
             * Потолок здесь — пожелание человека, а не мера устройства.
             * Ниже потолка оставляем всё: сервер выбирает сам, и пусть
             * у него будет из чего, — так надёжнее, чем называть одну
             * дорожку и получать отказ.
             */
            if (tier <= _sabrCap) {
                [allVideo addObject:[self sabrFormatFrom:format]];
            }

            // Про запас — на случай, если ниже потолка не окажется ничего.
            [everyVideo addObject:[self sabrFormatFrom:format]];
        } else if ([mime rangeOfString:@"mp4a"].location != NSNotFound) {
            NSDictionary *track = [YTJson objectIn:format key:@"audioTrack"];
            NSString *identifier = [YTJson textIn:track key:@"id"];

            if ([identifier length] > 0 && ![seenTracks containsObject:identifier]) {
                [seenTracks addObject:identifier];

                [tracks addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                    identifier, @"id",
                    [YTJson textIn:track key:@"displayName"] ?: identifier, @"title",
                    /**
                     * Отмечаем ту, что зазвучит сама, — иначе в списке
                     * галочка у одной дорожки, а слышно другую.
                     */
                    [NSNumber numberWithBool:([byLanguage length] > 0
                        ? [identifier isEqualToString:byLanguage]
                        : (nativeVoice ? [self isOriginalTrack:format]
                                       : [self isDefaultTrack:format]))], @"default",
                    nil]];
            }

            /**
             * Озвучку, наоборот, отбираем: их у ролика бывает несколько
             * с одинаковыми номерами дорожек, и различает их только
             * `audioTrack`. Оставляем все качества выбранной — сервер
             * возьмёт из них подходящее.
             */
            /**
             * Без выбора человека играем родную дорожку.
             *
             * Родной нет — тогда уж ту, что сервер зовёт основной:
             * у ролика без озвучек она единственная и есть.
             */
            BOOL wanted;

            if ([byLanguage length] > 0) {
                wanted = [identifier isEqualToString:byLanguage];
            } else if (nativeVoice) {
                wanted = [self isOriginalTrack:format]
                      && ![self isCompressedTrack:format];
            } else {
                wanted = [self isDefaultTrack:format];
            }

            if (wanted || [identifier length] == 0) {
                [allAudio addObject:[self sabrFormatFrom:format]];
            }

            // Про запас — если отбор не оставит ни одной.
            [everyAudio addObject:[self sabrFormatFrom:format]];
        }
    }

    [self rememberLadder:ladder];

    _lastSabrHeights = [[tiers allObjects]
        sortedArrayUsingSelector:@selector(compare:)];

    _lastSabrTracks = ([tracks count] > 1) ? tracks : [NSArray array];

    /**
     * Если ниже названного потолка не нашлось ни одной дорожки, берём
     * весь набор: пусть сервер даст ближайшее, что у него есть.
     *
     * Без этого ролик, у которого все дорожки выше выбранного качества,
     * не заигрывал бы вовсе — а человек просил «не выше», а не «только
     * так и никак иначе».
     */
    if ([allVideo count] == 0) {
        NSLog(@"[YouTube/Потоки] Ниже %ldp дорожек нет — берём ближайшее",
              (long)_sabrCap);

        [allVideo addObjectsFromArray:everyVideo];
    }

    /**
     * Без звука не остаёмся ни при каком отборе.
     *
     * Родная дорожка могла найтись только в поджатом виде, а выбранная
     * человеком озвучка — исчезнуть из ответа вовсе. Молчащий ролик хуже,
     * чем не тот голос.
     */
    if ([allAudio count] == 0) {
        NSLog(@"[YouTube/Потоки] Отбор не оставил звука — берём что есть");

        [allAudio addObjectsFromArray:everyAudio];
    }

    /**
     * Эфиру нужна особая повадка — скажем об этом подаче заранее.
     *
     * У трансляции нет ни отдельного заголовка дорожки, ни длительностей
     * у кусков, ни конца; всё это подача учитывает, но только если знает,
     * что перед ней эфир.
     */
    NSDictionary *about = [YTJson objectIn:playerResponse key:@"videoDetails"];

    sabr.liveMode = [YTJson boolIn:about key:@"isLive"]
                 || [YTJson boolIn:about key:@"isLiveNow"];

    [sabr setAvailableVideo:allVideo audio:allAudio];

    /**
     * Названную человеком ступень закрепляем сразу и намертво.
     *
     * Перечень целиком сервер понимает как разрешение выбирать, и он
     * выбирает: за полторы минуты ролика дорожка менялась шесть раз.
     * Пока это «Авто», так и задумано — но когда ступень названа руками,
     * менять её нельзя вовсе, и проще всего не давать выбора: в запросе
     * окажется одна дорожка.
     *
     * При «Авто» закрепление случится само, по первой пришедшей
     * дорожке, — уже внутри подачи.
     */
    /**
     * У эфира дорожку намертво не закрепляем.
     *
     * Закрепление писано для записи: там ролик лежит целиком, и все
     * его дорожки у сервера под рукой — можно потребовать одну и стоять
     * на своём. У трансляции сервер отдаёт то, что снял и сложил сейчас,
     * и на просьбу «только эта дорожка и никакая другая» он отвечает
     * пустотой: в журнале это «Ответ 0 КБ: видео 0 фрагментов», а на
     * экране — «поток не собрался», при том что эфир идёт.
     *
     * Пожелание при этом остаётся: названная ступень уходит первой
     * в перечне предпочтений, и сервер начинает с неё.
     */
    if (_sabrExact && !sabr.liveMode) {
        [sabr pinVideo:[self sabrFormatFrom:video] hard:YES];
    }

    NSLog(@"[YouTube/Подача] В предпочтениях: видео %lu, звука %lu, "
          @"кадров не выше %ld",
          (unsigned long)[allVideo count], (unsigned long)[allAudio count],
          (long)([self prefersThirtyFrames] ? 30 : 60));

    if (_sabrLiveStart > 0 && sabr.liveMode) {
        [sabr setLiveStartHint:_sabrLiveStart];
    }

    /**
     * Отчёт о набранном перенимается **до** первой просьбы.
     *
     * Позже уже поздно: подача спрашивает сервер прямо здесь, внутри
     * `requestVideo:`, и именно эта первая просьба у свежей подачи
     * говорила «у меня нет ничего».
     */
    if (sabr.liveMode) {
        [sabr adoptLiveProgressFrom:_sabrLiveFrom];
    }

    if ([sabr requestVideo:[self sabrFormatFrom:video]
                     audio:[self sabrFormatFrom:audio]
                    fromMs:0]) {
        NSLog(@"[YouTube/Подача] Получилось: заголовок видео %lu байт, "
              @"первый фрагмент %lu байт, всего фрагментов %ld, %.0f с",
              (unsigned long)[[sabr videoInit] length],
              (unsigned long)[[sabr videoSegment:1] length],
              (long)[sabr videoSegmentCount], [sabr duration]);

        _lastSabr = sabr;

        return nil;
    }

    return [sabr reloadToken];
}

+ (void)setNextSabrLiveFrom:(YTSabr *)sabr {
    _sabrLiveFrom = sabr;
}

+ (void)setNextSabrLiveStart:(NSTimeInterval)seconds {
    _sabrLiveStart = MAX(0.0, seconds);
}

+ (YTSabr *)sabrFor:(NSDictionary *)playerResponse
          maxHeight:(NSInteger)maxHeight
         audioTrack:(NSString *)trackId {
    return [self sabrFor:playerResponse
               maxHeight:maxHeight
              audioTrack:trackId
                   exact:NO];
}

+ (YTSabr *)sabrFor:(NSDictionary *)playerResponse
          maxHeight:(NSInteger)maxHeight
         audioTrack:(NSString *)trackId
              exact:(BOOL)exact {
    _lastSabr = nil;
    _sabrCap = (maxHeight > 0) ? maxHeight : NSIntegerMax;
    _sabrTrack = [trackId copy];
    _sabrExact = exact;

    /** Новый ролик — новая сессия: прошлые неудачи обновления не в счёт. */
    _renewFailures = 0;
    _lastRenew = 0;

    [self probeSabr:playerResponse];

    // Подсказка разовая: следующий ролик начнёт как обычно.
    _sabrLiveStart = 0;
    _sabrLiveFrom = nil;

    if (_lastSabr == nil || [_lastSabr videoInit] == nil) {
        return nil;
    }

    return _lastSabr;
}

/**
 * Подача в стороне от общего состояния.
 *
 * Вся настройка захода — потолок, точность, озвучка — живёт здесь
 * в статических переменных: у плеера подача одна, и заводить ради неё
 * объект было незачем. У скачивания она вторая, и, начатое во время
 * просмотра, оно подменило бы плееру и меню качества, и перечень
 * озвучек — от чужого ролика.
 *
 * Поэтому снимок общего состояния снимается до захода и ставится
 * обратно после. Сам сеанс возвращается вызывающему: дальше он
 * распоряжается им сам, ни на что общее не глядя.
 *
 * Под замком целиком: два захода разом перепутали бы снимки.
 */
+ (YTSabr *)detachedSabrFor:(NSDictionary *)playerResponse
                  maxHeight:(NSInteger)maxHeight {
    return [self detachedSabrFor:playerResponse maxHeight:maxHeight audioTrack:nil];
}

+ (YTSabr *)detachedSabrFor:(NSDictionary *)playerResponse
                  maxHeight:(NSInteger)maxHeight
                 audioTrack:(NSString *)trackId {
    @synchronized ([YTStreams class]) {
        YTSabr *keepSabr = _lastSabr;
        NSArray *keepHeights = _lastSabrHeights;
        NSArray *keepTracks = _lastSabrTracks;
        NSMutableDictionary *keepTiers = _sabrTiers;
        NSInteger keepCap = _sabrCap;
        NSString *keepTrack = _sabrTrack;
        BOOL keepExact = _sabrExact;

        YTSabr *fresh = [self sabrFor:playerResponse
                            maxHeight:maxHeight
                           audioTrack:trackId
                                exact:YES];

        _lastSabr = keepSabr;
        _lastSabrHeights = keepHeights;
        _lastSabrTracks = keepTracks;
        _sabrTiers = keepTiers;
        _sabrCap = keepCap;
        _sabrTrack = keepTrack;
        _sabrExact = keepExact;

        return fresh;
    }
}

+ (NSArray *)sabrHeights {
    return _lastSabrHeights ?: [NSArray array];
}

+ (NSInteger)sabrPlayingHeight {
    NSInteger itag = [_lastSabr playingItag];

    if (itag <= 0) {
        return 0;
    }

    NSNumber *tier = [_sabrTiers objectForKey:[NSNumber numberWithInteger:itag]];

    return [tier integerValue];
}

+ (NSArray *)sabrAudioTracks {
    return _lastSabrTracks ?: [NSArray array];
}

+ (NSArray *)audioTracksIn:(NSArray *)formats {
    NSMutableArray *tracks = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    /**
     * Отмечаем ту, что зазвучит сама.
     *
     * Не «родную» безусловно, как было: какую дорожку включит плеер,
     * решает настройка языка, и галочка должна стоять там же. Иначе
     * в списке отмечена одна дорожка, а слышно другую — ровно та
     * путаница, из-за которой этот список и завели.
     */
    NSString *wanted = [self trackIdForMode:[YTSettings playbackAudioLanguage]
                                  inFormats:formats];

    BOOL nativeVoice = NO;

    for (YTFormat *format in formats) {
        if (format.hasAudio && !format.hasVideo && format.audioIsOriginal) {
            nativeVoice = YES;

            break;
        }
    }

    for (YTFormat *format in formats) {
        if (!format.hasAudio || format.hasVideo) {
            continue;
        }

        NSString *identifier = format.audioTrackId;

        /**
         * Дорожка без имени озвучки — это единственная озвучка ролика.
         * Предлагать выбор из неё одной незачем, поэтому такие
         * пропускаем: пустой перечень и означает «выбирать не из чего».
         */
        if ([identifier length] == 0 || [seen containsObject:identifier]) {
            continue;
        }

        [seen addObject:identifier];

        [tracks addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            identifier, @"id",
            format.audioTrackName ?: identifier, @"title",
            [NSNumber numberWithBool:([wanted length] > 0
                ? [identifier isEqualToString:wanted]
                : (nativeVoice ? format.audioIsOriginal
                               : format.audioIsDefault))], @"default",
            nil]];
    }

    return tracks;
}

+ (NSTimeInterval)lengthIn:(NSDictionary *)playerResponse {
    NSString *seconds = [YTJson textIn:
        [YTJson objectIn:playerResponse key:@"videoDetails"] key:@"lengthSeconds"];

    return (NSTimeInterval)[seconds doubleValue];
}

+ (NSString *)progressiveUrlIn:(NSDictionary *)playerResponse {
    NSDictionary *streaming = [YTJson objectIn:playerResponse key:@"streamingData"];

    NSString *poToken = [[YTPoToken shared] tokenFor:[YTApi streamBinding]];

    NSString *best = nil;
    NSInteger bestHeight = -1;

    for (NSDictionary *format in [YTJson arrayIn:streaming key:@"formats"]) {
        NSString *url = [YTJson textIn:format key:@"url"];
        NSString *mime = [YTJson textIn:format key:@"mimeType"];

        // Без адреса брать нечего: расшифровывать `signatureCipher` мы
        // не умеем — ради этого потоки и просятся у других клиентов.
        if ([url length] == 0 || [mime rangeOfString:@"video/mp4"].location == NSNotFound) {
            continue;
        }

        // Склеенный — значит со звуком внутри.
        BOOL hasAudio = [mime rangeOfString:@"mp4a"].location != NSNotFound
            || [format objectForKey:@"audioChannels"] != nil;

        if (!hasAudio) {
            continue;
        }

        NSInteger height = [YTJson intIn:format key:@"height"];

        if (height > bestHeight) {
            bestHeight = height;
            best = url;
        }
    }

    if ([best length] == 0) {
        return nil;
    }

    if ([poToken length] > 0 && [best rangeOfString:@"&pot="].location == NSNotFound) {
        best = [best stringByAppendingFormat:@"&pot=%@", poToken];
    }

    best = [[YTNSig shared] fixUrl:best];

    NSLog(@"[YouTube/Потоки] Склеенный поток %ldp%@", (long)bestHeight,
          [self signatureNote:best]);

    return best;
}

+ (NSArray *)formatsFrom:(NSDictionary *)playerResponse {
    /**
     * Подачу здесь не трогаем.
     *
     * Разбор адресов и подача — два разных пути, и какой из них в ходу,
     * видно по самому ответу: если адресов нет, список выйдет пустым,
     * и плеер сам сходит за `sabrFor:`. Пробовать подачу заранее значило
     * бы гонять её впустую всякий раз, когда адреса на месте.
     */
    NSDictionary *streaming = [YTJson objectIn:playerResponse key:@"streamingData"];
    NSArray *adaptive = [YTJson arrayIn:streaming key:@"adaptiveFormats"];

    /**
     * PO-токен, привязанный к ролику, — вторая половина доказательства.
     *
     * Первая, сеансовая, удостоверяет клиента перед `/player`. Эта
     * удостоверяет его перед раздачей: `googlevideo` сверяет параметр
     * `pot` в адресе и без него нередко отвечает 403, даже если сам
     * адрес подписан верно.
     *
     * Идентификатор берётся из того же ответа — там он лежит в
     * учётной записи, у гостя — посетителя, а у IOS-клиента её нет вовсе:
     * он токена не просит. Раздача сверяет `pot` с тем сеансом, которым
     * добыта ссылка, поэтому чужой токен в адресе — такой же отказ 403,
     * как и подделанный. Что годится для этих адресов, знает `YTApi`:
     * там видно, чей ответ в итоге пригодился.
     */
    NSString *poToken = [[YTPoToken shared] tokenFor:[YTApi streamBinding]];

    if ([poToken length] > 0) {
        NSLog(@"[YouTube/Потоки] Адреса с PO-токеном сеанса (%lu знаков)",
              (unsigned long)[poToken length]);
    } else {
        NSLog(@"[YouTube/Потоки] Адреса без PO-токена — клиент его не просил");
    }

    NSMutableArray *result = [NSMutableArray array];

    for (id value in adaptive) {
        if (![value isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        NSDictionary *format = value;

        NSString *url = [YTJson textIn:format key:@"url"];

        /**
         * Дорожки без `url` пропускаем.
         *
         * У них вместо адреса лежит `signatureCipher`, который надо
         * расшифровывать кодом из `player.js`. Именно ради того, чтобы
         * этого не случалось, потоки и спрашиваются у ANDROID_VR: он
         * отдаёт адреса уже подписанными. Если такие дорожки всё-таки
         * пришли — значит, запрос ушёл не тем клиентом.
         */
        if ([url length] == 0) {
            continue;
        }

        NSString *mime = [YTJson stringIn:format key:@"mimeType" fallback:@""];
        NSString *mimeLower = [mime lowercaseString];

        YTFormat *entry = [[YTFormat alloc] init];

        /**
         * Токен дописывается в адрес, а не шлётся заголовком: раздача
         * читает его из строки запроса. Если в адресе он уже есть —
         * ответ пришёл от клиента, который позаботился сам, — не трогаем.
         */
        if ([poToken length] > 0 && [url rangeOfString:@"&pot="].location == NSNotFound) {
            url = [url stringByAppendingFormat:@"&pot=%@", poToken];
        }

        /**
         * `n` в адресе полагается расшифровывать — сырой раздача
         * отбивает отказом 403. Если расшифровка ещё не готова,
         * адрес остаётся как был: попробовать и получить отказ лучше,
         * чем не пробовать.
         */
        url = [[YTNSig shared] fixUrl:url];

        entry.url = url;
        entry.width = [YTJson intIn:format key:@"width"];
        entry.height = [YTJson intIn:format key:@"height"];
        entry.mimeType = mime;
        entry.itag = [YTJson intIn:format key:@"itag"];
        entry.fps = [YTJson intIn:format key:@"fps"];
        entry.bitrate = [YTJson intIn:format key:@"bitrate"];
        entry.averageBitrate = [YTJson intIn:format key:@"averageBitrate"];

        // Приходит строкой, а не числом, — как и всё длинное в этом ответе.
        entry.contentLength =
            [[YTJson stringIn:format key:@"contentLength"] longLongValue];

        entry.initialRangeStart = [self rangeField:format key:@"initRange" edge:@"start"];
        entry.initialRangeEnd = [self rangeField:format key:@"initRange" edge:@"end"];
        entry.indexRangeStart = [self rangeField:format key:@"indexRange" edge:@"start"];
        entry.indexRangeEnd = [self rangeField:format key:@"indexRange" edge:@"end"];

        entry.hasAudio = [mimeLower rangeOfString:@"audio"].location != NSNotFound
                      || [format objectForKey:@"audioChannels"] != nil;

        entry.hasVideo = [mimeLower rangeOfString:@"video"].location != NSNotFound
                      || [format objectForKey:@"width"] != nil;

        entry.audioTrackId = [self audioTrackField:format key:@"id"];
        entry.audioTrackName = [self audioTrackField:format key:@"displayName"];
        entry.audioIsDefault = [YTJson boolIn:[YTJson objectIn:format key:@"audioTrack"]
                                          key:@"audioIsDefault"];
        entry.audioIsOriginal = [self isOriginalTrack:format];
        entry.audioIsCompressed = [self isCompressedTrack:format];
        entry.audioIsAutoDubbed = [self isAutoDubbedTrack:format];
        entry.audioLanguage = [self languageOfTrack:format];

        [result addObject:entry];
    }

    /**
     * Что в итоге разобралось. Строка нужна затем, что дальше отбор идёт
     * по кодеку и высоте, и без неё «подходящей дорожки нет» ничего
     * не объясняет: непонятно, чего именно не нашлось.
     */
    NSMutableString *summary = [NSMutableString string];

    for (YTFormat *format in result) {
        [summary appendFormat:@"%ld:%ldp%@ ", (long)format.itag, (long)format.height,
            [format isH264] ? @"" : @"(не H.264)"];
    }

    NSLog(@"[YouTube/Потоки] Разобрано дорожек: %lu — %@",
          (unsigned long)[result count],
          [summary length] > 0 ? summary : @"пусто");

    return result;
}

+ (NSArray *)heightsInResponse:(NSDictionary *)playerResponse {
    NSDictionary *streaming = [YTJson objectIn:playerResponse key:@"streamingData"];

    NSMutableSet *tiers = [NSMutableSet set];

    for (id value in [YTJson arrayIn:streaming key:@"adaptiveFormats"]) {
        if (![value isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        NSDictionary *format = value;

        NSString *mime = [[YTJson stringIn:format key:@"mimeType" fallback:@""]
            lowercaseString];

        /**
         * Только H.264 и только видеоряд — тот же отбор, что у
         * `heightsIn:`. Собирать мы умеем лишь его: VP9 и AV1 наш
         * писатель MP4 не описывает, а старое железо их и не сыграет.
         */
        if ([mime rangeOfString:@"video"].location == NSNotFound ||
            [mime rangeOfString:@"avc1"].location == NSNotFound) {
            continue;
        }

        NSInteger tier = [self tierIn:format];

        if (tier > 0) {
            [tiers addObject:[NSNumber numberWithInteger:tier]];
        }
    }

    return [[tiers allObjects] sortedArrayUsingSelector:@selector(compare:)];
}

+ (NSArray *)heightsIn:(NSArray *)formats {
    NSMutableSet *tiers = [NSMutableSet set];
    NSMutableArray *ladder = [NSMutableArray array];

    BOOL thirty = [self prefersThirtyFrames];

    for (YTFormat *format in formats) {
        if (!format.hasVideo || format.hasAudio || ![format isH264]) {
            continue;
        }

        NSInteger tier = [format qualityTier];

        if (tier <= 0) {
            continue;
        }

        [ladder addObject:[NSArray arrayWithObjects:
            [NSNumber numberWithInteger:tier],
            [NSNumber numberWithInteger:format.fps], nil]];

        /**
         * Шестидесятикадровые не показываем, когда тумблер выключен.
         *
         * Прежде здесь не было отбора вовсе, и список обещал ступени,
         * которых выбор не давал: `chooseVideo:` берёт их по тому же
         * правилу, что и подача.
         */
        if (thirty && format.fps > 31) {
            continue;
        }

        [tiers addObject:[NSNumber numberWithInteger:tier]];
    }

    [self rememberLadder:ladder];

    /**
     * Отбор не оставил ничего — значит у ролика все дорожки по шестьдесят.
     * Показываем их: пустой список качества хуже неудобного.
     */
    if ([tiers count] == 0) {
        for (NSArray *pair in ladder) {
            [tiers addObject:[pair objectAtIndex:0]];
        }
    }

    return [[tiers allObjects] sortedArrayUsingSelector:@selector(compare:)];
}

+ (YTFormat *)chooseVideo:(NSArray *)formats maxHeight:(NSInteger)maxHeight {
    YTFormat *best = nil;

    for (YTFormat *format in formats) {
        // Дорожка должна быть чисто видеоряд, без звука: демуксер собирает
        // поток из двух дорожек сам.
        if (!format.hasVideo || format.hasAudio || ![format isH264]) {
            continue;
        }

        /**
         * Тумблер «60 кадров» действует и здесь.
         *
         * Прежде отбор по кадрам был только у подачи, а на готовых
         * адресах его не было вовсе: список качеств обещал одно,
         * выбор давал другое. При равной ступени берём ту, что чаще
         * кадрами, — иначе победила бы первая по порядку, а порядок
         * ведёт сервер.
         */
        if ([self prefersThirtyFrames] && format.fps > 31) {
            continue;
        }

        NSInteger tier = [format qualityTier];

        if (maxHeight > 0 && tier > maxHeight) {
            continue;
        }

        BOOL better = (best == nil)
            || (tier > [best qualityTier])
            || (tier == [best qualityTier] && format.fps > best.fps);

        if (better) {
            best = format;
        }
    }

    if (best != nil) {
        return best;
    }

    /**
     * Потолок мог отсечь всё — так бывает у роликов, снятых целиком выше
     * него. Тогда берётся самая мелкая из имеющихся: пусть устройство
     * хотя бы попробует.
     */
    for (YTFormat *format in formats) {
        if (!format.hasVideo || format.hasAudio || ![format isH264]) {
            continue;
        }

        if (best == nil || [format qualityTier] < [best qualityTier]) {
            best = format;
        }
    }

    return best;
}

+ (YTFormat *)chooseAudio:(NSArray *)formats preferredTrack:(NSString *)trackId {
    NSMutableArray *audio = [NSMutableArray array];

    for (YTFormat *format in formats) {
        NSString *mime = [format.mimeType lowercaseString];

        // Только AAC: Opus и прочее старое железо не декодирует, а наш
        // ремуксер умеет заворачивать в ADTS именно AAC.
        if (!format.hasAudio || format.hasVideo) {
            continue;
        }

        if (mime == nil || [mime rangeOfString:@"mp4a"].location == NSNotFound) {
            continue;
        }

        [audio addObject:format];
    }

    if ([audio count] == 0) {
        return nil;
    }

    YTFormat *best = nil;

    for (YTFormat *format in audio) {
        // Выбранная человеком дорожка языка важнее всего остального.
        if ([trackId length] > 0 && ![format.audioTrackId isEqualToString:trackId]) {
            continue;
        }

        if (best == nil || format.bitrate > best.bitrate) {
            best = format;
        }
    }

    if (best != nil) {
        return best;
    }

    /**
     * Человек ничего не выбирал — значит, играем родную.
     *
     * Не «основную»: основной сервер зовёт ту, что подходит языку
     * запроса, и у ролика с озвучками это озвучка. Просивший включить
     * ролик перевода не заказывал.
     */
    for (YTFormat *format in audio) {
        if (!format.audioIsOriginal || format.audioIsCompressed) {
            continue;
        }

        if (best == nil || format.bitrate > best.bitrate) {
            best = format;
        }
    }

    if (best != nil) {
        return best;
    }

    // Родной нет — тогда отмеченную сервером основной,
    // а если и такой нет, самую щедрую по битрейту.
    for (YTFormat *format in audio) {
        if (format.audioIsDefault && (best == nil || format.bitrate > best.bitrate)) {
            best = format;
        }
    }

    if (best != nil) {
        return best;
    }

    for (YTFormat *format in audio) {
        if (best == nil || format.bitrate > best.bitrate) {
            best = format;
        }
    }

    return best;
}

+ (BOOL)isBeyondDevice:(NSInteger)height {
    return (height > [self deviceMaxHeight]);
}

+ (NSInteger)deviceMaxHeight {
    static NSInteger maxHeight = 0;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        char model[64] = {0};
        size_t size = sizeof(model);

        sysctlbyname("hw.machine", model, &size, NULL, 0);

        NSString *name = [NSString stringWithUTF8String:model];

        NSLog(@"[YouTube/Потоки] Устройство: %@", name);

        /**
         * Правило по семейству и номеру, а не перечень моделей.
         *
         * Перечень пришлось бы дописывать под каждое новое устройство,
         * и всякая незнакомая модель попадала бы в «быстрые» молча —
         * иногда верно, иногда нет. Семейство же с номером говорит
         * о чипе прямо, и границы тут ровные:
         *
         *     iPhone1,x … iPhone3,x — до A4 включительно (по iPhone 4);
         *     iPod1,x  … iPod4,x    — до A4 (по iPod touch 4);
         *     iPad1,x               — A4 (iPad 1).
         *
         * Всё, что выше номером, — A5 и новее: iPhone 4S (iPhone4,1),
         * iPad 2 (iPad2,x), iPod touch 5 (iPod5,1) и дальше без края.
         * Незнакомое имя (симулятор, будущая модель) считается новым:
         * ошибиться в сторону запрета хуже, чем в сторону доверия, —
         * запрет человек не сможет снять, а лишнее качество снимается
         * настройкой.
         *
         * A4 к тому же декодирует H.264 не выше уровня 3.1, то есть
         * 720p: заявленный High 4.1 даёт на нём звук без картинки.
         * Отсюда и потолок высоты, а не только частоты.
         */
        NSString *family = nil;
        NSInteger number = 0;

        NSUInteger at = 0;

        while (at < [name length]) {
            unichar letter = [name characterAtIndex:at];

            if (letter >= '0' && letter <= '9') {
                break;
            }

            at++;
        }

        family = [name substringToIndex:at];

        while (at < [name length]) {
            unichar letter = [name characterAtIndex:at];

            if (letter < '0' || letter > '9') {
                break;
            }

            number = number * 10 + (letter - '0');
            at++;
        }

        BOOL oldChip =
            ([family isEqualToString:@"iPhone"] && number >= 1 && number <= 3) ||
            ([family isEqualToString:@"iPod"]   && number >= 1 && number <= 4) ||
            ([family isEqualToString:@"iPad"]   && number == 1);

        _slowDevice = oldChip;
        maxHeight = oldChip ? 720 : 1080;

        NSLog(@"[YouTube/Потоки] Чип: %@ (%@ %ld), потолок %ldp, "
              @"шестьдесят кадров по умолчанию %@",
              oldChip ? @"A4 или старше" : @"A5 или новее",
              [family length] > 0 ? family : @"?", (long)number,
              (long)maxHeight, oldChip ? @"выключены" : @"включены");
    });

    return maxHeight;
}

/**
 * Запоминает лестницу: ступень, её кадры и то, что скрыто тумблером.
 *
 * `pairs` — пары «ступень, кадры» по **всем** дорожкам H.264, до отбора.
 * Отбор делается здесь: так в одном месте и подпись «1080p60», и ответ
 * на вопрос «а куда делось 1080p».
 */
+ (void)rememberLadder:(NSArray *)pairs {
    NSMutableDictionary *frames = [NSMutableDictionary dictionary];
    NSMutableSet *all = [NSMutableSet set];

    BOOL thirty = [self prefersThirtyFrames];

    for (NSArray *pair in pairs) {
        NSInteger tier = [[pair objectAtIndex:0] integerValue];
        NSInteger rate = [[pair objectAtIndex:1] integerValue];

        if (tier <= 0) {
            continue;
        }

        NSNumber *key = [NSNumber numberWithInteger:tier];

        [all addObject:key];

        if (thirty && rate > 31) {
            continue;
        }

        NSNumber *have = [frames objectForKey:key];

        if (have == nil || rate > [have integerValue]) {
            [frames setObject:[NSNumber numberWithInteger:rate] forKey:key];
        }
    }

    NSMutableArray *only = [NSMutableArray array];

    for (NSNumber *tier in all) {
        if ([frames objectForKey:tier] == nil) {
            [only addObject:tier];
        }
    }

    @synchronized ([YTStreams class]) {
        _tierFrames = frames;
        _sixtyOnlyTiers = [only sortedArrayUsingSelector:@selector(compare:)];
    }

    /**
     * Лестницу пишем в журнал целиком.
     *
     * Частота у ступени — не наша выдумка и не округление: её называет
     * сам YouTube для каждой дорожки. У ролика, снятого на 24 кадра, так
     * и стоит 24, а 144p сервер отдаёт половинной частотой — 15 кадров
     * при 30 у остальных ступеней. Без этой строки спорить об этом
     * пришлось бы на память.
     */
    NSMutableString *listed = [NSMutableString string];

    for (NSNumber *tier in [[frames allKeys]
             sortedArrayUsingSelector:@selector(compare:)]) {
        [listed appendFormat:@"%@%ldp%ld", [listed length] > 0 ? @", " : @"",
            (long)[tier integerValue],
            (long)[[frames objectForKey:tier] integerValue]];
    }

    for (NSNumber *tier in [self sixtyOnlyHeights]) {
        [listed appendFormat:@"%@%ldp — только 60",
            [listed length] > 0 ? @", " : @"", (long)[tier integerValue]];
    }

    NSLog(@"[YouTube/Потоки] Лестница качеств: %@",
          [listed length] > 0 ? listed : @"пусто");
}

+ (NSInteger)framesForItag:(NSInteger)itag {
    @synchronized ([YTStreams class]) {
        return [[_itagFrames objectForKey:
            [NSNumber numberWithInteger:itag]] integerValue];
    }
}

+ (NSInteger)framesForHeight:(NSInteger)height {
    @synchronized ([YTStreams class]) {
        return [[_tierFrames objectForKey:
            [NSNumber numberWithInteger:height]] integerValue];
    }
}

+ (NSArray *)sixtyOnlyHeights {
    @synchronized ([YTStreams class]) {
        return _sixtyOnlyTiers ?: [NSArray array];
    }
}

+ (BOOL)prefersThirtyFrames {
    // Считается вместе с потолком — там же, где смотрят на модель.
    [self deviceMaxHeight];

    /**
     * Решает **настройка**, а модель — только её значение по умолчанию.
     *
     * Прежде здесь стояло «медленное устройство И настройка выключена»,
     * и на быстром устройстве тумблер не значил ничего: выключив его,
     * человек всё равно получал шестьдесят кадров. Между тем причины
     * выключить есть и там — греется, садится батарея, сеть слабая.
     */
    return ![YTSettings allowsSixtyFrames];
}

+ (BOOL)deviceDislikesSixtyFrames {
    [self deviceMaxHeight];

    return _slowDevice;
}

@end
