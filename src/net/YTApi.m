#import "YTApi.h"
#import "YTSabr.h"
#import "YTProto.h"

#import "YTStrings.h"

#import "YTAuth.h"
#import "YTHttp.h"
#import "YTJson.h"
#import "YTSettings.h"
#import "YTPlayerJs.h"
#import "YTPoToken.h"
#import "YTWebAuth.h"
#import "YTVideoItem.h"

/**
 * Ключ InnerTube. Он не секретный: один и тот же у всех веб-клиентов
 * YouTube и лежит в разметке любой страницы. Взят из Config.cs.
 */
static NSString *const YTInnertubeKey = @"AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8";

/** Версии клиентов — те же, что в UWP-версии. */
/**
 * Номер 85, а не 7, — и это не небрежность, а стена.
 *
 * В 1.4-164 я привёл личность клиента к дампу браузера: номер 7, версия
 * 7.20260909.12.00, Tizen 6.0, SamsungBrowser. Журнал 89 показал цену.
 * Через три минуты сервер начал слать в каждом ответе часть №58 —
 * «требуется подтверждение подлинности»: девять раз состояние 2, потом
 * сто семьдесят четыре раза состояние 3, и после этого лишь восемнадцать
 * ответов с кусками. Показ умер.
 *
 * Браузер получает состояние 1 во всех ста десяти ответах: у него есть
 * BotGuard, и он проходит проверку. Наш чеканщик PO-токена тоже крутит
 * BotGuard в UIWebView, но клиенту №7 сервер этого не засчитывает —
 * у настоящего TV-клиента в теле `/player` есть ещё `attestationRequest`,
 * которого у нас нет и которого не собрать на пятой iOS.
 *
 * С номером 85 в журналах 84–88 части №58 не было ни разу. Значит для
 * него проверка не включена, и это единственная личность, под которой
 * мы играем. Остальные поля запроса, выровненные по дампу, остаются.
 */
static NSString *const YTTvVersion      = @"7.20250209.19.00";
static NSString *const YTTvPlayerVersion = @"7.20260715.15.00";

/**
 * Версия TV-клиента, какой она была до SABR.
 *
 * Подачу через SABR раскатывают по версиям клиента: свежие получают
 * дорожки без адресов вовсе, старые — обычные, с готовыми ссылками.
 * Второй заход этой версией стоит один запрос и делается лишь тогда,
 * когда свежая ответила одним SABR.
 */
static NSString *const YTTvLegacyVersion = @"7.20220918.10.00";

/**
 * Версия, которой представиться вместо обычной, — на время одного
 * запроса.
 *
 * Заведено ради одного случая: повтора `/player` под старой версией
 * TV-клиента. Версия обязана совпасть в теле и в заголовках, а собирает
 * их `post:` внутри себя, поэтому подмена делается здесь, а не
 * передаётся насквозь через полдюжины вызовов.
 */
static NSString *YTVersionOverride = nil;
static NSString *const YTWebVersion     = @"2.20260430.08.00";
static NSString *const YTAndroidVersion = @"19.09.37";

/**
 * Версии клиентов, которыми ходят за Shorts, — из Config.cs.
 * Они там свои, отличные от общих: reel-запросы придирчивы к версии.
 */
static NSString *const YTShortsWebVersion = @"2.20260206.01.00";
static NSString *const YTShortsMwebVersion = @"2.20251222.01.00";
static NSString *const YTShortsAndroidVersion = @"20.10.38";

static NSString *const YTTvUserAgent =
    @"Mozilla/5.0 (SMART-TV; LINUX; Tizen 5.0) AppleWebKit/537.36 (KHTML, like Gecko) "
    @"Version/5.0 TV Safari/537.36";

static NSString *const YTWebUserAgent =
    @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
    @"Chrome/124.0.0.0 Safari/537.36";

/**
 * Клиент, у которого спрашиваются потоки, — шлем Oculus Quest.
 *
 * Перенесено из `Video.xaml.cs` дословно: имя, версия, номер клиента для
 * заголовка и User-Agent. Менять здесь нечего — набор подобран так, что
 * сервер отдаёт готовые подписанные адреса.
 */
static NSString *const YTAndroidVrVersion = @"1.65.10";
static NSString *const YTAndroidVrUserAgent =
    @"com.google.android.apps.youtube.vr.oculus/1.65.10 "
    @"(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip";

/**
 * Клиент шлема Apple Vision Pro.
 *
 * Единственный из безымянных, кому раздача отдаёт видео **дальше первой
 * минуты**. Остальные — ANDROID_VR, ANDROID, IOS — обрываются между 60-й
 * и 70-й секундой: подача перестаёт давать куски, а готовые адреса
 * отвечают отказом. Замерено не нами: тем же упирается Opaline, и там
 * это записано с числами (59904 мс и 69888 мс, проверка 18 августа
 * 2026 года).
 *
 * В наших журналах это ровно те же строки: «Подача не дала кусок 12
 * (время 61.4 с)», «не дала кусок 14 (время 60.3 с)», «не дала кусок 12
 * (время 61.1 с)» — на трёх разных устройствах и роликах. Выглядело
 * как поломка перемотки, а на деле сессия просто кончалась.
 */
static NSString *const YTVisionVersion = @"1.02";
static NSString *const YTVisionUserAgent =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 "
    @"(KHTML, like Gecko) Version/26.0 Safari/605.1.15";

/**
 * Клиент первичного `/player` — из `BuildPlayerPayload`. Там рядом стоит
 * пояснение: «Match get_url.py exactly: IOS client → streamingData.hlsManifestUrl».
 */
static NSString *const YTIosVersion = @"20.49.6";
static NSString *const YTIosUserAgent =
    @"com.google.ios.youtube/19.16.3 (iPhone16,2; U; CPU iOS 18_0 like Mac OS X)";

/** Версия WEB-клиента, которым добывается свежий `visitorData`. */
static NSString *const YTVisitorSeedVersion = @"2.20260626.01.00";

/** Запасной `visitorData` — из Config.cs, там он записан в процентном виде. */
static NSString *const YTFallbackVisitorData =
    @"CgtjTS00dGRYTXhBOCif8OnOBjIoCgJQTBIiEh4SHAsMDg8QERITFBUWFxgZGhscHR4fICEiIyQlJicgSA%3D%3D";

/**
 * `visitorData` текущего сеанса. Выдаётся сервером и живёт до перезапуска
 * либо до того, как его пометят: тогда он сбрасывается и добывается заново.
 */
static NSString *YTSessionVisitorData = nil;

/**
 * Признак учётной записи, выданный сервером. Приходит в `responseContext`
 * ответов вошедшего и служит привязкой для PO-токена: у аккаунта
 * доказательство привязано к нему, а не к посетителю.
 */
static NSString *YTSessionDatasyncId = nil;

/**
 * Имя, под которым надо ходить за кусками текущего ролика.
 *
 * Меняется вслед за тем, чей ответ `/player` в итоге пригодился: адрес
 * подписан под клиента (`c=…` записан прямо в нём), и раздача сверяет,
 * тем ли клиентом за ним пришли. Пока цепочка кончалась на ANDROID_VR,
 * значение было одно и стояло вшитым; теперь она может кончиться и WEB,
 * и IOS — и тогда прежнее имя означает отказ 403.
 */
static NSString *YTStreamUserAgent = nil;

/** Кто добыл нынешние адреса потоков — им же представляемся подаче. */
static NSString *YTStreamClient = nil;

/**
 * Привязка PO-токена, годная для адресов текущего ролика, — либо nil,
 * если клиент, добывший их, токеном не пользовался вовсе.
 *
 * Привязка у каждого клиента своя: WEB ходит с куками, и его удостоверяет
 * признак учётной записи; ANDROID_VR ходит гостем, и его удостоверяет
 * `visitorData` из того же запроса; IOS не просит токена и не шлёт
 * `visitorData` — ему приписывать нечего. Чужой `pot` в адресе хуже, чем
 * никакого: раздача сверяет его с тем сеансом, которым добыта ссылка,
 * и отвечает отказом 403.
 */
static NSString *YTStreamBinding = nil;

/** `visitorData`, с которым уходил последний запрос ANDROID_VR. */
static NSString *YTAndroidVrBinding = nil;

/** Ролик, чьи адреса играются сейчас, — нужен для проверки выхода в сеть. */
static NSString *YTStreamVideoId = nil;

/**
 * Согласия на cookie здесь нет намеренно.
 *
 * Европейский YouTube встречает несогласившегося стеной и отдаёт ленту
 * пустой, и напрашивается послать cookie `SOCS`. Но UWP-версия ничего
 * такого не шлёт, а требование к порту — повторять её запросы в точности.
 * Всё, что мы добавим от себя, — это расхождение, которое потом придётся
 * искать при каждом несовпадении поведения.
 *
 * Если лента приходит пустой — смотреть надо на то, откуда выходит трафик,
 * а не дописывать сюда заголовки.
 */

/** Ленты держим в памяти пару минут — возврат назад не перезапрашивает их. */
static const NSTimeInterval YTFeedTTL = 120;

@implementation YTApi

#pragma mark Язык

/**
 * Язык и страна запроса.
 *
 * Берутся из настроек устройства, а не зашиты: от них зависит и язык
 * названий разделов, и состав ленты. UWP-версия делает то же самое
 * в `EnsureLocale`.
 */
/**
 * Насколько пришлось поступиться локалью, чтобы сервер начал отвечать.
 *
 * 0 — своё и язык, и регион; 1 — свой язык, регион `US`; 2 — `en`/`US`.
 *
 * Ступени именно в таком порядке, и это не формальность. У пользователя
 * из Киргизии `browse` и поиск отвечали отказом при `hl=ru`, `gl=KG` —
 * то есть с языком, который YouTube знает наверняка. Значит, дело было
 * в регионе, а не в языке. Прежняя правка меняла разом и то и другое,
 * и выдача становилась английской — о чём он тут же и написал.
 *
 * Поэтому сначала уступаем только регион, и лишь если и это не помогло —
 * язык. Что именно спасло, видно по журналу: строка со ступенью пишется
 * при каждом переходе.
 */
static NSInteger YTLocaleRelax = 0;

/**
 * Чем называть выбранный канал: `pageId` или парой «профиль||владелец».
 *
 * Сервер присылает обе приметы разом и не говорит, какую ждёт обратно.
 * Шлём первую; получив 401, переходим на вторую и дальше держимся её —
 * так же, как с уступками локали. Обратно не возвращаемся: сеанс один
 * и учётная запись одна, метаться незачем.
 */
static BOOL YTUseDatasyncMark = NO;

+ (BOOL)switchIdentityForm {
    @synchronized ([YTApi class]) {
        if (YTUseDatasyncMark) {
            return NO;
        }

        if ([[self activeAccountPage] length] == 0 ||
            [[self activeAccountDatasync] length] == 0) {
            return NO;
        }

        YTUseDatasyncMark = YES;
    }

    NSLog(@"[YouTube/Аккаунт] `pageId` сервер не принял — переходим "
          @"на пару «профиль||владелец»");

    // Ответы, снятые до перехода, сняты чужой приметой.
    [YTHttp dropMemoryCache];

    return YES;
}

/** Чем сейчас называем выбранный канал; пусто — каналом не назвались. */
+ (NSString *)behalfMark {
    @synchronized ([YTApi class]) {
        if (YTUseDatasyncMark) {
            NSString *pair = [self activeAccountDatasync];

            if ([pair length] > 0) {
                return pair;
            }
        }
    }

    return [self activeAccountPage];
}

+ (BOOL)relaxLocale {
    NSString *wasHl = [self hl];
    NSString *wasGl = [self gl];

    @synchronized ([YTApi class]) {
        if (YTLocaleRelax >= 2) {
            return NO;
        }

        YTLocaleRelax++;
    }

    NSLog(@"[YouTube/API] Уступаем локаль (ступень %ld): было hl=%@ gl=%@, "
          @"стало hl=%@ gl=%@",
          (long)YTLocaleRelax, wasHl, wasGl, [self hl], [self gl]);

    return YES;
}

+ (NSString *)hl {
    @synchronized ([YTApi class]) {
        if (YTLocaleRelax >= 2) {
            return @"en";
        }
    }

    // Выбранный в настройках язык главнее системного — как `GetSavedLanguage`
    // в UWP-версии, где сохранённый выбор тоже перекрывает язык устройства.
    NSString *chosen = [YTSettings language];

    if ([chosen length] > 0) {
        return chosen;
    }

    NSArray *languages = [[NSUserDefaults standardUserDefaults] objectForKey:@"AppleLanguages"];
    NSString *first = [languages count] > 0 ? [languages objectAtIndex:0] : @"en";

    // «ru-RU» → «ru»: InnerTube ждёт двухбуквенный код.
    NSRange dash = [first rangeOfString:@"-"];

    return dash.location != NSNotFound ? [first substringToIndex:dash.location] : first;
}

+ (NSString *)gl {
    @synchronized ([YTApi class]) {
        if (YTLocaleRelax >= 1) {
            return @"US";
        }
    }

    NSLocale *locale = [NSLocale currentLocale];
    NSString *country = [locale objectForKey:NSLocaleCountryCode];

    return [country length] == 2 ? country : @"US";
}

#pragma mark Контексты клиентов

/**
 * Описание клиента в теле запроса.
 *
 * Клиент здесь обязан совпадать с тем, что уйдёт в заголовках
 * `X-YouTube-Client-Name` и `-Version`: несовпадение — известная причина
 * отказов, о ней прямо сказано в комментарии UWP-версии.
 */
+ (NSDictionary *)clientContext:(NSString *)client {
    NSMutableDictionary *context = [NSMutableDictionary dictionary];

    [context setObject:client forKey:@"clientName"];
    [context setObject:[self hl] forKey:@"hl"];
    [context setObject:[self gl] forKey:@"gl"];

    if ([client isEqualToString:@"TVHTML5"]) {
        [context setObject:YTVersionOverride ?: YTTvVersion forKey:@"clientVersion"];
        [context setObject:@"TV" forKey:@"platform"];
        [context setObject:@"Samsung" forKey:@"deviceMake"];
        [context setObject:@"SmartTV" forKey:@"deviceModel"];
        [context setObject:@"Tizen" forKey:@"osName"];
        [context setObject:@"5.0" forKey:@"osVersion"];
    } else if ([client isEqualToString:@"MWEB"]) {
        [context setObject:YTShortsMwebVersion forKey:@"clientVersion"];
        [context setObject:@"MOBILE" forKey:@"platform"];
    } else if ([client isEqualToString:@"ANDROID"]) {
        [context setObject:YTAndroidVersion forKey:@"clientVersion"];
        [context setObject:@"MOBILE" forKey:@"platform"];
        [context setObject:@"Android" forKey:@"osName"];
        [context setObject:@"11" forKey:@"osVersion"];
        [context setObject:[NSNumber numberWithInt:30] forKey:@"androidSdkVersion"];
        [context setObject:@"Google" forKey:@"deviceMake"];
        [context setObject:@"Pixel 5" forKey:@"deviceModel"];
    } else {
        [context setObject:YTWebVersion forKey:@"clientVersion"];
    }

    return context;
}

/** Номер клиента для заголовка: TV — 85, WEB — 1, ANDROID — 3. */
+ (NSString *)clientNumber:(NSString *)client {
    if ([client isEqualToString:@"TVHTML5"]) { return @"85"; }
    if ([client isEqualToString:@"ANDROID"]) { return @"3"; }
    if ([client isEqualToString:@"MWEB"])    { return @"2"; }

    return @"1";
}

+ (NSString *)clientVersion:(NSString *)client {
    if ([YTVersionOverride length] > 0) {
        return YTVersionOverride;
    }

    if ([client isEqualToString:@"TVHTML5"]) { return YTTvVersion; }
    if ([client isEqualToString:@"ANDROID"]) { return YTAndroidVersion; }
    if ([client isEqualToString:@"MWEB"])    { return YTShortsMwebVersion; }

    return YTWebVersion;
}

+ (NSString *)userAgent:(NSString *)client {
    if ([client isEqualToString:@"TVHTML5"]) { return YTTvUserAgent; }

    if ([client isEqualToString:@"ANDROID"]) {
        return [NSString stringWithFormat:
            @"com.google.android.youtube/%@ (Linux; U; Android 11) gzip", YTAndroidVersion];
    }

    return YTWebUserAgent;
}

#pragma mark Запрос

/**
 * POST к `youtubei/v1/<endpoint>`.
 *
 * `authorize` — слать ли `Authorization`. Слать его нужно не всегда:
 * с WEB-клиентом токен, выданный TV-клиенту, приводит к 400 — та же
 * находка, что записана в UWP-версии.
 */
+ (NSDictionary *)post:(NSString *)endpoint
                      body:(NSDictionary *)body
                    client:(NSString *)client
                 authorize:(BOOL)authorize
                       ttl:(NSTimeInterval)ttl {
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:body];

    NSMutableDictionary *context = [NSMutableDictionary dictionaryWithObject:
        [self clientContext:client] forKey:@"client"];

    /**
     * От чьего имени говорим, если у учётной записи каналов несколько.
     *
     * У одной записи Google бывает и личный канал, и бренд-каналы,
     * и детский. Какой из них считать своим, сервер решает сам, и решает
     * не всегда так, как ждёт человек: у одного из наших он выбрал канал
     * YouTube Kids. Выбранный человеком канал передаётся в `onBehalfOfUser`
     * — так же поступает и сам TV-клиент, когда в нём переключают профиль.
     */
    /**
     * **Только если запрос вообще кем-то подписан.**
     *
     * «Я от имени такого-то», сказанное без предъявления себя, — это
     * не просьба, а бессмыслица, и сервер отвечает на неё дословно:
     * `Request is missing required authentication credential`. Поиск
     * у нас уходит анонимным веб-клиентом, и стоило выбрать канал —
     * как поиск переставал работать целиком, отвечая 401 на всё.
     *
     * Хуже того, отказ этот тянул за собой ещё две беды: наш переход
     * на вторую примету канала (она тут ни при чём) и уступку локали
     * до `hl=en gl=US` на весь сеанс. Обе лечатся здесь же, в корне.
     */
    BOOL toldWho = ![client isEqualToString:@"TVHTML5"]
                && ![client isEqualToString:@"ANDROID"]
                 ? (!authorize && [YTWebAuth isSignedIn])
                 : NO;

    if (authorize && [[YTAuth accessToken] length] > 0) {
        toldWho = YES;
    }

    NSString *behalf = toldWho ? [self behalfMark] : nil;

    if ([behalf length] > 0) {
        [context setObject:[NSDictionary dictionaryWithObject:behalf
                                                       forKey:@"onBehalfOfUser"]
                    forKey:@"user"];
    }

    [payload setObject:context forKey:@"context"];

    NSString *url = [NSString stringWithFormat:
        @"https://www.youtube.com/youtubei/v1/%@?key=%@&prettyPrint=false",
        endpoint, YTInnertubeKey];

    NSMutableURLRequest *request =
        YTRequest(url, NSURLRequestUseProtocolCachePolicy, 25.0);

    if (request == nil) {
        return nil;
    }

    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[self userAgent:client] forHTTPHeaderField:@"User-Agent"];
    [request setValue:[self clientNumber:client] forHTTPHeaderField:@"X-YouTube-Client-Name"];
    [request setValue:[self clientVersion:client] forHTTPHeaderField:@"X-YouTube-Client-Version"];

    /**
     * `Accept-Language` шлём, `Origin` — нет.
     *
     * Ровно этот набор у `PostTvBrowseAsync` в оригинале: там заголовков
     * четыре — токен, User-Agent, пара `X-YouTube-Client-*` и язык.
     * `Origin` был отсебятиной: браузерный заголовок в запросе от клиента,
     * который браузером не является.
     */
    [request setValue:[NSString stringWithFormat:@"%@,%@;q=0.9", [self hl], [self hl]]
   forHTTPHeaderField:@"Accept-Language"];

    if (authorize) {
        NSString *token = [YTAuth accessToken];

        if ([token length] > 0) {
            [request setValue:[@"Bearer " stringByAppendingString:token]
           forHTTPHeaderField:@"Authorization"];
        }
    }

    /**
     * Веб-сессия подписывает то, что просит WEB-клиент.
     *
     * Порт `ApplyAuthenticatedHeaders` из SimpMusicLumia: куки уходят сами
     * (хранилище общее с UIWebView), а к ним добавляется подпись
     * `SAPISIDHASH`, номер аккаунта и origin. TV-клиента это не касается —
     * у него свой токен, и два способа представиться разом сервер
     * не принимает.
     */
    BOOL webClient = ![client isEqualToString:@"TVHTML5"]
        && ![client isEqualToString:@"ANDROID"];

    BOOL signedWithSession = NO;

    if (webClient && !authorize && [YTWebAuth isSignedIn]) {
        NSString *origin = @"https://www.youtube.com";
        NSString *signature = [YTWebAuth authorizationForOrigin:origin];

        if (signature != nil) {
            [request setValue:signature forHTTPHeaderField:@"Authorization"];
            [request setValue:@"0" forHTTPHeaderField:@"X-Goog-AuthUser"];
            [request setValue:origin forHTTPHeaderField:@"Origin"];
            [request setValue:origin forHTTPHeaderField:@"X-Origin"];

            signedWithSession = YES;
        }
    }

    /**
     * Куки уходят только с тем запросом, который мы **сами** подписали.
     *
     * Хранилище общее с UIWebView, и NSURLConnection по умолчанию
     * прикладывает куки ко всему, что идёт на youtube.com. После входа
     * это вышло боком: запрос ANDROID_VR — клиента заведомо анонимного,
     * ходящего с одним `visitorData`, — начал уносить с собой полный
     * сеанс аккаунта на две с половиной тысячи байт, но без подписи,
     * которая к такому сеансу полагается. Для Google это запрос,
     * наполовину вошедший, и отвечает он ровно тем, что мы и видели:
     * «Войдите в аккаунт, чтобы подтвердить, что вы не бот».
     *
     * Поэтому теперь: подписали — прикладываем; не подписали — нет.
     * У TV-клиента свой токен, и веб-сеанс ему тоже ни к чему.
     */
    [request setHTTPShouldHandleCookies:signedWithSession];

    [request setHTTPBody:[YTJson encode:payload]];

    /**
     * Локаль — один раз за сеанс, зато всегда.
     *
     * По ней разбирались две поломки подряд, и обе начинались с догадки
     * «а какой у него язык?» — при том что ответ есть у приложения
     * с первой секунды.
     */
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        NSLog(@"[YouTube/API] Локаль запросов: hl=%@, gl=%@", [self hl], [self gl]);
    });

    // Строка перед отправкой, а не только после отказа: без неё по журналу
    // не отличить «запрос ушёл и не вернулся» от «до запроса не дошло».
    /**
     * Чем представились — частью строки.
     *
     * Раньше отмечалась только веб-сессия, и заход веб-клиента с токеном
     * телевизора выглядел в журнале точно так же, как заход анонимный:
     * `→ next (WEB)`. Различать их надо, иначе по журналу не понять,
     * чей отказ мы читаем.
     */
    NSString *how = @"";

    if (webClient && !authorize && [YTWebAuth isSignedIn]) {
        how = @", веб-сессия";
    } else if (authorize && [[YTAuth accessToken] length] > 0) {
        how = @", токен";
    }

    /**
     * У `browse` дописываем, за чем именно пошли.
     *
     * Этим узлом берутся и «Главная», и подписки, и история, и плейлисты,
     * и каналы — в журнале они выглядели одинаково, и четыре подряд
     * `→ browse` было не разобрать: то ли одно и то же спрашивают четыре
     * раза, то ли четыре разные ленты разом.
     */
    NSString *what = @"";

    if ([endpoint isEqualToString:@"browse"]) {
        NSString *browseId = [YTJson textIn:payload key:@"browseId"];

        if ([browseId length] == 0 && [payload objectForKey:@"continuation"] != nil) {
            browseId = @"продолжение";
        }

        if ([browseId length] > 0) {
            what = [NSString stringWithFormat:@" %@", browseId];
        }
    }

    NSLog(@"[YouTube/API] → %@%@ (%@%@)", endpoint, what, client, how);

    // Потолок на тело: ответ «Главной» — это несколько мегабайт JSON,
    // и без ограничения одна сорвавшаяся страница могла бы вычерпать память.
    YTHttpResponse *response = ttl > 0
        ? [YTHttp send:request bodyLimit:12 * 1024 * 1024 cacheForTTL:ttl]
        : [YTHttp send:request bodyLimit:12 * 1024 * 1024];

    if (![response isSuccessful]) {
        NSError *error = response.error;

        // Домен и код важнее описания: по ним видно, чей это отказ —
        // наш собственный (-1012, снятая проверка сертификата), сетевой
        // (-1009 «нет сети», -1001 «истекло время») или сервера.
        NSLog(@"[YouTube/API] %@ (%@): код %ld, %@ %ld — %@", endpoint, client,
              (long)response.statusCode,
              [error domain] ?: @"без ошибки", (long)[error code],
              [error localizedDescription] ?: @"");

        /**
         * «Неверный запрос» при живой связи — повод усомниться в локали.
         *
         * Запрос собран нами одинаково для всех, а отказ приходит не всем:
         * у пользователя из Киргизии `browse` отвечал 400, а поиск —
         * пустотой, при том что `next` тем же клиентом работал. Ни списка
         * языков, ни списка регионов, которые InnerTube принимает, нигде
         * нет, поэтому проверяем опытом: уступаем ступень локали
         * и повторяем. Помогло — так и идём до конца сеанса.
         */
        /**
         * Слова сервера — тоже в журнал.
         *
         * Тело отказа мы прежде выбрасывали, и от 401 оставалось одно
         * число. А Google в этом теле пишет ровно то, чего не хватило:
         * «Request had invalid authentication credentials» — это одно,
         * а «Request is missing required authentication credential» —
         * совсем другое, и лечатся они по-разному.
         */
        NSString *said = [[NSString alloc] initWithData:response.body
                                               encoding:NSUTF8StringEncoding];

        if ([said length] > 0) {
            NSLog(@"[YouTube/API] %@ ответил: %@", endpoint,
                  [said length] > 500 ? [said substringToIndex:500] : said);
        }

        if (response.statusCode == 400 && [self relaxLocale]) {
            NSLog(@"[YouTube/API] Повторяем %@ (%@)", endpoint, client);

            return [self post:endpoint body:body client:client
                    authorize:authorize ttl:ttl];
        }

        /**
         * 401 при выбранном канале — сервер не принял того, чем мы этот
         * канал назвали.
         *
         * Личность канала сервер присылает двумя способами сразу:
         * `pageId` и парой «профиль||владелец» (`datasyncIdToken`).
         * Какой из них он ждёт обратно, по ответу не видно, и мы шлём
         * первый. Отказ означает, что нужен второй, — пробуем его
         * и дальше держимся того, что подошло.
         */
        if (response.statusCode == 401 && [behalf length] > 0 &&
            [self switchIdentityForm]) {
            NSLog(@"[YouTube/API] Повторяем %@ (%@) с другой приметой канала",
                  endpoint, client);

            return [self post:endpoint body:body client:client
                    authorize:authorize ttl:ttl];
        }

        return nil;
    }

    NSLog(@"[YouTube/API] ← %@ (%@): %lu КБ", endpoint, client,
          (unsigned long)([response.body length] / 1024));

    return [YTJson parse:response.body];
}

#pragma mark Продолжение

/**
 * Токен следующей страницы.
 *
 * Лежит он в `continuationItemRenderer` в конце списка. Ищем по всему
 * дереву — так же поступала UWP-версия (`FindContinuationTokenInObject`),
 * потому что глубина, на которой он окажется, зависит от рендерера.
 *
 * Потолок обхода общий, а не семь тысяч узлов, и это исправление.
 * Токен стоит **в конце** списка — то есть дальше всего от начала обхода,
 * — а ответ истории на пару сотен килобайт семи тысяч узлов не
 * укладывается. Обход упирался в потолок, не дойдя до конца, и список
 * выглядел исчерпанным: первая пачка приезжала, продолжения не было
 * никогда. Ровно та же беда уже случалась с лентой подписок и
 * с комментариями — там потолок подняли, здесь забыли.
 *
 * Стоимость невелика: полный обход делается один раз на страницу,
 * а не на каждую карточку.
 */
+ (NSString *)continuationIn:(id)tree {
    NSDictionary *item = [YTJson findFirst:@"continuationItemRenderer"
                                        in:tree limit:200000];

    if (item != nil) {
        NSDictionary *endpoint = [YTJson objectIn:item key:@"continuationEndpoint"];
        NSDictionary *command = [YTJson objectIn:endpoint key:@"continuationCommand"];

        NSString *token = [YTJson textIn:command key:@"token"];

        if (token != nil) {
            return token;
        }
    }

    // Старая форма, которую до сих пор отдаёт TV-клиент.
    NSDictionary *next = [YTJson findFirst:@"nextContinuationData" in:tree limit:200000];

    NSString *token = [YTJson textIn:next key:@"continuation"];

    if ([token length] > 0) {
        return token;
    }

    /**
     * Третья форма — `reloadContinuationData`.
     *
     * Именно её TV-клиент кладёт в панель комментариев, и ни одна
     * из двух прежних её не находила: комментарии у вертикальных
     * роликов открывались пустым списком, хотя ответ был исправный.
     */
    NSDictionary *reload = [YTJson findFirst:@"reloadContinuationData"
                                          in:tree limit:200000];

    return [YTJson textIn:reload key:@"continuation"];
}

/**
 * Собирает имена всех рендереров и view-model в ответе.
 *
 * Нужно ровно тогда, когда ответ полон, а разобрать из него нечего:
 * значит, полка в нём незнакомая. Имя полки — это и есть ответ на вопрос,
 * что дописать в разбор, и добывается он отсюда, а не перехватом трафика.
 */
static void YTCollectRendererNames(id node, NSMutableDictionary *counts, NSInteger depth) {
    if (depth > 40 || counts == nil) {
        return;
    }

    if ([node isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in node) {
            if ([key hasSuffix:@"Renderer"] || [key hasSuffix:@"ViewModel"]) {
                NSNumber *seen = [counts objectForKey:key];

                [counts setObject:[NSNumber numberWithInteger:[seen integerValue] + 1]
                           forKey:key];
            }

            YTCollectRendererNames([node objectForKey:key], counts, depth + 1);
        }

        return;
    }

    if ([node isKindOfClass:[NSArray class]]) {
        for (id item in node) {
            YTCollectRendererNames(item, counts, depth + 1);
        }
    }
}

