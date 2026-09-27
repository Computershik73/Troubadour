#import "YTPlayerViewController.h"

#import "YTStrings.h"

#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#import "YTApi.h"
#import "YTDownloads.h"
#import "YTFeedViews.h"
#import "YTHlsProxy.h"
#import "YTImageLoader.h"
#import "YTJson.h"
#import "YTMetrics.h"
#import "YTRoundedImageView.h"
#import "YTSettings.h"
#import "YTPlayerJs.h"
#import "YTMiniPlayer.h"
#import "YTNSig.h"
#import "YTNowPlaying.h"
#import "YTAuth.h"
#import "YTDislikes.h"
#import "YTSabr.h"
#import "YTSponsorBlock.h"
#import "YTStoryboard.h"
#import "YTStreams.h"
#import "YTPlaybackStats.h"
#import "YTStatsPanel.h"
#import "YTSubtitles.h"
#import "YTWebAuth.h"
#import "YTSkin.h"
#import "YTTheme.h"
#import "YTSettingsSheet.h"
#import "YTSimpleScreens.h"
#import "YTUtil.h"
#import "YTVideoItem.h"

/** Через сколько пульт прячется сам. */
static const NSTimeInterval YTControlsTimeout = 3.5;

/**
 * Сколько сторож ждёт перемотку, прежде чем отпустить её силой.
 *
 * Полминуты — с запасом на самый медленный случай, какой мы видели:
 * старый планшет, кусок под мегабайт, сборка около двенадцати секунд.
 */
static const NSTimeInterval YTSeekPatience = 30.0;

/**
 * Числа пульта — из `CustomVideoPlayer.xaml`, один в один.
 *
 * Кадр там лежит на `#0f0f0f`, кнопки нарисованы стилем `ControlButtonStyle`:
 * круг заливкой `#66000000` при непрозрачности 0.8, значок внутри мельче
 * самой кнопки. Нижняя полоса — отдельная сетка высотой 80 с картинкой-
 * затемнением на фоне.
 */
/**
 * Скорость на время удержания пальца.
 *
 * Двойка, как в нынешнем YouTube. Числом, а не настройкой: приём этот
 * не про предпочтения, а про «промотать вот это скучное место», и выбор
 * здесь был бы лишним вопросом к человеку.
 */

static const CGFloat YTStageButton = 40;      // Width/Height у кнопок пульта
static const CGFloat YTStageIcon = 20;        // Image внутри них
static const CGFloat YTStageCenter = 80;      // PlayPauseButton
static const CGFloat YTStageCenterIcon = 48;  // Image внутри него
static const CGFloat YTStageMargin = 8;       // Margin="8,8,0,0"
static const CGFloat YTBottomPanel = 80;      // Height у BottomControlsPanel
static const CGFloat YTBottomRow = 40;        // верхний ряд полосы
static const CGFloat YTTrackHeight = 4;       // высота дорожки
static const CGFloat YTThumbSide = 16;        // красный кружок

/** Отступы страницы под кадром — из `Video.xaml`. */
static const CGFloat YTPageMargin = 16;

/**
 * Кнопка, которую можно нажать чуть мимо.
 *
 * Кнопки пульта — сорок точек, и это ровно тот размер, в который на ходу
 * не попадаешь: промах в пять точек мимо края уходит не туда, а на кадр,
 * и вместо перемотки прячется пульт. Рисовать их крупнее нельзя — вид
 * взят из оригинала, — но принимать касания рядом с собой можно.
 *
 * Запас задаётся с каждой стороны отдельно: у кнопки полноэкранного вида
 * снизу проходит ползунок, и там расширяться нельзя, иначе она начнёт
 * перехватывать перетаскивание.
 */
@interface YTRoomyButton : UIButton {
    UIEdgeInsets _slack;
}

- (void)setSlack:(UIEdgeInsets)slack;

@end

@implementation YTRoomyButton

- (void)setSlack:(UIEdgeInsets)slack {
    _slack = slack;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect box = UIEdgeInsetsInsetRect([self bounds],
                                       UIEdgeInsetsMake(-_slack.top, -_slack.left,
                                                        -_slack.bottom, -_slack.right));

    return CGRectContainsPoint(box, point);
}

@end

@interface YTPlayerViewController () <UIGestureRecognizerDelegate,
                                     UIActionSheetDelegate, UIAlertViewDelegate>
@end

@interface YTPlayerViewController ()

/** Секунда продолжения: ставится навигацией до показа. */
@property (nonatomic, assign) NSTimeInterval resumeAt;

@end

@implementation YTPlayerViewController {
    NSString *_videoId;
    NSString *_titleText;
    NSString *_playlistId;

    UIScrollView *_page;

    /** Кадр и всё, что поверх него. */
    UIView *_stage;
    UIView *_videoHost;
    AVPlayer *_player;
    AVPlayerLayer *_playerLayer;
    AVPlayerItem *_observedItem;

    UIView *_overlay;

    /** Окно «статистика для сисадминов»; спрятано, пока не попросят. */
    YTStatsPanel *_stats;

    UILabel *_fullscreenTitle;
    UILabel *_fullscreenAuthor;

    UIButton *_minimize;
    UIButton *_settings;
    UIButton *_playPause;

    /** Перемотка кнопками: назад на 5, вперёд на 15 — как в Трубаче. */
    YTRoomyButton *_rewind;
    YTRoomyButton *_forward;
    UILabel *_rewindMark;
    UILabel *_forwardMark;

    UIImageView *_scrim;
    YTPillView *_timePill;

    UILabel *_time;
    YTRoomyButton *_fullscreen;

    /**
     * Виды полосы — картинками, а не просто цветными прямоугольниками.
     *
     * `UIImageView` умеет то, что нужно оформлению эпохи: тянуть картинку
     * серединой, оставляя торцы. Без рисунка он ведёт себя как обычный
     * вид, поэтому плоскому оформлению перемена ничего не стоит.
     */
    UIImageView *_track;
    UIImageView *_trackFill;
    UIImageView *_thumb;

    YTLoadingRing *_busy;

    /** Страница под кадром. */
    UILabel *_title;
    YTRoundedImageView *_channelAvatar;
    UILabel *_channelName;
    UILabel *_channelSubs;
    YTPillView *_subscribeFill;
    UILabel *_subscribeLabel;
    YTTappableView *_subscribeTouch;

    /** Колокольчик и стрелка внутри кнопки — только у подписанного. */
    UIImageView *_bellIcon;
    UIImageView *_bellChevron;
    YTSettingsSheet *_bell;
    NSInteger _notifications;

    /**
     * Ряд действий прокручивается вбок — как `VideoActionsScrollViewer`
     * в оригинале. Всё, что ниже, лежит в нём, а не прямо на странице.
     */
    UIScrollView *_actionScroll;

    YTPillView *_votePill;
    UIImageView *_likeIcon;
    UILabel *_likeCount;
    UIView *_voteSeparator;
    UIImageView *_dislikeIcon;

    /** Число дизлайков по Return YouTube Dislike — справа от значка. */
    UILabel *_dislikeCount;
    YTPillView *_sharePill;

    /**
     * Прозрачные накладки для нажатий.
     *
     * Значки в ряду действий — обычные картинки на общей подложке,
     * своих касаний у них нет. Накладки кладутся поверх и ловят
     * нажатие каждая за своим значком.
     */
    YTTappableView *_likeTouch;
    YTTappableView *_dislikeTouch;
    YTTappableView *_shareTouch;
    UIImageView *_shareIcon;
    UILabel *_shareLabel;

    /**
     * «Скачать» — рядом с «Поделиться».
     *
     * Подпись у неё переменная: пусто, пока не трогали, проценты во время
     * загрузки и галочка у скачанного. Значок один и тот же, из набора
     * (`pl_download`) — он там лежал с самого начала и до сих пор
     * никем не использовался.
     */
    YTPillView *_downloadPill;
    YTTappableView *_downloadTouch;
    UIImageView *_downloadIcon;
    UILabel *_downloadLabel;

    /**
     * «Сохранить» — между «Поделиться» и «Скачать», как в оригинале.
     * Видна только вошедшему: плейлисты бывают лишь у учётной записи.
     */
    YTPillView *_savePill;
    YTTappableView *_saveTouch;
    UIImageView *_saveIcon;
    UILabel *_saveLabel;

    /** Лежит ли ролик хоть в одном плейлисте — по этому красится значок. */
    BOOL _savedSomewhere;

    YTSettingsSheet *_saveSheet;
    NSArray *_saveStates;

    /**
     * Сведения о ролике держим у себя — их берёт загрузчик.
     *
     * Раздел скачанного должен открываться без сети, а значит подписи
     * карточки нужно сложить рядом с файлом в тот же миг, когда загрузку
     * заводят. Спросить их потом будет не у кого.
     */
    NSDictionary *_details;

    /** Окно «убрать скачанное» — ему нужен получатель нажатий. */
    UIAlertView *_removeAlert;

    /** Панель выбора качества для скачивания — та же, что у настроек. */
    YTSettingsSheet *_downloadSheet;

    /**
     * Что сейчас показано в панели качеств и что из этого уже дошло.
     *
     * Держится ради обновления на ходу: панель открывают, чтобы следить
     * за загрузкой, и стоять с числами часовой давности она не должна.
     */
    NSArray *_downloadRowHeights;
    NSMutableSet *_downloadRowsDone;

    /** Какое качество убираем — окно подтверждения об этом не помнит. */
    NSInteger _removeHeight;

    /** Набор качеств этого ролика: спрашивается один раз. */
    NSArray *_knownHeights;
    BOOL _askingHeights;

    YTTappableView *_commentsTouch;
    YTPillView *_commentsCard;
    UILabel *_commentsTitle;
    YTRoundedImageView *_commentAvatar;
    UILabel *_commentAuthor;
    UILabel *_commentTime;
    UILabel *_commentText;

    UILabel *_status;

    /**
     * Кнопка «Пройти проверку» — показывается только тогда, когда `/player`
     * упёрся в стену «вы не робот». Обычный отказ ею не лечится, и
     * предлагать её всегда значило бы врать.
     */
    UIButton *_challenge;
    UILabel *_gateLabel;

    /**
     * Очередь подборки — порт `PlaylistQueuePanel` из Video.xaml.
     *
     * Карточка на подложке `AppSurfaceBrush` со скруглением 12 и полями 12,
     * внутри — заголовок с номером текущего ролика и складывающийся список.
     * Показывается только тогда, когда ролик открыт из плейлиста или микса:
     * в остальных случаях `Visibility="Collapsed"`.
     */
    /** Карточка глав — устроена как очередь: шапка, стрелка, строки. */
    YTPillView *_chapterCard;
    YTTappableView *_chapterHeader;
    UILabel *_chapterTitle;
    UILabel *_chapterNow;
    UIImageView *_chapterChevron;
    NSMutableArray *_chapterRows;
    BOOL _chaptersCollapsed;

    YTPillView *_queueCard;
    YTTappableView *_queueHeader;
    UILabel *_queueTitle;
    UILabel *_queuePosition;
    UIImageView *_queueChevron;
    NSArray *_queue;
    NSMutableArray *_queueRows;
    BOOL _queueCollapsed;

    /** Похожие: карточки во всю ширину, как в `RelatedVideosContainerVertical`. */
    /**
     * Раздельная раскладка: страница слева, очередь и похожие справа.
     *
     * Включается только на планшете лёжа и только пока кадр не развёрнут.
     * Там ширины хватает на две колонки, а высоты — нет: у планшета лёжа
     * её меньше, чем у телефона стоя, и всё, что ниже кадра, пришлось бы
     * долго крутить. Так же сделано в Трубаче.
     */
    BOOL _split;
    UIScrollView *_side;
    UIView *_columnDivider;

    UILabel *_relatedTitle;
    NSArray *_related;
    NSMutableArray *_relatedCards;

    /** Панель настроек за шестерёнкой — общая с Shorts. */
    YTSettingsSheet *_menu;
    NSArray *_heights;

    YTCommentsSheet *_commentsSheet;

    NSArray *_formats;
    NSInteger _pickedHeight;
    NSString *_commentsToken;

    /** Чат трансляции: метка следующей страницы и последние записи. */
    NSString *_chatToken;
    NSMutableArray *_chatItems;
    NSArray *_chatFilters;
    NSTimer *_chatTimer;

    /** Первая страница комментариев, взятая заранее, — для панели. */
    NSDictionary *_commentsPage;

    /** Субтитры: перечень дорожек, выбранная и её реплики. */
    NSArray *_subtitleTracks;
    YTSubtitleTrack *_subtitleTrack;
    NSArray *_subtitleCues;
    UILabel *_subtitleLabel;

    /**
     * Вставки SponsorBlock и место последнего прыжка.
     *
     * Последний прыжок помнится, чтобы не прыгать дважды: перемотка
     * доходит не мгновенно, и до неё отсчёт успевает снова попасть
     * в ту же вставку.
     */
    NSArray *_sponsorSegments;

    /** Отчёт об отметках пишется один раз на ролик, а не на каждый ход часов. */
    BOOL _sponsorMarksLogged;
    NSTimeInterval _lastSkippedTo;

    /** Раскадровка для перемотки и уже взятые листы. */
    YTStoryboard *_storyboard;
    NSMutableDictionary *_sheets;
    UIView *_previewBox;
    UIImageView *_previewImage;
    UILabel *_previewTime;

    /** Главы из описания: время начала каждой. */
    NSArray *_chapters;

    /** Накладки на полосе: вставки и разрывы между главами. */
    NSMutableArray *_marks;

    id _timeObserver;
    NSTimer *_hideTimer;

    /**
     * Сторож застревания: кадр стоит, а плеер играет — идёт набор.
     *
     * Наблюдатель времени для этого не годится: он срабатывает по
     * движению кадра, а застревание — это как раз его остановка. Значит,
     * свой таймер, четыре раза в секунду.
     */
    NSTimer *_stallTimer;
    NSTimeInterval _stallSeen;
    NSTimeInterval _stalledFor;
    BOOL _stalled;

    /** Адрес нынешнего потока — по нему перезаводится декодер. */
    NSString *_streamUrl;

    /** Сколько раз уже спускались сами; больше трёх незачем. */
    NSInteger _stepDowns;

    BOOL _fullscreenMode;
    BOOL _controlsVisible;
    BOOL _seeking;

    /**
     * Куда перематываем и ждём ли ещё.
     *
     * Плеер узнаёт новое положение не сразу: пока он добирает данные
     * с нужного места, `currentTime` показывает прежнее. Если верить
     * ему сразу после перемотки, ползунок отскакивает назад и время
     * продолжает идти по-старому — на неспешном канале это хорошо
     * заметно и выглядит так, будто перемотка не сработала.
     *
     * Поэтому до конца перемотки показываем то, что попросили.
     */
    BOOL _awaitingSeek;

    /** Играли ли до перемотки — нужно и обработчику, и сторожу. */
    BOOL _seekWasPlaying;

    /** Метка нынешнего прыжка: по ней узнаётся перебитый обработчик. */
    NSInteger _seekToken;

    /** Уходили ли уже с потерянной подачи на готовые адреса. */
    BOOL _sabrFellBack;

    /** Заявка на фоновую работу, пока приложение свёрнуто. */
    UIBackgroundTaskIdentifier _backgroundTask;
    NSTimeInterval _seekTarget;

    /** Сколько раз уже брали ссылку заново из-за сменившегося выхода. */
    NSInteger _refusalRetries;
    BOOL _finished;

    /** Человек хотел смотреть: пауза не его, а системы или фона. */
    BOOL _meantToPlay;

    /** Отмечали ли уже этот ролик просмотренным. */
    BOOL _watchReported;

    /**
     * Ответ `/player`, из которого берутся адреса сигналов просмотра.
     *
     * Первый, запрошенный от имени выбранного канала, — и он не меняется,
     * даже когда играть пришлось готовыми адресами VISIONOS: сигналы
     * по его адресам сервер записывал бы не в историю канала.
     */
    NSDictionary *_trackingJson;

    /** Запись просмотра: конец прошлого отрезка и когда он начался. */
    NSTimeInterval _watchSegmentFrom;
    NSTimeInterval _watchSegmentAt;
    NSInteger _watchPings;
    NSTimer *_watchTimer;

    /** Запись просмотра уже закрыта последним отрезком — второй раз не шлём. */
    BOOL _watchClosed;

    /** Когда последний раз записали место показа в незакрытую запись. */
    NSTimeInterval _pendingNotedAt;

    YTTappableView *_channelTouch;

    /** Название — кнопка описания, и само описание при нём. */
    YTTappableView *_titleTouch;
    YTSettingsSheet *_descriptionSheet;
    NSString *_descriptionText;

    /** Просмотры и дата в том виде, в каком их прислал сервер. */
    NSString *_viewsText;
    NSString *_publishedText;

    /** Ступень, взятая на готовых адресах, — там выбираем мы сами. */
    NSInteger _readyHeight;

    /** Сворачиваемся ли мы сейчас в мини-окно, и приняли ли плеер из него. */
    BOOL _minimising;
    BOOL _adopted;

    /**
     * Плеер уже играет принятым из мини-окна.
     *
     * Отдельно от «плеер не nil»: тот бывает не nil и у сорвавшегося
     * потока, который как раз и надо запустить заново.
     */
    BOOL _playingAdopted;

    /**
     * Подписан ли `status` у нынешнего элемента.
     *
     * У принятого из мини-окна элемента наблюдателя нет — он давно
     * готов, слушать нечего. Снимать неподписанного нельзя: UIKit на
     * это отвечает исключением, а не молчанием.
     */
    BOOL _observingStatus;

    /** Отвязана ли сейчас видеоповерхность — то есть были ли мы в фоне. */
    BOOL _surfaceDetached;

    /** Когда начали возвращать картинку — чтобы знать, сколько это заняло. */
    NSTimeInterval _surfaceReturn;
    UIPanGestureRecognizer *_edgeBack;

    /** Протяг вниз по кадру — то же, что кнопка сворачивания. */
    UIPanGestureRecognizer *_collapseDrag;

    /**
     * Разведение пальцев по кадру — в полный экран, сведение — обратно.
     * `_zoomUsed` не даёт одному жесту сработать дважды: порог пройден
     * один раз, а `Changed` приходит и дальше.
     */
    UIPinchGestureRecognizer *_zoom;
    BOOL _zoomUsed;

    /**
     * Растянут ли кадр по экрану — верхняя ступень зума.
     *
     * Живёт только в полном экране: в окне кадр и так по ширине, а
     * обрезать его там было бы вредом без выгоды. Поэтому выход из
     * полного экрана эту ступень снимает.
     */
    BOOL _fillsScreen;

    /**
     * Свободное увеличение кадра: во сколько раз и куда сдвинут.
     *
     * Единица и ноль означают «как было»: слой без преобразования, и
     * весь прежний порядок — вписан или растянут — решается одной только
     * укладкой. Зум поверх неё, а не вместо: растянутый по экрану кадр
     * тоже можно приблизить.
     */
    CGFloat _zoomScale;
    CGPoint _zoomShift;

    /** С чего начался нынешний жест: масштаб и середина между пальцами. */
    CGFloat _zoomFrom;
    CGPoint _zoomAnchor;

    /**
     * Прокрутка страницы, выключенная на время жеста по кадру.
     *
     * Кадр в обычном виде лежит **внутри** прокрутки, и палец, ведущий
     * вниз, заодно оттягивал бы страницу за верхний край. Выключение
     * отменяет её протяг и убирает это подрагивание.
     */
    BOOL _pageScrollHeld;

    /** Метка захода: по ней бракуются запуски, начатые до ухода. */
    YTGeneration *_loadGeneration;

    /** Ожидание объявленной трансляции: когда начнётся и когда пробовали. */
    NSTimeInterval _broadcastAt;

    /** Готовая надпись ожидания от сервера — когда час начала неизвестен. */
    NSString *_broadcastSaid;
    NSTimeInterval _broadcastTriedAt;
    NSTimer *_broadcastWatch;

    /** Ждём ли возобновления прерванного эфира, и с каким тактом пробуем. */
    BOOL _broadcastResuming;
    NSTimeInterval _broadcastEvery;

    /** Проверка, не кончилась ли идущая трансляция: когда и идёт ли сейчас. */
    NSTimeInterval _broadcastCheckedAt;
    BOOL _broadcastChecking;

    /** Остановка эфира: показана ли надпись и когда перезапускали поток. */
    BOOL _liveStallNoted;
    NSTimeInterval _liveHardRestartAt;

    /** Ближайший `load` пересобирает только поток, не трогая страницу. */
    BOOL _reloadStreamOnly;

    /** Когда последний раз писали запас в журнал. */
    NSTimeInterval _healthSaidAt;

    /** Посекундная сводка: когда писали и сколько байт было тогда. */
    NSTimeInterval _statsSaidAt;
    long long _statsBytes;

    /** Когда последний раз брали свежую подачу и идёт ли это сейчас. */
    NSTimeInterval _feedRenewAt;
    BOOL _feedRenewing;

    /** Запас плеера на последнем замере — по нему решаем, как скоро вмешиваться. */
    double _healthBuffer;

    /** Сколько замеров кряду запас убывает. */
    NSInteger _healthFalls;

    /** Кто автор и подписаны ли мы на него. */
    NSString *_channelId;
    BOOL _subscribed;

    /** Наша оценка ролика и приметы для её изменения. */
    BOOL _liked;
    BOOL _disliked;
    NSDictionary *_rateParams;

    UILabel *_notice;

    NSTimeInterval _duration;
    NSInteger _maxHeight;

    /**
     * Ответ `/player` целиком и выбранная озвучка.
     *
     * Нужны, чтобы пересобрать подачу при смене качества или языка:
     * там нет готовых адресов, и заново просить приходится весь набор.
     */
    NSDictionary *_playerJson;
    NSString *_audioTrack;

    /** Спрашивали ли про дорожку у этого ролика — один раз на показ. */
    BOOL _askedAudioTrack;

    /**
     * Какая страница меню открыта: сама панель (0) либо список качеств,
     * скоростей, озвучек, субтитров.
     *
     * В оригинале это отдельные `StackPanel` внутри одного нижнего
     * листа — `MainSettingsPanel`, `QualitySettingsPanel` и прочие, —
     * которые показываются по очереди. Здесь то же самое одним числом:
     * строки всё равно перестраиваются заново на каждом открытии.
     */
    NSInteger _menuPage;

    /** Скорость воспроизведения; 1.0 — обычная. */
    float _rate;
}

- (id)initWithVideoId:(NSString *)videoId title:(NSString *)title {
    return [self initWithVideoId:videoId title:title playlist:nil];
}

- (id)initWithVideoId:(NSString *)videoId
                title:(NSString *)title
             playlist:(NSString *)playlistId {
    self = [super init];

    if (self != nil) {
        _videoId = [videoId copy];
        _titleText = [title copy];
        _playlistId = [playlistId copy];
        _maxHeight = [YTStreams deviceMaxHeight];

        // Ноль — это годная заявка, а «нет заявки» помечается отдельно.
        _backgroundTask = UIBackgroundTaskInvalid;

        /**
         * Скорость — с самого начала обычная.
         *
         * Поля объекта начинаются с нуля, а ноль для скорости означает
         * паузу. Я выставлял единицу только при переходе к другому
         * ролику, и первое открытие уходило в `setRate:0` — плеер честно
         * исполнял приказ и стоял. Выглядело это как «видео не играет
         * ни в каком качестве», хотя сегменты собирались исправно.
         */
        _rate = 1.0f;

        /**
         * Предпочитаемое качество из настроек **перевешивает** меру
         * устройства.
         *
         * Раньше здесь стоял `MIN`, и выбранные вручную 1080p на A4
         * молча превращались в 720p. Мера устройства — совет: она
         * решает, что взять при «Авто», а названное человеком число
         * исполняется как сказано. Не пойдёт — он это увидит, и лучше
         * так, чем гадать, почему настройка не действует.
         */
        NSInteger preferred = [YTSettings preferredHeight];

        if (preferred > 0) {
            _maxHeight = preferred;

            /**
             * Названное в настройках отмечается в шестерёнке как выбранное.
             *
             * Иначе меню открывалось с пометкой «Авто» — при том, что
             * никакого «Авто» не было: качество задано человеком и им же
             * ограничена подача. Пометка стояла на строке, которая не
             * описывала ничего.
             */
            _pickedHeight = preferred;
        }

        _loadGeneration = [[YTGeneration alloc] init];

        /**
         * Тот же ролик уже играет в мини-окне — забираем его себе.
         * Ни запроса, ни подачи заново: и то и другое уже сделано.
         */
        if ([YTMiniPlayer isActive]) {
            if ([[YTMiniPlayer videoId] isEqualToString:videoId]) {
                _adopted = YES;
            } else {
                /**
                 * Открывают другой ролик — свёрнутый закрываем.
                 *
                 * Двух воспроизведений разом быть не должно: петля у
                 * приложения одна, и новый поток всё равно отберёт её
                 * у свёрнутого. Тот замолчал бы посреди кадра, оставшись
                 * висеть окном, — лучше убрать его сразу и честно.
                 */
                NSLog(@"[YouTube/Мини] Открыт другой ролик — закрываем окно");

                [YTMiniPlayer close];
            }
        }

        _relatedCards = [NSMutableArray array];
        _queueRows = [NSMutableArray array];
        _chapterRows = [NSMutableArray array];

        // Свёрнуты по умолчанию — как в оригинале.
        _chaptersCollapsed = YES;
    }

    return self;
}

#pragma mark Ориентация

/**
 * Landscape разрешается только в развёрнутом кадре — и только на телефоне.
 *
 * Задать ориентацию извне на iOS нельзя, её можно лишь разрешить или
 * запретить, а поворачивает устройство человек. На планшете landscape
 * разрешён всегда: там это не особый режим, а обычное положение.
 */
- (BOOL)allowsLandscape {
    if (_fullscreenMode || UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        return YES;
    }

    /**
     * «Полный экран при повороте» — порт
     * `AutoFullscreenLandscapeToggleButton`. Со включённой настройкой
     * landscape разрешён и на странице: повернув телефон, человек получает
     * развёрнутый кадр, а не перевёрнутую страницу. Само разворачивание
     * делает `willRotateToInterfaceOrientation:`.
     */
    return [YTSettings autoFullscreenInLandscape];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    if (orientation == UIInterfaceOrientationPortrait) {
        return YES;
    }

    if (orientation == UIInterfaceOrientationPortraitUpsideDown) {
        return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad;
    }

    return [self allowsLandscape];
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    if ([self allowsLandscape]) {
        return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad
            ? UIInterfaceOrientationMaskAll
            : UIInterfaceOrientationMaskAllButUpsideDown;
    }

    return UIInterfaceOrientationMaskPortrait;
}

#pragma mark Построение

- (void)loadView {
    YTUseFullScreenLayout(self);

    [super loadView];

    [[self view] setBackgroundColor:[YTTheme background]];

    _page = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [_page setBackgroundColor:[YTTheme background]];
    [[self view] addSubview:_page];

    [self buildStage];
    [self buildDetails];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(enteredBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(enteredForeground)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];

    /**
     * И на «стали деятельны» тоже.
     *
     * Погасший сам по себе экран не всегда доводит приложение до фона:
     * бывает одно `WillResignActive`, и тогда `WillEnterForeground`
     * при возврате не приходит вовсе. Пересоздать поверхность дважды
     * не жалко, а не пересоздать — это чёрный кадр.
     */
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(enteredForeground)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sabrLost)
                                                 name:YTSabrLostNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sabrRefusedPick)
                                                 name:YTSabrPinRefusedNotification
                                               object:nil];

    [self adoptFromMini];

    [self load];
}

/**
 * Забирает плеер у мини-окна: слой возвращается в кадр страницы,
 * воспроизведение не прерывается.
 *
 * Подачу при этом не трогаем — она та же самая, и переоткрыв её,
 * мы оборвали бы ровно то, что человек и просил вернуть, нажав
 * по окошку.
 */
- (void)adoptFromMini {
    if (!_adopted) {
        return;
    }

    _adopted = NO;

    AVPlayer *player = [YTMiniPlayer adoptPlayer];
    AVPlayerLayer *layer = [YTMiniPlayer adoptLayer];

    if (player == nil) {
        return;
    }

    _player = player;
    _playerLayer = layer;
    _playingAdopted = YES;

    if (_playerLayer == nil) {
        _playerLayer = [AVPlayerLayer playerLayerWithPlayer:player];
    }

    [_playerLayer setVideoGravity:[self videoGravity]];
    [_playerLayer setFrame:[_videoHost bounds]];
    [[_videoHost layer] addSublayer:_playerLayer];

    /**
     * Наблюдатель состояния здесь не нужен: элемент давно готов —
     * он играет. А вот отсчёт времени и конец ролика страница слушает
     * сама, иначе полоса стояла бы на месте.
     */
    __weak YTPlayerViewController *weakSelf = self;

    _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMake(1, 2)
                                                          queue:dispatch_get_main_queue()
                                                     usingBlock:^(CMTime time) {
        [weakSelf tick];
    }];

    /**
     * Элемент запоминается и здесь — чтобы `detachPlayerObservers`
     * знал, с кого снимать оповещение о конце ролика при следующем
     * сворачивании. `status` у него не подписан, о чём и говорит
     * `_observingStatus`.
     */
    _observedItem = [_player currentItem];
    _observingStatus = NO;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playbackFinished)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:_observedItem];

    _duration = [[YTHlsProxy shared] duration];

    if (_duration <= 0) {
        CMTime known = [[_player currentItem] duration];

        if (CMTIME_IS_NUMERIC(known)) {
            _duration = CMTimeGetSeconds(known);
        }
    }

    [_playPause setImage:YTDarkIcon([_player rate] > 0 ? @"pl_pause" : @"pl_play")
                forState:UIControlStateNormal];

    [_busy stop];

    [self updateProgress];
    [self startStallWatch];

    NSLog(@"[YouTube/Плеер] Ролик принят обратно у мини-окна");
}

/**
 * Круглая кнопка пульта — порт `ControlButtonStyle`: эллипс заливкой
 * `#66000000`, значок по центру, непрозрачность 0.8.
 */
- (YTRoomyButton *)stageButton:(NSString *)icon side:(CGFloat)side action:(SEL)action {
    YTRoomyButton *button = [YTRoomyButton buttonWithType:UIButtonTypeCustom];

    // Кнопки пульта лежат поверх кадра — значок всегда из тёмного набора.
    [button setImage:YTDarkIcon(icon) forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    [button setBackgroundColor:[UIColor colorWithWhite:0 alpha:0.4]];
    [button setAlpha:0.8];

    [[button layer] setCornerRadius:side / 2];

    // Значок не растягивается на всю кнопку: в оригинале он заметно мельче.
    [[button imageView] setContentMode:UIViewContentModeScaleAspectFit];

    [_overlay addSubview:button];

    return button;
}

/**
 * Число под значком перемотки: на сколько секунд шаг.
 *
 * Отдельной подписью поверх кнопки, а не значком с цифрой внутри:
 * значков у нас набор из оригинала, и рисовать новые ради двух чисел
 * незачем. Нажатия подпись не забирает — она лежит на кнопке.
 */
- (UILabel *)stageMark:(NSString *)number on:(UIButton *)button {
    UILabel *mark = YTLabel(YTFontSemiBold(9), [UIColor whiteColor], 1);

    [mark setText:number];
    [mark setTextAlignment:NSTextAlignmentCenter];
    [mark setUserInteractionEnabled:NO];
    [button addSubview:mark];

    return mark;
}

- (void)rewindTapped {
    [self skipBy:-5];
    [self showControls];
}

- (void)forwardTapped {
    [self skipBy:15];
    [self showControls];
}

- (void)buildStage {
    _stage = [[UIView alloc] initWithFrame:CGRectZero];

    // `Background="#0f0f0f"` у PlayerGrid — не цвет темы, а число: кадр
    // остаётся тёмным и в светлом оформлении.
    [_stage setBackgroundColor:YTColor(0x0F0F0F)];
    [[self view] addSubview:_stage];

    _videoHost = [[UIView alloc] initWithFrame:CGRectZero];
    [_videoHost setBackgroundColor:YTColor(0x0F0F0F)];
    [_stage addSubview:_videoHost];

    _busy = [[YTLoadingRing alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
    [_stage addSubview:_busy];
    [_busy start];

    _overlay = [[UIView alloc] initWithFrame:CGRectZero];
    [_stage addSubview:_overlay];

    _stats = [[YTStatsPanel alloc] initWithFrame:CGRectZero];
    [_stats setHidden:YES];
    [_stage addSubview:_stats];

    __weak YTPlayerViewController *weakForStats = self;

    [_stats setOnClose:^{ [weakForStats toggleStats]; }];

    [_stats setSource:^YTStatsSnapshot *{
        YTPlayerViewController *strong = weakForStats;

        if (strong == nil) {
            return nil;
        }

        YTStatsSnapshot *snapshot = [[YTStatsSnapshot alloc] init];

        snapshot.player = strong->_player;
        snapshot.playerJson = strong->_playerJson;
        snapshot.sabr = strong->_sabrFellBack ? nil : [YTStreams lastSabr];
        snapshot.videoId = strong->_videoId;
        snapshot.heights = strong->_heights;
        snapshot.viewport = [strong->_videoHost bounds].size;
        snapshot.rate = strong->_rate;

        return snapshot;
    }];

    /**
     * Затемнения на весь кадр в оригинале нет: пульт читается за счёт
     * подложек у самих кнопок и картинки-градиента под нижним рядом.
     * Поэтому накладка прозрачная.
     */
    [_overlay setBackgroundColor:[UIColor clearColor]];

    // Название и автор поверх кадра — только в развёрнутом виде.
    _fullscreenTitle = YTLabel(YTFontSemiBold(16), [UIColor whiteColor], 1);
    [_fullscreenTitle setHidden:YES];
    [_overlay addSubview:_fullscreenTitle];

    _fullscreenAuthor = YTLabel(YTFontRegular(13), YTColor(0xDDDDDD), 1);
    [_fullscreenAuthor setHidden:YES];
    [_overlay addSubview:_fullscreenAuthor];

    _minimize = [self stageButton:@"pl_collapse"
                             side:YTStageButton
                           action:@selector(collapseTapped)];

    _settings = [self stageButton:@"pl_settings"
                             side:YTStageButton
                           action:@selector(settingsTapped)];

    /**
     * Перемотка кнопками — как в Трубаче: назад на 5 секунд, вперёд на 15.
     *
     * Числа оттуда же и взяты. Они не случайны: назад отматывают, когда
     * прослушали пару слов, а вперёд перепрыгивают через заставку или
     * затянутое вступление — и шаг там нужен крупнее. Вид наш: тот же
     * круг с полупрозрачной подложкой, что у остальных кнопок пульта,
     * только с числом под значком, чтобы шаг был виден без догадок.
     */
    _rewind = [self stageButton:@"pl_back"
                           side:YTStageButton
                         action:@selector(rewindTapped)];

    _rewindMark = [self stageMark:@"5" on:_rewind];

    /**
     * Запас в двенадцать точек с каждой стороны.
     *
     * До кнопки воспроизведения от них двадцать восемь, так что запасы
     * соседей не сходятся: между ними остаётся полоска в четыре точки,
     * и нажать «play» вместо перемотки нельзя.
     */
    [_rewind setSlack:UIEdgeInsetsMake(12, 12, 12, 12)];

    _playPause = [self stageButton:@"pl_play"
                              side:YTStageCenter
                            action:@selector(playPauseTapped)];

    _forward = [self stageButton:@"pl_skip"
                            side:YTStageButton
                          action:@selector(forwardTapped)];

    _forwardMark = [self stageMark:@"15" on:_forward];

    [_forward setSlack:UIEdgeInsetsMake(12, 12, 12, 12)];

    /**
     * Окно предпросмотра при перемотке.
     *
     * Кадры лежат на общих листах-спрайтах, поэтому окно составное:
     * снаружи коробка с обрезкой по краям, внутри — весь лист, сдвинутый
     * так, чтобы в проём попал нужный кадр. Так же устроен предпросмотр
     * и в оригинале.
     */
    _previewBox = [[UIView alloc] initWithFrame:CGRectZero];
    [_previewBox setBackgroundColor:[UIColor blackColor]];
    [_previewBox setClipsToBounds:YES];
    [_previewBox setHidden:YES];
    [_previewBox setUserInteractionEnabled:NO];
    [[_previewBox layer] setBorderWidth:1];
    [[_previewBox layer] setBorderColor:[[UIColor whiteColor] CGColor]];
    [_overlay addSubview:_previewBox];

    _previewImage = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_previewBox addSubview:_previewImage];

    _previewTime = YTLabel(YTFontSemiBold(12), [UIColor whiteColor], 1);
    [_previewTime setTextAlignment:NSTextAlignmentCenter];
    [_previewTime setBackgroundColor:[UIColor colorWithWhite:0 alpha:0.6f]];
    [_previewTime setHidden:YES];
    [_overlay addSubview:_previewTime];

    // Нижняя полоса: картинка-затемнение, поверх неё время и разворот.
    _scrim = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_scrim setImage:YTDarkIcon(@"pl_scrim")];
    [_scrim setContentMode:UIViewContentModeScaleToFill];
    [_scrim setUserInteractionEnabled:NO];
    [_overlay addSubview:_scrim];

    // `Background="#80000000"`, `CornerRadius="15"`.
    _timePill = [[YTPillView alloc] initWithFrame:CGRectZero];
    [_timePill setFillColor:[UIColor colorWithWhite:0 alpha:0.5]];
    [_timePill setCornerRadius:15];
    [_overlay addSubview:_timePill];

    _time = YTLabel(YTFontSemiBold(14), [UIColor whiteColor], 1);
    [_time setTextAlignment:NSTextAlignmentCenter];
    [_time setText:@"0:00 / 0:00"];
    [_overlay addSubview:_time];

    _fullscreen = [self stageButton:@"pl_fullscreen"
                               side:YTStageButton
                             action:@selector(fullscreenTapped)];

    /**
     * Здесь запас несимметричный.
     *
     * Вверх и в стороны расширяться можно свободно: там пусто. А снизу
     * в четырёх точках проходит полоса воспроизведения, и запас под
     * кнопкой отнимал бы у неё касания — потянуть ползунок у правого края
     * стало бы нельзя. Поэтому снизу оставляем две точки: попасть проще,
     * перемотке не мешает.
     */
    [_fullscreen setSlack:UIEdgeInsetsMake(14, 14, 2, 14)];

    /**
     * Полоса воспроизведения. В оригинале это `Slider` со своим шаблоном:
     * дорожка `#666666`, пройденная часть `#f03`, кружок 16 точек того же
     * цвета. Здесь то же самое обычными видами — штатный `UISlider`
     * пришлось бы перекрашивать картинками, а рисунок у него всё равно
     * другой.
     */
    _track = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_track setBackgroundColor:YTColor(0x666666)];
    [[_track layer] setCornerRadius:YTTrackHeight / 2];
    [_overlay addSubview:_track];

    _trackFill = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_trackFill setBackgroundColor:YTColor(0xFF0033)];
    [[_trackFill layer] setCornerRadius:YTTrackHeight / 2];
    [_overlay addSubview:_trackFill];

    _thumb = [[UIImageView alloc] initWithFrame:
        CGRectMake(0, 0, YTThumbSide, YTThumbSide)];
    [_thumb setBackgroundColor:YTColor(0xFF0033)];
    [[_thumb layer] setCornerRadius:YTThumbSide / 2];
    [_overlay addSubview:_thumb];

    /**
     * Полосу одеваем сразу и ещё раз при смене оформления.
     *
     * Здесь — чтобы она была одета к первому же показу; в `applyTheme`
     * ниже — чтобы переодевалась, когда оформление сменили при открытом
     * плеере.
     */
    [YTSkin dressTrack:_track fill:_trackFill knob:_thumb];

    /**
     * Нажатия по кадру разбираются распознавателями, а не отдельными
     * слоями-поверхностями: иначе одиночное и двойное не развести —
     * `UIControl` срабатывает сразу по отпусканию пальца.
     */
    UITapGestureRecognizer *single =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(stageTapped)];

    /**
     * Получатель нужен ради одного правила — не отбирать касания
     * у кнопок пульта. Подробности у `gestureRecognizer:shouldReceiveTouch:`.
     */
    [single setDelegate:self];

    [_stage addGestureRecognizer:single];

    UIPanGestureRecognizer *scrub =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(scrubbed:)];

    [scrub setDelegate:self];

    // Перематывают одним пальцем. Без этого двупалое сведение по кадру
    // сходило бы заодно и за протяг по полосе.
    [scrub setMaximumNumberOfTouches:1];

    [_overlay addGestureRecognizer:scrub];

    /**
     * Протяг вниз по кадру — то же, что кнопка сворачивания в его углу.
     *
     * Кнопка остаётся: жест ей не замена, а короткий путь. Условия, при
     * которых он засчитывается, — в `gestureRecognizerShouldBegin:`;
     * там же он уступает дорогу полосе перемотки, которая живёт на том
     * же кадре и тоже ловит движение пальцем.
     */
    UIPanGestureRecognizer *drag =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(collapseDragged:)];

    [drag setDelegate:self];
    [drag setMaximumNumberOfTouches:1];

    [_stage addGestureRecognizer:drag];

    _collapseDrag = drag;

    /**
     * Разведение пальцев — в полный экран, сведение — обратно.
     *
     * Оба направления, а не одно: жест, который только разворачивает,
     * человек всё равно попробует применить наоборот, и молчание в ответ
     * читалось бы поломкой. Так же ведёт себя и официальный клиент.
     */
    UIPinchGestureRecognizer *zoom =
        [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(zoomed:)];

    [zoom setDelegate:self];

    [_stage addGestureRecognizer:zoom];

    _zoom = zoom;

    /**
     * Строка субтитров лежит на кадре, а **не** в накладке пульта.
     *
     * Это принципиально: пульт прячется, гася накладку целиком, и строка
     * внутри неё пропадала вместе с кнопками — субтитры было видно ровно
     * до того мига, как пульт уезжал. Кадру же гаснуть незачем, и строка
     * на нём остаётся, пока включена.
     *
     * Заводится после накладки — значит, лежит выше неё, и пульт строку
     * не перекрывает. Нажатия по кадру она не забирает: распознаватели
     * висят на самом кадре и получают касания и в её видах, — но свой
     * протяг ловит, субтитры двигают пальцем.
     */
    _subtitleLabel = YTLabel(YTFontSemiBold(15), [UIColor whiteColor], 3);
    [_subtitleLabel setTextAlignment:NSTextAlignmentCenter];
    [_subtitleLabel setBackgroundColor:[UIColor colorWithWhite:0 alpha:0.6f]];
    [_subtitleLabel setUserInteractionEnabled:YES];
    [_subtitleLabel setHidden:YES];
    [_stage addSubview:_subtitleLabel];

    UIPanGestureRecognizer *move =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(moveSubtitles:)];

    [_subtitleLabel addGestureRecognizer:move];

    _controlsVisible = YES;

    [self scheduleHide];

    /**
     * Протяжка от левого края — уход назад, с закрытием плеера.
     *
     * Сворачивание в мини-плеер — дело отдельной кнопки. Здесь именно
     * уход: человек показал, что ролик ему больше не нужен, и оставлять
     * звук играть в свёрнутом виде было бы навязчиво.
     *
     * Своя протяжка, а не системная: полоса навигации у нас скрыта,
     * и системный жест при этом до конца не доводит — из-за него же
     * не работала кнопка «назад» в настройках.
     */
    UIPanGestureRecognizer *edge =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(edgeBack:)];

    [edge setDelegate:self];
    [[self view] addGestureRecognizer:edge];

    _edgeBack = edge;
}

