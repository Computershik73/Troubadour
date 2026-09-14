#import "YTSimpleScreens.h"

#import "YTStrings.h"

#import "YTHttp.h"
#import "YTWebAuth.h"
#import "YTMetrics.h"
#import "YTSkin.h"
#import "YTTheme.h"
#import "YTUtil.h"

/**
 * Проверка «вы не робот».
 *
 * Капчи в ответе `/player` нет и быть не может: сервер отвечает только
 * состоянием `LOGIN_REQUIRED` и строкой «Войдите в аккаунт, чтобы
 * подтвердить, что вы не бот». Сама проверка живёт не в API, а на
 * странице: при обращении с помеченного адреса Google отдаёт браузеру
 * страницу `google.com/sorry` с reCAPTCHA, и решается она только там.
 *
 * Поэтому здесь встроенный браузер, а не своя картинка. Он открывает
 * обычную страницу ролика; если проверка нужна — Google покажет её сам,
 * и человек решит её как в браузере.
 *
 * Работает это по одной причине: **UIWebView делит хранилище cookie
 * с NSURLConnection**. Печенье, выданное за пройденную проверку
 * (`GOOGLE_ABUSE_EXEMPTION`), попадает в то же общее хранилище, из
 * которого их берут наши запросы. С WKWebView так бы не вышло — у него
 * хранилище своё, и решённая проверка осталась бы внутри него.
 *
 * Оговорка, которую стоит знать заранее: потоки берутся у клиента
 * ANDROID_VR, а он ходит без cookie вовсе. Ему помогает не само печенье,
 * а то, что после пройденной проверки Google снимает пометку с адреса
 * целиком — обычно на несколько часов. То есть способ рабочий, но
 * не гарантированный.
 */

/**
 * Кем представляется встроенный браузер.
 *
 * Со своим настоящим именем — WebKit 537.51 от iOS 7 — Google встречает
 * страницей «обновите браузер» вместо проверки, и решать становится
 * нечего. Поэтому имя подменяется.
 *
 * Выбор — про равновесие, и оба края плохи. Назовёшься слишком свежим
 * (нынешний Chrome) — придёт нынешняя сборка страницы, которую движок
 * семёрки не выполнит вовсе. Останешься собой — не пустят на порог.
 * Отсюда середина: Safari из iOS 12. Он новее порога, за которым Google
 * считает браузер устаревшим, и при этом его сборка страницы — эпохи ES6,
 * с которой WebKit семёрки хоть как-то справляется.
 *
 * Строка настоящая, не сочинённая: такую шлёт Safari на iPhone с iOS 12.5.7.
 */
static NSString *const YTChallengeUserAgent =
    @"Mozilla/5.0 (iPhone; CPU iPhone OS 12_5_7 like Mac OS X) "
    @"AppleWebKit/605.1.15 (KHTML, like Gecko) Version/12.1.2 Mobile/15E148 Safari/604.1";

/**
 * Имя для страницы входа — Opera Mini.
 *
 * Расчёт обратный тому, что у проверки. Нынешняя страница входа
 * (`GlifWebSignIn`) — целиком приложение на JavaScript: формы там нет
 * вовсе, поля рисованные, отправка идёт запросом изнутри. Впрыск значения
 * в такое поле не помогает — приложение держит своё состояние отдельно
 * и чужую подстановку не замечает; в журнале «ок», а на экране пусто.
 *
 * Зато у Google до сих пор жива простая разметка для браузеров, которым
 * JavaScript не по силам, — с настоящим `<form>` и обычной отправкой.
 * Отдаётся она по имени браузера, и Opera Mini на Symbian — как раз
 * тот случай: дальше некуда.
 *
 * Если простую разметку всё же не отдадут, ничего не сломается: страница
 * останется прежней, а рядом есть вставка куки, которой всё равно, что
 * там за разметка.
 */
static NSString *const YTLoginUserAgent =
    @"Opera/9.80 (J2ME/MIDP; Opera Mini/5.0 (SymbianOS/24.838; U; en) "
    @"Presto/2.5.25 Version/10.54";

/**
 * Подменяет имя браузера для UIWebView.
 *
 * Другого способа нет: заголовок, положенный в сам запрос, UIWebView
 * перепишет своим — он ходит в сеть сам и заголовки собирает сам.
 * Единственная точка, которую он слушает, — ключ `UserAgent`
 * в NSUserDefaults; оттуда WebKit берёт имя при создании каждого вида.
 *
 * На наши собственные запросы это не влияет: они ставят `User-Agent`
 * явно, каждый свой — TV-клиенту тизеновский, ANDROID_VR оculus-овский.
 */
static void YTUseUserAgent(NSString *agent) {
    [[NSUserDefaults standardUserDefaults] registerDefaults:
        [NSDictionary dictionaryWithObject:agent forKey:@"UserAgent"]];

    // `registerDefaults:` не перебивает уже записанное значение, поэтому
    // на всякий случай кладём и поверх: иначе однажды сохранённое чужое
    // имя пережило бы перезапуск и осталось бы навсегда.
    [[NSUserDefaults standardUserDefaults] setObject:agent forKey:@"UserAgent"];
}


