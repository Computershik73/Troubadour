#import "YTPoToken.h"

#import <UIKit/UIKit.h>

#import "YTHttp.h"
#import "YTJson.h"
#import "YTUtil.h"

/**
 * Ключ запроса задачи и ключ службы аттестации — постоянные, из
 * `potoken-google.m`. Не секретные: одинаковы у всех и лежат в разметке
 * YouTube.
 */
static NSString *const YTBotguardRequestKey = @"O43z0dpjhgX20SCx4KAo";
static NSString *const YTBotguardApiKey = @"AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw";

/**
 * Страница-решатель разговаривает с нами переходами по служебным адресам:
 * вернуть значение из функции она не может — работа асинхронная.
 *
 *     status://scriptsLoaded  — JavaScript страницы разобран;
 *     status://vmReady        — программа развернулась;
 *     status://poReady        — чеканщик готов;
 *     botguard-response://…   — ответ программы, закодированный процентами.
 *
 * Все они перехватываются в `shouldStartLoadWithRequest:` и никуда
 * не ведут.
 */
static NSString *const YTStatusScheme = @"status://";
static NSString *const YTResponseScheme = @"botguard-response://";

@interface YTPoToken () <UIWebViewDelegate>
@end

@implementation YTPoToken {
    UIWebView *_web;

    /** Куски задачи: сама программа, её имя в окне и код исполнителя. */
    NSString *_program;
    NSString *_globalName;
    NSString *_safeScript;

    /** Токен целостности и срок, после которого его пора обновить. */
    NSString *_integrityToken;
    NSDate *_renewAfter;

    BOOL _started;
    BOOL _ready;

    /** Докуда дошла подготовка — для сторожа и журнала. */
    NSString *_stage;
}

+ (YTPoToken *)shared {
    static YTPoToken *shared = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{ shared = [[YTPoToken alloc] init]; });

    return shared;
}

- (BOOL)isReady {
    @synchronized (self) {
        return _ready;
    }
}

#pragma mark Шаг 1 — страница-решатель

- (void)prepare {
    @synchronized (self) {
        /**
         * Второй заход начинается только тогда, когда токен целостности
         * состарился: подготовка стоит секунд, и повторять её на каждый
         * ролик незачем.
         */
        if (_started && (_renewAfter == nil || [_renewAfter timeIntervalSinceNow] > 0)) {
            return;
        }

        _started = YES;
        _ready = NO;
    }

    YTMain(^{ [self loadSolver]; });
}

- (void)loadSolver {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"challenge_solver"
                                                     ofType:@"html"];

    NSString *html = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];

    if ([html length] == 0) {
        NSLog(@"[YouTube/PO] Решатель не прочитался");
        return;
    }

    /**
     * Вид невидимый, но живой: он должен лежать в окне, иначе WebKit
     * не станет исполнять его JavaScript. Тот же приём в оригинале —
     * рамка вынесена за край экрана.
     */
    if (_web == nil) {
        _web = [[UIWebView alloc] initWithFrame:CGRectMake(-500, -500, 100, 100)];
        [_web setDelegate:self];

        [[[UIApplication sharedApplication] keyWindow] addSubview:_web];
    }

    NSLog(@"[YouTube/PO] Открываем решатель (%lu КБ)",
          (unsigned long)([html length] / 1024));

    _stage = @"страница открыта";

    /**
     * Сторож подготовки.
     *
     * Вся она — разговор со страницей: та сама сообщает, что загрузилась,
     * что завела исполнителя, что готова чеканить. Оборвись разговор на
     * любом шаге — и в журнале просто не будет следующей строки; понять,
     * ждём мы сеть, страницу или уже ничего, нельзя. Сторож говорит это
     * вслух и позволяет начать заново со следующего ролика.
     */
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(checkProgress)
                                               object:nil];

    [self performSelector:@selector(checkProgress) withObject:nil afterDelay:25.0];

    /**
     * Адрес основы обязателен: программа проверяет, откуда её запустили,
     * и с пустой основой отказывается работать.
     */
    [_web loadHTMLString:html baseURL:[NSURL URLWithString:@"https://www.youtube.com"]];
}

