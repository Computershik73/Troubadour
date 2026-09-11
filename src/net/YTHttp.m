#import "YTHttp.h"

#import "YTStrings.h"

#import <Security/Security.h>

static NSString *const YTHttpErrorDomain = @"ru.computershik.troubadour.http";

/** Код ошибки «ответ больше лимита». */
static const NSInteger YTHttpErrorBodyTooLarge = -4;

@implementation YTHttpResponse

- (BOOL)isSuccessful {
    return self.error == nil && self.statusCode >= 200 && self.statusCode < 300;
}

- (NSString *)text {
    if ([self.body length] == 0) {
        return @"";
    }

    NSString *value = [[NSString alloc] initWithData:self.body encoding:NSUTF8StringEncoding];
    return value ?: @"";
}

@end


/** Проверка цепочки сертификатов; определена ниже, у остальных дел с TLS. */
static BOOL YTTrustIsValid(SecTrustRef trust, NSString *host);

/** Сколько раз проверяли доверие и сколько это заняло — по одной на соединение. */
static NSInteger YTTrustChecks = 0;
static NSTimeInterval YTTrustSeconds = 0;

Class YTNetworkClass(NSString *name) {
    // Кеш не нужен: NSClassFromString сам ищет по хеш-таблице рантайма,
    // и запросов у нас не столько, чтобы это было заметно.
    return NSClassFromString(name);
}

NSMutableURLRequest *YTRequest(NSString *url,
                               NSURLRequestCachePolicy policy,
                               NSTimeInterval timeout) {
    NSURL *address = [NSURL URLWithString:url];

    if (address == nil) {
        // Молчаливый nil здесь дорого обходится: запрос просто не уходит,
        // и в журнале не остаётся ни строки. Чаще всего виноват пробел
        // или кириллица в подставленном значении.
        NSLog(@"[YouTube/HTTP] Адрес не разобран: %@", url);
        return nil;
    }

    return [YTNetworkClass(@"NSMutableURLRequest") requestWithURL:address
                                                      cachePolicy:policy
                                                  timeoutInterval:timeout];
}

NSString *YTEncodeParameter(NSString *value) {
    if ([value length] == 0) {
        return @"";
    }

    /**
     * `stringByAddingPercentEncodingWithAllowedCharacters:` появился только
     * в iOS 7, поэтому здесь вариант эпохи: CFURLCreateStringByAddingPercentEscapes
     * со списком того, что кодировать обязательно.
     *
     * Кодируется при этом **только подставляемое значение**, не адрес целиком:
     * в готовом адресе уже есть и разделители, и заранее закодированные куски,
     * и пропущенный через кодировщик знак процента превратился бы в %25.
     */
    CFStringRef escaped = CFURLCreateStringByAddingPercentEscapes(
        NULL,
        (__bridge CFStringRef)value,
        NULL,
        CFSTR(":/?#[]@!$&'()*+,;=%"),
        kCFStringEncodingUTF8);

    return (__bridge_transfer NSString *)escaped ?: @"";
}

/**
 * Значение этой константы совпадает с её именем — так объявлено в Foundation.
 * Пишем строкой, чтобы не тянуть символ, который на разных версиях iOS
 * экспортируют разные библиотеки.
 */
static NSString *const YTServerTrustMethod = @"NSURLAuthenticationMethodServerTrust";


#pragma mark - Отдельный поток для соединений

/**
 * NSURLConnection работает через цикл выполнения, а его нужно кому-то крутить.
 * Заводим один поток на всё приложение: соединений много, а поток дешевле
 * создавать один раз, чем на каждый запрос.
 */
@interface YTHttpThread : NSThread
@end

@implementation YTHttpThread

- (void)main {
    @autoreleasepool {
        NSRunLoop *loop = [NSRunLoop currentRunLoop];

        // Без хотя бы одного источника цикл выполнения завершается сразу.
        [loop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];

        while (![self isCancelled]) {
            @autoreleasepool {
                [loop runMode:NSDefaultRunLoopMode
                   beforeDate:[NSDate dateWithTimeIntervalSinceNow:10.0]];
            }
        }
    }
}

@end


#pragma mark - Одно соединение

@interface YTHttpCall : NSObject <NSURLConnectionDataDelegate> {
    NSMutableData *_buffer;
    NSUInteger _limit;
    dispatch_semaphore_t _done;
    NSURLConnection *_connection;
}

