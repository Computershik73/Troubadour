#import <Foundation/Foundation.h>

/** Шлётся при изменении любой настройки — открытые экраны перечитывают своё. */
extern NSString *const YTSettingsChangedNotification;

/**
 * Каким путём добывается поток.
 *
 * Путей ровно два, и оба рабочие — разница в том, чем платишь.
 *
 * `YTDeliverySabr` — подача SABR от TV-клиента. Это то, чем YouTube
 *     раздаёт видео сегодня: вместо готовых ссылок сервер отдаёт поток
 *     кусками по запросу. Качества все, вплоть до 1080p и выше, звуковые
 *     дорожки все. Требует входа в учётную запись.
 *
 * `YTDeliveryAndroidVr` — готовые адреса от клиента шлема. Старый способ:
 *     сервер присылает прямые ссылки на дорожки. Работает и без входа,
 *     но ссылки привязаны к тому адресу, с которого их взяли, — из-за
 *     VPN и адресов дата-центров раздача на них отвечает отказом чаще,
 *     чем хотелось бы.
 *
 * При `YTDeliverySabr` второй путь остаётся запасным: если подача
 * не задалась, приложение само переходит к готовым адресам.
 */
typedef enum {
    YTDeliverySabr = 0,
    YTDeliveryAndroidVr = 1
} YTDelivery;

/**
 * Какую звуковую дорожку брать у ролика с несколькими языками.
 *
 * У YouTube их сегодня три вида: родная (`acont=original`) — та, на
 * которой ролик сняли; озвучка, записанная автором или его командой
 * (`acont=dubbed`); и автоматический дубляж (`acont=dubbed-auto`) —
 * синтезированный голос поверх родного. Сервер помечает «основной»
 * (`audioIsDefault`) не родную, а ту, что подходит языку запроса, —
 * полагаться на эту пометку нельзя.
 *
 * `YTAudioLanguageOriginal` — всегда родная.
 *
 * `YTAudioLanguageDeviceAuthored` — на языке устройства, но только если
 *     её записали люди; синтезированную не берём. Нет такой — родная.
 *
 * `YTAudioLanguageDeviceAny` — на языке устройства любая, включая
 *     автоматический дубляж. Нет и его — родная.
 *
 * `YTAudioLanguageAsk` — спрашивать каждый раз, когда дорожек больше одной.
 */
typedef enum {
    YTAudioLanguageOriginal = 0,
    YTAudioLanguageDeviceAuthored = 1,
    YTAudioLanguageDeviceAny = 2,
    YTAudioLanguageAsk = 3
} YTAudioLanguage;

/**
 * Настройки приложения — порт `Settings.xaml` и его хранилища.
 *
 * В UWP-версии всё это лежит в `ApplicationData.Current.LocalSettings`,
 * здесь — в NSUserDefaults: разница только в имени хранилища, набор ключей
 * и значения по умолчанию те же.
 *
 * Чего здесь нет и почему:
 *
 *   «Живая плитка» — плиток на iOS не бывает; настройка управляет
 *       обновлением тайла на начальном экране Windows и переносить её
 *       некуда;
 *   «Отправлять уведомления» — фоновые всплывающие уведомления требуют
 *       либо фоновой задачи (в UWP она есть), либо сервера с APNs.
 *       Ни того, ни другого у неподписанной сборки на iOS 5 нет; сам
 *       экран уведомлений при этом перенесён и работает;
 *   «Предпросмотр перемотки» — раскадровка (`StoryboardThumbnails.cs`)
 *       пока не перенесена, и переключатель управлял бы пустотой.
 *
 * Остальные строки на месте, вместе с порядком, значками и значениями
 * по умолчанию.
 */
@interface YTSettings : NSObject

#pragma mark Язык

/**
 * Язык надписей самого приложения. Пусто — как в системе.
 *
 * Отдельно от языка ответов ниже, и это не придирка: смотреть ролики
 * с русскими подписями, а приложение держать на английском — обычное
 * желание, и наоборот тоже.
 */
+ (NSString *)interfaceLanguage;
+ (void)setInterfaceLanguage:(NSString *)code;