/** Общий вид ответа со списком роликов. */
+ (NSDictionary *)feedFrom:(NSDictionary *)json {
    if (json == nil) {
        return nil;
    }

    NSArray *items = [YTVideoItem parseFrom:json];

    if ([items count] == 0) {
        /**
         * Ответ есть, роликов нет — почти всегда это стена согласия либо
         * региональное ограничение. Одного этого мало: снаружи «пустая
         * выдача» и «сервер отказал» выглядят одинаково, а лечатся
         * по-разному. Поэтому печатаем и то, из чего ответ состоит.
         *
         * Сам ответ в журнал не кладём: в `responseContext` едут метки
         * сеанса, а журналом делятся.
         */
        NSMutableString *note = [NSMutableString string];

        for (NSString *key in [json allKeys]) {
            [note appendFormat:@"%@%@", [note length] > 0 ? @", " : @"", key];
        }

        NSDictionary *error = [YTJson objectIn:json key:@"error"];

        if (error != nil) {
            [note appendFormat:@"; ошибка %ld %@ (%@)",
                (long)[YTJson intIn:error key:@"code"],
                [YTJson stringIn:error key:@"status" fallback:@"?"],
                [YTJson stringIn:error key:@"message" fallback:@"?"]];
        }

        for (NSDictionary *alert in [YTJson findAll:@"alertRenderer" in:json limit:2000]) {
            NSString *text = [YTJson renderedText:alert key:@"text"];

            if ([text length] > 0) {
                [note appendFormat:@"; окно: %@", text];
            }
        }

        NSLog(@"[YouTube/API] Ответ разобран, но роликов в нём нет — поля: %@", note);

        /**
         * И перечень полок — если ответ не пуст.
         *
         * «Полей много, роликов нет» значит, что в ответе лежит что-то,
         * чего разбор не знает. Печатаем имена рендереров по убыванию
         * числа — самое частое и есть то, что мы пропускаем.
         */
        if ([YTJson objectIn:json key:@"contents"] != nil) {
            NSMutableDictionary *counts = [NSMutableDictionary dictionary];

            YTCollectRendererNames(json, counts, 0);

            NSArray *names = [[counts allKeys] sortedArrayUsingComparator:
                ^NSComparisonResult(NSString *first, NSString *second) {
                    return [[counts objectForKey:second] compare:[counts objectForKey:first]];
                }];

            NSMutableString *shelves = [NSMutableString string];

            for (NSUInteger i = 0; i < [names count] && i < 12; i++) {
                NSString *name = [names objectAtIndex:i];

                [shelves appendFormat:@"%@%@×%@", [shelves length] > 0 ? @", " : @"",
                    name, [counts objectForKey:name]];
            }

            NSLog(@"[YouTube/API] Что в ответе лежит: %@", shelves);
        }
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    [result setObject:items forKey:@"items"];

    NSString *continuation = [self continuationIn:json];

    if (continuation != nil) {
        [result setObject:continuation forKey:@"continuation"];
    }

    return result;
}

#pragma mark Лента

+ (NSDictionary *)homeFeed:(NSString *)continuation {
    return [self homeFeedWithParams:nil continuation:continuation];
}

+ (NSDictionary *)homeFeedWithParams:(NSString *)params continuation:(NSString *)continuation {
    /**
     * «Главная» — это `FEwhat_to_watch` у **TV-клиента и с токеном**.
     *
     * Так делает `GetRecommendationsPageAsync`, и никак иначе: там
     * при пустом refresh-токене метод сразу возвращает пустую страницу,
     * а запрос уходит через `PostTvBrowseAsync` — клиент TVHTML5,
     * заголовок `Authorization`.
     *
     * Прежде здесь стоял WEB-клиент без токена, и это была отсебятина.
     * Она же и была причиной пустой ленты у вошедшего: анонимный
     * `FEwhat_to_watch` у WEB-клиента отвечает успешно, но без роликов —
     * рекомендовать ему некому.
     *
     * У невошедшего ленты нет вовсе — тоже как в оригинале. На её месте
     * показывается призыв поискать (`SuggestionsSection` из Home.xaml),
     * это делает сам раздел, увидев пустой ответ.
     */
    if (![YTAuth isSignedIn]) {
        return nil;
    }

    NSMutableDictionary *body = [NSMutableDictionary dictionary];

    if ([continuation length] > 0) {
        [body setObject:continuation forKey:@"continuation"];
    } else {
        [body setObject:@"FEwhat_to_watch" forKey:@"browseId"];

        if ([params length] > 0) {
            [body setObject:params forKey:@"params"];
        }
    }

    return [self feedFrom:[self post:@"browse"
                                body:body
                              client:@"TVHTML5"
                           authorize:YES
                                 ttl:[continuation length] > 0 ? 0 : YTFeedTTL]];
}

/**
 * Лента таблетки — тем же клиентом, каким её листает браузер.
 *
 * Обычная «Главная» у нас уходит TV-клиентом с токеном, и это правильно:
 * рекомендации там свои. Но наборы таблеток — `EgIIBBoETGl2ZUgC` и
 * подобные — TV-клиент не понимает и отвечает на них как на запрос без
 * набора. Оттого нажатие на «Сейчас в эфире» и не меняло ничего.
 *
 * В браузере эта таблетка — обычный `browse` от WEB-клиента, подписанный
 * сессией (куки плюс `SAPISIDHASH`). Ровно это здесь и делается: `post:`
 * подписывает веб-клиента сам, когда веб-сессия есть. Нет её — запрос
 * уходит безымянным, и трансляции всё равно приходят: подборка не личная.
 */
/**
 * Лента с полками: заголовок и его плитки.
 *
 * Разбор тот же, что у «Истории» с её днями: полка — это `shelfRenderer`
 * с заголовком, внутри плитки. Вынесен сюда, чтобы не повторять.
 */
+ (NSArray *)shelvesIn:(NSDictionary *)json {
    NSMutableArray *groups = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    NSArray *names = [NSArray arrayWithObjects:
        @"shelfRenderer", @"richShelfRenderer", @"itemSectionRenderer", nil];

    for (NSDictionary *hit in [YTJson findAllOfAny:names in:json limit:200000]) {
        NSDictionary *node = [hit objectForKey:@"node"];
        NSString *title = [self historyDayTitleIn:node];

        if ([title length] == 0) {
            continue;
        }

        NSMutableArray *items = [NSMutableArray array];

        for (YTVideoItem *item in [YTVideoItem parseFrom:node]) {
            NSString *key = [item.videoId length] > 0 ? item.videoId : item.title;

            if ([key length] == 0 || [seen containsObject:key]) {
                continue;
            }

            [seen addObject:key];
            [items addObject:item];
        }

        if ([items count] == 0) {
            continue;
        }

        [groups addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            title, @"title", items, @"items", nil]];
    }

    return groups;
}

/**
 * Вкладка «Сейчас в эфире» — это `FEtopics_live` у TV-клиента.
 *
 * Прежде здесь была возня с набором `EgIIBBoETGl2ZUgC` и меткой из облака
 * таблеток: я искал эфиры там, где их листает веб. Дамп yttv7 показал, что
 * у телевизора для этого свой раздел — `FEtopics_live`, рядом с
 * `FEtopics_gaming` и `FEtopics_music`. Он и отвечает полками:
 * «Recommended», «Live Now», «Recent Live Streams».
 */
+ (NSDictionary *)liveFeed:(NSString *)continuation {
    /**
     * У вошедшего и у безымянного — разные двери.
     *
     * `FEtopics_live` — раздел TV-клиента, и он требует токена: без входа
     * не отвечает вовсе. Безымянному эфиры отдаёт канал
     * `UC4R8DWoMoI7CAwX8_LjQHig` — это и есть youtube.com/live, куда
     * браузер попадает без всякой подписи (дамп yt8: ни `Authorization`,
     * ни кук, клиент WEB, ответ на 784 килобайта).
     *
     * Полки у них разные по виду, но не по смыслу: у телевизора
     * `shelfRenderer`, у веба `richShelfRenderer`. Разбор знает оба.
     */
    BOOL signedIn = [YTAuth isSignedIn];

    NSMutableDictionary *body = [NSMutableDictionary dictionary];

    if ([continuation length] > 0) {
        [body setObject:continuation forKey:@"continuation"];
    } else {
        [body setObject:(signedIn ? @"FEtopics_live" : @"UC4R8DWoMoI7CAwX8_LjQHig")
                 forKey:@"browseId"];
    }

    NSDictionary *json = [self post:@"browse"
                               body:body
                             client:(signedIn ? @"TVHTML5" : @"WEB")
                          authorize:signedIn
                                ttl:0];

    if (json == nil) {
        return nil;
    }

    NSMutableDictionary *result =
        [NSMutableDictionary dictionaryWithDictionary:[self feedFrom:json]];

    NSArray *groups = [self shelvesIn:json];

    if ([groups count] > 0) {
        [result setObject:groups forKey:@"groups"];
    }

    NSLog(@"[YouTube/API] Эфиры (%@): полок %lu, роликов %lu, продолжение %@",
          signedIn ? @"раздел TV" : @"канал, без входа",
          (unsigned long)[groups count],
          (unsigned long)[[result objectForKey:@"items"] count],
          [result objectForKey:@"continuation"] != nil ? @"есть" : @"нет");

    return result;
}

+ (NSArray *)homeCategories {
    /**
     * «Таблетки» — **не запрос**, а свой список.
     *
     * Так в оригинале, и там об этом сказано прямо:
     * «Home chips are fixed locally. Do not request categories/chips from
     * Innertube» (`GetHomeCategoriesAsync`). Раньше здесь искался
     * `chipCloudChipRenderer` в ответе «Главной» — лишний запрос ради
     * набора, который и так известен, да ещё и другой у вошедшего.
     *
     * У каждой таблетки, кроме первой, есть поисковый запрос: выбор
     * таблетки в оригинале выполняет обычный поиск по нему
     * (`GetHomeCategoryVideosAsync` → `GetAnonymousSearchVideosAsync`),
     * а не листает ленту с `params`. Запросы английские намеренно —
     * они же в UWP: так выдача не зависит от языка приложения.
     */
    static NSArray *categories = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        NSArray *flat = [NSArray arrayWithObjects:
            YTLoc(@"Все"), @"",
            YTLoc(@"Фильмы и анимация"), @"Film & Animation",
            YTLoc(@"Авто"), @"Autos & Vehicles",
            YTLoc(@"Музыка"), @"Music",
            YTLoc(@"Животные"), @"Pets & Animals",
            YTLoc(@"Спорт"), @"Sports",
            YTLoc(@"Короткометражки"), @"Short Movies",
            YTLoc(@"Путешествия"), @"Travel & Events",
            YTLoc(@"Игры"), @"Gaming",
            YTLoc(@"Влоги"), @"Videoblogging",
            YTLoc(@"Люди и блоги"), @"People & Blogs",
            YTLoc(@"Юмор"), @"Comedy videos",
            YTLoc(@"Развлечения"), @"Entertainment",
            YTLoc(@"Новости и политика"), @"News & Politics",
            YTLoc(@"Стиль"), @"Howto & Style",
            YTLoc(@"Образование"), @"Education",
            YTLoc(@"Наука и техника"), @"Science & Technology",
            YTLoc(@"Благотворительность"), @"Nonprofits & Activism",
            YTLoc(@"Кино"), @"Movies",
            YTLoc(@"Аниме"), @"Anime Animation",
            YTLoc(@"Боевики"), @"Action Adventure movies",
            YTLoc(@"Классика"), @"Classic movies",
            YTLoc(@"Комедии"), @"Comedy movies",
            YTLoc(@"Документальные"), @"Documentary movies",
            YTLoc(@"Драмы"), @"Drama movies",
            YTLoc(@"Семейные"), @"Family movies",
            YTLoc(@"Зарубежные"), @"Foreign movies",
            YTLoc(@"Ужасы"), @"Horror movies",
            YTLoc(@"Фантастика"), @"Sci-Fi Fantasy movies",
            YTLoc(@"Триллеры"), @"Thriller movies",
            @"Shorts", @"YouTube Shorts",
            YTLoc(@"Сериалы"), @"Shows",
            YTLoc(@"Трейлеры"), @"Trailers",
            nil];

        NSMutableArray *list = [NSMutableArray array];

        for (NSUInteger i = 0; i + 1 < [flat count]; i += 2) {
            NSMutableDictionary *entry = [NSMutableDictionary dictionary];

            [entry setObject:[flat objectAtIndex:i] forKey:@"title"];

            NSString *query = [flat objectAtIndex:i + 1];

            if ([query length] > 0) {
                [entry setObject:query forKey:@"query"];
            }

            [list addObject:entry];
        }

        /**
         * «Сейчас в эфире» — не поиск, а та же лента с `params`.
         *
         * Остальные таблетки в оригинале выполняют поиск по английской
         * строке, но эфиру такой запрос не годится: поиск по слову «live»
         * приносит что угодно, кроме идущих трансляций. В вебе эта
         * таблетка листает `FEwhat_to_watch` с набором `EgIIBBoETGl2ZUgC`
         * — он и лежит здесь. Набор короткий и к сеансу не привязан:
         * длинная строка продолжения из браузера лишь заворачивает его
         * вместе со снимком страницы, а нужен из неё только он.
         *
         * Стоит второй, сразу за «Всеми»: так же, как в вебе.
         */
        NSMutableDictionary *live = [NSMutableDictionary dictionary];

        [live setObject:YTLoc(@"Сейчас в эфире") forKey:@"title"];
        [live setObject:@"FEtopics_live" forKey:@"browse"];

        [list insertObject:live atIndex:1];

        categories = [list copy];
    });

    return categories;
}

#pragma mark Поиск

+ (NSDictionary *)search:(NSString *)query continuation:(NSString *)continuation {
    return [self search:query continuation:continuation kind:YTSearchVideos];
}

+ (NSDictionary *)search:(NSString *)query
            continuation:(NSString *)continuation
                    kind:(YTSearchKind)kind {
    NSMutableDictionary *body = [NSMutableDictionary dictionary];

    if ([continuation length] > 0) {
        [body setObject:continuation forKey:@"continuation"];
    } else {
        [body setObject:query forKey:@"query"];

        // Пометки — те же, что в `GetSearchParams`.
        NSString *params = nil;

        switch (kind) {
            case YTSearchPlaylists: params = @"EgIQAw=="; break;
            case YTSearchChannels:  params = @"EgIQAg=="; break;
            case YTSearchShorts:    params = nil;        break;
            default:                params = @"EgIQAQ=="; break;
        }

        if (params != nil) {
            [body setObject:params forKey:@"params"];
        }
    }

    /**
     * Поиск от имени вошедшего, если вход есть.
     *
     * Вход по QR-коду — это токен TV-клиента (`YTAuth`), и веб-запросу он
     * не подписывается: WEB-клиент умеет только веб-сессию (`YTWebAuth`).
     * Оттого таблетки на «Главной», которые суть поиск, шли безымянными
     * даже у вошедшего: без истории, без «не рекомендовать канал», без
     * возрастных отметок. Если веб-сессии нет, а токен есть — спрашиваем
     * тем же клиентом, что и «Главную»: TVHTML5 с токеном. Ответ поиска у
     * него в тех же плитках, что и лента, и разбор их уже знает.
     */
    BOOL asTv = [YTAuth isSignedIn] && ![YTWebAuth isSignedIn];

    NSDictionary *json = [self post:@"search"
                               body:body
                             client:asTv ? @"TVHTML5" : @"WEB"
                          authorize:asTv
                                ttl:0];

    /**
     * Пустая выдача — тоже повод усомниться в локали.
     *
     * Поиск, в отличие от `browse`, на непонятную локаль отвечает
     * не отказом, а вежливым ничем: код 200, два килобайта одного лишь
     * `responseContext`. Отличить это от «правда ничего не нашлось»
     * можно только повтором, и повторяем мы ровно один раз за сеанс —
     * дальше нейтральная локаль стоит уже у всех запросов.
     */
    /**
     * `json != nil` здесь обязательно, и это не перестраховка.
     *
     * Пустой ответ и **отсутствие** ответа — разные вещи, а по одному
     * лишь `contents` они неразличимы: у неудачи там тоже пусто.
     * Из-за этого всякий отказ поиска — хоть 401, хоть обрыв связи —
     * проходил за «непонятную локаль» и уводил приложение в `hl=en gl=US`
     * до перезапуска, вместе с лентой и подписями. В журнале это видно
     * прямо: три 401 подряд и две ступени уступки между ними.
     */
    while (json != nil &&
           [YTJson objectIn:json key:@"contents"] == nil &&
           [continuation length] == 0 &&
           [self relaxLocale]) {

        NSLog(@"[YouTube/API] Поиск ничего не дал — повторяем");

        json = [self post:@"search" body:body
                    client:asTv ? @"TVHTML5" : @"WEB" authorize:asTv ttl:0];
    }

    /**
     * Каналы разбираются своим ходом: общий разбор знает только ролики
     * и подборки, а `channelRenderer` пропускает — оттого вкладка
     * «Каналы» и отвечала «роликов в нём нет».
     */
    if (kind == YTSearchChannels) {
        NSMutableDictionary *feed = [NSMutableDictionary dictionaryWithDictionary:
            [self feedFrom:json]];

        [feed setObject:[YTVideoItem parseChannelsFrom:json] forKey:@"items"];

        return feed;
    }

    if (kind != YTSearchShorts) {
        NSMutableDictionary *feed = [NSMutableDictionary dictionaryWithDictionary:
            [self feedFrom:json] ?: [NSDictionary dictionary]];

        /**
         * Пусто, а ответ полон — досматриваем вертикальные.
         *
         * Общий разбор их пропускает намеренно: у Shorts своя лента
         * и свой разбор. Но в выдаче поиска они встречаются полкой
         * посреди обычных роликов, и бывает выдача, где кроме них
         * ничего и нет, — по такому запросу экран оставался пустым.
         * Лучше показать вертикальные, чем ничего.
         */
        if ([[feed objectForKey:@"items"] count] == 0 && json != nil &&
            ![YTSettings hidesShorts]) {
            NSArray *shorts = [YTVideoItem parseShortsFrom:json];

            if ([shorts count] > 0) {
                NSLog(@"[YouTube/API] Обычных роликов в выдаче нет, "
                      @"зато вертикальных %lu — показываем их",
                      (unsigned long)[shorts count]);

                [feed setObject:shorts forKey:@"items"];
            }
        }

        return feed;
    }

    /**
     * Вертикальные отбираются из общей выдачи своим разбором.
     *
     * Пометки `params` для них у YouTube нет — сервер подмешивает их
     * полкой в обычную выдачу, откуда оригинал их и достаёт. Общий
     * разбор такие карточки пропускает намеренно, поэтому здесь идёт
     * отдельный, по именам `reelItemRenderer` и `shortsLockupViewModel`.
     */
    NSMutableDictionary *feed = [NSMutableDictionary dictionaryWithDictionary:
        [self feedFrom:json]];

    [feed setObject:[YTVideoItem parseShortsFrom:json] forKey:@"items"];

    return feed;
}

+ (NSArray *)searchSuggestions:(NSString *)query {
    if ([query length] == 0) {
        return nil;
    }

    /**
     * Подсказки живут не в InnerTube, а в старой службе `suggestqueries`,
     * и отвечает она не JSON, а JSONP: `window.google.ac.h([...])`.
     * Разбирается это отрезанием обёртки — так же делала UWP-версия.
     */
    NSString *url = [NSString stringWithFormat:
        @"https://suggestqueries.google.com/complete/search?client=youtube&ds=yt&hl=%@&q=%@",
        [self hl], YTEncodeParameter(query)];

    NSMutableURLRequest *request = YTRequest(url, NSURLRequestUseProtocolCachePolicy, 10.0);

    if (request == nil) {
        return nil;
    }

    YTHttpResponse *response = [YTHttp send:request bodyLimit:256 * 1024];

    if (![response isSuccessful]) {
        return nil;
    }

    NSString *text = [response text];

    NSRange open = [text rangeOfString:@"("];
    NSRange close = [text rangeOfString:@")" options:NSBackwardsSearch];

    if (open.location == NSNotFound || close.location == NSNotFound ||
        close.location <= open.location) {
        return nil;
    }

    NSRange inner = NSMakeRange(open.location + 1, close.location - open.location - 1);
    NSData *payload = [[text substringWithRange:inner] dataUsingEncoding:NSUTF8StringEncoding];

    // Ответ здесь массив, а не объект, поэтому не через YTJson parse:.
    id parsed = [NSJSONSerialization JSONObjectWithData:payload options:0 error:NULL];

    if (![parsed isKindOfClass:[NSArray class]] || [parsed count] < 2) {
        return nil;
    }

    id list = [parsed objectAtIndex:1];

    if (![list isKindOfClass:[NSArray class]]) {
        return nil;
    }

    NSMutableArray *suggestions = [NSMutableArray array];

    for (id row in list) {
        // Каждая строка — это [текст, вес, …]; нужен только текст.
        if ([row isKindOfClass:[NSArray class]] && [row count] > 0) {
            id first = [row objectAtIndex:0];

            if ([first isKindOfClass:[NSString class]]) {
                [suggestions addObject:first];
            }
        } else if ([row isKindOfClass:[NSString class]]) {
            [suggestions addObject:row];
        }
    }

    return suggestions;
}

#pragma mark Ролик

+ (NSDictionary *)videoDetails:(NSString *)videoId {
    return [self videoDetails:videoId playlist:nil];
}

+ (NSDictionary *)videoDetails:(NSString *)videoId playlist:(NSString *)playlistId {
    NSMutableDictionary *body = [NSMutableDictionary dictionary];

    [body setObject:videoId forKey:@"videoId"];

    /**
     * Идентификатор подборки уходит в запрос вместе с роликом — иначе
     * очереди в ответе не будет вовсе. В оригинале страница ролика
     * получает `PlaylistId` при переходе и передаёт его дальше: без него
     * микс открывался бы одиноким роликом, о чём в `ParseTileRenderer`
     * сказано прямо.
     */
    if ([playlistId length] > 0) {
        [body setObject:playlistId forKey:@"playlistId"];
    }

    NSDictionary *json = [self postNext:body];

    if (json == nil) {
        return nil;
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    /**
     * Заголовок и счётчики лежат в `videoPrimaryInfoRenderer`, автор
     * и описание — в `videoSecondaryInfoRenderer`. Порт
     * `ExtractVideoInfoFromRenderer`, только поиск по дереву вместо ходьбы
     * по известному пути: форма ответа `next` у WEB-клиента меняется чаще,
     * чем хотелось бы.
     */
    /**
     * Метка чата трансляции — отдельно от панелей комментариев.
     *
     * Именно отдельно: у эфира комментариев может не быть вовсе, и внутри
     * обхода панелей эта метка просто не нашлась бы. Живёт она в своём
     * месте, `conversationBar`, и от комментариев не зависит.
     */
    NSString *chatToken = [self liveChatTokenIn:json];

    if ([chatToken length] > 0) {
        [result setObject:chatToken forKey:@"liveChatToken"];
    }

    NSDictionary *primary = [YTJson findFirst:@"videoPrimaryInfoRenderer" in:json limit:6000];
    NSDictionary *secondary = [YTJson findFirst:@"videoSecondaryInfoRenderer" in:json limit:6000];

    NSString *title = [YTJson renderedText:primary key:@"title"];

    [result setObject:(title ?: @"") forKey:@"title"];

    NSString *views = [YTJson renderedText:
        [YTJson objectIn:[YTJson objectIn:primary key:@"viewCount"] key:@"videoViewCountRenderer"]
        key:@"viewCount"];

    if (views != nil) { [result setObject:views forKey:@"views"]; }

    NSString *published = [YTJson renderedText:primary key:@"dateText"];

    if (published != nil) { [result setObject:published forKey:@"published"]; }

    NSDictionary *owner = [YTJson findFirst:@"videoOwnerRenderer" in:secondary limit:2000];

    NSString *channelTitle = [YTJson renderedText:owner key:@"title"];

    if (channelTitle != nil) { [result setObject:channelTitle forKey:@"channelTitle"]; }

    NSString *subscribers = [YTJson renderedText:owner key:@"subscriberCountText"];

    if (subscribers != nil) { [result setObject:subscribers forKey:@"subscribers"]; }

    NSString *avatar = [YTJson thumbnailIn:owner key:@"thumbnail" minWidth:88];

    if (avatar != nil) { [result setObject:avatar forKey:@"channelThumbnail"]; }

    NSDictionary *browse = [YTJson findFirst:@"browseEndpoint" in:owner limit:500];
    NSString *channelId = [YTJson textIn:browse key:@"browseId"];

    if (channelId != nil) { [result setObject:channelId forKey:@"channelId"]; }

    NSString *description = [YTJson renderedText:secondary key:@"attributedDescription"];

    if (description == nil) {
        description = [YTJson renderedText:secondary key:@"description"];
    }

    if (description == nil) {
        // Новая форма: описание лежит в attributedDescription с полем content.
        NSDictionary *attributed = [YTJson objectIn:secondary key:@"attributedDescription"];
        description = [YTJson textIn:attributed key:@"content"];
    }

    if (description != nil) { [result setObject:description forKey:@"description"]; }

    /**
     * Число лайков берётся из подписи кнопки. Отдельного числового поля
     * у InnerTube нет: сервер отдаёт уже готовую строку вроде «20 тыс.»,
     * и в оригинале показывается именно она.
     */
    NSDictionary *likeButton = [YTJson findFirst:@"segmentedLikeDislikeButtonViewModel"
                                              in:json limit:6000];

    /**
     * Спускаемся именно по ветке лайка, а не первым попавшимся
     * переключателем.
     *
     * Под этой подложкой их два — лайк и дизлайк, — а обход дерева ходит
     * по ключам словаря, порядок которых в Cocoa не определён. Оттого
     * на кнопке и оказывалась подпись «Не нравится» вместо счётчика:
     * искали `toggleButtonViewModel`, а находили тот, что от дизлайка.
     * Имя `likeButtonViewModel` двусмысленности не оставляет.
     */
    NSDictionary *likeBranch = [YTJson findFirst:@"likeButtonViewModel"
                                              in:likeButton limit:1000];

    NSDictionary *likeToggle = [YTJson findFirst:@"toggleButtonViewModel"
                                              in:(likeBranch ?: likeButton) limit:1000];

    NSDictionary *likeDefault = [YTJson objectIn:likeToggle key:@"defaultButtonViewModel"];

    NSDictionary *likeInner = [YTJson findFirst:@"buttonViewModel"
                                             in:(likeDefault ?: likeToggle) limit:500];

    NSString *likes = [YTJson textIn:likeInner key:@"title"];

    if (likes == nil) {
        NSDictionary *old = [YTJson findFirst:@"toggleButtonRenderer" in:json limit:6000];
        likes = [YTJson renderedText:old key:@"defaultText"];
    }

    if (likes != nil) { [result setObject:likes forKey:@"likes"]; }

    // Похожие — обычные карточки, разбираются общим путём.
    NSDictionary *secondaryResults = [YTJson findFirst:@"secondaryResults" in:json limit:6000];

    [result setObject:[YTVideoItem parseFrom:secondaryResults] forKey:@"related"];

    /**
     * Очередь подборки — список роликов плейлиста или микса, открытого
     * вместе с этим.
     *
     * Порт `PlaylistQueuePanel` из Video.xaml: в ответе `next` она лежит
     * отдельной веткой `playlist.playlist` и состоит из
     * `playlistPanelVideoRenderer`. Разбирать её надо именно оттуда,
     * а не общим ходом по всему ответу: те же рендереры встречаются
     * и в других местах, и в «похожие» попадала бы чужая очередь.
     *
     * Ключи: `queue` (массив YTVideoItem), `queueTitle` и `queueIndex` —
     * номер текущего ролика, из которого собирается подпись «3 из 50».
     */
    NSDictionary *queue = [YTJson objectIn:[YTJson findFirst:@"playlist" in:json limit:6000]
                                       key:@"playlist"];

    if (queue != nil) {
        NSArray *items = [YTVideoItem parseFrom:[YTJson arrayIn:queue key:@"contents"]];

        if ([items count] > 0) {
            [result setObject:items forKey:@"queue"];

            NSString *queueTitle = [YTJson textIn:queue key:@"title"];

            if (queueTitle == nil) {
                queueTitle = [YTJson renderedText:queue key:@"titleText"];
            }

            if (queueTitle != nil) {
                [result setObject:queueTitle forKey:@"queueTitle"];
            }

            [result setObject:[NSNumber numberWithInteger:
                [YTJson intIn:queue key:@"currentIndex"]] forKey:@"queueIndex"];
        }
    }

    /**
     * Токен комментариев лежит в панели с идентификатором
     * `engagement-panel-comments-section` — порт `FindCommentsContinuation`.
     * Брать первый попавшийся токен нельзя: рядом лежит токен похожих.
     */
    NSArray *panels = [YTJson findAll:@"engagementPanelSectionListRenderer" in:json limit:6000];

    for (NSDictionary *panel in panels) {
        NSString *identifier = [YTJson textIn:panel key:@"panelIdentifier"];

        /**
         * Имя панели у веба и у TV-клиента разное: `engagement-panel-
         * comments-section` против `comment-item-section`. Берём оба —
         * ответы приходят и от того, и от другого.
         */
        if (![identifier isEqualToString:@"engagement-panel-comments-section"] &&
            ![identifier isEqualToString:@"comment-item-section"]) {
            continue;
        }

        NSString *token = [self continuationIn:panel];

        if (token != nil) {
            [result setObject:token forKey:@"commentsToken"];
        }

        /**
         * Сколько комментариев — здесь же, в шапке панели.
         *
         * Лежит оно не в «commentCount», как можно было бы подумать,
         * а в `contextualInfo` — строкой рядом с заголовком «Комментарии»,
         * той самой, что видна под роликом: «2,4 млн». Проверено
         * на живом ответе. Раньше счётчик брали только у TV-клиента,
         * а тот отвечает вошедшим, — оттого у вертикальных роликов
         * без входа его не было вовсе.
         */
        if ([result objectForKey:@"comments"] == nil) {
            NSDictionary *header = [YTJson findFirst:@"engagementPanelTitleHeaderRenderer"
                                                  in:panel limit:600];

            NSString *count = [YTJson renderedText:header key:@"contextualInfo"];

            if ([count length] > 0) {
                [result setObject:count forKey:@"comments"];
            }
        }

        break;
    }

    /**
     * Лайк и подписка — отдельным запросом к TV-клиенту.
     *
     * Веб-ответ о них молчит, если браузерной сессии нет, а она у нас
     * не основной вход. Что скажет TV-клиент, то и показываем; не скажет
     * ничего — остаётся то, что нашлось в вебе.
     */
    NSDictionary *state = [self watchState:videoId];

    for (NSString *key in state) {
        [result setObject:[state objectForKey:key] forKey:key];
    }

    return result;
}

/**
 * Метки ответа и правки из поддерева одного комментария.
 *
 * Имена полей берутся по всему поддереву, а не по известному пути:
 * форма этой поверхности меняется чаще, чем имена, — так же добывается
 * и метка написания комментария. Что найдётся, то и кладём; чего нет,
 * того у нас и не будет — сервер не даёт метку правки чужому
 * комментарию, и по её отсутствию как раз и видно, что он чужой.
 */
+ (void)collectCommentMarks:(NSDictionary *)node into:(NSMutableDictionary *)entry {
    NSString *reply = [YTJson findString:@"createReplyParams" in:node limit:20000];

    if ([reply length] > 0) {
        [entry setObject:reply forKey:@"reply"];
    }

    NSString *edit = [YTJson findString:@"updateCommentParams" in:node limit:20000];

    if ([edit length] == 0) {
        edit = [YTJson findString:@"updateReplyParams" in:node limit:20000];
    }

    if ([edit length] > 0) {
        [entry setObject:edit forKey:@"edit"];
    }
}

/**
 * Метка следующей страницы **перечня** комментариев.
 *
 * `continuationIn:` берёт первый попавшийся `continuationItemRenderer`
 * во всём дереве, и на второй странице это оказывается не конец списка,
 * а ветка ответов: такой же узел стоит у каждой ветки, и стоит он раньше
 * — сразу при своём комментарии. Перечень уходил в чужую ветку, и её
 * ответы вставали в него как обычные записи.
 *
 * Поэтому метку берём там, где она и лежит: последним звеном
 * привезённого куска — `continuationItems` у `appendContinuationItemsAction`
 * либо у `reloadContinuationItemsCommand`. Ветки внутри куска не
 * последние, и спутать их с концом списка больше нечем.
 */
+ (NSString *)listContinuationIn:(id)tree {
    NSMutableArray *actions = [NSMutableArray array];

    [actions addObjectsFromArray:[YTJson findAll:@"appendContinuationItemsAction"
                                              in:tree limit:200000]];
    [actions addObjectsFromArray:[YTJson findAll:@"reloadContinuationItemsCommand"
                                              in:tree limit:200000]];

    for (NSDictionary *action in actions) {
        NSArray *items = [YTJson arrayIn:action key:@"continuationItems"];

        if ([items count] == 0) {
            continue;
        }

        NSDictionary *tail = [YTJson objectAt:items index:[items count] - 1];
        NSDictionary *renderer = [YTJson objectIn:tail key:@"continuationItemRenderer"];

        if (renderer == nil) {
            continue;
        }

        NSDictionary *endpoint = [YTJson objectIn:renderer key:@"continuationEndpoint"];
        NSDictionary *command = [YTJson objectIn:endpoint key:@"continuationCommand"];

        NSString *token = [YTJson textIn:command key:@"token"];

        if ([token length] > 0) {
            return token;
        }
    }

    return nil;
}

/**
 * Продолжение ветки ответов.
 *
 * У перечня метка следующей страницы лежит в `continuationEndpoint`.
 * У ветки — нет: там это **кнопка** «Показать ещё ответы», и токен
 * спрятан в её команде, `button.buttonRenderer.command.continuationCommand`.
 * Прежний разбор такой формы не знал, ветка выглядела исчерпанной
 * на первой пачке, и у комментария с двадцатью шестью ответами
 * показывалось восемь.
 *
 * Спрашивается это только у страницы ветки. В перечне такие кнопки тоже
 * есть — своя у каждой ветки, — и взятая там она увела бы страницы всего
 * перечня в чужую ветку.
 */
+ (NSString *)repliesContinuationIn:(id)tree {
    NSArray *items = [YTJson findAll:@"continuationItemRenderer" in:tree limit:200000];

    for (NSDictionary *item in items) {
        NSDictionary *button = [YTJson objectIn:[YTJson objectIn:item key:@"button"]
                                            key:@"buttonRenderer"];
        NSDictionary *command =
            [YTJson objectIn:[YTJson objectIn:button key:@"command"]
                         key:@"continuationCommand"];

        NSString *token = [YTJson textIn:command key:@"token"];

        if ([token length] > 0) {
            return token;
        }
    }

    return nil;
}

/**
 * Старые формы метки — их кладёт TV-клиент.
 *
 * `nextContinuationData` и `reloadContinuationData`; последняя приезжает
 * в панели комментариев у вертикальных роликов. `continuationItemRenderer`
 * здесь намеренно не спрашивается: этим занят `listContinuationIn:`,
 * и только он отличает конец списка от ветки.
 */
+ (NSString *)legacyContinuationIn:(id)tree {
    NSDictionary *next = [YTJson findFirst:@"nextContinuationData" in:tree limit:200000];

    NSString *token = [YTJson textIn:next key:@"continuation"];

    if ([token length] > 0) {
        return token;
    }

    NSDictionary *reload = [YTJson findFirst:@"reloadContinuationData"
                                          in:tree limit:200000];

    return [YTJson textIn:reload key:@"continuation"];
}

+ (NSDictionary *)comments:(NSString *)token {
    return [self comments:token replies:NO];
}

+ (NSDictionary *)comments:(NSString *)token replies:(BOOL)replies {
    if ([token length] == 0) {
        return nil;
    }

    NSDictionary *json = [self postNext:
        [NSDictionary dictionaryWithObject:token forKey:@"continuation"]];

    if (json == nil) {
        return nil;
    }

    NSMutableArray *comments = [NSMutableArray array];
    /**
     * Потолок обхода поднят с семи тысяч до общего.
     *
     * Страница комментариев — четверть мегабайта, и словарей в ней много
     * больше семи тысяч: обход упирался в потолок, не дойдя до конца.
     * Терялись и последние комментарии, и ветки ответов — они лежат
     * в дереве позже самих записей.
     */
    NSArray *payloads = [YTJson findAll:@"commentEntityPayload" in:json limit:200000];

    /**
     * Ветки ответов: у какого комментария за ними идти.
     *
     * Сам текст ответов в ответе не лежит — там только метка продолжения
     * в `commentThreadRenderer.replies`. Связать её с записью нужно
     * по номеру комментария, и вот тут была загвоздка: **у
     * `commentViewModel` поля `commentId` нет вовсе**. Есть `commentKey` —
     * та же строка, но упакованная: base64 от куска protobuf, внутри
     * которого номер лежит открытым текстом. Прежний разбор спрашивал
     * несуществующее поле, всегда получал пустоту, и веток не было
     * ни у одного комментария.
     *
     * Поэтому ключ распаковываем и ищем номер в нём. Кодировка при
     * распаковке — latin-1: там двоичный protobuf, из которого нам нужна
     * только читаемая часть, а latin-1 переводит любые байты и не сорвётся.
     *
     * В UWP-версии веток нет вовсе; это добавка сверх оригинала.
     */
    NSMutableArray *threads = [NSMutableArray array];

    for (NSDictionary *thread in
         [YTJson findAll:@"commentThreadRenderer" in:json limit:200000]) {
        NSString *token = [self continuationIn:[YTJson objectIn:thread key:@"replies"]];

        if ([token length] == 0) {
            continue;
        }

        /**
         * Опознавательный ключ ветки — `toolbarStateKey`.
         *
         * Он же лежит и в записи с текстом (`properties.toolbarStateKey`),
         * и совпадает с ней слово в слово — проверено на живом ответе:
         * двадцать веток из двадцати. Номера комментария в самой ветке
         * нет: `commentViewModel` его не содержит, а прежний разбор
         * спрашивал именно его — оттого веток не было ни у одного
         * комментария.
         *
         * Сам `commentViewModel` при этом завёрнут дважды: внешний ключ
         * держит объект с таким же именем внутри. Поэтому ищем не первый
         * попавшийся, а тот, у которого ключ действительно есть.
         */
        NSString *key = nil;

        for (NSDictionary *view in [YTJson findAll:@"commentViewModel"
                                                in:thread limit:600]) {
            key = [YTJson textIn:view key:@"toolbarStateKey"];

            if ([key length] > 0) {
                break;
            }
        }

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];

        [entry setObject:token forKey:@"token"];

        if ([key length] > 0) { [entry setObject:key forKey:@"key"]; }

        [self collectCommentMarks:thread into:entry];

        [threads addObject:entry];
    }

    /**
     * Ветки бывают не у всех, а ответить и поправить можно и там, где
     * их нет. Поэтому метки собираются ещё и по самим записям — обход
     * идёт по `commentThreadRenderer` целиком, включая те, у которых
     * продолжения нет.
     */
    NSMutableArray *marks = [NSMutableArray array];

    for (NSDictionary *thread in
         [YTJson findAll:@"commentThreadRenderer" in:json limit:200000]) {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];

        for (NSDictionary *view in [YTJson findAll:@"commentViewModel"
                                                in:thread limit:600]) {
            NSString *key = [YTJson textIn:view key:@"toolbarStateKey"];

            if ([key length] > 0) {
                [entry setObject:key forKey:@"key"];

                break;
            }
        }

        [self collectCommentMarks:thread into:entry];

        [marks addObject:entry];
    }

    for (NSDictionary *payload in payloads) {
        NSDictionary *author = [YTJson objectIn:payload key:@"author"];
        NSDictionary *properties = [YTJson objectIn:payload key:@"properties"];

        NSString *text = [YTJson textIn:[YTJson objectIn:properties key:@"content"]
                                     key:@"content"];

        if ([text length] == 0) {
            continue;
        }

        NSString *name = [YTJson stringIn:author key:@"displayName" fallback:@""];

        // Имя приходит то с собачкой, то без — приводим к одному виду,
        // как в оригинале.
        if ([name length] > 0 && ![name hasPrefix:@"@"]) {
            name = [@"@" stringByAppendingString:name];
        }

        NSMutableDictionary *comment = [NSMutableDictionary dictionary];

        [comment setObject:name forKey:@"author"];
        [comment setObject:text forKey:@"text"];

        NSString *when = [YTJson textIn:properties key:@"publishedTime"];

        if (when != nil) { [comment setObject:when forKey:@"published"]; }

        /**
         * Кружок автора комментария лежит не там, где у прочих карточек,
         * и порядок поиска здесь взят из `ParseCommentEntityPayload`.
         *
         * Первым делом `author.avatarThumbnailUrl` — готовая ссылка на
         * тот самый кружок 88 точек. Именно её мы и упускали: разбор
         * начинался сразу с `avatar.image.sources[]`, а в ответах, где
         * `avatar` пуст или отдан отдельной записью, оттуда брать
         * нечего — кружков не было вовсе.
         *
         * Запасной ход — `sources[]`, и там берётся **самый крупный**
         * снимок, а не первый подходящий: порядок в массиве не обещан.
         */
        NSString *avatar = [YTJson textIn:author key:@"avatarThumbnailUrl"];

        if ([avatar length] == 0) {
            NSDictionary *avatarNode = [YTJson objectIn:payload key:@"avatar"];
            NSDictionary *image = [YTJson objectIn:avatarNode key:@"image"];

            NSInteger best = -1;

            for (NSDictionary *source in [YTJson arrayIn:image key:@"sources"]) {
                NSString *url = [YTJson textIn:source key:@"url"];

                if ([url length] == 0) {
                    continue;
                }

                NSInteger area = [YTJson intIn:source key:@"width"] *
                                 [YTJson intIn:source key:@"height"];

                if ([avatar length] == 0 || area >= best) {
                    avatar = url;
                    best = area;
                }
            }

            if ([avatar length] == 0) {
                // Совсем старая форма, на случай если сервер к ней вернётся.
                avatar = [YTJson thumbnailIn:avatarNode key:@"image" minWidth:88];
            }
        }

        if ([avatar length] > 0) { [comment setObject:avatar forKey:@"avatar"]; }

        /**
         * Ветка: сколько ответов и по какой метке за ними идти. Счётчик
         * лежит в `toolbar` — там же, где число оценок.
         */
        NSString *identifier = [YTJson textIn:properties key:@"toolbarStateKey"];
        NSString *token = nil;

        for (NSDictionary *thread in threads) {
            NSString *key = [thread objectForKey:@"key"];

            if ([identifier length] > 0 && [key isEqualToString:identifier]) {
                token = [thread objectForKey:@"token"];
                break;
            }
        }

        /**
         * Не нашлось по номеру — берём по месту.
         *
         * Ветки и записи сервер присылает в одном порядке, поэтому
         * n-я ветка принадлежит n-й записи. Это запасной ход на случай,
         * если упаковка ключа опять сменится: пусть лучше ветка окажется
         * не у того комментария, чем не окажется вовсе.
         */
        if ([token length] == 0 && [comments count] < [threads count]) {
            token = [[threads objectAtIndex:[comments count]] objectForKey:@"token"];
        }

        if ([token length] > 0) {
            NSString *count = [YTJson textIn:[YTJson objectIn:payload key:@"toolbar"]
                                         key:@"replyCount"];

            [comment setObject:token forKey:@"replies"];

            if ([count length] > 0) {
                [comment setObject:count forKey:@"replyCount"];
            }
        }

        /**
         * Метки ответа и правки — тем же способом, что и ветка: по
         * `toolbarStateKey`, а не нашлось — по месту в списке.
         *
         * Метка правки приходит только у своих комментариев: сервер
         * решает это сам и чужому её не даёт. По её наличию и решается,
         * показывать ли «Изменить», — своего списка «чьё это» у нас нет,
         * а гадать по имени канала ненадёжно.
         */
        NSDictionary *mark = nil;

        for (NSDictionary *candidate in marks) {
            NSString *key = [candidate objectForKey:@"key"];

            if ([identifier length] > 0 && [key isEqualToString:identifier]) {
                mark = candidate;
                break;
            }
        }

        if (mark == nil && [comments count] < [marks count]) {
            mark = [marks objectAtIndex:[comments count]];
        }

        NSString *replyParams = [mark objectForKey:@"reply"];
        NSString *editParams = [mark objectForKey:@"edit"];

        if ([replyParams length] > 0) {
            [comment setObject:replyParams forKey:@"replyParams"];
        }

        if ([editParams length] > 0) {
            [comment setObject:editParams forKey:@"editParams"];
        }

        [comments addObject:comment];

        // Столько же, сколько брала UWP-версия: дальше начинается лишняя
        // работа по замеру текста, а прокрутка всё равно доберётся
        // до следующей страницы.
        if ([comments count] >= 80) {
            break;
        }
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    [result setObject:comments forKey:@"items"];

    NSString *next = [self listContinuationIn:json];

    if ([next length] == 0 && replies) {
        next = [self repliesContinuationIn:json];
    }

    if ([next length] == 0) {
        next = [self legacyContinuationIn:json];
    }

    if (next != nil) { [result setObject:next forKey:@"continuation"]; }

    /**
     * Сколько записей получили метки — строкой в журнал.
     *
     * Метки эти добываются поиском по имени поля, а форма поверхности
     * меняется; молчаливый ноль означал бы «ответить нельзя никому»,
     * и отличить его от «поле переименовали» было бы нечем.
     */
    NSUInteger canReply = 0;
    NSUInteger canEdit = 0;

    for (NSDictionary *comment in comments) {
        if ([[comment objectForKey:@"replyParams"] length] > 0) { canReply++; }
        if ([[comment objectForKey:@"editParams"] length] > 0)  { canEdit++; }
    }

    NSLog(@"[YouTube/Комментарий] Записей %lu, ответить можно %lu, "
          @"поправить своих %lu",
          (unsigned long)[comments count],
          (unsigned long)canReply, (unsigned long)canEdit);

    /**
     * Метка «этому можно писать» — оттуда же, из этой самой страницы.
     *
     * Отдельного запроса за ней нет: `createCommentParams` кладётся
     * сервером в поле ввода над списком, и раз список мы уже привезли,
     * то и метка приехала вместе с ним. Её отсутствие — это ответ
     * «писать нельзя»: так бывает и у ролика с закрытыми комментариями,
     * и у любого, когда мы пришли без учётной записи.
     */
    NSString *create = [self createParamsIn:json];

    if (create != nil) {
        [result setObject:create forKey:@"createParams"];
    } else {
        // Молчаливое отсутствие метки увело в сторону на целый заход:
        // по журналу было не отличить «нельзя писать» от «нас не узнали».
        [self reportComposerShapeIn:json];
    }

    /**
     * Закрытые комментарии — отдельный случай, а не «их просто нет».
     *
     * Сервер об этом говорит сам и на языке человека: вместо списка
     * приезжает `messageRenderer` с надписью «Комментарии отключены».
     * Свою придумывать незачем — у сервера она и точнее, и переведена.
     *
     * Признак берём только при пустом списке: тот же рендерер попадается
     * и рядом с непустой лентой — например, с пометкой о сортировке.
     */
    if ([comments count] == 0) {
        NSString *said = [self refusalTextIn:json];

        if ([said length] > 0) {
            [result setObject:said forKey:@"disabledMessage"];

            NSLog(@"[YouTube/Комментарий] Сервер о списке: %@", said);
        }
    }

    return result;
}