@property (nonatomic, strong) YTHttpResponse *result;

/** Класть ли ответ в дисковый кеш. */
@property (nonatomic, assign) BOOL caching;

/** Заданы только в потоковом режиме; тогда тело не накапливается. */
@property (nonatomic, copy) void (^onHeaders)(YTHttpResponse *head);
@property (nonatomic, copy) BOOL (^onChunk)(NSData *chunk);

- (YTHttpResponse *)run:(NSURLRequest *)request
              bodyLimit:(NSUInteger)bodyLimit
               onThread:(NSThread *)thread;

@end


@implementation YTHttpCall

- (YTHttpResponse *)run:(NSURLRequest *)request
              bodyLimit:(NSUInteger)bodyLimit
               onThread:(NSThread *)thread {
    _buffer = [NSMutableData data];
    _limit = bodyLimit;
    _done = dispatch_semaphore_create(0);

    self.result = [[YTHttpResponse alloc] init];
    self.result.expectedLength = -1;

    _connection = [[YTNetworkClass(@"NSURLConnection") alloc] initWithRequest:request
                                                                     delegate:self
                                                             startImmediately:NO];

    [self performSelector:@selector(startOnThread)
                 onThread:thread
               withObject:nil
            waitUntilDone:NO];

    // Свой предохранитель поверх timeoutInterval: если соединение почему-то
    // не позвало ни один из завершающих методов, поток вызывающего не должен
    // остаться в ожидании навсегда.
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(90.0 * NSEC_PER_SEC));

    if (dispatch_semaphore_wait(_done, deadline) != 0) {
        [self performSelector:@selector(cancelOnThread)
                     onThread:thread
                   withObject:nil
                waitUntilDone:NO];

        self.result.error = [NSError errorWithDomain:YTHttpErrorDomain
                                                code:NSURLErrorTimedOut
                                            userInfo:[NSDictionary dictionaryWithObject:YTLoc(@"Сервер не ответил")
                                                                                 forKey:NSLocalizedDescriptionKey]];
    }

    return self.result;
}

- (void)startOnThread {
    [_connection scheduleInRunLoop:[NSRunLoop currentRunLoop]
                           forMode:NSDefaultRunLoopMode];
    [_connection start];
}

- (void)cancelOnThread {
    [_connection cancel];
}

- (void)finish {
    dispatch_semaphore_signal(_done);
}

#pragma mark Данные

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    [_buffer setLength:0];

    self.result.headersAt = CFAbsoluteTimeGetCurrent();
    self.result.expectedLength = [response expectedContentLength];

    if ([response isKindOfClass:YTNetworkClass(@"NSHTTPURLResponse")]) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;

        self.result.statusCode = [http statusCode];
        self.result.headers = [http allHeaderFields];
    }

    if (self.onHeaders != nil) {
        self.onHeaders(self.result);
    }
}

/**
 * Ответ в дисковый кеш кладём не всегда: сегменты видео весят мегабайты,
 * не повторяются, и запись их на диск во время воспроизведения только
 * отнимает время у самого воспроизведения — а заодно вытесняет из кеша
 * превью, ради которых он и заведён.
 */