/**
 * Протяжка засчитывается, только если начата у самого края и идёт вбок.
 *
 * Иначе она отбирала бы касания у прокрутки страницы и у перемотки
 * по полосе: обе живут на том же экране и тоже ловят движение пальцем.
 */
/**
 * Касания по кнопкам пульта распознавателям не отдаются.
 *
 * **Из-за этого пульт не работал на iOS 5.** Распознаватель нажатия
 * висит на `_stage`, а кнопки лежат в накладке внутри него, то есть
 * ниже по дереву. С iOS 6 UIKit разводит их сам: касание, которое
 * берёт на себя `UIControl`, надвидовому распознавателю уже не достаётся.
 * На пятой такого правила нет — распознаватель забирает касание себе
 * и, поскольку `cancelsTouchesInView` включён по умолчанию, отменяет
 * доставку кнопке. Нажатие уходит в пустоту: пульт лишь прячется,
 * а кнопка не срабатывает.
 *
 * Поэтому разводим вручную и на всех системах одинаково: попали
 * в `UIControl` — распознаватель молчит. Заодно уходит зависимость
 * поведения от версии там, где её быть не должно.
 */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
       shouldReceiveTouch:(UITouch *)touch {
    /**
     * Строку субтитров двигают пальцем, и движение это в том числе вниз.
     * Свои жесты кадра здесь молчат, иначе строку нельзя было бы опустить
     * — плеер сворачивался бы на полпути.
     */
    if (gesture == _collapseDrag || gesture == _zoom) {
        UIView *hit = [touch view];

        while (hit != nil && hit != [self view]) {
            if (hit == _subtitleLabel) {
                return NO;
            }

            hit = [hit superview];
        }
    }

    UIView *hit = [touch view];

    while (hit != nil && hit != [self view]) {
        if ([hit isKindOfClass:[UIControl class]]) {
            return NO;
        }

        hit = [hit superview];
    }

    return YES;
}

/**
 * Не занята ли эта точка полосой перемотки.
 *
 * Полоса лежит внизу кадра и ловит движение пальцем, а запас в 22 точки
 * над ней — тот же, что у `scrubbed:`: попасть в четырёхточечную полосу
 * пальцем иначе нельзя. Всё, что начато здесь, принадлежит перемотке,
 * и отбирать у неё эти касания нельзя.
 */
- (BOOL)pointIsOnTrack:(CGPoint)point {
    return point.y > CGRectGetMinY([_track frame]) - 22;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (gesture == _edgeBack) {
        CGPoint start = [gesture locationInView:[self view]];

        if (start.x > 24) {
            return NO;
        }

        CGPoint move = [(UIPanGestureRecognizer *)gesture translationInView:[self view]];

        return fabs(move.x) > fabs(move.y);
    }

    if (gesture == _collapseDrag) {
        /**
         * В развёрнутом виде сворачивать нечего: кнопки в углу там нет
         * вовсе, её место занимает название ролика, — и жест, который
         * делал бы то, чего в этом виде не делают кнопкой, здесь лишний.
         */
        if (_fullscreenMode) {
            return NO;
        }

        if ([self pointIsOnTrack:[gesture locationInView:_overlay]]) {
            return NO;
        }

        /**
         * Только вниз и только если страница уже наверху. Иначе жест
         * отбирал бы у прокрутки её же движение: кадр лежит внутри
         * прокрутки, и снизу к нему подходят как раз протягом вниз.
         */
        if ([_page contentOffset].y > 0) {
            return NO;
        }

        CGPoint move = [(UIPanGestureRecognizer *)gesture translationInView:_stage];

        return move.y > 0 && move.y > fabs(move.x);
    }

    return YES;
}

/**
 * Прокрутка страницы придерживается на время жеста по кадру.
 *
 * Кадр в обычном виде лежит внутри неё, и палец, ведущий вниз или
 * сводящий два пальца, заодно оттягивал бы страницу за верхний край.
 * Выключение прокрутки на ходу отменяет её собственный протяг — рывок
 * не успевает начаться.
 */
- (void)holdPageScroll:(BOOL)hold {
    if (hold == _pageScrollHeld) {
        return;
    }

    _pageScrollHeld = hold;

    [_page setScrollEnabled:!hold];
}

- (void)collapseDragged:(UIPanGestureRecognizer *)gesture {
    if ([gesture state] == UIGestureRecognizerStateBegan) {
        [self holdPageScroll:YES];

        return;
    }

    if ([gesture state] == UIGestureRecognizerStateCancelled) {
        [self holdPageScroll:NO];

        return;
    }

    if ([gesture state] != UIGestureRecognizerStateEnded) {
        return;
    }

    [self holdPageScroll:NO];

    if (_fullscreenMode) {
        return;
    }

    CGPoint move = [gesture translationInView:_stage];

    /**
     * Шестьдесят точек — тот же порог, что у ухода протяжкой от края:
     * дрожь пальца в него не укладывается, а намеренное движение
     * укладывается с запасом.
     */
    if (move.y < 60 || fabs(move.x) > move.y) {
        return;
    }

    [self collapseTapped];
}

- (void)zoomed:(UIPinchGestureRecognizer *)gesture {
    if ([gesture state] == UIGestureRecognizerStateBegan) {
        _zoomUsed = NO;
        _zoomFrom = (_zoomScale > 0) ? _zoomScale : 1.0f;
        _zoomAnchor = [gesture locationInView:_videoHost];

        [self holdPageScroll:YES];

        return;
    }

    if ([gesture state] == UIGestureRecognizerStateEnded ||
        [gesture state] == UIGestureRecognizerStateCancelled) {
        [self holdPageScroll:NO];
        [self settleZoom];

        return;
    }

    if ([gesture state] != UIGestureRecognizerStateChanged || _zoomUsed) {
        return;
    }

    /**
     * В полном экране пальцы двигают кадр, а не переключают ступени.
     *
     * Ступенчатая лестница ниже осталась для окна: развели — развернули.
     * А когда кадр уже во весь экран, дальше разводить пальцы незачем
     * ради ещё одной ступени — там начинается обычное увеличение, какое
     * бывает у картинок: во сколько угодно раз и с перетаскиванием
     * серединой между пальцами.
     */
    if (_fullscreenMode) {
        CGFloat wanted = _zoomFrom * [gesture scale];

        // Ниже единицы кадр не уменьшаем: под ним чернота, а не страница.
        CGFloat scale = MAX((CGFloat)1.0, MIN((CGFloat)6.0, wanted));

        CGPoint middle = [gesture locationInView:_videoHost];

        _zoomShift = CGPointMake(_zoomShift.x + middle.x - _zoomAnchor.x,
                                 _zoomShift.y + middle.y - _zoomAnchor.y);
        _zoomAnchor = middle;
        _zoomScale = scale;

        // За край кадр не пускаем вовсе, а не подтягиваем потом.
        _zoomShift = [self settledShift];

        [self applyZoom];

        /**
         * Подошли близко к величине, при которой полосы исчезают, —
         * защёлкиваем её.
         *
         * Руками поймать эту величину нельзя: промах в пару процентов
         * оставляет то щель по краю, то лишнюю обрезку. А промахнуться
         * легко — кадр при этом выглядит почти правильно, и человек
         * так и смотрит с полоской в палец шириной.
         */
        if ([self shouldSnapToFill:scale]) {
            _zoomUsed = YES;

            [self resetZoom];
            [self setFillsScreen:YES];

            [self showNotice:YTLoc(@"Полосы убраны")];
        }

        /**
         * Свели пальцы, а уменьшать уже некуда — значит просят выйти.
         *
         * Тот же жест, что и в окне, и то же условие: сведение на четверть
         * от начала. Без этого выход из полного экрана пропадал бы, стоило
         * один раз приблизить кадр.
         */
        if (scale <= 1.0f && wanted < 0.75f) {
            _zoomUsed = YES;

            [self resetZoom];
            [self fullscreenTapped];
        }

        return;
    }

    /**
     * Пороги несимметричны нарочно: разводят пальцы размашисто, а сводят
     * скупо — пальцы упираются друг в друга. Полуторный размах наружу
     * и три четверти внутрь примерно равны по усилию.
     */
    CGFloat scale = [gesture scale];

    /**
     * Лестница из трёх ступеней, вверх и вниз одним и тем же жестом:
     *
     *     окно → полный экран → полный экран без полей
     *
     * Средняя ступень вписывает кадр целиком, и у ролика, снятого
     * не под экран, сверху и снизу остаются чёрные поля. Верхняя
     * растягивает кадр по большей стороне: поля уходят, но края кадра
     * при этом обрезаются — это размен, а не улучшение, и потому он
     * отдельным шагом, а не делается сам.
     *
     * Обратный ход зеркальный: сперва возвращаем поля, и лишь потом
     * выходим из полного экрана. Иначе одно сведение пальцев меняло бы
     * сразу две вещи, и вернуть только одну из них было бы нельзя.
     */
    if (scale > 1.5f) {
        _zoomUsed = YES;

        if (!_fullscreenMode) {
            [self fullscreenTapped];
        } else {
            [self setFillsScreen:YES];
        }
    } else if (scale < 0.75f) {
        _zoomUsed = YES;

        if (_fillsScreen) {
            [self setFillsScreen:NO];
        } else if (_fullscreenMode) {
            [self fullscreenTapped];
        }
    }
}
// Короткие сообщения показывает `showNotice:` — она уже есть ниже.

/**
 * Кладёт нынешнее увеличение на слой.
 *
 * Преобразованием, а не размером: у слоя с преобразованием `frame`
 * считается из него же, и укладка, ставящая рамку, стёрла бы зум.
 * Действия отключаем — иначе каждый шаг жеста Core Animation
 * проигрывает четверть секунды, и кадр тянется за пальцами с отставанием.
 */
- (void)applyZoom {
    if (_playerLayer == nil) {
        return;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    if (_zoomScale <= 1.0f) {
        [_playerLayer setAffineTransform:CGAffineTransformIdentity];
    } else {
        CGAffineTransform move =
            CGAffineTransformMakeTranslation(_zoomShift.x, _zoomShift.y);

        [_playerLayer setAffineTransform:
            CGAffineTransformScale(move, _zoomScale, _zoomScale)];
    }

    [CATransaction commit];
}

/** Снимает увеличение целиком — при выходе, смене ролика, новом слое. */
- (void)resetZoom {
    _zoomScale = 1.0f;
    _zoomShift = CGPointZero;

    [self applyZoom];
}

/**
 * Сдвиг, при котором под кадром не остаётся пустоты.
 *
 * Увеличенный вдвое кадр торчит за края на половину лишнего размера
 * с каждой стороны — ровно настолько его и можно увести, не показав
 * из-под него черноту. Считается на каждом шаге жеста: вытолкнуть кадр
 * за экран нельзя вовсе, а не «можно, но потом вернётся».
 */
- (CGPoint)settledShift {
    if (_zoomScale <= 1.0f) {
        return CGPointZero;
    }

    CGSize box = [_videoHost bounds].size;

    CGFloat limitX = box.width * (_zoomScale - 1.0f) / 2.0f;
    CGFloat limitY = box.height * (_zoomScale - 1.0f) / 2.0f;

    return CGPointMake(MAX(-limitX, MIN(limitX, _zoomShift.x)),
                       MAX(-limitY, MIN(limitY, _zoomShift.y)));
}

/** По отпускании остаётся выровнять то, что мог изменить поворот экрана. */
- (void)settleZoom {
    CGPoint settled = [self settledShift];

    if (settled.x == _zoomShift.x && settled.y == _zoomShift.y) {
        return;
    }

    _zoomShift = settled;

    [UIView animateWithDuration:0.2 animations:^{ [self applyZoom]; }];
}

/**
 * Во сколько раз надо увеличить вписанный кадр, чтобы полосы исчезли.
 *
 * Это отношение сторон кадра к сторонам экрана — что у лежачего ролика
 * на высоком экране, что у стоячего на широком. Единица означает, что
 * полос нет вовсе и защёлкивать нечего.
 *
 * Размер берём у самой дорожки. Он же врёт числами на iPad 2 — панель
 * статистики об этом помнит, — но врёт пропорционально: 853×480 вместо
 * 1280×720 это всё те же шестнадцать к девяти, а больше нам ничего
 * и не нужно.
 */
- (CGFloat)fillRatio {
    CGSize frame = CGSizeZero;

    for (AVPlayerItemTrack *piece in [[_player currentItem] tracks]) {
        AVAssetTrack *track = [piece assetTrack];

        if ([[track mediaType] isEqualToString:AVMediaTypeVideo]) {
            frame = [track naturalSize];

            break;
        }
    }

    CGSize box = [_videoHost bounds].size;

    if (frame.width <= 0 || frame.height <= 0 || box.width <= 0 || box.height <= 0) {
        return 1.0f;
    }

    CGFloat video = frame.width / frame.height;
    CGFloat screen = box.width / box.height;

    return MAX(video / screen, screen / video);
}

/**
 * Пора ли защёлкивать подгон.
 *
 * Порог — восемь сотых: разница, которую глаз уже не отличает от точного
 * совпадения, но которой хватает, чтобы не сработать случайно по дороге
 * к настоящему увеличению. Полосы шириной меньше сотой доли экрана
 * не в счёт — там защёлкивать нечего.
 */
- (BOOL)shouldSnapToFill:(CGFloat)scale {
    if (_fillsScreen) {
        return NO;
    }

    CGFloat ratio = [self fillRatio];

    return (ratio > 1.01f && ABS(scale - ratio) < 0.08f);
}

/**
 * Как кадр укладывается в отведённое место.
 *
 * Спрашивается всякий раз, когда слой заводится заново, — а заводится он
 * не только при пуске: ещё при возврате из фона (там слой пустеет) и при
 * приёме плеера из мини-окна. Держать выбор человека в одном месте
 * дешевле, чем помнить про все три.
 */
- (NSString *)videoGravity {
    return _fillsScreen
        ? AVLayerVideoGravityResizeAspectFill
        : AVLayerVideoGravityResizeAspect;
}

- (void)toggleFillsScreen {
    [self hideMenu];
    [self resetZoom];
    [self setFillsScreen:!_fillsScreen];
}

- (void)setFillsScreen:(BOOL)fills {
    if (_fillsScreen == fills) {
        return;
    }

    _fillsScreen = fills;

    [_playerLayer setVideoGravity:[self videoGravity]];

    NSLog(@"[YouTube/Плеер] Кадр %@", fills
        ? @"растянут по экрану — поля убраны, края обрезаны"
        : @"вписан целиком — поля вернулись");
}

- (void)edgeBack:(UIPanGestureRecognizer *)gesture {
    if ([gesture state] != UIGestureRecognizerStateEnded) {
        return;
    }

    CGPoint move = [gesture translationInView:[self view]];

    // Половина ширины пальцем не проводится случайно, а шестидесяти точек
    // хватает, чтобы отличить намерение от дрожи.
    if (move.x < 60) {
        return;
    }

    [self teardownPlayer];
    [[YTHlsProxy shared] close];

    [YTNav pop];
}

/** Подпись-кнопка в ряду действий: значок, текст, общая подложка. */
- (UIImageView *)actionIcon:(NSString *)name into:(UIView *)parent {
    UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectZero];

    [icon setImage:YTIcon(name)];
    [icon setContentMode:UIViewContentModeScaleAspectFit];
    [icon setUserInteractionEnabled:NO];

    [parent addSubview:icon];

    return icon;
}

- (void)buildDetails {
    // `FontSize="18" FontWeight="Bold"`, перенос по словам.
    _title = YTLabel(YTFontBold(18), [YTTheme primaryText], 0);
    [_title setText:_titleText];
    [_page addSubview:_title];

    /**
     * Название — кнопка, открывающая описание.
     *
     * В оригинале весь этот блок и есть кнопка (`VideoInfoButton`),
     * а по нажатию выводится панель с описанием — `ShowDescriptionBottomSheet`.
     * Накладка кладётся поверх названия и повторяет его место при каждой
     * раскладке: сам `UILabel` нажатий не принимает.
     */
    _titleTouch = [[YTTappableView alloc] initWithFrame:CGRectZero];
    [_titleTouch setHighlights:NO];

    {
        __weak YTPlayerViewController *weakSelf = self;

        [_titleTouch setOnTap:^{ [weakSelf openDescription]; }];
    }

    [_page addSubview:_titleTouch];

    // Кружок канала — `Width="40" Height="40"`.
    _channelAvatar = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];
    [_channelAvatar setCircular:YES];
    [_channelAvatar setPlaceholderColor:[YTTheme avatarPlaceholder]];
    [_page addSubview:_channelAvatar];

    _channelName = YTLabel(YTFontMedium(15), [YTTheme primaryText], 1);
    [_page addSubview:_channelName];

    _channelSubs = YTLabel(YTFontRegular(12), [YTTheme secondaryText], 1);
    [_page addSubview:_channelSubs];

    // `CornerRadius="18"`, заливка PrimaryActionBackground.
    _subscribeFill = [[YTPillView alloc] initWithFrame:CGRectZero];
    [_subscribeFill setCornerRadius:18];
    [_subscribeFill setFillColor:[YTTheme primaryActionBackground]];
    [_page addSubview:_subscribeFill];

    _subscribeLabel = YTLabel(YTFontSemiBold(13), [YTTheme primaryActionForeground], 1);
    [_subscribeLabel setTextAlignment:NSTextAlignmentCenter];
    [_subscribeLabel setText:YTLoc(@"Подписаться")];
    [_page addSubview:_subscribeLabel];

    /**
     * Колокольчик и стрелка внутри кнопки — `SubscribeSubscribedIconsPanel`:
     * значок 22 и стрелка 16 с отступом 6. Показываются только подписанному.
     */
    _bellIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_bellIcon setContentMode:UIViewContentModeScaleAspectFit];
    [_bellIcon setUserInteractionEnabled:NO];
    [_bellIcon setHidden:YES];
    [_page addSubview:_bellIcon];

    _bellChevron = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_bellChevron setImage:YTIcon(@"down_arrow")];
    [_bellChevron setContentMode:UIViewContentModeScaleAspectFit];
    [_bellChevron setUserInteractionEnabled:NO];
    [_bellChevron setHidden:YES];
    [_page addSubview:_bellChevron];

    /**
     * Кружок с именем автора открывает канал.
     *
     * Накладка кладётся до кнопки подписки и заканчивается там, где
     * та начинается: иначе она перекрыла бы кнопку и подписаться стало
     * бы нечем.
     */
    _channelTouch = [[YTTappableView alloc] initWithFrame:CGRectZero];
    [_channelTouch setHighlights:NO];

    {
        __weak YTPlayerViewController *weakSelf = self;

        [_channelTouch setOnTap:^{ [weakSelf openChannel]; }];
    }

    [_page addSubview:_channelTouch];

    _subscribeTouch = [[YTTappableView alloc] initWithFrame:CGRectZero];
    [_subscribeTouch setHighlights:NO];

    {
        __weak YTPlayerViewController *weakSelf = self;

        [_subscribeTouch setOnTap:^{ [weakSelf subscribeTapped]; }];
    }
    [_page addSubview:_subscribeTouch];

    /**
     * Ряд действий — в своей прокрутке, как в оригинале.
     *
     * `scrollsToTop` снимаем обязательно: когда таких прокруток на экране
     * больше одной, iOS не отдаёт нажатие по строке состояния ни одной
     * из них, и страница переставала бы уезжать наверх.
     */
    _actionScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [_actionScroll setShowsHorizontalScrollIndicator:NO];
    [_actionScroll setShowsVerticalScrollIndicator:NO];
    [_actionScroll setScrollsToTop:NO];
    [_actionScroll setAlwaysBounceVertical:NO];
    [_actionScroll setDirectionalLockEnabled:YES];
    [_actionScroll setBackgroundColor:[UIColor clearColor]];
    [_page addSubview:_actionScroll];

    // Оценка: одна подложка на две кнопки, между ними тонкая черта.
    _votePill = [[YTPillView alloc] initWithFrame:CGRectZero];
    [_votePill setCornerRadius:18];
    [_votePill setFillColor:[YTTheme surface]];
    [_actionScroll addSubview:_votePill];

    _likeIcon = [self actionIcon:@"pl_like" into:_actionScroll];

    _likeCount = YTLabel(YTFontRegular(14), [YTTheme primaryText], 1);
    [_actionScroll addSubview:_likeCount];

    // `Width="0.75" Height="18"`, `#F1F1F1` при непрозрачности 0.47.
    _voteSeparator = [[UIView alloc] initWithFrame:CGRectZero];
    [_voteSeparator setBackgroundColor:[YTColor(0xF1F1F1) colorWithAlphaComponent:0.47]];
    [_actionScroll addSubview:_voteSeparator];

    _dislikeIcon = [self actionIcon:@"pl_dislike" into:_actionScroll];

    _dislikeCount = YTLabel(YTFontRegular(14), [YTTheme primaryText], 1);
    [_actionScroll addSubview:_dislikeCount];

    {
        __weak YTPlayerViewController *weakSelf = self;

        _likeTouch = [[YTTappableView alloc] initWithFrame:CGRectZero];
        [_likeTouch setHighlights:NO];
        [_likeTouch setOnTap:^{ [weakSelf rateTapped:@"like"]; }];
        [_actionScroll addSubview:_likeTouch];

        _dislikeTouch = [[YTTappableView alloc] initWithFrame:CGRectZero];
        [_dislikeTouch setHighlights:NO];
        [_dislikeTouch setOnTap:^{ [weakSelf rateTapped:@"dislike"]; }];
        [_actionScroll addSubview:_dislikeTouch];

        _shareTouch = [[YTTappableView alloc] initWithFrame:CGRectZero];
        [_shareTouch setHighlights:NO];
        [_shareTouch setOnTap:^{ [weakSelf shareTapped]; }];
        [_actionScroll addSubview:_shareTouch];

        _saveTouch = [[YTTappableView alloc] initWithFrame:CGRectZero];
        [_saveTouch setHighlights:NO];
        [_saveTouch setOnTap:^{ [weakSelf saveTapped]; }];
        [_actionScroll addSubview:_saveTouch];

        _downloadTouch = [[YTTappableView alloc] initWithFrame:CGRectZero];
        [_downloadTouch setHighlights:NO];
        [_downloadTouch setOnTap:^{ [weakSelf downloadTapped]; }];
        [_actionScroll addSubview:_downloadTouch];
    }

    _sharePill = [[YTPillView alloc] initWithFrame:CGRectZero];
    [_sharePill setCornerRadius:18];
    [_sharePill setFillColor:[YTTheme surface]];
    [_actionScroll addSubview:_sharePill];

    // В оригинале у «Поделиться» значок `player/send.png`, а не share.png.
    _shareIcon = [self actionIcon:@"pl_send" into:_actionScroll];

    _shareLabel = YTLabel(YTFontRegular(14), [YTTheme primaryText], 1);
    [_shareLabel setText:YTLoc(@"Поделиться")];
    [_actionScroll addSubview:_shareLabel];

    // «Сохранить»: `Assets/save.png`, подпись 14 с отступом 6 — как у соседей.
    _savePill = [[YTPillView alloc] initWithFrame:CGRectZero];
    [_savePill setCornerRadius:18];
    [_savePill setFillColor:[YTTheme surface]];
    [_actionScroll addSubview:_savePill];

    _saveIcon = [self actionIcon:@"pl_save" into:_actionScroll];

    _saveLabel = YTLabel(YTFontRegular(14), [YTTheme primaryText], 1);
    [_saveLabel setText:YTLoc(@"Сохранить")];
    [_actionScroll addSubview:_saveLabel];

    [self applySaveButton];

    _downloadPill = [[YTPillView alloc] initWithFrame:CGRectZero];
    [_downloadPill setCornerRadius:18];
    [_downloadPill setFillColor:[YTTheme surface]];
    [_actionScroll addSubview:_downloadPill];

    _downloadIcon = [self actionIcon:@"pl_download" into:_actionScroll];

    _downloadLabel = YTLabel(YTFontRegular(14), [YTTheme primaryText], 1);
    [_actionScroll addSubview:_downloadLabel];

    // Загрузка идёт своим ходом и сообщает о себе оповещением: полоса
    // процентов на кнопке двигается сама, без опроса.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(downloadsChanged)
                                                 name:YTDownloadsChangedNotification
                                               object:nil];

    // Карточка комментария: `Padding="12"`, AppSurface, `CornerRadius="12"`.
    _commentsCard = [[YTPillView alloc] initWithFrame:CGRectZero];
    [_commentsCard setCornerRadius:12];
    [_commentsCard setFillColor:[YTTheme surface]];
    [_page addSubview:_commentsCard];

    _commentsTitle = YTLabel(YTFontBold(14), [YTTheme primaryText], 1);
    [_commentsTitle setText:YTLoc(@"Комментарии")];
    [_page addSubview:_commentsTitle];

    _commentAvatar = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];
    [_commentAvatar setCircular:YES];
    [_commentAvatar setPlaceholderColor:[YTTheme avatarPlaceholder]];
    [_page addSubview:_commentAvatar];

    _commentAuthor = YTLabel(YTFontMedium(12), [YTTheme secondaryText], 1);
    [_page addSubview:_commentAuthor];

    _commentTime = YTLabel(YTFontRegular(12), [YTTheme mutedText], 1);
    [_commentTime setTextAlignment:NSTextAlignmentRight];
    [_page addSubview:_commentTime];

    // `MaxLines="2"`, перенос по словам.
    _commentText = YTLabel(YTFontRegular(13), [YTTheme primaryText], 2);
    [_page addSubview:_commentText];

    [_commentsCard setHidden:YES];

    // Заголовок над похожими: в оригинале его нет, список идёт сразу
    // за комментариями — поэтому подпись пустая и места не занимает.
    /**
     * Главы ролика — той же карточкой, что и очередь подборки.
     *
     * Свёрнутая показывает ту главу, что идёт сейчас; развёрнутая —
     * весь список, и нажатие по строке перематывает к её началу.
     * Стоит выше очереди: главы про этот ролик, а очередь — про соседние.
     */
    _chapterCard = [[YTPillView alloc] initWithFrame:CGRectZero];
    [_chapterCard setCornerRadius:12];
    [_chapterCard setHidden:YES];
    [_page addSubview:_chapterCard];

    _chapterHeader = [[YTTappableView alloc] initWithFrame:CGRectZero];
    [_chapterHeader setHighlights:NO];
    [_chapterHeader setHidden:YES];
    [_page addSubview:_chapterHeader];

    _chapterTitle = YTLabel(YTFontBold(14), [YTTheme primaryText], 1);
    [_chapterTitle setText:YTLoc(@"Главы")];
    [_chapterHeader addSubview:_chapterTitle];

    _chapterNow = YTLabel(YTFontRegular(12), [YTTheme secondaryText], 1);
    [_chapterHeader addSubview:_chapterNow];

    _chapterChevron = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_chapterChevron setContentMode:UIViewContentModeScaleAspectFit];
    [_chapterChevron setUserInteractionEnabled:NO];
    [_chapterHeader addSubview:_chapterChevron];

    __weak YTPlayerViewController *weakChapterSelf = self;

    [_chapterHeader setOnTap:^{
        [weakChapterSelf toggleChapters];
    }];

    _queueCard = [[YTPillView alloc] initWithFrame:CGRectZero];
    [_queueCard setCornerRadius:12];
    [_queueCard setHidden:YES];
    [_page addSubview:_queueCard];

    _queueHeader = [[YTTappableView alloc] initWithFrame:CGRectZero];
    [_queueHeader setHighlights:NO];
    [_queueHeader setHidden:YES];
    [_page addSubview:_queueHeader];

    _queueTitle = YTLabel(YTFontBold(14), [YTTheme primaryText], 1);
    [_queueHeader addSubview:_queueTitle];

    _queuePosition = YTLabel(YTFontRegular(12), [YTTheme secondaryText], 1);
    [_queueHeader addSubview:_queuePosition];

    _queueChevron = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_queueChevron setContentMode:UIViewContentModeScaleAspectFit];
    [_queueChevron setUserInteractionEnabled:NO];
    [_queueHeader addSubview:_queueChevron];

    __weak YTPlayerViewController *weakQueueSelf = self;

    [_queueHeader setOnTap:^{
        [weakQueueSelf toggleQueue];
    }];

    /**
     * Правая колонка планшета. Заводится сразу и стоит спрятанной:
     * поворот случается посреди просмотра, и собирать её в этот миг
     * значило бы моргнуть пустотой.
     */
    _side = [[UIScrollView alloc] initWithFrame:CGRectZero];

    [_side setBackgroundColor:[YTTheme background]];
    [_side setShowsVerticalScrollIndicator:NO];
    [_side setHidden:YES];
    [[self view] addSubview:_side];

    _columnDivider = [[UIView alloc] initWithFrame:CGRectZero];

    [_columnDivider setBackgroundColor:[YTTheme divider]];
    [_columnDivider setHidden:YES];
    [[self view] addSubview:_columnDivider];

    _relatedTitle = YTLabel(YTFontSemiBold(14), [YTTheme primaryText], 1);
    [_relatedTitle setText:YTLoc(@"Похожие видео")];
    [_page addSubview:_relatedTitle];

    /**
     * Кнопка проверки — вид кнопки «Повторить» из `OfflinePanel`:
     * голубая `#3EA6FF`, скругление 22, отступы 18×8.
     */
    _challenge = [UIButton buttonWithType:UIButtonTypeCustom];

    [[_challenge titleLabel] setFont:YTFontMedium(14)];
    [_challenge setTitle:YTLoc(@"Пройти проверку") forState:UIControlStateNormal];
    [_challenge setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [_challenge setBackgroundColor:[YTTheme accentBlue]];
    [[_challenge layer] setCornerRadius:22];
    [_challenge setHidden:YES];
    [_challenge addTarget:self
                   action:@selector(passChallenge)
         forControlEvents:UIControlEventTouchUpInside];

    /**
     * Сообщение о стене и кнопка лежат **поверх кадра**, а не в конце
     * страницы.
     *
     * Сначала они были там же, где обычная строка состояния, — то есть
     * ниже описания, комментариев и десятка похожих роликов. Формально
     * всё работало, а на деле кнопку никто не видел: до неё надо было
     * долистать. Место кадра при отказе всё равно пустует, и это первое,
     * что видно на экране.
     */
    [[self view] addSubview:_challenge];

    _gateLabel = YTLabel(YTFontRegular(14), [UIColor whiteColor], 0);
    [_gateLabel setTextAlignment:NSTextAlignmentCenter];
    [_gateLabel setHidden:YES];
    [[self view] addSubview:_gateLabel];

    _status = YTLabel(YTFontRegular(14), [YTTheme mutedText], 0);
    [_status setTextAlignment:NSTextAlignmentCenter];
    [_page addSubview:_status];

    __weak YTPlayerViewController *weakSelf = self;

    // Нажатие по карточке комментария открывает весь список — так же
    // в оригинале, где `CommentsContainerButton` ведёт на отдельный экран.
    YTTappableView *commentsTouch = [[YTTappableView alloc] initWithFrame:CGRectZero];

    [commentsTouch setHighlights:NO];
    [commentsTouch setOnTap:^{ [weakSelf openComments]; }];

    [_page addSubview:commentsTouch];

    _commentsTouch = commentsTouch;
}

/**
 * Комментарии открываются панелью поверх страницы, а не переходом
 * на отдельный экран.
 *
 * Разница не косметическая: уход с экрана снимает плеер и закрывает
 * прокси (`viewWillDisappear:`), то есть воспроизведение обрывается.
 * Панель ложится сверху, кадр остаётся на месте и продолжает играть —
 * так же в оригинале, где это `CommentsBottomSheetPanel`.
 */
#pragma mark Скачивание

/**
 * Нажатие на «Скачать».
 *
 * Три случая, и все три — здесь: скачанного предлагаем убрать, идущую
 * загрузку останавливаем, всё прочее заводим. Отдельного меню под это
 * не нужно: у кнопки одно очевидное действие на каждое состояние.
 */
- (void)downloadTapped {
    if ([_videoId length] == 0) {
        return;
    }

    /**
     * Меню открывается всегда, даже когда что-то уже скачано.
     *
     * Сперва скачанный ролик отвечал на нажатие одним вопросом —
     * «убрать?». Это отрезало главное: взять его же в другом качестве.
     * А качества у одного ролика вполне соседствуют, ради того ключ
     * записи и сделан составным. Убрать скачанное можно там же, в меню,
     * повторным выбором того же качества.
     */

    /**
     * Качество спрашиваем всегда, а не запоминаем.
     *
     * Выбор здесь не настройка, а решение про этот ролик: длинный
     * в 1080p — это гигабайт, короткий — десяток мегабайт, и уместное
     * качество у них разное. Меню же стоит одного нажатия.
     *
     * Панель та же, что у настроек плеера, а не `UIActionSheet`: у него
     * на новых системах свои причуды, а главное — рядом, в том же плеере,
     * качество для просмотра выбирают именно этой панелью, и меню
     * скачивания должно выглядеть так же.
     */
    /**
     * Меню строится по тому, что у ролика есть, а не по общему списку.
     *
     * Постоянный перечень от 144p до 1080p предлагал и то, чего нет:
     * человек выбирал 1080p, а загрузчик молча брал ближайшее 360p.
     * Спрашиваем сервер и показываем только настоящее — заодно и подмены
     * больше не случается.
     */
    /**
     * Спрашиваем один раз на ролик, а не на каждое нажатие.
     *
     * Ответ идёт через сеть, и до него ничего не появляется. Человек
     * нажимает ещё раз, и ещё — в журнале это выглядело как девять
     * запросов `/player` за две секунды. Набор качеств у ролика при
     * этом один и тот же, так что и спрашивать его довольно однажды.
     */
    if (_askingHeights) {
        return;
    }

    if (_knownHeights != nil) {
        [self showQualityMenu:_knownHeights];

        return;
    }

    _askingHeights = YES;

    __weak YTPlayerViewController *weakSelf = self;

    [YTDownloads askHeightsFor:_videoId done:^(NSArray *heights) {
        YTPlayerViewController *me = weakSelf;

        if (me == nil) {
            return;
        }

        me->_askingHeights = NO;
        me->_knownHeights = [heights copy];

        [me showQualityMenu:heights];
    }];
}

