#import "YTWebAuth.h"

#import <CommonCrypto/CommonDigest.h>

#import "YTHttp.h"

NSString *const YTWebAuthChangedNotification = @"YTWebAuthChanged";

/** Под каким именем лежит отложенная веб-сессия. */
static NSString *const YTWebSessionKey = @"YTWebSessionCookies";

/**
 * Хранилище берётся по имени в рантайме.
 *
 * `NSHTTPCookieStorage` — из той же семьи NSURL*, что и `NSURLRequest`:
 * в SDK 9.3 он числится за CFNetwork, а на iOS 7 живёт в Foundation.
 * Прямая ссылка на класс привязала бы нас к CFNetwork, и приложение
 * не запустилось бы на семёрке — эту ошибку уже ловили однажды,
 * теперь её сторожит `check-macho.py`.
 */
static id YTCookieStorage(void) {
    return [YTNetworkClass(@"NSHTTPCookieStorage") sharedHTTPCookieStorage];
}

/**
 * Имена куки, по которым узнаётся вход, — в том же порядке, что
 * в `BuildSapisidAuthorization` оригинала. Первая найденная и идёт
 * в подпись.
 */
static NSArray *YTSapisidNames(void) {
    static NSArray *names = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        names = [[NSArray alloc] initWithObjects:
            @"SAPISID", @"__Secure-3PAPISID", @"__Secure-1PAPISID", nil];
    });

    return names;
}

@implementation YTWebAuth

/**
 * Куки берутся из общего хранилища — того же, куда их кладёт UIWebView
 * при входе и откуда их берёт NSURLConnection в наших запросах.
 */
+ (NSString *)sapisid {
    id storage = YTCookieStorage();

    for (NSString *name in YTSapisidNames()) {
        for (NSHTTPCookie *cookie in [storage cookies]) {
            if (![[cookie name] isEqualToString:name]) {
                continue;
            }

            /**
             * Домен проверяется потому, что одноимённые куки Google живут
             * и на google.com, и на youtube.com. Нам нужна та, что уйдёт
             * с запросом к youtube.com, — иначе подпись будет от чужого
             * сеанса, и сервер её отвергнет.
             */
            NSString *domain = [cookie domain];

            if ([domain rangeOfString:@"youtube.com"].location != NSNotFound
                || [domain rangeOfString:@"google.com"].location != NSNotFound) {

                if ([[cookie value] length] > 0) {
                    return [cookie value];
                }
            }
        }
    }

    return nil;
}

+ (BOOL)isSignedIn {
    return [[self sapisid] length] > 0;
}

+ (NSString *)authorizationForOrigin:(NSString *)origin {
    NSString *sapisid = [self sapisid];

    if ([sapisid length] == 0) {
        return nil;
    }

    long long seconds = (long long)[[NSDate date] timeIntervalSince1970];

    NSString *source = [NSString stringWithFormat:@"%lld %@ %@",
                        seconds, sapisid, origin];

    /**
     * SHA-1 из CommonCrypto: он есть с самых первых версий системы,
     * и тащить ради одного отпечатка что-то ещё незачем.
     */
    NSData *raw = [source dataUsingEncoding:NSUTF8StringEncoding];

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];

    CC_SHA1([raw bytes], (CC_LONG)[raw length], digest);

    NSMutableString *hex = [NSMutableString string];

    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }

    return [NSString stringWithFormat:@"SAPISIDHASH %lld_%@", seconds, hex];
}

+ (NSString *)loginUrl {
    /**
     * Адрес — из `LoginWebViewPage`, только возврат ведёт не в музыку,
     * а на youtube.com: сессия одна на оба, но по адресу возврата
     * удобнее понять, что вход закончился.
     */
    return @"https://accounts.google.com/ServiceLogin?service=youtube"
           @"&continue=https%3A%2F%2Fwww.youtube.com%2F";
}