- (NSCachedURLResponse *)connection:(NSURLConnection *)connection
                  willCacheResponse:(NSCachedURLResponse *)cached {
    return self.caching ? cached : nil;
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    // Потоковый режим: отдаём кусок сразу и ничего не накапливаем.
    if (self.onChunk != nil) {
        if (!self.onChunk(data)) {
            [connection cancel];
            [self finish];
        }

        return;
    }

    [_buffer appendData:data];

    // Обрываем, как только стало ясно, что ответ длиннее лимита: дочитывать
    // мегабайты, чтобы потом их выбросить, незачем.
    if (_limit > 0 && [_buffer length] > _limit) {
        [connection cancel];

        NSString *text = [NSString stringWithFormat:@"Ответ больше %lu МБ",
                                                    (unsigned long)(_limit / 1024 / 1024)];

        self.result.error = [NSError errorWithDomain:YTHttpErrorDomain
                                                code:YTHttpErrorBodyTooLarge
                                            userInfo:[NSDictionary dictionaryWithObject:text
                                                                                 forKey:NSLocalizedDescriptionKey]];
        [_buffer setLength:0];
        [self finish];
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    self.result.body = [NSData dataWithData:_buffer];
    [self finish];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    if (self.result.error == nil) {
        self.result.error = error;
    }

    [self finish];
}

#pragma mark Сертификаты

- (void)connection:(NSURLConnection *)connection
        willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
    NSURLProtectionSpace *space = [challenge protectionSpace];

    if (![[space authenticationMethod] isEqualToString:YTServerTrustMethod]) {
        [[challenge sender] continueWithoutCredentialForAuthenticationChallenge:challenge];
        return;
    }

    SecTrustRef trust = [space serverTrust];

#ifdef YT_INSECURE_TLS
    /**
     * Отладочная сборка: проверка подлинности сервера снята целиком.
     *
     * Нужно ровно для одного — смотреть трафик перехватчиком (Charles,
     * Proxyman, mitmproxy). Тот подменяет сертификат своим, и честная
     * проверка его не пропустит, потому что цепочка и правда чужая.
     *
     * Включается только явно, ключом сборки:
     *
     *     make package INSECURE_TLS=1
     *
     * Обычная сборка этого кода не содержит вовсе — не «содержит,
     * но не включает», а именно не содержит: `#ifdef` выбрасывает его
     * на этапе разбора. Случайно попасть в готовый пакет ему неоткуда.
     *
     * Строка в журнале пишется на каждый запрос намеренно и не сокращается:
     * такую сборку нельзя перепутать с обычной, посмотрев в лог.
     */
    NSLog(@"[YouTube/TLS] !!! ПРОВЕРКА СЕРТИФИКАТОВ ОТКЛЮЧЕНА (отладочная "
          @"сборка), доверяем кому угодно: %@", [space host]);

    if (trust != NULL) {
        NSURLCredential *credential =
            [YTNetworkClass(@"NSURLCredential") credentialForTrust:trust];

        [[challenge sender] useCredential:credential forAuthenticationChallenge:challenge];
        return;
    }
#endif

    /**
     * Считаем проверки доверия — по ним видно, сколько было рукопожатий.
     *
     * Проверка случается ровно один раз на соединение, а не на запрос:
     * значит, растущий счётчик при неизменном числе запросов означает,
     * что соединения не переиспользуются и каждая картинка платит за
     * новое рукопожатие. Иначе про «долго ждём ответа» не сказать,
     * чья это доля — сети или нашего же железа.
     */
    NSTimeInterval checkedAt = CFAbsoluteTimeGetCurrent();

    if (trust != NULL && YTTrustIsValid(trust, [space host])) {
        @synchronized ([YTHttp class]) {
            YTTrustChecks++;
            YTTrustSeconds += CFAbsoluteTimeGetCurrent() - checkedAt;
        }

        NSURLCredential *credential =
            [YTNetworkClass(@"NSURLCredential") credentialForTrust:trust];
        [[challenge sender] useCredential:credential forAuthenticationChallenge:challenge];
        return;
    }

    NSLog(@"[YouTube/TLS] Цепочка отвергнута: %@", [space host]);

    [[challenge sender] cancelAuthenticationChallenge:challenge];
}

@end


#pragma mark - Проверка цепочки

static BOOL YTTrustResultIsOk(SecTrustResultType result) {
    return result == kSecTrustResultUnspecified || result == kSecTrustResultProceed;
}

/**
 * Вшитые корни из Resources/certs. Читаются один раз.
 *
 * Все четыре — Google Trust Services, выпущены 22 июня 2016 года и действуют
 * до 2036-го. Их выкладывает сама Google на pki.goog/repo/certs; отпечатки
 * SHA-256 записаны в README, чтобы файлы можно было сверить, не доверяя
 * тому, кто их положил.
 *
 * R1 и R2 — RSA, R3 и R4 — эллиптические. Сегодня цепочка youtube.com идёт
 * через R1, но какой именно корень подставит балансировщик, заранее
 * неизвестно, и класть один ради экономии полутора килобайт не стоит.
 */