#pragma mark Отправка комментария

/**
 * `createCommentParams` в ответе — метка, которой сервер разрешает писать.
 *
 * Лежит она в поле ввода над списком, по пути
 * `commentsHeaderRenderer.createRenderer.commentSimpleboxRenderer`,
 * и не в самом поле, а **в его кнопке отправки**. Строка непрозрачная
 * и подписана сервером: собрать её самим нельзя, только взять из ответа —
 * ровно как токены продолжения.
 *
 * Ищем обходом, а не по этому пути: разбор всего остального здесь устроен
 * так же, и место поля от клиента к клиенту разное.
 */
+ (NSString *)createParamsIn:(id)json {
    /**
     * Ищем строку, а не объект, и это главное.
     *
     * Первый заход искал метку через `findAll:`, а тот собирает **только
     * словари** — значение под ключом берётся, лишь когда это объект.
     * Метка же строка, и найтись так не могла ни при каком потолке.
     * Отладка ушла в сторону надолго: по журналу это выглядело как
     * «сервер не даёт писать», хотя сервер давал, а не читали мы.
     */
    NSString *params = [YTJson findString:@"createCommentParams"
                                       in:json limit:200000];

    if ([params length] > 0) {
        return params;
    }

    /**
     * Запасной путь: метка по форме, а не по имени.
     *
     * На случай, если YouTube переименует ключ. Приметы известны: метка
     * лежит в кнопке отправки поля ввода и записана строкой под ключом,
     * оканчивающимся на `Params`. Следящие метки (`trackingParams`,
     * `clickTrackingParams`) подходят под то же описание, но метками
     * записи не являются — их отбрасываем поимённо.
     */
    NSDictionary *box = [YTJson findFirst:@"commentSimpleboxRenderer"
                                       in:json limit:200000];

    id submit = [box objectForKey:@"submitButton"];

    NSString *guess = [self paramsLikeIn:submit depth:8];

    if (guess != nil) {
        NSLog(@"[YouTube/Комментарий] Метка взята по форме, длина %lu",
              (unsigned long)[guess length]);
    }

    return guess;
}

/**
 * Строка под ключом, оканчивающимся на `Params`, — обходом поддерева.
 *
 * Отдельным обходом, а не через `YTJson findAll:`, потому что там ищут
 * по точному имени, а нам имя как раз и неизвестно.
 */
