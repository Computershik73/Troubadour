#import "YTAuth.h"

#import "YTStrings.h"

#import "YTHttp.h"
#import "YTJson.h"

NSString *const YTAuthChangedNotification = @"YTAuthChanged";

/**
 * Учётные данные клиента «YouTube on TV».
 *
 * Взяты из Config.cs UWP-версии без изменений. Это не секрет: у публичных
 * клиентов OAuth «секрет» существует только формально, он одинаков у всех
 * установок и лежит в открытом виде в любом таком приложении.
 */
static NSString *const YTClientId =
    @"861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com";
static NSString *const YTClientSecret = @"SboVhoG9s0rNafixCSGGKXAT";

/** Те же, что в Login.xaml.cs. */
static NSString *const YTDeviceScope =
    @"http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content";
static NSString *const YTDeviceModel = @"ytlr:samsung:smarttv";
static NSString *const YTTvUserAgent = @"Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0)";

static NSString *const YTRefreshTokenKey = @"yt_refresh_token";

static NSString *YTRefreshTokenValue = nil;

/** Токен доступа и когда он протухнет. На диск не кладётся. */
static NSString *YTAccessTokenValue = nil;
static NSTimeInterval YTAccessTokenExpires = 0;

/** Состояние идущего входа по коду. */
static NSString *YTDeviceCode = nil;
static NSString *YTUserCodeValue = nil;
static NSTimeInterval YTPollIntervalValue = 5.0;

@implementation YTAuth

+ (void)restore {
    YTRefreshTokenValue =
        [[NSUserDefaults standardUserDefaults] stringForKey:YTRefreshTokenKey];

    NSLog(@"[YouTube/Вход] %@", [YTRefreshTokenValue length] > 0
          ? @"Сохранённый вход поднят" : YTLoc(@"Входа нет"));
}

+ (BOOL)isSignedIn {
    return [YTRefreshTokenValue length] > 0;
}

+ (NSString *)refreshToken {
    return YTRefreshTokenValue;
}

+ (void)store:(NSString *)token {
    YTRefreshTokenValue = [token copy];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    if ([token length] > 0) {
        [defaults setObject:token forKey:YTRefreshTokenKey];
    } else {
        [defaults removeObjectForKey:YTRefreshTokenKey];
    }

    [defaults synchronize];

    @synchronized (self) {
        YTAccessTokenValue = nil;
        YTAccessTokenExpires = 0;
    }

    /**
     * Кратковременный кеш ответов сбрасывается вместе со входом: витрина
     * и ленты у вошедшего и невошедшего разные, а ключом там один адрес —
     * первые минуты после входа приходили бы прежние, гостевые ответы.
     */
    [YTHttp dropMemoryCache];

    [[NSNotificationCenter defaultCenter] postNotificationName:YTAuthChangedNotification
                                                        object:nil];
}

+ (void)signOut {
    NSLog(@"[YouTube/Вход] Выход из аккаунта");

    [self store:nil];
}

#pragma mark Токен доступа

