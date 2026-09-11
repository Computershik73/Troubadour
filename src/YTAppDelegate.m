#import "YTAppDelegate.h"

#import <AVFoundation/AVFoundation.h>

#import "YTAuth.h"
#import "YTWebAuth.h"
#import "YTNSig.h"
#import "YTPoToken.h"
#import "YTImageLoader.h"
#import "YTMiniPlayer.h"
#import "YTRoundedImageView.h"
#import "YTShellViewController.h"
#import "YTTheme.h"
#import "YTUtil.h"

@implementation YTAppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)options {
    /**
     * Запись в закрытый с той стороны сокет по умолчанию убивает процесс
     * сигналом SIGPIPE. А закрывается он постоянно: плеер отпускается при
     * смене качества и при уходе с экрана, и ровно в этот момент рабочий
     * поток прокси дописывает ему сегмент. Сигнал глушится на всё
     * приложение; на каждом принятом соединении вдобавок стоит SO_NOSIGPIPE.
     */
    signal(SIGPIPE, SIG_IGN);

    /**
     * Нехватка памяти отмечается в журнале.
     *
     * На iPhone 4 система молча просит освободиться, а если не помогло —
     * убивает. Со стороны это неотличимо от падения по своей вине, и без
     * этой строки в отчёте о падении разницу не видно вовсе.
     */
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        NSLog(@"[YouTube/Память] Система просит освободить память");
    }];

    // Поднимаем сохранённый вход до того, как экраны спросят о нём.
    [YTAuth restore];

    /**
     * И веб-сессию — тем же порядком и по той же причине.
     *
     * Куки, положенные веб-видом при входе в браузере, живут в общем
     * хранилище, пока приложение работает, но до следующего запуска
     * доходят не всегда. Свой запас поднимаем сами и до первых запросов:
     * иначе первый же ответ `/player` придёт с проверкой «вы не бот»,
     * хотя человек давно вошёл.
     */
    [YTWebAuth restoreSession];

    /**
     * Подготовка PO-токена начинается сразу и идёт своим чередом: она
     * стоит нескольких секунд, а нужна к первому же ролику. Ждать её
     * никто не будет — запрос потоков уйдёт и без токена, просто с ним
     * он проходит стену «подтвердите, что вы не бот».
     *
     * Браузер, в котором крутится программа, поднимается невидимым
     * и остаётся жить: чеканка потом занимает миллисекунды.
     */
    [[YTPoToken shared] prepare];
    [[YTNSig shared] prepare];

    [self configureAudioSession];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    [self.window setBackgroundColor:[YTTheme background]];

    YTShellViewController *shell = [[YTShellViewController alloc] init];

    /**
     * Навигация штатная, но с невидимой полосой: верхнюю панель со словесным
     * знаком приложение рисует само — так же, как это делала UWP-версия
     * своим Navbar.xaml. От UINavigationController нужны только переходы
     * и стопка экранов.
     */
    UINavigationController *navigation =
        [[YTNavigationController alloc] initWithRootViewController:shell];

    [navigation setNavigationBarHidden:YES];

    // Стопка — контроллер верхнего уровня, и до iOS 7 отступ под строку
    // состояния система отмеряет именно от неё. Экраны отступают сами.
    YTUseFullScreenLayout(navigation);

    /**
     * Подложка стопки тоже красится в цвет страницы. По умолчанию она белая,
     * и на iPad с iOS 6 её видно светлыми полосами по краям, когда вид
     * экрана оказывается чуть уже окна.
     */
    [[navigation view] setBackgroundColor:[YTTheme background]];

    [YTNav setController:navigation];

    [self.window setRootViewController:navigation];
    [self.window makeKeyAndVisible];

    [[UIApplication sharedApplication] setStatusBarStyle:[YTTheme statusBarStyle]];

    return YES;
}

