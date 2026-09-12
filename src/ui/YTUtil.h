#import <UIKit/UIKit.h>

@class YTVideoItem;

/**
 * Работа в фоне. В UWP-версии это был `async/await` поверх `HttpClient`,
 * здесь — обычная очередь: все методы YTApi синхронные и ждут ответа.
 */
void YTAsync(dispatch_block_t work);

/** Вернуться на главный поток. */
void YTMain(dispatch_block_t work);

/**
 * Отменяемая фоновая задача. Заменяет `CancellationToken` UWP-версии:
 * у экрана есть номер поколения, и ответ, пришедший от прежней вкладки,
 * свою ленту уже не дописывает.
 */
@interface YTGeneration : NSObject

@property (nonatomic, readonly) NSInteger current;

/** Начинает новое поколение и возвращает его номер. */
- (NSInteger)next;

/** Актуален ли ещё ответ этого поколения. */
- (BOOL)isCurrent:(NSInteger)generation;

@end


/**
 * Вид, принимающий нажатие.
 *
 * Нужен потому, что в UIKit нажатие забирает себе тот вид, на который попали,
 * а не тот, кто им владеет: у `UIView` `userInteractionEnabled` включён
 * с рождения. В UWP было наоборот — там карточка это `Button`, и всё её
 * содержимое нажимается заодно с ней.
 *
 * Поэтому карточки строятся так: сверху этот вид, внутри — подписи
 * и картинки с выключенным взаимодействием.
 */
@interface YTTappableView : UIView

@property (nonatomic, copy) dispatch_block_t onTap;

/**
 * Долгое нажатие; при нём обычное не засчитывается.
 *
 * Заводится только тем, кому назначено: распознаватель добавляется
 * в установщике, и виды без него остаются на голых касаниях, как были.
 */
@property (nonatomic, copy) dispatch_block_t onHold;

/** Подсветка под пальцем — `AppSurfaceHoverColor` из App.xaml. */
@property (nonatomic, assign) BOOL highlights;

@end


/**
 * «Потяните, чтобы обновить».
 *
 * `UIRefreshControl` появился в iOS 6, поэтому здесь свой: вид над
 * содержимым списка, который следит за прокруткой и срабатывает, когда
 * список оттянули дальше порога и отпустили.
 */
@interface YTRefreshHeader : UIView

/** Заводится один раз и сам подписывается на прокрутку своего списка. */
+ (YTRefreshHeader *)attachedTo:(UIScrollView *)scrollView action:(dispatch_block_t)action;

/** Зовётся из scrollViewDidScroll: владельца. */
- (void)followScroll;

/** Зовётся из scrollViewDidEndDragging: владельца. */
- (void)releaseScroll;

/** Обновление закончилось — прячем индикатор. */
- (void)finish;

@property (nonatomic, readonly) BOOL isRefreshing;

@end


/**
 * Отдать контроллеру всё окно целиком, включая полосу под строкой состояния.
 *
 * До iOS 7 вид контроллера по умолчанию занимал не окно, а «область
 * содержимого» — окно без строки состояния. Наши экраны при этом сами
 * отступают на её высоту (шапка рисуется под ней), и отступ выходил двойной:
 * содержимое съезжало на 20 точек вниз, а снизу ровно столько же окна
 * оставалось незакрытым — там и просвечивала подложка.
 *
 * С iOS 7 вид и так во весь экран, и звать это не нужно; поэтому свойство
 * спрашивается через runtime — в новых SDK его уже нет.
 *
 * Заодно снимается автоматическая правка отступов списков (iOS 7 и новее):
 * система добавляет первому найденному UIScrollView отступ сверху под свои
 * панели, которых у нас нет.
 *
 * Зовётся из loadView, до того как вид попадёт в окно.
 */
void YTUseFullScreenLayout(UIViewController *controller);

/** Высота строки состояния сейчас — она бывает вдвое выше во время звонка. */
CGFloat YTStatusBarHeight(void);


/**
 * Переходы между экранами.
 *
 * Разделы не держат ссылку на навигацию, а просят её у этого класса —
 * иначе каждому пришлось бы тащить контроллер сквозь всю цепочку создания.
 */
@interface YTNav : NSObject

+ (UINavigationController *)controller;
+ (void)setController:(UINavigationController *)controller;

+ (void)push:(UIViewController *)screen;
+ (void)pop;

/** Стоит ли этот экран в стопке — и возврат к нему, если стоит. */
+ (BOOL)contains:(UIViewController *)screen;
+ (void)popTo:(UIViewController *)screen;

/** Открыть страницу ролика — зовётся отовсюду, где есть карточка. */
+ (void)openVideo:(NSString *)videoId title:(NSString *)title;

/**
 * То же, но ролик открыт из подборки: её идентификатор нужен, чтобы
 * страница показала очередь. У микса без него очередь не придёт вовсе.
 */
+ (void)openVideo:(NSString *)videoId
            title:(NSString *)title
         playlist:(NSString *)playlistId;