/** Сторож: подготовка либо кончилась, либо застряла — и мы скажем, где. */
- (void)checkProgress {
    if ([self isReady]) {
        return;
    }

    NSLog(@"[YouTube/PO] Чеканщик не поднялся за 25 с, дошли до «%@» — "
          @"попробуем заново при следующем ролике",
          [_stage length] > 0 ? _stage : @"начала");

    /**
     * Снимаем пометку «подготовка началась», иначе следующий ролик
     * увидит её и молча уйдёт, а заканчивать её будет уже нечему.
     */
    @synchronized (self) {
        _started = NO;
    }
}

#pragma mark Разговор со страницей

- (BOOL)webView:(UIWebView *)webView
    shouldStartLoadWithRequest:(NSURLRequest *)request
                navigationType:(UIWebViewNavigationType)navigationType {
    NSString *url = [[request URL] absoluteString];

    if ([url hasPrefix:YTStatusScheme]) {
        NSString *status = [url substringFromIndex:[YTStatusScheme length]];

        NSLog(@"[YouTube/PO] Решатель: %@", status);

        _stage = [status copy];

        if ([status isEqualToString:@"scriptsLoaded"]) {
            // Задачу спрашиваем в фоне: это сеть, а мы на главном потоке.
            YTAsync(^{ [self requestChallenge]; });
        } else if ([status isEqualToString:@"vmReady"]) {
            [self askBotguard];
        } else if ([status isEqualToString:@"poReady"]) {
            @synchronized (self) { _ready = YES; }

            [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                     selector:@selector(checkProgress)
                                                       object:nil];

            NSLog(@"[YouTube/PO] Готово: чеканщик поднят");
        }

        return NO;
    }

    if ([url hasPrefix:YTResponseScheme]) {
        NSString *raw = [url substringFromIndex:[YTResponseScheme length]];
        NSString *answer = [raw stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

        NSLog(@"[YouTube/PO] Ответ программы: %lu знаков",
              (unsigned long)[answer length]);

        YTAsync(^{ [self requestIntegrityToken:answer]; });

        return NO;
    }

    return YES;
}

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error {
    NSLog(@"[YouTube/PO] Решатель не загрузился: %@", [error localizedDescription]);
}

#pragma mark Шаг 2 — задача от Google

/**
 * Общий ход к службе аттестации. `Create` выдаёт задачу, `GenerateIT` —
 * токен целостности; отличаются они только именем и телом.
 */
- (NSDictionary *)askAttestation:(NSString *)method body:(NSDictionary *)body {
    NSString *address = [NSString stringWithFormat:
        @"https://www.youtube.com/api/jnn/v1/%@?noauth=1", method];

    NSMutableURLRequest *request =
        YTRequest(address, NSURLRequestReloadIgnoringLocalCacheData, 25.0);

    if (request == nil) {
        return nil;
    }

    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"content-type"];
    [request setValue:YTBotguardApiKey forHTTPHeaderField:@"x-goog-api-key"];
    [request setValue:@"grpc-web-javascript/0.1" forHTTPHeaderField:@"x-user-agent"];

    // Служба общая для всех: сеанс аккаунта ей не нужен и только мешает.
    [request setHTTPShouldHandleCookies:NO];

    [request setHTTPBody:[YTJson encode:body]];

    /**
     * Три захода вместо одного.
     *
     * Код 0 — это не отказ службы, а несостоявшийся разговор: не нашлось
     * имя хоста, не сложилось TLS, оборвалась связь. На неспешных и
     * капризных сетях такое случается именно в первые секунды после
     * запуска, когда мы сюда и приходим, — а цена промаха велика:
     * без задачи не будет ни токена целостности, ни PO-токена, и весь
     * сеанс пройдёт без них. Повтор через полторы секунды почти всегда
     * попадает.
     */
    YTHttpResponse *response = nil;

    for (NSInteger attempt = 0; attempt < 3; attempt++) {
        response = [YTHttp send:request bodyLimit:4 * 1024 * 1024];

        if ([response isSuccessful]) {
            return [YTJson parse:response.body];
        }

        NSLog(@"[YouTube/PO] %@: код %ld%@", method, (long)response.statusCode,
              (attempt < 2) ? @" — пробуем снова" : @"");

        // Отказ службы повторять незачем: он придёт тот же.
        if (response.statusCode != 0) {
            return nil;
        }

        if (attempt < 2) {
            [NSThread sleepForTimeInterval:1.5];
        }
    }

    return nil;
}