/**
 * Категория и режим звука.
 *
 * `AVAudioSessionCategoryPlayback` нужен по двум причинам сразу: без него
 * звук пропадает при уходе в фон, и он же снимает зависимость от бокового
 * переключателя «без звука» — иначе ролик у выключенного звонка идёт немым.
 *
 * `AVAudioSessionModeMoviePlayback` — не пометка: под него система включает
 * обработку выходного сигнала для кино, и на встроенном динамике речь
 * становится разборчивее.
 *
 * Обе константы записаны строками, а не взяты символами, и это не
 * перестраховка. `AVAudioSessionModeMoviePlayback` объявлена в SDK как
 * доступная с iOS 6, а нижняя граница у нас 5.1 — компилятор в таком случае
 * делает символ слабым, dyld разрешает его в NULL, и обращение к константе
 * даёт nil. Дальше срабатывает ловушка: сам `setMode:error:` существует
 * с iOS 5.0, то есть `respondsToSelector:` отвечает «да», и мы честно зовём
 * его с nil — а `AVAudioSession` на nil отвечает исключением прямо здесь,
 * в didFinishLaunching. Значение этих констант совпадает с их именем,
 * поэтому строка работает везде, а на iOS 5 система просто отвечает отказом
 * в error.
 */
- (void)configureAudioSession {
    static NSString *const YTPlaybackCategory = @"AVAudioSessionCategoryPlayback";
    static NSString *const YTMoviePlaybackMode = @"AVAudioSessionModeMoviePlayback";

    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;

    if (![session setCategory:YTPlaybackCategory error:&error]) {
        NSLog(@"[YouTube/Звук] Категория не принята: %@", [error localizedDescription]);
    }

    if ([session respondsToSelector:@selector(setMode:error:)]) {
        error = nil;

        if (![session setMode:YTMoviePlaybackMode error:&error]) {
            // На iOS 5 режима не существует — это ожидаемый отказ, не беда.
            NSLog(@"[YouTube/Звук] Режим кино не принят: %@", [error localizedDescription]);
        }
    }

    [session setActive:YES error:NULL];
}

/**
 * Кнопки пульта, когда страницы ролика на виду уже нет.
 *
 * Цепочка отвечающих кончается делегатом приложения, и до него события
 * доходят, когда первым отвечающим не стал никто. Так бывает со свёрнутым
 * в окно роликом: страница ушла из стопки, а звук идёт — и кнопки на
 * заблокированном экране без этого были бы мертвы.
 */
- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    if ([event type] != UIEventTypeRemoteControl || ![YTMiniPlayer isActive]) {
        return;
    }

    switch ([event subtype]) {
        case UIEventSubtypeRemoteControlPlay:
            // «Играй» и «стой» приходят порознь: переключателем их
            // обрабатывать нельзя, повторное «играй» ставило бы паузу.
            if (![YTMiniPlayer isPlaying]) {
                [YTMiniPlayer togglePlay];
            }
            break;

        case UIEventSubtypeRemoteControlPause:
            if ([YTMiniPlayer isPlaying]) {
                [YTMiniPlayer togglePlay];
            }
            break;

        case UIEventSubtypeRemoteControlTogglePlayPause:
            [YTMiniPlayer togglePlay];
            break;

        default:
            break;
    }
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
    // Система просит потесниться — отдаём оба кеша картинок: сами превью
    // и готовые скруглённые кадры.
    [YTImageLoader trim];
    [YTRoundedImageView trimFrames];
}

/**
 * Уходя в фон, отдаём картинки сами, не дожидаясь просьбы.
 *
 * В фоне нас держат только ради звука, а память меряют по всему занятому.
 * Разобранные превью — самое крупное, что у нас есть, и на телефоне
 * их набирается на десятки мегабайт. Кто занимает больше, того система
 * и снимает первым; снятое приложение при возврате показывает заставку
 * и начинает всё заново.
 */
- (void)applicationDidEnterBackground:(UIApplication *)application {
    [YTImageLoader trim];
    [YTRoundedImageView trimFrames];

    /**
     * Заодно освежаем запас веб-сессии: Google подменяет куки по ходу
     * работы, и отложенные при входе к следующему запуску могли
     * устареть.
     */
    [YTWebAuth keepSession];

    NSLog(@"[YouTube/Память] Ушли в фон — картинки отданы");
}

@end