+ (NSString *)paramsLikeIn:(id)node depth:(NSInteger)depth {
    if (depth <= 0 || node == nil) {
        return nil;
    }

    if ([node isKindOfClass:[NSArray class]]) {
        for (id item in node) {
            NSString *found = [self paramsLikeIn:item depth:depth - 1];

            if (found != nil) { return found; }
        }

        return nil;
    }

    if (![node isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    for (NSString *key in node) {
        id value = [node objectForKey:key];

        if ([key hasSuffix:@"Params"] &&
            ![key isEqualToString:@"trackingParams"] &&
            ![key isEqualToString:@"clickTrackingParams"] &&
            [value isKindOfClass:[NSString class]] &&
            [value length] > 0) {
            NSLog(@"[YouTube/Комментарий] Похоже на метку: %@ (%lu знаков)",
                  key, (unsigned long)[value length]);

            return value;
        }
    }

    // Вглубь — только после того, как весь этот уровень осмотрен.
    for (NSString *key in node) {
        NSString *found = [self paramsLikeIn:[node objectForKey:key]
                                       depth:depth - 1];

        if (found != nil) { return found; }
    }

    return nil;
}

/**
 * Что на самом деле лежит в кнопке отправки — строками в журнал.
 *
 * Нужно ровно тогда, когда метку не нашли ни по имени, ни по форме:
 * без этого следующий шаг снова был бы гаданием. Вывод ограничен
 * и по глубине, и по числу строк — журнал пишется на устройстве,
 * и вываливать в него четверть мегабайта незачем.
 */
+ (void)dumpNode:(id)node path:(NSString *)path depth:(NSInteger)depth
            into:(NSMutableArray *)lines {
    if (depth <= 0 || [lines count] >= 40) {
        return;
    }

    if ([node isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in node) {
            id value = [node objectForKey:key];

            NSString *here = [path length] > 0
                ? [NSString stringWithFormat:@"%@.%@", path, key] : key;

            if ([value isKindOfClass:[NSString class]]) {
                NSString *text = value;

                [lines addObject:[NSString stringWithFormat:@"%@ = %@%@", here,
                    [text length] > 40 ? [text substringToIndex:40] : text,
                    [text length] > 40 ? @"…" : @""]];
            } else if ([value isKindOfClass:[NSNumber class]]) {
                [lines addObject:[NSString stringWithFormat:@"%@ = %@", here, value]];
            } else {
                [self dumpNode:value path:here depth:depth - 1 into:lines];
            }

            if ([lines count] >= 40) { return; }
        }

        return;
    }

    if ([node isKindOfClass:[NSArray class]]) {
        NSUInteger index = 0;

        for (id item in node) {
            [self dumpNode:item
                      path:[NSString stringWithFormat:@"%@[%lu]", path,
                            (unsigned long)index++]
                     depth:depth - 1
                      into:lines];

            if ([lines count] >= 40) { return; }
        }
    }
}

/**
 * Почему метки не оказалось — по виду самого поля ввода.
 *
 * Различать надо два случая, снаружи неотличимые. У анонима поле
 * приходит **без кнопки отправки вовсе**: вместо неё
 * `prepareAccountEndpoint` с окном «Чтобы продолжить, нужно войти
 * в аккаунт». У вошедшего кнопка есть, и метка лежит в ней. То есть
 * отсутствие метки при живой сессии означает не «нельзя писать»,
 * а «сервер нас не узнал» — и лечится это входом, а не другим клиентом.
 *
 * Третий случай — поля нет совсем: у ролика закрыты комментарии либо
 * ответ пришёл не тот.
 */
+ (void)reportComposerShapeIn:(id)json {
    NSDictionary *box = [YTJson findFirst:@"commentSimpleboxRenderer"
                                       in:json limit:200000];

    if (box == nil) {
        NSLog(@"[YouTube/Комментарий] Поля ввода в ответе нет вовсе — "
              @"похоже, комментарии у ролика закрыты");

        return;
    }

    BOOL anonymous = [box objectForKey:@"prepareAccountEndpoint"] != nil;
    BOOL hasSubmit = [box objectForKey:@"submitButton"] != nil;

    NSLog(@"[YouTube/Комментарий] Поле ввода в ответе: кнопка отправки %@, "
          @"приглашение войти %@ → сервер считает нас %@",
          hasSubmit ? @"есть" : @"нет",
          anonymous ? @"есть" : @"нет",
          (anonymous && !hasSubmit) ? @"гостем" : @"вошедшими");

    if (anonymous) {
        NSLog(@"[YouTube/Комментарий] Куки сеанса: %@", [YTWebAuth sessionReport]);
    }

    /**
     * Кнопка есть, а метки в ней не нашлось — выкладываем кнопку целиком.
     *
     * Это тот случай, когда сервер нас узнал и писать даёт, а мы не поняли,
     * чем именно. Разбираться по имени ключа больше нечем: `createCommentParams`
     * в ней нет, и следующий шаг без этого вывода был бы очередной догадкой.
     */
    if (hasSubmit) {
        NSMutableArray *lines = [NSMutableArray array];

        [self dumpNode:[box objectForKey:@"submitButton"]
                  path:@"submitButton" depth:8 into:lines];

        NSLog(@"[YouTube/Комментарий] Кнопка отправки, %lu строк:",
              (unsigned long)[lines count]);

        for (NSString *line in lines) {
            NSLog(@"[YouTube/Комментарий]   %@", line);
        }
    }
}

/**
 * Метка по токену панели комментариев.
 *
 * Панель — это и есть то место, где поле ввода живёт: в странице ролика
 * его нет вовсе. Первый заход искал метку именно там, в ответе на
 * `{videoId}`, и не находил никогда — ошибка тем обиднее, что разведка
 * это показала заранее, а вывод в код не доехал.
 */
+ (NSString *)commentParamsForToken:(NSString *)token {
    if ([token length] == 0) {
        return nil;
    }

    NSDictionary *panel = [self postNext:
        [NSDictionary dictionaryWithObject:token forKey:@"continuation"]];

    NSString *params = [self createParamsIn:panel];

    NSLog(@"[YouTube/Комментарий] Метка из панели: %@",
          params != nil ? @"есть" : @"нет");

    if (params == nil) { [self reportComposerShapeIn:panel]; }

    return params;
}

/**
 * Метку токеном телевизора взять нельзя — проверено 24.08.2026.
 *
 * Мысль была такая: писать телевизором можно (узел `comment/create_comment`
 * про клиента не спрашивает), но саму метку кладут в поле ввода над
 * списком, а списка TV-клиенту не присылают вовсе. Значит, метку брали
 * веб-клиентом, подписанным сессией браузера, — и без браузерного входа
 * комментарии отваливались целиком, хотя вход по коду жив.
 *
 * Пробовали попросить панель **именем WEB**, а удостовериться токеном
 * телевизора. Сервер отвечает `400` — и не «мы вас не узнали», а отказом
 * разбирать запрос: пара «веб-клиент и токен телевизора» для него
 * не запрос вовсе. То же под MWEB и на всех трёх ступенях локали.
 *
 * Заход убран, а не оставлен выключенным: он стоил четырёх запросов
 * на каждое открытие комментариев и вдобавок сажал общую локаль —
 * лестница уступок принимала эти 400 за беду с регионом и уводила
 * приложение в `hl=en gl=US` до перезапуска.
 */

/**
 * Токен панели комментариев в ответе страницы ролика.
 *
 * Тот же разбор, что в `videoDetails:`: панель узнаётся по имени
 * `engagement-panel-comments-section`, у старых ответов —
 * `comment-item-section`.
 */
/**
 * Метка чата трансляции из ответа страницы ролика.
 *
 * Лежит она в `conversationBar.liveChatRenderer`, рядом с комментариями,
 * и приходит тем же запросом `next`, которым мы уже берём описание, —
 * второго захода не нужно. Проверено в браузере на живом эфире: путь
 * `contents.twoColumnWatchNextResults.conversationBar.liveChatRenderer`,
 * внутри `continuations[0].reloadContinuationData.continuation`.
 *
 * У записи такой панели нет вовсе, и это надёжный признак: чат бывает
 * только у трансляции и у её записи, пока чат не убрали.
 */
+ (NSString *)liveChatTokenIn:(id)json {
    NSDictionary *chat = [YTJson findFirst:@"liveChatRenderer" in:json limit:200000];

    if (chat == nil) {
        return nil;
    }

    for (NSDictionary *step in [YTJson arrayIn:chat key:@"continuations"]) {
        NSDictionary *reload = [YTJson findFirst:@"reloadContinuationData"
                                              in:step limit:2000];

        NSString *token = [YTJson stringIn:reload key:@"continuation"];

        if ([token length] > 0) {
            return token;
        }
    }

    return nil;
}

/**
 * Страница чата трансляции.
 *
 * Ответ разбираем в простые записи: имя, текст, кружок автора. Текст
 * склеиваем из `runs` — там вперемешку куски строк и смайлы; у смайла
 * в `emojiId` лежит сам символ, если он обычный, а у канальных —
 * ярлык вида `:name:`, и его мы и подставляем, картинки не тянем.
 *
 * Возвращаем ещё метку следующей страницы и задержку до неё: сервер сам
 * говорит, когда приходить снова (обычно десять секунд), и спорить с ним
 * незачем — чаще он всё равно не отдаст.
 */
/**
 * Склеивает текст сообщения из `runs`: куски строк и смайлы вперемешку.
 *
 * У обычного смайла в `emojiId` лежит сам символ, у канальных — длинный
 * ключ; вместо него подставляем ярлык вида `:name:`, картинки не тянем.
 */
+ (NSString *)liveChatTextIn:(NSDictionary *)said {
    NSMutableString *text = [NSMutableString string];

    for (NSDictionary *run in [YTJson arrayIn:[said objectForKey:@"message"] key:@"runs"]) {
        NSString *piece = [YTJson stringIn:run key:@"text"];

        if ([piece length] > 0) {
            [text appendString:piece];

            continue;
        }

        NSDictionary *emoji = [run objectForKey:@"emoji"];

        if (![emoji isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        NSString *sign = [YTJson stringIn:emoji key:@"emojiId"];

        if ([sign length] > 4) {
            NSArray *shortcuts = [YTJson arrayIn:emoji key:@"shortcuts"];

            sign = ([shortcuts count] > 0) ? [shortcuts objectAtIndex:0] : @"";
        }

        if ([sign length] > 0) {
            [text appendString:sign];
        }
    }

    return text;
}

+ (NSDictionary *)liveChat:(NSString *)token {
    if ([token length] == 0) {
        return nil;
    }

    NSDictionary *json = [self post:@"live_chat/get_live_chat"
                               body:[NSDictionary dictionaryWithObject:token
                                                                forKey:@"continuation"]
                             client:@"WEB"
                          authorize:NO
                                ttl:0];

    if (json == nil) {
        return nil;
    }

    NSDictionary *feed = [YTJson findFirst:@"liveChatContinuation" in:json limit:200000];

    if (feed == nil) {
        return nil;
    }

    NSMutableDictionary *page = [NSMutableDictionary dictionary];
    NSMutableArray *items = [NSMutableArray array];

    /**
     * Закреплённое сообщение приходит отдельным действием и живёт до тех
     * пор, пока автор его не снимет: своего повторения в следующих
     * страницах у него нет. Поэтому отдаём его наверх, а панель держит
     * последнее виденное.
     */
    for (NSDictionary *action in [YTJson arrayIn:feed key:@"actions"]) {
        NSDictionary *add = [YTJson findFirst:@"addBannerToLiveChatCommand"
                                           in:action limit:2000];

        if (add == nil) {
            continue;
        }

        NSDictionary *said = [YTJson findFirst:@"liveChatTextMessageRenderer"
                                            in:add limit:4000];

        if (said == nil) {
            continue;
        }

        NSString *who = [YTJson textIn:[said objectForKey:@"authorName"] key:@"simpleText"];
        NSString *what = [self liveChatTextIn:said];

        if ([what length] > 0) {
            [page setObject:[NSDictionary dictionaryWithObjectsAndKeys:
                (who != nil ? who : @""), @"author",
                what, @"text",
                nil] forKey:@"banner"];
        }
    }

    for (NSDictionary *action in [YTJson arrayIn:feed key:@"actions"]) {
        NSDictionary *add = [YTJson findFirst:@"addChatItemAction" in:action limit:2000];

        if (add == nil) {
            continue;
        }

        NSDictionary *said = [YTJson findFirst:@"liveChatTextMessageRenderer"
                                            in:add limit:2000];

        if (said == nil) {
            continue;
        }

        NSString *author = [YTJson textIn:[said objectForKey:@"authorName"] key:@"simpleText"];

        if ([author length] == 0) {
            author = [YTJson textIn:said key:@"authorName"];
        }

        NSString *text = [self liveChatTextIn:said];

        if ([text length] == 0) {
            continue;
        }

        NSString *avatar = nil;

        NSArray *pictures = [YTJson arrayIn:[said objectForKey:@"authorPhoto"]
                                        key:@"thumbnails"];

        if ([pictures count] > 0) {
            avatar = [YTJson stringIn:[pictures objectAtIndex:0] key:@"url"];
        }

        NSMutableDictionary *item = [NSMutableDictionary dictionary];

        [item setObject:(author != nil ? author : @"") forKey:@"author"];
        [item setObject:text forKey:@"text"];

        // Метка для списка: у чата своя, узкая раскладка строки.
        [item setObject:[NSNumber numberWithBool:YES] forKey:@"isChat"];

        if ([avatar length] > 0) {
            [item setObject:avatar forKey:@"avatar"];
        }

        NSString *stamp = [YTJson stringIn:said key:@"id"];

        if ([stamp length] > 0) {
            [item setObject:stamp forKey:@"id"];
        }

        [items addObject:item];
    }

    [page setObject:items forKey:@"items"];

    NSTimeInterval wait = 10.0;

    for (NSDictionary *step in [YTJson arrayIn:feed key:@"continuations"]) {
        NSDictionary *data = [YTJson findFirst:@"invalidationContinuationData"
                                            in:step limit:2000];

        if (data == nil) {
            data = [YTJson findFirst:@"timedContinuationData" in:step limit:2000];
        }

        if (data == nil) {
            data = [YTJson findFirst:@"reloadContinuationData" in:step limit:2000];
        }

        NSString *next = [YTJson stringIn:data key:@"continuation"];

        if ([next length] == 0) {
            continue;
        }

        [page setObject:next forKey:@"token"];

        id timeout = [data objectForKey:@"timeoutMs"];

        if ([timeout respondsToSelector:@selector(doubleValue)]) {
            NSTimeInterval said = [timeout doubleValue] / 1000.0;

            if (said > 1.0) {
                wait = MIN(30.0, said);
            }
        }

        break;
    }

    [page setObject:[NSNumber numberWithDouble:wait] forKey:@"wait"];

    return page;
}

/**
 * Достаёт объект JSON, лежащий в разметке после названия.
 *
 * Считаем скобки, а не ищем закрывающую: внутри страницы этот объект
 * идёт одной строкой в полмегабайта, и в нём полно и тех и других.
 * Кавычки при счёте пропускаем целиком — иначе скобка внутри чьего-то
 * ника оборвала бы разбор, — а экранированную кавычку не принимаем
 * за конец строки.
 */
+ (NSDictionary *)jsonAfterMarker:(NSString *)marker in:(NSString *)page {
    NSRange found = [page rangeOfString:marker];

    if (found.location == NSNotFound) {
        return nil;
    }

    NSUInteger at = found.location + found.length;
    NSUInteger length = [page length];

    // От названия до самой скобки идут кавычки, скобки и знак равенства.
    while (at < length && [page characterAtIndex:at] != '{') {
        unichar sign = [page characterAtIndex:at];

        if (sign == ';' || sign == '<') {
            return nil;
        }

        at++;
    }

    if (at >= length) {
        return nil;
    }

    NSUInteger start = at;
    NSInteger depth = 0;
    BOOL inString = NO;
    BOOL escaped = NO;

    for (NSUInteger i = start; i < length; i++) {
        unichar sign = [page characterAtIndex:i];

        if (inString) {
            if (escaped) {
                escaped = NO;
            } else if (sign == 0x5c) {
                escaped = YES;
            } else if (sign == '"') {
                inString = NO;
            }

            continue;
        }

        if (sign == '"') {
            inString = YES;
        } else if (sign == '{') {
            depth++;
        } else if (sign == '}') {
            depth--;

            if (depth == 0) {
                NSString *slice = [page substringWithRange:
                    NSMakeRange(start, i - start + 1)];

                return [YTJson parse:[slice dataUsingEncoding:NSUTF8StringEncoding]];
            }
        }
    }

    return nil;
}

/**
 * Метки фильтров чата: «все сообщения» и «интересные».
 *
 * Берутся не через InnerTube, а со страницы самого чата, и это не каприз.
 * В ответе `next` метки фильтров лежат тоже, но урезанные — сорок четыре
 * знака, без опознания трансляции, — и сервер отвечает на них отказом
 * `400 INVALID_ARGUMENT`. Проверено обе: и «Чат», и «Интересные». На
 * странице `/live_chat` те же фильтры несут полные метки в пятьсот с
 * лишним знаков, и с ними `get_live_chat` отвечает как надо.
 *
 * Порядок у подменю всегда один: сперва «интересные», потом «все».
 * Названия берём свои, а не серверные: второй фильтр сервер зовёт просто
 * «Чат», что рядом с заголовком «Чат» ничего не объясняет.
 */
+ (NSArray *)liveChatFiltersForVideo:(NSString *)videoId {
    if ([videoId length] == 0) {
        return nil;
    }

    NSString *address = [NSString stringWithFormat:
        @"https://www.youtube.com/live_chat?v=%@&is_popout=1", videoId];

    NSMutableURLRequest *request =
        YTRequest(address, NSURLRequestUseProtocolCachePolicy, 20.0);

    if (request == nil) {
        return nil;
    }

    YTHttpResponse *response = [YTHttp send:request bodyLimit:(4 * 1024 * 1024)];

    if ([response error] != nil || [[response body] length] == 0) {
        return nil;
    }

    NSString *page = [[NSString alloc] initWithData:[response body]
                                           encoding:NSUTF8StringEncoding];

    if ([page length] == 0) {
        return nil;
    }

    NSDictionary *data = [self jsonAfterMarker:@"ytInitialData" in:page];

    if (data == nil) {
        return nil;
    }

    NSDictionary *menu = [YTJson findFirst:@"sortFilterSubMenuRenderer"
                                        in:data limit:200000];

    NSArray *items = [YTJson arrayIn:menu key:@"subMenuItems"];

    if ([items count] < 2) {
        return nil;
    }

    NSMutableArray *filters = [NSMutableArray array];

    for (NSDictionary *item in items) {
        NSDictionary *reload = [YTJson findFirst:@"reloadContinuationData"
                                              in:item limit:2000];

        NSString *token = [YTJson stringIn:reload key:@"continuation"];

        if ([token length] == 0) {
            continue;
        }

        [filters addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            token, @"token",
            ([YTJson stringIn:item key:@"title"] ?: @""), @"serverTitle",
            nil]];
    }

    return ([filters count] >= 2) ? filters : nil;
}

+ (NSString *)commentsTokenIn:(id)json {
    for (NSDictionary *panel in
            [YTJson findAll:@"engagementPanelSectionListRenderer" in:json limit:200000]) {
        NSString *identifier = [YTJson stringIn:panel key:@"panelIdentifier"];

        if ([identifier length] == 0) {
            identifier = [YTJson stringIn:panel key:@"targetId"];
        }

        if (![identifier isEqualToString:@"engagement-panel-comments-section"] &&
            ![identifier isEqualToString:@"comment-item-section"]) {
            continue;
        }

        NSDictionary *command = [YTJson findFirst:@"continuationCommand"
                                               in:panel limit:20000];

        NSString *token = [YTJson textIn:command key:@"token"];

        if ([token length] > 0) {
            return token;
        }
    }

    return nil;
}

/**
 * Метка для ролика, когда токена панели под рукой нет.
 *
 * Заходов два, и оба обязательны: сперва страница ролика — за токеном
 * панели, затем сама панель — за меткой. Одним запросом не выйдет,
 * поле ввода в странице не лежит.
 *
 * nil означает, что писать не дают вовсе.
 */
+ (NSString *)commentParamsForVideo:(NSString *)videoId {
    if ([videoId length] == 0) {
        return nil;
    }

    NSDictionary *page = [self postNext:
        [NSDictionary dictionaryWithObject:videoId forKey:@"videoId"]];

    NSString *token = [self commentsTokenIn:page];

    if ([token length] == 0) {
        NSLog(@"[YouTube/Комментарий] Панели комментариев у ролика нет");

        return nil;
    }

    return [self commentParamsForToken:token];
}

/**
 * Не отказ ли это, присланный под видом успеха.
 *
 * У InnerTube ответ на запись бывает удачным по коду и неудачным
 * по существу: приходит 200 с `actionResult`, где написано `STATUS_FAILED`,
 * либо с одним лишь `openPopupAction` — окном «войдите» или «не получилось».
 * Считать успехом всякий непустой ответ значило бы показывать человеку
 * «отправлено» там, где ничего не отправлено.
 *
 * Признаком успеха берётся то, что сервер присылает при удаче: либо прямо
 * `STATUS_SUCCEEDED`, либо готовая запись нового комментария, которую
 * клиент должен вставить в список.
 */
+ (BOOL)commentAccepted:(NSDictionary *)json {
    if (json == nil) {
        return NO;
    }

    for (NSDictionary *result in [YTJson findAll:@"actionResult" in:json limit:20000]) {
        NSString *status = [YTJson stringIn:result key:@"status"];

        if ([status isEqualToString:@"STATUS_SUCCEEDED"]) {
            return YES;
        }

        if ([status length] > 0) {
            NSLog(@"[YouTube/Комментарий] Сервер о записи: %@", status);

            return NO;
        }
    }

    // Ответ без `actionResult`: удачу выдаёт сама вставляемая запись.
    if ([YTJson findFirst:@"commentEntityPayload" in:json limit:20000] != nil ||
        [YTJson findFirst:@"createCommentAction" in:json limit:20000] != nil) {
        return YES;
    }

    return NO;
}

/**
 * Что сервер сказал словами, отказывая.
 *
 * У InnerTube отказ на запись почти всегда несёт готовую надпись для
 * человека — ту самую, что официальный клиент показал бы всплывающим
 * окном: «комментарии отключены», «войдите в аккаунт», «слишком часто».
 * Она куда точнее любой нашей догадки о причине, и её незачем
 * пересказывать своими словами — надо просто показать.
 *
 * Ищем по всему дереву: окно приезжает то `notificationTextRenderer`,
 * то `alertRenderer`, то диалогом с заголовком, и место у них разное.
 */
+ (NSString *)refusalTextIn:(NSDictionary *)json {
    if (json == nil) {
        return nil;
    }

    NSArray *renderers = [NSArray arrayWithObjects:
        @"notificationTextRenderer", @"alertRenderer", @"messageRenderer",
        @"confirmDialogRenderer", @"backstagePostDialogRenderer", nil];

    NSArray *fields = [NSArray arrayWithObjects:
        @"successResponseText", @"errorMessage", @"text", @"title",
        @"message", @"dialogMessage", nil];

    for (NSDictionary *node in [YTJson findAllOfAny:renderers in:json limit:20000]) {
        for (NSString *field in fields) {
            NSString *said = [YTJson renderedText:node key:field];

            if ([said length] > 0) {
                return said;
            }
        }
    }

    return nil;
}

+ (BOOL)postComment:(NSString *)text
              video:(NSString *)videoId
             params:(NSString *)params {
    return [self postComment:text video:videoId params:params
                       token:nil reason:NULL];
}

+ (BOOL)postComment:(NSString *)text
              video:(NSString *)videoId
             params:(NSString *)params
             reason:(NSString **)reason {
    return [self postComment:text video:videoId params:params
                       token:nil reason:reason];
}

+ (BOOL)postComment:(NSString *)text
              video:(NSString *)videoId
             params:(NSString *)params
              token:(NSString *)commentsToken
             reason:(NSString **)reason {
    if (reason != NULL) { *reason = nil; }

    if ([text length] == 0 || [videoId length] == 0) {
        return NO;
    }

    if (![YTAuth isSignedIn] && ![YTWebAuth isSignedIn]) {
        NSLog(@"[YouTube/Комментарий] Не вошли — писать нечем");

        if (reason != NULL) { *reason = YTLoc(@"Не выполнен вход."); }

        return NO;
    }

    /**
     * Метка: готовая, затем по токену панели, и лишь затем через ролик.
     *
     * Порядок — по числу запросов: ноль, один, два. Прежде здесь всегда
     * шёл путь «через ролик», и на живом устройстве это выливалось
     * в три запроса подряд за одной и той же меткой, потому что экран
     * к тому времени уже спрашивал её сам.
     */
    NSString *create = params;

    if ([create length] == 0 && [commentsToken length] > 0) {
        create = [self commentParamsForToken:commentsToken];
    }

    if ([create length] == 0 && [commentsToken length] == 0) {
        create = [self commentParamsForVideo:videoId];
    }

    if ([create length] == 0) {
        NSLog(@"[YouTube/Комментарий] Метки нет — сервер писать не даёт");

        if (reason != NULL) {
            *reason = YTLoc(@"YouTube не дал разрешения на запись: "
                            @"у этого ролика комментарии могут быть отключены.");
        }

        return NO;
    }

    return [self sendComment:text
                          to:@"comment/create_comment"
                       field:@"createCommentParams"
                      params:create
                        note:videoId
                      reason:reason];
}

/**
 * Общая отправка: написать, ответить, поправить.
 *
 * Все три — один и тот же разговор с сервером и отличаются лишь узлом
 * и именем поля с меткой. Перебор клиентов, разбор успеха и разбор
 * отказа у них общие, и разводить их по трём почти одинаковым кускам
 * значило бы чинить потом каждый по отдельности.
 */
+ (BOOL)sendComment:(NSString *)text
                 to:(NSString *)endpoint
              field:(NSString *)field
             params:(NSString *)params
               note:(NSString *)note
             reason:(NSString **)reason {
    if ([text length] == 0 || [params length] == 0) {
        return NO;
    }

    NSMutableDictionary *body = [NSMutableDictionary dictionary];

    [body setObject:text forKey:@"commentText"];
    [body setObject:params forKey:field];

    /**
     * TV-клиент идёт первым — и это тот самый опыт, ради которого всё.
     *
     * Официально телевизор комментировать не умеет: YouTube на нём
     * показывает «оставьте комментарий с телефона или сайта», и панели
     * комментариев в ответе TV-клиента действительно нет — проверено
     * запросом, её там ноль. Но узел `comment/create_comment` про клиента
     * ничего не спрашивает: он проверяет метку и учётную запись, а метка
     * привязана к ролику, не к тому, кто её показал.
     *
     * Поэтому пробуем: метку берём где дают, а пишем токеном TV-клиента.
     * Откажет — за ним MWEB и WEB, которых подписывает браузерная сессия;
     * порядок тот же, что у оценки, и по той же причине.
     */
    NSArray *clients = [NSArray arrayWithObjects:@"TVHTML5", @"MWEB", @"WEB", nil];

    for (NSString *client in clients) {
        BOOL tv = [client isEqualToString:@"TVHTML5"];

        // TV представляется токеном, веб-семейство — сессией браузера;
        // подпись сессией ставит сам `post:`, когда `authorize` снят.
        if (tv && ![YTAuth isSignedIn]) { continue; }
        if (!tv && ![YTWebAuth isSignedIn]) { continue; }

        NSDictionary *json = [self post:endpoint
                                   body:body
                                 client:client
                              authorize:tv
                                    ttl:0];

        if ([self commentAccepted:json]) {
            NSLog(@"[YouTube/Комментарий] %@: принят к %@ клиентом %@",
                  endpoint, note, client);

            return YES;
        }

        /**
         * Причину запоминаем от **последнего** говорившего.
         *
         * Первым идёт TV-клиент, и его отказ ожидаем — показывать человеку
         * именно его значило бы объяснять беду тем, что мы же и затеяли
         * ради опыта. Важно то, чем кончил последний, кому писать
         * полагается по-настоящему.
         */
        NSString *said = [self refusalTextIn:json];

        if (reason != NULL && [said length] > 0) { *reason = said; }

        NSLog(@"[YouTube/Комментарий] %@ отказал (%@)%@", client,
              json != nil ? @"ответ без успеха" : @"нет ответа",
              [said length] > 0
                  ? [NSString stringWithFormat:@": %@", said] : @"");

        /**
         * Отказ веб-клиенту — повод пересчитать куки сеанса.
         *
         * Одной `SAPISID` довольно, чтобы счесть вход состоявшимся
         * и собрать подпись, но серверу нужен весь набор: неполный он
         * встречает так же, как если бы входа не было вовсе. Снаружи это
         * неотличимо от «телевизору не дают», а различие решающее —
         * лечится оно повторным входом, а не другим клиентом.
         */
        if (!tv) {
            NSLog(@"[YouTube/Комментарий] Куки сеанса: %@",
                  [YTWebAuth sessionReport]);
        }
    }

    return NO;
}

+ (BOOL)replyComment:(NSString *)text
              params:(NSString *)params
              reason:(NSString **)reason {
    return [self sendComment:text
                          to:@"comment/create_comment_reply"
                       field:@"createReplyParams"
                      params:params
                        note:@"ответ"
                      reason:reason];
}

+ (BOOL)editComment:(NSString *)text
             params:(NSString *)params
             reason:(NSString **)reason {
    return [self sendComment:text
                          to:@"comment/update_comment"
                       field:@"updateCommentParams"
                      params:params
                        note:@"правка"
                      reason:reason];
}

#pragma mark Потоки

/**
 * Есть ли в ответе потоки. Порт `PlayerJsonHasStreams`.
 *
 * Проверяется именно наличие непустых `formats`/`adaptiveFormats`, а не
 * `playabilityStatus`: при срабатывании анти-бота статус бывает и `OK`,
 * а `streamingData` при этом пустой.
 */
/**
 * Есть ли в ответе **пригодные** потоки, а не просто перечень дорожек.
 *
 * Проверять число дорожек мало, и это выяснилось на живом ответе.
 * WEB-клиент вошедшего отвечает `status: OK` и присылает три десятка
 * `adaptiveFormats` — **без единого адреса**: там только размеры, куски
 * и длительность, а само видео он ждёт через `serverAbrStreamingUrl`,
 * то есть по своему протоколу подачи. Склеенная дорожка (itag 18) адрес
 * тоже не содержит: вместо него `signatureCipher`, который расшифровывает
 * плеер YouTube своим кодом.
 *
 * Для нас и то и другое — пустышка: демуксеру нужен обычный адрес, по
 * которому можно запросить диапазон байтов. Поэтому годным считается
 * ответ, где есть хотя бы одна дорожка с готовым `url`.
 *
 * Толк от строгости прямой: цепочка клиентов идёт дальше вместо того,
 * чтобы остановиться на ответе, который выглядит удачным и ничего
 * не играет.
 */
+ (BOOL)playerHasStreams:(NSDictionary *)json {
    NSDictionary *streaming = [YTJson objectIn:json key:@"streamingData"];

    if (streaming == nil) {
        return NO;
    }

    NSArray *lists = [NSArray arrayWithObjects:
        [YTJson arrayIn:streaming key:@"adaptiveFormats"],
        [YTJson arrayIn:streaming key:@"formats"],
        nil];

    for (NSArray *list in lists) {
        for (NSDictionary *format in list) {
            if ([[YTJson textIn:format key:@"url"] length] > 0) {
                return YES;
            }
        }
    }

    return NO;
}

/**
 * Есть ли в ответе **раздельные** дорожки с адресами.
 *
 * Отличать их от склеенных приходится потому, что склеенная — это
 * единственный формат 18: 360p, звук внутри, и никакого выбора качества.
 * Ответ, где есть только она, формально «с потоками», и цепочка
 * останавливалась на нём, не дойдя до клиента, у которого дорожки
 * настоящие.
 */
+ (BOOL)playerHasAdaptiveStreams:(NSDictionary *)json {
    NSDictionary *streaming = [YTJson objectIn:json key:@"streamingData"];

    for (NSDictionary *format in [YTJson arrayIn:streaming key:@"adaptiveFormats"]) {
        if ([[YTJson textIn:format key:@"url"] length] > 0) {
            return YES;
        }
    }

    return NO;
}

/**
 * Что на самом деле лежит в ответе — строка для журнала.
 *
 * Отказ от `/player` виден сразу, а вот удачный ответ без единого
 * играбельного адреса выглядит в журнале точно так же, как рабочий.
 * Различать надо три случая: адреса готовы; адреса зашифрованы
 * (`signatureCipher` — их надо расшифровывать кодом плеера); адресов
 * нет вовсе и подача идёт через SABR.
 */
+ (NSString *)streamNote:(NSDictionary *)json {
    NSDictionary *streaming = [YTJson objectIn:json key:@"streamingData"];

    if (streaming == nil) {
        return @"без потоков";
    }

    NSUInteger ready = 0;
    NSUInteger sealed = 0;
    NSUInteger total = 0;

    NSArray *lists = [NSArray arrayWithObjects:
        [YTJson arrayIn:streaming key:@"adaptiveFormats"],
        [YTJson arrayIn:streaming key:@"formats"],
        nil];

    for (NSArray *list in lists) {
        for (NSDictionary *format in list) {
            total++;

            if ([[YTJson textIn:format key:@"url"] length] > 0) {
                ready++;
            } else if ([[YTJson textIn:format key:@"signatureCipher"] length] > 0) {
                sealed++;
            }
        }
    }

    return [NSString stringWithFormat:@"дорожек %lu: готовых %lu, шифрованных %lu%@",
        (unsigned long)total, (unsigned long)ready, (unsigned long)sealed,
        [YTJson textIn:streaming key:@"serverAbrStreamingUrl"] != nil ? @", подача SABR" : @""];
}

+ (NSString *)sessionBinding {
    @synchronized ([YTApi class]) {
        if ([YTSessionDatasyncId length] > 0) {
            return YTSessionDatasyncId;
        }

        if ([YTSessionVisitorData length] > 0) {
            return YTSessionVisitorData;
        }
    }

    return nil;
}

+ (BOOL)isBotGate:(NSDictionary *)playerResponse {
    NSDictionary *status = [YTJson objectIn:playerResponse key:@"playabilityStatus"];

    return [[YTJson stringIn:status key:@"status" fallback:@""]
        isEqualToString:@"LOGIN_REQUIRED"];
}

+ (NSString *)playabilityReason:(NSDictionary *)json {
    if (json == nil) {
        return @"пустой ответ";
    }

    NSDictionary *status = [YTJson objectIn:json key:@"playabilityStatus"];

    if (status == nil) {
        return @"нет streamingData";
    }

    NSString *state = [YTJson stringIn:status key:@"status" fallback:@"?"];
    NSString *reason = [YTJson textIn:status key:@"reason"];

    return reason != nil
        ? [NSString stringWithFormat:@"%@: %@", state, reason]
        : state;
}

/**
 * Когда начнётся запланированная трансляция.
 *
 * Ролик, объявленный заранее, отвечает на `/player` без потоков вовсе —
 * их ещё нет, — и снаружи это неотличимо от поломки: «Не удалось
 * получить поток». Отличить помогает время начала, и лежит оно в двух
 * разных местах, смотря какой клиент спрашивал.
 *
 * Первое — заставка ожидания в `playabilityStatus`: там время дано
 * числом секунд, как оно есть. Второе — сведения о трансляции
 * в `microformat`, где время записано строкой вида
 * `2026-09-09T20:00:00+00:00`. Берём первое попавшееся.
 */
+ (NSTimeInterval)scheduledStartIn:(NSDictionary *)json {
    NSDictionary *slate = [YTJson objectIn:
        [YTJson objectIn:
            [YTJson objectIn:
                [YTJson objectIn:
                    [YTJson objectIn:json key:@"playabilityStatus"]
                    key:@"liveStreamability"]
                key:@"liveStreamabilityRenderer"]
            key:@"offlineSlate"]
        key:@"liveStreamOfflineSlateRenderer"];

    NSString *seconds = [YTJson stringIn:slate key:@"scheduledStartTime"];

    if ([seconds length] > 0) {
        NSTimeInterval when = [seconds doubleValue];

        if (when > 0) {
            return when;
        }
    }

    NSDictionary *details = [YTJson objectIn:
        [YTJson objectIn:
            [YTJson objectIn:json key:@"microformat"]
            key:@"playerMicroformatRenderer"]
        key:@"liveBroadcastDetails"];

    NSString *stamp = [YTJson stringIn:details key:@"startTimestamp"];

    if ([stamp length] >= 19) {
        /**
         * Разбираем сами, без `NSDateFormatter`.
         *
         * Формат здесь всегда один и тот же — ISO 8601 с часовым поясом,
         * — а разбор через `NSDateFormatter` на iOS 5 требует правильной
         * локали, иначе молча возвращает пустоту у людей с нелатинским
         * календарём. Своими руками надёжнее и короче.
         */
        NSInteger year = [[stamp substringWithRange:NSMakeRange(0, 4)] integerValue];
        NSInteger month = [[stamp substringWithRange:NSMakeRange(5, 2)] integerValue];
        NSInteger day = [[stamp substringWithRange:NSMakeRange(8, 2)] integerValue];
        NSInteger hour = [[stamp substringWithRange:NSMakeRange(11, 2)] integerValue];
        NSInteger minute = [[stamp substringWithRange:NSMakeRange(14, 2)] integerValue];
        NSInteger second = [[stamp substringWithRange:NSMakeRange(17, 2)] integerValue];

        NSDateComponents *parts = [[NSDateComponents alloc] init];

        [parts setYear:year];
        [parts setMonth:month];
        [parts setDay:day];
        [parts setHour:hour];
        [parts setMinute:minute];
        [parts setSecond:second];

        NSCalendar *calendar =
            [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];

        [calendar setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];

        NSDate *date = [calendar dateFromComponents:parts];

        if (date != nil) {
            NSTimeInterval when = [date timeIntervalSince1970];

            // Пояс в конце строки: `Z` — уже мировое, иначе `+03:00`.
            NSString *zone = [stamp substringFromIndex:19];

            if ([zone length] >= 6 &&
                ([zone characterAtIndex:0] == '+' || [zone characterAtIndex:0] == '-')) {
                NSInteger zoneHour = [[zone substringWithRange:NSMakeRange(1, 2)] integerValue];
                NSInteger zoneMinute = [[zone substringWithRange:NSMakeRange(4, 2)] integerValue];
                NSInteger shift = zoneHour * 3600 + zoneMinute * 60;

                when += ([zone characterAtIndex:0] == '+') ? -shift : shift;
            }

            return when;
        }
    }

    return 0;
}

/**
 * `visitorData` для запроса потоков.
 *
 * Порт `GetSessionVisitorDataAsync`. Значение выдаёт сам сервер, и
 * ANDROID_VR без него упирается в анти-бота («Sign in to confirm you're
 * not a bot»). Берётся оно из `responseContext` любого ответа youtubei;
 * если своего ещё нет — делается один лёгкий анонимный запрос WEB `/player`
 * ровно ради него, а в самом крайнем случае идёт вшитая строка.
 *
 * Замок общий, чтобы десяток экранов не пошёл добывать его разом.
 */
+ (NSString *)sessionVisitorData:(NSString *)videoId {
    @synchronized ([YTApi class]) {
        if ([YTSessionVisitorData length] > 0) {
            return YTSessionVisitorData;
        }

        NSString *fetched = [self fetchFreshVisitorData:videoId];

        if ([fetched length] > 0) {
            YTSessionVisitorData = [fetched copy];
            return YTSessionVisitorData;
        }
    }

    // Раскодируем: в Config.cs строка лежит экранированной, а в заголовок
    // и в тело она должна уйти обычной.
    NSString *decoded = [YTFallbackVisitorData
        stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

    return decoded ?: YTFallbackVisitorData;
}

+ (void)invalidateVisitorData {
    @synchronized ([YTApi class]) {
        YTSessionVisitorData = nil;
    }
}

/**
 * Первичный `/player` — клиентом IOS, как `BuildPlayerPayload`.
 *
 * В оригинале это самый первый запрос страницы ролика, и делается он
 * не ради потоков: из его `responseContext` берётся `visitorData`, с которым
 * следом идёт ANDROID_VR. Без этого шага ANDROID_VR упирается в анти-бота
 * («Sign in to confirm you're not a bot»), а свежий `visitorData` от
 * анонимного WEB стену не снимает — там об этом сказано прямо, в комментарии
 * перед `CaptureVisitorData`.
 *
 * Заодно в ответе лежит `hlsManifestUrl`: `PostInnertubeAsync` не зря шлёт
 * с ним iOS-овский User-Agent — «for best chance of getting hlsManifestUrl».
 * Он нужен запасным путём, если потоков не отдадут вовсе.
 */
+ (NSDictionary *)iosPlayerResponse:(NSString *)videoId {
    return [self iosPlayerResponse:videoId authorize:NO];
}

/**
 * `/player` под IOS-клиентом; `authorize` — приложить ли к запросу
 * учётную запись.
 *
 * Без неё запрос уходит гостем, и стену «подтвердите, что вы не бот»
 * он проходит через раз: когда проходит — отдаёт два с лишним десятка
 * настоящих раздельных дорожек, вплоть до 2160p, без шифра и без `n`.
 * Это лучшее, что нам вообще отвечают, и терять его из-за случайности
 * обидно.
 *
 * Поэтому вторым заходом тот же запрос идёт с токеном и `visitorData`
 * сеанса. Стену держат для гостей, а за токеном стоит настоящий вход —
 * тот самый, с которым проходят TVHTML5 и WEB.
 */
+ (NSDictionary *)iosPlayerResponse:(NSString *)videoId authorize:(BOOL)authorize {
    if ([videoId length] == 0) {
        return nil;
    }

    NSMutableDictionary *client = [NSMutableDictionary dictionary];

    [client setObject:@"IOS" forKey:@"clientName"];
    [client setObject:YTIosVersion forKey:@"clientVersion"];
    [client setObject:@"Apple" forKey:@"deviceMake"];
    [client setObject:@"iPhone16,2" forKey:@"deviceModel"];
    [client setObject:@"iOS" forKey:@"osName"];
    [client setObject:@"18.0" forKey:@"osVersion"];
    [client setObject:[self hl] forKey:@"hl"];
    [client setObject:[self gl] forKey:@"gl"];

    NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        YTIosUserAgent, @"User-Agent",
        @"5", @"X-YouTube-Client-Name",
        YTIosVersion, @"X-YouTube-Client-Version",
        nil];

    if (authorize) {
        NSString *token = [YTAuth accessToken];

        if ([token length] == 0) {
            return nil;
        }

        [headers setObject:[@"Bearer " stringByAppendingString:token]
                    forKey:@"Authorization"];

        NSString *visitorData = [self sessionVisitorData:videoId];

        if ([visitorData length] > 0) {
            [client setObject:visitorData forKey:@"visitorData"];
            [headers setObject:visitorData forKey:@"X-Goog-Visitor-Id"];
        }
    }

    NSDictionary *payload = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSDictionary dictionaryWithObject:client forKey:@"client"], @"context",
        videoId, @"videoId",
        [NSNumber numberWithBool:YES], @"contentCheckOk",
        [NSNumber numberWithBool:YES], @"racyCheckOk",
        nil];

    return [self postPlayerPayload:payload headers:headers];
}

/** Запоминает `visitorData` из любого ответа youtubei — `CaptureVisitorData`. */
+ (void)captureVisitorData:(NSDictionary *)json {
    NSDictionary *context = [YTJson objectIn:json key:@"responseContext"];

    /**
     * Заодно запоминаем признак учётной записи. Он лежит рядом,
     * в `mainAppWebResponseContext`, и приходит только у вошедшего;
     * хвост из палок в нём лишний — привязка идёт по самому номеру.
     */
    NSString *datasync = [YTJson textIn:
        [YTJson objectIn:context key:@"mainAppWebResponseContext"] key:@"datasyncId"];

    if ([datasync length] > 0) {
        NSRange bar = [datasync rangeOfString:@"|"];

        if (bar.location != NSNotFound) {
            datasync = [datasync substringToIndex:bar.location];
        }

        @synchronized ([YTApi class]) {
            if (![datasync isEqualToString:YTSessionDatasyncId]) {
                YTSessionDatasyncId = [datasync copy];

                NSLog(@"[YouTube/Плеер] Привязка сеанса: учётная запись");
            }
        }
    }

    NSString *visitorData = [YTJson textIn:context key:@"visitorData"];

    if ([visitorData length] == 0) {
        return;
    }

    @synchronized ([YTApi class]) {
        if ([YTSessionVisitorData length] == 0) {
            YTSessionVisitorData = [visitorData copy];
        }
    }
}

/** Один анонимный WEB `/player` ради `responseContext.visitorData`. */
+ (NSString *)fetchFreshVisitorData:(NSString *)videoId {
    if ([videoId length] == 0) {
        return nil;
    }

    NSMutableDictionary *client = [NSMutableDictionary dictionary];

    [client setObject:@"WEB" forKey:@"clientName"];
    [client setObject:YTVisitorSeedVersion forKey:@"clientVersion"];
    [client setObject:[self hl] forKey:@"hl"];
    [client setObject:[self gl] forKey:@"gl"];

    NSDictionary *payload = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSDictionary dictionaryWithObject:client forKey:@"client"], @"context",
        videoId, @"videoId",
        [NSNumber numberWithBool:YES], @"contentCheckOk",
        [NSNumber numberWithBool:YES], @"racyCheckOk",
        nil];

    NSDictionary *json = [self postPlayerPayload:payload
                                         headers:[NSDictionary dictionaryWithObjectsAndKeys:
                                                     YTWebUserAgent, @"User-Agent",
                                                     @"1", @"X-YouTube-Client-Name",
                                                     YTVisitorSeedVersion, @"X-YouTube-Client-Version",
                                                     nil]];

    return [YTJson textIn:[YTJson objectIn:json key:@"responseContext"] key:@"visitorData"];
}

/**
 * Ответ `/player` — там лежат потоки.
 *
 * Клиент — **ANDROID_VR** (шлем Oculus Quest), и это перенесено из
 * UWP-версии дословно, вместе с версией, User-Agent и номером клиента.
 * Выбран он не наугад: с выданным сервером `visitorData` этот клиент
 * отдаёт готовые к скачиванию адреса — и progressive, и adaptive, —
 * уже подписанные сервером (`sig`/`lsig` применены), без `&n=`, без `&pot=`
 * и без шифра подписи. То есть без разбора `player.js` и исполнения
 * JavaScript, чего на iOS 5 попросту нечем сделать.
 *
 * Ключ InnerTube сюда не шлётся вовсе: клиента опознают заголовки
 * `X-YouTube-Client-*`.
 *
 * `playbackContext` тоже не шлётся — он нужен только TVHTML5, где чинит
 * «the page needs to be reloaded». `contentCheckOk` и `racyCheckOk`
 * оставляют играбельными ролики с возрастным предупреждением.
 *
 * Повтор ровно один: пустые потоки почти всегда означают, что `visitorData`
 * протух или помечен, и сервер ответил анти-ботом. Тогда он сбрасывается,
 * добывается заново, и запрос повторяется.
 */
/**
 * Потоки для Shorts — своя цепочка, не та, что у обычного ролика.
 *
 * Порт `PopulateShortPlaybackInfoAsync`: ANDROID без токена, затем WEB
 * без токена, затем WEB с токеном. ANDROID_VR, которым берутся потоки
 * на странице ролика, здесь не годится — на Shorts он отвечает
 * LOGIN_REQUIRED («Войдите в аккаунт, чтобы подтвердить, что вы не бот»),
 * и в оригинале его для Shorts и не спрашивают.
 *
 * `contentCheckOk` и `racyCheckOk` — оттуда же: без них ролики с пометкой
 * возрастного ограничения отвечают отказом вместо потоков.
 */
+ (NSDictionary *)shortsPlayerResponse:(NSString *)videoId {
    return [self shortsPlayerResponse:videoId gate:NULL];
}

+ (NSDictionary *)shortsPlayerResponse:(NSString *)videoId gate:(BOOL *)gate {
    if (gate != NULL) {
        *gate = NO;
    }

    if ([videoId length] == 0) {
        return nil;
    }

    /**
     * Порядок и тела — из `GetShortPlaybackUrlAsync`: ANDROID без токена,
     * затем WEB без токена, затем WEB с токеном. Там же сказано, почему
     * первый заход без токена: `/player` у ANDROID-клиента отвечает
     * на `Bearer` отказом 400 INVALID_ARGUMENT.
     *
     * Запрос уходит тем же ходом, что и сама лента Shorts: у этой
     * поверхности свои версии клиентов и свои заголовки. С общими,
     * которыми ходит остальное приложение, ANDROID отвечал 400,
     * а WEB — «Видео недоступно».
     */
    /**
     * Сперва — общий путь, тот же, которым играют обычные ролики.
     *
     * Порядок из оригинала (ANDROID, WEB, WEB с токеном) сложился, когда
     * безымянные клиенты ещё отдавали потоки. Сейчас все трое отвечают
     * `LOGIN_REQUIRED`, и вертикальные ролики не играли вовсе: в журнале
     * это три отказа подряд и «потока нет».
     *
     * Подача SABR от TV-клиента работает и здесь — ролик тот же самый,
     * поверхность другая. Прежняя цепочка остаётся за ней: вдруг
     * когда-нибудь снова заработает, а склеенный поток играть проще.
     */
    NSDictionary *main = [self playerResponse:videoId];

    if ([self playerHasStreams:main] ||
        [YTJson textIn:[YTJson objectIn:main key:@"streamingData"]
                   key:@"serverAbrStreamingUrl"] != nil) {
        NSLog(@"[YouTube/Shorts] %@: поток общим путём (%@)",
              videoId, [self streamNote:main]);

        return main;
    }

    NSArray *attempts = [NSArray arrayWithObjects:@"ANDROID", @"WEB", @"WEB-AUTH", nil];

    for (NSString *attempt in attempts) {
        BOOL authorize = [attempt isEqualToString:@"WEB-AUTH"];
        NSString *client = authorize ? @"WEB" : attempt;

        if (authorize && ![YTAuth isSignedIn]) {
            continue;
        }

        NSMutableDictionary *body = [NSMutableDictionary dictionary];

        [body setObject:videoId forKey:@"videoId"];
        [body setObject:[NSNumber numberWithBool:YES] forKey:@"contentCheckOk"];
        [body setObject:[NSNumber numberWithBool:YES] forKey:@"racyCheckOk"];

        if ([client isEqualToString:@"WEB"]) {
            NSDictionary *context = [NSDictionary dictionaryWithObject:
                [NSDictionary dictionaryWithObject:@"HTML5_PREF_WANTS"
                                            forKey:@"html5Preference"]
                                                                forKey:@"contentPlaybackContext"];

            [body setObject:context forKey:@"playbackContext"];
        }

        NSDictionary *json = [self shortsPost:@"player"
                                         body:body
                                       client:client
                                    authorize:authorize];

        if ([[self shortsUrlIn:json] length] > 0) {
            NSLog(@"[YouTube/Shorts] %@: поток от %@%@", videoId, client,
                  authorize ? @" с токеном" : @" без токена");

            return json;
        }

        NSLog(@"[YouTube/Shorts] %@: %@%@ без потока (%@)", videoId, client,
              authorize ? @" с токеном" : @"", [self playabilityReason:json]);

        if (gate != NULL && [self isBotGate:json]) {
            *gate = YES;
        }
    }

    /**
     * Стена и на общем пути — тоже стена: до перебора дело доходит
     * ровно потому, что `/player` ответил `LOGIN_REQUIRED`.
     */
    if (gate != NULL && [self isBotGate:main]) {
        *gate = YES;
    }

    return nil;
}