/**
 * Язык ответов сервера — то, что уходит в `hl`. Пустая строка означает
 * «как в системе»: тогда берётся язык устройства.
 *
 * Меняется то, на каком языке YouTube присылает названия роликов,
 * подписи «3 часа назад» и заголовки полок; надписи самого приложения
 * живут отдельно, ключом выше.
 */
+ (NSString *)language;
+ (void)setLanguage:(NSString *)language;

/** Список языков, как `Localization.SupportedLanguages` в оригинале. */
+ (NSArray *)languageOptions;

/** Человеческое название языка по коду; для пустого — «Как в системе». */
+ (NSString *)languageTitle:(NSString *)code;

#pragma mark Видео

/**
 * Предпочитаемая высота кадра: 0 — «Авто». Плеер берёт формат не выше её
 * и не выше того, что тянет устройство.
 */
+ (NSInteger)preferredHeight;
+ (void)setPreferredHeight:(NSInteger)height;

/**
 * Предпочитаемая высота у вертикальных роликов — своя.
 *
 * Shorts почти всегда смотрят мимоходом и в дороге, а весят они при том
 * же качестве заметно больше обычного: кадр вертикальный, и пикселей
 * в нём при той же высоте столько же, зато длится он полминуты.
 * В оригинале выбор качества у Shorts тоже отдельный — своя шестерёнка
 * в правом верхнем углу.
 */
+ (NSInteger)shortsHeight;
+ (void)setShortsHeight:(NSInteger)height;

/** Высоты для списка выбора, от «Авто» и вниз. */
+ (NSArray *)qualityOptions;

+ (NSString *)qualityTitle:(NSInteger)height;

#pragma mark Превью

/**
 * Качество превью: ширина картинки, которую просить у i.ytimg.com.
 * 0 — «Авто», то есть под размер карточки на экране.
 */
+ (NSInteger)thumbnailWidth;
+ (void)setThumbnailWidth:(NSInteger)width;

+ (NSArray *)thumbnailOptions;
+ (NSString *)thumbnailTitle:(NSInteger)width;

#pragma mark Поток

/** Способ получения потока; по умолчанию — подача SABR. */
+ (YTDelivery)delivery;
+ (void)setDelivery:(YTDelivery)delivery;

+ (NSArray *)deliveryOptions;
+ (NSString *)deliveryTitle:(YTDelivery)delivery;

/** Строка под названием — чем этот путь отличается от другого. */
+ (NSString *)deliveryHint:(YTDelivery)delivery;

#pragma mark Языковая дорожка

/** Какую дорожку брать при скачивании. */
+ (YTAudioLanguage)downloadAudioLanguage;
+ (void)setDownloadAudioLanguage:(YTAudioLanguage)mode;

/** Какую дорожку включать при просмотре. */
+ (YTAudioLanguage)playbackAudioLanguage;
+ (void)setPlaybackAudioLanguage:(YTAudioLanguage)mode;

+ (NSArray *)audioLanguageOptions;
+ (NSString *)audioLanguageTitle:(YTAudioLanguage)mode;
+ (NSString *)audioLanguageHint:(YTAudioLanguage)mode;

#pragma mark Переключатели

/** Показывать кружок канала на карточках — `ChannelIconsToggleButton`. */
+ (BOOL)showsChannelIcons;
+ (void)setShowsChannelIcons:(BOOL)shows;

/**
 * Показывать ли приложение под чужим значком и названием.
 *
 * Хранится у нас, а меняется в связке: настройка — это лишь память
 * о том, что выбрал человек. Само переключение делает `YTAppIcon`.
 */
+ (BOOL)usesAlternateIcon;
+ (void)setUsesAlternateIcon:(BOOL)uses;

/** Разворачивать кадр при повороте — `AutoFullscreenLandscapeToggleButton`. */
+ (BOOL)autoFullscreenInLandscape;
+ (void)setAutoFullscreenInLandscape:(BOOL)automatic;

/**
 * Включать следующий ролик очереди, когда нынешний доиграл.
 *
 * По умолчанию включено — так ведёт себя и плейлист, и микс на самом
 * YouTube. Выключенное оставляет последний кадр с кнопкой «сначала».
 */