static NSArray *YTBundledAnchors(void) {
    static NSArray *anchors = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        /**
         * Берём **все** файлы `.der` из `certs`, а не список по именам.
         *
         * Так задумано: чтобы добавить корень, достаточно положить файл
         * рядом с остальными и пересобрать. Это нужно не только на будущее,
         * когда Google сменит корни, — это единственный способ пропустить
         * через приложение отладочный перехватчик вроде Charles или
         * Proxyman: они подменяют сертификат своим, и без их корня цепочка
         * не пройдёт, потому что она и правда чужая.
         */
        NSArray *paths = [[NSBundle mainBundle] pathsForResourcesOfType:@"der"
                                                            inDirectory:@"certs"];

        NSMutableArray *loaded = [NSMutableArray array];

        for (NSString *path in [paths sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *name = [[path lastPathComponent] stringByDeletingPathExtension];
            NSData *data = [NSData dataWithContentsOfFile:path];

            if ([data length] == 0) {
                NSLog(@"[YouTube/TLS] Корень %@ не прочитан", name);
                continue;
            }

            SecCertificateRef certificate =
                SecCertificateCreateWithData(NULL, (__bridge CFDataRef)data);

            if (certificate != NULL) {
                [loaded addObject:(__bridge_transfer id)certificate];
            } else {
                NSLog(@"[YouTube/TLS] Корень %@ не разобран", name);
            }
        }

        NSLog(@"[YouTube/TLS] Вшитых корней: %lu", (unsigned long)[loaded count]);

        // Имена пишутся один раз: если файл подменён или обрезан, разбор
        // пройдёт, а имя окажется чужим — это видно только так.
        for (id certificate in loaded) {
            CFStringRef summary =
                SecCertificateCopySubjectSummary((__bridge SecCertificateRef)certificate);

            NSLog(@"[YouTube/TLS]   корень: %@",
                  (__bridge NSString *)summary ?: @"без имени");

            if (summary != NULL) {
                CFRelease(summary);
            }
        }

        anchors = [loaded copy];
    });

    return anchors;
}

/**
 * Словами — чтобы в журнале был не голый номер.
 *
 * Зовётся только из строк журнала, а в готовой сборке их нет вовсе —
 * оттого и пометка: без неё компилятор справедливо считает эту работу
 * никому не нужной и останавливает сборку.
 */
__attribute__((unused))
static NSString *YTTrustResultName(SecTrustResultType result) {
    switch (result) {
        case kSecTrustResultInvalid:                 return @"Invalid";
        case kSecTrustResultProceed:                 return @"Proceed";
        case kSecTrustResultDeny:                    return @"Deny";
        case kSecTrustResultUnspecified:             return @"Unspecified";
        case kSecTrustResultRecoverableTrustFailure: return @"RecoverableTrustFailure";
        case kSecTrustResultFatalTrustFailure:       return @"FatalTrustFailure";
        case kSecTrustResultOtherError:              return @"OtherError";
        default:                                     return @"?";
    }
}

/** Сертификаты, которые прислал сервер, в порядке от листа к корню. */
static NSArray *YTChainOf(SecTrustRef trust) {
    NSMutableArray *chain = [NSMutableArray array];

    CFIndex count = SecTrustGetCertificateCount(trust);

    for (CFIndex i = 0; i < count; i++) {
        SecCertificateRef certificate = SecTrustGetCertificateAtIndex(trust, i);

        if (certificate != NULL) {
            [chain addObject:(__bridge id)certificate];
        }
    }

    return chain;
}

/** Пишет в журнал, что именно прислал сервер: имена и число звеньев. */
static void YTLogChain(NSArray *chain) {
    NSLog(@"[YouTube/TLS] Прислано звеньев: %lu", (unsigned long)[chain count]);

    for (NSUInteger i = 0; i < [chain count]; i++) {
        SecCertificateRef certificate = (__bridge SecCertificateRef)[chain objectAtIndex:i];

        CFStringRef summary = SecCertificateCopySubjectSummary(certificate);

        NSLog(@"[YouTube/TLS]   %lu: %@", (unsigned long)i,
              (__bridge NSString *)summary ?: @"без имени");

        if (summary != NULL) {
            CFRelease(summary);
        }
    }
}

/**
 * Проверяет цепочку на **свежем** объекте доверия, а не на присланном.
 *
 * Это не перестраховка. `SecTrustEvaluate` запоминает свой ответ внутри
 * объекта, и повторный вызов после подмены якорей на старых системах
 * возвращает прежний результат — то есть отказ, сколько корней ни добавь.
 * Снаружи это выглядит как «свои корни не работают»: они и не работали,
 * потому что до них дело не доходило.
 *
 * Заодно здесь задаётся своя политика SSL с именем узла: у присланного
 * объекта она уже есть, но, собирая объект заново, её надо поставить
 * самим — иначе имя в сертификате никто не сверит, и проверка станет
 * слабее системной.
 */