/**
 * Готовый к воспроизведению адрес — порт `SelectPlayableShortUrl`.
 *
 * Берётся **склеенный** поток из `formats`: mp4 со звуком внутри.
 * Разбирать DASH здесь не нужно, и в оригинале он тоже не разбирается:
 * у вертикальных роликов склеенная дорожка есть всегда, а AVPlayer
 * играет её сам, без прокси.
 *
 * Из нескольких выбирается самый высокий, не выше выбранного в настройках;
 * если ниже потолка нет ничего — самый высокий вообще, как
 * в `ChooseShortByPreferredQuality`.
 */
+ (NSString *)shortsUrlIn:(NSDictionary *)playerResponse {
    NSArray *formats = [YTJson arrayIn:[YTJson objectIn:playerResponse key:@"streamingData"]
                                   key:@"formats"];

    NSString *best = nil;
    NSInteger bestHeight = -1;
    NSString *tallest = nil;
    NSInteger tallestHeight = -1;

    NSInteger preferred = [YTSettings preferredHeight];

    for (NSDictionary *format in formats) {
        NSString *url = [YTJson textIn:format key:@"url"];
        NSString *mime = [YTJson textIn:format key:@"mimeType"];

        if ([url length] == 0 || [mime rangeOfString:@"video/mp4"].location == NSNotFound) {
            continue;
        }

        BOOL hasAudio = [mime rangeOfString:@"mp4a"].location != NSNotFound
            || [format objectForKey:@"audioChannels"] != nil;

        if (!hasAudio) {
            continue;
        }

        NSInteger height = [YTJson intIn:format key:@"height"];

        if (height > tallestHeight) {
            tallestHeight = height;
            tallest = url;
        }

        if (preferred > 0 && height <= preferred && height > bestHeight) {
            bestHeight = height;
            best = url;
        }
    }

    return best != nil ? best : tallest;
}

/**
 * Сведения о ролике из ответа `/player` — порт `ApplyPlayerResponseToShort`.
 *
 * Лента reel присылает только идентификаторы: ни названия, ни автора
 * в ней нет. Всё это лежит в `videoDetails` ответа `/player`, который
 * и так запрашивается ради потока — то есть даром.
 *
 * Ничего сверх этого ответа здесь не спрашивается: счётчики и кружок
 * автора приезжают отдельно, `shortsDetails:known:`, и не задерживают
 * первый кадр.
 */
+ (NSDictionary *)shortsPlayback:(NSString *)videoId {
    BOOL gate = NO;

    NSDictionary *json = [self shortsPlayerResponse:videoId gate:&gate];

    if (json == nil) {
        // Причину отказа стоит донести до страницы: проверку человек
        // может пройти, а пустой экран ему ничего не говорит.
        return gate
            ? [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES]
                                          forKey:@"botGate"]
            : nil;
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    NSString *progressive = [self shortsUrlIn:json];

    if ([progressive length] > 0) {
        [result setObject:progressive forKey:@"url"];
    }

    /**
     * Сам ответ тоже отдаём: склеенного потока может не быть вовсе,
     * и тогда играть придётся подачей — а для неё нужен весь ответ,
     * а не одна ссылка.
     */
    [result setObject:json forKey:@"player"];

    NSDictionary *details = [YTJson objectIn:json key:@"videoDetails"];

    NSString *title = [YTJson textIn:details key:@"title"];
    NSString *author = [YTJson textIn:details key:@"author"];

    NSDictionary *microformat = [YTJson findFirst:@"playerMicroformatRenderer"
                                               in:json limit:2000];

    NSString *owner = [YTJson textIn:microformat key:@"ownerChannelName"];

    if (owner != nil) { author = owner; }

    if (title != nil)  { [result setObject:title forKey:@"title"]; }
    if (author != nil) { [result setObject:author forKey:@"channelTitle"]; }

    NSString *channelId = [YTJson textIn:details key:@"channelId"];

    if (channelId != nil) { [result setObject:channelId forKey:@"channelId"]; }

    return result;
}

/**
 * Счётчики, кружок автора и метка комментариев — отдельным заходом.
 *
 * Раньше это добиралось прямо здесь, в пути к потоку, и поток ждал:
 * `watchState:` — запрос, страница ролика — ещё один, и на iPhone 4
 * между ответом `/player` и первым фрагментом уходило семь секунд
 * из десяти. Ни одна из этих цифр воспроизведению не нужна — они
 * рисуются в столбце справа и могут приехать позже кадра.
 *
 * Счётчики у ленты reel есть не всегда: seedless-ответ присылает одни
 * идентификаторы, а `reelPlayerOverlayRenderer` приходит не к каждому
 * ролику. Тот же запрос, которым для обычного ролика берутся лайк
 * и подписка, знает и о вертикальном — ролик тот же, поверхность другая.
 *
 * `known` — то, что уже принёс ответ `/player`: по нему видно, чего
 * недостаёт, и лишнего запроса не будет.
 */
+ (NSDictionary *)shortsDetails:(NSString *)videoId known:(NSDictionary *)known {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    NSDictionary *state = [self watchState:videoId];

    for (NSString *key in state) {
        [result setObject:[state objectForKey:key] forKey:key];
    }

    /**
     * Без входа `watchState:` молчит — недостающее берём обычным путём
     * страницы ролика.
     *
     * Тот запрос ходит клиентом WEB и без учётной записи: поставлен ли
     * лайк, он не знает, а **сколько** их — знает, как знает и кружок
     * автора, и метку комментариев. Оттого у вертикальных роликов без
     * входа не было ни счётчиков, ни аватарки: единственный, кто их
     * приносил, требовал входа.
     *
     * Запрос лишний, поэтому идёт только когда нужного и правда нет.
     */
    /**
     * Название — тоже из нужного.
     *
     * В ленте Shorts его нет: TV-клиент отвечает на `reel_watch_sequence`
     * без `reelPlayerOverlayRenderer`, и у всех роликов оставалась метка
     * «Shorts», которую страница показывает пустой строкой. Оттого
     * подписи под роликами и были пустыми на всех Shorts подряд.
     */
    NSArray *wanted = [NSArray arrayWithObjects:
        @"likes", @"comments", @"channelThumbnail", @"commentsToken",
        @"channelTitle", @"subscribers", @"title", nil];

    BOOL missing = NO;

    for (NSString *key in wanted) {
        if ([result objectForKey:key] == nil && [known objectForKey:key] == nil) {
            missing = YES;
            break;
        }
    }

    if (missing) {
        NSDictionary *details = [self videoDetails:videoId playlist:nil];

        for (NSString *key in wanted) {
            id value = [details objectForKey:key];

            if (value != nil && [result objectForKey:key] == nil &&
                [known objectForKey:key] == nil) {

                [result setObject:value forKey:key];
            }
        }

        NSLog(@"[YouTube/Shorts] %@: добрали со страницы ролика — "
              @"лайки %@, комментарии %@, кружок %@",
              videoId,
              [result objectForKey:@"likes"] ?: @"нет",
              [result objectForKey:@"comments"] ?: @"нет",
              [result objectForKey:@"channelThumbnail"] != nil ? @"есть" : @"нет");
    }

    return result;
}


+ (NSString *)mediaUserAgent {
    @synchronized ([YTApi class]) {
        if ([YTStreamUserAgent length] > 0) {
            return YTStreamUserAgent;
        }
    }

    return YTAndroidVrUserAgent;
}

/** Запоминает, чьим именем и с какой привязкой добыты адреса ролика. */
+ (void)setStreamUserAgent:(NSString *)userAgent binding:(NSString *)binding {
    @synchronized ([YTApi class]) {
        YTStreamUserAgent = [userAgent copy];
        YTStreamBinding = [binding copy];

        /**
         * Заодно запоминаем, **кто** добыл эти адреса.
         *
         * Подача сверяет, тем ли клиентом её просят: имя, номер и версия
         * должны совпасть с тем, кому выдан адрес. Пока мы в каждом
         * запросе представлялись TVHTML5 — а без входа адрес приходит
         * вовсе не от него, — сервер отвечал просьбой обновить ответ
         * и не давал ни байта, ничего при этом не объясняя.
         */
        if ([userAgent isEqualToString:YTVisionUserAgent]) {
            YTStreamClient = @"VISIONOS";
        } else if ([userAgent isEqualToString:YTAndroidVrUserAgent]) {
            YTStreamClient = @"ANDROID_VR";
        } else if ([userAgent isEqualToString:YTTvUserAgent]) {
            YTStreamClient = @"TVHTML5";
        } else if ([userAgent isEqualToString:YTIosUserAgent]) {
            YTStreamClient = @"IOS";
        } else {
            YTStreamClient = @"TVHTML5";
        }
    }
}

+ (NSDictionary *)streamClientInfo {
    NSString *client = nil;

    @synchronized ([YTApi class]) {
        client = [YTStreamClient copy];
    }

    if ([client isEqualToString:@"VISIONOS"]) {
        return [NSDictionary dictionaryWithObjectsAndKeys:
            @"101", @"number", YTVisionVersion, @"version",
            @"visionOS", @"osName", @"1.0.2.21O209", @"osVersion",
            @"Apple", @"make", @"RealityDevice14,1", @"model", nil];
    }

    if ([client isEqualToString:@"ANDROID_VR"]) {
        return [NSDictionary dictionaryWithObjectsAndKeys:
            @"28", @"number", YTAndroidVrVersion, @"version",
            @"Android", @"osName", @"12L", @"osVersion",
            @"Oculus", @"make", @"Quest 3", @"model", nil];
    }

    if ([client isEqualToString:@"IOS"]) {
        return [NSDictionary dictionaryWithObjectsAndKeys:
            @"5", @"number", YTIosVersion, @"version",
            @"iOS", @"osName", @"18.3.2.22D82", @"osVersion",
            @"Apple", @"make", @"iPhone16,2", @"model", nil];
    }

    return [NSDictionary dictionaryWithObjectsAndKeys:
        [self clientNumber:@"TVHTML5"], @"number",
        [self clientVersion:@"TVHTML5"], @"version",
        @"Tizen", @"osName", @"5.0", @"osVersion",
        @"Samsung", @"make", @"SmartTV", @"model", nil];
}

/**
 * Каким нас видит Google **сейчас** — по свежему ответу `/player`.
 *
 * Адрес раздачи подписан вместе с адресом того, кто его попросил
 * (`ip` входит в `sparams`, а подпись покрывает `sparams`), и раздача
 * сверяет, с того ли адреса пришли. Если выход в сеть меняется между
 * тем, как мы получили ссылку, и тем, как пошли по ней, — это пустой
 * отказ 403 без единого слова объяснения, ровно тот, что мы видим.
 *
 * Отличить этот случай от прочих можно только сравнением: спросить
 * адрес заново и посмотреть, тот же ли он. Запрос идёт лишь после
 * отказа и стоит семь килобайт.
 *
 * nil, если спросить не у кого либо ответ пришёл без адресов.
 */
+ (NSString *)probeSeenIp {
    NSString *videoId = nil;

    @synchronized ([YTApi class]) {
        videoId = YTStreamVideoId;
    }

    if ([videoId length] == 0) {
        return nil;
    }

    NSDictionary *streaming =
        [YTJson objectIn:[self iosPlayerResponse:videoId] key:@"streamingData"];

    NSArray *lists = [NSArray arrayWithObjects:
        [YTJson arrayIn:streaming key:@"adaptiveFormats"],
        [YTJson arrayIn:streaming key:@"formats"],
        nil];

    for (NSArray *list in lists) {
        for (NSDictionary *format in list) {
            NSString *url = [YTJson textIn:format key:@"url"];
            NSRange found = [url rangeOfString:@"&ip="];

            if (found.location == NSNotFound) {
                continue;
            }

            NSString *tail = [url substringFromIndex:NSMaxRange(found)];
            NSRange stop = [tail rangeOfString:@"&"];

            return stop.location == NSNotFound
                ? tail : [tail substringToIndex:stop.location];
        }
    }

    return nil;
}

+ (NSString *)streamBinding {
    @synchronized ([YTApi class]) {
        return YTStreamBinding;
    }
}

/**
 * `next` — страница ролика: описание, комментарии, похожие, очередь.
 *
 * Клиент WEB и **без** `Bearer`: пару «WEB плюс токен» сервер принимает
 * не везде, `browse` на неё отвечает отказом 400, о чём в оригинале
 * написано прямо над `PostInnertubeJsonAsync`. Учётную запись здесь
 * представляет браузерная сессия, если она есть, — подпись ставится
 * в `post:`, — а состояние «нравится» и «подписан» берётся отдельно,
 * TV-клиентом: `watchState:`.
 */
+ (NSDictionary *)postNext:(NSDictionary *)body {
    return [self post:@"next" body:body client:@"WEB" authorize:NO ttl:0];
}

/**
 * Состояние ролика для учётной записи: лайк и подписка.
 *
 * Отдельным запросом и TV-клиентом, потому что учётную запись у нас
 * удостоверяет токен QR-кода, а принимает его в паре с собой именно
 * TVHTML5 — тот же клиент, которым берутся «Главная», подписки
 * и история.
 *
 * Ответ TV-клиента к тому же проще разбирать: там прежние рендереры
 * с прямыми полями `subscribed` и `isToggled`, тогда как веб давно
 * перешёл на модели представления, где состояние лежит в отдельном
 * хранилище сущностей и по самой кнопке не читается.
 *
 * nil, если входа нет или сервер отказал, — тогда состояние остаётся
 * тем, что дал веб.
 */
+ (NSDictionary *)watchState:(NSString *)videoId {
    if ([videoId length] == 0 || ![YTAuth isSignedIn]) {
        return nil;
    }

    NSDictionary *json = [self post:@"next"
                               body:[NSDictionary dictionaryWithObject:videoId
                                                                forKey:@"videoId"]
                             client:@"TVHTML5"
                          authorize:YES
                                ttl:0];

    if (json == nil) {
        NSLog(@"[YouTube/Ролик] TV-клиент не сказал о лайке и подписке");

        return nil;
    }

    NSMutableDictionary *state = [NSMutableDictionary dictionary];

    NSDictionary *subscribe = [YTJson findFirst:@"subscribeButtonRenderer"
                                             in:json limit:6000];

    if (subscribe == nil) {
        // Та же запасная форма, что и у лайка: отдельная сущность.
        subscribe = [YTJson findFirst:@"subscriptionStateEntity" in:json limit:6000];
    }

    if (subscribe != nil) {
        [state setObject:[NSNumber numberWithBool:
            [YTJson boolIn:subscribe key:@"subscribed"]] forKey:@"subscribed"];

        NSInteger bell = [self notificationsIn:subscribe];

        if (bell != YTNotificationsUnknown) {
            [state setObject:[NSNumber numberWithInteger:bell] forKey:@"notifications"];
        }
    }

    // Колокольчик приходит и отдельной сущностью — берём, если в кнопке
    // его не оказалось: у разных ответов он лежит по-разному.
    if ([state objectForKey:@"notifications"] == nil) {
        NSMutableDictionary *entities = [NSMutableDictionary dictionary];

        [self applySubscriptionEntitiesTo:entities from:json];

        NSNumber *bell = [entities objectForKey:@"notifications"];

        if (bell != nil) {
            [state setObject:bell forKey:@"notifications"];
        }
    }

    /**
     * Лайк у TV-клиента лежит в `likeButtonRenderer` — прямо строкой
     * `likeStatus` со значением `LIKE`, `DISLIKE` или `INDIFFERENT`,
     * и рядом же готовая подпись счётчика.
     *
     * Искал я это сперва в `toggleButtonRenderer` по примете
     * `targetId: watch-like`. Примета в ответе есть, но лежит она
     * не там — оттого в журнале и стояло «лайк неизвестно».
     */
    NSDictionary *like = [YTJson findFirst:@"likeButtonRenderer" in:json limit:6000];

    NSString *status = [YTJson textIn:like key:@"likeStatus"];

    if (status == nil) {
        /**
         * Запасная форма: то же состояние приходит отдельной сущностью
         * в `frameworkUpdates`. Сервер шлёт обе, но полагаться на одну
         * только кнопку не стоит — её форма меняется чаще.
         */
        NSDictionary *entity = [YTJson findFirst:@"likeStatusEntity" in:json limit:6000];

        status = [YTJson textIn:entity key:@"likeStatus"];
    }

    if (status != nil) {
        [state setObject:[NSNumber numberWithBool:
            [status isEqualToString:@"LIKE"]] forKey:@"liked"];
    }

    NSString *count = [YTJson renderedText:like key:@"likeCountText"];

    if ([count length] > 0) {
        [state setObject:count forKey:@"likes"];
    }

    /**
     * Число комментариев лежит в точке входа в их панель — готовой
     * строкой, как и всё остальное у TV-клиента.
     */
    /**
     * Имя рендерера — `commentsEntryPointRenderer`. Я искал его сперва
     * как `…HeaderRenderer`, и счётчик оттого не появлялся вовсе:
     * в ответе TV-клиента такого имени нет.
     */
    NSDictionary *entry = [YTJson findFirst:@"commentsEntryPointRenderer"
                                         in:json limit:6000];

    if (entry == nil) {
        entry = [YTJson findFirst:@"commentsEntryPointHeaderRenderer"
                               in:json limit:6000];
    }

    NSString *comments = [YTJson renderedText:entry key:@"commentCount"];

    if ([comments length] > 0) {
        [state setObject:comments forKey:@"comments"];
    }

    /**
     * Автор и его кружок — оттуда же.
     *
     * Лента reel присылает одни идентификаторы, а этот запрос мы всё
     * равно делаем ради лайка. Второй ходки за тем же самым не нужно.
     */
    /**
     * Название ролика. У вертикальных его больше взять неоткуда: лента
     * reel присылает одни идентификаторы, а в ответе `/player` подпись
     * лежит не всегда — у Shorts она нередко пуста.
     */
    NSDictionary *meta = [YTJson findFirst:@"videoMetadataRenderer" in:json limit:6000];

    NSString *heading = [YTJson renderedText:meta key:@"title"];

    if ([heading length] > 0) {
        [state setObject:heading forKey:@"title"];
    }

    /**
     * Приметы для оценки — их выдаёт сам сервер.
     *
     * У каждого хода свой набор: поставить лайк, поставить дизлайк,
     * снять оценку. Лежат они в служебных эндпоинтах кнопки, и по тому,
     * какое поле заполнено, ход и опознаётся: `likeParams` — лайк,
     * `dislikeParams` — дизлайк, `removeLikeParams` — снятие.
     */
    NSArray *endpoints = [YTJson findAllOfAny:
        [NSArray arrayWithObjects:@"likeEndpoint", @"dislikeEndpoint", nil]
                                            in:json limit:6000];

    for (NSDictionary *endpoint in endpoints) {
        NSString *value = [YTJson textIn:endpoint key:@"likeParams"];

        if ([value length] > 0) { [state setObject:value forKey:@"likeParams"]; }

        value = [YTJson textIn:endpoint key:@"dislikeParams"];

        if ([value length] > 0) { [state setObject:value forKey:@"dislikeParams"]; }

        value = [YTJson textIn:endpoint key:@"removeLikeParams"];

        if ([value length] > 0) { [state setObject:value forKey:@"noneParams"]; }
    }

    /**
     * Токен комментариев — оттуда же.
     *
     * У вертикальных роликов иначе выходила задержка на пустом месте:
     * лист комментариев шёл за ним отдельным запросом к веб-клиенту,
     * ждал несколько секунд и нередко возвращался ни с чем — у Shorts
     * веб-ответ панели комментариев не несёт. TV-ответ несёт, и мы его
     * и так уже запросили ради счётчиков.
     */
    NSArray *panels = [YTJson findAll:@"engagementPanelSectionListRenderer"
                                   in:json limit:6000];

    for (NSDictionary *panel in panels) {
        NSString *identifier = [YTJson textIn:panel key:@"panelIdentifier"];

        if (![identifier isEqualToString:@"comment-item-section"] &&
            ![identifier isEqualToString:@"engagement-panel-comments-section"]) {
            continue;
        }

        NSString *token = [self continuationIn:panel];

        if ([token length] > 0) {
            [state setObject:token forKey:@"commentsToken"];
        }

        break;
    }

    NSDictionary *owner = [YTJson findFirst:@"videoOwnerRenderer" in:json limit:6000];

    NSString *channel = [YTJson renderedText:owner key:@"title"];

    if ([channel length] > 0) {
        [state setObject:channel forKey:@"channelTitle"];
    }

    NSString *avatar = [YTJson thumbnailIn:owner key:@"thumbnail" minWidth:88];

    if ([avatar length] > 0) {
        [state setObject:avatar forKey:@"channelThumbnail"];
    }

    NSLog(@"[YouTube/Ролик] TV-клиент о ролике: лайк %@, подписка %@ (%@ / %@ комм.)",
          [state objectForKey:@"liked"] ? ([[state objectForKey:@"liked"] boolValue] ? @"да" : @"нет") : @"неизвестно",
          [state objectForKey:@"subscribed"] ? ([[state objectForKey:@"subscribed"] boolValue] ? @"да" : @"нет") : @"неизвестно",
          [state objectForKey:@"likes"] ?: @"—", [state objectForKey:@"comments"] ?: @"—");

    return [state count] > 0 ? state : nil;
}

+ (BOOL)rate:(NSString *)videoId as:(NSString *)action params:(NSString *)params {
    if ([videoId length] == 0 || ![YTAuth isSignedIn]) {
        return NO;
    }

    NSString *endpoint = @"like/removelike";

    if ([action isEqualToString:@"like"]) {
        endpoint = @"like/like";
    } else if ([action isEqualToString:@"dislike"]) {
        endpoint = @"like/dislike";
    }

    NSMutableDictionary *body = [NSMutableDictionary dictionary];

    [body setObject:[NSDictionary dictionaryWithObject:videoId forKey:@"videoId"]
             forKey:@"target"];

    if ([params length] > 0) {
        [body setObject:params forKey:@"params"];
    }

    /**
     * TVHTML5 идёт первым, MWEB и WEB — запасными.
     *
     * Порядок в оригинале обратный, и он там не выведен, а унаследован
     * от TubeReplacer вместе с формой запроса. Между тем учётную запись
     * у нас удостоверяет токен QR-кода, а принимает его в паре с собой
     * именно TV-клиент: с веб-семейством эта пара проходит не везде —
     * `browse` отвечает на неё отказом 400, и `next` тоже отвечал.
     *
     * Что TV-клиент оценивать умеет, видно по его же ответу: сервер
     * присылает ему готовые `likeEndpoint` и `dislikeEndpoint` с целью
     * и приметами. Их мы сюда и передаём.
     *
     * Веб-клиенты оставлены следом — на случай, если TV когда-нибудь
     * откажет: форма запроса у всех троих одна.
     */
    NSArray *clients = [NSArray arrayWithObjects:@"TVHTML5", @"MWEB", @"WEB", nil];

    for (NSString *client in clients) {
        NSDictionary *json = [self post:endpoint
                                   body:body
                                 client:client
                              authorize:YES
                                    ttl:0];

        if (json != nil) {
            NSLog(@"[YouTube/Оценка] %@ для %@: принята (%@)",
                  endpoint, videoId, client);

            return YES;
        }

        NSLog(@"[YouTube/Оценка] %@ для %@: отказ от %@", endpoint, videoId, client);
    }

    return NO;
}

+ (BOOL)setSubscribed:(BOOL)subscribed channel:(NSString *)channelId {
    if ([channelId length] == 0 || ![YTAuth isSignedIn]) {
        return NO;
    }

    /**
     * Постоянные `params` из оригинала: `DefaultSubscribeParams`
     * и `DefaultUnsubscribeParams`. Сервер принимает их для любого
     * канала — это не подпись, а пометка о том, откуда нажали.
     */
    NSMutableDictionary *body = [NSMutableDictionary dictionary];

    [body setObject:[NSArray arrayWithObject:channelId] forKey:@"channelIds"];
    [body setObject:(subscribed ? @"CgIIAxgA" : @"CgIIAxgB") forKey:@"params"];

    NSDictionary *json = [self post:(subscribed ? @"subscription/subscribe"
                                                : @"subscription/unsubscribe")
                               body:body
                             client:@"TVHTML5"
                          authorize:YES
                                ttl:0];

    NSLog(@"[YouTube/Канал] %@ на %@: %@", subscribed ? @"Подписка" : @"Отписка",
          channelId, json != nil ? @"удалась" : @"отказ");

    return json != nil;
}

/**
 * Подписка и колокольчик из `frameworkUpdates`.
 *
 * У нынешней кнопки (`subscribeButtonViewModel`) внутри лежат **оба**
 * её вида разом — «Подписаться» с `subscribed: false` и «Вы подписаны»
 * с `subscribed: true`, — потому что это заготовки, а не состояние.
 * Кто из них сейчас на экране, сказано отдельно: сущностью
 * `subscriptionStateEntity` в `frameworkUpdates`. Прежний разбор брал
 * первое попавшееся `subscribeState`, то есть всегда заготовку
 * «Подписаться», и оттого показывал «не подписан» даже подписанному.
 *
 * Колокольчик там же, соседней сущностью, готовым значением:
 * `SUBSCRIPTION_NOTIFICATION_STATE_ALL` и подобными.
 */
+ (void)applySubscriptionEntitiesTo:(NSMutableDictionary *)result from:(id)json {
    /**
     * Ищем по точному пути, а не обходом дерева.
     *
     * Ответ канала — под полмегабайта JSON, и обход в нём упирается
     * в потолок посещённых узлов раньше, чем доберётся до `frameworkUpdates`:
     * порядок ключей в словаре не определён, и попадётся ли эта ветка
     * в отпущенный бюджет — как повезёт. А путь к сущностям известен.
     */
    NSArray *mutations = [YTJson arrayIn:
        [YTJson objectIn:[YTJson objectIn:json key:@"frameworkUpdates"]
                     key:@"entityBatchUpdate"] key:@"mutations"];

    NSDictionary *entity = nil;
    NSDictionary *bell = nil;

    for (NSDictionary *mutation in mutations) {
        NSDictionary *payload = [YTJson objectIn:mutation key:@"payload"];

        if (entity == nil) {
            entity = [YTJson objectIn:payload key:@"subscriptionStateEntity"];
        }

        if (bell == nil) {
            bell = [YTJson objectIn:payload key:@"subscriptionNotificationStateEntity"];
        }
    }

    if (entity == nil) {
        entity = [YTJson findFirst:@"subscriptionStateEntity" in:json limit:8000];
    }

    if (entity != nil) {
        [result setObject:[NSNumber numberWithBool:
            [YTJson boolIn:entity key:@"subscribed"]] forKey:@"subscribed"];
    }

    if (bell == nil) {
        bell = [YTJson findFirst:@"subscriptionNotificationStateEntity"
                              in:json limit:8000];
    }

    NSString *state = [[YTJson textIn:bell key:@"state"] uppercaseString];

    if ([state length] == 0) {
        return;
    }

    NSInteger picked = YTNotificationsUnknown;

    if ([state rangeOfString:@"ALL"].location != NSNotFound) {
        picked = YTNotificationsAll;
    } else if ([state rangeOfString:@"NONE"].location != NSNotFound ||
               [state rangeOfString:@"OFF"].location != NSNotFound) {
        picked = YTNotificationsNone;
    } else if ([state rangeOfString:@"DEFAULT"].location != NSNotFound ||
               [state rangeOfString:@"OCCASIONAL"].location != NSNotFound ||
               [state rangeOfString:@"PERSONALIZED"].location != NSNotFound) {
        picked = YTNotificationsPersonalized;
    }

    if (picked != YTNotificationsUnknown) {
        [result setObject:[NSNumber numberWithInteger:picked] forKey:@"notifications"];
    }
}

/**
 * Нынешнее предпочтение оповещений из кнопки подписки — порт
 * `ParseNotificationStateText`.
 *
 * У кнопки лежит перечень состояний со своими значками и подписями,
 * а рядом — `currentStateId` того, которое выбрано. Ни того ни другого
 * может не оказаться; тогда узнаём по подписи, и она бывает на языке
 * человека — оттого и русские слова в разборе.
 */
+ (NSInteger)notificationsIn:(NSDictionary *)subscribe {
    NSDictionary *toggle = [YTJson findFirst:@"subscriptionNotificationToggleButtonRenderer"
                                          in:subscribe limit:2000];

    if (toggle == nil) {
        return YTNotificationsUnknown;
    }

    NSString *current = [YTJson textIn:toggle key:@"currentStateId"];

    NSArray *states = [YTJson arrayIn:toggle key:@"states"];

    for (NSDictionary *node in states) {
        NSString *identifier = [YTJson stringIn:node key:@"stateId" fallback:nil];

        if (current != nil && ![identifier isEqualToString:current]) {
            continue;
        }

        NSString *icon = [YTJson textIn:[YTJson findFirst:@"icon" in:node limit:200]
                                    key:@"iconType"];

        NSString *label = [[YTJson renderedText:node key:@"state"] uppercaseString];

        if (label == nil) {
            label = [[YTJson renderedText:node key:@"tooltip"] uppercaseString];
        }

        NSString *mark = [icon length] > 0 ? [icon uppercaseString] : label;

        if (mark == nil) {
            continue;
        }

        if ([mark rangeOfString:@"OFF"].location != NSNotFound ||
            [mark rangeOfString:@"NONE"].location != NSNotFound ||
            [mark rangeOfString:@"ОТКЛ"].location != NSNotFound ||
            [mark rangeOfString:@"НЕТ"].location != NSNotFound) {
            return YTNotificationsNone;
        }

        if ([mark rangeOfString:@"ACTIVE"].location != NSNotFound ||
            [mark rangeOfString:@"ALL"].location != NSNotFound ||
            [mark rangeOfString:@"ВСЕ"].location != NSNotFound) {
            return YTNotificationsAll;
        }

        return YTNotificationsPersonalized;
    }

    return YTNotificationsUnknown;
}

/**
 * Запись байтов в base64.
 *
 * Свой, а не системный: `-base64EncodedStringWithOptions:` появился
 * в iOS 7, а нижняя граница у нас 5.1. Обычная азбука, с хвостом
 * из знаков равенства — сервер ждёт именно её.
 */
static NSString *YTBase64(NSData *data) {
    static const char *alphabet =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    const unsigned char *bytes = [data bytes];
    NSUInteger length = [data length];

    NSMutableString *text = [NSMutableString stringWithCapacity:(length + 2) / 3 * 4];

    for (NSUInteger i = 0; i < length; i += 3) {
        NSUInteger left = length - i;

        unsigned int block = (unsigned int)bytes[i] << 16;

        if (left > 1) { block |= (unsigned int)bytes[i + 1] << 8; }
        if (left > 2) { block |= (unsigned int)bytes[i + 2]; }

        [text appendFormat:@"%c%c", alphabet[(block >> 18) & 0x3F],
                                    alphabet[(block >> 12) & 0x3F]];

        [text appendFormat:@"%c", left > 1 ? alphabet[(block >> 6) & 0x3F] : '='];
        [text appendFormat:@"%c", left > 2 ? alphabet[block & 0x3F] : '='];
    }

    return text;
}

/**
 * Метка для `notification/modify_channel_preference` — порт
 * `BuildNotificationPreferenceParams`.
 *
 * Это не подпись и не догадка, а собранный вручную protobuf, тот же
 * байт в байт: поле 1 — номер канала строкой, поле 2 — вложенное
 * сообщение с кодом состояния, дальше две постоянные величины. Кодов
 * три: 1 — по интересам, 2 — все, 3 — никаких.
 */
+ (NSString *)notificationParams:(NSInteger)state channel:(NSString *)channelId {
    NSData *identifier = [channelId dataUsingEncoding:NSUTF8StringEncoding];

    if ([identifier length] == 0 || [identifier length] > 127) {
        return nil;
    }

    unsigned char code = 1;

    if (state == YTNotificationsAll)  { code = 2; }
    if (state == YTNotificationsNone) { code = 3; }

    NSMutableData *blob = [NSMutableData data];

    unsigned char head[2] = {0x0A, (unsigned char)[identifier length]};

    [blob appendBytes:head length:2];
    [blob appendData:identifier];

    unsigned char tail[8] = {0x12, 0x02, 0x08, code, 0x18, 0x00, 0x20, 0x04};

    [blob appendBytes:tail length:8];

    return YTEncodeParameter(YTBase64(blob));
}

+ (BOOL)setNotifications:(NSInteger)state channel:(NSString *)channelId {
    if ([channelId length] == 0 || ![YTAuth isSignedIn]) {
        return NO;
    }

    NSString *params = [self notificationParams:state channel:channelId];

    if (params == nil) {
        return NO;
    }

    NSDictionary *json = [self post:@"notification/modify_channel_preference"
                               body:[NSDictionary dictionaryWithObject:params
                                                                forKey:@"params"]
                             client:@"TVHTML5"
                          authorize:YES
                                ttl:0];

    NSLog(@"[YouTube/Канал] Оповещения %ld для %@: %@",
          (long)state, channelId, json != nil ? @"приняты" : @"отказ");

    return json != nil;
}