+ (BOOL)autoplayNextInQueue;
+ (void)setAutoplayNextInQueue:(BOOL)automatic;

/**
 * Насколько раньше показывать субтитры, в секундах.
 *
 * Положительное — раньше. В оригинале секунда (`DefaultSubtitleOffsetMs
 * = 1000`), и там же сказано зачем — реплику читают до того, как её
 * произнесут, а не после. У нас по умолчанию две: поток идёт через
 * подачу и склейку, и время у плеера отстаёт от времени в дорожке
 * ещё примерно на секунду. Предел ±5: дальше это уже не поправка.
 */
+ (double)subtitleOffset;
+ (void)setSubtitleOffset:(double)seconds;

/**
 * Где на экране лежит строка субтитров: доля высоты кадра от верха.
 *
 * Её двигают пальцем, и место запоминается. Доля, а не точки, — чтобы
 * при повороте строка осталась там же по смыслу, а не уехала за край.
 */
+ (double)subtitlePlace;
+ (void)setSubtitlePlace:(double)share;

/** То же по горизонтали: доля ширины кадра до середины строки. */
+ (double)subtitlePlaceX;
+ (void)setSubtitlePlaceX:(double)share;

/**
 * Переходить к следующему Shorts, когда нынешний доиграл.
 *
 * По умолчанию выключено: там ролик повторяется по кругу, как и в самом
 * YouTube, — Shorts листают пальцем.
 */
+ (BOOL)autoplayNextShort;
+ (void)setAutoplayNextShort:(BOOL)automatic;

/**
 * Убрать Shorts отовсюду разом.
 *
 * Одним переключателем, а не пятью: вертикальные ролики попадаются
 * не только на своей вкладке, но и в выдаче поиска, и полками в ленте,
 * и вперемешку с обычными на канале, в подборках и в истории. Тому,
 * кто их не смотрит, приходилось бы обходить каждое место по очереди —
 * а половину из них он и не подозревает.
 *
 * Что происходит при включении:
 *
 *   * вкладка Shorts уходит из нижней панели;
 *   * в поиске пропадает таблетка Shorts, а из выдачи — вертикальные;
 *   * из всех лент — «Главной», подписок, канала, подборок, истории
 *     и похожих — вертикальные отсеиваются при разборе ответа.
 */
+ (BOOL)hidesShorts;
+ (void)setHidesShorts:(BOOL)hides;

/**
 * Показывать число дизлайков по Return YouTube Dislike.
 *
 * Включено сразу: ради этого числа настройку и завели. Выключают её
 * те, кто не хочет отдавать номера роликов стороннему сервису.
 */
+ (BOOL)showsDislikes;
+ (void)setShowsDislikes:(BOOL)shows;

/**
 * Обход блокировок YouTube через Cloudflare WARP (см. src/warp/YTWarp.h).
 *
 * Выключен, пока человек не включит сам — из настроек или согласившись
 * на предложение, которое приложение делает, когда YouTube в его сети
 * недоступен.
 */
+ (BOOL)usesWarp;
+ (void)setUsesWarp:(BOOL)uses;

/** Человек попросил больше не предлагать обход. */
+ (BOOL)warpOfferDeclined;
+ (void)setWarpOfferDeclined:(BOOL)declined;

/**
 * Брать ли шестидесятикадровые дорожки.
 *
 * По умолчанию на A4 и A5 — нет: эти чипы не успевают разбирать столько
 * кадров ни в каком размере, и 720p60 им тяжелее, чем 1080p30, так что
 * потолком разрешения от беды не спастись. Но запрет здесь неуместен:
 * тяжесть зависит и от самого ролика, и от того, что ещё делает
 * устройство, — а решать, смотреть ли ценой рывков, человеку.
 *
 * На остальных устройствах по умолчанию берутся, как и раньше.
 */
+ (BOOL)allowsSixtyFrames;
+ (void)setAllowsSixtyFrames:(BOOL)allows;

/** Отказывается ли устройство от шестидесяти кадров без особой просьбы. */
+ (BOOL)prefersThirtyByDevice;

@end