- (void)showQualityMenu:(NSArray *)heights {
    if ([heights count] == 0) {
        UIAlertView *alert = [[UIAlertView alloc]
            initWithTitle:YTLoc(@"Скачать не выйдет")
                  message:YTLoc(@"YouTube не дал ни одной дорожки, которую "
                                @"можно было бы забрать целиком.")
                 delegate:nil
        cancelButtonTitle:YTLoc(@"Понятно")
        otherButtonTitles:nil];

        [alert show];

        return;
    }

    NSMutableArray *rows = [NSMutableArray array];

    __weak YTPlayerViewController *weakSelf = self;

    for (NSNumber *number in heights) {
        NSInteger height = [number integerValue];

        YTDownloadItem *have = [YTDownloads itemFor:_videoId height:height];

        /**
         * Уже скачанное помечаем галочкой — и второй раз не качаем.
         *
         * Иначе человек, забывший, что уже брал этот ролик в 720p,
         * скачал бы его снова поверх готового.
         */
        NSString *title = [self downloadRowTitle:height];

        [rows addObject:[YTSheetRow choice:title
                                    picked:(have != nil && have.complete)
                                    action:^{
            [weakSelf startDownload:height];
        }]];
    }

    if (_downloadSheet == nil) {
        _downloadSheet = [[YTSettingsSheet alloc] initWithDark:NO];
    }

    _downloadRowHeights = [heights copy];

    /**
     * Кто уже был готов в миг сборки — чтобы потом заметить того,
     * кто дошёл при открытой панели: у него меняется не только подпись,
     * но и галочка, а её на месте не переставить.
     */
    _downloadRowsDone = [NSMutableSet set];

    for (NSNumber *number in heights) {
        YTDownloadItem *done = [YTDownloads itemFor:_videoId
                                             height:[number integerValue]];

        if (done != nil && done.complete) {
            [_downloadRowsDone addObject:number];
        }
    }

    [_downloadSheet setTitle:YTLoc(@"Качество для скачивания") rows:rows];
    [_downloadSheet openIn:[self view]];
}

/**
 * Подпись строки качества: само качество, а к нему — что с ним сейчас.
 *
 * Вынесена отдельно затем, что нужна дважды: при сборке панели и при
 * каждом её обновлении на ходу.
 */
- (NSString *)downloadRowTitle:(NSInteger)height {
    YTDownloadItem *have = [YTDownloads itemFor:_videoId height:height];

    NSString *title = [YTDownloads titleForHeight:height];

    if ([YTDownloads isBusy:_videoId height:height]) {
        /**
         * Идущую загрузку показываем процентами и предлагаем бросить.
         *
         * Прежде остановка висела на самой кнопке скачивания, и это
         * мешало главному: пока что-то качалось, нажатие означало
         * «останови», и завести второе качество было нельзя. Место
         * для остановки — здесь, у той строки, которой она касается.
         */
        return [title stringByAppendingFormat:@"  ·  %.0f%%  ·  %@",
                [have progress] * 100, YTLoc(@"остановить")];
    }

    if (have != nil && have.complete) {
        return [title stringByAppendingFormat:@"  ·  %@",
                [YTDownloads sizeText:have.gotBytes]];
    }

    if (have != nil) {
        return [title stringByAppendingFormat:@"  %.0f%%", [have progress] * 100];
    }

    return title;
}

/**
 * Проценты в открытой панели двигаются сами.
 *
 * Панель эту открывают как раз затем, чтобы посмотреть, как идёт
 * загрузка, — а она стояла с теми числами, что были в миг открытия,
 * и выглядела застрявшей.
 *
 * Подписи меняются на месте, панель не пересобирается: строки живут
 * дважды в секунду, и пересборка отнимала бы нажатие у пальца, лежащего
 * на строке. Исключение — когда загрузка кончилась: там меняется ещё
 * и галочка, а случается это один раз, и потерять нажатие не жаль.
 */
- (void)refreshDownloadSheet {
    if (![_downloadSheet isOpen] || [_downloadRowHeights count] == 0) {
        return;
    }

    BOOL settled = NO;

    for (NSUInteger i = 0; i < [_downloadRowHeights count]; i++) {
        NSInteger height = [[_downloadRowHeights objectAtIndex:i] integerValue];

        YTDownloadItem *have = [YTDownloads itemFor:_videoId height:height];

        BOOL complete = (have != nil && have.complete);

        if (complete && ![_downloadRowsDone containsObject:
                             [NSNumber numberWithInteger:height]]) {
            settled = YES;
        }

        [_downloadSheet retitleRowAt:i to:[self downloadRowTitle:height]];
    }

    if (settled) {
        [self showQualityMenu:_downloadRowHeights];
    }
}

- (void)startDownload:(NSInteger)height {
    [_downloadSheet close];

    // Выбрали то, что качается прямо сейчас, — значит просят бросить.
    if ([YTDownloads isBusy:_videoId height:height]) {
        [YTDownloads stop:_videoId height:height];

        [self updateDownloadButton];

        return;
    }

    YTDownloadItem *have = [YTDownloads itemFor:_videoId height:height];

    /**
     * Выбрали то, что уже скачано, — значит хотят это убрать.
     *
     * Другого смысла у такого нажатия нет: качать заново нечего.
     * Спрашиваем подтверждение — удаление файла необратимо.
     */
    if (have != nil && have.complete) {
        _removeHeight = height;

        _removeAlert = [[UIAlertView alloc]
            initWithTitle:YTLoc(@"Убрать скачанное?")
                  message:YTLoc(@"Файл ролика будет удалён с устройства.")
                 delegate:self
        cancelButtonTitle:YTLoc(@"Отмена")
        otherButtonTitles:YTLoc(@"Убрать"), nil];

        [_removeAlert show];

        return;
    }

    /**
     * «Спрашивать каждый раз» — значит спросить до первого байта.
     *
     * Дорожка вшивается в файл при склейке, и сменить её потом можно
     * только перекачав всё заново; поэтому вопрос идёт здесь, а не после.
     * Перечень дорожек стоит одного запроса, и лишь при этой настройке.
     */
    if ([YTSettings downloadAudioLanguage] == YTAudioLanguageAsk) {
        [self askTrackThenDownload:height];

        return;
    }

    [self beginDownload:height track:nil];
}

- (void)askTrackThenDownload:(NSInteger)height {
    __weak YTPlayerViewController *weakSelf = self;

    [YTDownloads askTracksFor:_videoId done:^(NSArray *tracks) {
        YTPlayerViewController *me = weakSelf;

        if (me == nil) {
            return;
        }

        // Дорожка одна — вопрос был бы издевательством.
        if ([tracks count] < 2) {
            [me beginDownload:height track:nil];

            return;
        }

        [me showTrackMenu:tracks height:height];
    }];
}

- (void)showTrackMenu:(NSArray *)tracks height:(NSInteger)height {
    NSMutableArray *rows = [NSMutableArray array];

    __weak YTPlayerViewController *weakSelf = self;

    for (NSDictionary *track in tracks) {
        NSString *identifier = [track objectForKey:@"id"];

        [rows addObject:[YTSheetRow choice:[track objectForKey:@"title"]
                                    picked:[[track objectForKey:@"default"] boolValue]
                                    action:^{
            YTPlayerViewController *me = weakSelf;

            [me->_downloadSheet close];
            [me beginDownload:height track:identifier];
        }]];
    }

    if (_downloadSheet == nil) {
        _downloadSheet = [[YTSettingsSheet alloc] initWithDark:NO];
    }

    _downloadRowHeights = nil;

    [_downloadSheet setTitle:YTLoc(@"Язык звука") rows:rows];
    [_downloadSheet openIn:[self view]];
}

- (void)beginDownload:(NSInteger)height track:(NSString *)trackId {
    [YTDownloads start:_videoId title:[_title text]
               details:_details item:nil height:height audioTrack:trackId];

    [self updateDownloadButton];
}

/**
 * Ответ окна «убрать скачанное».
 *
 * Получатель у `UIAlertView` один на класс, а окон здесь несколько:
 * поэтому сверяемся не с номером кнопки вслепую, а с тем, что окно —
 * именно наше.
 */
- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index {
    if (alert != _removeAlert) {
        return;
    }

    _removeAlert = nil;

    if (index == [alert cancelButtonIndex]) {
        return;
    }

    [YTDownloads remove:_videoId height:_removeHeight];

    [self updateDownloadButton];
}



- (void)downloadsChanged {
    [self updateDownloadButton];
    [self refreshDownloadSheet];
}

/**
 * Подпись кнопки по состоянию загрузки.
 *
 * Проценты берутся у самой записи, а не считаются здесь: она одна знает
 * и сколько скачано, и сколько обещано.
 */
- (void)updateDownloadButton {
    if (_downloadLabel == nil) {
        return;
    }

    NSArray *have = [YTDownloads itemsFor:_videoId];

    NSString *text = @"";
    BOOL downloaded = NO;

    /**
     * На кнопке — самое красноречивое из состояний.
     *
     * Качеств у ролика может быть скачано несколько; показывать все
     * на кнопке негде, да и незачем. Идёт загрузка — её проценты;
     * есть готовое — окрашенный значок и никакой подписи; есть только
     * брошенное — его доля.
     */
    for (YTDownloadItem *one in have) {
        if ([YTDownloads isBusy:_videoId height:one.height]) {
            text = [NSString stringWithFormat:@"%.0f%%", [one progress] * 100];
            downloaded = NO;

            break;
        }

        if (one.complete) {
            downloaded = YES;
            text = @"";
        } else if ([text length] == 0 && !downloaded) {
            text = [NSString stringWithFormat:@"%.0f%%", [one progress] * 100];
        }
    }

    /**
     * Скачанное помечается цветом, как нажатый лайк.
     *
     * У лайка для этого есть готовый значок `pl_like_on`; у стрелки
     * скачивания такого в наборе нет, поэтому красим сам значок.
     * Галочки при этом не нужно — цвет и есть ответ, а подпись только
     * растянула бы кнопку.
     */
    [_downloadIcon setImage:downloaded
        ? YTTintedImage(YTIcon(@"pl_download"), [YTTheme accentBlue])
        : YTIcon(@"pl_download")];

    if ([[_downloadLabel text] isEqualToString:text]) {
        return;
    }

    [_downloadLabel setText:text];

    [[self view] setNeedsLayout];
}

- (void)openComments {
    /**
     * У трансляции на этом месте чат, и открывается он же.
     *
     * Комментариев у эфира обычно нет вовсе, так что выбор простой:
     * есть метка чата — показываем разговор, нет — прежние комментарии.
     */
    if ([_chatToken length] > 0) {
        [self openLiveChatSheet];

        return;
    }

    if ([_commentsToken length] == 0) {
        return;
    }

    if (_commentsSheet == nil) {
        _commentsSheet = [[YTCommentsSheet alloc] initWithFrame:CGRectZero];
        [[self view] addSubview:_commentsSheet];
    }

    [[self view] bringSubviewToFront:_commentsSheet];
    [_commentsSheet setFrame:[[self view] bounds]];

    [_commentsSheet openWithToken:_commentsToken
                             page:_commentsPage
                            video:_videoId];
}

- (void)openLiveChatSheet {
    if (_commentsSheet == nil) {
        _commentsSheet = [[YTCommentsSheet alloc] initWithFrame:CGRectZero];
        [[self view] addSubview:_commentsSheet];
    }

    [[self view] bringSubviewToFront:_commentsSheet];
    [_commentsSheet setFrame:[[self view] bounds]];

    /**
     * Набранное отдаём панели: пока человек смотрел, карточка уже собрала
     * последние полсотни записей, и открывать разговор с пустого места
     * незачем.
     */
    [_commentsSheet openWithLiveChat:_chatToken
                               items:_chatItems
                               video:_videoId
                             viewers:_viewsText
                             filters:_chatFilters];
}

/**
 * Открывает проверку во встроенном браузере.
 *
 * Своей капчи у нас нет и быть не может: `/player` присылает только
 * состояние `LOGIN_REQUIRED`, а сама проверка живёт на странице Google
 * и решается в браузере. Пройденная проверка попадает в общее хранилище
 * cookie — то же, из которого их берут наши запросы, — и после «Готово»
 * страница пробует получить поток заново.
 */
- (void)passChallenge {
    NSString *videoId = _videoId;
    BOOL web = [YTWebAuth isSignedIn];

    __weak YTPlayerViewController *weakSelf = self;

    dispatch_block_t done = ^{
        YTPlayerViewController *player = weakSelf;

        if (player == nil) {
            return;
        }

        [player retryAfterChallenge];
    };

    YTChallengeViewController *screen = web
        ? [[YTChallengeViewController alloc] initWithVideoId:videoId done:done]
        : [[YTChallengeViewController alloc] initForLoginWithDone:done];

    [YTNav push:screen];
}

/**
 * Окно с просьбой сменить выход в сеть.
 *
 * `UIAlertView` — не устаревшая небрежность: `UIAlertController`
 * появился в iOS 8, а нам нужна пятая.
 */
#pragma mark Дизлайки и «Сохранить»

/**
 * Число дизлайков — отдельным запросом, после страницы.
 *
 * Ждать его перед показом незачем: оно стороннее и не главное, а сервис
 * бывает и медленным. Пришло — дописываем; ролик за это время сменился —
 * выбрасываем.
 */
- (void)loadDislikes {
    [_dislikeCount setText:nil];

    [[self view] setNeedsLayout];

    if (![YTSettings showsDislikes]) {
        return;
    }

    NSString *videoId = [_videoId copy];

    __weak YTPlayerViewController *weakSelf = self;

    YTAsync(^{
        NSNumber *count = [YTDislikes countFor:videoId];

        YTMain(^{
            YTPlayerViewController *screen = weakSelf;

            if (screen == nil || count == nil || ![videoId isEqualToString:screen->_videoId]) {
                return;
            }

            [screen->_dislikeCount setText:YTCompactCount([count longLongValue])];

            [[screen view] setNeedsLayout];
        });
    });
}

/** Кнопка «Сохранить»: видна ли и каким значком. */
- (void)applySaveButton {
    BOOL signedIn = [YTAuth isSignedIn];

    [_savePill setHidden:!signedIn];
    [_saveTouch setHidden:!signedIn];
    [_saveIcon setHidden:!signedIn];
    [_saveLabel setHidden:!signedIn];

    [_saveIcon setImage:YTIcon(_savedSomewhere ? @"pl_save_on" : @"pl_save")];

    /**
     * Спрашиваем, собран ли вид: зовут нас и при самой сборке страницы,
     * а `[self view]` из `loadView` заходит в него же снова.
     */
    if ([self isViewLoaded]) {
        [[self view] setNeedsLayout];
    }
}

/**
 * «Сохранить» — порт `SaveBottomSheetPanel` из оригинала.
 *
 * Лист открывается сразу, со строкой «Загрузка…», и наполняется, когда
 * придёт список: ждать сети до появления листа значило бы оставить
 * нажатие без ответа на секунду и больше.
 */
- (void)saveTapped {
    if (![YTAuth isSignedIn]) {
        [self showNotice:YTLoc(@"Войдите в аккаунт")];

        return;
    }

    if (_saveSheet == nil) {
        _saveSheet = [[YTSettingsSheet alloc] initWithDark:NO];
    }

    NSString *videoId = [_videoId copy];

    [_saveSheet setTitle:YTLoc(@"Выберите плейлист")
                    rows:[NSArray arrayWithObject:[YTSheetRow note:YTLoc(@"Загрузка…")]]];
    [_saveSheet openIn:[self view]];

    __weak YTPlayerViewController *weakSelf = self;

    YTAsync(^{
        NSArray *states = [YTApi playlistSaveStates:videoId];

        YTMain(^{
            [weakSelf fillSaveSheet:states forVideo:videoId];
        });
    });
}

- (void)fillSaveSheet:(NSArray *)states forVideo:(NSString *)videoId {
    // Лист закрыли или ролик сменился — список уже никому не нужен.
    if (![videoId isEqualToString:_videoId] || ![_saveSheet isOpen]) {
        return;
    }

    if (states == nil) {
        [_saveSheet setTitle:YTLoc(@"Выберите плейлист")
                        rows:[NSArray arrayWithObject:[YTSheetRow note:YTLoc(@"Не получилось")]]];

        return;
    }

    _saveStates = states;

    [self noteSavedIn:states];

    if ([states count] == 0) {
        [_saveSheet setTitle:YTLoc(@"Выберите плейлист")
                        rows:[NSArray arrayWithObject:[YTSheetRow note:YTLoc(@"Нет данных")]]];

        return;
    }

    __weak YTPlayerViewController *weakSelf = self;

    NSMutableArray *rows = [NSMutableArray array];

    for (NSMutableDictionary *state in states) {
        [rows addObject:[YTSheetRow choice:[state objectForKey:@"title"]
                                    picked:[[state objectForKey:@"contains"] boolValue]
                                    action:^{ [weakSelf toggleSave:state]; }]];
    }

    [_saveSheet setTitle:YTLoc(@"Выберите плейлист") rows:rows];
}

/**
 * Нажатие по плейлисту: кладёт ролик или убирает, лист закрывается,
 * итог — короткой надписью. Так же и в оригинале.
 */
- (void)toggleSave:(NSMutableDictionary *)state {
    [_saveSheet close];

    BOOL save = ![[state objectForKey:@"contains"] boolValue];

    NSString *videoId = [_videoId copy];
    NSString *playlistId = [state objectForKey:@"playlistId"];
    NSString *title = [state objectForKey:@"title"];

    __weak YTPlayerViewController *weakSelf = self;

    YTAsync(^{
        BOOL done = [YTApi setVideo:videoId saved:save inPlaylist:playlistId];

        YTMain(^{
            YTPlayerViewController *screen = weakSelf;

            if (screen == nil) {
                return;
            }

            if (!done) {
                [screen showNotice:YTLoc(@"Не получилось")];

                return;
            }

            [state setObject:[NSNumber numberWithBool:save] forKey:@"contains"];

            if ([videoId isEqualToString:screen->_videoId]) {
                [screen noteSavedIn:screen->_saveStates];
            }

            [screen showNotice:(save
                ? YTLocF(@"Видео добавлено в плейлист «%@»", title)
                : YTLocF(@"Видео удалено из плейлиста «%@»", title))];
        });
    });
}

/** Лежит ли ролик хоть в одном плейлисте — по этому красится значок. */
- (void)noteSavedIn:(NSArray *)states {
    BOOL any = NO;

    for (NSDictionary *state in states) {
        if ([[state objectForKey:@"contains"] boolValue]) {
            any = YES;

            break;
        }
    }

    _savedSomewhere = any;

    [self applySaveButton];
}

/**
 * Короткая надпись поверх страницы — на две секунды.
 *
 * Окно с кнопкой ради «ссылка скопирована» было бы слишком: человек
 * и так видит, что нажал, ему нужно лишь подтверждение.
 */
- (void)showNotice:(NSString *)text {
    if (_notice == nil) {
        _notice = YTLabel(YTFontRegular(14), [UIColor whiteColor], 1);

        [_notice setTextAlignment:NSTextAlignmentCenter];

        /**
         * До двух строк: «Видео добавлено в плейлист «Смотреть позже»»
         * в одну строку шириной с экран iPhone не влезает, и название
         * плейлиста — самое нужное в надписи — уходило в многоточие.
         */
        [_notice setNumberOfLines:2];
        [_notice setBackgroundColor:[UIColor colorWithWhite:0 alpha:0.8]];
        [[_notice layer] setCornerRadius:14];
        [_notice setClipsToBounds:YES];
        [_notice setAlpha:0];

        [[self view] addSubview:_notice];
    }

    [_notice setText:text];

    CGRect box = [[self view] bounds];
    CGFloat width = MIN(box.size.width - 48, (CGFloat)300);

    CGFloat textHeight = YTTextHeight(text, [_notice font], width - 16, 2);
    CGFloat height = MAX((CGFloat)28, ceil(textHeight) + 10);

    // Низ надписи там же, где был у однострочной: растёт она вверх.
    [_notice setFrame:CGRectMake((box.size.width - width) / 2,
                                 box.size.height - 92 - height, width, height)];

    [[self view] bringSubviewToFront:_notice];

    [UIView animateWithDuration:0.2 animations:^{ [_notice setAlpha:1]; }];

    [self performSelector:@selector(hideNotice) withObject:nil afterDelay:2.0];
}

- (void)hideNotice {
    [UIView animateWithDuration:0.3 animations:^{ [_notice setAlpha:0]; }];
}

- (void)showAddressWarning {
    UIAlertView *alert = [[UIAlertView alloc]
        initWithTitle:YTLoc(@"Раздача отказывает")
              message:YTLoc(@"YouTube привязывает ссылку на видео к адресу, "
                            @"с которого её выдали, а наш адрес меняется от "
                            @"запроса к запросу. Смените сервер VPN или "
                            @"отключите его — и попробуйте снова.")
             delegate:nil
    cancelButtonTitle:YTLoc(@"Понятно")
    otherButtonTitles:nil];

    [alert show];
}

- (void)retryAfterChallenge {
    [_challenge setHidden:YES];
    [_gateLabel setHidden:YES];
    [_status setText:nil];
    [_busy start];

    [[self view] setNeedsLayout];

    [self load];
}

#pragma mark Загрузка

/**
 * Ждём начала объявленной трансляции.
 *
 * Ожидание держится на одном повторяющемся таймере в пять секунд: он
 * переписывает надпись с оставшимся временем и, когда срок подошёл,
 * заново просит поток. Ни отдельной нити, ни ожидания в сети здесь нет —
 * приложение всё это время живёт обычной жизнью, и список, и описание
 * ролика остаются на месте.
 *
 * Пробовать начинаем не в назначенную секунду, а через полминуты после
 * неё: у YouTube трансляция поднимается не мгновенно, и ранние попытки
 * лишь тратят запросы. Дальше — раз в полминуты, пока не выйдет; отказы
 * при этом не накапливаются, каждая попытка независима.
 */
- (void)awaitBroadcastAt:(NSTimeInterval)scheduled generation:(NSInteger)generation {
    [self awaitBroadcastAt:scheduled said:nil generation:generation];
}

- (void)awaitBroadcastAt:(NSTimeInterval)scheduled
                    said:(NSString *)said
              generation:(NSInteger)generation {
    if (![_loadGeneration isCurrent:generation]) {
        return;
    }

    [_busy stop];

    _broadcastSaid = [said copy];
    _broadcastAt = scheduled;
    _broadcastTriedAt = 0;
    _broadcastResuming = NO;
    _broadcastEvery = 30;

    [self showBroadcastWait];

    [_broadcastWatch invalidate];

    _broadcastWatch = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                       target:self
                                                     selector:@selector(tickBroadcast)
                                                     userInfo:nil
                                                      repeats:YES];

    NSLog(@"[YouTube/Плеер] Трансляция %@ — ждём", scheduled > 0
        ? [NSString stringWithFormat:@"назначена на %@",
              [NSDate dateWithTimeIntervalSince1970:scheduled]]
        : @"ещё не началась, час начала в ответе не назван");
}

/**
 * Ждём, пока прерванный эфир возобновится.
 *
 * Тот же таймер, что и у назначенной трансляции, только срок — «уже»,
 * а попытки — раз в десять секунд: перерывы у YouTube длятся от
 * полуминуты до двух, и ждать полминуты между попытками — значит
 * терять до полуминуты эфира сверх самого перерыва.
 */
- (void)awaitLiveResumeWithGeneration:(NSInteger)generation {
    if (![_loadGeneration isCurrent:generation]) {
        return;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    _broadcastAt = now;
    _broadcastTriedAt = now;
    _broadcastResuming = YES;
    _broadcastEvery = 5;

    [_status setText:YTLoc(@"Трансляция прервалась — ждём…")];

    [_broadcastWatch invalidate];

    _broadcastWatch = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                       target:self
                                                     selector:@selector(tickBroadcast)
                                                     userInfo:nil
                                                      repeats:YES];

    NSLog(@"[YouTube/Плеер] Эфир без кусков — ждём возобновления, "
          @"пробуем каждые %.0f с", _broadcastEvery);
}

/** Надпись ожидания: сколько осталось либо «вот-вот начнётся». */
- (void)showBroadcastWait {
    if (_broadcastResuming) {
        [_status setText:YTLoc(@"Трансляция прервалась — ждём…")];

        return;
    }

    /**
     * Часа не знаем — говорим словами сервера, а не молчим.
     */
    if (_broadcastAt <= 0) {
        [_status setText:[_broadcastSaid length] > 0
            ? _broadcastSaid
            : YTLoc(@"Трансляция ещё не началась — ждём…")];

        return;
    }

    NSTimeInterval left = _broadcastAt - [[NSDate date] timeIntervalSince1970];

    if (left <= 0) {
        [_status setText:YTLoc(@"Ждём начала трансляции…")];

        return;
    }

    if (left < 60) {
        [_status setText:YTLoc(@"Трансляция вот-вот начнётся")];

        return;
    }

    if (left < 3600) {
        [_status setText:YTLocF(@"Трансляция начнётся через %ld мин",
                                (long)(left / 60))];

        return;
    }

    /**
     * Дальше часа — со днём, иначе одно время вводит в заблуждение.
     *
     * «Начнётся в 17:30» у трансляции, до которой двенадцать часов,
     * читается как «сегодня вечером», а она может быть и завтра. День
     * добавляем всегда, когда он не сегодняшний.
     */
    NSDate *when = [NSDate dateWithTimeIntervalSince1970:_broadcastAt];

    NSDateFormatter *clock = [[NSDateFormatter alloc] init];

    [clock setTimeStyle:NSDateFormatterShortStyle];

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSUInteger units = NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit;

    NSDateComponents *today = [calendar components:units fromDate:[NSDate date]];
    NSDateComponents *day = [calendar components:units fromDate:when];

    BOOL sameDay = ([today year] == [day year]
                    && [today month] == [day month]
                    && [today day] == [day day]);

    [clock setDateStyle:sameDay ? NSDateFormatterNoStyle : NSDateFormatterMediumStyle];

    [_status setText:YTLocF(@"Трансляция начнётся %@", [clock stringFromDate:when])];
}

- (void)tickBroadcast {
    [self showBroadcastWait];

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    /**
     * У назначенной трансляции первая попытка — через полминуты после
     * срока, дальше раз в полминуты; у прерванного эфира — сразу и
     * раз в десять секунд.
     */
    if (!_broadcastResuming && _broadcastAt > 0 && now < _broadcastAt + 30) {
        return;
    }

    if (_broadcastTriedAt > 0 && now - _broadcastTriedAt < _broadcastEvery) {
        return;
    }

    _broadcastTriedAt = now;

    NSLog(@"[YouTube/Плеер] Пробуем взять трансляцию заново");

    // Ждём возобновления прерванного эфира — страница остаётся, меняется поток.
    _reloadStreamOnly = _broadcastResuming;

    [self load];
}

/**
 * План Б для эфира: стоит дольше положенного — перезапускаем поток.
 *
 * Первая линия обороны живёт в подаче: застрявшую сессию она заводит
 * заново сама, через шесть секунд тишины, и плеер этого не замечает.
 * Сюда доходит то, что не вылечилось и так: пятнадцать секунд без
 * единого куска при стоящем плеере — значит, застряло глубже, и дешевле
 * пересобрать всё, чем гадать. Не чаще раза в полминуты: сам перезапуск
 * стоит три-четыре секунды.
 *
 * Заодно говорим человеку, что происходит: через три секунды остановки
 * вместо голого кружка — «Трансляция прервалась — ждём…».
 */
- (void)rescueLiveStall {
    YTHlsProxy *proxy = [YTHlsProxy shared];

    if (![proxy isLive]) {
        return;
    }

    if (_stalledFor >= 3.0 && !_liveStallNoted) {
        _liveStallNoted = YES;

        [_status setText:YTLoc(@"Трансляция прервалась — ждём…")];
    }

    [self restartLiveIfStarved];
}

/**
 * Жёсткий перезапуск — по голоду подачи, не дожидаясь остановки плеера.
 *
 * Прежде перезапуск ждал, пока плеер встанет и простоит пять секунд;
 * а у плеера полминуты запаса, и перезапуск приходил на сорок четвёртой
 * секунде после того, как подача замолчала, — когда спасать было уже
 * нечего. Теперь мерило — сама подача: двенадцать секунд без единого
 * куска (два мягких перезапуска сессии позади, оба впустую) — и поток
 * пересобирается, пока у плеера ещё есть что играть. Получается
 * без остановки картинки.
 *
 * Зовётся и из присмотра за остановкой, и из обычного такта — иначе
 * голод подачи при полном запасе плеера никто бы не заметил вовремя.
 */
- (void)restartLiveIfStarved {
    YTHlsProxy *proxy = [YTHlsProxy shared];

    if (![proxy isLive] || _broadcastResuming) {
        return;
    }

    NSTimeInterval starved = [proxy liveStarvedSeconds];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    /**
     * Жёсткий перезапуск — последнее средство, и ждёт своей очереди.
     *
     * Сперва сторож в прокси заводит сессию заново (восемь секунд без
     * куска, повтор каждые пятнадцать): это дешёво и в журналах 41 и 42
     * оживляло показ сразу. Полный перезапуск тянет заново `/player`,
     * теряет набранное и сбивает страницу, поэтому вступает лишь когда
     * сторож не справился дважды. Запаса на девяносто секунд хватает,
     * чтобы это ожидание человек не увидел.
     */
    /**
     * Жёсткий перезапуск рвёт показ — и человек это видит.
     *
     * Он пересобирает плеер: картинка дёргается, последний кусок перед
     * разрывом играет заново. В журнале 45 он сработал дважды за три
     * минуты — ровно тогда, когда запас только начал убывать, а показу
     * оставалось ещё секунд сорок. Лечить подачу он при этом не лечит:
     * пересадка сессии делает то же самое, но показа не касается вовсе.
     *
     * Потому порог — две минуты. За это время сторож успеет пересадить
     * сессию восемь раз; если и тогда куски не идут, показ всё равно уже
     * встал, и терять нечего. А обычную просадку человек теперь не
     * почувствует: её закрывает запас, и подача меняется под ним
     * незаметно.
     */
    if (starved >= 120.0 && now - _liveHardRestartAt > 60.0) {
        _liveHardRestartAt = now;

        NSLog(@"[YouTube/Плеер] Подача эфира молчит %.0f с — перезапускаем поток",
              starved);

        _reloadStreamOnly = YES;

        [self load];
    }
}

/**
 * Не кончилась ли трансляция, пока плеер стоит.
 *
 * Сервер о конце эфира не говорит ничего — просто перестаёт отдавать
 * куски, а плеер ждёт у края, как будто они ещё придут. Снаружи это
 * вечная подгрузка, а иногда и звук с последнего куска по второму
 * разу. Единственный, кто знает правду, — `/player`: у завершённой
 * трансляции `isLive` гаснет.
 *
 * Спрашиваем не сразу, а когда подача молчит дольше двадцати секунд,
 * и не чаще раза в полминуты: обычные паузы сервера короче, а лишний
 * поход в `/player` стоит секунды и трафика.
 */
- (void)checkBroadcastOver {
    YTHlsProxy *proxy = [YTHlsProxy shared];

    if (![proxy isLive] || [proxy liveStarvedSeconds] < 20.0 || _broadcastChecking) {
        return;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    if (now - _broadcastCheckedAt < 30.0) {
        return;
    }

    _broadcastCheckedAt = now;
    _broadcastChecking = YES;

    NSString *videoId = _videoId;
    NSInteger generation = [_loadGeneration current];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *player = [YTApi playerResponse:videoId];
        NSDictionary *about = [YTJson objectIn:player key:@"videoDetails"];

        BOOL alive = (player == nil)
            || [YTJson boolIn:about key:@"isLive"]
            || [YTJson boolIn:about key:@"isLiveNow"];

        YTMain(^{
            _broadcastChecking = NO;

            if (alive || ![_loadGeneration isCurrent:generation]) {
                return;
            }

            NSLog(@"[YouTube/Плеер] Трансляция завершена — доигрываем набранное");

            [[YTHlsProxy shared] endLive];

            [_busy stop];
            [_status setText:YTLoc(@"Трансляция завершена")];
        });
    });
}

/** Ожидание прежнего ролика не переживает смены. */
- (void)stopBroadcastWait {
    [_broadcastWatch invalidate];

    _broadcastWatch = nil;
    _broadcastAt = 0;
    _broadcastTriedAt = 0;
    _broadcastResuming = NO;
}