/**
 * Метка показа — шестнадцать знаков, и **одна на весь просмотр**.
 *
 * Прежде она выдумывалась заново при каждом обращении, и это была не
 * мелочь, а подмена личности. В дампе движения youtube.com/tv одна метка
 * стоит в девяноста одном запросе подряд — во всех обращениях за видео,
 * и в тех же `qoe` и `watchtime`. Ею сервер и связывает наши просьбы в
 * один показ. У нас же каждый служебный сигнал уходил от нового зрителя,
 * а в окне для сисадминов метка менялась раз в секунду — оттого и
 * заметно со стороны.
 *
 * Держится на ролик: пересадка подачи, перезапуск сессии и смена
 * качества показ не прерывают, и метку менять при них не нужно. Новый
 * ролик — новая метка.
 */
+ (NSString *)playbackNonceForVideo:(NSString *)videoId {
    static NSString *const alphabet =
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

    static NSString *nonce = nil;
    static NSString *owner = nil;

    @synchronized ([YTApi class]) {
        NSString *key = ([videoId length] > 0) ? videoId : @"";

        if (nonce == nil || ![owner isEqualToString:key]) {
            NSMutableString *fresh = [NSMutableString stringWithCapacity:16];

            for (NSUInteger i = 0; i < 16; i++) {
                [fresh appendFormat:@"%C",
                    [alphabet characterAtIndex:(arc4random() % 64)]];
            }

            nonce = [fresh copy];
            owner = [key copy];
        }

        return nonce;
    }
}

+ (NSString *)playbackNonce {
    return [self playbackNonceForVideo:YTStreamVideoId];
}

/** Один служебный сигнал; отказ не беда, историю он не ломает. */
+ (void)pingStats:(NSString *)url {
    NSMutableURLRequest *request =
        YTRequest(url, NSURLRequestReloadIgnoringLocalCacheData, 15.0);

    if (request == nil) {
        return;
    }

    NSString *token = [YTAuth accessToken];

    if ([token length] > 0) {
        [request setValue:[@"Bearer " stringByAppendingString:token]
       forHTTPHeaderField:@"Authorization"];
    }

    [request setValue:YTTvUserAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"https://www.youtube.com/tv" forHTTPHeaderField:@"Referer"];

    YTHttpResponse *answer = [YTHttp send:request bodyLimit:4096];

    NSLog(@"[YouTube/История] Сигнал %@: код %ld",
          [[NSURL URLWithString:url] path], (long)[answer statusCode]);
}

+ (void)reportWatched:(NSDictionary *)playerResponse
             position:(NSTimeInterval)position {
    [self reportWatched:playerResponse
               position:position
                   from:-1
                elapsed:0
                  final:NO];
}

/**
 * Отрезок просмотра: отсюда, досюда, столько прошло.
 *
 * Настоящий TV-клиент не отмечает ролик одной точкой — он ведёт
 * непрерывную запись. В дампе yttv5 пятнадцать обращений к `watchtime`
 * за сессию: первые три через десять секунд, дальше через сорок, и в
 * каждом `st` равен `et` предыдущего. Так сервер складывает из отрезков
 * всю дорожку просмотра, а не одну отметку у нулевой секунды.
 *
 * `from` меньше нуля означает «отрезка нет» — начало показа.
 */
+ (void)reportWatched:(NSDictionary *)playerResponse
             position:(NSTimeInterval)position
                 from:(NSTimeInterval)from
              elapsed:(NSTimeInterval)elapsed
                final:(BOOL)final {
    if (![YTAuth isSignedIn]) {
        return;
    }

    NSDictionary *tracking = [YTJson objectIn:playerResponse key:@"playbackTracking"];

    NSString *playback = [YTJson textIn:
        [YTJson objectIn:tracking key:@"videostatsPlaybackUrl"] key:@"baseUrl"];

    NSString *watchtime = [YTJson textIn:
        [YTJson objectIn:tracking key:@"videostatsWatchtimeUrl"] key:@"baseUrl"];

    if ([playback length] == 0 && [watchtime length] == 0) {
        NSLog(@"[YouTube/История] Адресов для сигналов нет — просмотр не отмечен");

        return;
    }

    NSTimeInterval length = [[YTJson textIn:
        [YTJson objectIn:playerResponse key:@"videoDetails"]
                   key:@"lengthSeconds"] doubleValue];

    NSString *videoId = [YTJson textIn:
        [YTJson objectIn:playerResponse key:@"videoDetails"] key:@"videoId"];

    /**
     * Общая часть запроса — то, чем клиент представляется. Значения
     * взяты у TV-клиента: сигналы должны выглядеть так же, как от него,
     * иначе просмотр не засчитывается.
     */
    NSString *common = [NSString stringWithFormat:
        @"&cpn=%@&ver=2&fs=0&volume=100&muted=0&state=playing"
        @"&c=TVHTML5&cver=%@&cplayer=UNIPLAYER&cmodel=SmartTV"
        @"&cos=Tizen&cosver=5.0&cplatform=TV&ctheme=CLASSIC&hl=%@&cr=%@",
        [self playbackNonce], [self clientVersion:@"TVHTML5"], [self hl], [self gl]];

    NSTimeInterval at = MAX(position, 0.0);
    BOOL opening = (from < 0);

    /**
     * Сигнал `playback` — только при начале показа: он открывает запись,
     * и повторять его на каждом отрезке незачем.
     */
    if (opening && [playback length] > 0) {
        [self pingStats:[NSString stringWithFormat:@"%@%@&cmt=%.3f",
            playback, common, at]];
    }

    if ([watchtime length] > 0) {
        /**
         * Именно этот сигнал и заводит запись в истории: он сообщает,
         * какой отрезок посмотрели. Нулевой отрезок не считается,
         * поэтому у самого начала берётся секунда.
         */
        NSTimeInterval begin = opening ? 0.0 : MAX(from, 0.0);
        NSTimeInterval end = MAX(at, begin);

        if (opening && end <= begin) {
            end = begin + 1.0;
        }

        NSTimeInterval spent = opening ? end : MAX(elapsed, 0.0);

        NSMutableString *url = [NSMutableString stringWithFormat:
            @"%@%@&cmt=%.3f&st=%.3f&et=%.3f&rt=%.3f",
            watchtime, common, at, begin, end, spent];

        if (length > 0) {
            [url appendFormat:@"&len=%.3f", length];
        }

        /**
         * `final=1` у последнего отрезка.
         *
         * В дампе его нет, и это не довод против: дамп снят с эфира,
         * который не кончается, — там все пятнадцать обращений идут со
         * `state=playing` и без признака конца. Признак этот у сигналов
         * YouTube означает «запись закрыта, больше по этому показу
         * ничего не будет».
         */
        if (final) {
            [url appendString:@"&final=1"];
        }

        [self pingStats:url];
    }

    NSLog(@"[YouTube/История] %@: отрезок %.0f…%.0f с, показ на %.0f с%@",
          videoId, opening ? 0.0 : MAX(from, 0.0), at, at,
          final ? @", запись закрыта" : @"");
}

+ (NSDictionary *)playerResponse:(NSString *)videoId {
    if ([videoId length] == 0) {
        return nil;
    }

    @synchronized ([YTApi class]) {
        YTStreamVideoId = [videoId copy];
    }

    /**
     * Порядок — из `LoadVideoDetailsFastAsync`: сперва IOS, и только потом
     * ANDROID_VR. Первый запрос нужен не ради потоков, а ради `visitorData`:
     * с ним ANDROID_VR проходит анти-бота с первой попытки, о чём в оригинале
     * написано прямо над `CaptureVisitorData`.
     */
    NSDictionary *primary = [self iosPlayerResponse:videoId];

    [self captureVisitorData:primary];

    /**
     * TV-клиент спрашивается первым, и если он ответил подачей SABR —
     * берём его, не пробуя остальных.
     *
     * Так раздаёт видео сам YouTube, и так у нас доступны все качества
     * и все звуковые дорожки. Готовые адреса от ANDROID_VR дают меньше
     * и отказывают чаще: ссылка привязана к адресу, с которого её взяли,
     * а он у нас меняется от запроса к запросу — на них раздача отвечает
     * отказом там, где подаче всё равно.
     *
     * Годен этот ответ или нет, окончательно выяснится позже, когда
     * подачу спросят о первых кусках. Если не задастся — плеер сходит
     * за `androidVrPlayerResponse:` и доиграет вторым путём.
     */
    if ([YTSettings delivery] == YTDeliverySabr &&
        ([YTAuth isSignedIn] || [YTWebAuth isSignedIn])) {
        NSDictionary *forced = [self fetchTvPlayer:videoId];

        if ([YTJson textIn:[YTJson objectIn:forced key:@"streamingData"]
                       key:@"serverAbrStreamingUrl"] != nil) {
            NSLog(@"[YouTube/Плеер] Подача SABR от TVHTML5 (%@)",
                  [self streamNote:forced]);

            [self captureVisitorData:forced];
            [self setStreamUserAgent:YTTvUserAgent binding:[self sessionBinding]];

            return forced;
        }

        NSLog(@"[YouTube/Плеер] TVHTML5 без подачи (%@) — идём за готовыми адресами",
              [self playabilityReason:forced]);
    }

    return [self androidVrPlayerResponse:videoId primary:primary];
}

+ (NSDictionary *)androidVrPlayerResponse:(NSString *)videoId {
    if ([videoId length] == 0) {
        return nil;
    }

    @synchronized ([YTApi class]) {
        YTStreamVideoId = [videoId copy];
    }

    /**
     * IOS-клиент спрашивается и здесь — по той же причине, что и в
     * `playerResponse:`: его ответ несёт `visitorData`, с которым
     * ANDROID_VR проходит анти-бота с первой попытки. Заодно он же
     * идёт последним ходом, если не выйдет ничего другого.
     */
    NSDictionary *primary = [self iosPlayerResponse:videoId];

    [self captureVisitorData:primary];

    return [self androidVrPlayerResponse:videoId primary:primary];
}

/**
 * Общая часть: ответ IOS-клиента уже на руках, второй раз его не просим.
 */
+ (NSDictionary *)androidVrPlayerResponse:(NSString *)videoId
                                  primary:(NSDictionary *)primary {
    /**
     * Сперва шлем Apple — он один играет дальше первой минуты.
     *
     * ANDROID_VR отвечает охотно и адреса даёт, но раздача обрывает его
     * сессию около шестидесятой секунды: подача перестаёт слать куски,
     * и просмотр встаёт. В наших журналах это «Подача не дала кусок 12
     * (время 61.4 с)» и такие же строки на 60.3 и 61.1 с — на разных
     * устройствах и роликах. Vision Pro этого предела не знает.
     *
     * Если он почему-либо не ответит потоками, ниже всё как было:
     * ANDROID_VR, повтор со свежим `visitorData`, TV-клиент, IOS.
     */
    NSDictionary *vision = [self fetchVisionPlayer:videoId reloadToken:nil];

    if ([self playerHasStreams:vision]) {
        NSLog(@"[YouTube/Плеер] Потоки от VISIONOS (%@)", [self streamNote:vision]);

        [self captureVisitorData:vision];
        [self setStreamUserAgent:YTVisionUserAgent binding:nil];

        return vision;
    }

    NSLog(@"[YouTube/Плеер] VISIONOS без потоков (%@) — идём к ANDROID_VR",
          [self playabilityReason:vision]);

    NSDictionary *json = [self fetchAndroidVrPlayer:videoId];

    if ([self playerHasStreams:json]) {
        [self setStreamUserAgent:YTAndroidVrUserAgent binding:YTAndroidVrBinding];

        return json;
    }

    NSLog(@"[YouTube/Плеер] ANDROID_VR без потоков (%@); обновляем visitorData",
          [self playabilityReason:json]);

    [self invalidateVisitorData];

    NSDictionary *retry = [self fetchAndroidVrPlayer:videoId];

    if ([self playerHasStreams:retry]) {
        NSLog(@"[YouTube/Плеер] Повтор со свежим visitorData удался");

        [self setStreamUserAgent:YTAndroidVrUserAgent binding:YTAndroidVrBinding];

        return retry;
    }

    NSLog(@"[YouTube/Плеер] Повтор тоже без потоков (%@)", [self playabilityReason:retry]);

    /** Ответ, годный лишь на крайний случай: склеенный поток без выбора. */
    NSDictionary *fallback = nil;

    /** Чьим именем идти за придержанным потоком. */
    NSString *fallbackAgent = nil;

    /**
     * TV-клиент с токеном учётной записи.
     *
     * Стоит раньше WEB, потому что за ним настоящий вход, а не куки,
     * и потому что WEB давно раздаёт одну лишь SABR-подачу: дорожек
     * два десятка, адресов ноль. Токен OAuth выдан именно TV-клиенту —
     * тому же, которым берутся «Главная», подписки и история.
     */
    if ([YTAuth isSignedIn] || [YTWebAuth isSignedIn]) {
        NSDictionary *tv = [self fetchTvPlayer:videoId];

        [self captureVisitorData:tv];

        NSLog(@"[YouTube/Плеер] TVHTML5 с учётной записью: %@ (%@)",
              [self playabilityReason:tv], [self streamNote:tv]);

        if ([self playerHasAdaptiveStreams:tv]) {
            NSLog(@"[YouTube/Плеер] Потоки от TVHTML5");

            [self setStreamUserAgent:YTTvUserAgent binding:[self sessionBinding]];

            return tv;
        }

        if ([self playerHasStreams:tv]) {
            NSLog(@"[YouTube/Плеер] У TVHTML5 только склеенный поток — придержим");

            fallback = tv;
            fallbackAgent = YTTvUserAgent;
        }

        /**
         * Тот же запрос, но от имени старой версии TV-клиента.
         *
         * Подачу через SABR раскатывают по версиям: свежий клиент
         * получает два десятка дорожек без единого адреса, тогда как
         * версии до раскатки отвечают по-старому — готовыми ссылками.
         * Стоит это одного запроса и делается лишь тогда, когда свежая
         * версия ответила одним SABR.
         */
        NSDictionary *legacy = [self fetchTvPlayer:videoId version:YTTvLegacyVersion];

        NSLog(@"[YouTube/Плеер] TVHTML5 версии %@: %@ (%@)", YTTvLegacyVersion,
              [self playabilityReason:legacy], [self streamNote:legacy]);

        if ([self playerHasAdaptiveStreams:legacy]) {
            NSLog(@"[YouTube/Плеер] Потоки от TVHTML5 старой версии");

            [self setStreamUserAgent:YTTvUserAgent binding:[self sessionBinding]];

            return legacy;
        }

        if (fallback == nil && [self playerHasStreams:legacy]) {
            fallback = legacy;
            fallbackAgent = YTTvUserAgent;
        }
    }

    /**
     * WEB под веб-сессией — уже после ANDROID_VR, а не до него.
     *
     * Поначалу он стоял первым: раз сессия снимает стену, пусть и
     * спрашивает. На живом ответе выяснилось, что снимать-то снимает,
     * а играть нечего — WEB присылает дорожки без адресов и ждёт подачи
     * через SABR. То есть каждый ролик начинался с запроса, который
     * заведомо ничего не даёт.
     *
     * Стену при этом снимает не сам запрос, а куки: они уходят с любым
     * нашим обращением к youtube.com, в том числе от ANDROID_VR, —
     * NSURLConnection подставляет их из общего хранилища сам. Поэтому
     * порядок теперь обычный, а WEB остался на конце: вдруг у какого-то
     * ролика адреса всё же будут.
     */
    if ([YTWebAuth isSignedIn]) {
        NSMutableDictionary *body = [NSMutableDictionary dictionary];

        [body setObject:videoId forKey:@"videoId"];
        [body setObject:[NSNumber numberWithBool:YES] forKey:@"contentCheckOk"];
        [body setObject:[NSNumber numberWithBool:YES] forKey:@"racyCheckOk"];

        [body setObject:[NSDictionary dictionaryWithObject:
            [NSDictionary dictionaryWithObject:@"HTML5_PREF_WANTS"
                                        forKey:@"html5Preference"]
                                                    forKey:@"contentPlaybackContext"]
                 forKey:@"playbackContext"];

        NSDictionary *web = [self post:@"player"
                                  body:body
                                client:@"WEB"
                             authorize:NO
                                   ttl:0];

        [self captureVisitorData:web];

        NSLog(@"[YouTube/Плеер] WEB с веб-сессией: %@ (%@)",
              [self playabilityReason:web], [self streamNote:web]);

        if ([self playerHasAdaptiveStreams:web]) {
            NSLog(@"[YouTube/Плеер] Потоки от WEB с веб-сессией");

            [self setStreamUserAgent:YTWebUserAgent binding:[self sessionBinding]];

            return web;
        }

        /**
         * Есть только склеенный поток — придержим его и пойдём дальше.
         *
         * Раньше цепочка на этом кончалась, и до ответа IOS-клиента,
         * добытого в самом начале, дело не доходило вовсе. А у WEB-адресов
         * есть своя беда: в них параметр `n`, который полагается
         * расшифровывать кодом из `base.js`, и раздача отбивает
         * нерасшифрованный отказом 403. У IOS такого нет.
         */
        if ([self playerHasStreams:web]) {
            NSLog(@"[YouTube/Плеер] У WEB только склеенный поток — придержим");

            fallback = web;
            fallbackAgent = YTWebUserAgent;
        }

        /**
         * Отдельная строка про случай «ответ удачный, а играть нечего»:
         * иначе по журналу не отличить отказ от подачи через SABR.
         */
        NSDictionary *streaming = [YTJson objectIn:web key:@"streamingData"];

        if (streaming != nil) {
            NSLog(@"[YouTube/Плеер] WEB ответил без адресов (дорожек %lu, "
                  @"подача через SABR) — идём дальше",
                  (unsigned long)[[YTJson arrayIn:streaming key:@"adaptiveFormats"] count]);
        } else {
            NSLog(@"[YouTube/Плеер] WEB с веб-сессией без потоков (%@)",
                  [self playabilityReason:web]);
        }
    }


    /**
     * Последний ход — ответ IOS-клиента. Стену анти-бота он проходит чаще,
     * потому что и был первым запросом сеанса; в нём есть и обычные дорожки,
     * и `hlsManifestUrl`, который плеер играет напрямую.
     */
    NSLog(@"[YouTube/Плеер] IOS-клиент: %@ (%@)",
          [self playabilityReason:primary], [self streamNote:primary]);

    if ([self playerHasStreams:primary]) {
        NSLog(@"[YouTube/Плеер] Берём потоки у IOS-клиента");

        /**
         * Привязки нет: IOS-клиент не просил токена и не слал
         * `visitorData`, так что его адресам приписывать нечего.
         */
        [self setStreamUserAgent:YTIosUserAgent binding:nil];

        return primary;
    }

    /**
     * Тот же IOS-клиент, но с учётной записью.
     *
     * Гостя стена заворачивает через раз, а за токеном стоит настоящий
     * вход — с ним проходят и TVHTML5, и WEB. Отличие в том, что IOS
     * единственный отдаёт раздельные дорожки с готовыми адресами:
     * у остальных подача через SABR, и играть там нечего.
     */
    if ([YTAuth isSignedIn]) {
        NSDictionary *signedIn = [self iosPlayerResponse:videoId authorize:YES];

        NSLog(@"[YouTube/Плеер] IOS с учётной записью: %@ (%@)",
              [self playabilityReason:signedIn], [self streamNote:signedIn]);

        if ([self playerHasStreams:signedIn]) {
            NSLog(@"[YouTube/Плеер] Берём потоки у IOS с учётной записью");

            [self setStreamUserAgent:YTIosUserAgent binding:nil];

            return signedIn;
        }
    }

    if (fallback != nil) {
        NSLog(@"[YouTube/Плеер] Играем придержанный склеенный поток");

        [self setStreamUserAgent:fallbackAgent binding:[self sessionBinding]];

        return fallback;
    }

    /**
     * И совсем последний ход — готовый HLS от IOS-клиента.
     *
     * Ради него в оригинале и шлётся iOS-овский User-Agent: «for best chance
     * of getting hlsManifestUrl». Разбирать там нечего — это обычный
     * плейлист, который AVPlayer играет сам, без прокси; качество выбирает
     * он же. Хуже, чем свой демуксер, только тем, что выбор высоты уходит
     * из наших рук, — зато играет там, где ANDROID_VR упёрся в анти-бота.
     */
    if ([YTJson textIn:[YTJson objectIn:primary key:@"streamingData"]
                   key:@"hlsManifestUrl"] != nil) {
        NSLog(@"[YouTube/Плеер] Потоков нет, но есть готовый HLS от IOS-клиента");

        return primary;
    }

    return retry != nil ? retry : json;
}

/**
 * `/player` под TV-клиентом с токеном учётной записи.
 *
 * Порт запроса из `ReportWatchHistoryAsync`: там он сделан ради ссылок
 * учёта просмотра, но запрос это обыкновенный, и потоки в ответе те же.
 *
 * Смысл его здесь в том, что стену «подтвердите, что вы не бот» проходит
 * не всякий клиент, а тот, за кем стоит настоящий вход. Анонимные —
 * IOS, ANDROID_VR, WEB без кук — упираются в неё все до одного, и наш
 * PO-токен им не помогает: он выдан веб-BotGuard'ом и годится только
 * клиентам веб-семьи, к которой TV относится, а Android с его
 * собственной аттестацией — нет.
 *
 * `signatureTimestamp` обязателен: без него сервер отвечает «страницу
 * надо перезагрузить». Число добывается один раз и живёт в настройках.
 */
+ (NSDictionary *)fetchTvPlayer:(NSString *)videoId {
    return [self fetchTvPlayer:videoId version:nil reloadToken:nil];
}

+ (NSDictionary *)fetchTvPlayer:(NSString *)videoId version:(NSString *)version {
    return [self fetchTvPlayer:videoId version:version reloadToken:nil];
}

+ (NSDictionary *)tvPlayerResponse:(NSString *)videoId reloadToken:(NSString *)token {
    if ([token length] == 0) {
        return nil;
    }

    return [self fetchTvPlayer:videoId version:nil reloadToken:token];
}

+ (NSDictionary *)refreshedPlayerResponse:(NSString *)videoId
                              reloadToken:(NSString *)token {
    if ([videoId length] == 0) {
        return nil;
    }

    /**
     * Спрашиваем тем же клиентом, чей ответ обновляем.
     *
     * Выбор здесь повторяет `playerResponse:` слово в слово, и это не
     * лишняя строгость: подача выдана под сессию клиента. Пока мы ходили
     * за обновлением к TV-клиенту всегда, у вошедших всё сходилось,
     * а у остальных приходил отказ в один килобайт — «в свежем ответе
     * нет адреса» — и просмотр вставал на месте, хотя лечился одним
     * запросом к ANDROID_VR.
     */
    if ([YTSettings delivery] == YTDeliverySabr &&
        ([YTAuth isSignedIn] || [YTWebAuth isSignedIn])) {
        NSDictionary *tv = [self fetchTvPlayer:videoId version:nil reloadToken:token];

        if ([YTJson textIn:[YTJson objectIn:tv key:@"streamingData"]
                       key:@"serverAbrStreamingUrl"] != nil) {
            return tv;
        }

        NSLog(@"[YouTube/Плеер] TVHTML5 обновиться не дал (%@) — спросим ANDROID_VR",
              [self playabilityReason:tv]);
    }

    return [self fetchAndroidVrPlayer:videoId reloadToken:token];
}

+ (NSDictionary *)fetchTvPlayer:(NSString *)videoId
                        version:(NSString *)version
                    reloadToken:(NSString *)token {
    YTVersionOverride = [version copy];

    NSMutableDictionary *context = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        @"HTML5_PREF_WANTS", @"html5Preference",
        nil];

    NSInteger sts = [YTPlayerJs signatureTimestamp];

    if (sts > 0) {
        [context setObject:[NSNumber numberWithInteger:sts] forKey:@"signatureTimestamp"];
    }

    NSMutableDictionary *playback = [NSMutableDictionary dictionaryWithObject:
        context forKey:@"contentPlaybackContext"];

    /**
     * Токен перезапроса, если подача его просила.
     *
     * Кладётся в `playbackContext` рядом с обычным содержимым, и по нему
     * сервер отдаёт свежие адрес подачи и настройки — то самое, чего
     * ему не хватало, когда он отвечал «обнови ответ».
     */
    if ([token length] > 0) {
        [playback setObject:[NSDictionary dictionaryWithObject:
            [NSDictionary dictionaryWithObject:token forKey:@"token"]
                                                        forKey:@"reloadPlaybackParams"]
                     forKey:@"reloadPlaybackContext"];
    }

    NSMutableDictionary *body = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        videoId, @"videoId",
        [NSNumber numberWithBool:YES], @"contentCheckOk",
        [NSNumber numberWithBool:YES], @"racyCheckOk",
        playback, @"playbackContext",
        nil];

    // Метка показа и в `/player` — у браузера она стоит в теле запроса.
    [body setObject:[self playbackNonceForVideo:videoId] forKey:@"cpn"];

    NSString *poToken = [[YTPoToken shared] tokenFor:[self sessionBinding]];

    if ([poToken length] > 0) {
        [body setObject:[NSDictionary dictionaryWithObject:poToken forKey:@"poToken"]
                 forKey:@"serviceIntegrityDimensions"];
    }

    NSDictionary *json = [self post:@"player" body:body client:@"TVHTML5" authorize:YES ttl:0];

    YTVersionOverride = nil;

    return json;
}

+ (NSDictionary *)fetchAndroidVrPlayer:(NSString *)videoId {
    return [self fetchAndroidVrPlayer:videoId reloadToken:nil];
}

+ (NSDictionary *)fetchAndroidVrPlayer:(NSString *)videoId
                           reloadToken:(NSString *)token {
    NSString *visitorData = [self sessionVisitorData:videoId];

    NSMutableDictionary *client = [NSMutableDictionary dictionary];

    [client setObject:@"ANDROID_VR" forKey:@"clientName"];
    [client setObject:YTAndroidVrVersion forKey:@"clientVersion"];
    [client setObject:@"Oculus" forKey:@"deviceMake"];
    [client setObject:@"Quest 3" forKey:@"deviceModel"];
    [client setObject:[NSNumber numberWithInt:32] forKey:@"androidSdkVersion"];
    [client setObject:@"Android" forKey:@"osName"];
    [client setObject:@"12L" forKey:@"osVersion"];
    [client setObject:@"MOBILE" forKey:@"platform"];
    [client setObject:[self hl] forKey:@"hl"];
    [client setObject:[self gl] forKey:@"gl"];

    if ([visitorData length] > 0) {
        [client setObject:visitorData forKey:@"visitorData"];
    }

    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        [NSDictionary dictionaryWithObject:client forKey:@"client"], @"context",
        videoId, @"videoId",
        [NSNumber numberWithBool:YES], @"contentCheckOk",
        [NSNumber numberWithBool:YES], @"racyCheckOk",
        nil];

    /**
     * Токен перезапроса, если подача его просила.
     *
     * Кладётся так же, как у TV-клиента: поле общее для всех клиентов,
     * от имени которого спрашивать — дело спрашивающего. А спрашивать
     * надо именно тем клиентом, чей ответ мы обновляем: подача привязана
     * к сессии, и TV-клиент без входа отвечает на такую просьбу отказом
     * в один килобайт.
     */
    if ([token length] > 0) {
        [payload setObject:[NSDictionary dictionaryWithObject:
            [NSDictionary dictionaryWithObject:
                [NSDictionary dictionaryWithObject:token forKey:@"token"]
                    forKey:@"reloadPlaybackParams"]
                forKey:@"reloadPlaybackContext"]
                    forKey:@"playbackContext"];
    }

    /**
     * PO-токена здесь нет — и это не упущение.
     *
     * Наш токен чеканит веб-BotGuard, и годится он только клиентам
     * веб-семьи: WEB, MWEB, TVHTML5. У Android своя аттестация
     * (DroidGuard), запустить которую в браузере нечем, и веб-токен
     * этот клиент не признаёт: три прогона подряд с исправным токеном
     * при трёх разных привязках дали один и тот же `LOGIN_REQUIRED`.
     *
     * В оригинале его тут тоже нет — там об этом сказано прямо:
     * «no signature cipher, no &n=, no Po token».
     */
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];

    [headers setObject:YTAndroidVrUserAgent forKey:@"User-Agent"];
    [headers setObject:@"28" forKey:@"X-YouTube-Client-Name"];
    [headers setObject:YTAndroidVrVersion forKey:@"X-YouTube-Client-Version"];

    if ([visitorData length] > 0) {
        [headers setObject:visitorData forKey:@"X-Goog-Visitor-Id"];
    }

    return [self postPlayerPayload:payload headers:headers];
}

/**
 * Ответ `/player` от имени шлема Apple Vision Pro.
 *
 * Отличается от ANDROID_VR только тем, кем мы представляемся, — и этим
 * решает главную беду безымянного просмотра: сессия не кончается на
 * шестидесятой секунде. Ни PO-токена, ни входа не просит, адреса в ответе
 * готовые, подача в нём тоже есть.
 */
+ (NSDictionary *)fetchVisionPlayer:(NSString *)videoId
                        reloadToken:(NSString *)token {
    NSString *visitorData = [self sessionVisitorData:videoId];

    NSMutableDictionary *client = [NSMutableDictionary dictionary];

    [client setObject:@"VISIONOS" forKey:@"clientName"];
    [client setObject:YTVisionVersion forKey:@"clientVersion"];
    [client setObject:@"Apple" forKey:@"deviceMake"];
    [client setObject:@"RealityDevice14,1" forKey:@"deviceModel"];
    [client setObject:@"visionOS" forKey:@"osName"];
    [client setObject:@"1.0.2.21O209" forKey:@"osVersion"];
    [client setObject:YTVisionUserAgent forKey:@"userAgent"];
    [client setObject:[self hl] forKey:@"hl"];
    [client setObject:[self gl] forKey:@"gl"];

    if ([visitorData length] > 0) {
        [client setObject:visitorData forKey:@"visitorData"];
    }

    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        [NSDictionary dictionaryWithObject:client forKey:@"client"], @"context",
        videoId, @"videoId",
        [NSNumber numberWithBool:YES], @"contentCheckOk",
        [NSNumber numberWithBool:YES], @"racyCheckOk",
        nil];

    if ([token length] > 0) {
        [payload setObject:[NSDictionary dictionaryWithObject:
            [NSDictionary dictionaryWithObject:
                [NSDictionary dictionaryWithObject:token forKey:@"token"]
                    forKey:@"reloadPlaybackParams"]
                forKey:@"reloadPlaybackContext"]
                    forKey:@"playbackContext"];
    }

    NSMutableDictionary *headers = [NSMutableDictionary dictionary];

    [headers setObject:YTVisionUserAgent forKey:@"User-Agent"];
    [headers setObject:@"101" forKey:@"X-YouTube-Client-Name"];
    [headers setObject:YTVisionVersion forKey:@"X-YouTube-Client-Version"];

    if ([visitorData length] > 0) {
        [headers setObject:visitorData forKey:@"X-Goog-Visitor-Id"];
    }

    return [self postPlayerPayload:payload headers:headers];
}

/**
 * POST на `/player` без ключа InnerTube и без нашего общего построителя
 * контекста: тело здесь собрано целиком вызывающим, потому что клиент
 * `/player` не совпадает ни с одним из тех, какими мы ходим за лентой.
 */
+ (NSDictionary *)postPlayerPayload:(NSDictionary *)payload headers:(NSDictionary *)headers {
    NSMutableURLRequest *request =
        YTRequest(@"https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
                  NSURLRequestReloadIgnoringLocalCacheData, 25.0);

    if (request == nil) {
        return nil;
    }

    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:[self hl] forHTTPHeaderField:@"Accept-Language"];
    [request setValue:@"https://www.youtube.com" forHTTPHeaderField:@"Origin"];

    /**
     * Этим ходом идут IOS, ANDROID_VR и затравка `visitorData` — клиенты,
     * которым сеанс аккаунта не положен вовсе. Куки к ним не прикладываем:
     * именно они и превращали ответ в «подтвердите, что вы не бот».
     */
    [request setHTTPShouldHandleCookies:NO];

    for (NSString *name in headers) {
        [request setValue:[headers objectForKey:name] forHTTPHeaderField:name];
    }

    [request setHTTPBody:[YTJson encode:payload]];

    // Ответ не кешируем: адреса потоков подписаны на срок и к следующему
    // открытию ролика уже протухнут.
    YTHttpResponse *response = [YTHttp send:request bodyLimit:4 * 1024 * 1024 caching:NO];

    if (![response isSuccessful]) {
        NSLog(@"[YouTube/Плеер] /player: код %ld, %@",
              (long)response.statusCode,
              [response.error localizedDescription] ?: @"без ошибки");
        return nil;
    }

    return [YTJson parse:response.body];
}