+ (void)signOut {
    id storage = YTCookieStorage();

    for (NSHTTPCookie *cookie in [[storage cookies] copy]) {
        NSString *domain = [cookie domain];

        if ([domain rangeOfString:@"youtube.com"].location != NSNotFound
            || [domain rangeOfString:@"google.com"].location != NSNotFound) {

            [storage deleteCookie:cookie];
        }
    }

    [[NSUserDefaults standardUserDefaults] removeObjectForKey:YTWebSessionKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    [[NSNotificationCenter defaultCenter] postNotificationName:YTWebAuthChangedNotification
                                                        object:nil];
}

/**
 * Имена кук, по которым Google узнаёт вошедшего.
 *
 * `SAPISID` и её собратья идут в подпись, `SID` с `HSID` и `SSID` —
 * сам сеанс, `LOGIN_INFO` — то, чем YouTube отличает вошедшего от гостя.
 * Не хватает хоть одной существенной — и сервер встречает нас проверкой
 * «вы не бот», хотя вход как будто состоялся.
 */
static NSArray *YTSessionNames(void) {
    static NSArray *names = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        names = [[NSArray alloc] initWithObjects:
            @"SID", @"HSID", @"SSID", @"APISID", @"SAPISID",
            @"__Secure-1PSID", @"__Secure-3PSID",
            @"__Secure-1PAPISID", @"__Secure-3PAPISID",
            @"LOGIN_INFO", nil];
    });

    return names;
}

+ (NSString *)sessionReport {
    id storage = YTCookieStorage();

    NSMutableSet *have = [NSMutableSet set];

    for (NSHTTPCookie *cookie in [storage cookies]) {
        NSString *domain = [cookie domain];

        if ([domain rangeOfString:@"youtube.com"].location == NSNotFound &&
            [domain rangeOfString:@"google.com"].location == NSNotFound) {
            continue;
        }

        [have addObject:[cookie name]];
    }

    NSMutableArray *missing = [NSMutableArray array];

    for (NSString *name in YTSessionNames()) {
        if (![have containsObject:name]) {
            [missing addObject:name];
        }
    }

    if ([missing count] == 0) {
        return @"все нужные куки на месте";
    }

    return [NSString stringWithFormat:@"не хватает: %@",
            [missing componentsJoinedByString:@", "]];
}

#pragma mark Запас на следующий запуск

+ (void)keepSession {
    id storage = YTCookieStorage();

    NSMutableArray *kept = [NSMutableArray array];

    for (NSHTTPCookie *cookie in [storage cookies]) {
        NSString *domain = [cookie domain];

        if ([domain rangeOfString:@"youtube.com"].location == NSNotFound
            && [domain rangeOfString:@"google.com"].location == NSNotFound) {
            continue;
        }

        /**
         * Куку откладываем её же описанием: словарь свойств переживает
         * запись в настройки, а сам объект — нет.
         */
        NSDictionary *properties = [cookie properties];

        if (properties != nil) {
            [kept addObject:properties];
        }
    }

    if ([kept count] == 0) {
        return;
    }

    [[NSUserDefaults standardUserDefaults] setObject:kept forKey:YTWebSessionKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    NSLog(@"[YouTube/Вход] Веб-сессия отложена: кук %lu, %@",
          (unsigned long)[kept count], [self sessionReport]);
}

+ (void)restoreSession {
    // Уже есть — значит, хранилище донесло само, и мешать ему незачем.
    if ([self isSignedIn]) {
        return;
    }

    NSArray *kept = [[NSUserDefaults standardUserDefaults] objectForKey:YTWebSessionKey];

    if ([kept count] == 0) {
        return;
    }

    id storage = YTCookieStorage();
    NSUInteger back = 0;

    for (NSDictionary *properties in kept) {
        // Класс по имени — прямая ссылка тянет CFNetwork, см. `YTCookieStorage`.
        NSHTTPCookie *cookie =
            [YTNetworkClass(@"NSHTTPCookie") cookieWithProperties:properties];

        if (cookie != nil) {
            [storage setCookie:cookie];

            back++;
        }
    }

    NSLog(@"[YouTube/Вход] Веб-сессия поднята из запаса: кук %lu, вход %@, %@",
          (unsigned long)back, [self isSignedIn] ? @"есть" : @"не собрался",
          [self sessionReport]);

    if ([self isSignedIn]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:YTWebAuthChangedNotification
                                                            object:nil];
    }
}

@end