static BOOL YTEvaluateWithAnchors(NSArray *chain, NSString *host,
                                  NSArray *anchors, BOOL anchorsOnly) {
    SecPolicyRef policy = SecPolicyCreateSSL(true, (__bridge CFStringRef)host);

    if (policy == NULL) {
        return NO;
    }

    SecTrustRef trust = NULL;

    OSStatus status = SecTrustCreateWithCertificates((__bridge CFArrayRef)chain,
                                                     policy, &trust);
    CFRelease(policy);

    if (status != errSecSuccess || trust == NULL) {
        NSLog(@"[YouTube/TLS] Объект доверия не создан: %ld", (long)status);
        return NO;
    }

    SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)anchors);
    SecTrustSetAnchorCertificatesOnly(trust, anchorsOnly);

    SecTrustResultType result = kSecTrustResultInvalid;

    status = SecTrustEvaluate(trust, &result);

    NSLog(@"[YouTube/TLS] Со своими корнями (%@): %@ (код %ld)",
          anchorsOnly ? @"только они" : @"вместе с системными",
          YTTrustResultName(result), (long)status);

    CFRelease(trust);

    return status == errSecSuccess && YTTrustResultIsOk(result);
}

static BOOL YTTrustIsValid(SecTrustRef trust, NSString *host) {
    SecTrustResultType result = kSecTrustResultInvalid;

    OSStatus status = SecTrustEvaluate(trust, &result);

    if (status == errSecSuccess && YTTrustResultIsOk(result)) {
        return YES;
    }

    /**
     * Системе цепочка не понравилась. Дальше — свои корни, но прежде
     * стоит записать, что вообще происходит: без этого «цепочка отвергнута»
     * не отличить от десятка разных причин.
     *
     * Часы пишутся не зря: на устройстве, пролежавшем в ящике, дата
     * сбрасывается, и тогда **любой** сертификат оказывается просроченным
     * или ещё не начавшим действовать. Выглядит это ровно как отказ
     * доверия, а чинится переводом часов.
     */
    NSLog(@"[YouTube/TLS] %@: система отвергла — %@ (код %ld), часы устройства %@",
          host, YTTrustResultName(result), (long)status, [NSDate date]);

    NSArray *chain = YTChainOf(trust);

    YTLogChain(chain);

    NSArray *anchors = YTBundledAnchors();

    if ([anchors count] == 0 || [chain count] == 0) {
        return NO;
    }

    // Сначала свои корни вместе с системными: так проверка остаётся
    // не слабее обычной.
    if (YTEvaluateWithAnchors(chain, host, anchors, NO)) {
        return YES;
    }

    /**
     * Не вышло — пробуем только свои.
     *
     * Разница не косметическая: пока системные якоря в силе, построитель
     * пути вправе довести цепочку до корня из хранилища и на нём же
     * отказать, не пробуя наш самоподписанный. Запрет на чужие якоря
     * убирает этот тупик.
     *
     * Слабее от этого не становится: наши четыре корня — это и есть те,
     * кем выдано всё, к чему приложение обращается.
     */
    if (YTEvaluateWithAnchors(chain, host, anchors, YES)) {
        return YES;
    }

    /**
     * Последняя ступень: убрать из присланного то, что мешает.
     *
     * Google присылает не только лист и промежуточный, но и **кросс-подписанный**
     * GTS Root R1 — тот, что выдан старым GlobalSign Root CA. Для нового
     * устройства это подарок: цепочка замыкается на GlobalSign, который
     * в системе есть с незапамятных времён. Для нас — помеха: построитель
     * видит в присланном готовое продолжение и тянет путь к GlobalSign,
     * вместо того чтобы остановиться на нашем самоподписанном корне
     * с тем же именем.
     *
     * Поэтому здесь из входного набора выбрасывается всё, чьё имя совпадает
     * с именем одного из наших корней: остаются лист и промежуточные,
     * а замкнуть путь можно только нашим якорем.
     */
    NSMutableSet *anchorNames = [NSMutableSet set];

    for (id certificate in anchors) {
        CFStringRef summary =
            SecCertificateCopySubjectSummary((__bridge SecCertificateRef)certificate);

        if (summary != NULL) {
            [anchorNames addObject:(__bridge NSString *)summary];
            CFRelease(summary);
        }
    }

    NSMutableArray *trimmed = [NSMutableArray array];

    for (id certificate in chain) {
        CFStringRef summary =
            SecCertificateCopySubjectSummary((__bridge SecCertificateRef)certificate);

        NSString *name = (__bridge NSString *)summary;
        BOOL isAnchor = (name != nil && [anchorNames containsObject:name]);

        if (summary != NULL) {
            CFRelease(summary);
        }

        if (!isAnchor) {
            [trimmed addObject:certificate];
        }
    }

    if ([trimmed count] == 0 || [trimmed count] == [chain count]) {
        // Выбрасывать оказалось нечего — эта ступень ничего не добавит.
        return NO;
    }

    NSLog(@"[YouTube/TLS] Пробуем без присланных корней: осталось %lu звеньев",
          (unsigned long)[trimmed count]);

    return YTEvaluateWithAnchors(trimmed, host, anchors, YES);
}