#pragma mark Shorts

/**
 * Один заход за лентой Shorts определённым клиентом.
 *
 * Тело у seedless-запроса своё: `inputType`, `params` и
 * `disablePlayerResponse` — порт `BuildSeedlessShortsPayload`. У продолжения
 * тело другое, из одного `sequenceParams`.
 */
+ (NSDictionary *)shortsAttempt:(NSString *)sequence
                         client:(NSString *)client
                      authorize:(BOOL)authorize {
    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    NSString *endpoint;

    /**
     * Тело — порт `BuildSeedlessShortsPayload` и `BuildShortsSequencePayload`.
     * У первой страницы `inputType`, `params` и `disablePlayerResponse`,
     * у продолжения — один `sequenceParams`.
     */
    if ([sequence length] > 0) {
        endpoint = @"reel/reel_watch_sequence";

        [body setObject:sequence forKey:@"sequenceParams"];
    } else {
        endpoint = @"reel/reel_item_watch";

        [body setObject:@"REEL_WATCH_INPUT_TYPE_SEEDLESS" forKey:@"inputType"];
        [body setObject:@"CA8%3D" forKey:@"params"];
        [body setObject:[NSNumber numberWithBool:YES] forKey:@"disablePlayerResponse"];
    }

    return [self shortsPost:endpoint body:body client:client authorize:authorize];
}

/**
 * Запрос к поверхности Shorts — порт `PostInnertubeJsonAsync`.
 *
 * У reel-точек и у `/player`, который спрашивают ради Shorts, всё своё:
 * версии клиентов, номер TV-клиента (7, а не 85), `X-Goog-Visitor-Id`
 * у веб-клиентов, свои `Origin` и `Referer`, адрес без `prettyPrint`.
 * Общий `post:` шлёт другое, и с ним эти точки отвечают отказом.
 */
+ (NSDictionary *)shortsPost:(NSString *)endpoint
                        body:(NSDictionary *)body
                      client:(NSString *)client
                   authorize:(BOOL)authorize {
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:body];

    /**
     * Контекст клиента у reel-запросов свой — `BuildShortsClientJson`:
     * у TV к обычному набору добавляется `clientFormFactor`, у MWEB —
     * платформа MOBILE, и версии тоже свои.
     */
    NSMutableDictionary *context = [NSMutableDictionary dictionary];

    [context setObject:client forKey:@"clientName"];
    [context setObject:[self hl] forKey:@"hl"];
    [context setObject:[self gl] forKey:@"gl"];

    NSString *version;

    if ([client isEqualToString:@"TVHTML5"]) {
        version = YTTvPlayerVersion;

        [context setObject:@"TV" forKey:@"platform"];
        [context setObject:@"UNKNOWN_FORM_FACTOR" forKey:@"clientFormFactor"];
    } else if ([client isEqualToString:@"MWEB"]) {
        version = YTShortsMwebVersion;

        [context setObject:@"MOBILE" forKey:@"platform"];
    } else if ([client isEqualToString:@"ANDROID"]) {
        // `BuildAndroidClientJson`: имя, версия, androidSdkVersion, hl и gl —
        // и больше ничего. Лишние поля здесь тоже расхождение.
        version = YTShortsAndroidVersion;

        [context setObject:[NSNumber numberWithInt:30] forKey:@"androidSdkVersion"];
    } else {
        version = YTShortsWebVersion;
    }

    [context setObject:version forKey:@"clientVersion"];

    NSMutableDictionary *whole =
        [NSMutableDictionary dictionaryWithObject:context forKey:@"client"];

    /**
     * От чьего имени просим — как и во всех прочих запросах.
     *
     * Контекст здесь собирается свой, мимо общего построителя, и потому
     * выбранный канал сюда не попадал вовсе: человек переключался, а
     * лента Shorts оставалась от того канала, какой выберет сервер.
     */
    NSString *behalf = [self activeAccountPage];

    if ([behalf length] > 0) {
        [whole setObject:[NSDictionary dictionaryWithObject:behalf
                                                     forKey:@"onBehalfOfUser"]
                  forKey:@"user"];
    }

    [payload setObject:whole forKey:@"context"];

    /**
     * Адрес без `prettyPrint`: в `PostInnertubeJsonAsync` его нет, только ключ.
     */
    NSString *url = [NSString stringWithFormat:
        @"https://www.youtube.com/youtubei/v1/%@?key=%@", endpoint, YTInnertubeKey];

    NSMutableURLRequest *request =
        YTRequest(url, NSURLRequestUseProtocolCachePolicy, 25.0);

    if (request == nil) {
        return nil;
    }

    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    if (authorize) {
        NSString *token = [YTAuth accessToken];

        if ([token length] > 0) {
            [request setValue:[@"Bearer " stringByAppendingString:token]
           forHTTPHeaderField:@"Authorization"];
        }
    }

    NSString *language = [NSString stringWithFormat:@"%@,%@;q=0.9", [self hl], [self hl]];

    [request setValue:language forHTTPHeaderField:@"Accept-Language"];
    [request setValue:version forHTTPHeaderField:@"X-YouTube-Client-Version"];

    /**
     * Заголовки для каждого клиента — из `PostInnertubeJsonAsync`, дословно.
     *
     * Здесь важна каждая мелочь, и особенно номер TV-клиента: у reel-запросов
     * это **7**, а не 85, как у `browse`. В оригинале рядом с этим местом
     * стоит объяснение: с чужим номером тело TVHTML5 противоречит заголовкам,
     * и запрос отвечает отказом. `X-Goog-Visitor-Id` у веб-клиентов тоже
     * обязателен — без него reel-точки не отвечают ничем полезным.
     */
    if ([client isEqualToString:@"ANDROID"]) {
        // У ANDROID заголовков всего три: номер, версия и User-Agent.
        // Ни visitor-id, ни Origin с Referer там нет.
        [request setValue:@"3" forHTTPHeaderField:@"X-YouTube-Client-Name"];
        [request setValue:[NSString stringWithFormat:
            @"com.google.android.youtube/%@ (Linux; U; Android 11) gzip",
            YTShortsAndroidVersion]
       forHTTPHeaderField:@"User-Agent"];
    } else if ([client isEqualToString:@"TVHTML5"]) {
        [request setValue:@"7" forHTTPHeaderField:@"X-YouTube-Client-Name"];
        [request setValue:YTTvUserAgent forHTTPHeaderField:@"User-Agent"];
        [request setValue:@"https://www.youtube.com" forHTTPHeaderField:@"Origin"];
        [request setValue:@"https://www.youtube.com/tv" forHTTPHeaderField:@"Referer"];
    } else if ([client isEqualToString:@"MWEB"]) {
        [request setValue:@"2" forHTTPHeaderField:@"X-YouTube-Client-Name"];
        [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
                          @"AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 "
                          @"Mobile/15E148 Safari/604.1"
       forHTTPHeaderField:@"User-Agent"];
        [request setValue:YTFallbackVisitorData forHTTPHeaderField:@"X-Goog-Visitor-Id"];
        [request setValue:@"https://m.youtube.com" forHTTPHeaderField:@"Origin"];
        [request setValue:@"https://m.youtube.com/shorts/" forHTTPHeaderField:@"Referer"];
    } else {
        [request setValue:@"1" forHTTPHeaderField:@"X-YouTube-Client-Name"];
        [request setValue:YTWebUserAgent forHTTPHeaderField:@"User-Agent"];
        [request setValue:YTFallbackVisitorData forHTTPHeaderField:@"X-Goog-Visitor-Id"];
        [request setValue:@"https://www.youtube.com" forHTTPHeaderField:@"Origin"];
        [request setValue:@"https://www.youtube.com/shorts/" forHTTPHeaderField:@"Referer"];
    }

    [request setHTTPBody:[YTJson encode:payload]];

    NSLog(@"[YouTube/Shorts] → %@ (%@%@)", endpoint, client, authorize ? @", с токеном" : @"");

    YTHttpResponse *response = [YTHttp send:request bodyLimit:12 * 1024 * 1024];

    if (![response isSuccessful]) {
        NSLog(@"[YouTube/Shorts] %@ (%@): код %ld", endpoint, client,
              (long)response.statusCode);

        return nil;
    }

    return [YTJson parse:response.body];
}

/**
 * Есть ли в ответе хоть один ролик.
 *
 * Проверять надо именно это, а не «ответ пришёл». Отказ поверхности reel
 * приезжает таким же разобранным словарём, как и лента, и перебор
 * клиентов на нём останавливался: первый же ответивший считался удачей,
 * хотя роликов в нём не было ни одного.
 */
+ (BOOL)shortsUsable:(NSDictionary *)json {
    if (json == nil) {
        return NO;
    }

    return [[YTJson findAll:@"reelWatchEndpoint" in:json limit:60000] count] > 0;
}

/**
 * Кто отдал прошлую страницу ленты Shorts и с токеном ли.
 *
 * Держится между страницами затем, что `sequenceParams` выдан **тем**
 * клиентом: продолжение чужого перечня — уже не тот перечень.
 */
static NSString *YTShortsClient = nil;
static BOOL YTShortsAuthorized = NO;

+ (NSDictionary *)shorts:(NSString *)sequence {
    BOOL first = ([sequence length] == 0);

    // Новая лента — и клиента выбираем заново.
    if (first) {
        YTShortsClient = nil;
        YTShortsAuthorized = NO;
    }

    NSDictionary *json = nil;
    NSString *served = nil;
    BOOL servedAuth = NO;

    /**
     * Продолжает тот, кто начал.
     *
     * Прежде каждая страница выбирала клиента заново, с самого начала
     * перечня. Стоило TV-клиенту разок промолчать посреди ленты — и
     * следующая страница приезжала от другого, а то и вовсе без токена.
     * Со стороны это ровно то, на что жаловались: несколько роликов
     * своих, а дальше как будто случайные.
     */
    if (!first && YTShortsClient != nil) {
        json = [self shortsAttempt:sequence
                            client:YTShortsClient
                         authorize:YTShortsAuthorized];

        if ([self shortsUsable:json]) {
            served = YTShortsClient;
            servedAuth = YTShortsAuthorized;
        } else {
            json = nil;
        }
    }

    /**
     * Порядок перебора — из `ShortsAuthClients`. Токен выдан TV-клиенту,
     * и какой из reel-клиентов его примет, заранее неизвестно: тело обязано
     * совпадать с заголовками, поэтому каждый пробуется целиком.
     */
    if (json == nil && [YTAuth isSignedIn]) {
        NSArray *clients = [NSArray arrayWithObjects:@"TVHTML5", @"MWEB", @"WEB", nil];

        for (NSString *client in clients) {
            NSDictionary *attempt = [self shortsAttempt:sequence
                                                 client:client
                                              authorize:YES];

            if ([self shortsUsable:attempt]) {
                json = attempt;
                served = client;
                servedAuth = YES;

                break;
            }
        }
    }

    /**
     * Без токена — только у гостя и только на первой странице.
     *
     * Гостю иначе ленты не видать вовсе, а первой странице простительно:
     * лучше общая лента, чем пустой раздел. А вот подменять учётную
     * запись **посреди** ленты нельзя: человек листает своё, и вдруг
     * пошло чужое — без единого слова о том, что случилось. Прежде
     * так и было.
     */
    if (json == nil && (first || ![YTAuth isSignedIn])) {
        NSDictionary *attempt = [self shortsAttempt:sequence
                                             client:@"WEB"
                                          authorize:NO];

        if ([self shortsUsable:attempt]) {
            json = attempt;
            served = @"WEB";
            servedAuth = NO;

            if ([YTAuth isSignedIn]) {
                NSLog(@"[YouTube/Shorts] Ни один клиент не принял токен — "
                      @"лента будет общей, не по учётной записи");
            }
        }
    }

    if (json == nil) {
        NSLog(@"[YouTube/Shorts] Продолжения не дал никто%@",
              (!first && [YTAuth isSignedIn])
                  ? @" — чужую ленту вместо своей не подставляем"
                  : @"");

        return nil;
    }

    YTShortsClient = served;
    YTShortsAuthorized = servedAuth;

    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    /**
     * Ролики лежат за `reelWatchEndpoint` — и в `entries`, и, у части
     * ответов, прямо в корне под `replacementEndpoint`. Поиск по всему
     * дереву находит оба случая, как и `ExtractShortsEntries` с его
     * запасным обходом.
     */
    /**
     * Рекламу в ленту не пускаем.
     *
     * Она приходит теми же `reelWatchEndpoint`, но лежит внутри
     * рекламных обёрток. Собираем их отдельно, вынимаем оттуда номера
     * роликов — и эти номера в ленту не берём вовсе, чтобы человеку не
     * пришлось их пролистывать.
     */
    NSMutableSet *ads = [NSMutableSet set];

    NSArray *adSlots = [YTJson findAllOfAny:[NSArray arrayWithObjects:
                                                @"adSlotRenderer",
                                                @"adPlacementRenderer",
                                                @"instreamVideoAdRenderer",
                                                @"reelPlayerAdRenderer",
                                                @"adVideoRenderer",
                                                @"linearAdSequenceRenderer",
                                                @"displayAdRenderer",
                                                @"adBreakServiceRenderer", nil]
                                         in:json limit:60000];

    for (NSDictionary *slot in adSlots) {
        for (NSDictionary *inner in [YTJson findAll:@"reelWatchEndpoint"
                                                 in:slot limit:4000]) {
            NSString *adVideo = [YTJson textIn:inner key:@"videoId"];

            if ([adVideo length] == 11) {
                [ads addObject:adVideo];
            }
        }
    }

    if ([ads count] > 0) {
        NSLog(@"[YouTube/Shorts] Рекламных роликов в ответе: %lu — пропускаем",
              (unsigned long)[ads count]);
    }

    NSArray *endpoints = [YTJson findAll:@"reelWatchEndpoint" in:json limit:60000];

    for (NSDictionary *endpoint in endpoints) {
        NSString *videoId = [YTJson textIn:endpoint key:@"videoId"];

        if ([videoId length] != 11 || [seen containsObject:videoId]
            || [ads containsObject:videoId]) {
            continue;
        }

        /**
         * Второй признак рекламы — в самой ссылке.
         *
         * У рекламного ролика в `reelWatchEndpoint` лежат служебные поля
         * для рекламной отчётности, которых у обычного нет. Обёртку мы
         * ловим не всегда — их названия меняются, — а эти поля лежат
         * прямо там, куда мы и так смотрим.
         */
        if ([endpoint objectForKey:@"adClientParams"] != nil
            || [endpoint objectForKey:@"adsControlFlowOverrides"] != nil
            || [YTJson boolIn:endpoint key:@"isAd"]) {
            [ads addObject:videoId];

            continue;
        }

        [seen addObject:videoId];

        YTVideoItem *item = [[YTVideoItem alloc] init];

        item.videoId = videoId;
        item.title = @"Shorts";

        // Превью у Shorts в ответе нет: `BuildHqThumbnailUrl` собирает
        // его из идентификатора, и здесь то же самое.
        item.thumbnail = [NSString stringWithFormat:
            @"https://i.ytimg.com/vi/%@/hqdefault.jpg", videoId];

        /**
         * Подписи в ленте reel есть не всегда: у seedless-ответа их обычно
         * нет вовсе, и тогда они приезжают позже, вместе с потоком, из
         * `videoDetails`. Но если оверлей всё же прислали — берём оттуда,
         * как `ApplyShortsUiMetadata` в оригинале.
         */
        NSDictionary *overlay = [YTJson findFirst:@"reelPlayerOverlayRenderer"
                                               in:endpoint limit:2000];

        NSString *title = [YTJson renderedText:overlay key:@"reelTitleText"];

        if ([title length] > 0) {
            item.title = title;
        }

        NSDictionary *header = [YTJson findFirst:@"reelPlayerHeaderRenderer"
                                              in:endpoint limit:2000];

        NSString *author = [YTJson renderedText:header key:@"channelTitleText"];

        if ([author length] > 0) {
            item.channelTitle = author;
        }

        item.channelThumbnail = [YTJson thumbnailIn:header
                                                key:@"channelThumbnail"
                                           minWidth:88];

        [items addObject:item];
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    [result setObject:items forKey:@"items"];

    NSString *token = [YTJson textIn:json key:@"sequenceContinuation"];

    if (token == nil) {
        NSDictionary *command = [YTJson findFirst:@"continuationCommand" in:json limit:60000];

        token = [YTJson textIn:command key:@"token"];
    }

    if (token != nil) {
        [result setObject:token forKey:@"sequence"];
    }

    /**
     * Поимённый след ленты: без него рекламу в ней не опознать.
     *
     * Реклама играет не через нашу подачу и в журнале не оставляет ни
     * строки — в журнале 96 это две с половиной минуты тишины между
     * роликами. Зная, что было в ленте по порядку, рекламный ролик можно
     * назвать по номеру и добавить его обёртку в опознание.
     */
    NSMutableString *listed = [NSMutableString string];

    for (YTVideoItem *entry in items) {
        [listed appendFormat:@"%@%@", [listed length] > 0 ? @", " : @"", entry.videoId];
    }

    NSLog(@"[YouTube/Shorts] В ленте по порядку: %@", listed);

    NSLog(@"[YouTube/Shorts] роликов: %lu, отдал %@ (%@), продолжение: %@",
          (unsigned long)[items count], served,
          servedAuth ? @"с токеном" : @"без токена",
          token != nil ? @"есть" : @"нет");

    return result;
}

#pragma mark Аккаунт

/** Имя настройки: выбранный канал переживает перезапуск. */
static NSString *const YTActivePageKey = @"YTActiveAccountPage";

/** Вторая примета того же канала — на случай, если первой сервер не примет. */
static NSString *const YTActiveDatasyncKey = @"YTActiveAccountDatasync";

+ (NSString *)activeAccountPage {
    return [[NSUserDefaults standardUserDefaults] stringForKey:YTActivePageKey];
}

+ (NSString *)identityMark {
    if (![YTAuth isSignedIn]) {
        return @"гость";
    }

    NSString *page = [self activeAccountPage];

    // Канал не выбирали — говорим от того, кого выберет сервер. Это тоже
    // определённое лицо, и от «гостя» оно отличается.
    return [page length] > 0 ? page : @"по умолчанию";
}

+ (NSString *)activeAccountDatasync {
    return [[NSUserDefaults standardUserDefaults] stringForKey:YTActiveDatasyncKey];
}

+ (void)setActiveAccountPage:(NSString *)page {
    [self setActiveAccountPage:page datasync:nil];
}

+ (void)setActiveAccountPage:(NSString *)page datasync:(NSString *)datasync {
    NSUserDefaults *settings = [NSUserDefaults standardUserDefaults];

    if ([page length] > 0) {
        [settings setObject:page forKey:YTActivePageKey];
    } else {
        [settings removeObjectForKey:YTActivePageKey];
    }

    if ([datasync length] > 0) {
        [settings setObject:datasync forKey:YTActiveDatasyncKey];
    } else {
        [settings removeObjectForKey:YTActiveDatasyncKey];
    }

    /**
     * Новый канал — снова с первой приметы.
     *
     * Переход на вторую сделан для **того** канала, которому первая
     * не подошла; у следующего всё может быть иначе, и начинать сразу
     * со второй значило бы чинить то, что не сломано.
     */
    @synchronized ([YTApi class]) {
        YTUseDatasyncMark = NO;
    }

    [self forgetAccounts];

    [settings synchronize];

    /**
     * Ответы, снятые от прежнего канала, больше не годятся: и лента,
     * и подписки, и история у каждого канала свои, а ключом в памяти
     * стоит один адрес.
     */
    [YTHttp dropMemoryCache];

    NSLog(@"[YouTube/Аккаунт] Выбран канал %@", [page length] > 0 ? page : @"по умолчанию");

    /**
     * Оповещаем тем же сигналом, что и о входе.
     *
     * Смена канала для экранов означает ровно то же самое: имя, кружок
     * и всё содержимое теперь другие. Кружок в нижней панели берётся
     * у `accountAvatarUrl`, а тот отдаёт аватар **выбранного** канала —
     * значит достаточно попросить панель перечитать его. Заводить ради
     * этого второй сигнал незачем: получатели у него были бы те же.
     */
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:YTAuthChangedNotification object:nil];
    });
}

/**
 * Кому принадлежит канал — по этому значению сервер и узнаёт, от чьего
 * имени с ним говорят.
 *
 * Лежит оно в служебной части строки списка, и добираться до него по
 * известному пути смысла нет: форма ответа у этой поверхности меняется
 * чаще, чем хотелось бы, а имя поля постоянно. Поэтому просто ищем
 * `pageId` по всему поддереву строки.
 */
/**
 * Выкладывает ответ списка каналов в журнал — один раз за запуск.
 *
 * Заведено затем, что метка владельца не нашлась ни под одним из имён,
 * которые мы перебирали. Гадать дальше нечем: надо посмотреть, что
 * сервер присылает на самом деле. Ответ маленький, около пяти килобайт,
 * так что выложить его целиком дешевле, чем ставить очередную догадку.
 *
 * `NSLog` обрезает длинные строки, поэтому режем на куски сами.
 * Один раз за запуск — иначе журнал утонет: список запрашивается
 * по нескольку раз подряд.
 *
 * Внутри — имена ваших каналов и признаки личности. Журнал вы отдаёте
 * сами и сами решаете, что из него убрать.
 */
+ (void)dumpAccountsResponse:(NSDictionary *)json tag:(NSString *)tag {
    /**
     * По разу за запуск на каждого спрошенного: ответов теперь несколько,
     * и один общий замок показал бы только первый — как раз тот, который
     * нам и не подошёл.
     */
    static NSMutableSet *shown = nil;

    @synchronized ([YTApi class]) {
        if (shown == nil) { shown = [NSMutableSet set]; }

        if ([shown containsObject:tag]) { return; }

        [shown addObject:tag];
    }

    if (json == nil) {
        NSLog(@"[YouTube/Аккаунт] %@: ответа нет вовсе", tag);

        return;
    }

    /**
     * Сперва — самое важное в одной строке: есть ли вообще искомое имя
     * где-нибудь в ответе. Если нет, то и искать его незачем, и вопрос
     * сводится к тому, чем сервер помечает личность вместо него.
     */
    NSArray *names = [NSArray arrayWithObjects:
        @"pageId", @"externalChannelId", @"datasyncId", @"identityToken",
        @"obfuscatedGaiaId", @"channelId", @"browseId", nil];

    for (NSString *name in names) {
        NSString *value = [YTJson findString:name in:json limit:200000];

        NSLog(@"[YouTube/Аккаунт] В ответе %@: %@", name,
              [value length] > 0 ? value : @"нет");
    }

    NSData *data = [YTJson encode:json];

    NSString *text = [[NSString alloc] initWithData:data
                                           encoding:NSUTF8StringEncoding];

    NSUInteger step = 700;

    NSLog(@"[YouTube/Аккаунт] Ответ %@ целиком, %lu знаков:", tag,
          (unsigned long)[text length]);

    for (NSUInteger at = 0; at < [text length]; at += step) {
        NSUInteger take = MIN(step, [text length] - at);

        NSLog(@"[YouTube/Аккаунт] %@ %lu| %@", tag, (unsigned long)(at / step),
              [text substringWithRange:NSMakeRange(at, take)]);
    }
}

+ (NSString *)pageIdIn:(NSDictionary *)item {
    /**
     * Чем помечена личность канала — по тому, что сервер реально шлёт.
     *
     * Имени `pageId` в ответе нет вовсе, и это не поломка разбора:
     * `pageId` бывает у бренд-каналов, а здесь профили-персоны одной
     * учётной записи (`REGISTERED_GAIA_SERVICES_IS_YOUTUBE_PERSONA`).
     * У них личность лежит в `selectActiveIdentityEndpoint.supportedTokens`
     * и записана тремя способами сразу:
     *
     *     personaIdToken.personaId        — сам профиль;
     *     accountStateToken.obfuscatedGaiaId — он же, у главного канала;
     *     datasyncIdToken.datasyncIdToken — пара «профиль||владелец».
     *
     * Берём `personaId`: он и есть тот, от чьего имени просят говорить.
     * Нет его — берём `obfuscatedGaiaId`: у главного канала записи
     * с персоной не бывает, а состояние есть всегда.
     *
     * `pageId` оставлен первым на случай бренд-каналов: у них он есть,
     * и он там главнее.
     */
    NSString *page = [YTJson findString:@"pageId" in:item limit:20000];

    if ([page length] > 0) {
        return page;
    }

    page = [YTJson findString:@"personaId" in:item limit:20000];

    if ([page length] > 0) {
        return page;
    }

    return [YTJson findString:@"obfuscatedGaiaId" in:item limit:20000];
}

/**
 * Пара «профиль||владелец» — вторая примета той же личности.
 *
 * Хранится рядом с первой затем, что сервер помечает профиль двумя
 * способами, и какой из них он ждёт обратно, по ответу не видно.
 * Если `onBehalfOfUser` окажется мало, в дело пойдёт эта.
 */
+ (NSString *)datasyncIdIn:(NSDictionary *)item {
    return [YTJson findString:@"datasyncIdToken" in:item limit:20000];
}

/**
 * Каналы из готового ответа — порт `ParseAccountInfoFromAccountsList`,
 * только там берётся один, а здесь весь список.
 *
 * Ответ устроен так: `accountSectionListRenderer` → `accountItemSectionRenderer`
 * → `accountItem` на канал. Личность лежит в `selectActiveIdentityEndpoint`
 * и записана по-разному у разных: у бренд-канала это `pageIdToken.pageId`,
 * у владельца — только `accountStateToken.obfuscatedGaiaId`.
 */
+ (NSArray *)accountsIn:(NSDictionary *)json {
    NSArray *items = [YTJson findAll:@"accountItem" in:json limit:4000];

    NSMutableArray *accounts = [NSMutableArray array];

    for (NSDictionary *item in items) {
        NSString *name = [YTJson renderedText:item key:@"accountName"];

        if ([name length] == 0) {
            continue;
        }

        NSMutableDictionary *account = [NSMutableDictionary dictionary];

        [account setObject:name forKey:@"name"];

        NSString *handle = [YTJson renderedText:item key:@"channelHandle"];

        if (handle == nil) { handle = [YTJson renderedText:item key:@"accountByline"]; }
        if (handle != nil) { [account setObject:handle forKey:@"handle"]; }

        NSString *avatar = [YTJson thumbnailIn:item key:@"accountPhoto" minWidth:88];

        if (avatar != nil) { [account setObject:avatar forKey:@"avatar"]; }

        NSString *page = [self pageIdIn:item];

        NSString *datasync = [self datasyncIdIn:item];

        if (datasync != nil) { [account setObject:datasync forKey:@"datasync"]; }

        if (page != nil) {
            [account setObject:page forKey:@"page"];

            NSLog(@"[YouTube/Аккаунт] «%@»: личность %@%@", name, page,
                  [datasync length] > 0 ? @", пара есть" : @"");
        } else {
            /**
             * Без метки канал показать можно, а переключиться на него —
             * нет. Молчать об этом нельзя: снаружи это выглядит как
             * «выбрал, и ничего не произошло».
             */
            NSLog(@"[YouTube/Аккаунт] У канала «%@» метки владельца нет — "
                  @"переключиться на него не выйдет", name);

            [self dumpAccountsResponse:json tag:@"без метки"];
        }

        NSDictionary *browse = [YTJson findFirst:@"browseEndpoint" in:item limit:600];
        NSString *channelId = [YTJson textIn:browse key:@"browseId"];

        if ([channelId hasPrefix:@"UC"]) {
            [account setObject:channelId forKey:@"channelId"];
        }

        /**
         * Основным оригинал считает тот канал, у которого есть подпись
         * `accountByline` — так в `ParseAccountInfoFromAccountsList`.
         * Порядок в списке приметой не служит: он не определён.
         */
        BOOL primary = ([YTJson objectIn:item key:@"accountByline"] != nil) ||
                       [YTJson boolIn:item key:@"isSelected"];

        [account setObject:[NSNumber numberWithBool:primary] forKey:@"primary"];

        [accounts addObject:account];
    }

    return accounts;
}

/**
 * Что именно перечислять — `accountReadMask` из запроса TV-клиента.
 *
 * Без него сервер отдаёт **одного владельца**, и ответ выходит в килобайт
 * даже у записи с несколькими каналами. Со стороны это неотличимо от
 * «канал и правда один», и мы на это попались: искали причину в подписи
 * и в клиенте, а спрашивали не о том. Телевизор просит поимённо, и мы
 * теперь тоже.
 *
 * `returnFamilyMembersAccounts` снят, как и у него: это не свои каналы,
 * а другие люди в семейной группе, и говорить от их имени нельзя.
 */
+ (NSDictionary *)accountReadMask {
    NSArray *wanted = [NSArray arrayWithObjects:
        @"returnOwner", @"returnBrandAccounts", @"returnPersonaAccounts",
        @"returnFamilyChildAccounts", nil];

    NSMutableDictionary *mask = [NSMutableDictionary dictionary];

    for (NSString *key in wanted) {
        [mask setObject:[NSNumber numberWithBool:YES] forKey:key];
    }

    [mask setObject:[NSNumber numberWithBool:NO]
             forKey:@"returnFamilyMembersAccounts"];

    return [NSDictionary dictionaryWithObject:mask forKey:@"accountReadMask"];
}

/**
 * Разобранный список каналов — один на всех.
 *
 * Кеш ответов у нас есть и работает, но спасает не всегда: спрашивают
 * этот список сразу с полудюжины мест — кружок в панели, страница «Вы»,
 * профиль, меню каналов, — и все они трогаются с места **одновременно**.
 * Пока первый ответ не приехал, в кеше пусто, и остальные честно уходят
 * в сеть за тем же самым. В журнале это видно прямо: тринадцать запросов
 * `accounts_list` за полминуты, половина из них парами в один и тот же
 * миг. На iPhone 4 по сотовой связи это заметно.
 *
 * Поэтому разбор держится здесь, а спрашивает его только один: остальные
 * ждут на замке и получают готовое.
 */
static NSArray *YTAccountsCache = nil;
static NSString *YTAccountsCacheFor = nil;

+ (void)forgetAccounts {
    @synchronized ([YTApi class]) {
        YTAccountsCache = nil;
        YTAccountsCacheFor = nil;
    }
}

+ (NSArray *)accountsList {
    if (![YTAuth isSignedIn]) {
        return [NSArray array];
    }

    /**
     * Замок на весь заход, а не только на чтение.
     *
     * Иначе двое, пришедшие разом, оба увидят пустой кеш и оба пойдут
     * в сеть — то самое, от чего кеш и заводился.
     */
    @synchronized ([YTApi class]) {
        NSString *mark = [self identityMark];

        if (YTAccountsCache != nil && [YTAccountsCacheFor isEqualToString:mark]) {
            return YTAccountsCache;
        }

        NSDictionary *json = [self post:@"account/accounts_list"
                                   body:[self accountReadMask]
                                 client:@"TVHTML5"
                              authorize:YES
                                    ttl:900];

        NSArray *accounts = [self accountsIn:json];

        NSLog(@"[YouTube/Аккаунт] Каналов в записи: %lu",
              (unsigned long)[accounts count]);

        /**
         * Пустой список не запоминаем: это не ответ, а неудача — сеть
         * отказала или ответ не разобрался. Запомнив её, мы бы держали
         * человека без каналов до самого перезапуска.
         */
        if ([accounts count] > 0) {
            YTAccountsCache = accounts;
            YTAccountsCacheFor = [mark copy];
        }

        return accounts;
    }
}

/** Выбранный человеком канал, иначе основной, иначе первый попавшийся. */
+ (NSDictionary *)currentAccount {
    NSArray *accounts = [self accountsList];

    if ([accounts count] == 0) {
        return nil;
    }

    NSString *chosen = [self activeAccountPage];

    if ([chosen length] > 0) {
        for (NSDictionary *account in accounts) {
            if ([[account objectForKey:@"page"] isEqualToString:chosen]) {
                return account;
            }
        }
    }

    for (NSDictionary *account in accounts) {
        if ([[account objectForKey:@"primary"] boolValue]) {
            return account;
        }
    }

    return [accounts objectAtIndex:0];
}

+ (NSString *)accountAvatarUrl {
    if (![YTAuth isSignedIn]) {
        return nil;
    }

    // Своего запроса здесь нет: `currentAccount` спрашивает то же самое,
    // а лишний заход только удваивал `accounts_list` при запуске.
    return [[self currentAccount] objectForKey:@"avatar"];
}