/**
 * Открыть вертикальный ролик листалкой, начав ленту с него.
 *
 * Карточка передаётся целиком: в ней и пропуск на ленту вокруг ролика,
 * и подписи с превью, которые листалка покажет, пока лента едет.
 */
+ (void)openShort:(YTVideoItem *)item;

/** Открыть канал. */
+ (void)openChannel:(NSString *)channelId title:(NSString *)title;

/** Открыть подборку — плейлист или микс. */
+ (void)openPlaylist:(NSString *)playlistId title:(NSString *)title;

/**
 * Переключить нижнюю панель на раздел.
 *
 * Нужно там, где один раздел отсылает к другому, — например, «Подписки»
 * невошедшего отправляют на «Моё», где живёт вход.
 */
+ (void)selectTab:(NSInteger)index;

@end


/**
 * Стопка экранов, которая спрашивает об ориентации верхний экран.
 *
 * С iOS 6 систему интересует только контроллер верхнего уровня — здесь это
 * сама стопка, — а штатный UINavigationController отвечает за себя и вниз
 * вопрос не передаёт. Из-за этого плеер не мог бы ни запретить landscape
 * на странице, ни разрешить его в полноэкранном режиме: его ответ никто
 * не спрашивал бы.
 */
@interface YTNavigationController : UINavigationController
@end


/**
 * Кольцо ожидания.
 *
 * Порт `AndroidLoadingRing.xaml` — в UWP-версии это отдельный контрол
 * с дугой, крутящейся по кругу, потому что штатный `ProgressRing` там
 * выглядит иначе. Здесь то же самое: дуга в четверть окружности,
 * оборот за секунду, цвет `LoadingRingColor`.
 */
@interface YTLoadingRing : UIView

- (void)start;
- (void)stop;

@end


/**
 * Состояние экрана вместо содержимого: кольцо ожидания либо сообщение.
 *
 * Сообщение об отсутствии сети повторяет `OfflinePanel` из Home.xaml:
 * картинка 170×170, заголовок 22 SemiBold, пояснение 16, под ними кнопка
 * «Повторить» — голубая `#3EA6FF`, скругление 22, отступы 18×8.
 */
@interface YTStatusView : UIView

- (void)showBusy;
- (void)showMessage:(NSString *)message;

/** Полный вид отказа: картинка, заголовок, пояснение и кнопка. */
- (void)showOffline:(NSString *)title
              hint:(NSString *)hint
       actionTitle:(NSString *)actionTitle
            action:(dispatch_block_t)action;

- (void)hide;

@end


/**
 * Подгрузка следующих страниц списка при прокрутке.
 *
 * У InnerTube страницы размечены не номерами, а «токенами продолжения»:
 * в конце списка лежит `continuationItemRenderer` с непрозрачной строкой,
 * которую надо отправить обратно тем же запросом. Собрать её на клиенте
 * нельзя — она подписана сервером.
 *
 * Здесь только учёт: сам токен, признак занятости и порог прокрутки. Ходит
 * в сеть и разбирает ответ по-прежнему сам экран — списки разные, и
 * складывать в ленту им нужно разное.
 *
 * Занятость нужна не для порядка, а по существу: `scrollViewDidScroll:`
 * зовётся на каждый кадр прокрутки, и без неё одна и та же страница
 * запрашивалась бы десятками. Поэтому `claimOn:`, отвечая «пора», сразу
 * и занимает себя — проверка и захват одним действием.
 */
@interface YTPager : NSObject

/** Токен следующей страницы; nil — страниц больше нет. */
@property (nonatomic, copy) NSString *token;

/** Есть ли что грузить. */
@property (nonatomic, readonly) BOOL hasMore;

/** Новый список: прежние страницы забываются. */
- (void)reset;

/** Пора ли грузить, и если пора — занять себя. */
- (BOOL)claimOn:(UIScrollView *)scrollView;

/**
 * То же для полосы, которая едет вбок.
 *
 * Отдельным методом, а не разбором направления внутри: у вертикального
 * списка полоса прокрутки одна, а у горизонтальной полосы формально есть
 * обе, и угадывать по ним, куда она едет, — гадание. Зовущий знает точно.
 */
- (BOOL)claimSidewaysOn:(UIScrollView *)scrollView;

/** Загрузка кончилась — можно просить следующую. */
- (void)finish;

@end

/**
 * Показ листа «Поделиться».
 *
 * На iPad `UIActivityViewController` обязан выходить поповером: показанный
 * обычным способом, он бросает исключение и уносит приложение. Именно так
 * закрывались Shorts по кнопке «Поделиться». Здесь это в одном месте,
 * чтобы не разойтись снова.
 */
/** Память кончается: отдать всё, что можно взять заново. */
extern NSString *const YTReleaseHeavyNotification;

@interface YTShare : NSObject

+ (void)presentSheet:(id)sheet from:(UIView *)anchor in:(UIViewController *)host;

@end