#pragma mark - Клиент

/** Запись кратковременного кеша: тело ответа и время, когда оно получено. */
@interface YTCacheEntry : NSObject
@property (nonatomic, strong) YTHttpResponse *response;
@property (nonatomic, assign) NSTimeInterval storedAt;
@end

@implementation YTCacheEntry
@end


@implementation YTHttp

+ (NSThread *)thread {
    static YTHttpThread *thread = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        thread = [[YTHttpThread alloc] init];
        [thread setName:@"ru.computershik.troubadour.http"];
        [thread start];
    });

    return thread;
}

+ (void)initialize {
    if (self != [YTHttp class]) {
        return;
    }

    // Основной потребитель дискового кеша — превью с i.ytimg.com: они отдаются
    // с длинным max-age и не меняются.
    Class cacheClass = YTNetworkClass(@"NSURLCache");

    id cache = [[cacheClass alloc] initWithMemoryCapacity:2 * 1024 * 1024
                                             diskCapacity:48 * 1024 * 1024
                                                 diskPath:@"youtube-http"];
    [cacheClass setSharedURLCache:cache];
}

+ (NSInteger)trustChecks {
    @synchronized (self) {
        return YTTrustChecks;
    }
}

+ (NSTimeInterval)trustSeconds {
    @synchronized (self) {
        return YTTrustSeconds;
    }
}

+ (NSMutableDictionary *)memoryCache {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        cache = [[NSMutableDictionary alloc] init];
    });

    return cache;
}

+ (YTHttpResponse *)send:(NSURLRequest *)request bodyLimit:(NSUInteger)bodyLimit {
    return [self send:request bodyLimit:bodyLimit caching:YES];
}

+ (YTHttpResponse *)send:(NSURLRequest *)request
               bodyLimit:(NSUInteger)bodyLimit
                 caching:(BOOL)caching {
    if (request == nil) {
        YTHttpResponse *failed = [[YTHttpResponse alloc] init];

        failed.error = [NSError errorWithDomain:YTHttpErrorDomain
                                           code:NSURLErrorBadURL
                                       userInfo:nil];
        return failed;
    }

    if ([NSThread isMainThread]) {
        NSLog(@"[YouTube/HTTP] Запрос с главного потока: %@", [[request URL] absoluteString]);
    }

    YTHttpCall *call = [[YTHttpCall alloc] init];
    [call setCaching:caching];

    return [call run:request bodyLimit:bodyLimit onThread:[self thread]];
}

+ (YTHttpResponse *)stream:(NSURLRequest *)request
                 onHeaders:(void (^)(YTHttpResponse *head))onHeaders
                   onChunk:(BOOL (^)(NSData *chunk))onChunk {
    YTHttpCall *call = [[YTHttpCall alloc] init];

    [call setCaching:NO];
    [call setOnHeaders:onHeaders];
    [call setOnChunk:onChunk];

    return [call run:request bodyLimit:0 onThread:[self thread]];
}