- (void)requestChallenge {
    NSDictionary *json = [self askAttestation:@"Create"
                                         body:[NSDictionary dictionaryWithObject:YTBotguardRequestKey
                                                                          forKey:@"request_key"]];

    /**
     * Задача приходит перемешанной: это base64, у которого к каждому байту
     * прибавлено 97. Обратное действие даёт обычный JSON — порт
     * `descrambleChallenge`. Имя поля не закреплено, поэтому берём
     * единственную длинную строку в ответе.
     */
    NSString *scrambled = nil;

    for (id value in [json allValues]) {
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 100) {
            scrambled = value;
            break;
        }
    }

    NSArray *parts = [self descramble:scrambled];

    if ([parts count] < 6) {
        NSLog(@"[YouTube/PO] Задача не разобралась — попробуем при следующем ролике");

        /**
         * Снимаем пометку «подготовка началась».
         *
         * Без этого один неудачный заход при запуске означал сеанс вовсе
         * без PO-токена: `prepare` при каждом следующем ролике видел
         * начатую подготовку и молча уходил, а закончиться ей было уже
         * нечем. Теперь следующий ролик начнёт заново.
         */
        @synchronized (self) {
            _started = NO;
        }

        return;
    }

    /**
     * Раскладка та же, что в оригинале:
     *
     *     [1] — код исполнителя (список строк), он и заводит в окне объект,
     *           имя которого лежит в [5];
     *     [4] — сама программа;
     *     [5] — имя этого объекта.
     */
    id script = [parts objectAtIndex:1];

    if ([script isKindOfClass:[NSArray class]]) {
        for (id piece in script) {
            if ([piece isKindOfClass:[NSString class]] && [(NSString *)piece length] > 0) {
                script = piece;
                break;
            }
        }
    }

    @synchronized (self) {
        _safeScript = [script isKindOfClass:[NSString class]] ? [script copy] : nil;
        _program = [[parts objectAtIndex:4] copy];
        _globalName = [[parts objectAtIndex:5] copy];
    }

    if ([_safeScript length] == 0 || [_program length] == 0) {
        NSLog(@"[YouTube/PO] В задаче нет программы");
        return;
    }

    NSLog(@"[YouTube/PO] Задача получена: программа %lu знаков, исполнитель %lu КБ",
          (unsigned long)[_program length], (unsigned long)([_safeScript length] / 1024));

    _stage = @"задача получена";

    YTMain(^{ [self startProgram]; });
}

- (NSArray *)descramble:(NSString *)scrambled {
    if ([scrambled length] == 0) {
        return nil;
    }

    NSData *raw = [[NSData alloc] initWithBase64Encoding:scrambled];

    if ([raw length] == 0) {
        return nil;
    }

    NSMutableData *plain = [NSMutableData dataWithLength:[raw length]];

    const char *from = [raw bytes];
    char *to = [plain mutableBytes];

    for (NSUInteger i = 0; i < [raw length]; i++) {
        to[i] = from[i] + 97;
    }

    id json = [NSJSONSerialization JSONObjectWithData:plain options:0 error:NULL];

    return [json isKindOfClass:[NSArray class]] ? json : nil;
}

#pragma mark Шаг 3 — запуск программы

/**
 * Сперва в страницу вкладывается код исполнителя, и только потом
 * запускается программа: до этого объекта с нужным именем в окне нет,
 * и запуск отвечает «vm not found».
 */