/**
 * Нынешний веб-вид зовётся без своих заголовков.
 *
 * Подключить `WebKit` обычным `#import` нельзя: проект собирается
 * с модулями, а модуль этой библиотеки в нашем SDK не собирается вовсе —
 * компилятор отвечает «файл не найден». Да и не нужно: классы всё равно
 * берутся по имени, потому что на iOS 5 и 6 их нет, а обращения идут
 * через `performSelector:` — так подписи не спорят с одноимёнными
 * методами старого веб-вида.
 */
@interface YTChallengeViewController () <UIWebViewDelegate>
@end

@implementation YTChallengeViewController {
    NSString *_videoId;
    dispatch_block_t _onDone;

    UIView *_bar;
    UIButton *_close;
    UILabel *_barTitle;
    UIButton *_done;

    UIWebView *_web;

    /** Нынешний веб-вид — им открывается вход там, где он есть. */
    UIView *_modern;

    /** Сторож входа: посматривает, не появилась ли веб-сессия. */
    NSTimer *_watch;

    /** Сколько кук перенесли в прошлый раз — чтобы не повторяться в журнале. */
    NSUInteger _movedCookies;

    YTLoadingRing *_busy;
    UILabel *_hint;

    /**
     * Куда и с чем возвращать решённую проверку.
     *
     * Снимается со страницы `/sorry` до ухода на запасную форму: сама
     * страница к тому времени будет уже выгружена, а без её скрытых полей
     * (`continue`, `q`) отправлять токен некуда.
     */
    NSString *_returnAction;
    NSString *_returnFields;

    BOOL _fallbackTried;
    BOOL _tokenSent;

    /** Экран открыт ради входа, а не ради проверки. */
    BOOL _login;
}

- (id)initWithVideoId:(NSString *)videoId done:(dispatch_block_t)done {
    self = [super init];

    if (self != nil) {
        _videoId = [videoId copy];
        _onDone = [done copy];
    }

    return self;
}

- (id)initForLoginWithDone:(dispatch_block_t)done {
    self = [self initWithVideoId:nil done:done];

    if (self != nil) {
        _login = YES;
    }

    return self;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return YES;
}