- (void)load {
    /**
     * Решатель `n` — поднимать сразу, не дожидаясь ответа `/player`.
     *
     * После выгрузки по нехватке памяти он поднимается заново, и на iPad 1
     * это десять секунд с лишним. Начав сейчас, выигрываем время, которое
     * уходит на `next` и `/player`. Уже поднят — ничего не делает.
     */
    [[YTNSig shared] prepare];

    // Таймер ожидания — в сторону; признаки остаются: попытка идёт через нас же.
    [_broadcastWatch invalidate];
    _broadcastWatch = nil;

    /**
     * Перезапуск потока — только поток.
     *
     * Полный `load` заново тянет описание, комментарии и похожие —
     * и список похожих на глазах у человека перетасовывается при каждом
     * перезапуске эфира. Ему это ни к чему: ролик тот же, страница та же,
     * пересобрать надо одну подачу. Признак ставят те, кто перезапускает
     * поток посреди показа; обычное открытие идёт по-старому.
     */
    BOOL streamOnly = _reloadStreamOnly;

    _reloadStreamOnly = NO;

    // Плеер принят у мини-окна — грузим только описание страницы.
    BOOL playerReady = _playingAdopted;

    NSString *videoId = _videoId;
    NSString *playlist = _playlistId;

    NSInteger generation = [_loadGeneration next];

    if (!streamOnly) {
        // Прежний ролик своих вставок, субтитров и кадров дальше не тащит.
        _sponsorSegments = nil;
        _sponsorMarksLogged = NO;
        _subtitleTracks = nil;
        _subtitleTrack = nil;
        _subtitleCues = nil;
        _storyboard = nil;
        _chapters = nil;

        // Список глав прежнего ролика убираем сразу, не дожидаясь нового описания.
        [self applyChapters];
        _lastSkippedTo = -1;

        [_sheets removeAllObjects];
        [_subtitleLabel setHidden:YES];
    }

    /**
     * Разметка вставок — сторонняя служба, и ходить к ней отдельно.
     *
     * Своей очередью, а не в общем ряду: ответ YouTube от неё не зависит,
     * и ждать её перед показом страницы было бы незачем. Не ответит —
     * просто не будет пропусков.
     */
    if (!streamOnly) YTAsync(^{
        NSArray *segments = [YTSponsorBlock segmentsFor:videoId];

        YTMain(^{
            if (![_loadGeneration isCurrent:generation]) {
                NSLog(@"[YouTube/SponsorBlock] Вставки опоздали — ролик уже другой");

                return;
            }

            _sponsorSegments = segments;

            NSLog(@"[YouTube/SponsorBlock] Плееру передано вставок: %lu, "
                  @"длительность ролика %.0f с",
                  (unsigned long)[segments count], _duration);

            // Полоса перерисуется на ближайшем ходе часов, но ждать его
            // незачем: отметки уже можно поставить.
            [self layoutMarks];
        });
    });

    YTAsync(^{
        // Описание нужно раньше, поток — важнее; идут по очереди, но
        // страница показывается, не дожидаясь потока.
        if (!streamOnly) {
            NSDictionary *details = [YTApi videoDetails:videoId playlist:playlist];

            YTMain(^{
                /**
                 * Сверяем ролик, а не поколение загрузки: перезапуск одного
                 * потока (эфир, смена качества) тоже начинает новое
                 * поколение, а сведения при этом всё те же и нужны.
                 */
                if (![_videoId isEqualToString:videoId]) {
                    return;
                }

                if (details != nil) {
                    [self applyDetails:details];
                } else {
                    [self retryDetails:videoId playlist:playlist attempt:1];
                }
            });
        }

        NSDictionary *player = [YTApi playerResponse:videoId];

        // Адреса сигналов просмотра — из этого ответа, что бы ни было дальше.
        NSDictionary *tracking = player;

        YTMain(^{
            if ([_loadGeneration isCurrent:generation] &&
                [YTJson objectIn:tracking key:@"playbackTracking"] != nil) {
                _trackingJson = tracking;
            }
        });

        /**
         * Субтитры и раскадровка — из того же ответа `/player`, который
         * и так нужен ради потока: своих запросов они не требуют.
         */
        NSArray *tracks = [YTSubtitles tracksIn:player];
        YTStoryboard *board = [YTStoryboard parse:[YTStoryboard specIn:player]];

        YTMain(^{
            if (![_loadGeneration isCurrent:generation]) {
                return;
            }

            _subtitleTracks = tracks;
            _storyboard = board;
        });

        /**
         * Плеер принят из мини-окна — за потоком идти незачем.
         *
         * Он играет из подачи, поднятой ещё на прошлой странице; открыв
         * её заново, мы оборвали бы ровно то, что человек просил вернуть.
         * Ответ `/player` всё же берём: из него наполняется меню качества
         * и адреса служебных сигналов.
         */
        if (playerReady) {
            NSArray *ready = [YTStreams formatsFrom:player];

            _playerJson = player;
            _formats = ([ready count] > 0 ? ready : nil);
            _heights = ([ready count] > 0
                        ? [YTStreams heightsIn:ready]
                        : [YTStreams sabrHeights]);

            return;
        }

        NSArray *formats = [YTStreams formatsFrom:player];

        /**
         * Прямой эфир — узнаём заранее, а решаем позже.
         *
         * Порядок путей для эфира тот же, что и для обычного ролика:
         * сперва подача, и только если она не задалась — готовый
         * плейлист из того же ответа. Спрашивать ради него другого
         * клиента незачем.
         */
        NSDictionary *about = [YTJson objectIn:player key:@"videoDetails"];

        BOOL live = [YTJson boolIn:about key:@"isLive"] ||
                    [YTJson boolIn:about key:@"isLiveNow"];

        /**
         * Подача просится настройкой — а не только отсутствием адресов.
         *
         * Прежде путь выбирался по одному признаку: есть готовые адреса —
         * играем ими, нет — идём подачей. Настройка при этом решала лишь,
         * у какого клиента спрашивать ответ, и то не всегда: подачу
         * у TV-клиента мы просим только у вошедшего. Выходило, что
         * у не вошедшего в настройках стоит «Подача SABR», а играет он
         * готовыми адресами от клиента шлема — и получает всё, чем те
         * плохи: отказ 403 на дальнем куске сразу после перемотки.
         *
         * Теперь просьба исполняется, когда её есть чем исполнить:
         * `serverAbrStreamingUrl` приходит и в ответе для не вошедшего.
         * Не задастся — ниже тот же запасной ход, что и был.
         */
        BOOL wantsSabr = ([YTSettings delivery] == YTDeliverySabr);

        BOOL sabrOffered = [YTJson textIn:[YTJson objectIn:player key:@"streamingData"]
                                      key:@"serverAbrStreamingUrl"] != nil;

        if ([formats count] > 0 && wantsSabr && sabrOffered) {
            NSLog(@"[YouTube/Плеер] Готовых адресов %lu, но настройка просит подачу",
                  (unsigned long)[formats count]);
        }

        if ([formats count] == 0 || (wantsSabr && sabrOffered)) {
            /**
             * Дорожек нет, но бывает готовый HLS от IOS-клиента — ради него
             * в оригинале и шлётся iOS-овский User-Agent. Разбирать нечего:
             * это обычный плейлист, AVPlayer играет его сам, качество
             * выбирает тоже он. Меню качества в этом случае пустое —
             * выбирать не из чего.
             */
            /**
             * Раздельных дорожек нет — берём склеенный поток.
             *
             * Так отвечает WEB-клиент: `adaptiveFormats` приходят без
             * адресов (подача через SABR), а единственный настоящий адрес
             * лежит в `formats` — обычно 360p со звуком внутри. Качество
             * ниже, чем у демуксера, зато играет там, где иначе не играет
             * ничего: перекладывать нечего, кадры уже в одном контейнере.
             */
            /**
             * Обычных адресов нет — значит, подача SABR. Она даёт те же
             * фрагменты, что демуксер брал бы из сети, так что прокси
             * работает как обычно, только источник другой.
             */
            // Ушли с экрана, пока ходили в сеть, — подачу не поднимаем.
            if (![_loadGeneration isCurrent:generation]) {
                return;
            }

            YTSabr *sabr = [YTStreams sabrFor:player
                                     maxHeight:_maxHeight
                                    audioTrack:_audioTrack
                                         exact:(_pickedHeight > 0)];

            /**
             * Ещё раз перед прокси: `sabrFor:` ходит в сеть и стоит секунд,
             * а прокси у приложения один. Открыв его опоздавшей загрузкой,
             * мы отберём подачу у той страницы, которая играет сейчас.
             */
            if (![_loadGeneration isCurrent:generation]) {
                return;
            }

            if (sabr != nil) {
                NSString *local = [[YTHlsProxy shared] openWithSabr:sabr];

                if ([local length] > 0) {
                    NSLog(@"[YouTube/Плеер] Играем через подачу SABR");

            YTMain(^{ _broadcastResuming = NO; });

                    /**
                     * Меню качества на этом пути наполняется из описаний
                     * дорожек: разбирать нечего, адресов нет, а ступени
                     * известны. `_formats` при этом пуст — по нему и видно,
                     * каким путём мы играем.
                     */
                    _playerJson = player;
                    _formats = nil;
                    _heights = [YTStreams sabrHeights];

                    // Плеер принят из мини-окна — запускать его заново нечего.
                    if (!playerReady) {
                        YTMain(^{ [self startPlayer:local generation:generation]; });
                    }

                    return;
                }
            }

            /**
             * Подача не задалась — переходим ко второму пути.
             *
             * Отказ на этом шаге почти всегда об адресе: ответ `/player`
             * пришёл, дорожки перечислены, а куски раздача не отдала.
             * Готовые адреса от ANDROID_VR к этому не так чувствительны,
             * и там, где подача встала, ролик нередко играет.
             *
             * Ходим за ними только если сюда пришли подачей: когда
             * ANDROID_VR выбран в настройках, ответ уже его, и второго
             * такого же захода не нужно.
             */
            /**
             * За готовыми адресами ходим только тогда, когда их у нас нет.
             * Если подачу мы выбрали при живых адресах — они уже разобраны,
             * и второй запрос был бы впустую.
             */
            if (wantsSabr && [formats count] == 0) {
                NSLog(@"[YouTube/Плеер] Подача не задалась — берём готовые адреса");

                /**
                 * Заодно забываем сборку плеера. Одна из причин, по
                 * которым подача встаёт, — что YouTube выкатил новую сборку,
                 * пока приложение было открыто, и метка подписи с расшифровкой
                 * `n` у нас от прежней. Следующая попытка перечитает и то, и другое.
                 */
                [YTPlayerJs forgetPlayerId];

                NSDictionary *plain = [YTApi androidVrPlayerResponse:videoId];
                NSArray *plainFormats = [YTStreams formatsFrom:plain];

                if ([plainFormats count] > 0) {
                    player = plain;
                    formats = plainFormats;
                }
            } else if (wantsSabr) {
                NSLog(@"[YouTube/Плеер] Подача не задалась — играем готовыми "
                      @"адресами, они уже есть");
            }
        }

        /**
         * Эфир, которого подача не осилила, — готовым плейлистом.
         *
         * У прямого эфира нет ни карты фрагментов, ни объявленных длин:
         * `initRange` и `indexRange` в дорожках отсутствуют, а подача
         * присылает вместо фрагментов один `ftyp+moov` с номером ноль.
         * В журнале это «всего фрагментов 0, 0 с», а следом «Заголовок
         * видеодорожки не разобран»: демуксеру собирать нечего.
         *
         * Зато в том же ответе лежит обычный HLS, который AVPlayer играет
         * сам и умеет с первой версии. Берём его оттуда же, где взяли
         * ответ, — другого клиента ради этого не спрашиваем.
         */
        if (live) {
            NSString *manifest = [YTJson textIn:
                [YTJson objectIn:player key:@"streamingData"] key:@"hlsManifestUrl"];

            if ([manifest length] > 0) {
                NSLog(@"[YouTube/Плеер] Эфир: подача не задалась — играем "
                      @"готовым плейлистом");

                _playerJson = player;
                _formats = nil;
                _heights = nil;

                YTMain(^{ [self startPlayer:manifest generation:generation]; });

                return;
            }

            NSLog(@"[YouTube/Плеер] Эфир, а готового плейлиста в ответе нет");

            /**
             * Эфир без потоков — это перерыв, а не поломка.
             *
             * Трансляция на стороне YouTube прерывается — кодировщик
             * падает, куски не нарезаются минуту-полторы, — и подача
             * в это время честно отвечает пустотой, сколько сессий
             * ни заводи. Прежде мы шли по пути записи: «Подача не
             * задалась — играем готовыми адресами», а готовых адресов
             * у эфира нет, и показ умирал с «поток не собрался». Человек
             * открывал ролик заново — и через минуту всё шло.
             *
             * Теперь перерыв пережидаем сами: надпись, попытка каждые
             * десять секунд, пока `/player` говорит, что эфир живой.
             */
            YTMain(^{ [self awaitLiveResumeWithGeneration:generation]; });

            return;
        }

        if ([formats count] == 0) {
            NSString *progressive = [YTStreams progressiveUrlIn:player];

            if ([progressive length] > 0) {
                /**
                 * Даже готовый mp4 отдаём плееру через петлю. Сам он пошёл бы
                 * за ним своим стеком — с системным именем и без наших
                 * корней, — а раздача сверяет имя с клиентом, под которого
                 * подписана ссылка, и отвечает отказом 403.
                 */
                // Прокси один на всех — опоздавшему его не отдаём.
                if (![_loadGeneration isCurrent:generation]) {
                    return;
                }

                NSString *local = [[YTHlsProxy shared] relayUrl:progressive
                                                       duration:[YTStreams lengthIn:player]];

                if ([local length] > 0) {
                    NSLog(@"[YouTube/Плеер] Играем склеенный поток");

                    _formats = nil;
                    _heights = nil;

                    // Плеер принят из мини-окна — запускать его заново нечего.
                    if (!playerReady) {
                        YTMain(^{ [self startPlayer:local generation:generation]; });
                    }

                    return;
                }
            }

            NSString *manifest = [YTJson textIn:
                [YTJson objectIn:player key:@"streamingData"] key:@"hlsManifestUrl"];

            if ([manifest length] > 0) {
                NSLog(@"[YouTube/Плеер] Играем готовый HLS");

                _formats = nil;
                _heights = nil;

                YTMain(^{ [self startPlayer:manifest generation:generation]; });

                return;
            }

            /**
             * Трансляция ещё не началась — это не поломка, а ожидание.
             *
             * Объявленный заранее эфир отвечает без потоков: их пока нет.
             * Снаружи это выглядело как «Не удалось получить поток», и
             * человек, открывший презентацию за пятнадцать минут до
             * начала, видел отказ вместо часов ожидания.
             */
            NSTimeInterval scheduled = [YTApi scheduledStartIn:player];

            /**
             * Ждём по признаку, а не по найденному часу.
             *
             * Час начала лежит у разных клиентов в разных местах, и когда
             * его не нашлось, человек видел «Не удалось получить поток» —
             * будто приложение сломалось, хотя трансляция просто ещё
             * не началась. Признак же однозначен: `LIVE_STREAM_OFFLINE`.
             * Нет часа — покажем то, что сказал сам сервер, а нет и
             * этого — хотя бы честное «ещё не началась».
             */
            if (scheduled > 0 || [YTApi isUpcomingBroadcast:player]) {
                NSString *said = [YTApi offlineSlateTextIn:player];

                YTMain(^{
                    [self awaitBroadcastAt:scheduled
                                      said:said
                                generation:generation];
                });

                return;
            }

            if (_broadcastResuming) {
                NSLog(@"[YouTube/Плеер] Ждали возобновления эфира — он завершён");

                YTMain(^{
                    [self stopBroadcastWait];
                    [_busy stop];

                    [_status setText:YTLoc(@"Трансляция завершена")];
                });

                return;
            }

            BOOL gate = [YTApi isBotGate:player];

            YTMain(^{
                [_busy stop];

                [_status setText:gate ? nil : YTLoc(@"Не удалось получить поток")];

                /**
                 * Стену снимает не столько проверка, сколько вход в браузере.
                 *
                 * Вход по QR-коду здесь не помогает, и это важно сказать
                 * прямо: человек видит своё имя в «Вы», считает себя вошедшим
                 * и не понимает, чего от него хотят. А токен QR-кода удостоверяет
                 * учётную запись, а стена спрашивает другое — что запрос идёт
                 * от человека из браузера, а не из ниоткуда. Доказательство этому —
                 * куки веб-сессии, и берутся они только входом в браузере.
                 */
                BOOL web = [YTWebAuth isSignedIn];

                [_gateLabel setText:web
                    ? YTLoc(@"YouTube просит подтвердить, что вы не робот")
                    : YTLoc(@"YouTube упёрся в проверку. Входа по QR-коду ей мало — "
                            @"нужен ещё вход в браузере: кнопкой ниже либо в настройках "
                            @"приложения, строка «Вход в браузере»")];

                [_challenge setTitle:web ? YTLoc(@"Пройти проверку") : YTLoc(@"Войти в браузере")
                            forState:UIControlStateNormal];
                [_gateLabel setHidden:!gate];
                [_challenge setHidden:!gate];

                [[self view] setNeedsLayout];
            });

            return;
        }

        _formats = formats;
        _heights = [YTStreams heightsIn:formats];

        // Ответ нужен и после начала показа: из него берутся адреса
        // служебных сигналов, которыми ролик попадает в историю.
        _playerJson = player;

        YTFormat *video = [YTStreams chooseVideo:formats maxHeight:_maxHeight];
        /**
         * Выбранная озвучка передаётся и сюда.
         *
         * Прежде здесь стоял `nil`, то есть на готовых адресах всегда
         * бралась дорожка по умолчанию — выбор из меню просто некуда
         * было донести, и он ничего не менял.
         */
        YTFormat *audio = [YTStreams chooseAudio:formats
                                  preferredTrack:([_audioTrack length] > 0
            ? _audioTrack
            : [YTStreams trackIdForMode:[YTSettings playbackAudioLanguage]
                              inFormats:formats])];

        // Что взяли на самом деле — это и покажет меню качества.
        _readyHeight = [video qualityTier];

        if (video == nil) {
            NSLog(@"[YouTube/Плеер] Подходящей дорожки нет: потолок %ldp, "
                  @"дорожек %lu", (long)_maxHeight, (unsigned long)[formats count]);

            // Тот же запасной ход: склеенный поток вместо раздельных.
            NSString *progressive = [YTStreams progressiveUrlIn:player];

            if ([progressive length] > 0) {
                /**
                 * Даже готовый mp4 отдаём плееру через петлю. Сам он пошёл бы
                 * за ним своим стеком — с системным именем и без наших
                 * корней, — а раздача сверяет имя с клиентом, под которого
                 * подписана ссылка, и отвечает отказом 403.
                 */
                // Прокси один на всех — опоздавшему его не отдаём.
                if (![_loadGeneration isCurrent:generation]) {
                    return;
                }

                NSString *local = [[YTHlsProxy shared] relayUrl:progressive
                                                       duration:[YTStreams lengthIn:player]];

                if ([local length] > 0) {
                    NSLog(@"[YouTube/Плеер] Играем склеенный поток");

                    _formats = nil;
                    _heights = nil;

                    // Плеер принят из мини-окна — запускать его заново нечего.
                    if (!playerReady) {
                        YTMain(^{ [self startPlayer:local generation:generation]; });
                    }

                    return;
                }
            }

            YTMain(^{
                [_busy stop];
                [_status setText:YTLoc(@"Подходящей дорожки нет")];
            });

            return;
        }

        if (audio == nil) {
            NSLog(@"[YouTube/Плеер] Звуковой дорожки нет");
        }

        NSLog(@"[YouTube/Плеер] Выбрано: видео itag %ld (%ldp), звук itag %ld",
              (long)video.itag, (long)video.height, (long)audio.itag);

        // Прокси один на всех — опоздавшему его не отдаём.
        if (![_loadGeneration isCurrent:generation]) {
            return;
        }

        /**
         * Где брать ссылки заново, если раздача откажет.
         *
         * Готовые адреса отзываются раньше своего срока — заметнее всего
         * это при перемотке в дальнюю часть ролика: кусок оттуда получает
         * 403, сегмент не собирается, и плеер ждёт его молча и вечно.
         * Прокси в этот миг знает только адрес; спросить `/player` заново
         * может лишь тот, у кого есть номер ролика, — то есть мы.
         *
         * Дорожки ищем по тем же itag: другое качество посреди
         * воспроизведения означало бы иной `moov`, а он у плеера уже свой.
         */
        NSString *wanted = _videoId;
        NSInteger videoItag = video.itag;
        NSInteger audioItag = audio.itag;

        NSDictionary *(^refresher)(void) = ^NSDictionary *(void) {
            NSDictionary *player = [YTApi playerResponse:wanted];
            NSArray *formats = [YTStreams formatsFrom:player];

            NSMutableDictionary *fresh = [NSMutableDictionary dictionary];

            for (YTFormat *format in formats) {
                if ([format.url length] == 0) {
                    continue;
                }

                if (format.itag == videoItag) {
                    [fresh setObject:format.url forKey:@"video"];
                } else if (format.itag == audioItag) {
                    [fresh setObject:format.url forKey:@"audio"];
                }
            }

            NSLog(@"[YouTube/Плеер] Спросили ссылки заново для %@: нашлось %lu",
                  wanted, (unsigned long)[fresh count]);

            return fresh;
        };

        NSString *url = [[YTHlsProxy shared] openWithVideo:video audio:audio];

        // Только после открытия: оно начинается с `close`, а тот всё
        // прежнее, включая способ обновления, нарочно выбрасывает.
        [[YTHlsProxy shared] setUrlRefresher:refresher];

        YTMain(^{
            if (url == nil) {
                [_busy stop];
                [_status setText:YTLoc(@"Поток не собрался")];
                return;
            }

            [self startPlayer:url generation:generation];
        });
    });
}

/**
 * Показывает, что учётная запись уже сделала с роликом.
 *
 * Оба признака необязательны: `nil` значит «неизвестно», и тогда кнопка
 * остаётся в исходном виде. Это не то же, что «нет»: сказать «вы
 * не подписаны», не спросив, было бы враньём, а человек по этой кнопке
 * судит о том, подписан ли он вообще.
 */
/**
 * Подписаться или отписаться.
 *
 * Кнопка меняется сразу, не дожидаясь ответа: сеть тут медленная,
 * а отказ — редкость. Не вышло — возвращаем как было и говорим об этом
 * в журнал.
 */
/**
 * Оценка ролика.
 *
 * После отправки состояние **перечитывается** у сервера, а не берётся
 * из наших предположений: счётчик лайков меняется вместе с оценкой,
 * а посчитать его самим нельзя — сервер округляет («6,6 тыс.»),
 * и прибавить единицу к округлённому значит соврать.
 */
- (void)rateTapped:(NSString *)want {
    if ([_videoId length] == 0) {
        return;
    }

    if (![YTAuth isSignedIn]) {
        [self showNotice:YTLoc(@"Нужен вход в аккаунт")];

        return;
    }

    // Повторное нажатие снимает оценку — как и на самом YouTube.
    BOOL already = ([want isEqualToString:@"like"] && _liked) ||
                   ([want isEqualToString:@"dislike"] && _disliked);

    NSString *action = already ? @"none" : want;
    NSString *videoId = _videoId;

    // Примета для этого хода, если сервер её присылал.
    NSString *params = [_rateParams objectForKey:
        [action stringByAppendingString:@"Params"]];

    YTAsync(^{
        [YTApi rate:videoId as:action params:params];

        NSDictionary *state = [YTApi watchState:videoId];

        YTMain(^{
            if (![videoId isEqualToString:_videoId]) {
                return;
            }

            NSString *likes = [state objectForKey:@"likes"];

            if ([likes length] > 0) {
                [_likeCount setText:likes];
            }

            _disliked = [action isEqualToString:@"dislike"];

            [self applyLiked:[state objectForKey:@"liked"] subscribed:nil];
            [[self view] setNeedsLayout];
        });
    });
}

/**
 * «Поделиться».
 *
 * На iOS 6 и выше — системный лист: он умеет и почту, и сообщения,
 * и всё, что человек себе поставил. На пятой такого листа нет вовсе
 * (`UIActivityViewController` появился в шестой), поэтому там ссылка
 * кладётся в буфер обмена, о чём и сообщается надписью.
 */
- (void)shareTapped {
    if ([_videoId length] == 0) {
        return;
    }

    NSString *link = [@"https://youtu.be/" stringByAppendingString:_videoId];

    Class sheet = NSClassFromString(@"UIActivityViewController");

    if (sheet != nil) {
        NSArray *items = [NSArray arrayWithObjects:
            [[_title text] length] > 0 ? [_title text] : link, [NSURL URLWithString:link], nil];

        id controller = [[sheet alloc] initWithActivityItems:items
                                       applicationActivities:nil];

        [YTShare presentSheet:controller from:_shareTouch in:self];

        return;
    }

    [[UIPasteboard generalPasteboard] setString:link];

    [self showNotice:YTLoc(@"Ссылка скопирована")];
}

- (void)openChannel {
    if ([_channelId length] == 0) {
        return;
    }

    [self keepPlayingWhileLeaving];

    [YTNav openChannel:_channelId title:[_channelName text]];
}

/**
 * Отдаёт плеер мини-окну перед уходом на другой экран — **не** уходя
 * со страницы самому.
 *
 * Уйти со страницы ролика можно двумя способами, и они разные. Кнопка
 * сворачивания убирает страницу из стопки: человек сказал, что смотреть
 * больше не будет, но слушать хочет. А переход на канал — это шаг
 * в сторону, из которого возвращаются «назад»; страница должна остаться
 * под каналом и дождаться возврата.
 *
 * Плеер при этом всё равно переезжает в мини-окно: иначе `viewWillDisappear:`
 * снял бы его, и звук оборвался бы на полуслове. Пометка `_minimising`
 * как раз и говорит той разборке, что снимать нечего. По возвращении
 * `viewWillAppear:` заберёт плеер обратно — тем же ходом, каким страница
 * забирает его после нажатия по мини-окну.
 */
- (void)keepPlayingWhileLeaving {
    if (_player == nil || _minimising) {
        return;
    }

    _minimising = YES;

    [self detachPlayerObservers];

    [YTMiniPlayer showWithPlayer:_player
                           layer:_playerLayer
                         videoId:_videoId
                           title:[_title text]
                           owner:self];

    _player = nil;
    _playerLayer = nil;
}

/**
 * Нажатие по кнопке подписки.
 *
 * У подписанного она работает не переключателем, а колокольчиком: в
 * оригинале `SubscribeButton_Click` у подписанного открывает панель
 * с выбором оповещений, где отписка — одна из строк. Отписаться
 * случайным касанием там нельзя, и здесь так же.
 */
- (void)subscribeTapped {
    if ([_channelId length] == 0) {
        return;
    }

    if (_subscribed) {
        [self openBellMenu];
        return;
    }

    [self toggleSubscription];
}

/**
 * Панель колокольчика — те же четыре строки, что в
 * `SubscriptionMenuBottomSheetPanel`: все оповещения, по интересам,
 * никаких и отписаться.
 */
- (void)openBellMenu {
    if (_bell == nil) {
        _bell = [[YTSettingsSheet alloc] initWithDark:NO];
    }

    __weak YTPlayerViewController *weakSelf = self;

    NSMutableArray *rows = [NSMutableArray array];

    [rows addObject:[YTSheetRow choice:YTLoc(@"Все")
                                picked:(_notifications == YTNotificationsAll)
                                action:^{ [weakSelf pickNotifications:YTNotificationsAll]; }]];

    [rows addObject:[YTSheetRow choice:YTLoc(@"По интересам")
                                picked:(_notifications == YTNotificationsPersonalized ||
                                        _notifications == YTNotificationsUnknown)
                                action:^{ [weakSelf pickNotifications:YTNotificationsPersonalized]; }]];

    [rows addObject:[YTSheetRow choice:YTLoc(@"Нет")
                                picked:(_notifications == YTNotificationsNone)
                                action:^{ [weakSelf pickNotifications:YTNotificationsNone]; }]];

    [rows addObject:[YTSheetRow command:@"unsubscribe"
                                  title:YTLoc(@"Отменить подписку")
                                 action:^{ [weakSelf unsubscribeFromMenu]; }]];

    [_bell setTitle:YTLoc(@"Оповещения") rows:rows];
    [_bell openIn:[self view]];
}

- (void)pickNotifications:(NSInteger)state {
    [_bell close];

    if (state == _notifications || [_channelId length] == 0) {
        return;
    }

    NSInteger previous = _notifications;
    NSString *channel = _channelId;

    _notifications = state;

    [self applyBellIcon];

    YTAsync(^{
        BOOL done = [YTApi setNotifications:state channel:channel];

        if (done) {
            return;
        }

        // Сервер отказал — возвращаем значок к прежнему виду, не ври.
        YTMain(^{
            _notifications = previous;

            [self applyBellIcon];
            [self showNotice:YTLoc(@"Не удалось изменить оповещения")];
        });
    });
}

- (void)unsubscribeFromMenu {
    [_bell close];

    [self toggleSubscription];
}

/** Значок колокольчика под нынешнее предпочтение. */
- (void)applyBellIcon {
    NSString *icon = @"notifications";

    if (_notifications == YTNotificationsAll)  { icon = @"notifications_all"; }
    if (_notifications == YTNotificationsNone) { icon = @"notifications_none"; }

    [_bellIcon setImage:YTIcon(icon)];
}

- (void)toggleSubscription {
    if ([_channelId length] == 0) {
        return;
    }

    BOOL wanted = !_subscribed;
    NSString *channel = _channelId;

    _subscribed = wanted;

    [self applyLiked:nil subscribed:[NSNumber numberWithBool:wanted]];

    YTAsync(^{
        BOOL done = [YTApi setSubscribed:wanted channel:channel];

        if (done) {
            return;
        }

        YTMain(^{
            _subscribed = !wanted;

            [self applyLiked:nil subscribed:[NSNumber numberWithBool:!wanted]];
        });
    });
}

- (void)applyLiked:(NSNumber *)liked subscribed:(NSNumber *)subscribed {
    if (liked != nil) {
        _liked = [liked boolValue];

        [_likeIcon setImage:YTIcon(_liked ? @"pl_like_on" : @"pl_like")];
        [_dislikeIcon setImage:YTIcon(_disliked ? @"pl_dislike_on" : @"pl_dislike")];
    }

    if (subscribed == nil) {
        return;
    }

    BOOL on = [subscribed boolValue];

    _subscribed = on;

    // Подписанному — приглушённая подложка и обычный текст: ровно так
    // отличает эти два состояния и сам YouTube.
    [_subscribeLabel setText:on ? YTLoc(@"Вы подписаны") : YTLoc(@"Подписаться")];
    [_subscribeLabel setTextColor:on ? [YTTheme secondaryText]
                                     : [YTTheme primaryActionForeground]];
    [_subscribeFill setFillColor:on ? [YTTheme surface]
                                    : [YTTheme primaryActionBackground]];

    /**
     * У подписанного в кнопке появляются колокольчик и стрелка —
     * `SubscribeSubscribedIconsPanel` в разметке оригинала.
     */
    [_bellIcon setHidden:!on];
    [_bellChevron setHidden:!on];

    if (on) {
        [self applyBellIcon];
    }

    [[self view] setNeedsLayout];
}

/**
 * Сведения о ролике не пришли — просим ещё, с нарастающей паузой.
 *
 * Прежде неудача была окончательной: страница так и оставалась без
 * названия, канала и оценок, хотя ролик играл. А случается она чаще всего
 * на минутном провале связи — журнал 25.09.2026: iPhone 4, сорок секунд
 * без ответа и через туннель, и мимо него (SponsorBlock тоже не дождался),
 * — и сразу за провалом тот же запрос прошёл бы. Четыре попытки
 * за полминуты: дольше ждать нет смысла, человек уже смотрит.
 */
- (void)retryDetails:(NSString *)videoId
            playlist:(NSString *)playlist
             attempt:(NSInteger)attempt {
    if (attempt > 4) {
        NSLog(@"[YouTube/Плеер] Сведения о ролике так и не пришли — сдаёмся");

        return;
    }

    NSTimeInterval delay = 3.0 * attempt;

    NSLog(@"[YouTube/Плеер] Сведения о ролике не пришли — попытка %ld через %.0f с",
          (long)attempt + 1, delay);

    __weak YTPlayerViewController *weak = self;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YTPlayerViewController *me = weak;

        if (me == nil || ![me->_videoId isEqualToString:videoId]) {
            return;
        }

        YTAsync(^{
            NSDictionary *details = [YTApi videoDetails:videoId playlist:playlist];

            YTMain(^{
                YTPlayerViewController *again = weak;

                if (again == nil || ![again->_videoId isEqualToString:videoId]) {
                    return;
                }

                if (details != nil) {
                    NSLog(@"[YouTube/Плеер] Сведения о ролике пришли с попытки %ld",
                          (long)attempt + 1);

                    [again applyDetails:details];
                } else {
                    [again retryDetails:videoId playlist:playlist attempt:attempt + 1];
                }
            });
        });
    });
}

- (void)applyDetails:(NSDictionary *)details {
    if (details == nil) {
        return;
    }

    NSString *title = [details objectForKey:@"title"];

    if ([title length] > 0) {
        [_title setText:title];
        [_fullscreenTitle setText:title];
    }

    NSString *channel = [details objectForKey:@"channelTitle"];

    [_channelName setText:channel];
    [_fullscreenAuthor setText:channel];
    [_channelSubs setText:[details objectForKey:@"subscribers"]];
    [_likeCount setText:[details objectForKey:@"likes"]];

    [self loadDislikes];

    /**
     * Отметку «сохранено» сбрасываем: узнать её можно только списком
     * плейлистов, а спрашивать его ради значка на каждом ролике — лишний
     * запрос. Лист, когда его откроют, покрасит значок сам.
     */
    _savedSomewhere = NO;

    [self applySaveButton];

    // Новый ролик — ряд с начала: с оценкой, а не с «Скачать».
    [_actionScroll setContentOffset:CGPointZero animated:NO];

    _rateParams = [details copy];

    // Те же сведения нужны загрузчику — он складывает их рядом с файлом.
    _details = [details copy];

    // Качества принадлежат ролику: сменился ролик — набор недействителен.
    _knownHeights = nil;

    [self updateDownloadButton];

    // Нынешнее предпочтение оповещений — им отмечена строка в панели.
    NSNumber *bell = [details objectForKey:@"notifications"];

    if (bell != nil) {
        _notifications = [bell integerValue];
    }

    [self applyLiked:[details objectForKey:@"liked"]
          subscribed:[details objectForKey:@"subscribed"]];

    _channelId = [[details objectForKey:@"channelId"] copy];

    NSString *avatar = [details objectForKey:@"channelThumbnail"];

    if ([avatar length] > 0) {
        [YTImageLoader loadInto:_channelAvatar url:avatar targetWidth:40];
    }

    _descriptionText = [[details objectForKey:@"description"] copy];
    _chapters = [self chaptersIn:_descriptionText];

    [self applyChapters];

    // Просмотры и дата — для строки сведений над описанием.
    _viewsText = [[details objectForKey:@"views"] copy];
    _publishedText = [[details objectForKey:@"published"] copy];

    [self applyQueue:details];
    [self applyRelated:[details objectForKey:@"related"]];

    // Комментарии подтягиваются отдельно: на них уходит свой запрос,
    // а страница должна показаться раньше.
    NSString *token = [details objectForKey:@"commentsToken"];

    _commentsToken = [token copy];

    /**
     * Чат трансляции показывается на месте карточки комментариев.
     *
     * У эфира комментариев обычно нет, и там прежде висела надпись
     * «Комментарии к этому видео отключены» — место пустовало, хотя
     * живой разговор идёт рядом. Метка чата приходит тем же ответом
     * `next`, что и всё описание, так что лишнего запроса не нужно.
     */
    [self stopLiveChat];

    _chatFilters = nil;

    // Обычный ролик — заголовок прежний; ниже его сменит чат, если он есть.
    [_commentsTitle setText:YTLoc(@"Комментарии")];

    _chatToken = [[details objectForKey:@"liveChatToken"] copy];

    if ([_chatToken length] > 0) {
        _chatItems = [NSMutableArray array];

        /**
         * Метки фильтров добываем сразу, пока человек смотрит: за ними
         * идёт отдельный заход на страницу чата, и делать его в тот миг,
         * когда панель открывают, значит заставить ждать.
         */
        NSString *forVideo = [_videoId copy];

        __weak YTPlayerViewController *weakChat = self;

        YTAsync(^{
            NSArray *filters = [YTApi liveChatFiltersForVideo:forVideo];

            YTMain(^{
                YTPlayerViewController *screen = weakChat;

                if (screen != nil && [forVideo isEqualToString:screen->_videoId]) {
                    screen->_chatFilters = filters;
                }
            });
        });

        // На месте комментариев теперь чат — и называется он так же.
        [_commentsTitle setText:YTLoc(@"Чат")];

        [self showCommentsNotice:YTLoc(@"Чат трансляции загружается…")];
        [self pollLiveChat];
    }

    /**
     * Панели комментариев у ролика нет вовсе — значит, они закрыты.
     *
     * Прежде карточка просто не появлялась, и выглядело это как «ещё
     * грузится»: человек ждал у пустого места, которое ничем не кончалось.
     * Своих слов у сервера в этом случае нет — спрашивать было нечего, —
     * поэтому надпись наша.
     */
    if ([token length] == 0 && [_chatToken length] == 0) {
        [self showCommentsNotice:YTLoc(@"Комментарии к этому видео отключены")];
    }

    if ([token length] > 0) {
        YTAsync(^{
            NSDictionary *comments = [YTApi comments:token];

            YTMain(^{
                /**
                 * Ответ придерживаем для панели.
                 *
                 * Эта же страница нужна и ей, а брали её дважды: сперва
                 * сюда — ради первого комментария под роликом, — потом
                 * заново, когда панель открывали. Отсюда и секунды
                 * ожидания на первом открытии: четверть мегабайта
                 * запрашивалась и разбиралась второй раз подряд.
                 */
                if ([token isEqualToString:_commentsToken]) {
                    _commentsPage = comments;
                }

                [self applyComments:comments];
            });
        });
    }

    [[self view] setNeedsLayout];
}

/**
 * Похожие. На телефоне это те же карточки во всю ширину, что в ленте,
 * только с прямыми углами превью (`CornerRadius="0"` в шаблоне) и отступом
 * 16 между ними.
 */
/** Место ролика в очереди, или −1, если его там нет. */
- (NSInteger)indexOfVideo:(NSString *)videoId in:(NSArray *)items {
    if ([videoId length] == 0) {
        return -1;
    }

    for (NSUInteger i = 0; i < [items count]; i++) {
        if ([[[items objectAtIndex:i] videoId] isEqualToString:videoId]) {
            return (NSInteger)i;
        }
    }

    return -1;
}

/**
 * Очередь для показа: у сохранённого плейлиста — та, что прислали,
 * у микса — своя, накопленная.
 *
 * Порт `MergeJamQueue` из Video.xaml.cs. Сохранённый плейлист приходит
 * целиком и в неизменном порядке, поэтому свежий ответ и есть истина.
 * Микс («джем») устроен иначе: сервер каждый раз пересобирает скользящее
 * окно вокруг нынешнего ролика, и брать его как есть — значит терять всё
 * уже прослушанное и видеть новый список на каждом переходе. Поэтому
 * список ведём сами: он растёт, порядок в нём держится, а дописывается
 * он **только** когда играет последний в нём ролик — так же растёт микс
 * и на самом YouTube.
 *
 * Список статический: страница ролика на каждый переход своя новая,
 * а микс продолжается — ровно поэтому и в оригинале он статический.
 */
static NSString *YTJamPlaylistId = nil;
static NSMutableArray *YTJamItems = nil;

- (NSArray *)queueFrom:(NSArray *)fresh {
    // Микс узнаётся по приставке: `RD` — автоподборка, `PL` и прочие — нет.
    BOOL mix = [_playlistId hasPrefix:@"RD"];

    if (!mix) {
        YTJamPlaylistId = nil;
        YTJamItems = nil;

        return fresh;
    }

    if (YTJamItems == nil || ![YTJamPlaylistId isEqualToString:_playlistId]) {
        // Микс другой — история прежнего ни к чему.
        YTJamPlaylistId = [_playlistId copy];
        YTJamItems = [NSMutableArray arrayWithArray:fresh];

        return YTJamItems;
    }

    NSInteger place = [self indexOfVideo:_videoId in:YTJamItems];
    BOOL atEnd = place < 0 || place >= (NSInteger)[YTJamItems count] - 1;

    if (!atEnd) {
        NSLog(@"[YouTube/Очередь] Микс не трогаем: %ld из %lu",
              (long)(place + 1), (unsigned long)[YTJamItems count]);

        return YTJamItems;
    }

    NSUInteger added = 0;

    for (YTVideoItem *item in fresh) {
        if ([self indexOfVideo:item.videoId in:YTJamItems] < 0) {
            [YTJamItems addObject:item];
            added++;
        }
    }

    NSLog(@"[YouTube/Очередь] Дошли до конца микса, дописано %lu, всего %lu",
          (unsigned long)added, (unsigned long)[YTJamItems count]);

    return YTJamItems;
}

/**
 * Очередь подборки — порт `PlaylistQueuePanel`.
 *
 * Строка: превью 104×58 со скруглением 8, название 13 в две строки,
 * автор 12 secondary с отступом 3, между строками 10. У играющего сейчас
 * ролика поверх превью кружок 30 с треугольником — `now_playing_visibility`
 * в оригинале.
 */
- (void)applyQueue:(NSDictionary *)details {
    _queue = [self queueFrom:[details objectForKey:@"queue"]];

    BOOL has = [_queue count] > 0;

    [_queueCard setHidden:!has];
    [_queueHeader setHidden:!has];

    for (UIView *row in _queueRows) {
        [row removeFromSuperview];
    }

    [_queueRows removeAllObjects];

    if (!has) {
        return;
    }

    NSString *title = [details objectForKey:@"queueTitle"];

    [_queueTitle setText:[title length] > 0 ? title : YTLoc(@"Плейлист")];

    /**
     * Номер берём по своему списку, а не из ответа.
     *
     * `currentIndex` сервера считает по той пачке, которую он сейчас
     * прислал; у микса это скользящее окно, и в нашем накопленном списке
     * тот же ролик стоит совсем на другом месте. Своим счётом «5 из 30»
     * не разъезжается с тем, что человек видит.
     */
    NSInteger index = [self indexOfVideo:_videoId in:_queue];

    if (index < 0) {
        index = [[details objectForKey:@"queueIndex"] integerValue];
    }

    [_queuePosition setText:YTLocF(@"%ld из %lu",
                                   (long)(index + 1), (unsigned long)[_queue count])];

    __weak YTPlayerViewController *weakSelf = self;

    for (NSUInteger i = 0; i < [_queue count]; i++) {
        YTVideoItem *item = [_queue objectAtIndex:i];

        YTTappableView *row = [[YTTappableView alloc] initWithFrame:CGRectZero];

        [row setHighlights:NO];

        YTRoundedImageView *thumb = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];

        [thumb setCornerRadius:8];
        [thumb setPlaceholderColor:[YTTheme videoPlaceholder]];
        [row addSubview:thumb];

        [YTImageLoader loadInto:thumb url:item.thumbnail targetWidth:104];

        UILabel *name = YTLabel(YTFontRegular(13), [YTTheme primaryText], 2);

        [name setText:item.title];
        [row addSubview:name];

        UILabel *author = YTLabel(YTFontRegular(12), [YTTheme secondaryText], 1);

        [author setText:item.channelTitle];
        [row addSubview:author];

        // Кружок «сейчас играет» — только у текущего ролика.
        YTPillView *marker = [[YTPillView alloc] initWithFrame:CGRectZero];

        [marker setCornerRadius:15];
        [marker setFillColor:[UIColor colorWithWhite:0 alpha:0.8]];
        [marker setHidden:(NSInteger)i != index];
        [row addSubview:marker];

        /**
         * Треугольник — наш значок, а не знак «▶».
         *
         * В разметке оригинала стоит именно этот знак, но на iOS
         * у U+25B6 есть эмодзи-начертание, и система выбирает его:
         * вместо тонкого белого треугольника выходит цветная картинка
         * со своим полем. Значок `pl_play` рисует ровно то, что нужно,
         * и уже лежит в связке.
         */
        UIImageView *play = [[UIImageView alloc] initWithFrame:CGRectZero];

        [play setImage:YTDarkIcon(@"pl_play")];
        [play setContentMode:UIViewContentModeScaleAspectFit];
        [play setHidden:(NSInteger)i != index];
        [row addSubview:play];

        NSString *videoId = item.videoId;
        NSString *videoTitle = item.title;

        [row setOnTap:^{
            [weakSelf openQueueItem:videoId title:videoTitle];
        }];

        [[self listHost] addSubview:row];
        [_queueRows addObject:row];
    }
}

/**
 * Переход к соседнему ролику подборки — порт `NavigateToPlaylistVideo`.
 *
 * Новой страницы не открывается: подборка остаётся той же, меняется
 * только ролик. В оригинале это `SwitchToVideoAsync(videoId,
 * currentPlaylistId, _playlistQueueTitle)`, и там же сказано зачем —
 * «keeps the playlist / mix context while moving between its videos,
 * so the queue (and, for a jam, its endless continuation) survives».
 */