- (void)startProgram {
    NSString *script = nil;
    NSString *program = nil;
    NSString *globalName = nil;

    @synchronized (self) {
        script = _safeScript;
        program = _program;
        globalName = _globalName;

        // Держать их дальше незачем: программа разворачивается один раз,
        // а весит она немало.
        _safeScript = nil;
        _program = nil;
    }

    [_web stringByEvaluatingJavaScriptFromString:script];

    NSString *run = [NSString stringWithFormat:
        @"(function(){try{runBotguardChallenge(\"%@\",\"%@\");return 'запущено';}"
        @"catch(e){return 'ошибка: '+e;}})()", program, globalName];

    NSString *result = [_web stringByEvaluatingJavaScriptFromString:run];

    NSLog(@"[YouTube/PO] Программа: %@", result ?: @"ответа нет");
}

/** Программа развернулась — просим у неё ответ для службы аттестации. */
- (void)askBotguard {
    NSString *result = [_web stringByEvaluatingJavaScriptFromString:
        @"(function(){try{createPOSignalOutput();return 'спрошено';}"
        @"catch(e){return 'ошибка: '+e;}})()"];

    NSLog(@"[YouTube/PO] Ответ у программы: %@", result ?: @"ответа нет");
}

#pragma mark Шаг 4 — токен целостности

- (void)requestIntegrityToken:(NSString *)botguardResponse {
    NSDictionary *json = [self askAttestation:@"GenerateIT"
                                         body:[NSDictionary dictionaryWithObjectsAndKeys:
                                                  YTBotguardRequestKey, @"request_key",
                                                  botguardResponse, @"botguard_response",
                                                  nil]];

    NSString *token = [YTJson textIn:json key:@"integrityToken"];

    if ([token length] == 0) {
        NSLog(@"[YouTube/PO] Токена целостности не выдали");
        return;
    }

    /**
     * Срок сервер называет сам. Обновляем на восьмидесяти процентах —
     * так же, как `integrityTokenShouldProbablyRenew` в оригинале:
     * лучше обновиться заранее, чем посреди воспроизведения.
     */
    NSInteger ttl = [YTJson intIn:json key:@"estimatedTtlSecs" fallback:3600];

    @synchronized (self) {
        _integrityToken = [token copy];
        _renewAfter = [NSDate dateWithTimeIntervalSinceNow:ttl * 0.8];
    }

    NSLog(@"[YouTube/PO] Токен целостности получен, годен %ld с", (long)ttl);

    _stage = @"токен целостности получен";

    YTMain(^{
        NSString *start = [NSString stringWithFormat:
            @"(function(){try{processIntegrityToken(\"%@\");return 'поднимаем';}"
            @"catch(e){return 'ошибка: '+e;}})()", token];

        NSLog(@"[YouTube/PO] Чеканщик: %@",
              [_web stringByEvaluatingJavaScriptFromString:start] ?: @"ответа нет");
    });
}

#pragma mark Шаг 5 — чеканка

- (NSString *)tokenFor:(NSString *)binding {
    if (![self isReady] || [binding length] == 0) {
        return nil;
    }

    /**
     * Чеканка идёт в браузере, а он живёт на главном потоке. Запросы
     * к `/player` идут из фона, поэтому переход обязателен — и он
     * синхронный: токен нужен прямо сейчас, а занимает чеканка
     * миллисекунды.
     */
    __block NSString *token = nil;

    dispatch_block_t mint = ^{
        token = [_web stringByEvaluatingJavaScriptFromString:
            [NSString stringWithFormat:
                @"(function(){try{return mintPOToken(\"%@\")||'';}"
                @"catch(e){return '';}})()", binding]];
    };

    if ([NSThread isMainThread]) {
        mint();
    } else {
        dispatch_sync(dispatch_get_main_queue(), mint);
    }

    if ([token length] == 0) {
        NSLog(@"[YouTube/PO] Токен не отчеканился для %@", binding);

        return nil;
    }

    return token;
}

@end