- (void)loadView {
    YTUseFullScreenLayout(self);

    [super loadView];

    [[self view] setBackgroundColor:[YTTheme background]];

    _bar = [[UIView alloc] initWithFrame:CGRectZero];
    [YTSkin paintBar:_bar];
    [[self view] addSubview:_bar];

    _close = [UIButton buttonWithType:UIButtonTypeCustom];
    [[_close titleLabel] setFont:YTFontRegular(24)];
    [_close setTitle:@"‹" forState:UIControlStateNormal];
    [_close setTitleColor:[YTTheme primaryText] forState:UIControlStateNormal];
    [_close addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_close];

    _barTitle = YTLabel(YTFontSemiBold(16), [YTTheme primaryText], 1);
    [_barTitle setText:_login ? YTLoc(@"Вход") : YTLoc(@"Проверка")];
    [_bar addSubview:_barTitle];

    // «Готово» закрывает окно и просит страницу ролика попробовать снова:
    // понять со стороны, что проверка пройдена, нельзя — Google просто
    // перестаёт её показывать.
    _done = [UIButton buttonWithType:UIButtonTypeCustom];
    [[_done titleLabel] setFont:YTFontMedium(15)];
    [_done setTitle:YTLoc(@"Готово") forState:UIControlStateNormal];
    [_done setTitleColor:[YTTheme accentBlue] forState:UIControlStateNormal];
    [_done addTarget:self action:@selector(finish) forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_done];

    _hint = YTLabel(YTFontRegular(13), [YTTheme secondaryText], 0);
    [_hint setTextAlignment:NSTextAlignmentCenter];
    [_hint setText:_login
        ? YTLoc(@"Войдите в аккаунт Google. После входа окно закроется само.")
        : YTLoc(@"Пройдите проверку и нажмите «Готово». Если поле проверки пустое — "
                @"движок этой версии iOS её не рисует.")];
    [[self view] addSubview:_hint];

    /**
     * Имя ставится до создания вида: WebKit читает его один раз, при
     * создании, и позже сменить его этому виду уже нельзя.
     *
     * Вход открывается под Opera Mini, проверка — под Safari из iOS 12,
     * и это проверено обоими краями.
     *
     * Под Opera Mini проверка отвечает прямым отказом: «Чтобы увидеть
     * reCAPTCHA, перейдите на поддерживаемый браузер». Под iOS 12 хотя бы
     * приходит страница целиком, пусть виджет на ней и остаётся пустым.
     * Из двух плохих исходов второй полезнее: страницу видно, и человек
     * может хотя бы прочитать, что о нём думает Google.
     */
    YTUseUserAgent(_login ? YTLoginUserAgent : YTChallengeUserAgent);

    if ([self modernWebAvailable]) {
        /**
         * Вход открываем нынешним веб-видом.
         *
         * Старый на iOS 14 падает прямо на страницах входа Google — не
         * у нас в коде, а внутри самого движка: в отчёте о падении вся
         * цепочка от начала до конца системная, наших строк там нет
         * вовсе. Починить это изнутри нельзя, а обойти можно: нынешний
         * веб-вид работает отдельным процессом, современные страницы
         * ему привычны, и падать в нашем приложении там нечему.
         *
         * Куки он держит у себя, и мы их сами перекладываем в общее
         * хранилище — см. `harvestModernCookies`.
         */
        _modern = [[NSClassFromString(@"WKWebView") alloc] initWithFrame:CGRectZero];

        [_modern performSelector:@selector(setNavigationDelegate:) withObject:self];
        [_modern setBackgroundColor:[YTTheme background]];

        [[self view] addSubview:_modern];
    } else {
        _web = [[UIWebView alloc] initWithFrame:CGRectZero];
        [_web setDelegate:self];
        [_web setScalesPageToFit:YES];
        [_web setBackgroundColor:[YTTheme background]];
        [[self view] addSubview:_web];
    }

    _busy = [[YTLoadingRing alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_busy];


    /**
     * Либо страница входа, либо страница ролика.
     *
     * Вход — тот же, каким входит SimpMusicLumia: обычная страница Google
     * с возвратом на youtube.com. После неё в общем хранилище остаются
     * куки настоящего сеанса, и ими подписываются наши запросы.
     *
     * Страница ролика открывается ради проверки: если Google хочет её
     * показать, он подставит её сам.
     */
    NSString *address = _login
        ? [YTWebAuth loginUrl]
        : [NSString stringWithFormat:@"https://m.youtube.com/watch?v=%@", _videoId ?: @""];

    [_busy start];

    /**
     * Класс запроса берётся по имени в рантайме, а не по ссылке.
     *
     * Это то самое правило, ради которого в проекте существует
     * `YTNetworkClass`: семья NSURL* переезжала между Foundation
     * и CFNetwork, в SDK 9.3 она числится за CFNetwork, а на iOS 7 живёт
     * в Foundation. Двухуровневые имена означают, что dyld ищет класс
     * ровно в названной библиотеке и, не найдя, отказывает целиком —
     * приложение умирает до main:
     *
     *     Symbol not found: _OBJC_CLASS_$_NSURLRequest
     *     Expected in: CFNetwork.framework/CFNetwork
     *
     * Поиск по имени этого узла не завязывает вовсе: класс находится там,
     * где он есть сегодня.
     */
    NSMutableURLRequest *request =
        [YTNetworkClass(@"NSMutableURLRequest") requestWithURL:[NSURL URLWithString:address]];

    NSLog(@"[YouTube/Проверка] Открываем %@", address);
    NSLog(@"[YouTube/Проверка] Представляемся: %@",
          _modern != nil ? @"нынешний веб-вид, имя своё"
                         : (_login ? YTLoginUserAgent : YTChallengeUserAgent));

    if (_modern != nil) {
        [_modern performSelector:@selector(loadRequest:) withObject:request];
    } else {
        [_web loadRequest:request];
    }
}

/**
 * Есть ли на этой системе нынешний веб-вид **вместе** с доступом к его
 * кукам.
 *
 * Одного веб-вида мало: без хранилища куки останутся у него внутри, и
 * вход, пройденный на глазах, для наших запросов не случится. Хранилище
 * появилось в iOS 11 — до неё пользуемся старым видом, который там
 * и работает исправно.
 */
- (BOOL)modernWebAvailable {
    if (!_login) {
        return NO;
    }

    Class view = NSClassFromString(@"WKWebView");
    Class store = NSClassFromString(@"WKWebsiteDataStore");

    if (view == nil || store == nil ||
        ![store respondsToSelector:@selector(defaultDataStore)]) {
        return NO;
    }

    id jar = [store performSelector:@selector(defaultDataStore)];

    return [jar respondsToSelector:@selector(httpCookieStore)];
}

/**
 * Перекладывает куки из хранилища нынешнего веб-вида в общее.
 *
 * Наши запросы ходят обычным сетевым стеком и о его хозяйстве не знают;
 * без этого переноса вход виден на экране, но не в запросах.
 */
- (void)harvestModernCookies {
    Class store = NSClassFromString(@"WKWebsiteDataStore");

    id data = [store performSelector:@selector(defaultDataStore)];
    id jar = [data performSelector:@selector(httpCookieStore)];

    if (![jar respondsToSelector:@selector(getAllCookies:)]) {
        return;
    }

    __weak YTChallengeViewController *weakSelf = self;

    void (^collect)(NSArray *) = ^(NSArray *cookies) {
        id shared = [YTNetworkClass(@"NSHTTPCookieStorage") sharedHTTPCookieStorage];

        NSUInteger moved = 0;

        for (NSHTTPCookie *cookie in cookies) {
            NSString *domain = [cookie domain];

            if ([domain rangeOfString:@"youtube.com"].location == NSNotFound &&
                [domain rangeOfString:@"google.com"].location == NSNotFound) {
                continue;
            }

            [shared setCookie:cookie];

            moved++;
        }

        YTChallengeViewController *screen = weakSelf;

        if (screen == nil) {
            return;
        }

        if (![YTWebAuth isSignedIn]) {
            /**
             * Говорим только когда число изменилось.
             *
             * Сторож заглядывает сюда каждые две секунды, и без этой
             * проверки журнал заполнялся десятками одинаковых строк,
             * в которых тонуло всё остальное.
             */
            if (moved != screen->_movedCookies) {
                screen->_movedCookies = moved;

                NSLog(@"[YouTube/Вход] Перенесено кук: %lu, сеанса пока нет",
                      (unsigned long)moved);
            }

            return;
        }

        NSLog(@"[YouTube/Вход] Веб-сессия получена (перенесено кук: %lu, %@)",
              (unsigned long)moved, [YTWebAuth sessionReport]);

        [YTWebAuth keepSession];

        [screen finish];
    };

    [jar performSelector:@selector(getAllCookies:) withObject:collect];
}

/**
 * Страница нынешнего веб-вида догрузилась.
 *
 * Подпись здесь без типов WebKit — они бы потребовали его заголовков;
 * рантайму же довольно совпадения имени, а оба довода — объекты.
 */
- (void)webView:(id)webView didFinishNavigation:(id)navigation {
    [_busy stop];
    [_busy setHidden:YES];

    id address = [webView performSelector:@selector(URL)];

    NSLog(@"[YouTube/Проверка] Загрузилось: %@",
          [address absoluteString] ?: @"адрес неизвестен");

    [self harvestModernCookies];
}

- (void)webView:(id)webView
    didFailProvisionalNavigation:(id)navigation
                       withError:(NSError *)error {
    [_busy stop];
    [_busy setHidden:YES];

    NSLog(@"[YouTube/Проверка] Не загрузилось: %@", [error localizedDescription]);

    /**
     * Куки смотрим и после неудачи.
     *
     * Последний шаг входа Google заканчивает уходом на youtube.com, а тот
     * норовит открыться в настоящем приложении — переход обрывается, и
     * «догрузилось» не приходит вовсе. Куки при этом уже поставлены, и
     * если не заглянуть сюда, окно входа останется висеть при готовой
     * сессии: ровно то, из-за чего непонятно, принят вход или нет.
     */
    [self harvestModernCookies];
}

- (void)webView:(id)webView didFailNavigation:(id)navigation withError:(NSError *)error {
    [self webView:webView didFailProvisionalNavigation:navigation withError:error];
}

/**
 * Куда пускать нынешний веб-вид.
 *
 * Только по http и https. Всё остальное — попытка увести человека
 * в настоящее приложение YouTube (`vnd.youtube:` и подобные): вход
 * при этом обрывается на полушаге, а вернуться в наше окно уже нечем.
 */
- (void)webView:(id)webView
    decidePolicyForNavigationAction:(id)action
                    decisionHandler:(void (^)(NSInteger))decide {
    id request = [action performSelector:@selector(request)];
    NSURL *address = [request performSelector:@selector(URL)];

    NSString *scheme = [[address scheme] lowercaseString];

    BOOL web = [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];

    if (!web && [scheme length] > 0) {
        NSLog(@"[YouTube/Проверка] Не пускаем в «%@» — остаёмся в окне входа", scheme);
    }

    /**
     * На сам YouTube в окне входа не ходим вовсе.
     *
     * Туда Google уводит последним шагом — «continue=youtube.com», — и
     * дело там уже сделано: куки поставлены. А вот система на такой адрес
     * отзывается настоящим приложением YouTube и выбрасывает туда человека
     * прямо посреди входа. Поэтому переход отменяем, забираем куки и
     * закрываемся сами.
     */
    if (web && _login &&
        [[[address host] lowercaseString] rangeOfString:@"youtube.com"].location != NSNotFound) {

        NSLog(@"[YouTube/Вход] Google увёл на youtube.com — вход закончен, "
              @"дальше не идём");

        decide(0);

        [self harvestModernCookies];

        return;
    }

    // 0 — отменить, 1 — разрешить; числа из `WKNavigationActionPolicy`.
    decide(web ? 1 : 0);
}

- (void)dealloc {
    [_web setDelegate:nil];
    [_web stopLoading];

    [_modern performSelector:@selector(setNavigationDelegate:) withObject:nil];
    [_modern performSelector:@selector(stopLoading)];

    [_watch invalidate];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    if (!_login || _modern == nil || _watch != nil) {
        return;
    }

    /**
     * Пока окно входа открыто, поглядываем на куки сами.
     *
     * Опираться на переходы страницы оказалось нельзя: последний шаг
     * Google обрывает уходом на youtube.com, и «догрузилось» не приходит.
     * Сессия к этому мигу уже готова, а окно висит — со стороны это
     * выглядит как «вошёл, но приложение не заметило».
     */
    _watch = [NSTimer scheduledTimerWithTimeInterval:2.0
                                              target:self
                                            selector:@selector(lookForSession)
                                            userInfo:nil
                                             repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];

    [_watch invalidate];

    _watch = nil;
}

/** Не появилась ли веб-сессия, пока человек возится со входом. */
- (void)lookForSession {
    [self harvestModernCookies];
}

- (void)cancel {
    [YTNav pop];
}

- (void)finish {
    dispatch_block_t done = _onDone;

    [YTNav pop];

    if (done != nil) {
        done();
    }
}

#pragma mark Браузер

- (void)webViewDidStartLoad:(UIWebView *)webView {
    NSLog(@"[YouTube/Проверка] Загрузка началась");
}

/** Что лежит в общем хранилище куки — для журнала. */
- (void)countCookies {
    /**
     * Класс берётся по имени, а не напрямую: прямая ссылка тянет за собой
     * CFNetwork, которого на iOS 5 в этом виде нет, и приложение там
     * не запускается вовсе. Проверка сборки это ловит.
     */
    id storage = [YTNetworkClass(@"NSHTTPCookieStorage") sharedHTTPCookieStorage];

    NSUInteger all = [[storage cookies] count];
    NSUInteger ours = 0;

    NSMutableArray *names = [NSMutableArray array];

    for (NSHTTPCookie *cookie in [storage cookies]) {
        if ([[cookie domain] rangeOfString:@"youtube.com"].location == NSNotFound &&
            [[cookie domain] rangeOfString:@"google.com"].location == NSNotFound) {
            continue;
        }

        ours++;

        if ([names count] < 8) {
            [names addObject:[cookie name]];
        }
    }

    NSLog(@"[YouTube/Вход] Куки сеанса пока нет: в хранилище %lu штук, "
          @"из них своих %lu%@%@",
          (unsigned long)all, (unsigned long)ours,
          [names count] > 0 ? @" — " : @"",
          [names count] > 0 ? [names componentsJoinedByString:@", "] : @"");
}

- (void)webViewDidFinishLoad:(UIWebView *)webView {
    [_busy stop];
    [_busy setHidden:YES];

    /**
     * Куда в итоге попали — по этому и видно, показали ли проверку:
     * страница `google.com/sorry` и есть она.
     */
    NSString *where = [[[webView request] URL] absoluteString];

    NSLog(@"[YouTube/Проверка] Загрузилось: %@", where ?: @"адрес неизвестен");

    /**
     * Вход закончился ровно тогда, когда в хранилище появились куки
     * сеанса, — ждать какого-то определённого адреса нельзя: Google
     * водит по нескольким страницам и на разных аккаунтах по-разному.
     */
    if (_login) {
        if ([YTWebAuth isSignedIn]) {
            NSLog(@"[YouTube/Вход] Веб-сессия получена");

            /**
             * И сразу откладываем её про запас.
             *
             * До следующего запуска положенное веб-видом доходит не
             * всегда, а выглядит это так, будто вход слетел: сейчас всё
             * играет, а после перезапуска снова просят войти.
             */
            [YTWebAuth keepSession];

            [self finish];

            return;
        }

        /**
         * Куки не появились — говорим, сколько их вообще видно.
         *
         * Отличает два совсем разных случая: человек ещё не дошёл до
         * конца входа (куки чужие и их немного) — или веб-вид кладёт их
         * не в то хранилище, из которого их берут наши запросы, и тогда
         * их не будет вовсе, сколько ни входи. Второе на новых системах
         * вероятнее всего, а по журналу до сих пор было неразличимо.
         */
        [self countCookies];

        return;
    }

    /**
     * Проверка принята, и Google увёл нас обратно на YouTube — значит
     * печенье поставлено и делать здесь больше нечего. Закрываемся сами
     * и просим страницу ролика попробовать снова: заставлять человека
     * нажимать «Готово» после уже пройденной проверки незачем.
     */
    if (_tokenSent && [where rangeOfString:@"/sorry"].location == NSNotFound) {
        NSLog(@"[YouTube/Проверка] Пройдена, возвращаемся к ролику");

        [self finish];

        return;
    }

    // Решённая проверка отдаёт токен — его надо вернуть на `/sorry`.
    if ([self sendTokenIfPresent]) {
        return;
    }

    /**
     * Запасная форма открылась, но без самой проверки: у неё нет формы,
     * зато есть жалоба «не удается связаться с сервисом». Значит адрес
     * подобран не тот — молчать об этом нельзя.
     */
    if (_fallbackTried && [where rangeOfString:@"fallback"].location != NSNotFound) {
        BOOL empty = [[_web stringByEvaluatingJavaScriptFromString:
            @"(function(){return document.forms.length?'':'1';})()"] length] > 0;

        if (empty) {
            NSLog(@"[YouTube/Проверка] Запасная форма пуста: ни поля, ни картинки — "
                  @"проверки без JavaScript для этого ключа не отдают");

            [_hint setText:YTLoc(@"Google не отдаёт проверку в виде, который эта версия "
                                 @"iOS может показать. Пройдите её на другом устройстве "
                                 @"с тем же выходом в сеть — пометка снимается со всей "
                                 @"сети, а не с устройства.")];

            [[self view] setNeedsLayout];
        }

        return;
    }

    // Виджет не отрисовался — уходим на запасную форму без JavaScript.
    [self useFallbackIfNeeded];
}

#pragma mark Запасная форма

/**
 * Запасная проверка reCAPTCHA — та, что без JavaScript.
 *
 * Виджет проверки приходит отдельным кадром и собран под нынешний
 * JavaScript: движок семёрки его не выполняет, и на странице остаётся
 * пустое место. Но у reCAPTCHA есть вторая форма, сделанная как раз для
 * браузеров без JavaScript, — `recaptcha/api/fallback`. Это обычная
 * страница с картинкой и кнопками, её старый движок рисует.
 *
 * Порядок такой:
 *
 *   1. со страницы `/sorry` снимается ключ сайта (`data-sitekey`),
 *      адрес её формы и все скрытые поля — `continue`, `q` и прочие;
 *   2. открывается запасная форма по этому ключу, человек решает её
 *      как обычную страницу;
 *   3. решённая форма отдаёт токен в `textarea` — он забирается
 *      и вместе со снятыми полями уходит обратно на `/sorry`;
 *   4. в ответ Google ставит печенье, снимающее пометку.
 *
 * Если хоть один шаг не вышел, экран остаётся обычным браузером:
 * страница открыта, и человек волен пройти проверку сам.
 */
- (void)useFallbackIfNeeded {
    if (_fallbackTried) {
        return;
    }

    NSString *sitekey = [_web stringByEvaluatingJavaScriptFromString:
        @"(function(){var e=document.querySelector('[data-sitekey]');"
        @"return e?e.getAttribute('data-sitekey'):'';})()"];

    if ([sitekey length] == 0) {
        [self explainPageWithoutChallenge];
        return;
    }

    /**
     * Поля формы снимаются все разом и уже закодированными: собирать их
     * потом будет негде — страница уйдёт из вида.
     */
    _returnAction = [_web stringByEvaluatingJavaScriptFromString:
        @"(function(){var f=document.forms[0];"
        @"return f?(f.action||document.location.href):'';})()"];

    _returnFields = [_web stringByEvaluatingJavaScriptFromString:
        @"(function(){var f=document.forms[0];if(!f)return '';var p=[];"
        @"for(var i=0;i<f.elements.length;i++){var e=f.elements[i];"
        @"if(!e.name||e.name=='g-recaptcha-response')continue;"
        @"p.push(encodeURIComponent(e.name)+'='+encodeURIComponent(e.value||''));}"
        @"return p.join('&');})()"];

    NSString *referer = [_web stringByEvaluatingJavaScriptFromString:@"document.location.href"];

    /**
     * Какая это reCAPTCHA — обычная или enterprise.
     *
     * Разница решающая, и на ней всё и споткнулось. У обычной запасная
     * форма живёт по адресу `recaptcha/api/fallback`, у enterprise —
     * `recaptcha/enterprise/fallback`. Ключ enterprise обычному адресу
     * незнаком, и тот честно отвечает страницей «Не удается связаться
     * с сервисом reCAPTCHA» — ровно её мы и видели.
     *
     * Узнаётся вид по тому, какую библиотеку тянет страница: `/sorry`
     * подключает `recaptcha/enterprise.js`.
     */
    BOOL enterprise = [[_web stringByEvaluatingJavaScriptFromString:
        @"(function(){var h=document.documentElement.innerHTML||'';"
        @"return h.indexOf('recaptcha/enterprise')>=0?'1':'';})()"] length] > 0;

    /**
     * `data-s` — второй токен, который `/sorry` кладёт рядом с ключом.
     * Запасная форма без него открывается, но пустой: он привязывает
     * проверку к этому конкретному отказу.
     */
    NSString *secret = [_web stringByEvaluatingJavaScriptFromString:
        @"(function(){var e=document.querySelector('[data-s]');"
        @"return e?encodeURIComponent(e.getAttribute('data-s')):'';})()"];

    /**
     * Версия выпуска reCAPTCHA.
     *
     * Ищется в два приёма, и порядок здесь важен. Сперва по дереву
     * страницы: библиотека подставляет свой основной скрипт по адресу
     * `gstatic.com/recaptcha/releases/<версия>/recaptcha__ru.js`. Но
     * подставляет **асинхронно**, и на медленном движке к моменту разбора
     * тега может ещё не быть — в этом и была причина, по которой адрес
     * запасной формы то и дело уходил без `v`, а форма отвечала «не
     * удается связаться».
     *
     * Поэтому второй приём — забрать `enterprise.js` самим и вынуть версию
     * из его текста. Файл крошечный, лежит по постоянному адресу и от
     * работы чужого JavaScript не зависит вовсе. Это и делает шаг
     * надёжным: страница может не успеть, отработать наполовину или
     * поменяться — версия всё равно найдётся.
     */
    NSString *version = [_web stringByEvaluatingJavaScriptFromString:
        @"(function(){var t=document.getElementsByTagName('script');"
        @"for(var i=0;i<t.length;i++){var m=(t[i].src||'')"
        @".match(/recaptcha[/]releases[/]([^/]+)[/]/);"
        @"if(m&&m[1])return m[1];}return '';})()"];

    if ([version length] == 0) {
        version = [self versionFromLibrary:enterprise];
    }

    /**
     * Адрес запасной формы собирается из четырёх обязательных частей:
     *
     *   k   — ключ сайта;
     *   co  — кто спрашивает: адрес хозяина страницы в base64, где
     *         дополнение `=` заменено точкой. Для `/sorry` хозяин всегда
     *         один и тот же — `https://www.google.com:443`, поэтому
     *         значение записано готовым, а не считается всякий раз;
     *   v   — версия выпуска, снятая со страницы;
     *   s   — второй токен `data-s`, привязывающий проверку к этому
     *         конкретному отказу.
     *
     * Без `co` и `v` служба отвечает страницей «Не удается связаться
     * с сервисом reCAPTCHA» — она приходит с кодом 200, отчего и выглядит
     * как поломка связи, хотя связь в порядке.
     */
    NSString *address = [NSString stringWithFormat:
        @"https://www.google.com/recaptcha/%@/fallback?k=%@"
        @"&co=aHR0cHM6Ly93d3cuZ29vZ2xlLmNvbTo0NDM.&hl=ru",
        enterprise ? @"enterprise" : @"api", sitekey];

    if ([version length] > 0) {
        address = [address stringByAppendingFormat:@"&v=%@", version];
    }

    if ([secret length] > 0) {
        address = [address stringByAppendingFormat:@"&s=%@", secret];
    }

    _fallbackTried = YES;

    NSLog(@"[YouTube/Проверка] Запасная форма: %@", address);
    NSLog(@"[YouTube/Проверка] Возврат на %@",
          [_returnAction length] > 0 ? _returnAction : @"?");

    [_busy start];
    [_busy setHidden:NO];

    [_hint setText:YTLoc(@"Выберите на картинке то, что просит подпись, и нажмите "
                         @"кнопку под ней. Проверок может быть несколько.")];

    [[self view] setNeedsLayout];

    NSMutableURLRequest *request = [YTNetworkClass(@"NSMutableURLRequest")
        requestWithURL:[NSURL URLWithString:address]];

    /**
     * Откуда пришли — обязательная часть: reCAPTCHA сверяет её с тем,
     * кому выдан ключ, и запрос «ниоткуда» отклоняет.
     */
    if ([referer length] > 0) {
        [request setValue:referer forHTTPHeaderField:@"Referer"];
    }

    [_web loadRequest:request];
}

/**
 * Объясняет страницу, на которой решать нечего.
 *
 * У `/sorry` два вида. Первый — с проверкой: есть ключ, есть форма,
 * человек её проходит. Второй — «повторите запрос позднее»: ни ключа,
 * ни формы, только отказ. Второй приходит с кодом 429, когда Google
 * не хочет разбираться, а хочет, чтобы запросы просто прекратились.
 *
 * Отдельно стоит строка с адресом. Если в ней два разных адреса через
 * «≠», это значит, что запрос пришёл не с того адреса, с которого Google
 * его ждал, — обычная примета дороги через промежуточный сервер, у
 * которого выход меняется между запросами. Проверку в таком случае
 * решать бессмысленно: снятая пометка привязана к адресу, а адрес
 * к следующему запросу станет другим.
 *
 * Всё это написано на самой странице, поэтому не гадаем, а читаем.
 */
- (void)explainPageWithoutChallenge {
    NSString *addresses = [_web stringByEvaluatingJavaScriptFromString:
        @"(function(){var t=document.body?document.body.innerText||'':'';"
        @"var m=t.match(/([0-9]+[.][0-9]+[.][0-9]+[.][0-9]+)[^0-9]+"
        @"([0-9]+[.][0-9]+[.][0-9]+[.][0-9]+)/);"
        @"return m?(m[1]+' / '+m[2]):'';})()"];

    BOOL later = [[_web stringByEvaluatingJavaScriptFromString:
        @"(function(){var t=document.body?document.body.innerText||'':'';"
        @"return (t.indexOf('позднее')>=0||t.indexOf('later')>=0)?'1':'';})()"] length] > 0;

    NSLog(@"[YouTube/Проверка] Проверки на странице нет%@%@",
          later ? @", сказано «повторите позднее»" : @"",
          [addresses length] > 0
              ? [NSString stringWithFormat:@", адреса не совпали: %@", addresses]
              : @"");

    if ([addresses length] > 0) {
        [_hint setText:YTLocF(
            @"Проверку пройти нельзя: запрос пришёл с одного адреса, а ждали "
            @"с другого (%@). Так бывает, когда трафик идёт через промежуточный "
            @"сервер со сменным выходом. Нужен путь с постоянным адресом.",
            addresses)];
    } else if (later) {
        [_hint setText:YTLoc(@"Google не предлагает проверку, а просит повторить позднее: "
                             @"с этого адреса шло слишком много запросов. Помогает только "
                             @"время или другой выход в сеть.")];
    } else {
        [_hint setText:YTLoc(@"Проверки на этой странице нет. Попробуйте позже или "
                             @"смените выход в сеть.")];
    }

    [[self view] setNeedsLayout];
}

/**
 * Версия выпуска из самой библиотеки reCAPTCHA.
 *
 * Внутри `enterprise.js` (или `api.js` у обычной) один раз встречается
 * адрес основного скрипта с версией в пути. Забираем файл своим клиентом
 * и достаём её оттуда — без участия страницы и её JavaScript.
 */
- (NSString *)versionFromLibrary:(BOOL)enterprise {
    NSString *address = enterprise
        ? @"https://www.google.com/recaptcha/enterprise.js"
        : @"https://www.google.com/recaptcha/api.js";

    /**
     * Ждём недолго и намеренно: запрос идёт с главного потока, а файл
     * крошечный. Затянись он на минуту — система сочла бы приложение
     * зависшим и сняла бы его.
     */
    NSMutableURLRequest *request =
        YTRequest(address, NSURLRequestUseProtocolCachePolicy, 10.0);

    if (request == nil) {
        return nil;
    }

    // Куки этому файлу ни к чему: он общий для всех и от аккаунта
    // не зависит.
    [request setHTTPShouldHandleCookies:NO];

    YTHttpResponse *response = [YTHttp send:request bodyLimit:64 * 1024];

    if (![response isSuccessful]) {
        NSLog(@"[YouTube/Проверка] Библиотека не забралась: код %ld",
              (long)response.statusCode);

        return nil;
    }

    NSString *text = [[NSString alloc] initWithData:response.body
                                           encoding:NSUTF8StringEncoding];

    NSRange marker = [text rangeOfString:@"recaptcha/releases/"];

    if (marker.location == NSNotFound) {
        return nil;
    }

    NSString *tail = [text substringFromIndex:marker.location + marker.length];
    NSRange slash = [tail rangeOfString:@"/"];

    if (slash.location == NSNotFound || slash.location == 0) {
        return nil;
    }

    NSString *version = [tail substringToIndex:slash.location];

    NSLog(@"[YouTube/Проверка] Версия из библиотеки: %@", version);

    return version;
}

/**
 * Забирает токен решённой формы и возвращает его на `/sorry`.
 *
 * Отвечает YES, если отправка ушла, — тогда разбирать эту страницу
 * дальше незачем.
 */
- (BOOL)sendTokenIfPresent {
    if (_tokenSent || [_returnAction length] == 0) {
        return NO;
    }

    NSString *token = [_web stringByEvaluatingJavaScriptFromString:
        @"(function(){var t=document.getElementsByTagName('textarea');"
        @"if(!t||!t.length)return '';return t[0].value||t[0].innerHTML||'';})()"];

    if ([token length] == 0) {
        return NO;
    }

    _tokenSent = YES;

    NSString *body = [NSString stringWithFormat:@"%@&g-recaptcha-response=%@",
                      _returnFields ?: @"", token];

    NSLog(@"[YouTube/Проверка] Токен получен (%lu знаков), возвращаем на %@",
          (unsigned long)[token length], _returnAction);

    NSMutableURLRequest *request = [YTNetworkClass(@"NSMutableURLRequest")
        requestWithURL:[NSURL URLWithString:_returnAction]];

    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/x-www-form-urlencoded"
   forHTTPHeaderField:@"Content-Type"];
    [request setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];

    [_hint setText:YTLoc(@"Проверка принята. Возвращаемся…")];

    [_busy start];
    [_busy setHidden:NO];

    [_web loadRequest:request];

    return YES;
}

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error {
    [_busy stop];
    [_busy setHidden:YES];

    NSLog(@"[YouTube/Проверка] Страница не открылась: %@", [error localizedDescription]);
}

#pragma mark Раскладка

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];

    CGRect box = [[self view] bounds];
    CGFloat top = YTStatusBarHeight();

    [_bar setFrame:CGRectMake(0, top, box.size.width, YTNavBarHeight)];
    [_close setFrame:CGRectMake(4, 8, 40, 40)];
    [_barTitle setFrame:CGRectMake(48, 8, box.size.width - 48 - 90, 40)];
    [_done setFrame:CGRectMake(box.size.width - 86, 8, 78, 40)];

    CGFloat y = top + YTNavBarHeight;

    CGFloat hintHeight = YTTextHeight([_hint text], [_hint font],
                                      box.size.width - 32, 0);

    [_hint setFrame:CGRectMake(16, y + 8, box.size.width - 32, hintHeight)];

    y += 8 + hintHeight + 8;

    CGRect page = CGRectMake(0, y, box.size.width, box.size.height - y);

    [_web setFrame:page];
    [_modern setFrame:page];

    [_busy setFrame:CGRectMake(box.size.width / 2 - 18, y + 40, 36, 36)];
}

@end