+ (YTHttpResponse *)send:(NSURLRequest *)request
               bodyLimit:(NSUInteger)bodyLimit
             cacheForTTL:(NSTimeInterval)ttl {
    if (ttl <= 0) {
        return [self send:request bodyLimit:bodyLimit];
    }

    /**
     * Ключ — адрес **и тело**.
     *
     * Одним адресом обойтись нельзя, и это выяснилось на устройстве.
     * У InnerTube все обращения идут на горстку одинаковых адресов:
     * лента «Главной», подписки, история и канал — это всё
     * `youtubei/v1/browse`, а различаются они только телом запроса.
     * С ключом по одному адресу ответ подписок (клиент TVHTML5, мегабайт)
     * оседал в кеше и возвращался в ответ на запрос ленты (клиент WEB):
     * запрос «выполнялся» за четыре миллисекунды, разбор проходил,
     * роликов в чужом ответе не находилось — и «Главная» оставалась пустой
     * до истечения TTL.
     *
     * Тело целиком в ключ не кладём: у продолжений там токен в килобайт.
     * Хватает его длины и хеша — совпадение обоих у разных тел настолько
     * маловероятно, что ради него не стоит держать лишнюю память.
     */
    NSData *body = [request HTTPBody];

    NSString *key = [NSString stringWithFormat:@"%@|%lu|%lu",
                     [[request URL] absoluteString],
                     (unsigned long)[body length],
                     (unsigned long)[body hash]];

    NSMutableDictionary *cache = [self memoryCache];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    @synchronized (cache) {
        YTCacheEntry *entry = [cache objectForKey:key];

        if (entry != nil && now - entry.storedAt < ttl) {
            return entry.response;
        }
    }

    /**
     * Одинаковые запросы, ушедшие одновременно, ждут первого.
     *
     * Кеш проверяется до отправки и заполняется после ответа — между
     * этими двумя мгновениями он пуст, и всё, что успело спросить то же
     * самое, уходило в сеть отдельно. При запуске это было видно прямо
     * в журнале: два одинаковых запроса ленты и четыре `accounts_list`
     * подряд — разделы просыпаются разом, и каждый спрашивает своё.
     *
     * Замок на ключ выстраивает их в очередь; второй и следующие,
     * дождавшись, находят готовый ответ в кеше и в сеть не идут.
     */
    @synchronized ([self lockForKey:key]) {
        @synchronized (cache) {
            YTCacheEntry *entry = [cache objectForKey:key];

            // Время берётся заново: пока ждали замок, могло пройти сколько
            // угодно, и ответ, годный минуту назад, мог успеть устареть.
            if (entry != nil
                && [NSDate timeIntervalSinceReferenceDate] - entry.storedAt < ttl) {
                return entry.response;
            }
        }

        return [self fetchAndStore:request bodyLimit:bodyLimit key:key ttl:ttl];
    }
}

/** Замок на ключ — чтобы одинаковые запросы не уходили в сеть разом. */
+ (id)lockForKey:(NSString *)key {
    static NSMutableDictionary *locks = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{ locks = [[NSMutableDictionary alloc] init]; });

    @synchronized (locks) {
        id lock = [locks objectForKey:key];

        if (lock == nil) {
            lock = [[NSObject alloc] init];

            // Столько же, сколько записей в кеше: замки нужны ровно тем
            // ключам, что в нём живут.
            if ([locks count] > 64) {
                [locks removeAllObjects];
            }

            [locks setObject:lock forKey:key];
        }

        return lock;
    }
}

+ (YTHttpResponse *)fetchAndStore:(NSURLRequest *)request
                        bodyLimit:(NSUInteger)bodyLimit
                              key:(NSString *)key
                              ttl:(NSTimeInterval)ttl {
    NSMutableDictionary *cache = [self memoryCache];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    YTHttpResponse *response = [self send:request bodyLimit:bodyLimit];

    if ([response isSuccessful]) {
        YTCacheEntry *entry = [[YTCacheEntry alloc] init];

        entry.response = response;
        entry.storedAt = now;

        @synchronized (cache) {
            // Держать всю историю переходов незачем: кеш нужен на секунды,
            // чтобы возврат назад не перезапрашивал ту же ленту.
            if ([cache count] > 32) {
                [cache removeAllObjects];
            }

            [cache setObject:entry forKey:key];
        }
    }

    return response;
}

+ (void)dropMemoryCache {
    NSMutableDictionary *cache = [self memoryCache];

    @synchronized (cache) {
        [cache removeAllObjects];
    }
}

@end