- (void)openQueueItem:(NSString *)videoId title:(NSString *)title {
    if ([videoId length] == 0 || [videoId isEqualToString:_videoId]) {
        return;
    }

    _videoId = [videoId copy];
    _titleText = [title copy];

    // Состояние прежнего ролика не должно пережить переход.
    _pickedHeight = 0;
    _sabrFellBack = NO;
    _askedAudioTrack = NO;
    _rate = 1.0f;
    _duration = 0;
    _finished = NO;
    _watchReported = NO;
    _trackingJson = nil;
    _commentsToken = nil;
    _commentsPage = nil;

    [_title setText:title];
    [_fullscreenTitle setText:title];

    [self teardownPlayer];
    [[YTHlsProxy shared] close];

    if (_commentsSheet != nil && [_commentsSheet isOpen]) {
        [_commentsSheet close];
    }

    [_busy start];

    // Страница начинается сверху: прежняя прокрутка относилась к другому
    // ролику, и оставлять её посреди списка было бы странно.
    [_page setContentOffset:CGPointZero animated:NO];

    [self load];
}

/** Складывает и раскладывает список — `PlaylistQueueHeaderButton_Click`. */
- (void)toggleQueue {
    _queueCollapsed = !_queueCollapsed;

    [[self view] setNeedsLayout];
}

- (void)toggleChapters {
    _chaptersCollapsed = !_chaptersCollapsed;

    [[self view] setNeedsLayout];
}

/**
 * Собирает список глав.
 *
 * Строка — метка времени слева и название справа: превью у глав нет,
 * а брать под каждую картинку самого ролика значило бы поставить
 * пять одинаковых квадратов, от которых никакого толку.
 *
 * Зовётся после разбора описания: до него `_chapters` пуст, и карточка
 * просто не показывается.
 */
- (void)applyChapters {
    BOOL has = [_chapters count] > 0;

    [_chapterCard setHidden:!has];
    [_chapterHeader setHidden:!has];

    for (UIView *row in _chapterRows) {
        [row removeFromSuperview];
    }

    [_chapterRows removeAllObjects];

    if (!has) {
        return;
    }

    __weak YTPlayerViewController *weakSelf = self;

    for (NSUInteger i = 0; i < [_chapters count]; i++) {
        NSDictionary *chapter = [_chapters objectAtIndex:i];

        YTTappableView *row = [[YTTappableView alloc] initWithFrame:CGRectZero];

        YTPillView *stamp = [[YTPillView alloc] initWithFrame:CGRectZero];

        [stamp setCornerRadius:4];
        [stamp setFillColor:[YTTheme surfaceHover]];
        [row addSubview:stamp];

        UILabel *time = YTLabel(YTFontRegular(12), [YTTheme secondaryText], 1);

        [time setTextAlignment:NSTextAlignmentCenter];
        [time setText:[self clock:[[chapter objectForKey:@"start"] doubleValue]]];
        [row addSubview:time];

        UILabel *name = YTLabel(YTFontRegular(14), [YTTheme primaryText], 2);

        [name setText:[chapter objectForKey:@"title"]];
        [row addSubview:name];

        NSTimeInterval start = [[chapter objectForKey:@"start"] doubleValue];

        [row setOnTap:^{
            [weakSelf openChapterAt:start];
        }];

        [[self listHost] addSubview:row];
        [_chapterRows addObject:row];
    }

    [self refreshChapterHeader];
}

/** Перемотка к началу главы. */
- (void)openChapterAt:(NSTimeInterval)start {
    NSLog(@"[YouTube/Плеер] Глава: перематываем на %.0f с", start);

    [self seekTo:start];

    /*
     * Список сворачивается: человек выбрал главу, дальше ему нужен
     * кадр, а не перечень. Так же ведёт себя и оригинал.
     */
    _chaptersCollapsed = YES;

    [self refreshChapterHeader];

    [[self view] setNeedsLayout];
}

/**
 * Обновляет подпись под заголовком: какая глава идёт сейчас.
 *
 * Зовётся с хода часов, поэтому дёшево: пока название не сменилось,
 * не трогаем ни надпись, ни раскладку.
 */
- (void)refreshChapterHeader {
    if ([_chapterCard isHidden]) {
        return;
    }

    NSString *now = [self chapterTitleAt:CMTimeGetSeconds([_player currentTime])];

    if ([now length] == 0) {
        /*
         * Двоеточие со счётом, а не «5 разделов»: по-русски число
         * требует склонения — «2 раздела», «5 разделов», — и одной
         * строкой это не выразить.
         */
        now = YTLocF(@"Разделов: %lu", (unsigned long)[_chapters count]);
    }

    if ([[_chapterNow text] isEqualToString:now]) {
        return;
    }

    [_chapterNow setText:now];
}

- (void)applyRelated:(NSArray *)related {
    _related = related;

    while ([_relatedCards count] < [related count]) {
        YTVideoCard *card = [[YTVideoCard alloc] initWithFrame:CGRectZero];

        [card setThumbRadius:0];

        [[self listHost] addSubview:card];
        [_relatedCards addObject:card];
    }

    for (NSUInteger i = 0; i < [_relatedCards count]; i++) {
        YTVideoCard *card = [_relatedCards objectAtIndex:i];

        if (i >= [related count]) {
            [card setHidden:YES];
            continue;
        }

        [card setHidden:NO];
        [card bind:[related objectAtIndex:i]];
    }

    [[self view] setNeedsLayout];
}

/**
 * Карточка с одной надписью вместо комментария.
 *
 * Тот же вид, что у обычной карточки, только без автора, времени
 * и кружка: заводить ради одной строки отдельную — значит удваивать
 * раскладку, которая и так уже есть.
 */
#pragma mark Чат трансляции

/**
 * Останавливает опрос чата и забывает набранное.
 *
 * Зовётся на каждой загрузке страницы и при уходе с неё: таймер, забытый
 * от прошлого ролика, стучался бы в чужой чат и переписывал карточку
 * поверх нового ролика.
 */
- (void)stopLiveChat {
    [_chatTimer invalidate];

    _chatTimer = nil;
    _chatToken = nil;
    _chatItems = nil;
}

/**
 * Берёт очередную страницу чата и показывает свежую запись.
 *
 * Опрос идёт с той задержкой, которую называет сам сервер (обычно десять
 * секунд): чаще он всё равно ничего не отдаст. Метка каждый раз новая,
 * старая после ответа не годится.
 *
 * В карточке под роликом видна одна запись — самая свежая, — как и у
 * комментариев, где показывается один комментарий. Весь разговор
 * открывается по нажатию, панелью.
 */
- (void)pollLiveChat {
    NSString *token = [_chatToken copy];

    if ([token length] == 0) {
        return;
    }

    NSInteger generation = [_loadGeneration current];

    __weak YTPlayerViewController *weakSelf = self;

    YTAsync(^{
        NSDictionary *page = [YTApi liveChat:token];

        YTMain(^{
            YTPlayerViewController *screen = weakSelf;

            if (screen == nil || ![screen->_loadGeneration isCurrent:generation]) {
                return;
            }

            [screen applyLiveChat:page after:token];
        });
    });
}

- (void)applyLiveChat:(NSDictionary *)page after:(NSString *)asked {
    // Пока ходили в сеть, страница могла смениться — ответ уже не наш.
    if (![asked isEqualToString:_chatToken]) {
        return;
    }

    if (page == nil) {
        /**
         * Молчание сервера чат не кончает: у трансляции бывают и пустые
         * ответы. Пробуем снова с той же меткой через десять секунд.
         */
        [self scheduleLiveChatAfter:10.0];

        return;
    }

    NSString *next = [page objectForKey:@"token"];

    if ([next length] > 0) {
        _chatToken = [next copy];
    }

    NSArray *fresh = [page objectForKey:@"items"];

    if ([fresh count] > 0) {
        if (_chatItems == nil) {
            _chatItems = [NSMutableArray array];
        }

        [_chatItems addObjectsFromArray:fresh];

        // Держим полсотни последних: панели этого хватает, памяти — тем более.
        while ([_chatItems count] > 50) {
            [_chatItems removeObjectAtIndex:0];
        }

        [self showLiveChatItem:[_chatItems lastObject]];
    } else if ([_chatItems count] == 0) {
        [self showCommentsNotice:YTLoc(@"В чате пока тихо")];
    }

    NSNumber *wait = [page objectForKey:@"wait"];

    [self scheduleLiveChatAfter:(wait != nil ? [wait doubleValue] : 10.0)];
}

- (void)scheduleLiveChatAfter:(NSTimeInterval)wait {
    [_chatTimer invalidate];

    _chatTimer = [NSTimer scheduledTimerWithTimeInterval:MAX(2.0, wait)
                                                  target:self
                                                selector:@selector(pollLiveChat)
                                                userInfo:nil
                                                 repeats:NO];
}

/**
 * Показывает запись чата в той же карточке, что и комментарий.
 *
 * Отдельной раскладки не заводим намеренно: карточка уже умеет автора,
 * кружок и текст, а «время» у записи чата смысла не имеет — она и так
 * сиюминутная. В его поле ставим пометку, что это чат.
 */
- (void)showLiveChatItem:(NSDictionary *)item {
    if (item == nil) {
        return;
    }

    [_commentAuthor setText:[item objectForKey:@"author"]];

    /**
     * Справа пусто: заголовок карточки и так говорит «Чат», а время у
     * записи чата смысла не имеет — она сиюминутная.
     */
    [_commentTime setText:@""];
    [_commentText setText:YTClampText([item objectForKey:@"text"] ?: @"", 300)];

    [_commentAvatar setHidden:NO];
    [_commentAvatar setImage:nil];

    NSString *avatar = [item objectForKey:@"avatar"];

    if ([avatar length] > 0) {
        [YTImageLoader loadInto:_commentAvatar url:avatar targetWidth:24];
    }

    [_commentsCard setHidden:NO];

    [[self view] setNeedsLayout];
}

- (void)showCommentsNotice:(NSString *)notice {
    [_commentAuthor setText:@""];
    [_commentTime setText:@""];
    [_commentText setText:notice];

    [_commentAvatar setImage:nil];
    [_commentAvatar setHidden:YES];

    [_commentsCard setHidden:NO];

    [[self view] setNeedsLayout];
}

- (void)applyComments:(NSDictionary *)comments {
    NSArray *items = [comments objectForKey:@"items"];

    if ([items count] == 0) {
        /**
         * Пусто по-разному: сервер сказал, почему, — говорим его словами;
         * промолчал — карточки нет, как и прежде. Придумывать «отключены»
         * там, где их могло просто не быть, не станем.
         */
        NSString *said = [comments objectForKey:@"disabledMessage"];

        if ([said length] > 0) {
            [self showCommentsNotice:said];
        } else {
            [_commentsCard setHidden:YES];
            [[self view] setNeedsLayout];
        }

        return;
    }

    // Обычная карточка — кружок вернуть, его мог спрятать отказ.
    [_commentAvatar setHidden:NO];

    /**
     * Показывается один комментарий — так же в оригинале: в карточке
     * «Комментарии» стоит ровно одна запись, а весь список открывается
     * отдельно.
     */
    NSDictionary *first = [items objectAtIndex:0];

    [_commentAuthor setText:[first objectForKey:@"author"]];
    [_commentTime setText:[first objectForKey:@"published"]];

    /**
     * Текст обрезается, и это не косметика: у ролика может набраться
     * тридцать с лишним тысяч знаков комментариев, а замер такого полотна
     * идёт через CoreText и на старом железе занимает секунды.
     */
    [_commentText setText:YTClampText([first objectForKey:@"text"] ?: @"", 600)];

    NSString *avatar = [first objectForKey:@"avatar"];

    if ([avatar length] > 0) {
        [YTImageLoader loadInto:_commentAvatar url:avatar targetWidth:24];
    }

    [_commentsCard setHidden:NO];

    [[self view] setNeedsLayout];
}

#pragma mark Плеер

/**
 * Пуск в обход сторожа — только для тех мест, где загрузка одна
 * и заведомо своя (смена качества, повтор той же страницы).
 */
- (void)startPlayer:(NSString *)url {
    [self startPlayer:url generation:[_loadGeneration current]];
}

/**
 * Пуск с проверкой поколения.
 *
 * Между уходом в сеть и возвратом человек успевает уйти со страницы и
 * зайти на неё заново. Тогда у старой загрузки всё готово, и она честно
 * доводит дело до конца: поднимает свой плеер и играет — только страницы
 * у неё уже нет. Со стороны это видно как ролик, который играет сам по
 * себе без мини-окна, а если новая страница к тому времени успела
 * подняться — как пропавшая картинка: прокси один на всех, и опоздавший
 * отбирает его у нынешнего.
 *
 * Поэтому поколение проверяется здесь, у самого пуска, а не только
 * в начале: до этой строки от ухода со страницы проходят десятки секунд.
 */
- (void)startPlayer:(NSString *)url generation:(NSInteger)generation {
    if (![_loadGeneration isCurrent:generation]) {
        NSLog(@"[YouTube/Плеер] Опоздавшая загрузка — плеер не поднимаем");
        return;
    }

    [self teardownPlayer];

    // Новый поток — новый счёт спусков; перезавод декодера идёт по тому
    // же адресу и счёт не сбрасывает.
    if (![url isEqualToString:_streamUrl]) {
        _stepDowns = 0;
    }

    _streamUrl = url;

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL URLWithString:url]];

    _observedItem = item;
    _observingStatus = YES;

    [item addObserver:self forKeyPath:@"status" options:0 context:NULL];

    _player = [AVPlayer playerWithPlayerItem:item];

    _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];

    /*
     * Новый ролик — новая укладка. Зум выбирают под соотношение сторон
     * конкретного кадра, и переносить его на следующий ролик значило бы
     * обрезать то, что человек обрезать не просил.
     */
    _fillsScreen = NO;

    [self resetZoom];

    [_playerLayer setVideoGravity:[self videoGravity]];
    [_playerLayer setFrame:[_videoHost bounds]];
    [[_videoHost layer] addSublayer:_playerLayer];

    __weak YTPlayerViewController *weakSelf = self;

    _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMake(1, 2)
                                                          queue:dispatch_get_main_queue()
                                                     usingBlock:^(CMTime time) {
        [weakSelf tick];
    }];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playbackFinished)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:item];

    [_playPause setImage:YTDarkIcon(@"pl_pause") forState:UIControlStateNormal];

    /**
     * Скорость восстанавливается при каждом пуске: `play` всегда ставит
     * обычную, и выбранная в меню иначе терялась бы после паузы,
     * перемотки и смены качества.
     *
     * Ноль здесь недопустим: это не «обычная скорость», а пауза.
     */
    /**
     * Продолжаем с того места, где бросили.
     *
     * Только у обычных роликов: у эфира своя ось времени, а Shorts, по
     * просьбе человека, всегда начинаются сначала — они идут своим
     * разделом и сюда не попадают. Досмотренный до конца тоже начинается
     * сначала: это решает само хранилище, возвращая ноль.
     */
    if (![[YTHlsProxy shared] isLive]) {
        NSTimeInterval resume = _resumeAt;

        if (resume > 0) {
            NSLog(@"[YouTube/Плеер] Продолжаем с %.0f с — здесь бросили", resume);

            [_player seekToTime:CMTimeMakeWithSeconds(resume, 600)
                toleranceBefore:CMTimeMakeWithSeconds(1.0, 600)
                 toleranceAfter:CMTimeMakeWithSeconds(1.0, 600)];
        }
    }

    if (_rate > 0 && _rate != 1.0f) {
        [_player setRate:_rate];
    } else {
        [_player play];
    }

    [self startStallWatch];
    [self showNowPlaying];

    [self askAudioTrackIfAsked];
}

/**
 * «Спрашивать каждый раз» — открываем список дорожек, когда их несколько.
 *
 * Вопрос задаётся после пуска, а не до: до пуска у нас ещё нет ответа
 * `/player`, а значит и перечня дорожек, — пришлось бы задерживать показ
 * ради лишнего запроса у каждого ролика, в том числе одноязычного.
 * Выбранная дорожка подхватывается на ходу, тем же путём, что и выбор
 * из меню вручную.
 */
- (void)askAudioTrackIfAsked {
    if (_askedAudioTrack
        || [YTSettings playbackAudioLanguage] != YTAudioLanguageAsk) {
        return;
    }

    if ([[self audioTracks] count] < 2) {
        return;
    }

    _askedAudioTrack = YES;

    [self openMenuPage:3];
    [_menu openIn:[self view]];
}

/**
 * Карточка на экране блокировки. Название и канал берутся со страницы,
 * обложка — та же, что у карточки ролика в ленте.
 */
- (void)showNowPlaying {
    NSString *artwork = [_videoId length] > 0
        ? [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", _videoId]
        : nil;

    [YTNowPlaying showTitle:[_title text]
                    channel:[_channelName text]
                    artwork:artwork
                     player:_player
                   duration:_duration];

    [self takeRemoteCommands];
}

/**
 * Забирает кнопки замка себе.
 *
 * Пока страница на виду, распоряжаться воспроизведением должна она:
 * свёрнутое окно тем временем пусто, а его обработчики трогали бы
 * не тот плеер.
 */
- (void)takeRemoteCommands {
    __weak YTPlayerViewController *weakSelf = self;

    [YTNowPlaying takeCommandsPlay:^{
        YTPlayerViewController *player = weakSelf;

        // «Играй» и «стой» приходят порознь: повторное «играй»
        // переключателем поставило бы на паузу.
        if (player != nil && [player->_player rate] <= 0) {
            [player playPauseTapped];
        }
    } pause:^{
        YTPlayerViewController *player = weakSelf;

        if (player != nil && [player->_player rate] > 0) {
            [player playPauseTapped];
        }
    } skip:^(NSTimeInterval seconds) {
        [weakSelf skipBy:seconds];
    } seekTo:^(NSTimeInterval seconds) {
        [weakSelf seekTo:seconds];
    }];
}

/**
 * Перемотка на несколько секунд от нынешнего места.
 *
 * Обработчик завершения здесь не нужен и вреден: `seekToTime:`
 * с обработчиком бросает исключение у неготового элемента, а кнопку
 * на замке жмут когда угодно.
 */
- (void)skipBy:(NSTimeInterval)seconds {
    if (_player == nil) {
        return;
    }

    NSTimeInterval now = CMTimeGetSeconds([_player currentTime]);

    if (isnan(now) || isinf(now)) {
        return;
    }

    NSTimeInterval target = now + seconds;

    if (target < 0) { target = 0; }
    if (_duration > 0 && target > _duration) { target = _duration - 1; }
    if (target < 0) { target = 0; }

    [self seekTo:target];
}

/**
 * Перемотка на заданное место — **единственный** путь для всех, кто
 * перематывает: ползунка, кнопок, гарнитуры и экрана блокировки.
 *
 * Раньше кнопки прыгали своим ходом, прямо на ходу воспроизведения, —
 * и на этом ловился зелёный мусор вместо кадра, а следом зависание.
 * Причина в устройстве потока: он идёт не готовым файлом, а через нашу
 * подачу и склейку в поток TS. Прыжок назад заставляет плеер просить
 * куски заново, и пока декодер продолжает жевать прежние, к нему
 * приходят кадры от другого места — без опорного кадра впереди.
 * Картинка от такого разваливается, а на A4, где декодер аппаратный
 * и один на систему, разваливается не только картинка.
 *
 * Поэтому порядок ровно тот же, что у ползунка, и он не случайный:
 *
 *   1. остановить — декодеру нечего жевать, пока идёт прыжок;
 *   2. прыгнуть с допуском — плееру дозволено встать на ближайший
 *      опорный кадр, а не собирать точное место из середины группы;
 *   3. продолжить, если играли, — и только после того, как прыжок
 *      действительно завершился.
 */
- (void)seekTo:(NSTimeInterval)target {
    if (_player == nil) {
        return;
    }

    _seekTarget = target;
    _finished = NO;

    [self showTime:target];

    /**
     * Играл ли плеер — вопрос к тому мигу, когда перемотки ещё не было.
     *
     * Пока прыжок идёт, плеер стоит по нашей же вине: мы сами его
     * остановили строкой ниже. И если в это время нажать кнопку ещё
     * раз — а её жмут по нескольку раз подряд, — то новая перемотка
     * спросит у остановленного плеера, играл ли он, услышит «нет»
     * и по завершении честно оставит его стоять. Навсегда: каждая
     * следующая перемотка застаёт ту же остановку.
     *
     * Ровно это и было в журнале: после двух быстрых нажатий все
     * последующие строки шли с пометкой «играл нет», и воспроизведение
     * не возобновлялось. Поэтому спрашиваем плеер только тогда, когда
     * прыжок не идёт; иначе верим прежнему ответу.
     */
    if (!_awaitingSeek) {
        _seekWasPlaying = ([_player rate] > 0);
    }

    BOOL wasPlaying = _seekWasPlaying;

    /**
     * Метка прыжка. Обработчик перебитой перемотки приходит позже своей
     * очереди и не должен распоряжаться плеером: за него это сделает
     * тот, кто перебил.
     */
    _seekToken++;

    NSInteger token = _seekToken;

    _awaitingSeek = YES;

    [_player pause];
    [_busy start];

    /**
     * Допуск в полсекунды в обе стороны.
     *
     * Точный прыжок велит плееру собрать именно тот кадр, а это значит
     * декодировать всю группу от опорного кадра до него — на неспешном
     * потоке и слабом железе самое хрупкое место. Полсекунды на глаз
     * незаметны, зато плеер встаёт на готовый кадр.
     */
    CMTime time = CMTimeMakeWithSeconds(target, 600);
    CMTime slack = CMTimeMakeWithSeconds(0.5, 600);

    /**
     * Обработчик завершения — только у готового элемента: иначе
     * `seekToTime:completionHandler:` бросает исключение, а кнопку
     * жмут когда угодно, в том числе в первые секунды.
     */
    if ([_observedItem status] != AVPlayerItemStatusReadyToPlay) {
        [_player seekToTime:time toleranceBefore:slack toleranceAfter:slack];

        _awaitingSeek = NO;

        [_busy stop];

        return;
    }

    NSTimeInterval started = CFAbsoluteTimeGetCurrent();

    NSLog(@"[YouTube/Плеер] Перемотка на %.1f с (играл %@, запас %@)",
          target, wasPlaying ? @"да" : @"нет",
          [_observedItem isPlaybackBufferEmpty] ? @"пуст" : @"есть");

    /**
     * Сторож на случай, если ответа не будет вовсе.
     *
     * `seekToTime:completionHandler:` обещает позвать обработчик, но
     * молчит, пока плеер не соберёт кадр в новом месте, — а собрать его
     * он может и не суметь: подача уходит за нужным куском заново, и на
     * неспешном железе это иногда не кончается ничем. Снаружи выходит
     * ровно то, о чём говорят: «при перемотке видео зависает» —
     * `tick` до конца перемотки показывает цель и не трогает ни время,
     * ни субтитры.
     *
     * По истечении срока сторож возвращает управление: снимает ожидание
     * и, если играли, пробует продолжить. Лучше рывок, чем немая картинка.
     *
     * Срок — полминуты, а не десять секунд, как было.
     *
     * Десяти хватало, пока кусок весил двести-триста килобайт. На старом
     * планшете с нынешними — под мегабайт — сборка одного куска занимает
     * от четырёх до двенадцати секунд, и сторож начал срабатывать на
     * перемотках, которые вот-вот доехали бы: в журнале это «не ответила
     * за 10 с» подряд там, где следом приходит «Сегмент собран за 10573
     * мс». Отпустить рано — значит показать рывок на ровном месте.
     */
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(seekTimedOut)
                                               object:nil];

    [self performSelector:@selector(seekTimedOut) withObject:nil afterDelay:YTSeekPatience];

    __weak YTPlayerViewController *weakSelf = self;

    [_player seekToTime:time
        toleranceBefore:slack
         toleranceAfter:slack
      completionHandler:^(BOOL finished) {
        YTMain(^{
            YTPlayerViewController *player = weakSelf;

            if (player == nil) {
                return;
            }

            [player seekFinished:finished
                           after:CFAbsoluteTimeGetCurrent() - started
                           token:token];
        });
    }];
}

/**
 * Общий хвост перемотки — и по ответу плеера, и по сторожу.
 *
 * `token` — метка того прыжка, который этот хвост завершает. Обработчик
 * перебитой перемотки приходит с опозданием и со своей меткой; ему тут
 * делать нечего, плеером распоряжается последний прыжок.
 */
- (void)seekFinished:(BOOL)finished
               after:(NSTimeInterval)seconds
               token:(NSInteger)token {
    if (token != _seekToken) {
        return;
    }

    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(seekTimedOut)
                                               object:nil];

    if (!_awaitingSeek) {
        return;
    }

    _awaitingSeek = NO;

    NSLog(@"[YouTube/Плеер] Перемотка кончилась за %.0f мс (%@)",
          seconds * 1000.0, finished ? @"дошла" : @"перебита");

    if (_seekWasPlaying) {
        if (_rate > 0 && _rate != 1.0f) {
            [_player setRate:_rate];
        } else {
            [_player play];
        }
    } else {
        [_busy stop];
    }

    [self updateProgress];
    [YTNowPlaying refreshWithPlayer:_player duration:_duration];
}

- (void)seekTimedOut {
    if (!_awaitingSeek) {
        return;
    }

    NSLog(@"[YouTube/Плеер] Перемотка не ответила за %.0f с — отпускаем "
          @"(время плеера %.1f с, цель %.1f с, запас %@)",
          YTSeekPatience, CMTimeGetSeconds([_player currentTime]), _seekTarget,
          [_observedItem isPlaybackBufferEmpty] ? @"пуст" : @"есть");

    [self seekFinished:NO after:YTSeekPatience token:_seekToken];
}

/**
 * Кнопки гарнитуры и экрана блокировки приходят по цепочке отвечающих,
 * и без согласия стать первым отвечающим до нас не доходят вовсе.
 */
- (BOOL)canBecomeFirstResponder {
    return YES;
}

/**
 * Приём кнопок сделан по-старому — `remoteControlReceivedWithEvent:`.
 *
 * Нынешний способ, `MPRemoteCommandCenter`, появился в iOS 7.1, а этот
 * работает с iOS 4 и до сих пор. При нижней границе 5.1 второй путь
 * пришлось бы держать всё равно, так что держим один.
 */
- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    if ([event type] != UIEventTypeRemoteControl || _player == nil) {
        return;
    }

    switch ([event subtype]) {
        case UIEventSubtypeRemoteControlPlay:
            /**
             * «Играй» и «стой» приходят порознь, и переключателем их
             * обрабатывать нельзя: повторное «играй» на играющем
             * поставило бы на паузу.
             */
            if ([_player rate] <= 0) {
                [self playPauseTapped];
            }
            break;

        case UIEventSubtypeRemoteControlPause:
            if ([_player rate] > 0) {
                [self playPauseTapped];
            }
            break;

        case UIEventSubtypeRemoteControlTogglePlayPause:
            [self playPauseTapped];
            break;

        // «Следующий» и «предыдущий» — те же десять секунд, что у двойного
        // нажатия по кадру: ролик один, переключать нечего.
        case UIEventSubtypeRemoteControlNextTrack:
            [self skipBy:10];
            break;

        case UIEventSubtypeRemoteControlPreviousTrack:
            [self skipBy:-10];
            break;

        default:
            break;
    }
}

- (void)startStallWatch {
    [self stopStallWatch];

    // Минус единица — чтобы первый обход счёл кадр сдвинувшимся: ноль
    // на ноль похож на застревание, а это просто начало.
    _stallSeen = -1;
    _stalledFor = 0;

    _stallTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                   target:self
                                                 selector:@selector(watchStall)
                                                 userInfo:nil
                                                  repeats:YES];
}

- (void)stopStallWatch {
    [_stallTimer invalidate];
    _stallTimer = nil;

    if (_stalled) {
        _stalled = NO;

        [_busy stop];
    }
}

/**
 * Полсекунды без движения при играющем плеере — это набор, а не пауза:
 * пауза видна по `rate`, и её мы не трогаем.
 *
 * Гасит кружок только тот, кто его зажёг: если он горит от загрузки
 * или перемотки, снимет его `tick` по первому же движению кадра.
 */
/**
 * Запас плеера — в журнал. Считаем ровно как панель «статистика».
 *
 * Человек указал на то, чего мне не хватало: я правил подачу по
 * косвенным признакам со стороны прокси (сколько набрано, сколько
 * отдано), а настоящий запас живёт в AVPlayer, и в журнале его не было
 * вовсе. Получалось вслепую. Теперь пишем его раз в две секунды рядом
 * с отставанием подачи от края — и видно сразу, просел запас или нет и
 * нагоняет ли подача.
 */
/**
 * Раз в секунду — всё то же, что в окне для сисадминов, в журнал.
 *
 * Просадка скорости перед смертью потока видна только в движении, а окно
 * показывает её тому, кто в него смотрит, и ничего не сохраняет. Поэтому
 * те же величины пишутся сюда: запас, скорость, сколько принесли за
 * секунду, чем занят плеер и на каком мы запросе. Строка одна, чтобы
 * журнал оставался читаемым, и только при идущем показе.
 */