+ (NSDictionary *)accountProfile {
    if (![YTAuth isSignedIn]) {
        return nil;
    }

    /**
     * Берём **выбранный** канал, а не первый попавшийся.
     *
     * Здесь стоял `findFirst:` по всему дереву, а порядок ключей
     * в разобранном JSON не определён вовсе: у записи с несколькими
     * каналами выпадал случайный. У одного из наших так выпал канал
     * YouTube Kids, хотя основным у него совсем другой.
     */
    NSDictionary *account = [self currentAccount];

    if (account == nil) {
        return nil;
    }

    /**
     * Всё нужное — имя, собачка, кружок, канал — уже разобрано в списке;
     * здесь остаётся только отдать выбранную строку.
     *
     * Собачка приходит не у всех: у канала без выбранного адреса её
     * попросту нет. В оригинале строка с собачкой и кнопкой «Смотреть
     * канал» в этом случае прячется целиком — так же и здесь, по
     * отсутствию ключа.
     */
    return [NSDictionary dictionaryWithDictionary:account];
}

+ (NSArray *)subscriptions {
    if (![YTAuth isSignedIn]) {
        return nil;
    }

    NSDictionary *json = [self post:@"browse"
                               body:[NSDictionary dictionaryWithObject:@"FEchannels"
                                                                forKey:@"browseId"]
                             client:@"TVHTML5"
                          authorize:YES
                                ttl:900];

    if (json == nil) {
        return nil;
    }

    NSMutableArray *channels = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    /**
     * Каналы у TV-клиента лежат не в `gridChannelRenderer`, а в `tileRenderer`
     * с `contentType == TILE_CONTENT_TYPE_CHANNEL` — так их и разбирает
     * `ParseSubscribedChannels` в Config.cs. Сетка из `gridChannelRenderer`
     * осталась в вебе; в ответе на `FEchannels` от TVHTML5 её попросту нет,
     * отчего полоса каналов и приходила пустой.
     *
     * Внутри плитки:
     *     contentId                             — идентификатор канала;
     *     metadata.tileMetadataRenderer.title   — название;
     *     header.tileHeaderRenderer.thumbnail   — кружок.
     */
    NSArray *found = [YTJson findAll:@"tileRenderer" in:json limit:200000];

    for (NSDictionary *tile in found) {
        NSString *contentType = [YTJson textIn:tile key:@"contentType"];

        if (![contentType isEqualToString:@"TILE_CONTENT_TYPE_CHANNEL"]) {
            continue;
        }

        NSString *channelId = [YTJson textIn:tile key:@"contentId"];

        if ([channelId length] == 0 || [seen containsObject:channelId]) {
            continue;
        }

        [seen addObject:channelId];

        NSDictionary *metadata = [YTJson objectIn:[YTJson objectIn:tile key:@"metadata"]
                                              key:@"tileMetadataRenderer"];

        NSString *title = [YTJson renderedText:metadata key:@"title"];

        NSDictionary *header = [YTJson objectIn:[YTJson objectIn:tile key:@"header"]
                                            key:@"tileHeaderRenderer"];

        NSString *thumbnail = [YTJson thumbnailIn:header key:@"thumbnail" minWidth:88];

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];

        [entry setObject:channelId forKey:@"channelId"];
        [entry setObject:(title ?: @"") forKey:@"title"];

        if (thumbnail != nil) { [entry setObject:thumbnail forKey:@"thumbnail"]; }

        [channels addObject:entry];
    }

    NSLog(@"[YouTube/Подписки] каналов найдено: %lu", (unsigned long)[channels count]);

    return channels;
}

+ (NSDictionary *)subscriptionsFeed:(NSString *)continuation {
    if (![YTAuth isSignedIn]) {
        return nil;
    }

    NSMutableDictionary *body = [NSMutableDictionary dictionary];

    if ([continuation length] > 0) {
        [body setObject:continuation forKey:@"continuation"];
    } else {
        [body setObject:@"FEsubscriptions" forKey:@"browseId"];
    }

    return [self feedFrom:[self post:@"browse"
                                body:body
                              client:@"TVHTML5"
                           authorize:YES
                                 ttl:0]];
}

+ (NSDictionary *)history:(NSString *)continuation {
    if (![YTAuth isSignedIn]) {
        return nil;
    }

    NSMutableDictionary *body = [NSMutableDictionary dictionary];

    if ([continuation length] > 0) {
        [body setObject:continuation forKey:@"continuation"];
    } else {
        [body setObject:@"FEhistory" forKey:@"browseId"];
    }

    return [self feedFrom:[self post:@"browse"
                                body:body
                              client:@"TVHTML5"
                           authorize:YES
                                 ttl:0]];
}

/**
 * Заголовок дня у полки истории — порт `ExtractHistorySectionTitle`.
 *
 * Заголовок лежит то прямо в полке, то в её шапке, и шапки эти разных
 * видов: `itemSectionHeaderRenderer` у WEB, `shelfHeaderRenderer` у полок
 * побольше. Поэтому смотрим по очереди все, а не один.
 *
 * Отсеиваем при этом заголовки, которые днём не являются: у раздела бывает
 * своё название («История», «Видео»), и превращать его в заголовок дня
 * незачем — так же поступает `IsMeaningfulHistorySectionTitle`.
 */
+ (NSString *)historyDayTitleIn:(NSDictionary *)node {
    NSString *title = [YTJson renderedText:node key:@"title"];

    if ([title length] == 0) {
        NSArray *headers = [NSArray arrayWithObjects:
            @"itemSectionHeaderRenderer", @"shelfHeaderRenderer",
            @"headerRenderer", @"richShelfHeaderRenderer", nil];

        for (NSString *name in headers) {
            NSDictionary *header = [YTJson findFirst:name in:node limit:400];

            title = [YTJson renderedText:header key:@"title"];

            if ([title length] > 0) {
                break;
            }
        }
    }

    if ([title length] == 0) {
        return nil;
    }

    NSArray *notDays = [NSArray arrayWithObjects:
        @"история", @"history", @"видео", @"videos", @"shorts",
        @"музыка", @"music", @"поиск", @"search", nil];

    NSString *lowered = [title lowercaseString];

    for (NSString *mark in notDays) {
        if ([lowered isEqualToString:mark]) {
            return nil;
        }
    }

    return title;
}

/**
 * История с разбивкой по дням — то, что в UWP-версии делает
 * `ParseHistoryFeedPage` и `CollectHistorySections`.
 *
 * Сервер раскладывает просмотренное по полкам с заголовками вроде
 * «Сегодня» и «На прошлой неделе». Полок может и не быть вовсе — TV-клиент
 * иногда присылает просто сетку, — и тогда всё уходит одной безымянной
 * пачкой, ровно как в оригинале («Older» без заголовка).
 *
 * Возвращает `groups` (массив `{title, items}`), `items` тем же плоским
 * списком, что и раньше, и `continuation`.
 */
+ (NSDictionary *)historyPage:(NSString *)continuation {
    BOOL web = [YTWebAuth isSignedIn];

    if (!web && ![YTAuth isSignedIn]) {
        return nil;
    }

    NSMutableDictionary *body = [NSMutableDictionary dictionary];

    if ([continuation length] > 0) {
        [body setObject:continuation forKey:@"continuation"];
    } else {
        [body setObject:@"FEhistory" forKey:@"browseId"];
    }

    /**
     * Клиент WEB, если есть веб-сеанс, — ради разбивки по дням.
     *
     * TV-клиент присылает историю плоской сеткой: ни полок, ни заголовков
     * «Сегодня» и «Вчера» в его ответе нет вовсе — проверено по дампу.
     * WEB раскладывает её по дням сам, но говорить ему нужно веб-сеансом:
     * токен телевизора он не принимает. Нет веб-сеанса — берём у TV,
     * список тот же, просто без разбивки.
     */
    NSDictionary *json = web
        ? [self post:@"browse" body:body client:@"WEB" authorize:NO ttl:0]
        : nil;

    if (json == nil) {
        json = [self post:@"browse" body:body client:@"TVHTML5" authorize:YES ttl:0];
    }

    if (json == nil) {
        return nil;
    }

    NSMutableDictionary *result =
        [NSMutableDictionary dictionaryWithDictionary:[self feedFrom:json]];

    NSMutableArray *groups = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    NSArray *names = [NSArray arrayWithObjects:
        @"shelfRenderer", @"richShelfRenderer", @"itemSectionRenderer", nil];

    for (NSDictionary *hit in [YTJson findAllOfAny:names in:json limit:200000]) {
        NSDictionary *node = [hit objectForKey:@"node"];

        NSString *title = [self historyDayTitleIn:node];

        if ([title length] == 0) {
            continue;
        }

        NSMutableArray *items = [NSMutableArray array];

        for (YTVideoItem *item in [YTVideoItem parseFrom:node]) {
            NSString *key = [item.videoId length] > 0 ? item.videoId : item.title;

            if ([key length] == 0 || [seen containsObject:key]) {
                continue;
            }

            [seen addObject:key];
            [items addObject:item];
        }

        if ([items count] == 0) {
            continue;
        }

        NSMutableDictionary *group = [NSMutableDictionary dictionary];

        [group setObject:title forKey:@"title"];
        [group setObject:items forKey:@"items"];
        [groups addObject:group];
    }

    /**
     * Полок с заголовками не нашлось — значит их и нет. Тогда одна пачка
     * без заголовка: список тот же, просто без разбивки по дням.
     */
    if ([groups count] == 0) {
        NSArray *items = [result objectForKey:@"items"];

        if ([items count] > 0) {
            [groups addObject:[NSDictionary dictionaryWithObject:items forKey:@"items"]];
        }
    }

    [result setObject:groups forKey:@"groups"];

    NSLog(@"[YouTube/История] дней %lu, роликов %lu, продолжение %@",
          (unsigned long)[groups count],
          (unsigned long)[[result objectForKey:@"items"] count],
          [result objectForKey:@"continuation"] != nil ? @"есть" : @"нет");

    return result;
}

+ (NSArray *)myPlaylists {
    if (![YTAuth isSignedIn]) {
        return nil;
    }

    NSDictionary *json = [self post:@"browse"
                               body:[NSDictionary dictionaryWithObject:@"FEplaylist_aggregation"
                                                                forKey:@"browseId"]
                             client:@"TVHTML5"
                          authorize:YES
                                ttl:900];

    return [self playlistsIn:json];
}

/**
 * Подборки в ответе — порт `ParsePlaylistCards`.
 *
 * Разбор отдельный от разбора роликов, и это не удвоение: у подборки нет
 * идентификатора ролика, а разбор карточек как раз на нём и держится —
 * плитка без `videoId` там отбрасывается. Признак подборки другой:
 * `contentType` вида `TILE_CONTENT_TYPE_PLAYLIST` либо `contentId`,
 * начинающийся с `PL` или `VL`.
 */
+ (NSArray *)playlistsIn:(id)json {
    if (json == nil) {
        return nil;
    }

    NSMutableArray *playlists = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    NSArray *names = [NSArray arrayWithObjects:
        @"tileRenderer", @"playlistRenderer", @"gridPlaylistRenderer",
        @"lockupViewModel", nil];

    for (NSDictionary *hit in [YTJson findAllOfAny:names in:json limit:200000]) {
        NSDictionary *node = [hit objectForKey:@"node"];
        BOOL isTile = [[hit objectForKey:@"name"] isEqualToString:@"tileRenderer"];

        NSString *playlistId = isTile
            ? [YTJson textIn:node key:@"contentId"]
            : [YTJson textIn:node key:@"playlistId"];

        if (playlistId == nil) {
            playlistId = [YTJson textIn:node key:@"contentId"];
        }

        if ([playlistId hasPrefix:@"VL"]) {
            playlistId = [playlistId substringFromIndex:2];
        }

        NSString *contentType = [YTJson textIn:node key:@"contentType"];

        BOOL looksLikePlaylist = [playlistId hasPrefix:@"PL"]
            || [playlistId hasPrefix:@"RD"]
            || [playlistId hasPrefix:@"UL"]
            || [playlistId hasPrefix:@"OLA"]
            || [contentType rangeOfString:@"PLAYLIST"].location != NSNotFound;

        if ([playlistId length] == 0 || !looksLikePlaylist
            || [seen containsObject:playlistId]) {
            continue;
        }

        [seen addObject:playlistId];

        YTVideoItem *item = [[YTVideoItem alloc] init];

        item.playlistId = playlistId;

        if (isTile) {
            NSDictionary *metadata = [YTJson objectIn:[YTJson objectIn:node key:@"metadata"]
                                                  key:@"tileMetadataRenderer"];

            item.title = [YTJson renderedText:metadata key:@"title"];

            NSArray *lines = [YTJson arrayIn:metadata key:@"lines"];

            /**
             * Под названием — все строки плитки через точку, как их
             * показывает сам TV-клиент: у чужой подборки это автор
             * и когда обновлена, у своей — доступ и когда обновлена.
             * Одной первой строки мало: у своих подборок в ней стоит
             * «Ограниченный доступ», и больше ничего не видно.
             */
            NSMutableArray *parts = [NSMutableArray array];

            for (NSDictionary *line in lines) {
                NSString *text = YTTileLineText(line, 0);

                if ([text length] > 0) {
                    [parts addObject:text];
                }
            }

            item.channelTitle = [parts componentsJoinedByString:@" • "];

            NSDictionary *header = [YTJson objectIn:[YTJson objectIn:node key:@"header"]
                                                key:@"tileHeaderRenderer"];

            /**
             * Число роликов лежит не в строках, а накладкой на превью —
             * там же, где у ролика длительность: `thumbnailOverlayTimeStatus`
             * со значком `PLAYLISTS` и текстом «10 видео». В строках стоит
             * совсем другое: доступ («Ограниченный доступ») и когда обновлён.
             * Оттуда мы и брали, оттого на плашке был доступ вместо счёта.
             *
             * Так же в UWP-версии — `ExtractDurationFromOverlays`.
             */
            NSDictionary *badge = [YTJson findFirst:@"thumbnailOverlayTimeStatusRenderer"
                                                 in:header limit:400];

            item.duration = [YTJson renderedText:badge key:@"text"];

            item.thumbnail = [YTJson thumbnailIn:header key:@"thumbnail" minWidth:480];
        } else {
            item.title = [YTJson renderedText:node key:@"title"];
            item.duration = [YTJson renderedText:node key:@"videoCountShortText"];

            if (item.duration == nil) {
                item.duration = [YTJson renderedText:node key:@"videoCountText"];
            }

            item.thumbnail = [YTJson thumbnailIn:node key:@"thumbnail" minWidth:480];

            if (item.thumbnail == nil) {
                NSDictionary *image = [YTJson findFirst:@"image" in:node limit:400];

                item.thumbnail = [YTJson thumbnailIn:image key:@"sources" minWidth:480];
            }
        }

        if ([item.title length] == 0) {
            item.title = YTLoc(@"Плейлист");
        }

        [playlists addObject:item];
    }

    NSLog(@"[YouTube/Плейлисты] подборок: %lu", (unsigned long)[playlists count]);

    return playlists;
}


#pragma mark Канал

+ (NSDictionary *)channel:(NSString *)channelId params:(NSString *)params {
    if ([channelId length] == 0) {
        return nil;
    }

    NSMutableDictionary *body = [NSMutableDictionary dictionary];

    [body setObject:channelId forKey:@"browseId"];

    if ([params length] > 0) {
        [body setObject:params forKey:@"params"];
    }

    return [self channelFrom:body];
}

+ (NSDictionary *)channel:(NSString *)channelId tab:(NSString *)tab {
    if ([channelId length] == 0) {
        return nil;
    }

    NSMutableDictionary *body = [NSMutableDictionary dictionary];

    [body setObject:channelId forKey:@"browseId"];

    /**
     * Вкладка задаётся непрозрачным `params`. Значения подсмотрены
     * у официального клиента и перенесены из UWP-версии как есть —
     * вычислить их нельзя, это закодированный protobuf.
     */
    if ([tab isEqualToString:@"videos"]) {
        [body setObject:@"EgZ2aWRlb3PyBgQKAjoA" forKey:@"params"];
    } else if ([tab isEqualToString:@"shorts"]) {
        [body setObject:@"EgZzaG9ydHPyBgUKA5oBAA%3D%3D" forKey:@"params"];
    } else if ([tab isEqualToString:@"playlists"]) {
        [body setObject:@"EglwbGF5bGlzdHPyBgQKAkIA" forKey:@"params"];
    } else if ([tab isEqualToString:@"featured"]) {
        [body setObject:@"EghmZWF0dXJlZPIGBAoCMgA%3D" forKey:@"params"];
    } else if ([tab isEqualToString:@"streams"]) {
        [body setObject:@"EgdzdHJlYW1z8gYECgJ6AA%3D%3D" forKey:@"params"];
    } else if ([tab isEqualToString:@"posts"]) {
        [body setObject:@"EgVwb3N0c_IGBAoCSgA%3D" forKey:@"params"];
    }

    return [self channelFrom:body];
}

/**
 * Общая часть обоих запросов канала: сам запрос и разбор ответа.
 *
 * Клиент WEB: у TV-клиента страница канала куцая — в его ответе нет
 * ни `twoColumnBrowseResultsRenderer`, ни перечня разделов вовсе,
 * разбирать там нечего.
 *
 * Токен при этом **не** прикладываем, хотя вошедшему он есть.
 * Токен у нас от TV-клиента, и с WEB его не принимают: узел отвечает
 * 400 `INVALID_ARGUMENT`. Вошедшему запрос подписывает веб-сеанс —
 * это делает сам `post:` для WEB-клиента, когда токен не запрошен, —
 * и такой ответ приходит с пометкой `logged_in: 1`, то есть с подпиской
 * и колокольчиком. Ответ вошедшего не запоминаем: подписка меняется
 * здесь же, и через минуту показывать старое было бы враньём.
 */
+ (NSDictionary *)channelFrom:(NSDictionary *)body {
    BOOL signedIn = [YTWebAuth isSignedIn];

    NSDictionary *json = [self post:@"browse"
                               body:body
                             client:@"WEB"
                          authorize:NO
                                ttl:(signedIn ? 0 : YTFeedTTL)];

    if (json == nil) {
        return nil;
    }

    NSMutableDictionary *result =
        [NSMutableDictionary dictionaryWithDictionary:[self feedFrom:json]];

    /**
     * Шапка и разделы лежат по известным путям — берём по ним.
     *
     * Обход дерева здесь ненадёжен: ответ канала бывает под полмегабайта,
     * потолок посещённых узлов кончается раньше, чем находка попадётся,
     * и что именно успеет найтись — зависит от порядка ключей в словаре,
     * то есть ни от чего. Обход остаётся запасным путём.
     */
    NSDictionary *top = [YTJson objectIn:json key:@"header"];

    NSDictionary *header = [YTJson objectIn:top key:@"c4TabbedHeaderRenderer"];

    if (header == nil) {
        header = [YTJson objectIn:top key:@"pageHeaderRenderer"];
    }

    if (header == nil) {
        header = [YTJson findFirst:@"c4TabbedHeaderRenderer" in:json limit:4000];
    }

    if (header == nil) {
        header = [YTJson findFirst:@"pageHeaderRenderer" in:json limit:4000];
    }

    NSString *title = [YTJson renderedText:header key:@"title"];

    if (title == nil) { title = [YTJson textIn:header key:@"pageTitle"]; }
    if (title != nil) { [result setObject:title forKey:@"title"]; }

    NSString *handle = [YTJson renderedText:header key:@"channelHandleText"];

    if (handle != nil) { [result setObject:handle forKey:@"handle"]; }

    NSString *subscribers = [YTJson renderedText:header key:@"subscriberCountText"];

    if (subscribers != nil) { [result setObject:subscribers forKey:@"subscribers"]; }

    NSDictionary *metadata =
        [YTJson objectIn:[YTJson objectIn:json key:@"metadata"]
                     key:@"channelMetadataRenderer"];

    if (metadata == nil) {
        metadata = [YTJson findFirst:@"channelMetadataRenderer" in:json limit:4000];
    }

    /**
     * Кружок и подложка — по путям из `ExtractChannelInfo`.
     *
     * Кружок сперва ищется в `channelMetadataRenderer.avatar`, и только
     * если там пусто — общим обходом по ключу `avatar`. Подложка лежит
     * в новой шапке под `pageHeaderViewModel.banner.imageBannerViewModel`,
     * где вместо `thumbnails` — `sources`. Прежний разбор знал лишь
     * старую форму и оттого не находил ни того ни другого: у нынешних
     * каналов шапка новая.
     */
    NSString *avatar = [YTJson thumbnailIn:metadata key:@"avatar" minWidth:176];

    if (avatar == nil) {
        /**
         * Второй путь — из новой шапки: `pageHeaderViewModel.image
         * .decoratedAvatarViewModel.avatar.avatarViewModel.image.sources`.
         * Тем же путём кружок берёт и TubeReplacer.
         */
        NSDictionary *decorated = [YTJson findFirst:@"decoratedAvatarViewModel"
                                                 in:json limit:8000];

        NSDictionary *inner = [YTJson findFirst:@"avatarViewModel"
                                             in:decorated limit:600];

        avatar = [YTJson thumbnailIn:[YTJson objectIn:inner key:@"image"]
                                 key:@"sources"
                            minWidth:176];
    }

    if (avatar == nil) {
        avatar = [self imageIn:json key:@"avatar" minWidth:176];
    }

    if (avatar != nil) { [result setObject:avatar forKey:@"avatar"]; }

    NSDictionary *pageHeader = [YTJson findFirst:@"pageHeaderViewModel" in:json limit:4000];

    NSDictionary *bannerNode = [YTJson objectIn:
        [YTJson objectIn:pageHeader key:@"banner"] key:@"imageBannerViewModel"];

    NSString *banner = [YTJson thumbnailIn:[YTJson objectIn:bannerNode key:@"image"]
                                       key:@"sources"
                                  minWidth:1024];

    if (banner == nil) {
        banner = [self imageIn:json key:@"banner" minWidth:1024];
    }

    if (banner != nil) { [result setObject:banner forKey:@"banner"]; }

    /**
     * Строка в журнале не лишняя: подложки у канала может не быть вовсе —
     * в ответе тогда `banner: null`, — и отличить «не нашли» от «нету»
     * иначе нечем.
     */
    NSLog(@"[YouTube/Канал] Шапка: кружок %@, подложка %@",
          avatar != nil ? @"есть" : @"нет", banner != nil ? @"есть" : @"нет");

    NSString *description = [YTJson textIn:metadata key:@"description"];

    if (description != nil) { [result setObject:description forKey:@"description"]; }

    if ([result objectForKey:@"title"] == nil) {
        NSString *fromMetadata = [YTJson textIn:metadata key:@"title"];

        if (fromMetadata != nil) { [result setObject:fromMetadata forKey:@"title"]; }
    }

    /**
     * Собачка: сперва из `vanityChannelUrl` — там она в виде адреса,
     * и хвост после `/@` надо раскодировать, иначе у русских каналов
     * вместо букв показались бы проценты с цифрами.
     */
    if ([result objectForKey:@"handle"] == nil) {
        NSString *vanity = [YTJson textIn:metadata key:@"vanityChannelUrl"];

        /**
         * Проверка на пустоту обязательна, и вот почему.
         *
         * `rangeOfString:` у nil возвращает не «не найдено», а нули:
         * пустой ответ на пустое сообщение. Ноль — это законное место
         * в строке, проверка на `NSNotFound` его пропускает, и дальше
         * `stringByAppendingString:` получает nil и валит приложение
         * исключением. Так и падала страница канала без собачки.
         */
        NSRange mark = [vanity length] > 0
            ? [vanity rangeOfString:@"/@"]
            : NSMakeRange(NSNotFound, 0);

        if (mark.location != NSNotFound) {
            NSString *tail = [vanity substringFromIndex:NSMaxRange(mark)];

            tail = [tail stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding]
                 ?: tail;

            [result setObject:[@"@" stringByAppendingString:tail] forKey:@"handle"];
        }
    }

    /**
     * Подписчики и число роликов — из строк `contentMetadataViewModel`
     * новой шапки. Строка с числами вторая; если разметка другая,
     * перебираем все и узнаём по словам, как в запасном ходе оригинала.
     */
    if ([result objectForKey:@"subscribers"] == nil) {
        for (NSDictionary *row in
             [YTJson arrayIn:[YTJson findFirst:@"contentMetadataViewModel"
                                            in:pageHeader limit:2000]
                         key:@"metadataRows"]) {
            for (NSDictionary *part in [YTJson arrayIn:row key:@"metadataParts"]) {
                NSString *text = [YTJson textIn:[YTJson objectIn:part key:@"text"]
                                            key:@"content"];

                if ([text length] == 0) {
                    continue;
                }

                if ([text rangeOfString:@"одпис"].location != NSNotFound ||
                    [text rangeOfString:@"ubscrib"].location != NSNotFound) {
                    [result setObject:text forKey:@"subscribers"];
                } else if ([text hasPrefix:@"@"] && [result objectForKey:@"handle"] == nil) {
                    [result setObject:text forKey:@"handle"];
                }
            }
        }
    }

    /**
     * Разделы канала — прямо из ответа, а не списком в коде.
     *
     * Сервер перечисляет их сам, с готовыми метками `params`, и у разных
     * каналов набор разный: у одного нет Shorts, у другого есть «Релизы».
     * Своим списком мы показывали бы и то, чего у канала нет, и метки
     * приходилось бы держать наугад.
     */
    NSMutableArray *sections = [NSMutableArray array];

    NSDictionary *columns =
        [YTJson objectIn:[YTJson objectIn:json key:@"contents"]
                     key:@"twoColumnBrowseResultsRenderer"];

    if (columns == nil) {
        columns = [YTJson findFirst:@"twoColumnBrowseResultsRenderer"
                                 in:json limit:4000];
    }

    for (NSDictionary *entry in [YTJson arrayIn:columns key:@"tabs"]) {
        NSDictionary *renderer = [YTJson objectIn:entry key:@"tabRenderer"];

        if (renderer == nil) {
            renderer = [YTJson objectIn:entry key:@"expandableTabRenderer"];
        }

        NSString *sectionTitle = [YTJson textIn:renderer key:@"title"];

        if ([sectionTitle length] == 0) {
            continue;
        }

        // «Поиск» — не раздел, а поле ввода: показывать в полосе нечего.
        if ([sectionTitle isEqualToString:YTLoc(@"Поиск")] ||
            [sectionTitle isEqualToString:@"Search"]) {
            continue;
        }

        NSDictionary *endpoint = [YTJson objectIn:
            [YTJson objectIn:renderer key:@"endpoint"] key:@"browseEndpoint"];

        NSString *sectionParams = [YTJson textIn:endpoint key:@"params"];

        NSMutableDictionary *section = [NSMutableDictionary dictionary];

        [section setObject:sectionTitle forKey:@"title"];

        if ([sectionParams length] > 0) {
            [section setObject:sectionParams forKey:@"params"];
        }

        [sections addObject:section];
    }

    if ([sections count] > 0) {
        [result setObject:sections forKey:@"sections"];
    }

    [self applySubscriptionEntitiesTo:result from:json];

    /**
     * Ответ без подписки — а вход у нас всё же есть.
     *
     * Так бывает, когда вошли по коду с телевизора: тогда есть токен,
     * но нет веб-сеанса, подписать которым WEB-запрос было бы нечем,
     * и ответ приходит анонимным — в нём нет даже кнопки подписки.
     * Тогда спрашиваем состояние отдельно, клиентом TV: страницу он
     * отдаёт куцую, но подписку и колокольчик знает.
     */
    if ([result objectForKey:@"subscribed"] == nil && [YTAuth isSignedIn]) {
        NSString *channelId = [body objectForKey:@"browseId"];

        NSDictionary *state = [self post:@"browse"
                                    body:[NSDictionary dictionaryWithObject:channelId
                                                                     forKey:@"browseId"]
                                  client:@"TVHTML5"
                               authorize:YES
                                     ttl:0];

        if (state != nil) {
            [self applySubscriptionEntitiesTo:result from:state];

            NSDictionary *button = [YTJson findFirst:@"subscribeButtonRenderer"
                                                  in:state limit:8000];

            if (button != nil && [result objectForKey:@"subscribed"] == nil) {
                [result setObject:[NSNumber numberWithBool:
                    [YTJson boolIn:button key:@"subscribed"]] forKey:@"subscribed"];

                NSInteger bell = [self notificationsIn:button];

                if (bell != YTNotificationsUnknown) {
                    [result setObject:[NSNumber numberWithInteger:bell]
                               forKey:@"notifications"];
                }
            }
        }
    }

    if ([result objectForKey:@"subscribed"] == nil) {
        // Старая форма кнопки: признак лежит прямо в ней.
        NSDictionary *subscribe = [YTJson findFirst:@"subscribeButtonRenderer"
                                                 in:json limit:6000];

        if (subscribe != nil) {
            [result setObject:[NSNumber numberWithBool:
                [YTJson boolIn:subscribe key:@"subscribed"]] forKey:@"subscribed"];

            NSInteger bell = [self notificationsIn:subscribe];

            if (bell != YTNotificationsUnknown) {
                [result setObject:[NSNumber numberWithInteger:bell] forKey:@"notifications"];
            }
        }
    }

    NSLog(@"[YouTube/Канал] Разделов: %lu, подписка: %@",
          (unsigned long)[sections count],
          [result objectForKey:@"subscribed"] != nil
              ? ([[result objectForKey:@"subscribed"] boolValue] ? @"да" : @"нет")
              : @"сервер не сказал");

    return result;
}

/**
 * Первая картинка под таким ключом, где бы она ни лежала, — порт
 * `ExtractFirstImageUrl`. Берётся и старая форма (`thumbnails`),
 * и новая (`sources`).
 */
+ (NSString *)imageIn:(id)tree key:(NSString *)key minWidth:(NSInteger)minWidth {
    NSDictionary *node = [YTJson findFirst:key in:tree limit:20000];

    if (node == nil) {
        return nil;
    }

    NSString *url = [YTJson thumbnailIn:node key:@"thumbnails" minWidth:minWidth];

    if (url == nil) {
        url = [YTJson thumbnailIn:node key:@"sources" minWidth:minWidth];
    }

    return url;
}

#pragma mark Подборка

+ (NSDictionary *)playlist:(NSString *)playlistId {
    NSString *identifier = playlistId;

    if ([identifier hasPrefix:@"VL"]) {
        identifier = [identifier substringFromIndex:2];
    }

    if ([identifier length] == 0) {
        return nil;
    }

    /**
     * Порт `NormalizePlaylistBrowseId`.
     *
     * Сохранённый плейлист открывается как `VL` + идентификатор — так его
     * грузит и YouTube.js. Миксу приставка, наоборот, мешает: с ней сервер
     * отвечает пустой страницей, потому что микса как сохранённого списка
     * не существует. Узнаётся микс по началу `RD` — сюда попадают и радио
     * `RDMM`, и станции `RDCLAK`.
     */
    BOOL isMix = [identifier hasPrefix:@"RD"];

    NSString *browseId = isMix ? identifier
                               : [@"VL" stringByAppendingString:identifier];

    /**
     * Клиент выбирается так же, как в UWP-версии: вошедшему — TV, потому
     * что токен выдан ему, и WEB с `Authorization` отвечает 400; гостю —
     * WEB, у которого страница подборки полнее.
     */
    BOOL signedIn = [YTAuth isSignedIn];

    NSDictionary *json = [self post:@"browse"
                               body:[NSDictionary dictionaryWithObject:browseId
                                                                forKey:@"browseId"]
                             client:(signedIn ? @"TVHTML5" : @"WEB")
                          authorize:signedIn
                                ttl:YTFeedTTL];

    if (json == nil) {
        return nil;
    }

    NSMutableDictionary *result =
        [NSMutableDictionary dictionaryWithDictionary:[self feedFrom:json]];

    NSDictionary *header = [YTJson findFirst:@"playlistHeaderRenderer" in:json limit:6000];

    if (header == nil) {
        header = [YTJson findFirst:@"pageHeaderRenderer" in:json limit:6000];
    }

    NSString *title = [YTJson renderedText:header key:@"title"];

    if (title == nil) {
        NSDictionary *metadata = [YTJson findFirst:@"playlistMetadataRenderer" in:json limit:6000];

        title = [YTJson textIn:metadata key:@"title"];
    }

    if (title == nil) { title = [YTJson textIn:header key:@"pageTitle"]; }
    if (title != nil) { [result setObject:title forKey:@"title"]; }

    NSString *owner = [YTJson renderedText:header key:@"ownerText"];

    if (owner != nil) { [result setObject:owner forKey:@"channelTitle"]; }

    NSString *count = [YTJson renderedText:header key:@"numVideosText"];

    if (count == nil) { count = [YTJson renderedText:header key:@"videoCountText"]; }
    if (count != nil) { [result setObject:count forKey:@"subtitle"]; }

    NSString *thumbnail = [YTJson thumbnailIn:header key:@"playlistHeaderBanner" minWidth:480];

    if (thumbnail != nil) { [result setObject:thumbnail forKey:@"thumbnail"]; }

    return result;
}

+ (NSDictionary *)browseContinuation:(NSString *)continuation {
    if ([continuation length] == 0) {
        return nil;
    }

    return [self feedFrom:[self post:@"browse"
                                body:[NSDictionary dictionaryWithObject:continuation
                                                                 forKey:@"continuation"]
                              client:@"WEB"
                           authorize:NO
                                 ttl:0]];
}

@end