+ (NSString *)accessToken {
    if (![self isSignedIn]) {
        return nil;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    @synchronized (self) {
        if (YTAccessTokenValue != nil && now < YTAccessTokenExpires) {
            return YTAccessTokenValue;
        }
    }

    /**
     * Замок на весь обмен, а не только на чтение поля.
     *
     * Если несколько экранов начинают грузиться разом, в сеть должен пойти
     * только первый: остальные подождут его и возьмут готовое. Без этого
     * при запуске уходило бы полдюжины одинаковых запросов к
     * oauth2.googleapis.com, и каждый следующий обесценивал бы предыдущий.
     */
    @synchronized ([YTAuth class]) {
        now = [NSDate timeIntervalSinceReferenceDate];

        if (YTAccessTokenValue != nil && now < YTAccessTokenExpires) {
            return YTAccessTokenValue;
        }

        NSString *body = [NSString stringWithFormat:
            @"client_id=%@&client_secret=%@&refresh_token=%@&grant_type=refresh_token",
            YTEncodeParameter(YTClientId),
            YTEncodeParameter(YTClientSecret),
            YTEncodeParameter(YTRefreshTokenValue)];

        NSDictionary *json = [self postForm:@"https://oauth2.googleapis.com/token" body:body];

        NSString *token = [YTJson textIn:json key:@"access_token"];

        if ([token length] == 0) {
            NSString *error = [YTJson stringIn:json key:@"error" fallback:@"нет ответа"];

            NSLog(@"[YouTube/Вход] Токен доступа не обновлён: %@", error);

            /**
             * `invalid_grant` — это не временная беда: долгоживущий токен
             * отозван (сменили пароль, отобрали доступ приложению). Держать
             * его дальше незачем, иначе каждый запрос будет ходить в сеть
             * за заведомым отказом. Остальные ошибки — сетевые, и вход
             * при них остаётся.
             */
            if ([error isEqualToString:@"invalid_grant"]) {
                NSLog(@"[YouTube/Вход] Долгоживущий токен отозван — выходим");
                [self store:nil];
            }

            return nil;
        }

        // Срок берём с запасом в минуту: между обменом и тем запросом,
        // ради которого он затевался, проходит время.
        double lifetime = [YTJson doubleIn:json key:@"expires_in" fallback:3600];

        YTAccessTokenValue = token;
        YTAccessTokenExpires = [NSDate timeIntervalSinceReferenceDate] + lifetime - 60;

        return token;
    }
}

#pragma mark Вход по коду

+ (NSString *)userCode {
    return YTUserCodeValue;
}

+ (NSTimeInterval)pollInterval {
    return YTPollIntervalValue;
}

+ (NSString *)beginDeviceFlow {
    /**
     * `device_id` — случайный на каждую попытку. Он ни к чему не привязан
     * и служит только тем, чтобы сервер отличал параллельные входы; UWP-версия
     * кладёт туда свежий GUID, здесь — то же самое через NSUUID (он есть
     * с iOS 6, поэтому при отказе берётся время с точностью до миллисекунды).
     */
    NSString *deviceId = nil;

    Class uuid = NSClassFromString(@"NSUUID");

    if (uuid != nil) {
        deviceId = [[uuid UUID] UUIDString];
    } else {
        deviceId = [NSString stringWithFormat:@"%.0f-%d",
                    [NSDate timeIntervalSinceReferenceDate] * 1000, arc4random() % 100000];
    }

    NSString *body = [NSString stringWithFormat:
        @"client_id=%@&scope=%@&device_id=%@&device_model=%@",
        YTEncodeParameter(YTClientId),
        YTEncodeParameter(YTDeviceScope),
        YTEncodeParameter(deviceId),
        YTEncodeParameter(YTDeviceModel)];

    NSDictionary *json = [self postForm:@"https://www.youtube.com/o/oauth2/device/code"
                                   body:body];

    YTDeviceCode = [[YTJson textIn:json key:@"device_code"] copy];
    YTUserCodeValue = [[YTJson textIn:json key:@"user_code"] copy];
    YTPollIntervalValue = [YTJson doubleIn:json key:@"interval" fallback:5];

    if ([YTDeviceCode length] == 0) {
        NSLog(@"[YouTube/Вход] Код устройства не получен");
        return nil;
    }

    NSLog(@"[YouTube/Вход] Код устройства получен, опрашивать раз в %.0f с",
          YTPollIntervalValue);

    return YTUserCodeValue;
}

+ (NSInteger)pollDeviceFlow {
    if ([YTDeviceCode length] == 0) {
        return -1;
    }

    NSString *body = [NSString stringWithFormat:
        @"client_id=%@&client_secret=%@&code=%@&grant_type=%@",
        YTEncodeParameter(YTClientId),
        YTEncodeParameter(YTClientSecret),
        YTEncodeParameter(YTDeviceCode),
        YTEncodeParameter(@"http://oauth.net/grant_type/device/1.0")];

    NSDictionary *json = [self postForm:@"https://www.youtube.com/o/oauth2/token" body:body];

    NSString *refresh = [YTJson textIn:json key:@"refresh_token"];

    if ([refresh length] > 0) {
        NSLog(@"[YouTube/Вход] Код подтверждён, вход выполнен");

        YTDeviceCode = nil;
        YTUserCodeValue = nil;

        [self store:refresh];

        return 1;
    }

    NSString *error = [YTJson stringIn:json key:@"error" fallback:@""];

    // Штатный ответ, пока код не введён, — не ошибка.
    if ([error isEqualToString:@"authorization_pending"]) {
        return 0;
    }

    // Просят опрашивать реже — послушаемся, иначе сервер начнёт отказывать.
    if ([error isEqualToString:@"slow_down"]) {
        YTPollIntervalValue += 5;
        return 0;
    }

    NSLog(@"[YouTube/Вход] Вход не удался: %@", [error length] > 0 ? error : @"нет ответа");

    YTDeviceCode = nil;

    return -1;
}

#pragma mark Общее

/** POST с телом `application/x-www-form-urlencoded`. */
+ (NSDictionary *)postForm:(NSString *)url body:(NSString *)body {
    // Кеш обходим намеренно: ответы про токены не кешируются никогда,
    // а на опрос кода это дало бы «ещё нет» вместо подтверждения.
    NSMutableURLRequest *request =
        YTRequest(url, NSURLRequestReloadIgnoringLocalCacheData, 20.0);

    if (request == nil) {
        return nil;
    }

    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [request setValue:YTTvUserAgent forHTTPHeaderField:@"User-Agent"];
    [request setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];

    YTHttpResponse *response = [YTHttp send:request bodyLimit:256 * 1024 caching:NO];

    // Разбираем тело и при отказе тоже: причина лежит в поле `error`,
    // а код ответа при `authorization_pending` — 428 или 400.
    return [YTJson parse:response.body];
}

@end