- (void)logPlaybackStats {
    if (_player == nil) {
        return;
    }

    AVPlayerItem *item = [_player currentItem];

    if (item == nil) {
        return;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    if (now - _statsSaidAt < 1.0) {
        return;
    }

    _statsSaidAt = now;

    double at = CMTimeGetSeconds([_player currentTime]);
    double health = 0;

    for (NSValue *value in [item loadedTimeRanges]) {
        CMTimeRange range = [value CMTimeRangeValue];
        double start = CMTimeGetSeconds(range.start);
        double end = start + CMTimeGetSeconds(range.duration);

        if (at >= start - 0.5 && at <= end && end - at > health) {
            health = end - at;
        }
    }

    double speed = [YTPlaybackStats speedKbps];

    AVPlayerItemAccessLogEvent *event = [[[item accessLog] events] lastObject];

    if (speed <= 0 && event != nil && [event observedBitrate] > 0) {
        speed = [event observedBitrate] / 1000.0;
    }

    long long total = (long long)[YTPlaybackStats totalBytes];
    long long delta = (_statsBytes <= 0) ? 0 : total - _statsBytes;

    _statsBytes = total;

    YTHlsProxy *proxy = [YTHlsProxy shared];
    /**
     * Подачу спрашиваем у раздачи, а не у `YTStreams`.
     *
     * Там лежит статик последней **построенной** подачи, и после неудачной
     * подмены он пустеет — а эфир при этом идёт от прежней. Сводка писала
     * «готовые адреса» при живой подаче SABR (журнал 80) и врала.
     */
    YTSabr *sabr = [[YTHlsProxy shared] liveSabr];

    if (sabr == nil && !_sabrFellBack) {
        sabr = [YTStreams lastSabr];
    }

    NSMutableString *line = [NSMutableString stringWithFormat:
        @"запас %.2f с, скорость %.0f Кбит/с, за секунду %lld КБ, "
        @"время %.1f с, состояние %ld, темп %.2f, память %.0f МБ",
        health, speed, delta / 1024, at, (long)[item status], [_player rate],
        YTResidentMegabytes()];

    if (sabr != nil) {
        [line appendFormat:@", запрос №%ld, дорожки %ld/%ld",
            (long)[sabr requests], (long)[sabr playingItag], (long)[sabr audioItag]];
    } else {
        [line appendString:@", готовые адреса"];
    }

    if ([proxy isLive]) {
        [line appendFormat:@", набрано %.0f с, отставание %.0f с",
            [proxy liveFilledSeconds], [proxy liveLagSeconds]];
    }

    NSLog(@"[YouTube/Здоровье] %@", line);
}

- (void)noteLiveHealth {
    YTHlsProxy *proxy = [YTHlsProxy shared];

    if (![proxy isLive]) {
        return;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    if (now - _healthSaidAt < 2.0) {
        return;
    }

    _healthSaidAt = now;

    AVPlayerItem *item = [_player currentItem];

    if (item == nil) {
        return;
    }

    double at = CMTimeGetSeconds([_player currentTime]);
    double health = 0;

    for (NSValue *value in [item loadedTimeRanges]) {
        CMTimeRange range = [value CMTimeRangeValue];
        double start = CMTimeGetSeconds(range.start);
        double end = start + CMTimeGetSeconds(range.duration);

        if (at >= start - 0.5 && at <= end && end - at > health) {
            health = end - at;
        }
    }

    /**
     * Считаем, сколько замеров кряду запас убывает.
     *
     * Это то самое «буфер меньше порога и убывает несколько секунд
     * подряд», о чём говорил человек. Замер идёт каждые две секунды,
     * значит три подряд — это шесть секунд, заведомо больше одного куска:
     * одна запоздавшая пачка счёт не поднимет.
     */
    if (_healthBuffer > 0 && health < _healthBuffer - 0.5) {
        _healthFalls++;
    } else if (health > _healthBuffer + 0.5) {
        _healthFalls = 0;
    }

    _healthBuffer = health;

    NSLog(@"[YouTube/Запас] Буфер %.1f с, подача отстала от края на %.0f с, "
          @"набрано до %.0f с, ход %@",
          health,
          [proxy liveLagSeconds],
          [proxy liveFilledSeconds],
          [_player rate] > 0 ? @"идёт" : @"стоит");
}

/**
 * Берём свежую подачу эфира и подменяем её под показом.
 *
 * Это замена жёсткому перезапуску. Оживляет застрявший эфир только новый
 * `/player` — это видно в журналах 41, 42, 45 и 48, — но добывать его
 * ценой пересборки плеера незачем: рывок и повтор последнего куска человек
 * видит, а лечение сидит в самой подаче. Потому ходим за `/player`, строим
 * новую подачу и отдаём её прокси: список сегментов и ось времени у него
 * свои, показ ничего не замечает.
 *
 * Двенадцать секунд без куска — порог. Сторож прокси к этому времени уже
 * пересадил сессию на том же адресе (восемь секунд) и, если это не
 * помогло, дело именно в адресе.
 */
- (void)renewLiveFeedIfStuck {
    YTHlsProxy *proxy = [YTHlsProxy shared];

    if (![proxy isLive] || _broadcastResuming || _playerJson == nil) {
        return;
    }

    NSTimeInterval starved = [proxy liveStarvedSeconds];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    /**
     * Пока запаса мало — вмешиваемся втрое быстрее.
     *
     * Журнал 58: начало показа стоило шестидесяти пяти секунд, и ушли они
     * на ожидание. Сервер на просьбу с края минус девяносто отдал короткую
     * пачку (семь кусков, 3144855-3144861) и замолчал; мы ждали двенадцать
     * секунд до подмены, и так три раза подряд. Когда буфер уже полон,
     * такое ожидание ничего не стоит — оно укрыто запасом. А когда запаса
     * нет, каждая секунда ожидания видна человеку.
     *
     * Потому порог двойной: при полном запасе двенадцать секунд, при
     * пустом — четыре, и повтор не через двадцать секунд, а через восемь.
     */
    /**
     * Торопимся не только на пустом запасе, но и на убывающем.
     *
     * Журнал 59: пуск вылечен (девять секунд до полного запаса вместо
     * шестидесяти пяти), но просадка протянулась девяносто пять секунд.
     * Начиналась она при запасе в пятьдесят секунд и сползала три
     * четверти минуты — а быстрый порог включался лишь ниже двадцати,
     * то есть когда почти всё уже потеряно.
     *
     * Потому спешим и тогда, когда запас ещё велик, но третий замер
     * кряду идёт вниз: это и значит, что подача не поспевает, и ждать
     * двенадцать секунд незачем. Порог в сорок пять секунд — чуть ниже
     * обычного рабочего значения (пятьдесят-пятьдесят пять), чтобы
     * мелкое колебание ровного хода не считалось просадкой.
     */
    BOOL thin = (_healthBuffer < 20.0)
        || (_healthBuffer < 45.0 && _healthFalls >= 3);

    /**
     * Порог тишины не может быть короче промежутка между кусками.
     *
     * Здесь стояли четыре секунды, и это была прямая ошибка: у эфира
     * кусок нарезается раз в пять секунд, значит четыре секунды тишины —
     * обычное состояние здоровой подачи. Журнал 61 показал цену:
     * одиннадцать подмен за две с половиной минуты при отставании ноль и
     * набранном, растущем ровно в реальном времени. Подача была
     * совершенно здорова, а мы меняли её каждые восемь секунд и тем
     * самым не давали ей работать — буфер стёк с 54,7 до нуля и остался
     * там, хотя ни одной причины для этого не было.
     *
     * Теперь и быстрый порог с запасом больше такта нарезки. Спешка
     * остаётся (восемь секунд против двенадцати, повтор через двенадцать
     * вместо двадцати), но здоровую паузу за беду мы больше не считаем.
     */
    /**
     * Тревога «подача молчит» — не раньше двадцати секунд.
     *
     * Журнал 90: запрос к серверу теперь держится открытым до восьми
     * секунд (девяносто процентов укладываются в 5,2 с, самый долгий —
     * 7,98 с), и тревога на восьмой секунде срабатывала посреди живого
     * запроса — в 20:27:14 через секунду после ответа с тремя кусками.
     * Каждая такая тревога заводила свежую подачу, и все одиннадцать
     * свежих подач за сеанс кончились строкой «не собралась»: у края
     * сервер отвечает им указанием продолжить со следующего куска и
     * нулём байт. Свежая подача у эфира — не лекарство, а лишний рывок.
     *
     * Двадцать секунд — это четыре куска, заведомо дольше любого
     * удержания запроса. И только при тонком запасе: с толстым ждать
     * можно и дольше, а дёргаться незачем.
     */
    NSTimeInterval needSilence = thin ? 20.0 : 30.0;
    NSTimeInterval needPause = thin ? 30.0 : 45.0;

    /**
     * Набор запаса на ходу отменён — он не работает.
     *
     * В 1.4-123 я пересаживал подачу за минуту до края, когда запас тонок.
     * Журнал 68: сработало восемь раз, буфер как стоял на двадцати трёх,
     * так и остался — восемь минут ровной полки. Садясь назад, мы
     * перекачиваем уже проигранное, а список append-only, и плееру оно
     * не нужно. Запас набирается только до старта (см. `openLiveWithSabr:`).
     */
    if (starved < needSilence || now - _feedRenewAt < needPause || _feedRenewing) {
        return;
    }

    _feedRenewAt = now;
    _feedRenewing = YES;

    NSString *videoId = [_videoId copy];
    NSInteger cap = _maxHeight;
    NSString *track = [_audioTrack copy];
    BOOL exact = (_pickedHeight > 0);

    NSLog(@"[YouTube/Плеер] Подача молчит %.0f с — берём свежую, показ не трогаем",
          starved);

    /**
     * Живой хвост продолжаем, мёртвый обходим — как и пересадка.
     *
     * Журнал 56: просадка тянулась две минуты, и оборвала её строка
     * «Подача молчит 100 с — берём свежую», хотя порог у нас двенадцать
     * секунд и подачи до неё брались трижды. Причина в месте: подсказка
     * ставилась на хвост набранного, а хвост был застрявший — сервер
     * отказывал ровно там, и каждая новая подача упиралась в ту же точку.
     *
     * Порог поставил двадцать пять секунд — и это оказалось много. Журнал
     * 57: подмены в просадке срабатывали вовремя, на двенадцатой,
     * семнадцатой и девятнадцатой секунде молчания, но строка «сажаем к
     * краю» не появилась ни разу: отставание к тому мгновению было
     * пятнадцать-двадцать секунд. Все три подачи сели на застрявший хвост,
     * и просадка всё равно протянулась полторы минуты.
     *
     * Рассуждение простое: подачу мы берём **потому**, что нынешняя молчит
     * двенадцать секунд. Значит её место не работает, и садиться туда же
     * бессмысленно почти всегда. Порог снижен до десяти секунд — при
     * двенадцати секундах молчания отставание столько и набирает.
     */
    NSTimeInterval filled = [proxy liveFilledSeconds];
    NSTimeInterval lag = [proxy liveLagSeconds];
    NSTimeInterval resumeAt = filled;

    if (filled > 0 && lag > 10.0) {
        resumeAt = MAX(0.0, filled + lag - 40.0);

        NSLog(@"[YouTube/Плеер] Хвост отстал на %.0f с — свежую подачу сажаем "
              @"к краю, на %.0f с", lag, resumeAt);
    }

    YTAsync(^{
        NSDictionary *player = [YTApi playerResponse:videoId];

        /**
         * Место называем **до** постройки: первая просьба делается внутри
         * `sabrFor:`, и опоздав, мы заставляем новую подачу перекачивать
         * девяносто секунд, которые у раздачи уже есть (журнал 51).
         */
        // Свежая подача должна знать, что уже набрано: иначе сервер молчит.
        [YTStreams setNextSabrLiveFrom:[[YTHlsProxy shared] liveSabr]];

        if (resumeAt > 0) {
            [YTStreams setNextSabrLiveStart:(lag > 10.0)
                ? resumeAt
                : MAX(0.0, resumeAt - 10.0)];
        }

        YTSabr *sabr = (player != nil)
            ? [YTStreams sabrFor:player maxHeight:cap audioTrack:track exact:exact]
            : nil;

        BOOL ok = (sabr != nil) && [[YTHlsProxy shared] renewLiveSabr:sabr];

        YTMain(^{
            _feedRenewing = NO;

            if (ok && player != nil) {
                _playerJson = player;
            } else {
                NSLog(@"[YouTube/Плеер] Свежая подача не собралась (%@) — "
                      @"оставляем старую",
                      (player == nil) ? @"ответа нет"
                        : (sabr == nil ? @"первый кусок не пришёл"
                                       : @"раздача не приняла"));
            }
        });
    });
}

- (void)watchStall {
    if (_player == nil) {
        return;
    }

    [self logPlaybackStats];
    [self noteLiveHealth];
    [self renewLiveFeedIfStuck];

    NSTimeInterval now = [self currentSeconds];

    BOOL playing = ([_player rate] > 0);
    BOOL moved = (now > _stallSeen + 0.01);

    _stallSeen = now;

    if (!playing || moved) {
        _stalledFor = 0;

        // Эфир пошёл — надпись об остановке снимаем.
        if (_liveStallNoted) {
            _liveStallNoted = NO;

            [_status setText:nil];
        }

        // Картинка идёт из запаса, а подача уже молчит — спасаем заранее.
        if (playing) {
            [self restartLiveIfStarved];
        }

        if (_stalled) {
            _stalled = NO;

            [_busy stop];
        }

        return;
    }

    _stalledFor += 0.25;

    [self checkBroadcastOver];
    [self rescueLiveStall];

    if (_stalledFor >= 0.5 && !_stalled) {
        _stalled = YES;

        [_busy start];
    }

    /**
     * Шесть секунд без движения — спускаемся на ступень ниже сами.
     *
     * Прежде это делал сервер, и делал молча, посреди ролика: качество
     * ехало вниз вместе с разрешением, а декодер оставался настроен
     * на прежнее. Теперь дорожка закреплена, спуск — наше решение,
     * и после него элемент пересоздаётся: декодер заводится начисто.
     *
     * Трёх спусков хватает на любую сеть: ниже начинается разрешение,
     * при котором смотреть уже нечего, а дёргать поток дальше — только
     * мешать.
     */
    if (_stalledFor >= 6.0 && _stepDowns < 3) {
        _stalledFor = 0;

        if ([[YTHlsProxy shared] stepDownVideo]) {
            _stepDowns++;
        }
    }
}

- (void)observeValueForKeyPath:(NSString *)path
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    /**
     * Уведомление приходит **не с главного потока**: KVO у
     * `AVPlayerItem.status` срабатывает на внутренней очереди AVFoundation.
     * Поэтому здесь только читается состояние, а всё, что касается видов,
     * уходит на главный поток. UIKit из чужого потока — это не «иногда
     * мигает», это падение.
     */
    if (object != _observedItem) {
        return;
    }

    AVPlayerItemStatus status = [_observedItem status];

    YTMain(^{
        if (status == AVPlayerItemStatusFailed) {
            NSLog(@"[YouTube/Плеер] Поток не открылся: %@",
                  [[_observedItem error] localizedDescription]);

            /**
             * Один повтор, если раздача отказала из-за сменившегося
             * выхода в сеть.
             *
             * Ссылка подписана вместе с адресом просителя, а раздающий
             * пул выдаёт каждому соединению свой адрес — какой попадётся.
             * Ссылку выдаёт `youtube.com`, байты лежат на `googlevideo.com`,
             * и это разные соединения: совпадут адреса или нет — дело
             * случая. Взяв ссылку заново, мы просто бросаем жребий ещё
             * раз, и на пуле из нескольких адресов это заметно помогает.
             *
             * Повтор один: если не везёт и со второй попытки, дело
             * не в случайности, и долбить сервер незачем.
             */
            if ([[YTHlsProxy shared] refusedByAddress]) {
                if (_refusalRetries < 3) {
                    _refusalRetries++;

                    NSLog(@"[YouTube/Плеер] Берём ссылку заново: адрес сменился "
                          @"(попытка %ld из 3)", (long)_refusalRetries);

                    [_status setText:@""];
                    [_busy start];

                    [self load];

                    return;
                }

                /**
                 * Три раза подряд — уже не случайность.
                 *
                 * Ссылку раздача подписывает на тот выход в сеть, с которого
                 * её выдали, и сверяет при каждом обращении. Когда выход
                 * меняется от запроса к запросу — а через VPN с общим
                 * выходом так и бывает, — новая ссылка устаревает раньше,
                 * чем мы успеваем ею воспользоваться. Своими силами тут
                 * не справиться: помочь может только человек.
                 */
                [_busy stop];
                [_status setText:YTLoc(@"Поток не загрузился")];
                [[self view] setNeedsLayout];

                [self showAddressWarning];

                return;
            }

            [_busy stop];
            [_status setText:YTLoc(@"Поток не загрузился")];
            [[self view] setNeedsLayout];

            return;
        }

        if (status == AVPlayerItemStatusReadyToPlay) {
            // Адрес расшифрован и играет — решатель своё отработал.
            [[YTNSig shared] streamStarted];

            /**
             * Плеер готов — значит, и перемотка, назначенная при смене
             * качества, уже состоялась или вот-вот состоится. Дальше
             * время можно показывать по нему.
             */
            _awaitingSeek = NO;

            /**
             * Ролик пошёл — отмечаем его просмотренным.
             *
             * Отдельного запроса «добавить в историю» у InnerTube нет:
             * просмотр считается по служебным сигналам, адреса которых
             * приходят в самом ответе `/player`. Делается это один раз
             * за ролик и на своём потоке: к показу оно отношения
             * не имеет, а ждать его незачем.
             */
            if (!_watchReported && [self trackingJson] != nil) {
                _watchReported = YES;

                NSDictionary *json = [self trackingJson];

                YTAsync(^{ [YTApi reportWatched:json position:0]; });

                [self startWatchReports];
            }

            // Ролик пошёл — отсчёт до скрытия пульта начинается заново.
            [self scheduleHide];

            _duration = [[YTHlsProxy shared] duration];

            /**
             * У склеенного потока длительности прокси не знает: плейлиста
             * он не собирал, а просто передаёт чужой mp4. Тогда её берём
             * у самого плеера — он прочитал её из заголовка файла.
             *
             * Без этого полоса перемотки оставалась пустой и перемотка
             * не работала вовсе: она считает цель как долю от длительности,
             * а доля от нуля — всегда ноль.
             */
            if (_duration <= 0) {
                CMTime known = [_observedItem duration];

                if (CMTIME_IS_NUMERIC(known)) {
                    _duration = CMTimeGetSeconds(known);
                }
            }

            [_busy stop];
            [self updateProgress];
        }
    });
}

/**
 * Дорожка сменилась — заводим декодер начисто.
 *
 * Элемент пересоздаётся на том же адресе прокси: сессия подачи жива,
 * ходить в сеть заново не нужно. Со стороны это выглядит как короткая
 * заминка вместо рассыпающейся картинки.
 */
- (void)restartForTrackChangeAt:(NSTimeInterval)resume {
    if (_player == nil || [_streamUrl length] == 0) {
        return;
    }

    NSLog(@"[YouTube/Плеер] Дорожка сменилась — перезаводим декодер "
          @"с %.1f с", resume);

    _awaitingSeek = YES;
    _seekTarget = resume;

    NSString *url = _streamUrl;

    [[YTHlsProxy shared] forgetShownTrack];

    [self teardownPlayer];
    [self startPlayer:url];

    if (resume > 1) {
        /**
         * Цель — чуть внутрь куска новой дорожки, и допуск узкий.
         *
         * Место перезавода — граница кусков. Без допусков плеер вправе
         * встать на ближайший ключевой кадр *до* цели, а до стыка ровно
         * в 8.91 с таким оказывалось начало предыдущего куска: показ
         * откатывался на пять секунд назад. Первый кадр куска подачи —
         * ключевой, поэтому десятой секунды внутрь хватает, чтобы плеер
         * взял нужный кусок и начал с его начала.
         *
         * Без обработчика завершения: элемент создан мгновение назад
         * и к воспроизведению ещё не готов — с обработчиком это
         * исключение и падение.
         */
        CMTime slack = CMTimeMakeWithSeconds(0.1, 600);

        [_player seekToTime:CMTimeMakeWithSeconds(resume + 0.1, 600)
            toleranceBefore:slack
             toleranceAfter:slack];
    } else {
        _awaitingSeek = NO;
    }
}

- (void)tick {
    /**
     * Место показа — в незакрытую запись просмотра, раз в пять секунд.
     *
     * Если приложение снимут посреди ролика (iPad 1, нехватка памяти),
     * при следующем запуске запись дошлётся с этим местом (YTApi,
     * flushPendingWatch). Чаще незачем: это запись на диск.
     */
    NSTimeInterval clock = [NSDate timeIntervalSinceReferenceDate];

    if (_watchReported && !_watchClosed && [_player rate] > 0 &&
        clock - _pendingNotedAt >= 5.0) {
        _pendingNotedAt = clock;

        NSTimeInterval shown = CMTimeGetSeconds([_player currentTime]);
        NSString *videoId = _videoId;

        if (shown > 0 && ![[YTHlsProxy shared] isLive]) {
            YTAsync(^{ [YTApi notePendingWatchPosition:shown video:videoId]; });
        }
    }

    /**
     * Перезавод откладываем на следующий проход цикла.
     *
     * Сюда мы попадаем из наблюдателя времени, то есть из блока, который
     * держит сам плеер, — а перезавод этот плеер разбирает вместе с его
     * наблюдателями. Снимать наблюдателя изнутри его же вызова нельзя.
     */
    /**
     * Пока идёт перемотка, время плеера ещё прежнее — спрашивать по нему
     * о смене дорожки нельзя: ответ был бы про место, откуда уходим.
     */
    NSTimeInterval change = (_seeking || _awaitingSeek)
        ? -1 : [[YTHlsProxy shared] trackChangeAt:[self currentSeconds]];

    if (change >= 0) {
        __weak YTPlayerViewController *weak = self;

        dispatch_async(dispatch_get_main_queue(), ^{
            [weak restartForTrackChangeAt:change];
        });

        return;
    }

    if (_seeking) {
        return;
    }

    /**
     * Пока перемотка не закончилась, показываем цель, а не то, что
     * говорит плеер: он до последнего отвечает прежним временем.
     */
    if (_awaitingSeek) {
        [self showTime:_seekTarget];

        return;
    }

    /**
     * Индикатор ожидания снимается по движению кадра, а не по
     * `playbackLikelyToKeepUp`: тот отвечает на другой вопрос — «хватит ли
     * запаса, чтобы доиграть без остановок», — и на неспешном канале
     * остаётся отрицательным всё время, пока видео прекрасно идёт.
     */
    if ([_player rate] > 0) {
        [_busy stop];
    }

    [self updateProgress];

    NSTimeInterval now = [self currentSeconds];

    [self skipSponsorAt:now];
    [self showSubtitlesAt:now];
}

/**
 * Прыжок через рекламную вставку — порт `SkipCheckTimer_Tick`.
 *
 * Только во время обычного хода: пока тянут полосу или ждут перемотку,
 * местом распоряжается человек, и выдёргивать его оттуда нельзя.
 */
- (void)skipSponsorAt:(NSTimeInterval)now {
    if ([_sponsorSegments count] == 0 || _seeking || _awaitingSeek ||
        [_player rate] <= 0) {

        return;
    }

    for (YTSponsorSegment *segment in _sponsorSegments) {
        if (now < segment.start || now >= segment.end) {
            continue;
        }

        /**
         * Уже прыгали сюда — значит, перемотка ещё не доехала. Второй
         * прыжок в то же место только сбил бы её.
         */
        if (_lastSkippedTo == segment.end) {
            return;
        }

        _lastSkippedTo = segment.end;

        NSLog(@"[YouTube/SponsorBlock] Пропускаем %@: %.0f→%.0f с",
              segment.category, segment.start, segment.end);

        // Тем же путём, что и всё прочее: прыжок на ходу разваливает поток.
        [self seekTo:segment.end];

        [self showNotice:YTLoc(@"Реклама пропущена")];

        return;
    }
}

/** Ставит поверх кадра реплику, приходящуюся на это время. */
- (void)showSubtitlesAt:(NSTimeInterval)now {
    if (_subtitleLabel == nil) {
        return;
    }

    if ([_subtitleCues count] == 0) {
        [_subtitleLabel setHidden:YES];

        return;
    }

    /**
     * Смотрим чуть вперёд — на величину смещения из настроек.
     *
     * Реплика должна появляться немного раньше, чем её произнесут:
     * её сперва читают. Плюс к тому поток идёт через нашу подачу
     * и склейку, и время у плеера отстаёт от времени в дорожке —
     * поправка гасит и это. Так же в оригинале: `position += SubtitleLeadOffset`.
     */
    now += [YTSettings subtitleOffset];

    NSString *text = nil;

    for (YTSubtitleCue *cue in _subtitleCues) {
        if (now >= cue.start && now < cue.end) {
            text = cue.text;
            break;
        }

        // Реплики идут по возрастанию: дальше уже поздние.
        if (cue.start > now) {
            break;
        }
    }

    [_subtitleLabel setText:text ?: @""];
    [_subtitleLabel setHidden:([text length] == 0)];

    [self layoutSubtitles];
}

/**
 * Кладёт строку субтитров на её место.
 *
 * Место хранится долями от размера кадра, а не точками: кадр меняет
 * размер при повороте и при развороте на весь экран, и в точках строка
 * уезжала бы за край. От долей же она всегда возвращается на видное
 * место, а если по новым размерам всё же вылезает — её подтягивают
 * обратно к краю.
 *
 * Считается тут, а не в общей раскладке: строка появляется и меняется
 * между её проходами, и ждать следующего значило бы показывать её
 * то не там, то никак.
 */
- (void)layoutSubtitles {
    if (_subtitleLabel == nil || [_subtitleLabel isHidden]) {
        return;
    }

    CGRect box = [_stage bounds];

    if (box.size.width <= 0 || box.size.height <= 0) {
        return;
    }

    // В развёрнутом кадре крупнее — так же в оригинале.
    [_subtitleLabel setFont:YTFontSemiBold(_fullscreenMode ? 18 : 15)];

    CGFloat side = 12;
    CGFloat limit = box.size.width - side * 2;

    CGFloat height = YTTextHeight([_subtitleLabel text], [_subtitleLabel font],
                                  limit - 12, 3) + 8;

    CGSize text = [[_subtitleLabel text] sizeWithFont:[_subtitleLabel font]
                                    constrainedToSize:CGSizeMake(limit - 12, 1000)
                                        lineBreakMode:NSLineBreakByWordWrapping];

    CGFloat width = MIN(limit, ceil(text.width) + 16);

    CGFloat centerX = box.size.width * [YTSettings subtitlePlaceX];
    CGFloat centerY = box.size.height * [YTSettings subtitlePlace];

    CGFloat left = centerX - width / 2;
    CGFloat top = centerY - height / 2;

    // За край не пускаем: строка должна остаться видимой при любом повороте.
    if (left < side) { left = side; }
    if (top < side) { top = side; }

    if (left + width > box.size.width - side) {
        left = box.size.width - side - width;
    }

    if (top + height > box.size.height - side) {
        top = box.size.height - side - height;
    }

    [_subtitleLabel setFrame:CGRectMake(left, top, width, height)];
}

/** Протяг по строке субтитров — она переезжает и запоминает новое место. */
- (void)moveSubtitles:(UIPanGestureRecognizer *)gesture {
    CGRect box = [_stage bounds];

    if (box.size.width <= 0 || box.size.height <= 0) {
        return;
    }

    CGPoint shift = [gesture translationInView:_stage];
    CGPoint place = [_subtitleLabel center];

    place.x += shift.x;
    place.y += shift.y;

    [gesture setTranslation:CGPointZero inView:_stage];

    [YTSettings setSubtitlePlaceX:place.x / box.size.width];
    [YTSettings setSubtitlePlace:place.y / box.size.height];

    [self layoutSubtitles];

    // Пока таскают субтитры, пульт прятаться не должен: он бы уехал
    // из-под пальца вместе с ними.
    [self scheduleHide];
}

/** Подпись сдвига: «+1,00 с» — со знаком, чтобы направление было видно. */
- (NSString *)subtitleOffsetTitle {
    double offset = [YTSettings subtitleOffset];

    return YTLocF(@"%@%.2f с", offset >= 0 ? @"+" : @"", offset);
}

- (void)nudgeSubtitles:(double)delta {
    [self setSubtitleOffset:[YTSettings subtitleOffset] + delta];
}

- (void)setSubtitleOffset:(double)seconds {
    [YTSettings setSubtitleOffset:seconds];

    NSLog(@"[YouTube/Субтитры] Сдвиг: %@", [self subtitleOffsetTitle]);

    // Строку перекладываем сразу, не дожидаясь следующей реплики.
    [self showSubtitlesAt:[self currentSeconds]];
    [self buildMenu];
}

/** Выбрана дорожка субтитров — или «выключены». */
- (void)pickSubtitles:(YTSubtitleTrack *)track {
    [self hideMenu];

    _subtitleTrack = track;
    _subtitleCues = nil;

    [_subtitleLabel setHidden:YES];

    if (track == nil) {
        NSLog(@"[YouTube/Субтитры] Выключены");

        return;
    }

    NSInteger generation = [_loadGeneration current];

    YTAsync(^{
        NSArray *cues = [YTSubtitles cuesFor:track];

        YTMain(^{
            // Пока ходили в сеть, могли открыть другой ролик или снять выбор.
            if (![_loadGeneration isCurrent:generation] || _subtitleTrack != track) {
                return;
            }

            _subtitleCues = cues;

            [self showSubtitlesAt:[self currentSeconds]];
        });
    });
}

- (NSTimeInterval)currentSeconds {
    CMTime time = [_player currentTime];

    Float64 seconds = CMTimeGetSeconds(time);

    // У только что созданного или сорвавшегося плеера время бывает
    // неопределённым — приведение NaN к целому не определено вовсе.
    if (isnan(seconds) || isinf(seconds) || seconds < 0) {
        return 0;
    }

    return seconds;
}

/**
 * Время в том же виде, что в оригинале: «0:00 / 0:00», а у длинных роликов
 * с часами. Минуты при часах дополняются нулём, при их отсутствии — нет.
 */
- (NSString *)clock:(NSTimeInterval)seconds {
    NSInteger total = (NSInteger)seconds;

    NSInteger hours = total / 3600;
    NSInteger minutes = (total % 3600) / 60;
    NSInteger rest = total % 60;

    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld",
                (long)hours, (long)minutes, (long)rest];
    }

    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)rest];
}

- (void)updateProgress {
    [self showTime:[self currentSeconds]];
}

/**
 * Название главы, в которую попадает этот миг; nil, если глав нет.
 *
 * Подходит последняя из начавшихся — метки идут по возрастанию, но
 * порядок в описании никто не гарантирует, поэтому берётся не первая
 * подходящая, а самая поздняя. Так же поступает `GetChapterTitleAt`
 * в оригинале.
 */
- (NSString *)chapterTitleAt:(NSTimeInterval)position {
    NSString *title = nil;
    double best = -1;

    for (NSDictionary *chapter in _chapters) {
        NSString *name = [chapter objectForKey:@"title"];

        if ([name length] == 0) {
            continue;
        }

        double start = [[chapter objectForKey:@"start"] doubleValue];

        if (start <= position && start >= best) {
            best = start;
            title = name;
        }
    }

    return title;
}

/**
 * Подпись под кадром: «12:34 / 45:67 · Название главы».
 *
 * Точка-разделитель и порядок — из `BuildTimeDisplayText` оригинала;
 * глава дописывается только тогда, когда она есть.
 */
- (NSString *)timeTextAt:(NSTimeInterval)position {
    NSString *text = [NSString stringWithFormat:@"%@ / %@",
        [self clock:position], [self clock:_duration]];

    NSString *chapter = [self chapterTitleAt:position];

    if ([chapter length] == 0) {
        return text;
    }

    return [NSString stringWithFormat:@"%@ · %@", text, chapter];
}

/** Рисует полосу и подпись для заданного времени. */
- (void)showTime:(NSTimeInterval)now {
    [_time setText:[self timeTextAt:now]];

    // Подпись под заголовком глав идёт за ходом ролика.
    [self refreshChapterHeader];

    [self layoutTimePill];
    [self placeProgress:(_duration > 0 ? now / _duration : 0)];
}

- (void)placeProgress:(double)share {
    if (share < 0) { share = 0; }
    if (share > 1) { share = 1; }

    CGRect box = [_track frame];

    [_trackFill setFrame:CGRectMake(box.origin.x, box.origin.y,
                                    box.size.width * share, box.size.height)];

    [_thumb setCenter:CGPointMake(box.origin.x + box.size.width * share,
                                  box.origin.y + box.size.height / 2)];

    [self layoutMarks];
}

/**
 * Отметки на полосе: разрывы между главами и цвет у рекламных вставок.
 *
 * Рисуются накладками поверх полосы, а не отдельным видом: полоса
 * и её заливка уже есть, и вмешиваться в них ради разметки незачем.
 * Виды заводятся один раз и переиспользуются — полоса двигается
 * по нескольку раз в секунду.
 */
- (void)layoutMarks {
    CGRect box = [_track frame];

    if (box.size.width <= 0 || _duration <= 0) {
        /**
         * Раскладка ещё не случилась или длительность неизвестна —
         * ставить отметки не на что. Строка нужна затем, что снаружи
         * это выглядит так же, как «вставок не нашлось».
         */
        if ([_sponsorSegments count] > 0) {
            NSLog(@"[YouTube/SponsorBlock] Отметки некуда ставить: полоса %.0f, "
                  @"длительность %.0f", box.size.width, _duration);
        }

        return;
    }

    if (_marks == nil) {
        _marks = [NSMutableArray array];
    }

    NSUInteger used = 0;

    // Вставки — цветом поверх полосы, как их метит сам SponsorBlock.
    for (YTSponsorSegment *segment in _sponsorSegments) {
        CGFloat from = box.origin.x + box.size.width * (segment.start / _duration);
        CGFloat to = box.origin.x + box.size.width * (segment.end / _duration);

        UIView *mark = [self markAt:used++];

        [mark setBackgroundColor:YTColor(0x00D400)];
        [mark setFrame:CGRectMake(from, box.origin.y,
                                  MAX((CGFloat)1, to - from), box.size.height)];

        /**
         * По одной строке на вставку и только при первой раскладке
         * этого ролика: полоса перекладывается по нескольку раз
         * в секунду, и без оговорки журнал стал бы нечитаем.
         */
        if (!_sponsorMarksLogged) {
            NSLog(@"[YouTube/SponsorBlock] Отметка %.0f–%.0f с → x %.0f ширина %.0f "
                  @"(полоса %.0f…%.0f)",
                  segment.start, segment.end, from, MAX((CGFloat)1, to - from),
                  box.origin.x, box.origin.x + box.size.width);
        }
    }

    if ([_sponsorSegments count] > 0) {
        _sponsorMarksLogged = YES;
    }

    // Главы — тонкие разрывы фоном страницы: так их показывает и оригинал.
    for (NSDictionary *chapter in _chapters) {
        double seconds = [[chapter objectForKey:@"start"] doubleValue];

        // Разрыв в самом начале полосы рисовать негде и незачем.
        if (seconds <= 0 || seconds >= _duration) {
            continue;
        }

        UIView *mark = [self markAt:used++];

        [mark setBackgroundColor:[UIColor blackColor]];
        [mark setFrame:CGRectMake(box.origin.x + box.size.width * (seconds / _duration) - 1,
                                  box.origin.y, 2, box.size.height)];
    }

    for (NSUInteger i = used; i < [_marks count]; i++) {
        [[_marks objectAtIndex:i] setHidden:YES];
    }
}

/** Накладка под номером; заводит новую, если такой ещё не было. */
- (UIView *)markAt:(NSUInteger)index {
    while ([_marks count] <= index) {
        UIView *mark = [[UIView alloc] initWithFrame:CGRectZero];

        [mark setUserInteractionEnabled:NO];

        // Под бегунком, но над полосой и её заливкой.
        [_overlay insertSubview:mark aboveSubview:_trackFill];
        [_marks addObject:mark];
    }

    UIView *mark = [_marks objectAtIndex:index];

    [mark setHidden:NO];

    return mark;
}

- (void)playbackFinished {
    /**
     * Тот же чужой поток, что и у Shorts: значок повтора, показ управления
     * и остановка кольца — всё это UIKit, и делать это не из главного
     * потока нельзя.
     */
    if (![NSThread isMainThread]) {
        YTMain(^{ [self playbackFinished]; });

        return;
    }

    _finished = YES;
    _meantToPlay = NO;

    // Ролик доигран — закрываем запись просмотра последним отрезком.
    [self stopWatchReports:YES];

    /**
     * Кольцо ожидания гасим: ролик доиграл, ждать больше нечего.
     *
     * Без этого оно оставалось крутиться поверх значка повтора — если
     * было запущено перемоткой или загрузкой и никто его не остановил.
     * Со стороны это выглядит как «ролик кончился, а он всё грузится».
     */
    [_busy stop];

    [_playPause setImage:YTDarkIcon(@"pl_replay") forState:UIControlStateNormal];
    [self showControls];

    [self playNextInQueue];
}

/**
 * Следующий ролик очереди, когда нынешний доиграл.
 *
 * Только внутри подборки: одиночный ролик ни во что не переходит — в этом
 * приложении нет «автовоспроизведения похожих», и подсовывать человеку
 * что попало незачем. У микса очередь к этому времени уже дописана: она
 * растёт, когда играет последний в ней ролик, — то есть как раз сейчас.
 */
- (void)playNextInQueue {
    if (![YTSettings autoplayNextInQueue] || [_queue count] == 0) {
        return;
    }

    NSInteger place = [self indexOfVideo:_videoId in:_queue];

    if (place < 0 || place + 1 >= (NSInteger)[_queue count]) {
        NSLog(@"[YouTube/Очередь] Ролик доиграл, следующего нет");

        return;
    }

    YTVideoItem *next = [_queue objectAtIndex:(NSUInteger)(place + 1)];

    NSLog(@"[YouTube/Очередь] Ролик доиграл, включаем следующий: %@", next.title);

    [self openQueueItem:next.videoId title:next.title];
}

/**
 * Снимает наблюдателей с плеера, **не** останавливая воспроизведение.
 *
 * Отдельно от `teardownPlayer` это нужно при сворачивании: плеер уходит
 * жить в мини-окно, а страница — из стопки. Наблюдатели при этом должны
 * уйти вместе со страницей, иначе они переживут её.
 *
 * Чем это кончается, видно на iOS 8: когда мини-окно закрывают, плеер
 * с элементом освобождаются, система сверяет, не остались ли на них
 * наблюдатели, находит наши — и валит приложение с «был освобождён,
 * пока на нём ещё висели наблюдатели». На iOS 6 такой проверки нет,
 * и там всё сходило с рук.
 */
- (void)detachPlayerObservers {
    [self stopStallWatch];

    if (_timeObserver != nil) {
        [_player removeTimeObserver:_timeObserver];
        _timeObserver = nil;
    }

    /**
     * Наблюдатель снимается с явно запомненного элемента, а не
     * с `[_player currentItem]`: к этому моменту текущим может оказаться
     * уже другой, и снятие ушло бы не туда.
     */
    if (_observedItem != nil) {
        if (_observingStatus) {
            [_observedItem removeObserver:self forKeyPath:@"status"];

            _observingStatus = NO;
        }

        [[NSNotificationCenter defaultCenter]
            removeObserver:self
                      name:AVPlayerItemDidPlayToEndTimeNotification
                    object:_observedItem];

        _observedItem = nil;
    }
}

/**
 * Запись просмотра ведётся отрезками, пока ролик идёт.
 *
 * Первые три отметки через десять секунд, дальше через сорок — так же,
 * как в дампе настоящего клиента. Реже нельзя: оборвись показ между
 * отметками, потерянным окажется весь промежуток.
 */
- (void)startWatchReports {
    [self stopWatchReports:NO];

    _watchSegmentFrom = 0;
    _watchSegmentAt = [NSDate timeIntervalSinceReferenceDate];
    _watchPings = 0;
    _watchClosed = NO;

    _watchTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                   target:self
                                                 selector:@selector(reportWatchSegment)
                                                 userInfo:nil
                                                  repeats:YES];
}

- (void)reportWatchSegment {
    if (_player == nil || [self trackingJson] == nil || [_player rate] <= 0) {
        return;
    }

    _watchPings++;

    // После трёх отметок подряд переходим на сорок секунд, как в дампе.
    if (_watchPings == 3) {
        [_watchTimer invalidate];

        _watchTimer = [NSTimer scheduledTimerWithTimeInterval:40.0
                                                       target:self
                                                     selector:@selector(reportWatchSegment)
                                                     userInfo:nil
                                                      repeats:YES];
    }

    [self sendWatchSegmentFinal:NO];
}

/** Отрезок от прошлой отметки до нынешнего места показа. */
/** Откуда брать адреса сигналов просмотра (см. `_trackingJson`). */
- (NSDictionary *)trackingJson {
    return _trackingJson != nil ? _trackingJson : _playerJson;
}

- (void)sendWatchSegmentFinal:(BOOL)final {
    if ([self trackingJson] == nil || !_watchReported || _watchClosed) {
        return;
    }

    if (final) {
        _watchClosed = YES;
    }

    NSTimeInterval at = CMTimeGetSeconds([_player currentTime]);

    if (!(at > 0)) {
        at = _watchSegmentFrom;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval spent = MAX(0.0, now - _watchSegmentAt);

    if (!final && at <= _watchSegmentFrom + 0.5) {
        return;
    }

    NSDictionary *json = [self trackingJson];
    NSTimeInterval from = _watchSegmentFrom;

    _watchSegmentFrom = at;
    _watchSegmentAt = now;

    YTAsync(^{
        [YTApi reportWatched:json position:at from:from elapsed:spent final:final];
    });
}

/** Мини-окно закрывают — запись просмотра закрываем тоже (см. YTMiniPlayer). */
- (void)miniPlayerWillClose {
    [self stopWatchReports:_watchReported];
}

/** Запись закрываем: ролик доигран или мы уходим с него. */
- (void)stopWatchReports:(BOOL)closing {
    [_watchTimer invalidate];
    _watchTimer = nil;

    if (closing) {
        [self sendWatchSegmentFinal:YES];
    }
}

- (void)teardownPlayer {
    [self stopWatchReports:_watchReported];


    // Ожидание объявленной трансляции плеера не переживает.
    [self stopBroadcastWait];

    [self detachPlayerObservers];

    [_player pause];
    [_playerLayer removeFromSuperlayer];

    _playerLayer = nil;
    _player = nil;
    _playingAdopted = NO;

    /**
     * Карточку убираем здесь, а не при уходе со страницы: свёрнутый
     * в окно ролик страницу как раз и переживает, и его карточка должна
     * остаться. Сюда мы попадаем только когда плеера не стало совсем.
     */
    [YTNowPlaying clear];
    [YTNowPlaying releaseCommands];
}

#pragma mark Пульт

- (void)stageTapped {
    if (_controlsVisible) {
        [self hideControls];
    } else {
        [self showControls];
    }
}

- (void)showControls {
    _controlsVisible = YES;

    [UIView animateWithDuration:0.2 animations:^{ [_overlay setAlpha:1]; }];

    [self scheduleHide];
}

- (void)hideControls {
    /**
     * Пока плеера нет, прятать нечего — но и забывать нельзя.
     *
     * Здесь стояла одна проверка на нулевую скорость, а у ещё
     * не созданного плеера она нулевая ровно так же, как у стоящего
     * на паузе. Отсчёт заводится при появлении экрана, к его концу
     * плеер обычно ещё не готов, отсчёт кончался впустую и больше
     * не заводился — пульт оставался на кадре навсегда.
     */
    if (_player == nil) {
        [self scheduleHide];

        return;
    }

    // На паузе не прячем: убрать пульт с замершего кадра значит оставить
    // человека без кнопок вовсе.
    if ([_player rate] == 0) {
        return;
    }

    _controlsVisible = NO;

    [UIView animateWithDuration:0.2 animations:^{ [_overlay setAlpha:0]; }];
}

- (void)scheduleHide {
    [_hideTimer invalidate];

    _hideTimer = [NSTimer scheduledTimerWithTimeInterval:YTControlsTimeout
                                                  target:self
                                                selector:@selector(hideControls)
                                                userInfo:nil
                                                 repeats:NO];
}

- (void)playPauseTapped {
    if (_finished) {
        _finished = NO;

        [_player seekToTime:kCMTimeZero];
        /**
     * Скорость восстанавливается при каждом пуске: `play` всегда ставит
     * обычную, и выбранная в меню иначе терялась бы после паузы,
     * перемотки и смены качества.
     */
        [self resumeAtChosenRate];
        [_playPause setImage:YTDarkIcon(@"pl_pause") forState:UIControlStateNormal];

        [self scheduleHide];
        return;
    }

    if ([_player rate] > 0) {
        _meantToPlay = NO;

        [_player pause];
        [_playPause setImage:YTDarkIcon(@"pl_play") forState:UIControlStateNormal];
    } else {
        /**
     * Скорость восстанавливается при каждом пуске: `play` всегда ставит
     * обычную, и выбранная в меню иначе терялась бы после паузы,
     * перемотки и смены качества.
     */
        [self resumeAtChosenRate];
        [_playPause setImage:YTDarkIcon(@"pl_pause") forState:UIControlStateNormal];

        [self scheduleHide];
    }

    // Карточка на замке должна знать о паузе — ползунок там свой.
    [YTNowPlaying refreshWithPlayer:_player duration:_duration];
}

- (void)collapseTapped {
    if (_fullscreenMode) {
        [self fullscreenTapped];
        return;
    }

    /**
     * Кнопка сворачивания — именно сворачивание, а не уход.
     *
     * Плеер вместе со слоем передаётся мини-окну и продолжает играть;
     * страница уходит из стопки. Уход с закрытием — это протяжка
     * от левого края, и там ролик глушится.
     *
     * Слой переносится, а не создаётся заново: новый начал бы с чёрного
     * кадра и набирал бы буфер сызнова.
     */
    if (_player != nil) {
        _minimising = YES;

        /**
         * Наблюдатели уходят вместе со страницей — плеер живёт дальше.
         *
         * Оставить их нельзя: страница уйдёт из стопки, а подписки на
         * элемент и на ход времени останутся. На iOS 8 это кончается
         * падением при закрытии окна, когда плеер освобождают.
         */
        [self detachPlayerObservers];

        [YTMiniPlayer showWithPlayer:_player
                               layer:_playerLayer
                             videoId:_videoId
                               title:[_title text]
                               owner:self];

        _player = nil;
        _playerLayer = nil;
    }

    [YTNav pop];
}

#pragma mark Меню качества

/**
 * Меню за шестерёнкой.
 *
 * Своё, а не `UIActionSheet`: тот объявлен устаревшим с iOS 8 и на новых
 * системах ведёт себя непредсказуемо, а `UIAlertController` появился
 * только в iOS 8 — при нижней границе 5.1 пришлось бы держать два пути.
 * Здесь один вид на весь диапазон, и выглядит он как всплывающая панель
 * настроек оригинала.
 */
- (void)settingsTapped {
    [self showControls];

    if ([_menu isOpen]) {
        [self hideMenu];
        return;
    }

    _menuPage = 0;

    [self buildMenu];
    [_menu openIn:[self view]];
}

/**
 * Описание ролика — панелью снизу, как `ShowDescriptionBottomSheet`.
 *
 * Открывается нажатием по названию: в оригинале весь блок названия и есть
 * кнопка. Пустое описание не показываем — панель без единой строки только
 * сбивает с толку; вместо неё короткая надпись поверх страницы.
 */
- (void)openDescription {
    if ([_descriptionText length] == 0) {
        [self showNotice:YTLoc(@"Описания у ролика нет")];

        return;
    }

    if (_descriptionSheet == nil) {
        _descriptionSheet = [[YTSettingsSheet alloc] initWithDark:NO];
    }

    [_descriptionSheet setTitle:YTLoc(@"Описание")
                           note:[self aboutLine]
                           text:_descriptionText];

    [_descriptionSheet openIn:[self view]];
}

/**
 * Строка сведений над описанием: просмотры и когда выложили.
 *
 * Обе части приходят от сервера уже собранными под язык человека —
 * «1 234 567 просмотров» и «12 авг. 2026 г.», — поэтому склеиваем как
 * есть. Точкой их разделяет и оригинал.
 */
- (NSString *)aboutLine {
    NSMutableArray *parts = [NSMutableArray array];

    if ([_viewsText length] > 0) {
        [parts addObject:_viewsText];
    }

    NSString *when = [self publishedToday] ?: _publishedText;

    if ([when length] > 0) {
        [parts addObject:when];
    }

    return [parts componentsJoinedByString:@" · "];
}

/**
 * Сегодняшний ролик — с точным временем вместо даты, как в оригинале.
 *
 * Дату сервер отдаёт словами и без часов, а у свежего ролика интереснее
 * как раз время. Берём его из `microformat` ответа `/player`: там дата
 * записана по правилам, с часовым поясом. Если её нет или ролик не
 * сегодняшний — nil, и строкой распорядится вызывающий.
 */
- (NSString *)publishedToday {
    NSDictionary *microformat = [YTJson findFirst:@"playerMicroformatRenderer"
                                               in:_playerJson
                                            limit:2000];

    NSString *stamp = [YTJson textIn:microformat key:@"publishDate"];

    if ([stamp length] == 0) {
        stamp = [YTJson textIn:microformat key:@"uploadDate"];
    }

    NSDate *date = [self dateFromStamp:stamp];

    if (date == nil || ![self isToday:date]) {
        return nil;
    }

    NSDateFormatter *clock = [[NSDateFormatter alloc] init];

    [clock setDateStyle:NSDateFormatterNoStyle];
    [clock setTimeStyle:NSDateFormatterShortStyle];

    return YTLocF(@"Сегодня, %@", [clock stringFromDate:date]);
}

/**
 * Разбирает дату из ответа: `2026-08-20T14:05:00-07:00`.
 *
 * Готового разборщика нет: `NSISO8601DateFormatter` появился только
 * в iOS 10, а нам нужно с 5.1. Поэтому обычный `NSDateFormatter`
 * с явным образцом и неизменной локалью — под чужой локалью образец
 * читается по-своему и разбор молча даёт nil.
 *
 * Двоеточие в часовом поясе убираем: `Z` в образце понимает `-0700`,
 * но не `-07:00`. Записи без времени — только дата — нам не годятся:
 * показывать в них нечего, и мы отвечаем nil.
 */
- (NSDate *)dateFromStamp:(NSString *)stamp {
    if ([stamp length] < 19 || [stamp rangeOfString:@"T"].location == NSNotFound) {
        return nil;
    }

    NSMutableString *text = [NSMutableString stringWithString:stamp];

    if ([text hasSuffix:@"Z"]) {
        [text replaceCharactersInRange:NSMakeRange([text length] - 1, 1)
                            withString:@"+0000"];
    } else if ([text length] > 6) {
        NSRange tail = NSMakeRange([text length] - 3, 1);

        if ([[text substringWithRange:tail] isEqualToString:@":"]) {
            [text deleteCharactersInRange:tail];
        }
    }

    NSDateFormatter *reader = [[NSDateFormatter alloc] init];

    [reader setLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"]];
    [reader setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZ"];

    return [reader dateFromString:text];
}

/** Сегодня ли это по календарю человека. */
- (BOOL)isToday:(NSDate *)date {
    NSCalendar *calendar = [NSCalendar currentCalendar];

    NSUInteger parts = NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit;

    NSDateComponents *then = [calendar components:parts fromDate:date];
    NSDateComponents *now = [calendar components:parts fromDate:[NSDate date]];

    return ([then year] == [now year] &&
            [then month] == [now month] &&
            [then day] == [now day]);
}

- (void)buildMenu {
    if (_menu == nil) {
        _menu = [[YTSettingsSheet alloc] initWithDark:NO];
    }

    __weak YTPlayerViewController *weakSelf = self;

    NSMutableArray *options = [NSMutableArray array];

    /**
     * Первая страница — разделы со значками, как `MainSettingsPanel`
     * в Video.xaml. Значки оттуда же: `quality.png` качеству, `speed.png`
     * скорости и озвучке (оригинал ставит ей ту же), `comments.png`
     * субтитрам, `reload.png` перезагрузке.
     */
    if (_menuPage == 0) {
        [options addObject:[YTSheetRow section:@"pl_quality"
                                        title:YTLoc(@"Качество")
                                        value:[self qualityTitle]
                                       action:^{ [weakSelf openMenuPage:1]; }]];

        [options addObject:[YTSheetRow section:@"pl_speed"
                                        title:YTLoc(@"Скорость воспроизведения")
                                        value:[self rateTitle]
                                       action:^{ [weakSelf openMenuPage:2]; }]];

        /**
         * Озвучка показывается, только когда есть из чего выбирать:
         * `AudioTrackButton` в оригинале объявлен `Visibility="Collapsed"`
         * и раскрывается тем же условием.
         */
        if ([[self audioTracks] count] > 1) {
            [options addObject:[YTSheetRow section:@"pl_speed"
                                            title:YTLoc(@"Аудиодорожка")
                                            value:nil
                                           action:^{ [weakSelf openMenuPage:3]; }]];
        }

        /**
         * У озвучки и субтитров подписи справа нет: в разметке оригинала
         * у этих двух кнопок третий столбец сразу стрелка, а не значение.
         */
        [options addObject:[YTSheetRow section:@"pl_comments"
                                        title:YTLoc(@"Субтитры")
                                        value:nil
                                       action:^{ [weakSelf openMenuPage:4]; }]];

        /**
         * Подгон кадра переехал сюда с жеста.
         *
         * Прежде третьей ступенью сведения-разведения пальцев было
         * «растянуть по экрану»; теперь на её месте свободное увеличение,
         * и точному подгону нужен свой угол. Он того стоит: на глаз
         * поймать величину, при которой полосы исчезают ровно, а края
         * обрезаются не больше необходимого, — занятие безнадёжное.
         */
        [options addObject:[YTSheetRow command:@"pl_fullscreen"
                                        title:(_fillsScreen
            ? YTLoc(@"Вписать кадр целиком")
            : YTLoc(@"Растянуть кадр по экрану"))
                                       action:^{
            [weakSelf toggleFillsScreen];
        }]];

        [options addObject:[YTSheetRow command:@"pl_reload"
                                        title:YTLoc(@"Перезагрузить видео")
                                       action:^{ [weakSelf reloadStream]; }]];

        // То же окно, что на сайте по правой кнопке: кодеки, сеть, буфер.
        [options addObject:[YTSheetRow command:@"pl_quality"
                                        title:YTLoc(@"Статистика для сисадминов")
                                       action:^{ [weakSelf toggleStats]; }]];
    } else {
        // Со сдвига возвращаемся к субтитрам, а не в самое начало.
        NSInteger back = (_menuPage == 5) ? 4 : 0;

        [options addObject:[YTSheetRow back:^{ [weakSelf openMenuPage:back]; }]];
    }

    if (_menuPage == 1) {
        [options addObject:[YTSheetRow choice:YTLoc(@"Авто")
                                       picked:(_pickedHeight == 0)
                                       action:^{ [weakSelf pickHeight:0]; }]];

        /**
         * Какая ступень идёт на самом деле — её и отмечаем словом.
         *
         * Выбранное и играющее — разные вещи, и меню показывало только
         * первое. На подаче ступень назначает сервер: попросив 1080p,
         * легко смотреть 720p, и по меню этого было не понять. А при
         * «Авто» галочка вообще не говорила ни о чём.
         */
        NSInteger playing = [self playingHeight];

        // Сверху вниз, от крупного к мелкому — привычный порядок.
        for (NSNumber *number in [[_heights reverseObjectEnumerator] allObjects]) {
            NSInteger height = [number integerValue];

            /**
             * Кадры подписываем только выше тридцати — как сам YouTube.
             *
             * У него «1080p60» и просто «1080p»: суффикс означает
             * «чаще обычного», а не «вот столько кадров». Писать его
             * всегда выходило хуже — у 24-кадрового ролика (а их много,
             * это киношная частота) меню показывало «1080p24», и это
             * читалось как поломка, хотя число верное. Точную частоту
             * по-прежнему показывает панель статистики, там она и нужна.
             */
            NSInteger frames = [YTStreams framesForHeight:height];

            NSString *title = (frames > 30)
                ? [NSString stringWithFormat:@"%ldp%ld", (long)height, (long)frames]
                : [NSString stringWithFormat:@"%ldp", (long)height];

            if ([YTStreams isBeyondDevice:height]) {
                title = [title stringByAppendingString:YTLoc(@" — может не пойти")];
            }

            if (height == playing) {
                title = [NSString stringWithFormat:@"%@ · %@", title, YTLoc(@"сейчас")];
            }

            [options addObject:[YTSheetRow choice:title
                                           picked:(height == _pickedHeight)
                                           action:^{ [weakSelf pickHeight:height]; }]];
        }

        /**
         * Почему список короче, чем у того же ролика в браузере.
         *
         * Ступень, которой у ролика нет в тридцати кадрах, из списка
         * исчезает молча — и выглядит это как «приложение не умеет
         * 1080p». Объясняем прямо здесь, вместе с тем, что делать.
         */
        NSArray *hidden = [YTStreams sixtyOnlyHeights];

        if ([hidden count] > 0 && [YTStreams prefersThirtyFrames]) {
            NSMutableArray *names = [NSMutableArray array];

            for (NSNumber *tier in [[hidden reverseObjectEnumerator] allObjects]) {
                [names addObject:[NSString stringWithFormat:@"%ldp",
                    (long)[tier integerValue]]];
            }

            [options addObject:[YTSheetRow note:[NSString stringWithFormat:
                YTLoc(@"Нет %@? У этого ролика такое качество есть только "
                      @"в 60 кадрах. Включите «60 кадров» в настройках, если "
                      @"устройство его потянет."),
                [names componentsJoinedByString:@", "]]]];
        }
    }

    if (_menuPage == 2) {
        /**
         * Только обычная скорость и ниже.
         *
         * Ускорение `AVPlayer` по нашей подаче не принимает: поток идёт
         * через прокси как HLS, и элемент объявляет `canPlayFastForward`
         * равным `NO`. Причём не просто не разгоняется, а **встаёт** —
         * `setRate:` выбирает ближайшее, что умеет, и ближайшим
         * оказывается ноль. Пункт, который останавливает ролик, хуже
         * отсутствующего, поэтому его в списке и нет.
         *
         * Замедление при этом работает, оттого список и обрывается
         * на единице, а не исчезает целиком.
         */
        NSArray *rates = [NSArray arrayWithObjects:
            [NSNumber numberWithFloat:0.25f], [NSNumber numberWithFloat:0.5f],
            [NSNumber numberWithFloat:0.75f], [NSNumber numberWithFloat:1.0f], nil];

        for (NSNumber *number in rates) {
            float rate = [number floatValue];

            [options addObject:[YTSheetRow choice:[self titleForRate:rate]
                                           picked:(rate == _rate)
                                           action:^{ [weakSelf pickRate:rate]; }]];
        }
    }

    if (_menuPage == 3) {
        NSArray *tracks = [self audioTracks];

        if ([tracks count] == 0) {
            [options addObject:[YTSheetRow choice:YTLoc(@"Другой озвучки нет")
                                           picked:NO action:nil]];
        }

        for (NSDictionary *track in tracks) {
            NSString *identifier = [track objectForKey:@"id"];
            BOOL picked = ([_audioTrack length] == 0)
                ? [[track objectForKey:@"default"] boolValue]
                : [identifier isEqualToString:_audioTrack];

            [options addObject:[YTSheetRow choice:[track objectForKey:@"title"]
                                           picked:picked
                                           action:^{ [weakSelf pickAudioTrack:identifier]; }]];
        }
    }

    if (_menuPage == 4) {
        if ([_subtitleTracks count] == 0) {
            [options addObject:[YTSheetRow choice:YTLoc(@"У этого ролика их нет")
                                           picked:NO action:nil]];
        } else {
            [options addObject:[YTSheetRow choice:YTLoc(@"Выключены")
                                           picked:(_subtitleTrack == nil)
                                           action:^{ [weakSelf pickSubtitles:nil]; }]];

            for (YTSubtitleTrack *track in _subtitleTracks) {
                [options addObject:[YTSheetRow choice:[track displayName]
                                               picked:(track == _subtitleTrack)
                                               action:^{ [weakSelf pickSubtitles:track]; }]];
            }

            [options addObject:[YTSheetRow section:@"pl_speed"
                                            title:YTLoc(@"Сдвиг по времени")
                                            value:[self subtitleOffsetTitle]
                                           action:^{ [weakSelf openMenuPage:5]; }]];
        }
    }

    if (_menuPage == 5) {
        /**
         * Сдвиг правится шагами, а не списком: и в оригинале это две
         * кнопки «раньше» и «позже» с шагом 0,25 секунды. Список из
         * четырёх десятков значений тут был бы неудобнее.
         */
        [options addObject:[YTSheetRow command:@"pl_skip"
                                         title:YTLoc(@"Раньше на 0,25 с")
                                        action:^{ [weakSelf nudgeSubtitles:0.25]; }]];

        [options addObject:[YTSheetRow command:@"pl_back"
                                         title:YTLoc(@"Позже на 0,25 с")
                                        action:^{ [weakSelf nudgeSubtitles:-0.25]; }]];

        [options addObject:[YTSheetRow command:@"pl_reload"
                                         title:YTLoc(@"Вернуть обычный (+2,00 с)")
                                        action:^{ [weakSelf setSubtitleOffset:2.0]; }]];

        [options addObject:[YTSheetRow choice:[self subtitleOffsetTitle]
                                       picked:NO action:nil]];
    }

    // У первой страницы заголовка нет — в оригинале он только у списков.
    [_menu setTitle:(_menuPage == 0 ? nil : [self menuPageTitle]) rows:options];
}

/** «Перезагрузить видео» — тот же поток заново, с того же места. */
/** Окно «статистика для сисадминов» поверх кадра — показать либо убрать. */
- (void)toggleStats {
    [self hideMenu];

    BOOL show = [_stats isHidden];

    [_stats setHidden:!show];

    if (show) {
        [_stats start];
    } else {
        [_stats stop];
    }
}

- (void)reloadStream {
    [self hideMenu];

    [self pickHeight:_pickedHeight force:YES];
}

/**
 * Подача сдалась посреди просмотра — доигрываем готовыми адресами.
 *
 * Сервер вправе попросить обновить ответ `/player`, и обычно это
 * проходит незаметно. Но бывает, что и обновлённый ответ подачи не
 * несёт — тогда байтов больше не будет вовсе, и просмотр встаёт: ни
 * куска, ни ошибки, только перемотки без ответа. Из журнала это видно
 * как «Обновиться не удалось трижды».
 *
 * Готовые адреса при этом чаще всего есть — они лежат в том же ответе,
 * который мы отложили, выбрав подачу. Пересобираем на них, место
 * просмотра `pickHeight:force:` сохраняет само.
 *
 * Один раз на ролик: если и готовые адреса не сыграют, второй заход
 * ничего не изменит, а перезапуски по кругу человек видит как мигание.
 */
- (void)sabrLost {
    /**
     * Извещение приходит с потока подачи, да ещё из-под её замка.
     * Пересборка же трогает и плеер, и полосу, поэтому уходим на главный
     * поток и отпускаем звавшего сразу.
     */
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(sabrLost)
                               withObject:nil
                            waitUntilDone:NO];

        return;
    }

    if (_sabrFellBack || _playerJson == nil || _formats != nil) {
        return;
    }

    NSArray *ready = [YTStreams formatsFrom:_playerJson];

    if ([ready count] == 0) {
        NSLog(@"[YouTube/Плеер] Подача потеряна, а готовых адресов в ответе нет");

        return;
    }

    _sabrFellBack = YES;
    _formats = ready;
    _heights = [YTStreams heightsIn:ready];

    NSLog(@"[YouTube/Плеер] Подача потеряна — доигрываем готовыми адресами "
          @"(дорожек %lu, с %.1f с)",
          (unsigned long)[ready count], [self currentSeconds]);

    [self pickHeight:_pickedHeight force:YES];
}

/**
 * Сервер не даёт выбранное качество — берём его готовыми адресами.
 *
 * В ответе TV-клиента готовых адресов почти нет (одна дорожка 360p),
 * поэтому за ними — к VISIONOS, как и при отказе подачи на старте.
 * Выбранной высоты нет и там — остаёмся на подаче: хуже, чем есть,
 * делать незачем. Один раз на ролик.
 */
- (void)sabrRefusedPick {
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(sabrRefusedPick)
                               withObject:nil
                            waitUntilDone:NO];

        return;
    }

    if (_sabrFellBack || _formats != nil || _pickedHeight <= 0 ||
        [[YTHlsProxy shared] isLive]) {
        return;
    }

    _sabrFellBack = YES;

    NSString *videoId = _videoId;
    NSInteger wanted = _pickedHeight;

    YTAsync(^{
        NSDictionary *plain = [YTApi androidVrPlayerResponse:videoId];
        NSArray *ready = [YTStreams formatsFrom:plain];
        NSArray *heights = [YTStreams heightsIn:ready];

        YTMain(^{
            if (![_videoId isEqualToString:videoId]) {
                return;
            }

            if (![heights containsObject:[NSNumber numberWithInteger:wanted]]) {
                NSLog(@"[YouTube/Плеер] Готовых адресов %ldp нет — остаёмся на подаче",
                      (long)wanted);

                return;
            }

            _formats = ready;
            _heights = heights;

            NSLog(@"[YouTube/Плеер] Сервер не дал %ldp подачей — играем готовыми "
                  @"адресами с %.1f с", (long)wanted, [self currentSeconds]);

            [self pickHeight:wanted force:YES];
        });
    });
}

- (NSString *)menuPageTitle {
    switch (_menuPage) {
        case 1:  return YTLoc(@"Качество");
        case 2:  return YTLoc(@"Скорость воспроизведения");
        case 3:  return YTLoc(@"Аудиодорожка");
        case 4:  return YTLoc(@"Субтитры");
        case 5:  return YTLoc(@"Сдвиг субтитров");
        default: return YTLoc(@"Настройки");
    }
}

/**
 * Ступень, которая идёт прямо сейчас; 0, если сказать нечего.
 *
 * Спрашиваем у того, кто её и выбрал: на подаче это сервер и мы узнаём
 * ступень из заголовка присланной дорожки, на готовых адресах — мы сами,
 * и она запомнена при выборе.
 */
- (NSInteger)playingHeight {
    return (_formats == nil) ? [YTStreams sabrPlayingHeight] : _readyHeight;
}

/**
 * Подпись строки «Качество» в меню: что выбрано и, если это не одно
 * и то же, что играет.
 */
- (NSString *)qualityTitle {
    NSString *picked = (_pickedHeight > 0)
        ? [NSString stringWithFormat:@"%ldp", (long)_pickedHeight]
        : YTLoc(@"Авто");

    NSInteger playing = [self playingHeight];

    if (playing <= 0 || playing == _pickedHeight) {
        return picked;
    }

    return [NSString stringWithFormat:@"%@ · %ldp", picked, (long)playing];
}

- (NSString *)titleForRate:(float)rate {
    if (rate == 1.0f) {
        return YTLoc(@"Обычная");
    }

    // Убираем лишний ноль: «1.5×», а не «1.50×».
    NSString *number = [NSString stringWithFormat:@"%.2f", rate];

    while ([number hasSuffix:@"0"]) {
        number = [number substringToIndex:[number length] - 1];
    }

    if ([number hasSuffix:@"."]) {
        number = [number substringToIndex:[number length] - 1];
    }

    return [number stringByAppendingString:@"×"];
}

- (NSString *)rateTitle {
    return [self titleForRate:_rate];
}

- (NSString *)trackTitle {
    for (NSDictionary *track in [YTStreams sabrAudioTracks]) {
        BOOL picked = ([_audioTrack length] == 0)
            ? [[track objectForKey:@"default"] boolValue]
            : [[track objectForKey:@"id"] isEqualToString:_audioTrack];

        if (picked) {
            return [track objectForKey:@"title"];
        }
    }

    return YTLoc(@"По умолчанию");
}

- (NSString *)captionTitle {
    return YTLoc(@"Выключены");
}

/** Переход между страницами меню — без закрытия и повторного выезда. */
- (void)openMenuPage:(NSInteger)page {
    _menuPage = page;

    [self buildMenu];
    [[self view] setNeedsLayout];
}

/**
 * Пуск с той скоростью, что выбрана в меню.
 *
 * Отдельным методом, потому что зовётся из обоих обработчиков пуска,
 * а раньше был там дважды переписан слово в слово.
 *
 * Ноль недопустим: это не «обычная скорость», а пауза.
 */
- (void)resumeAtChosenRate {
    _meantToPlay = YES;

    if (_rate > 0 && _rate != 1.0f) {
        [_player setRate:_rate];
        return;
    }

    [_player play];
}


/** Смена скорости воспроизведения. */
- (void)pickRate:(float)rate {
    [self hideMenu];

    _rate = rate;

    NSLog(@"[YouTube/Плеер] Скорость: %@", [self titleForRate:rate]);

    /**
     * Ставим скорость только идущему плееру: `setRate:` на
     * остановленном запустил бы воспроизведение, а человек нажал
     * на пункт меню, а не на «играть».
     */
    if ([_player rate] > 0) {
        [_player setRate:rate];

        /**
         * Проверяем, удержал ли плеер заданный ход.
         *
         * Он вправе не удержать: если декодер не поспевает, скорость
         * сбрасывается сама, а на неспешном железе это и происходит.
         * Отличить «не поспевает» от нашей ошибки снаружи нельзя,
         * а по журналу — сразу видно: заказан 2.0, держит 1.0.
         */
        [self performSelector:@selector(checkRate) withObject:nil afterDelay:2.0];
    }
}

- (void)checkRate {
    if (_player == nil) {
        return;
    }

    float now = [_player rate];

    if (now == 0) {
        NSLog(@"[YouTube/Плеер] Через 2 с после смены скорости плеер стоит "
              @"(заказано %.2f)", _rate);

        return;
    }

    if (fabsf(now - _rate) > 0.01f) {
        NSLog(@"[YouTube/Плеер] Скорость не удержалась: заказано %.2f, идёт %.2f",
              _rate, now);
    }
}

- (void)hideMenu {
    [_menu close];
}

/**
 * Пересобирает поток выбранной высотой и возвращает воспроизведение
 * на ту же секунду.
 */
/**
 * Смена озвучки.
 *
 * Пересобирает воспроизведение так же, как смена качества: подача даёт
 * дорожки по описанию, и другой язык — это другой набор в предпочтениях,
 * а значит новый запрос. Место в ролике сохраняется.
 */
/**
 * Озвучки этого ролика, откуда бы он ни игрался.
 *
 * Путей воспроизведения два, и перечень у каждого свой. Подача SABR
 * присылает его сама; на готовых адресах его нет, но сами дорожки
 * в ответе `/player` есть и помечены озвучкой — оттуда и собираем.
 *
 * Без этого меню озвучки показывалось только на подаче, а на готовых
 * адресах — а туда приложение уходит часто — его не было вовсе, хотя
 * выбирать было из чего.
 */
- (NSArray *)audioTracks {
    NSArray *fromSabr = [YTStreams sabrAudioTracks];

    if ([fromSabr count] > 1) {
        return fromSabr;
    }

    return [YTStreams audioTracksIn:[YTStreams formatsFrom:_playerJson]];
}

- (void)pickAudioTrack:(NSString *)identifier {
    [self hideMenu];

    if ([identifier isEqualToString:_audioTrack]) {
        return;
    }

    _audioTrack = [identifier copy];

    NSLog(@"[YouTube/Плеер] Озвучка: %@", identifier);

    [self pickHeight:_pickedHeight force:YES];
}

- (void)pickHeight:(NSInteger)height {
    [self pickHeight:height force:NO];
}

- (void)pickHeight:(NSInteger)height force:(BOOL)force {
    [self hideMenu];

    if (height == _pickedHeight && !force) {
        return;
    }

    _pickedHeight = height;

    if ([YTStreams isBeyondDevice:height]) {
        NSLog(@"[YouTube/Плеер] Выбрано %ldp — выше меры устройства (%ldp); "
              @"возможен звук без картинки",
              (long)height, (long)[YTStreams deviceMaxHeight]);

        /**
         * И говорим об этом вслух.
         *
         * В меню такая ступень и так помечена, но пометку легко не
         * заметить, а последствие заметное: рассыпающаяся картинка или
         * вовсе один звук. Раньше об этом знал только журнал.
         */
        [self showNotice:YTLocF(@"%ldp — выше меры устройства, может не пойти",
                                (long)height)];
    }

    NSTimeInterval resume = [self currentSeconds];

    /**
     * Пока пересобирается воспроизведение, показываем то место, к
     * которому вернёмся.
     *
     * Иначе полоса и часы продолжают идти сами по себе: плеер отпущен,
     * `currentSeconds` отдаёт последнее известное, а тик знай себе
     * тикает. Выглядит так, будто видео играет, — а его нет.
     */
    _awaitingSeek = YES;
    _seekTarget = resume;

    NSArray *formats = _formats;
    NSInteger cap = (height > 0) ? height : _maxHeight;

    /**
     * Прежний плеер отпускается **до** того, как трогается прокси: иначе
     * он продолжит просить сегменты у уже закрытой сессии, получит отказ
     * и уйдёт в ошибку ровно тогда, когда собирается новый.
     */
    [self teardownPlayer];

    [_busy start];

    YTAsync(^{
        NSString *url = nil;

        if (formats == nil && _playerJson != nil) {
            /**
             * Путь подачи: готовых дорожек нет, и «пересобрать» значит
             * попросить заново — с новым потолком и той же озвучкой.
             */
            YTSabr *sabr = [YTStreams sabrFor:_playerJson
                                    maxHeight:cap
                                   audioTrack:_audioTrack
                                        exact:(height > 0)];

            if (sabr != nil) {
                url = [[YTHlsProxy shared] openWithSabr:sabr];
            }
        } else {
            YTFormat *video = [YTStreams chooseVideo:formats maxHeight:cap];
            /**
         * Выбранная озвучка передаётся и сюда.
         *
         * Прежде здесь стоял `nil`, то есть на готовых адресах всегда
         * бралась дорожка по умолчанию — выбор из меню просто некуда
         * было донести, и он ничего не менял.
         */
        YTFormat *audio = [YTStreams chooseAudio:formats
                                  preferredTrack:_audioTrack];

            _readyHeight = [video qualityTier];

            url = [[YTHlsProxy shared] openWithVideo:video audio:audio];
        }

        YTMain(^{
            if (url == nil) {
                [_busy stop];
                [_status setText:YTLoc(@"Поток не собрался")];
                return;
            }

            [self startPlayer:url];

            if (resume > 1) {
                /**
                 * Только `seekToTime:` — **без** обработчика завершения.
                 *
                 * Вариант с обработчиком бросает исключение, если элемент
                 * ещё не готов к воспроизведению, а здесь он заведомо
                 * не готов: плеер создан мгновение назад. Приложение
                 * от этого падало с `SIGABRT` при каждой смене качества,
                 * и по журналу это выглядело как обрыв на ровном месте —
                 * исключение летит из AVFoundation, а не из нашего кода.
                 *
                 * Простой `seekToTime:` такого не делает: он запоминает
                 * цель и выполняет её, когда сможет.
                 */
                [_player seekToTime:CMTimeMakeWithSeconds(resume, 600)];
            } else {
                _awaitingSeek = NO;
            }
        });
    });
}

- (void)fullscreenTapped {
    _fullscreenMode = !_fullscreenMode;

    /**
     * Уходя из полного экрана, снимаем и зум.
     *
     * В окне кадр и так по ширине, а обрезанные края там были бы вредом
     * без выгоды. Важнее другое: иначе зум пережил бы выход и вернулся
     * при следующем развороте — человек его не просил, а поля пропали бы
     * сами собой, будто приложение своевольничает.
     */
    if (!_fullscreenMode) {
        [self setFillsScreen:NO];
        [self resetZoom];
    }

    [_fullscreen setImage:YTDarkIcon(_fullscreenMode ? @"pl_exit_fullscreen" : @"pl_fullscreen")
                 forState:UIControlStateNormal];

    /**
     * Название поверх кадра показывается только в развёрнутом виде,
     * и кнопка «свернуть» тогда уступает ему место — как в оригинале,
     * где `FullscreenTitlePanel` занимает верх слева, а `MinimizeButton`
     * прячется.
     */
    [_fullscreenTitle setHidden:!_fullscreenMode];
    [_fullscreenAuthor setHidden:!_fullscreenMode];
    [_minimize setHidden:_fullscreenMode];

    [[UIApplication sharedApplication]
        setStatusBarHidden:_fullscreenMode
             withAnimation:UIStatusBarAnimationFade];

    [[self view] setNeedsLayout];
    [self showControls];
}

/**
 * Поворот телефона при включённой настройке разворачивает кадр и,
 * обратно, сворачивает его. Задать ориентацию извне на iOS нельзя,
 * поэтому это отклик на поворот, а не его причина.
 */
- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)orientation
                                duration:(NSTimeInterval)duration {
    [super willRotateToInterfaceOrientation:orientation duration:duration];

    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad
        || ![YTSettings autoFullscreenInLandscape]) {
        return;
    }

    BOOL landscape = UIInterfaceOrientationIsLandscape(orientation);

    if (landscape != _fullscreenMode) {
        [self fullscreenTapped];
    }
}

/**
 * Главы — из временных меток в описании, как `UpdateDescriptionChaptersFromDescription`.
 *
 * Отдельного списка глав сервер не присылает: то, что показывает сам
 * YouTube, он собирает из описания — строк вида «12:34 Название». Берём
 * оттуда же. Метка должна стоять в начале строки: число посреди текста
 * («в 3:15 будет видно») главой не является.
 */
- (NSArray *)chaptersIn:(NSString *)text {
    if ([text length] == 0) {
        return nil;
    }

    NSMutableArray *chapters = [NSMutableArray array];

    for (NSString *line in [text componentsSeparatedByCharactersInSet:
             [NSCharacterSet newlineCharacterSet]]) {

        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];

        NSArray *parts = [[[trimmed componentsSeparatedByString:@" "] objectAtIndex:0]
            componentsSeparatedByString:@":"];

        if ([parts count] < 2 || [parts count] > 3) {
            continue;
        }

        NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];

        NSTimeInterval seconds = 0;
        BOOL good = YES;

        for (NSString *part in parts) {
            // Одни цифры, и не больше двух: «1:02:03» — время, «2025:07» — нет.
            if ([part length] == 0 || [part length] > 2 ||
                [[part stringByTrimmingCharactersInSet:digits] length] > 0) {

                good = NO;
                break;
            }

            seconds = seconds * 60 + [part integerValue];
        }

        if (!good || seconds < 0) {
            continue;
        }

        /**
         * Название главы — та же строка без времени, обрезанная по краям.
         *
         * Обрезаются не только пробелы: разделители между временем и
         * названием пишут кто во что горазд — «0:00 — Вступление»,
         * «0:00 | Вступление», «0:00. Вступление». Список знаков взят
         * из `ExtractDescriptionChapterTitle` оригинала.
         */
        NSString *title = [trimmed substringFromIndex:
            [[[trimmed componentsSeparatedByString:@" "] objectAtIndex:0] length]];

        title = [title stringByTrimmingCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@" \t-–—:|.()"]];

        [chapters addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithDouble:seconds], @"start",
            title != nil ? title : @"", @"title",
            nil]];
    }

    if ([chapters count] < 2) {
        // Одна метка — это не разбивка, а просто число в описании.
        return nil;
    }

    NSLog(@"[YouTube/Плеер] Глав в описании: %lu", (unsigned long)[chapters count]);

    return chapters;
}

/**
 * Кадр из раскадровки над полосой перемотки.
 *
 * Лист-спрайт берётся один раз и остаётся в памяти: на одном листе сотня
 * кадров, и при протяге по всей полосе их понадобится единицы. Пока лист
 * едет, окно показывает прежний кадр, а не мигает пустотой.
 */
- (void)showPreviewAt:(NSTimeInterval)seconds x:(CGFloat)x {
    if (_storyboard == nil) {
        return;
    }

    YTStoryboardFrame *frame = [_storyboard frameAt:seconds];

    if (frame == nil || frame.width <= 0) {
        return;
    }

    // Кадры в раскадровке мелкие (обычно 80×45) — растягиваем до вида,
    // одинакового у любого ролика.
    CGFloat scale = 128.0f / (CGFloat)frame.width;
    CGFloat boxWidth = round(frame.width * scale);
    CGFloat boxHeight = round(frame.height * scale);

    CGRect box = [_track frame];
    CGFloat left = x - boxWidth / 2;

    if (left < box.origin.x) { left = box.origin.x; }

    if (left + boxWidth > CGRectGetMaxX(box)) {
        left = CGRectGetMaxX(box) - boxWidth;
    }

    CGFloat top = CGRectGetMinY(box) - boxHeight - 26;

    [_previewBox setFrame:CGRectMake(left, top, boxWidth, boxHeight)];
    [_previewBox setHidden:NO];

    [_previewTime setFrame:CGRectMake(left, top + boxHeight + 2, boxWidth, 16)];
    [_previewTime setText:[self clock:seconds]];
    [_previewTime setHidden:NO];

    id sheet = [_sheets objectForKey:frame.sheet];

    // NSNull здесь значит «лист уже просим»: он ещё едет.
    if (![sheet isKindOfClass:[UIImage class]]) {
        [self fetchSheet:frame.sheet];

        return;
    }

    UIImage *image = (UIImage *)sheet;

    [_previewImage setFrame:CGRectMake(-frame.column * boxWidth,
                                       -frame.row * boxHeight,
                                       image.size.width * scale,
                                       image.size.height * scale)];

    [_previewImage setImage:image];
}

/** Берёт лист-спрайт и запоминает его. */
- (void)fetchSheet:(NSString *)url {
    if (_sheets == nil) {
        _sheets = [NSMutableDictionary dictionary];
    }

    // Пометка «уже просили» — тем же словарём, чтобы не просить дважды.
    if ([_sheets objectForKey:url] != nil) {
        return;
    }

    [_sheets setObject:[NSNull null] forKey:url];

    NSInteger generation = [_loadGeneration current];

    YTAsync(^{
        NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:url]];
        UIImage *image = [data length] > 0 ? [UIImage imageWithData:data] : nil;

        YTMain(^{
            if (![_loadGeneration isCurrent:generation] || image == nil) {
                [_sheets removeObjectForKey:url];

                return;
            }

            [_sheets setObject:image forKey:url];
        });
    });
}

- (void)hidePreview {
    [_previewBox setHidden:YES];
    [_previewTime setHidden:YES];
}

- (void)scrubbed:(UIPanGestureRecognizer *)gesture {
    CGPoint point = [gesture locationInView:_overlay];
    CGRect box = [_track frame];

    // Перематываем только жестом, начатым у полосы: иначе любой протяг
    // по кадру дёргал бы воспроизведение.
    if ([gesture state] == UIGestureRecognizerStateBegan) {
        _seeking = (point.y > CGRectGetMinY(box) - 22);

        if (!_seeking) {
            return;
        }
    }

    if (!_seeking || _duration <= 0) {
        return;
    }

    double share = (point.x - box.origin.x) / box.size.width;

    if (share < 0) { share = 0; }
    if (share > 1) { share = 1; }

    NSTimeInterval target = _duration * share;

    [_time setText:[self timeTextAt:target]];

    [self layoutTimePill];
    [self placeProgress:share];
    [self showPreviewAt:target x:point.x];

    if ([gesture state] == UIGestureRecognizerStateEnded ||
        [gesture state] == UIGestureRecognizerStateCancelled) {
        [self hidePreview];

        _seeking = NO;

        // Дальше — общий путь: остановить, прыгнуть с допуском, продолжить.
        [self seekTo:target];

        [self scheduleHide];
    }
}

#pragma mark Фон

/**
 * iOS останавливает воспроизведение, как только `AVPlayerLayer` уходит
 * с экрана: видеодорожка есть, показывать её негде. Плееру же всё равно,
 * куда девался слой, — отвязанный, он спокойно продолжает выдавать звук.
 */
- (void)enteredBackground {
    /**
     * Проверка вернувшейся картинки в фоне не нужна и вредна: слой там
     * заведомо пуст, и она пересобрала бы его впустую — как раз перед
     * тем, как мы его снова отвяжем.
     */
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(checkSurface)
                                               object:nil];

    [_playerLayer setPlayer:nil];

    _surfaceDetached = YES;

    [self holdBackgroundTime];
}

/**
 * Возвращает к жизни прокси, если сон приложения его убил.
 *
 * Сокет на 127.0.0.1 сна не переживает, а плеер держит плейлист с
 * номером порта в каждом адресе. Поэтому сперва пробуем занять тот же
 * номер: тогда плеер продолжит с того места, где стоял, и человек
 * ничего не заметит.
 *
 * Если номер отдать не смогли — воспроизведение придётся пересобрать
 * тем же ходом, что и при смене качества: он сохраняет место просмотра.
 * Пересобираем только при живой подаче: на готовых адресах плеер ходит
 * в сеть сам и наш прокси ему нужен лишь для склеенного потока.
 */
- (void)reviveProxy {
    if ([[YTHlsProxy shared] reviveListenerKeepingPort]) {
        return;
    }

    NSLog(@"[YouTube/Плеер] Прокси после сна на другом порту — пересобираем "
          @"с %.1f с", [self currentSeconds]);

    [self pickHeight:_pickedHeight force:YES];
}

/**
 * Просит у системы времени на фоновую работу.
 *
 * Пока приложение не усыплено, живы и сокеты — а с ними и наш прокси
 * на 127.0.0.1, из которого плеер берёт куски. Стоит процессу заснуть,
 * как описатель становится негодным, и по возвращении плееру некуда
 * идти: в журнале это «Соединение не принято: Bad file descriptor»,
 * а на экране — ролик, который «больше не грузится» после того, как
 * человек погасил экран на минуту.
 *
 * Времени дают немного — на наших системах минуты, — но именно
 * короткие отлучки и составляют почти все такие случаи. Что делать
 * с долгими, знает `enteredForeground`.
 *
 * Звук отдельно: пока он играет, система и так не усыпляет — на это
 * есть `audio` в списке фоновых занятий. Здесь речь о паузе, когда
 * играть нечего и держаться не за что.
 */
- (void)holdBackgroundTime {
    UIApplication *application = [UIApplication sharedApplication];

    if (![application respondsToSelector:@selector(beginBackgroundTaskWithExpirationHandler:)]) {
        return;
    }

    [self releaseBackgroundTime];

    __weak YTPlayerViewController *weakSelf = self;

    _backgroundTask = [application beginBackgroundTaskWithExpirationHandler:^{
        /**
         * Время вышло — отпускаем заявку сами.
         *
         * Не отпустить её значит быть снятым системой без разговоров,
         * а это хуже обычного засыпания: следующий запуск начнётся
         * с чистого листа.
         */
        [weakSelf releaseBackgroundTime];
    }];
}

/** Возвращает заявку системе. */
- (void)releaseBackgroundTime {
    UIApplication *application = [UIApplication sharedApplication];

    if (_backgroundTask == UIBackgroundTaskInvalid ||
        ![application respondsToSelector:@selector(endBackgroundTask:)]) {
        return;
    }

    [application endBackgroundTask:_backgroundTask];

    _backgroundTask = UIBackgroundTaskInvalid;
}

/**
 * Возврат из фона.
 *
 * Сперва пробуем дёшево: вернуть плеера прежнему слою. Если содержимое
 * слоя пережило фон, картинка появляется сразу же — без единого лишнего
 * действия.
 *
 * Пересборка слоя нужна не всегда, а стоит дорого: новый слой берёт кадр
 * заново, от ближайшего опорного, и на неспешном железе это те самые
 * секунда-две «загрузки» при разблокировке, о которых говорят. Раньше мы
 * пересобирали всегда — потому что бывает и так, что система выбрасывает
 * содержимое слоя, и тогда `setPlayer:` нового кадра не заводит: слой жив,
 * место занимает, а в нём чернота при работающем звуке.
 *
 * Отличить одно от другого умеет сам слой — `readyForDisplay` говорит,
 * есть ли чем рисовать. Поэтому: возвращаем плеера, а чуть погодя
 * смотрим, появился ли кадр, и пересобираем только если нет.
 */
- (void)enteredForeground {
    [self releaseBackgroundTime];

    /**
     * Только если поверхность действительно отвязывали. «Стали деятельны»
     * приходит и после снятого будильника, и после чужого окна поверх
     * приложения — трогать слой там незачем, это лишний чёрный промельк.
     */
    if (!_surfaceDetached || _player == nil || _videoHost == nil) {
        return;
    }

    [self reviveProxy];

    _surfaceDetached = NO;
    _surfaceReturn = CFAbsoluteTimeGetCurrent();

    [_playerLayer setPlayer:_player];

    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(checkSurface)
                                               object:nil];

    /**
     * Четверть секунды — на то, чтобы дошёл первый кадр. Меньше значит
     * пересобирать слой там, где он и сам бы ожил; больше — держать
     * черноту дольше нужного в том случае, когда пересборка неизбежна.
     */
    [self performSelector:@selector(checkSurface) withObject:nil afterDelay:0.25];

    /**
     * Играли до того, как погас экран, — играем и после.
     *
     * Поверхность мы возвращаем, а ход — нет: система успевает остановить
     * показ, пока приложение не деятельно, и он так и стоит. Со стороны
     * это «ролик открыт, а не идёт, пока не закроешь и не откроешь
     * заново». Возобновляем только то, что человек сам не ставил на
     * паузу и что не доиграло до конца.
     */
    if (_meantToPlay && !_finished && [_player rate] <= 0) {
        NSLog(@"[YouTube/Плеер] Вернулись из фона на паузе — продолжаем");

        [self resumeAtChosenRate];
    }
}

/** Ожил ли слой сам; если нет — собираем заново, как раньше. */
- (void)checkSurface {
    if (_player == nil || _videoHost == nil) {
        return;
    }

    NSTimeInterval spent = (CFAbsoluteTimeGetCurrent() - _surfaceReturn) * 1000.0;

    if (_playerLayer != nil && [_playerLayer isReadyForDisplay]) {
        NSLog(@"[YouTube/Плеер] Вернулись из фона — картинка на месте, %.0f мс",
              spent);

        return;
    }

    [_playerLayer removeFromSuperlayer];

    _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];

    [_playerLayer setVideoGravity:[self videoGravity]];
    [_playerLayer setFrame:[_videoHost bounds]];
    [[_videoHost layer] addSublayer:_playerLayer];

    NSLog(@"[YouTube/Плеер] Вернулись из фона — слой был пуст, пересобран "
          @"(ждали %.0f мс)", spent);
}

#pragma mark Раскладка

/**
 * Доля ширины под левую колонку.
 *
 * 0.62 — то же число, что в Трубаче: на 1024 точках это 635 под кадр
 * с описанием и 389 под список справа. Карточке похожего этого хватает,
 * а кадру 635 точек дают 357 высоты — ровно столько, чтобы под ним
 * осталось место названию и кнопкам.
 */
static const CGFloat YTSplitLeftShare = 0.62;

/** Раздельная раскладка — только планшет, только лёжа, только не в полный экран. */
- (BOOL)wantsSplitIn:(CGRect)bounds {
    if (_fullscreenMode) {
        return NO;
    }

    if ([[UIDevice currentDevice] userInterfaceIdiom] != UIUserInterfaceIdiomPad) {
        return NO;
    }

    return bounds.size.width > bounds.size.height;
}

- (CGFloat)pageWidthIn:(CGRect)bounds {
    return [self wantsSplitIn:bounds]
        ? floor(bounds.size.width * YTSplitLeftShare)
        : bounds.size.width;
}

/**
 * Переезд очереди и похожих между страницей и правой колонкой.
 *
 * Зовётся только когда раскладка действительно сменилась — при повороте
 * планшета и при выходе из развёрнутого кадра, а не каждый проход.
 */
- (void)applySplit:(BOOL)split {
    _split = split;

    UIView *host = [self listHost];

    [host addSubview:_chapterCard];
    [host addSubview:_chapterHeader];

    for (UIView *row in _chapterRows) {
        [host addSubview:row];
    }

    [host addSubview:_queueCard];
    [host addSubview:_queueHeader];

    for (UIView *row in _queueRows) {
        [host addSubview:row];
    }

    [host addSubview:_relatedTitle];

    for (UIView *card in _relatedCards) {
        [host addSubview:card];
    }

    NSLog(@"[YouTube/Плеер] Раскладка: %@", split ? @"две колонки" : @"одна");
}

/**
 * Куда класть очередь и похожие. Спрашивается и при их создании: карточки
 * похожих заводятся по мере прихода ответа, уже после поворота.
 */
- (UIView *)listHost {
    return _split ? (UIView *)_side : (UIView *)_page;
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];

    CGRect bounds = [[self view] bounds];

    if (_fullscreenMode) {
        [_page setHidden:YES];

        // Развёрнутый кадр занимает всё окно — правой колонке места нет.
        [_side setHidden:YES];
        [_columnDivider setHidden:YES];

        if ([_stage superview] != [self view]) {
            [[self view] addSubview:_stage];
        }

        [_stage setFrame:bounds];
        [self layoutStage];

        return;
    }

    [_page setHidden:NO];

    // Раскладка могла смениться поворотом или выходом из полного экрана;
    // переезд видов делается один раз, а не каждый проход.
    BOOL split = [self wantsSplitIn:bounds];

    if (split != _split) {
        [self applySplit:split];
    }

    CGFloat pageWidth = [self pageWidthIn:bounds];

    CGFloat top = YTStatusBarHeight();

    /**
     * Высота кадра считается от ширины как 16:9, а не задаётся числом.
     * Число молча предполагало бы телефон шириной 320: на планшете та же
     * полоса растянулась бы на всю ширину, кадр вписался бы в неё
     * по высоте, и от ролика осталась бы четверть экрана.
     */
    CGFloat stageHeight = MIN(floor(pageWidth * 9.0 / 16.0), bounds.size.height / 2);

    [_stage setFrame:CGRectMake(0, top, pageWidth, stageHeight)];

    /**
     * Сообщение о стене и кнопка — по центру кадра: подпись выше середины,
     * кнопка под ней. Высота 44 и скругление 22 — как у «Повторить»
     * в `OfflinePanel`.
     */
    if (![_challenge isHidden]) {
        CGRect frame = [_stage frame];

        CGFloat textWidth = frame.size.width - 48;
        CGFloat textHeight = YTTextHeight([_gateLabel text], [_gateLabel font], textWidth, 0);

        CGFloat block = textHeight + 12 + 44;
        CGFloat blockTop = frame.origin.y + (frame.size.height - block) / 2;

        [_gateLabel setFrame:CGRectMake(24, blockTop, textWidth, textHeight)];

        [_challenge setFrame:CGRectMake((frame.size.width - 190) / 2,
                                        blockTop + textHeight + 12, 190, 44)];

        [[self view] bringSubviewToFront:_gateLabel];
        [[self view] bringSubviewToFront:_challenge];
    } else {
        [_gateLabel setFrame:CGRectZero];
        [_challenge setFrame:CGRectZero];
    }
    [self layoutStage];

    /**
     * Кадр едет вместе со страницей, а не висит прибитым сверху.
     *
     * В оригинале `Video.xaml` — одна `ScrollViewer`, и проигрыватель
     * лежит в ней первым блоком: прокрутил вниз к похожим и комментариям
     * — кадр ушёл вверх вместе с названием. Прибитый сверху кадр съедал
     * бы половину экрана телефона всё время, что человек читает
     * комментарии.
     *
     * Для этого кадр и переносится внутрь прокрутки. В полном экране
     * он возвращается наружу — там он сам себе весь экран.
     */
    if ([_stage superview] != _page) {
        [_page addSubview:_stage];
        [_page sendSubviewToBack:_stage];
    }

    [_page setFrame:CGRectMake(0, top, pageWidth, bounds.size.height - top)];
    [_stage setFrame:CGRectMake(0, 0, pageWidth, stageHeight)];

    [self layoutPage:pageWidth top:stageHeight];

    /**
     * Видимость ставится каждый проход, а не только при переезде: после
     * возврата из развёрнутого кадра раскладка та же, что была, и
     * `applySplit:` не позовётся — а колонку там спрятали.
     */
    [_side setHidden:!_split];
    [_columnDivider setHidden:!_split];

    if (!_split) {
        return;
    }

    /**
     * Правая колонка: черта во всю высоту, за ней очередь и похожие.
     * Начинается от той же отметки, что и кадр слева, — так колонки
     * стоят вровень.
     */
    [_side setBackgroundColor:[YTTheme background]];
    [_columnDivider setBackgroundColor:[YTTheme divider]];

    CGFloat right = bounds.size.width - pageWidth;

    [_columnDivider setFrame:CGRectMake(pageWidth, top, 0.5, bounds.size.height - top)];

    [_side setFrame:CGRectMake(pageWidth + 0.5, top,
                               right - 0.5, bounds.size.height - top)];

    CGFloat y = 12;

    y = [self layoutChaptersAt:y width:right - 0.5];
    y = [self layoutQueueAt:y width:right - 0.5];
    y = [self layoutRelatedAt:y width:right - 0.5];

    [_side setContentSize:CGSizeMake(right - 0.5, y + 24)];
}

- (void)layoutStage {
    CGRect box = [_stage bounds];

    [_videoHost setFrame:box];

    /**
     * Рамку слою ставим без преобразования, а потом возвращаем его.
     *
     * `frame` у слоя с преобразованием — величина вычисляемая, и запись
     * в неё при живом зуме съехала бы и по размеру, и по месту.
     */
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    [_playerLayer setAffineTransform:CGAffineTransformIdentity];
    [_playerLayer setFrame:box];

    [CATransaction commit];

    [self applyZoom];
    [_overlay setFrame:box];

    [self layoutSubtitles];

    [_busy setFrame:CGRectMake(box.size.width / 2 - 28, box.size.height / 2 - 28, 56, 56)];

    // `Margin="8,8,0,0"` и `Margin="0,8,8,0"` у кнопок сверху.
    [_minimize setFrame:CGRectMake(YTStageMargin, YTStageMargin,
                                   YTStageButton, YTStageButton)];

    [_settings setFrame:CGRectMake(box.size.width - YTStageMargin - YTStageButton,
                                   YTStageMargin, YTStageButton, YTStageButton)];

    // Статистика — в левом верхнем углу, под рядом кнопок, чтобы их не закрывать.
    [_stats setFrame:CGRectMake(YTStageMargin, YTStageMargin + YTStageButton + 4,
                                MIN(box.size.width - 2 * YTStageMargin, 480),
                                [_stats preferredHeight])];

    /**
     * Название поверх кадра: `Margin="16,10,64,0"` — справа оставлено место
     * под шестерёнку.
     */
    CGFloat titleWidth = box.size.width - 16 - 64;

    [_fullscreenTitle setFrame:CGRectMake(16, 10, titleWidth, 20)];
    [_fullscreenAuthor setFrame:CGRectMake(16, 32, titleWidth, 16)];

    [_playPause setFrame:CGRectMake(box.size.width / 2 - YTStageCenter / 2,
                                    box.size.height / 2 - YTStageCenter / 2,
                                    YTStageCenter, YTStageCenter)];

    /**
     * Перемотка — по сторонам от кнопки воспроизведения.
     *
     * Отступ считается от её края, а не от середины кадра: кнопка крупнее
     * прочих, и от середины числа пришлось бы подбирать заново при каждой
     * смене её размера.
     */
    CGFloat gap = 28;
    CGFloat sideTop = box.size.height / 2 - YTStageButton / 2;
    CGFloat playLeft = box.size.width / 2 - YTStageCenter / 2;

    [_rewind setFrame:CGRectMake(playLeft - gap - YTStageButton, sideTop,
                                 YTStageButton, YTStageButton)];

    [_forward setFrame:CGRectMake(playLeft + YTStageCenter + gap, sideTop,
                                  YTStageButton, YTStageButton)];

    // Число — понизу кнопки, под значком.
    [_rewindMark setFrame:CGRectMake(0, YTStageButton - 13, YTStageButton, 10)];
    [_forwardMark setFrame:CGRectMake(0, YTStageButton - 13, YTStageButton, 10)];

    // Нижняя полоса высотой 80 с картинкой-затемнением во всю ширину.
    CGFloat panelTop = box.size.height - YTBottomPanel;

    [_scrim setFrame:CGRectMake(0, panelTop, box.size.width, YTBottomPanel)];

    // Верхний ряд: `Height="40" Margin="0,8,0,0"`.
    CGFloat rowTop = panelTop + 8;

    [_fullscreen setFrame:CGRectMake(box.size.width - 16 - YTStageButton,
                                     rowTop + (YTBottomRow - YTStageButton) / 2,
                                     YTStageButton, YTStageButton)];

    [self layoutTimePill];

    // Нижний ряд: `Height="20" Margin="16,0,16,8"`.
    CGFloat trackRowTop = box.size.height - 8 - 20;

    [_track setFrame:CGRectMake(16, trackRowTop + (20 - YTTrackHeight) / 2,
                                box.size.width - 32, YTTrackHeight)];

    [self updateProgress];
}

/**
 * Плашка времени. Ширина считается по тексту: в оригинале это `Border`
 * с `Margin="10,5"` вокруг подписи, то есть он обжимает её, а не тянется.
 */
- (void)layoutTimePill {
    CGRect box = [_stage bounds];

    CGSize text = [[_time text] sizeWithFont:[_time font]];

    CGFloat pillWidth = ceil(text.width) + 20;
    CGFloat pillHeight = ceil(text.height) + 10;

    /**
     * Название главы дописывается к времени, и длина его не наша:
     * бывают главы, названные предложением. Плашка растёт по тексту,
     * но не дальше кнопки полного экрана — иначе она наползла бы
     * на неё, а самое нужное, время, ушло бы за край экрана.
     * Что не влезло, `UILabel` обрежет многоточием.
     */
    CGFloat room = box.size.width - 16 - 16 - YTStageButton - 12;

    if (pillWidth > room) {
        pillWidth = room;
    }

    CGFloat panelTop = box.size.height - YTBottomPanel + 8;
    CGFloat y = panelTop + (YTBottomRow - pillHeight) / 2;

    [_timePill setFrame:CGRectMake(16, y, pillWidth, pillHeight)];
    [_time setFrame:CGRectMake(16, y, pillWidth, pillHeight)];
}

- (void)layoutPage:(CGFloat)width top:(CGFloat)top {
    CGFloat content = width - YTPageMargin * 2;

    // Начинаем под кадром: он теперь первый блок той же прокрутки.
    // `StackPanel Margin="16,12"` вокруг названия.
    CGFloat y = top + 12;

    CGFloat titleHeight = YTTextHeight([_title text], [_title font], content, 0);

    [_title setFrame:CGRectMake(YTPageMargin, y, content, titleHeight)];

    /**
     * Накладка нажатия — по всему блоку названия вместе с отступами,
     * как `VideoInfoButton` в оригинале: там кнопкой служит весь
     * `StackPanel Margin="16,12"`, а не одна строка текста.
     */
    [_titleTouch setFrame:CGRectMake(0, y - 12, width, titleHeight + 24)];

    y += titleHeight + 12;

    /**
     * Строка канала: `Margin="16,0,16,16"`. Кружок 40, текст с отступом 12,
     * кнопка подписки прижата вправо и обжимает подпись
     * (`Padding="14,7"` вокруг текста 13 SemiBold).
     */
    CGSize subscribeText = [[_subscribeLabel text] sizeWithFont:[_subscribeLabel font]];

    /**
     * У подписанного в кнопку встают колокольчик 22 и стрелка 16
     * с отступом 6 — их ширину кнопка и обжимает.
     */
    CGFloat bellBlock = _subscribed ? (22 + 6 + 16 + 6) : 0;

    CGFloat subscribeWidth = ceil(subscribeText.width) + 28 + bellBlock;
    CGFloat subscribeHeight = ceil(subscribeText.height) + 14;

    CGFloat rowHeight = MAX(40, subscribeHeight);

    [_channelAvatar setFrame:CGRectMake(YTPageMargin, y + (rowHeight - 40) / 2, 40, 40)];

    CGFloat nameLeft = YTPageMargin + 40 + 12;

    // Между текстом и кнопкой — `Margin="0,0,8,0"` у левой колонки.
    CGFloat nameWidth = width - nameLeft - YTPageMargin - subscribeWidth - 8;

    CGFloat nameHeight = ceil([[_channelName font] lineHeight]);
    CGFloat subsHeight = ceil([[_channelSubs font] lineHeight]);
    CGFloat textBlock = nameHeight + 2 + subsHeight;
    CGFloat textTop = y + (rowHeight - textBlock) / 2;

    [_channelName setFrame:CGRectMake(nameLeft, textTop, nameWidth, nameHeight)];
    [_channelSubs setFrame:CGRectMake(nameLeft, textTop + nameHeight + 2,
                                      nameWidth, subsHeight)];

    CGRect subscribe = CGRectMake(width - YTPageMargin - subscribeWidth,
                                  y + (rowHeight - subscribeHeight) / 2,
                                  subscribeWidth, subscribeHeight);

    [_channelTouch setFrame:CGRectMake(YTPageMargin, y,
                                       subscribe.origin.x - YTPageMargin - 8, rowHeight)];

    [_subscribeFill setFrame:subscribe];
    [_subscribeTouch setFrame:subscribe];

    if (_subscribed) {
        // Подпись слева, за ней колокольчик и стрелка.
        CGRect text = subscribe;

        text.size.width -= bellBlock;

        [_subscribeLabel setFrame:text];

        CGFloat bellLeft = CGRectGetMaxX(text) - 8;
        CGFloat middle = subscribe.origin.y + (subscribeHeight - 22) / 2;

        [_bellIcon setFrame:CGRectMake(bellLeft, middle, 22, 22)];
        [_bellChevron setFrame:CGRectMake(bellLeft + 22 + 6,
                                          subscribe.origin.y + (subscribeHeight - 16) / 2,
                                          16, 16)];
    } else {
        [_subscribeLabel setFrame:subscribe];
    }

    y += rowHeight + 16;

    /**
     * Ряд действий: `Margin="16,2,16,16"`.
     *
     * Оценка — одна подложка на две кнопки: у «нравится» поля 16/8, у
     * «не нравится» 8/16, между ними черта 0.75×18. Значки по 20, счётчик
     * 14 с отступом 6 от значка.
     */
    y += 2;

    CGFloat actionHeight = 20 + 16;   // значок 20 плюс поля 8 сверху и снизу

    CGSize likeSize = [[_likeCount text] sizeWithFont:[_likeCount font]];
    CGFloat likeWidth = [[_likeCount text] length] > 0 ? ceil(likeSize.width) + 6 : 0;

    // Число дизлайков — тем же отступом 6, что счётчик у лайка.
    CGSize dislikeSize = [[_dislikeCount text] sizeWithFont:[_dislikeCount font]];
    CGFloat dislikeWidth = [[_dislikeCount text] length] > 0
        ? ceil(dislikeSize.width) + 6 : 0;

    CGFloat voteWidth = 16 + 20 + likeWidth + 8 + 0.75 + 8 + 20 + dislikeWidth + 16;

    // «Поделиться»: `Padding="16,8"`, значок 20, текст с отступом 6.
    CGSize shareSize = [[_shareLabel text] sizeWithFont:[_shareLabel font]];
    CGFloat shareWidth = 16 + 20 + 6 + ceil(shareSize.width) + 16;

    // «Сохранить» — так же; у безымянного её нет вовсе.
    BOOL saves = ![_savePill isHidden];

    CGSize saveSize = [[_saveLabel text] sizeWithFont:[_saveLabel font]];
    CGFloat saveWidth = saves ? 16 + 20 + 6 + ceil(saveSize.width) + 16 : 0;

    /**
     * «Скачать» — значок, а при загрузке ещё и проценты.
     *
     * Слова у неё нет нарочно, как и в оригинале: стрелка вниз понятна
     * без подписи. Проценты появляются лишь тогда, когда есть что
     * показывать.
     */
    CGSize downSize = [[_downloadLabel text] sizeWithFont:[_downloadLabel font]];
    CGFloat downText = [[_downloadLabel text] length] > 0 ? ceil(downSize.width) + 6 : 0;
    CGFloat downWidth = 16 + 20 + downText + 16;

    /**
     * Ряд прокручивается вбок, как `VideoActionsScrollViewer` оригинала.
     *
     * Прежде ему запрещалось вылезать за поля, и кнопки уступали место
     * по очереди: сперва слово «Поделиться», потом счётчик лайков.
     * С «Сохранить» и числом дизлайков уступать пришлось бы уже всем,
     * и на iPhone 4 счётчик лайков пропадал бы совсем. Оригинал решает
     * это прокруткой — и мы так же: ничего не прячется и не ужимается,
     * лишнее уезжает за край.
     *
     * Поля 16 — внутри прокрутки: ряд начинается с отступа, а уезжает
     * до самого края экрана.
     */
    [_actionScroll setFrame:CGRectMake(0, y, width, actionHeight)];

    CGFloat left = YTPageMargin;

    [_votePill setFrame:CGRectMake(left, 0, voteWidth, actionHeight)];

    CGFloat x = left + 16;

    [_likeIcon setFrame:CGRectMake(x, 8, 20, 20)];

    // Накладка шире значка: пальцем в двадцать точек не попасть.
    [_likeTouch setFrame:CGRectMake(left, 0, 16 + 20 + likeWidth + 4, actionHeight)];

    x += 20;

    if (likeWidth > 0) {
        [_likeCount setFrame:CGRectMake(x + 6, (actionHeight - likeSize.height) / 2,
                                        likeWidth - 6, ceil(likeSize.height))];
    }

    x += likeWidth + 8;

    [_voteSeparator setFrame:CGRectMake(x, (actionHeight - 18) / 2, 0.75, 18)];

    x += 0.75 + 8;

    [_dislikeIcon setFrame:CGRectMake(x, 8, 20, 20)];

    [_dislikeTouch setFrame:CGRectMake(x - 8, 0, 20 + dislikeWidth + 24, actionHeight)];

    if (dislikeWidth > 0) {
        [_dislikeCount setFrame:CGRectMake(x + 20 + 6,
                                           (actionHeight - dislikeSize.height) / 2,
                                           dislikeWidth - 6, ceil(dislikeSize.height))];
    } else {
        [_dislikeCount setFrame:CGRectZero];
    }

    left += voteWidth + 8;

    [_sharePill setFrame:CGRectMake(left, 0, shareWidth, actionHeight)];
    [_shareTouch setFrame:CGRectMake(left, 0, shareWidth, actionHeight)];
    [_shareIcon setFrame:CGRectMake(left + 16, 8, 20, 20)];

    [_shareLabel setHidden:NO];
    [_shareLabel setFrame:CGRectMake(left + 16 + 20 + 6,
                                     (actionHeight - shareSize.height) / 2,
                                     ceil(shareSize.width), ceil(shareSize.height))];

    left += shareWidth + 8;

    if (saves) {
        [_savePill setFrame:CGRectMake(left, 0, saveWidth, actionHeight)];
        [_saveTouch setFrame:CGRectMake(left, 0, saveWidth, actionHeight)];
        [_saveIcon setFrame:CGRectMake(left + 16, 8, 20, 20)];

        [_saveLabel setFrame:CGRectMake(left + 16 + 20 + 6,
                                        (actionHeight - saveSize.height) / 2,
                                        ceil(saveSize.width), ceil(saveSize.height))];

        left += saveWidth + 8;
    }

    [_downloadPill setFrame:CGRectMake(left, 0, downWidth, actionHeight)];
    [_downloadTouch setFrame:CGRectMake(left, 0, downWidth, actionHeight)];
    [_downloadIcon setFrame:CGRectMake(left + 16, 8, 20, 20)];

    if (downText > 0) {
        [_downloadLabel setFrame:CGRectMake(left + 16 + 20 + 6,
                                            (actionHeight - downSize.height) / 2,
                                            ceil(downSize.width), ceil(downSize.height))];
    } else {
        [_downloadLabel setFrame:CGRectZero];
    }

    left += downWidth + YTPageMargin;

    [_actionScroll setContentSize:CGSizeMake(left, actionHeight)];

    // Ряд сузился или экран повернули — прежний сдвиг мог уйти за край.
    CGFloat most = MAX((CGFloat)0, left - width);

    if ([_actionScroll contentOffset].x > most) {
        [_actionScroll setContentOffset:CGPointMake(most, 0)];
    }

    y += actionHeight + 16;

    /**
     * Карточка комментария: `Margin="16,0,16,16"`, `Padding="12"`,
     * заголовок 14 Bold с отступом 8, кружок 24 с отступом 10 справа,
     * автор и время в одну строку, текст в две.
     */
    if (![_commentsCard isHidden]) {
        CGFloat inner = content - 24;

        CGFloat headerHeight = ceil([[_commentsTitle font] lineHeight]);
        CGFloat authorHeight = ceil([[_commentAuthor font] lineHeight]);

        CGFloat textWidth = inner - 24 - 10;
        CGFloat textHeight = YTTextHeight([_commentText text], [_commentText font],
                                          textWidth, 2);

        CGFloat cardHeight = 12 + headerHeight + 8 + authorHeight + textHeight + 12;

        [_commentsCard setFrame:CGRectMake(YTPageMargin, y, content, cardHeight)];

        CGFloat left = YTPageMargin + 12;
        CGFloat cursor = y + 12;

        [_commentsTitle setFrame:CGRectMake(left, cursor, inner, headerHeight)];

        cursor += headerHeight + 8;

        [_commentAvatar setFrame:CGRectMake(left, cursor, 24, 24)];

        CGFloat timeWidth = 90;

        [_commentAuthor setFrame:CGRectMake(left + 34, cursor,
                                            textWidth - timeWidth - 6, authorHeight)];

        [_commentTime setFrame:CGRectMake(left + 34 + textWidth - timeWidth, cursor,
                                          timeWidth, authorHeight)];

        [_commentText setFrame:CGRectMake(left + 34, cursor + authorHeight,
                                          textWidth, textHeight)];

        [_commentsTouch setFrame:[_commentsCard frame]];
        [_commentsTouch setHidden:NO];

        y += cardHeight + 16;
    } else {
        [_commentsTouch setHidden:YES];
    }

    /**
     * Очередь и похожие в раздельной раскладке уезжают в правую колонку,
     * и здесь их место пропускается.
     */
    if (!_split) {
        y = [self layoutChaptersAt:y width:width];
        y = [self layoutQueueAt:y width:width];
        y = [self layoutRelatedAt:y width:width];
    }

    CGFloat statusHeight = YTTextHeight([_status text], [_status font], content, 0);

    [_status setFrame:CGRectMake(YTPageMargin, y, content, statusHeight)];

    y += statusHeight;

    [self finishPage:y];
}

/**
 * Очередь подборки: `Margin="16,0,16,16"`, `Padding="12"`,
 * скругление 12. Шапка — название и номер, справа стрелка 18.
 * Строки: превью 104×58, между ними 10.
 *
 * Ширина приходит снаружи: тот же блок стоит то во всю страницу,
 * то в правой колонке планшета, и своя у него только высота.
 */
/**
 * Главы: та же карточка, что у очереди, — отступы 16, поля 12,
 * скругление 12. Шапка с названием, подписью и стрелкой; строки —
 * метка времени 52 шириной и название рядом.
 *
 * Ширина приходит снаружи по той же причине, что и у очереди: блок
 * стоит то во всю страницу, то в правой колонке планшета.
 */
- (CGFloat)layoutChaptersAt:(CGFloat)y width:(CGFloat)width {
    if ([_chapterCard isHidden]) {
        return y;
    }

    CGFloat content = width - YTPageMargin * 2;
    CGFloat inner = content - 24;
    CGFloat headerHeight = 40;
    CGFloat stampWidth = 52;
    CGFloat textLeft = stampWidth + 10;

    // Высоты строк считаем заранее: у названий бывает и одна строка, и две.
    NSMutableArray *heights = [NSMutableArray array];
    CGFloat listHeight = 0;

    if (!_chaptersCollapsed) {
        for (YTTappableView *row in _chapterRows) {
            UILabel *name = [[row subviews] objectAtIndex:2];

            CGFloat textWidth = inner - 8 - textLeft;
            CGFloat height = YTTextHeight([name text], [name font], textWidth, 2);

            height = MAX(height, (CGFloat)20) + 16;

            [heights addObject:[NSNumber numberWithFloat:height]];
            listHeight += height;
        }

        if ([heights count] > 0) {
            listHeight += 10;
        }
    }

    CGFloat cardHeight = 12 + headerHeight + listHeight + 12;

    [_chapterCard setFrame:CGRectMake(YTPageMargin, y, content, cardHeight)];
    [_chapterCard setFillColor:[YTTheme surface]];

    [_chapterHeader setFrame:CGRectMake(YTPageMargin + 12, y + 12, inner, headerHeight)];

    [_chapterTitle setFrame:CGRectMake(0, 2, inner - 26, 18)];
    [_chapterNow setFrame:CGRectMake(0, 22, inner - 26, 16)];

    [_chapterChevron setImage:YTIcon(@"down_arrow")];
    [_chapterChevron setFrame:CGRectMake(inner - 18, (headerHeight - 18) / 2, 18, 18)];

    CGFloat rowY = y + 12 + headerHeight + 10;

    for (NSUInteger i = 0; i < [_chapterRows count]; i++) {
        YTTappableView *row = [_chapterRows objectAtIndex:i];

        [row setHidden:_chaptersCollapsed];

        if (_chaptersCollapsed) {
            continue;
        }

        CGFloat rowHeight = [[heights objectAtIndex:i] floatValue];

        [row setFrame:CGRectMake(YTPageMargin + 12 + 4, rowY, inner - 8, rowHeight)];

        NSArray *parts = [row subviews];

        if ([parts count] == 3) {
            UIView *stamp = [parts objectAtIndex:0];
            UILabel *time = [parts objectAtIndex:1];
            UILabel *name = [parts objectAtIndex:2];

            [stamp setFrame:CGRectMake(0, (rowHeight - 20) / 2, stampWidth, 20)];
            [time setFrame:CGRectMake(0, (rowHeight - 20) / 2, stampWidth, 20)];

            [name setFrame:CGRectMake(textLeft, 8,
                                      inner - 8 - textLeft, rowHeight - 16)];
        }

        rowY += rowHeight;
    }

    return y + cardHeight + 16;
}

- (CGFloat)layoutQueueAt:(CGFloat)y width:(CGFloat)width {
    CGFloat content = width - YTPageMargin * 2;

    if ([_queueCard isHidden]) {
        return y;
    }

    CGFloat inner = content - 24;
    CGFloat headerHeight = 40;

    CGFloat listHeight = 0;

    if (!_queueCollapsed) {
        listHeight = 10 + [_queueRows count] * (58 + 8 + 10);
    }

    CGFloat cardHeight = 12 + headerHeight + listHeight + 12;

    [_queueCard setFrame:CGRectMake(YTPageMargin, y, content, cardHeight)];
    [_queueCard setFillColor:[YTTheme surface]];

    [_queueHeader setFrame:CGRectMake(YTPageMargin + 12, y + 12, inner, headerHeight)];

    [_queueTitle setFrame:CGRectMake(0, 2, inner - 26, 18)];
    [_queuePosition setFrame:CGRectMake(0, 22, inner - 26, 16)];

    [_queueChevron setImage:YTIcon(@"down_arrow")];
    [_queueChevron setFrame:CGRectMake(inner - 18, (headerHeight - 18) / 2, 18, 18)];

    CGFloat rowY = y + 12 + headerHeight + 10;

    for (NSUInteger i = 0; i < [_queueRows count]; i++) {
        YTTappableView *row = [_queueRows objectAtIndex:i];

        [row setHidden:_queueCollapsed];

        if (_queueCollapsed) {
            continue;
        }

        CGFloat rowHeight = 58 + 8;

        [row setFrame:CGRectMake(YTPageMargin + 12 + 4, rowY, inner - 8, rowHeight)];

        NSArray *parts = [row subviews];

        if ([parts count] == 5) {
            UIView *thumb = [parts objectAtIndex:0];
            UILabel *name = [parts objectAtIndex:1];
            UILabel *author = [parts objectAtIndex:2];
            UIView *marker = [parts objectAtIndex:3];
            UIView *play = [parts objectAtIndex:4];

            [thumb setFrame:CGRectMake(0, 4, 104, 58)];

            CGFloat textLeft = 104 + 10;
            CGFloat textWidth = inner - 8 - textLeft;

            [name setFrame:CGRectMake(textLeft, 4, textWidth, 34)];
            [author setFrame:CGRectMake(textLeft, 41, textWidth, 16)];

            CGRect circle = CGRectMake((104 - 30) / 2, 4 + (58 - 30) / 2, 30, 30);

            [marker setFrame:circle];

            /**
             * Треугольник 15 внутри кружка 30, сдвинут вправо на
             * точку: `Margin="2,0,0,0"` в оригинале — та же поправка
             * на то, что зрительный центр треугольника левее
             * геометрического.
             */
            [play setFrame:CGRectMake(circle.origin.x + (30 - 15) / 2 + 1,
                                      circle.origin.y + (30 - 15) / 2, 15, 15)];
        }

        rowY += rowHeight + 10;
    }

    y += cardHeight + 16;

    return y;
}

/**
 * Заголовок над похожими и сами карточки. Ширина, как и у очереди,
 * приходит снаружи.
 */
- (CGFloat)layoutRelatedAt:(CGFloat)y width:(CGFloat)width {
    CGFloat content = width - YTPageMargin * 2;

    /**
     * Заголовок над похожими — `RelatedVideosContainerVertical`.
     */
    if ([_related count] > 0) {
        [_relatedTitle setHidden:NO];
        [_relatedTitle setFrame:CGRectMake(YTPageMargin, y, content, 20)];

        y += 20 + 12;
    } else {
        [_relatedTitle setHidden:YES];
    }

    /**
     * Похожие. На телефоне это те же карточки во всю ширину, что в ленте,
     * с отступом 16 между ними (`Margin="0,0,0,16"` у шаблона).
     */
    for (NSUInteger i = 0; i < [_relatedCards count]; i++) {
        YTVideoCard *card = [_relatedCards objectAtIndex:i];

        if ([card isHidden] || i >= [_related count]) {
            continue;
        }

        CGFloat cardHeight = [YTVideoCard heightForWidth:content
                                                   item:[_related objectAtIndex:i]];

        [card setFrame:CGRectMake(YTPageMargin, y, content, cardHeight)];

        y += cardHeight + 16;
    }

    return y;
}

/** Хвост страницы: поле снизу и высота прокрутки. */
- (void)finishPage:(CGFloat)y {
    [_page setContentSize:CGSizeMake([_page bounds].size.width, y + 24)];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    if (_commentsSheet != nil && ![_commentsSheet isHidden]) {
        [_commentsSheet setFrame:[[self view] bounds]];
    }

    // Панель настроек раскладывает себя сама — ей нужен только размер.
    if ([_menu isOpen]) {
        [_menu setFrame:[[self view] bounds]];
    }
}

#pragma mark Жизненный цикл

/**
 * Экран уходит — незавершённый запуск отменяется.
 *
 * Пока мы ходили за ответом и набирали первый кусок, человек мог уйти
 * назад. Мини-плеера у обычного ролика ещё нет, значит продолжать
 * незачем: подача занимала бы канал и память ради кадра, который никто
 * не увидит. Метка поколения двигается, и всё, что придёт следом,
 * отбросится само.
 */
- (void)cancelPendingStart {
    [_loadGeneration next];
}

/**
 * Страница вернулась из мини-окна — забираем плеер обратно.
 *
 * Проверка нужна именно здесь, а не только в `viewDidLoad`: возвращают
 * ту же самую страницу, а её `viewDidLoad` отработал давно и второй раз
 * не позовётся. Без этого свёрнутый ролик остался бы в окне, а страница
 * показала бы пустой кадр.
 */
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    BOOL wasLent = _minimising;

    _minimising = NO;

    if (_player == nil && [YTMiniPlayer isActive] &&
        [[YTMiniPlayer videoId] isEqualToString:_videoId]) {
        _adopted = YES;

        [self adoptFromMini];

        return;
    }

    /**
     * Вернулись, а плеера нет: пока мы ходили по каналу, мини-окно
     * закрыли крестиком.
     *
     * Страница цела — описание, похожие, очередь на месте, — но кадр
     * пустой и играть нечему. Поднимаем поток заново, с тем же качеством;
     * ответ `/player` у нас уже есть, второй раз за ним идти незачем.
     */
    if (wasLent && _player == nil && _playerJson != nil) {
        NSLog(@"[YouTube/Плеер] Вернулись без плеера — поднимаем поток заново");

        [self pickHeight:_pickedHeight force:YES];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    /**
     * Кнопки пульта идут по цепочке отвечающих, а начинается она с первого
     * отвечающего. Пока им никто не стал, кнопки на заблокированном экране
     * мертвы. Здесь, а не в `viewDidLoad`: стать первым отвечающим можно
     * только когда вид уже в окне.
     */
    [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    [self becomeFirstResponder];

    // Вернулись на страницу — карточка снова про этот ролик.
    if (_player != nil) {
        [self showNowPlaying];
    }
}

/**
 * Чат живёт при странице, а не при плеере.
 *
 * Гасить его в `teardownPlayer` было прямой ошибкой: тот зовётся из
 * `startPlayer:`, то есть **после** того, как метка чата уже получена
 * вместе с описанием. Метка стиралась сразу после появления, нажатие по
 * плашке проваливалось в комментарии — а у эфира их нет, — и не делало
 * ровно ничего. Плеер пересобирается и при смене качества, и при смене
 * дорожки; разговор к этому отношения не имеет.
 */
- (void)viewWillDisappear:(BOOL)animated {
    [self stopLiveChat];

    [super viewWillDisappear:animated];

    [_hideTimer invalidate];
    _hideTimer = nil;

    /**
     * Сторож застревания снимается и при сворачивании: плеер уходит
     * к мини-окну, а таймер продолжил бы будить страницу, которой
     * на виду уже нет, и держал бы её в памяти собой же.
     */
    [self stopStallWatch];

    /**
     * Сначала отпускаем плеер, и только потом трогаем прокси. В обратном
     * порядке прежний плеер продолжал бы просить сегменты у уже закрытой
     * сессии, получал бы отказ и уходил в ошибку ровно тогда, когда его
     * и так снимают.
     */
    if (_minimising) {
        // Свернулись: плеер уже у мини-окна, глушить нечего.
        return;
    }

    [self cancelPendingStart];
    [self teardownPlayer];

    [[YTHlsProxy shared] close];

    if (_fullscreenMode) {
        [[UIApplication sharedApplication] setStatusBarHidden:NO
                                                withAnimation:UIStatusBarAnimationNone];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
