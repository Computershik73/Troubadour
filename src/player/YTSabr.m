#import "YTSabr.h"

#import <UIKit/UIKit.h>

#import "YTApi.h"
#import "YTStreams.h"
#import "YTHttp.h"
#import "YTNSig.h"
#import "YTProto.h"
#import "YTUmp.h"
#import "YTMp4.h"
#import "YTPlaybackStats.h"

@implementation YTSabrFormat

@synthesize itag = _itag;
@synthesize lastModified = _lastModified;
@synthesize xtags = _xtags;

+ (YTSabrFormat *)formatWithItag:(NSInteger)itag lastModified:(uint64_t)lastModified {
    YTSabrFormat *format = [[YTSabrFormat alloc] init];

    format.itag = itag;
    format.lastModified = lastModified;

    return format;
}

@end

/** Разобранный `MediaHeader` — ровно те поля, что нам нужны. */
@interface YTSabrHeader : NSObject

@property (nonatomic, assign) NSUInteger headerId;
@property (nonatomic, assign) NSInteger itag;
@property (nonatomic, assign) uint64_t lastModified;
@property (nonatomic, assign) BOOL isInit;
@property (nonatomic, assign) NSInteger sequence;
@property (nonatomic, assign) int64_t startMs;
@property (nonatomic, assign) int64_t durationMs;

@end

@implementation YTSabrHeader

@synthesize headerId = _headerId;
@synthesize itag = _itag;
@synthesize lastModified = _lastModified;
@synthesize isInit = _isInit;
@synthesize sequence = _sequence;
@synthesize startMs = _startMs;
@synthesize durationMs = _durationMs;

@end

@implementation YTSabr {
    NSString *_url;
    NSData *_config;
    NSString *_videoId;
    NSString *_poToken;

    NSInteger _requestNumber;

    /** Когда началась эта сессия подачи — поле 13 у TV-клиента. */
    NSTimeInterval _sessionFrom;

    /** Когда последний раз пришёл кусок — любой, хоть повтор. */
    NSTimeInterval _lastMediaAt;

    /**
     * Получили часть №69 — в следующем запросе обязано уйти поле 24.
     *
     * Правило снято с дампа yttv5 и выполняется там в ста девяти случаях
     * из ста девяти: поле 24 = {8: 7} стоит в запросе ровно тогда, когда
     * предыдущий ответ нёс часть №69, и ни в каком другом.
     */
    BOOL _ackResumePoint;

    /** Когда в журнал последний раз писались правила следующего запроса. */
    NSTimeInterval _policySaidAt;

    /** Последнее отправленное поле 29 — для строки такта. */
    int64_t _lastWatchedMs;

    /** Когда в журнал последний раз писался перечень набранного. */
    NSTimeInterval _runsSaidAt;

    /** Названы ли серверу дорожки: перечень нужен раз на сессию. */
    BOOL _toldFormats;

    /** Правили ли уже `n` в адресе подачи. */
    BOOL _fixed;

    /** Сервер попросил обновить ответ `/player`. */
    BOOL _needsReload;

    /** Нас отправили на другой узел — надо повторить запрос туда. */
    BOOL _redirected;

    /** Сколько запросов подряд подача отбила отказом. */
    NSInteger _failures;

    /** Первый кусок эфира, что у нас был, и его время: см. `noteLiveSeen:at:`. */
    NSInteger _liveSeenSeq;
    int64_t _liveSeenMs;

    /** Сколько раз уже выписали незнакомую часть — чтобы не залить журнал. */
    NSMutableDictionary *_unknownSeen;

    /** Сколько фрагментов подача принесла за всё время. */
    NSUInteger _delivered;

    /** То же, но считая повторы: сервер отматывает нас назад, и это жизнь. */
    NSUInteger _received;

    /** Когда в последний раз пришёл новый кусок — мерило застоя. */
    NSTimeInterval _lastDeliveryAt;

    /** Идёт набор запаса: оттяжки просьбы вперёд в это время не нужны. */
    BOOL _prefilling;

    /** Откуда продолжать, если подачу подменили под идущим показом. */
    NSTimeInterval _liveStartHint;


    /** До какой отметки уже объявляли переступ дыры — чтобы не повторяться. */
    NSTimeInterval _liveSkippedTo;

    /** Предел отдачи: конец окна перемотки (часть №31, поля 14/15). */
    NSTimeInterval _liveSeekSeconds;

    /** Когда этот предел нам назвали — он уезжает вперёд вместе с часами. */
    NSTimeInterval _liveSeekSeenAt;

    /** Номер головного куска (часть №31, поле 3) — чтобы считать время по номеру. */
    int64_t _liveHeadSequence;

    /** Место, с которого сервер просит продолжить (часть №69, поле 1.1.9). */
    NSTimeInterval _liveResumeAt;

    /** Просим «играющее сейчас»: край ещё не известен (первый заход). */
    BOOL _askLiveNow;

    /** Когда это указание пришло — дольше двадцати секунд ему не верим. */
    NSTimeInterval _liveResumeSaidAt;

    /** Когда последний раз выписывали часть №69 целиком. */
    NSTimeInterval _liveResumeDumpAt;


    /** С какого мгновения сервер отказывает (часть №69 без кусков). */
    NSTimeInterval _liveRefusedSince;

    /** Лестница дорожек как её выбрали, и когда её переставили из-за дыры. */
    NSArray *_preferredVideo;
    NSTimeInterval _rotatedAt;

    /** Когда последний раз выписывали часть №31, сведения о дорожке, запрос. */
    NSTimeInterval _liveHeadSaidAt;
    NSTimeInterval _formatInitSaidAt;
    NSTimeInterval _requestSaidAt;

    /** Токен для перезапроса ответа `/player`, если сервер его дал. */
    NSString *_reloadToken;

    /**
     * Что у нас уже есть: дорожка, последний номер и докуда набрано
     * по времени. Из этого складывается `buffered_ranges` — перечень,
     * без которого сервер шлёт одно и то же начало.
     */
    YTSabrFormat *_gotVideo;
    YTSabrFormat *_gotAudio;

    NSInteger _firstVideoSeq;
    NSInteger _firstAudioSeq;

    NSInteger _lastVideoSeq;
    NSInteger _lastAudioSeq;

    /** С какого времени идёт нынешний набранный кусок. */
    int64_t _rangeStartMs;

    int64_t _videoFilledMs;
    int64_t _audioFilledMs;

    /**
     * Печенье воспроизведения — им сервер помнит, что уже отдал.
     *
     * Приходит в правилах следующего запроса и возвращается в описании
     * клиента. Без него каждый запрос начинается сначала: сервер шлёт
     * те же первые фрагменты, и дальше первых секунд не уехать.
     */
    NSData *_playbackCookie;

    /** Сколько сервер просит подождать перед следующим запросом, мс. */
    int64_t _backoffMs;

    YTSabrFormat *_video;
    YTSabrFormat *_audio;

    /** Все дорожки ролика — они уходят в предпочтения. */
    NSArray *_allVideo;
    NSArray *_allAudio;

    NSData *_videoInit;
    NSData *_audioInit;

    /** Те же заголовки, разобранные: нужны, чтобы мерить длину кусков эфира. */
    YTTrackInit *_videoInitParsed;
    YTTrackInit *_audioInitParsed;
    NSData *_videoInitParsedFrom;
    NSData *_audioInitParsedFrom;

    /** Номер дорожки, которой принадлежат нынешние init-заголовки. */
    NSInteger _videoInitItag;
    NSInteger _audioInitItag;

    /** Номера кусков, перенятых у прежней подачи: байтов у нас нет. */
    NSMutableSet *_claimedVideo;
    NSMutableSet *_claimedAudio;

    NSMutableDictionary *_videoSegments;
    NSMutableDictionary *_audioSegments;

    /** Времена фрагментов: номер → начало и длительность в миллисекундах. */
    NSMutableDictionary *_videoTimes;
    NSMutableDictionary *_audioTimes;

    NSInteger _videoSegmentCount;

    /** Номер видеодорожки, которую сервер выбрал сам. */
    NSInteger _playingItag;

    /** Ступень, которую мы просим: она же уходит в состояние клиента. */
    NSInteger _wantedHeight;

    /** Закреплённая дорожка, признак ручного выбора и след срыва. */
    YTSabrFormat *_pinnedVideo;

    /** Что последний раз сказали о возможностях — чтобы не повторяться. */
    NSString *_capsSaid;

    /** Последний отказ был «ни одной дорожки не выбрано». */
    BOOL _refusedNoVideo;

    /** Отпускали ли уже закрепление после такого отказа. */
    BOOL _softenedPin;
    BOOL _hardPin;
    BOOL _trackChanged;

    /** Какая дорожка приходила в прошлый раз — по ней и видно смену. */
    NSInteger _deliveredItag;
    NSTimeInterval _duration;

    /** Собираемые сейчас сегменты: номер заголовка → заголовок и байты. */
    NSMutableDictionary *_openHeaders;
    NSMutableDictionary *_openBodies;

    /**
     * Перечень частей последнего ответа — для журнала.
     *
     * Разбираем мы только знакомые части, и по журналу не отличить
     * «сервер этого не прислал» от «мы этого не поняли». А отличать
     * приходится: заголовков дорожек нет, и надо знать, чья это беда.
     */
    NSMutableString *_seen;
}

@synthesize liveMode = _liveMode;
@synthesize liveStartSeconds = _liveStartSeconds;
/**
 * «Играю прямо сейчас» — такое время плеера шлёт сам TV-клиент.
 *
 * Это `Number.MAX_SAFE_INTEGER`, 2^53−1. В дампе движения youtube.com/tv
 * (yttv.har и yttv2.har, оба захода) первый запрос живой сессии выглядит
 * ровно так: поле 28 равно этому числу, диапазонов набранного нет вовсе —
 * и сервер первым же ответом отдаёт край, сто тридцать килобайт медиа.
 *
 * Ноль в том же месте означает другое: «с начала окна перемотки». На
 * круглосуточной волне это двенадцать часов назад, и именно оттуда нам
 * приходил первый кусок на холодном запуске (журнал 75: «первый кусок на
 * 43180 с позади края»). Лишний ход, потерянные секунды и список,
 * открытый одним куском.
 */
static const int64_t YTLiveNow = 9007199254740991LL;

/**
 * Насколько позади края начинаем набирать, в секундах.
 *
 * Сто двадцать — и величина эта не про ёмкость плеера, а про то, где
 * сервер отдаёт **пачкой**. Разница принципиальная, и я на ней уже
 * ошибся: в 1.4-117 опустил старт до края минус шестьдесят, рассудив
 * «больше плеер всё равно не удержит». Ёмкость тут ни при чём.
 *
 * У края сервер отдаёт по одному куску за ответ — придерживает соединение
 * до нарезки, это его обычный ход. Журнал 69: старт сел близко к краю, и
 * за восемь секунд набралось два куска подряд вместо десяти, а порядок был
 * 3792, 3789, 3790 шесть раз, 3791, 3782, 3786 — вразнобой и по одному.
 * Показ начался с двадцати секунд запаса и с ними же остался: у края запас
 * не растёт, это измерено (см. `openLiveWithSabr:`).
 *
 * А то, что уже нарезано, сервер отдаёт разом: в прежних журналах видно
 * одиннадцать кусков двумя пачками за две секунды. Значит стартовать надо
 * настолько позади, чтобы впереди лежало готовое — тогда плеер наберёт
 * свои полсотни секунд за считанные секунды и дальше поедет у края.
 *
 * Риска «уползти в отказ» тут больше нет: время плеера (поле 28) с 1.4-119
 * держится у края само по себе и от места набора не зависит.
 */
enum { YTLiveCushion = 120 };

@synthesize liveHeadSeconds = _liveHeadSeconds;

- (id)initWithUrl:(NSString *)abrUrl
           config:(NSData *)config
          videoId:(NSString *)videoId
          poToken:(NSString *)poToken {
    self = [super init];

    if (self != nil) {
        _url = [abrUrl copy];
        _config = config;
        _videoId = [videoId copy];
        _poToken = [poToken copy];

        _sessionFrom = [NSDate timeIntervalSinceReferenceDate];

        _claimedVideo = [[NSMutableSet alloc] init];
        _claimedAudio = [[NSMutableSet alloc] init];

        _videoSegments = [[NSMutableDictionary alloc] init];
        _audioSegments = [[NSMutableDictionary alloc] init];
        _videoTimes = [[NSMutableDictionary alloc] init];
        _audioTimes = [[NSMutableDictionary alloc] init];
        _openHeaders = [[NSMutableDictionary alloc] init];
        _openBodies = [[NSMutableDictionary alloc] init];
        _seen = [[NSMutableString alloc] init];
    }

    return self;
}

/**
 * Перенимаем отчёт о набранном — иначе сервер молчит свежей подаче.
 *
 * Журнал 80 показал это в чистом виде. Каждые двенадцать секунд мы берём
 * свежую подачу, она делает первую просьбу — и «первый кусок не пришёл».
 * И так, не сбиваясь, всю минуту, пока запас стоит на нуле.
 *
 * Причина в том, что с 1.4-147 мы носим одну метку показа `cpn` на весь
 * просмотр, как это делает браузер. Для сервера мы теперь один и тот же
 * зритель, которому он уже отдал куски до такого-то номера. А свежая
 * подача, родившись пустой, в перечне набранного не заявляет **ничего**:
 * ни одного диапазона. Выходит спор: зритель тот же, а держит он якобы
 * пустоту. Сервер отвечает на это указанием продолжить с того же куска и
 * ни единым байтом — ровно то «молчание», о котором речь.
 *
 * Браузер в такое противоречие не попадает: у него подача одна на весь
 * показ, и перечень она ведёт непрерывно — в дампе он есть в ста шести
 * просьбах из ста десяти и тянется на сто семьдесят шесть секунд.
 *
 * Байты новой подаче не нужны, их держит раздача. Нужно знание: какие
 * номера и времена у нас есть и с какого куска начинается наш отчёт.
 */
- (void)adoptLiveProgressFrom:(YTSabr *)other {
    if (other == nil || !_liveMode || !other->_liveMode) {
        return;
    }

    /**
     * Чужие словари читаем под замком той подачи: она в это время живёт
     * своим потоком и продолжает класть в них куски.
     */
    NSDictionary *videoTimes;
    NSDictionary *audioTimes;
    NSArray *videoKeys;
    NSArray *audioKeys;

    @synchronized (other) {
        videoTimes = [NSDictionary dictionaryWithDictionary:other->_videoTimes];
        audioTimes = [NSDictionary dictionaryWithDictionary:other->_audioTimes];
        videoKeys = [other->_videoSegments allKeys];
        audioKeys = [other->_audioSegments allKeys];
    }

    [_videoTimes addEntriesFromDictionary:videoTimes];
    [_audioTimes addEntriesFromDictionary:audioTimes];

    /**
     * Перенятые номера держим **отдельно**, а не в хранилище фрагментов.
     *
     * В 1.4-154 я клал сюда `[NSNull null]` — как отметку «этот кусок у
     * нас есть». Но это хранилище держит байты: раздача берёт из него
     * `[sabr videoSegment:n]` и сразу спрашивает длину. У `NSNull` такого
     * не спросишь, и приложение падало с неперехваченным исключением —
     * оба отчёта, за 18:09:55 и 18:18:24, указывают в `collectData:`,
     * вызванный из сборки куска.
     *
     * Байтов у свежей подачи и нет, они у прежней и у раздачи. Ей нужно
     * лишь знание о номерах — для перечня набранного. Вот его и держим
     * в стороне.
     */
    [_claimedVideo addObjectsFromArray:videoKeys];
    [_claimedAudio addObjectsFromArray:audioKeys];

    /**
     * Начало перечня берём осмысленное.
     *
     * В журнале 81 перенос написал «начало перечня №31» — число из другой
     * жизни, и перечень с него сервер прочесть не мог. Если у прежней
     * подачи отметка не вяжется с тем, что она держит, берём самый старый
     * из перенятых кусков: его номер и время известны точно.
     */
    _liveSeenSeq = other->_liveSeenSeq;
    _liveSeenMs = other->_liveSeenMs;

    NSArray *keys = [[_videoSegments allKeys]
        sortedArrayUsingSelector:@selector(compare:)];

    NSInteger oldest = [keys count] > 0 ? [[keys objectAtIndex:0] integerValue] : 0;

    if (oldest > 0 && (_liveSeenSeq < oldest - 2000 || _liveSeenSeq > oldest)) {
        _liveSeenSeq = oldest;
        _liveSeenMs = (int64_t)([self timeIn:_videoTimes
                                    sequence:oldest part:0] * 1000.0);
    }

    _firstVideoSeq = other->_firstVideoSeq;
    _firstAudioSeq = other->_firstAudioSeq;
    _lastVideoSeq = other->_lastVideoSeq;
    _lastAudioSeq = other->_lastAudioSeq;

    _gotVideo = other->_gotVideo;
    _gotAudio = other->_gotAudio;

    NSLog(@"[YouTube/Подача] Эфир: свежая подача переняла отчёт — "
          @"куски %ld…%ld, начало перечня №%ld",
          (long)_firstVideoSeq, (long)_lastVideoSeq, (long)_liveSeenSeq);
}

- (void)adoptUrl:(NSString *)abrUrl config:(NSData *)config {
    if ([abrUrl length] == 0 || [config length] == 0) {
        return;
    }

    _url = [abrUrl copy];
    _config = config;

    /**
     * Адрес свежий — значит, `n` в нём ещё не правлена. А печенье
     * воспроизведения осталось от прежней сессии и новой ни о чём не
     * говорит: отправив его, мы получим отказ на ровном месте.
     */
    _fixed = NO;
    _failures = 0;
    _playbackCookie = nil;

    _needsReload = NO;
    _reloadToken = nil;

    /**
     * Набранное не трогаем: ролик тот же и фрагменты в нём те же —
     * терять запас из-за смены адреса незачем.
     */
}

- (BOOL)needsReload {
    return _needsReload;
}

- (NSString *)videoId {
    return _videoId;
}

- (NSInteger)playingItag {
    return _playingItag;
}

- (NSInteger)deliveredVideoItag {
    return _deliveredItag;
}

- (NSInteger)audioItag {
    return _audioInitItag;
}

- (NSInteger)requests {
    return _requestNumber;
}

- (void)pinVideo:(YTSabrFormat *)format hard:(BOOL)hard {
    if (format == nil) {
        return;
    }

    _pinnedVideo = format;

    // Выбор поменялся — скажем серверу перечень заново, один раз.
    _toldFormats = NO;
    _hardPin = hard;

    NSInteger frames = [YTStreams framesForItag:format.itag];

    NSLog(@"[YouTube/Подача] Дорожка закреплена: itag %ld (%ldp%@), %@",
          (long)format.itag, (long)format.height,
          frames > 0 ? [NSString stringWithFormat:@", %ld кадр/с", (long)frames] : @"",
          hard ? @"выбор человека — менять нельзя" : @"сама, до конца ролика");
}

- (NSInteger)pinnedVideoItag {
    return _pinnedVideo != nil ? _pinnedVideo.itag : 0;
}

- (BOOL)takeVideoTrackChanged {
    BOOL changed = _trackChanged;

    _trackChanged = NO;

    return changed;
}

- (BOOL)stepDownVideo {
    if (_hardPin) {
        return NO;
    }

    NSInteger now = _pinnedVideo != nil ? _pinnedVideo.height : 0;

    if (now <= 0) {
        return NO;
    }

    YTSabrFormat *below = nil;

    for (YTSabrFormat *format in _allVideo) {
        if (format.height <= 0 || format.height >= now) {
            continue;
        }

        if (below == nil || format.height > below.height) {
            below = format;
        }
    }

    if (below == nil) {
        return NO;
    }

    NSLog(@"[YouTube/Подача] Спускаемся сами: %ldp вместо %ldp — набор "
          @"не поспевает", (long)below.height, (long)now);

    _pinnedVideo = below;

    // Выбор поменялся — скажем серверу перечень заново, один раз.
    _toldFormats = NO;

    return YES;
}

- (void)setWantedHeight:(NSInteger)height {
    _wantedHeight = height;
}

/**
 * Ступень под стать экрану — для «Авто».
 *
 * Берётся ближайшая из обычных, а не первая сверху: у экрана 640 точек
 * по короткой стороне ближе 720p, чем 480p, а у 768 — те же 720p, чем
 * 1080p. Так «Авто» на телефоне остаётся тем же, чем было, а на крупном
 * экране перестаёт упираться в семьсот двадцатку.
 */
- (NSInteger)tierForScreen:(NSInteger)edge {
    NSInteger tiers[] = { 144, 240, 360, 480, 720, 1080 };
    NSUInteger count = sizeof(tiers) / sizeof(tiers[0]);

    NSInteger best = tiers[count - 1];
    NSInteger closest = NSIntegerMax;

    for (NSUInteger i = 0; i < count; i++) {
        NSInteger distance = labs((long)(tiers[i] - edge));

        if (distance < closest) {
            closest = distance;
            best = tiers[i];
        }
    }

    return best;
}

- (void)setAvailableVideo:(NSArray *)video audio:(NSArray *)audio {
    _allVideo = video;
    _allAudio = audio;
    _preferredVideo = video;
    _rotatedAt = 0;
}

/**
 * Соседнюю ступень — на первое место.
 *
 * Разбор части №69 показал, что при остановке сервер **сам** ждёт кусок
 * (поле 9=3137873) и не дожидается: у дорожки 136 минутная дыра.
 * Браузер тем временем играет VP9 — другой конвейер кодирования, и дыры
 * в H.264-лестнице его не касаются. VP9 нам недоступен, но ступеней
 * H.264 несколько, и у соседней дыры может не быть: сервер берёт
 * первую названную, вот её и меняем. Через минуту ровного хода
 * порядок возвращается — качество поднимется само.
 */
- (void)preferNeighbourRung {
    if (!_liveMode || [_allVideo count] < 2) {
        return;
    }

    NSInteger current = _deliveredItag > 0
        ? _deliveredItag
        : (_pinnedVideo != nil ? _pinnedVideo.itag : 0);

    YTSabrFormat *now = nil;

    for (YTSabrFormat *format in _allVideo) {
        if (format.itag == current) {
            now = format;
        }
    }

    if (now == nil) {
        now = [_allVideo objectAtIndex:0];
    }

    YTSabrFormat *below = nil;

    for (YTSabrFormat *format in _allVideo) {
        if (format.height > 0 && format.height < now.height
            && (below == nil || format.height > below.height)) {
            below = format;
        }
    }

    // Ниже некуда — начинаем сначала, с лучшей.
    if (below == nil) {
        _allVideo = _preferredVideo;
        _pinnedVideo = [_preferredVideo objectAtIndex:0];
        _rotatedAt = [NSDate timeIntervalSinceReferenceDate];

        NSLog(@"[YouTube/Подача] Эфир: ступени кончились — снова с %ldp",
              (long)_pinnedVideo.height);

        return;
    }

    NSMutableArray *order = [_allVideo mutableCopy];

    [order removeObject:below];
    [order insertObject:below atIndex:0];

    _allVideo = order;
    _pinnedVideo = below;

    // Выбор поменялся — скажем серверу перечень заново, один раз.
    _toldFormats = NO;
    _rotatedAt = [NSDate timeIntervalSinceReferenceDate];

    NSLog(@"[YouTube/Подача] Эфир: у %ldp дыра — просим %ldp",
          (long)now.height, (long)below.height);
}

/** Минута ровного хода — возвращаем лестницу как была. */
- (void)restorePreferredRung {
    if (_rotatedAt <= 0 || _preferredVideo == nil) {
        return;
    }

    if ([NSDate timeIntervalSinceReferenceDate] - _rotatedAt < 60.0) {
        return;
    }

    _allVideo = _preferredVideo;
    _pinnedVideo = [_preferredVideo objectAtIndex:0];
    _rotatedAt = 0;

    NSLog(@"[YouTube/Подача] Эфир: минута ровного хода — снова просим %ldp",
          (long)_pinnedVideo.height);
}

/**
 * Видео ли это, судя по номеру дорожки.
 *
 * Сравнивать с одним заранее выбранным номером нельзя: выбирает сервер,
 * и он вправе прислать любую из перечисленных. Пока сравнивали, всё,
 * что не совпало, зачислялось в звук — и в журнале появлялся
 * «фрагмент звука itag 303».
 */
/** Метки дорожки по её номеру и времени правки — из нашего же списка. */
- (NSString *)xtagsForItag:(NSInteger)itag lastModified:(uint64_t)lastModified {
    for (NSArray *list in [NSArray arrayWithObjects:_allVideo, _allAudio, nil]) {
        for (YTSabrFormat *format in list) {
            if (format.itag == itag && format.lastModified == lastModified) {
                return format.xtags;
            }
        }
    }

    return nil;
}

/**
 * Пришла дорожка — сверяемся с закреплённой.
 *
 * При «Авто» первая же пришедшая и становится закреплённой: дальше
 * менять её незачем, а декодеру нужна постоянная. Если пришла другая
 * вопреки закреплению — поднимаем однократный флаг: плеер по нему
 * заведёт декодер начисто, иначе картинка посыплется. При мягком
 * закреплении вдобавок переезжаем на присланную: спорить с сервером
 * до бесконечности дороже, чем принять его выбор один раз.
 */
- (void)noteDeliveredVideoItag:(NSInteger)itag {
    if (itag <= 0) {
        return;
    }

    /**
     * Смену замечаем по самой пришедшей дорожке, а не по закреплению.
     *
     * Спуск на ступень ниже мы делаем и сами: закрепление тогда уже
     * новое, и сверка с ним ничего бы не показала — а разрешение
     * поменялось, и декодер об этом знать обязан.
     */
    if (_deliveredItag != 0 && itag != _deliveredItag) {
        _trackChanged = YES;
    }

    _deliveredItag = itag;

    if (_pinnedVideo == nil) {
        for (YTSabrFormat *format in _allVideo) {
            if (format.itag == itag) {
                [self pinVideo:format hard:NO];

                return;
            }
        }

        return;
    }

    if (itag == _pinnedVideo.itag) {
        return;
    }

    NSLog(@"[YouTube/Подача] Сервер прислал itag %ld вместо закреплённой %ld — "
          @"%@", (long)itag, (long)_pinnedVideo.itag,
          _hardPin ? @"держим свою" : @"принимаем и закрепляем присланную");

    if (_hardPin) {
        return;
    }

    for (YTSabrFormat *format in _allVideo) {
        if (format.itag == itag) {
            _pinnedVideo = format;

    // Выбор поменялся — скажем серверу перечень заново, один раз.
    _toldFormats = NO;

            return;
        }
    }
}

- (BOOL)isVideoItag:(NSInteger)itag {
    for (YTSabrFormat *format in _allVideo) {
        if (format.itag == itag) {
            return YES;
        }
    }

    return NO;
}

#pragma mark Сборка запроса

/** `misc.FormatId`: номер дорожки, время правки, метки. */
- (YTProtoWriter *)formatId:(YTSabrFormat *)format {
    YTProtoWriter *writer = [YTProtoWriter writer];

    [writer putVarint:(uint64_t)format.itag field:1];

    /**
     * У эфира дорожка называется одним номером.
     *
     * Перехваченный запрос web-плеера к тому же эфиру: и в перечне
     * набранного, и в списках дорожек — `{itag, версия 0, xtags пусто}`.
     * Мы же слали версию из заголовка (`last_modified`) и xtags, и по
     * этой «версии» сервер наш перечень не узнавал: считал, что у нас
     * пусто, и раз за разом присылал один и тот же головной кусок —
     * в журнале шесть минут подряд «Фрагмент 3137323» каждые 0,7 с.
     * У записи версия дорожки настоящая, там всё остаётся как было.
     */
    if (_liveMode) {
        [writer putVarint:0 field:2];

        /**
         * Третье поле — пустое, но **присутствующее**.
         *
         * Слепки рядом: у web-плеера дорожка везде `{1=140 2=0 3=<0:>}`,
         * у нас `{1=136 2=0}` — писатель пустую строку выбрасывал.
         * Для сервера с семантикой proto2 «поле есть» и «поля нет» —
         * разные идентификаторы, и наш перечень набранного мог не
         * совпадать с его дорожкой ровно из-за этого: он присылал
         * уже отданное и держал в «ожидании» то, что мы просили.
         */
        [writer putData:[NSData data] field:3];

        return writer;
    }

    [writer putVarint:format.lastModified field:2];
    [writer putString:format.xtags field:3];

    return writer;
}

/**
 * `StreamerContext` — кто просит.
 *
 * Здесь же уезжает PO-токен, и это единственное место, где подача
 * его ждёт. Кладётся он **байтами**, а не строкой: токен приходит
 * в записи base64url, и её надо раскодировать, иначе сервер видит
 * мусор.
 */
- (YTProtoWriter *)streamerContext {
    YTProtoWriter *info = [YTProtoWriter writer];

    /**
     * Представляемся тем же клиентом, чьим ответом получен адрес, —
     * и **той же версией**.
     *
     * Здесь стояла вписанная руками `7.20260715.15.00`, а это версия
     * плеера, не клиента: запрос `/player` уходит от TVHTML5 другой
     * версии. Сервер видел, что ответ выдан одному, а подачи просит
     * другой, и отвечал просьбой обновить ответ — без единого слова
     * о причине.
     */
    NSDictionary *who = [YTApi streamClientInfo];

    NSString *make = [who objectForKey:@"make"];
    NSString *model = [who objectForKey:@"model"];

    if ([make length] > 0) {
        [info putString:make field:12];
    }

    if ([model length] > 0) {
        [info putString:model field:13];
    }

    [info putVarint:(uint64_t)[[who objectForKey:@"number"] integerValue] field:16];
    [info putString:[who objectForKey:@"version"] field:17];
    [info putString:[who objectForKey:@"osName"] field:18];
    [info putString:[who objectForKey:@"osVersion"] field:19];

    /**
     * Хвост, одинаковый у всех клиентов: язык, страна, размеры экрана.
     *
     * Взят из рабочей реализации Opaline, где он уходит с каждым запросом
     * вне зависимости от клиента. Сами по себе эти поля ничего не решают,
     * но описание клиента без них неполно, а сверяет его сервер целиком.
     */
    /**
     * Сведения о клиенте — дословно по дампу yttv5.
     *
     * У браузера в 19.1 семь полей: 1 — локаль вида `ru_RU`, 12 — Samsung,
     * 13 — SmartTV, 16 — номер клиента 7, 17 — версия, 18 — Tizen,
     * 19 — 6.0. И ничего больше. Мы же слали ещё девять: язык и страну
     * отдельными полями, размеры экрана дважды, три флага и дробь — всё
     * из чужого образца, которого у TV-клиента нет.
     */
    [info putString:[NSString stringWithFormat:@"%@_%@", [YTApi hl], [YTApi gl]]
              field:1];

    YTProtoWriter *context = [YTProtoWriter writer];

    [context putMessage:info field:1];

    NSData *token = [self decodedToken];

    if (token != nil) {
        [context putData:token field:2];
    }

    if (_playbackCookie != nil) {
        [context putData:_playbackCookie field:3];
    }

    /**
     * Поле 19.4 — `{3: {1: 5}}` во всех ста десяти запросах браузера.
     * Что означает, не знаю; ставлю дословно, потому что оно постоянно.
     */
    YTProtoWriter *inner = [YTProtoWriter writer];
    [inner putVarint:5 field:1];

    YTProtoWriter *four = [YTProtoWriter writer];
    [four putMessage:inner field:3];

    [context putMessage:four field:4];

    return context;
}

/** Токен из записи base64url в байты. */
- (NSData *)decodedToken {
    return [YTSabr dataFromBase64Url:_poToken];
}

+ (NSData *)dataFromBase64Url:(NSString *)source {
    if ([source length] == 0) {
        return nil;
    }

    NSMutableString *text = [NSMutableString stringWithString:source];

    [text replaceOccurrencesOfString:@"-" withString:@"+"
                             options:0 range:NSMakeRange(0, [text length])];
    [text replaceOccurrencesOfString:@"_" withString:@"/"
                             options:0 range:NSMakeRange(0, [text length])];

    // base64 требует длины, кратной четырём; в base64url хвост опускают.
    while ([text length] % 4 != 0) {
        [text appendString:@"="];
    }

    /**
     * `initWithBase64EncodedString:` появился только в iOS 7, а нижняя
     * граница у нас 5.1; здесь годится давний `initWithBase64Encoding:` —
     * тот же разбор и та же строгость к длине.
     */
    return [[NSData alloc] initWithBase64Encoding:text];
}

/**
 * `VideoPlaybackAbrRequest` — само прошение.
 *
 * Отправляется не то, чего мы хотим, а то, что у нас есть: подача
 * решает сама, что прислать, глядя на выбранные дорожки и на время,
 * с которого мы играем.
 */
/**
 * Состояние клиента — `ClientAbrState`, поле 1 запроса.
 *
 * Долгое время мы посылали из него одно поле — время воспроизведения:
 * оно единственное, без которого сервер точно ничего не отдаёт, а всё
 * прочее казалось необязательным. Оказалось — не всё.
 *
 * Сразу после прыжка по ролику сервер отвечал пустотой: ни фрагмента,
 * ни отказа, только перечень дорожек да правила следующего запроса.
 * Скупому состоянию он, видимо, не верит — не понимает, ни где плеер,
 * ни что он вообще делает. Поэтому теперь состояние собирается так же,
 * как в рабочем образце `createClientABRState` из TubeReplacer: размеры
 * окна, скорость, видимость, состояние плеера и прочие поля, которые
 * там перечислены. Номера взяты из `client_abr_state.proto`, а не
 * угаданы.
 *
 * Скорость — единственное дробное поле во всём запросе: четыре байта,
 * младшими вперёд. Varint'ом её писать нельзя, у поля другой тип,
 * и сервер отверг бы сообщение целиком.
 */
- (YTProtoWriter *)clientState:(int64_t)startMs {
    YTProtoWriter *state = [YTProtoWriter writer];

    /**
     * Размеры окна — в точках экрана и «лёжа», большей стороной вперёд.
     *
     * Так делает и образец, и рассуждение там простое: смотреть будут
     * скорее в горизонтальном положении, а сервер по этим числам
     * прикидывает, какое разрешение человеку вообще нужно.
     */
    CGRect bounds = [[UIScreen mainScreen] bounds];
    CGFloat scale = 1.0;

    if ([[UIScreen mainScreen] respondsToSelector:@selector(scale)]) {
        scale = [[UIScreen mainScreen] scale];
    }

    NSInteger side = (NSInteger)(MAX(bounds.size.width, bounds.size.height) * scale);
    NSInteger edge = (NSInteger)(MIN(bounds.size.width, bounds.size.height) * scale);

    /**
     * Две разные повадки — и обе намеренные.
     *
     * При «Авто» (`_wantedHeight` не задана) мы описываем экран как есть
     * и называем привычной ту ступень, что ему под стать. Дальше решает
     * сервер: он вправе и снизить качество, когда сеть не тянет, — ради
     * этого подача и затевалась.
     *
     * Когда же ступень названа человеком, она перевешивает всё: окно
     * объявляем не меньше запрошенного, привычной ступенью — её саму.
     * Здесь прежде стояла вписанная руками семьсот двадцатка, и она
     * означала «мне привычны 720p» при любом выборе; сервер имел полное
     * право ей верить и верил — просили 1080p (itag 137 или 299),
     * получали 720p (136, 298), раз за разом.
     */
    NSInteger wanted = _wantedHeight;

    if (wanted > 0) {
        edge = MAX(edge, wanted);
        side = MAX(side, wanted * 16 / 9);
    } else {
        wanted = [self tierForScreen:edge];
    }

    [state putVarint:(uint64_t)MAX((NSInteger)1, side) field:18];
    [state putVarint:(uint64_t)MAX((NSInteger)1, edge) field:19];

    [state putVarint:(uint64_t)wanted field:21];


    /**
     * Поле 28 — это место **показа**, и у эфира оно отстаёт от набранного.
     *
     * Дамп yttv5 снят с той же волны, что и наши журналы, и говорит прямо.
     * Браузер набирает до самой головы — его перечень растёт сплошняком
     * `3167596…3167704`, последний кусок всегда головной, — но в поле 28
     * ставит время на четырнадцать с половиной секунд ниже. Ровно и
     * неизменно: сто десять запросов подряд, от 10,0 до 14,9 секунды,
     * в среднем 14,4. На его же панели это и написано: Live Latency 20,49 с
     * при запасе 18,09 с.
     *
     * Мы ставили туда своё место набора, то есть почти голову. Для сервера
     * это другой разговор: зритель, стоящий вплотную к краю, просит кусок
     * в тот самый миг, когда его дорезают. Там и терялись куски — все наши
     * молчания начинались с просьбы у самой головы.
     *
     * Отступаем на пятнадцать секунд. Это не тот отступ в две минуты,
     * который я убрал в 1.4-152: набирать мы по-прежнему будем до головы,
     * а на пятнадцать секунд отстанет только заявленное место показа —
     * как у браузера. У раздачи своя ось времени, и на картинку это не
     * влияет вовсе.
     */
    int64_t at = MAX((int64_t)0, startMs);

    if (_liveMode && at > 15000) {
        at -= 15000;
    }

    [state putVarint:_askLiveNow ? (uint64_t)YTLiveNow : (uint64_t)at
               field:28];

    // Видно (1) и играет (0) — то же, что в образце.
    /**
     * Три поля — по перехваченному запросу web-плеера к эфиру.
     *
     * Там 34=0 (у нас было 1), а также 71=1 и 85=1, которых у нас нет.
     * Что они значат, сервер не рассказывает; но это единственные
     * различия в состоянии клиента между запросом, которому он верит,
     * и нашим, — а поля-признаки как раз и говорят серверу, что клиент
     * умеет и что от него ждать. У записи оставляем как было: там всё
     * работает.
     */
    /**
     * Поле 29 — сколько мы уже смотрим, в миллисекундах. Без него
     * сервер не придерживает соединение, и эфир обречён на подгрузки.
     *
     * Найдено прямой пробой на живой сессии web-плеера (тело менялось
     * по одному полю, принудительный H.264). Браузер в установившемся
     * ходу посылает **один** запрос на кусок, и сервер держит его
     * ~4,9 с — ровно до того мгновения, когда кусок нарезан, — и тогда
     * отдаёт. Пустых ответов браузер не видит вовсе.
     *
     * Стоит убрать из его тела одно поле 29, и ответ приходит за 70 мс
     * пустым. Остальные восемь полей, которых мы не посылали (23, 36,
     * 39, 57, 59, 68, 72, 79), на это не влияют никак — проверено по
     * одному. А наш собственный набор полей **плюс** 29 держится 4,7 с
     * и отдаёт кусок, как браузеру.
     *
     * Порог — между одной и тремя секундами: 0, 1, 100, 1000 мс дают
     * мгновенную пустоту, 3000 и выше — придержанный ответ с куском.
     * Час (3 600 000) ничего не ломает, держит столько же.
     *
     * Отсюда и вся наша хворь: мы не посылали поля вовсе, сервер читал
     * ноль и отвечал сразу пустотой. Мы спрашивали каждые две секунды,
     * видели «Ответ 0 КБ» по двенадцать раз на полминуты и считали это
     * за беду — отсюда и перезапуски, и «долгие подгрузки».
     *
     * Время считаем от первой живой просьбы: на первых секундах оно
     * меньше порога, и это правильно — начало показа должно получить
     * ответ мгновенно, а не ждать нарезки.
     *
     * Но отсчёт **не должен** начинаться заново при каждой смене подачи,
     * а я завёл его полем объекта — и он начинался. Журнал 64: семь
     * подмен и пятнадцать пересадок, и в каждом стартовом запросе новой
     * подачи стоит `29=0`, тогда как браузер в ту же минуту шлёт 103717.
     * А ноль — это ровно то значение, при котором сервер не придерживает
     * соединение и отвечает мгновенной пустотой. Выходил круг: подмена
     * обнуляла счётчик, сервер отвечал пустотой, сторож считал это бедой
     * и брал ещё одну подачу.
     *
     * Просмотр идёт от начала показа, а не от начала сессии подачи, —
     * значит и отсчёт общий. Держим его в статике, привязанной к ролику.
     */
    if (_liveMode) {
        static NSString *watchedVideo = nil;
        static NSTimeInterval watchedFrom = 0;

        NSString *current = [self videoId];

        if (watchedFrom <= 0 || ![watchedVideo isEqualToString:current]) {
            watchedVideo = [current copy];
            watchedFrom = [NSDate timeIntervalSinceReferenceDate];
        }

        NSTimeInterval watched =
            [NSDate timeIntervalSinceReferenceDate] - watchedFrom;

        _lastWatchedMs = (int64_t)MAX(0.0, watched * 1000.0);

        [state putVarint:(uint64_t)_lastWatchedMs field:29];

        /**
         * Ещё четыре поля, которые браузер шлёт всегда, а мы не слали.
         *
         * Раньше я отнёс их к «замерам чужой сессии, которые копировать
         * нельзя». Первое верно, второе — нет: числа чужие, но величины
         * наши собственные, и сказать их серверу мы можем честно.
         *
         * Разбор дампа их и назвал. Разность полей 13 и 36 держится ровно
         * на 59861 во всех ста десяти запросах, а на четырнадцатом поле 13
         * падает к нулю, тогда как 36 продолжает расти. Значит 36 — время
         * от начала показа, а 13 — от начала нынешней сессии подачи, и
         * при её смене оно начинается заново. Поле 23 меняется от 769 869
         * до 4 046 992 — это скорость связи в битах в секунду. Поле 16
         * равно 480 при качестве 480p, то есть выбранная высота.
         *
         * Поля 39, 57 и 68 не ставим: что они означают, дамп не выдал, а
         * выдумывать серверу числа о себе — то самое, за что я уже
         * поплатился полем 59.
         */
        [state putVarint:(uint64_t)MAX(0.0, watched * 1000.0) field:36];

        [state putVarint:(uint64_t)MAX(0.0,
            ([NSDate timeIntervalSinceReferenceDate] - _sessionFrom) * 1000.0)
                  field:13];

        // В дампе той же волны поле 14 равно нулю во всех запросах.
        [state putVarint:0 field:14];

        double kbps = [YTPlaybackStats speedKbps];

        if (kbps > 0) {
            [state putVarint:(uint64_t)(kbps * 1000.0) field:23];
        }

        if (wanted > 0) {
            [state putVarint:(uint64_t)wanted field:16];
        }
    }

    /**
     * Набор полей сверен с дампом движения youtube.com/tv (yttv2.har).
     *
     * Из ста десяти живых запросов тринадцать полей держат в нём одно и
     * то же значение от начала до конца — их и ставим буквально:
     * 34=0, 40=3, 58=0, 71=1, 73=2, 76=0, 80=1, 85=1; а 16, 18, 19 и 21
     * у нас свои, по размеру кадра.
     *
     * Поля 59 среди них нет намеренно. В дампе оно равно 2160, и это
     * телевизор рассказывает о своей панели — при том что играет он 480p.
     * Поставив то же число, мы заявили бы серверу о четырёх тысячах строк,
     * которых ни одно наше устройство не покажет. Своей правдивой величины
     * у нас для этого поля нет, а неправду говорить незачем: до 1.4-146 мы
     * этого поля не слали вовсе, и эфир от его появления не стал жить
     * лучше (журнал 77).
     *
     * Поля 22, 35, 44 и 46 убраны: TV-клиент не шлёт их ни разу. Они были
     * нашей догадкой — про ровный звук и про ненужный VP9, — а догадка,
     * высказанная серверу, остаётся догадкой.
     *
     * Остальные девять полей дампа копировать нельзя, и это не лень:
     * 13, 23, 29, 36, 39, 57 и 68 — замеры самой сессии (сколько идёт
     * просмотр, какая скорость, сколько сделано запросов), а 14 и 28
     * меняются по ходу. Поставить туда чужое число значит сказать
     * серверу неправду о себе, и он ответит на неправду.
     */
    [state putVarint:(_liveMode ? 0 : 1) field:34];

    /**
     * Поле 38 — сорок четыре байта, одинаковые во всех ста десяти
     * запросах браузера. Внутри: дорожка `{кодек 2, 720×1280, 30 к/с}`,
     * звук, три числа и признак. Это заявление о возможностях, и оно
     * ровно наше: браузер человека принуждён к H.264 и 720p, как и мы.
     * Ставим дословно.
     */
    /**
     * Поле 38 — заявление о возможностях, и оно должно быть **нашим**.
     *
     * В 1.4-164 я скопировал его у телевизора байт в байт, а внутри там
     * стояло `720×1280`: браузер человека принуждён расширением к 720p,
     * и телевизор честно так и сказал. Мы повторили за ним — и сервер
     * стал отвечать на просьбу о 1080p перезапросом и отказом (журнал 94,
     * 00:46:51: «перезапрос:138», затем «отказ:26»). Обычные ролики
     * потеряли 1080p, хотя устройство его тянет.
     *
     * Строение сообщения — из дампа, числа — свои: высота и ширина по
     * потолку устройства (720 у старых чипов, 1080 у A5 и новее).
     */
    /**
     * Не ниже ручного выбора. Человек вправе попросить 1080p и на старом
     * чипе — меню предупреждает «может не пойти», но пробовать даёт. Заяви
     * мы серверу потолок ниже просьбы, он откажет ещё до пробы, как в
     * журнале 94. `_wantedHeight` ненулевой только при ручном выборе.
     */
    NSInteger ceiling = MAX([YTStreams deviceMaxHeight], _wantedHeight);

    /**
     * Кадры в секунду — из настройки, а не число тридцать навсегда.
     *
     * Поле 11 здесь — потолок частоты, и стояло в нём жёсткое `30`:
     * перенято из дампа, где браузер человека был прижат расширением
     * к тридцати. Сервер этому верит буквально и шестидесятикадровую
     * дорожку не присылает никогда — ни у записи, ни у эфира, сколько бы
     * их ни было в перечне предпочтений. Тумблер «60 кадров» при этом
     * отбирал дорожки у нас, но серверу о себе не говорил, и на подаче
     * не значил ничего.
     *
     * У записи это было незаметно: не дав шестидесяти, сервер даёт
     * тридцать того же качества. У эфира тридцатикадровой дорожки может
     * не быть вовсе.
     */
    NSInteger frames = [YTStreams prefersThirtyFrames] ? 30 : 60;

    /**
     * Поле 12 — последнее чужое число в этом сообщении.
     *
     * В дампе оно равно 2 684 050, в соседнем — 2 448 612, и оба сняты
     * с браузера, прижатого расширением к 720p при тридцати кадрах.
     * У нас оно стояло намертво, и выходило заявление «умею 1080p60,
     * но осилю столько, сколько весит 720p30». Сервер верил второй
     * половине: закрепив дорожку 137 в одиночку, мы получали
     * `sabr.no_video_selected` (журнал, 08:20:12), а у эфира, где
     * закрепления нет, он просто выбирал 136 при любом нашем «хочу 1080».
     *
     * Ровно та же ловушка, что с полями 3 и 4 в 1.4-164 и с полем 11
     * в 1.4-193: строение сообщения — из дампа, числа должны быть наши.
     * Пересчитываем от того же образца по точкам в секунду: 1280×720
     * при тридцати кадрах — это и есть 2 684 048.
     */
    double sample = 2684048.0
        / (1280.0 * 720.0 * 30.0)
        * (double)ceiling * (double)(ceiling * 16 / 9) * (double)frames;

    YTProtoWriter *videoCap = [YTProtoWriter writer];
    [videoCap putVarint:2 field:1];
    [videoCap putVarint:1 field:2];
    [videoCap putVarint:(uint64_t)ceiling field:3];
    [videoCap putVarint:(uint64_t)(ceiling * 16 / 9) field:4];
    [videoCap putVarint:(uint64_t)frames field:11];
    [videoCap putVarint:(uint64_t)sample field:12];
    [videoCap putVarint:0 field:15];

    /**
     * Печатаем, когда меняется сказанное, а не по номеру запроса:
     * `_requestNumber` к этому мгновению уже увеличен, и условие
     * «нулевой запрос» не срабатывало никогда.
     */
    NSString *said = [NSString stringWithFormat:@"%ldx%ld, %ld кадр/с, поле 12 = %.0f",
                      (long)(ceiling * 16 / 9), (long)ceiling, (long)frames, sample];

    if (![said isEqualToString:_capsSaid]) {
        _capsSaid = [said copy];

        NSLog(@"[YouTube/Подача] Возможности: %@", said);
    }

    YTProtoWriter *audioCap = [YTProtoWriter writer];
    [audioCap putVarint:1 field:1];
    [audioCap putVarint:2 field:2];
    [audioCap putVarint:0 field:6];

    YTProtoWriter *caps = [YTProtoWriter writer];
    [caps putMessage:videoCap field:1];
    [caps putMessage:audioCap field:2];
    [caps putVarint:249 field:4];
    [caps putVarint:350 field:4];
    [caps putVarint:278 field:4];
    [caps putVarint:3 field:5];

    [state putMessage:caps field:38];

    [state putVarint:3 field:40];
    [state putBool:NO field:58];

    /**
     * Поле 59 у телевизора — 2160, высота его панели. Наша панель ниже;
     * говорим свою, в тех же единицах.
     */
    /**
     * Поле 59 — не ниже потолка качества. У iPad 2 экран 1024 точки, а
     * 1080p он раскодирует; сказав «1024», мы сами отрезали себе 1080p.
     */
    CGSize screen = [[UIScreen mainScreen] bounds].size;
    CGFloat panelScale = [[UIScreen mainScreen] scale];
    NSInteger panel = (NSInteger)(MAX(screen.width, screen.height) * panelScale);

    [state putVarint:(uint64_t)MAX(panel, ceiling) field:59];

    if (_liveMode) {
        [state putBool:YES field:71];
    }

    /**
     * Поле 72 — `{2: высота}` при прочих нулях: нынешнее качество. Поле 79 —
     * восемнадцать байт трёх флагов, одинаковые во всех запросах. Поле 80
     * у браузера стоит в одном запросе из ста десяти — в первом; мы
     * слали его всегда.
     */
    YTProtoWriter *quality = [YTProtoWriter writer];
    [quality putVarint:0 field:1];
    [quality putVarint:(uint64_t)wanted field:2];
    [quality putVarint:0 field:3];
    [quality putVarint:0 field:4];
    [quality putVarint:0 field:5];
    [quality putVarint:0 field:6];
    [state putMessage:quality field:72];

    [state putVarint:2 field:73];
    [state putBool:NO field:76];

    static const uint8_t flags[18] = {
        0x0a,0x04,0x08,0x01,0x10,0x00, 0x0a,0x04,0x08,0x02,0x10,0x00,
        0x0a,0x04,0x08,0x02,0x10,0x01 };

    [state putData:[NSData dataWithBytes:flags length:sizeof(flags)] field:79];

    if (_requestNumber == 0) {
        [state putVarint:1 field:80];
    }

    if (_liveMode) {
        [state putBool:YES field:85];
    }

    return state;
}

- (NSData *)requestBodyFrom:(int64_t)startMs {
    YTProtoWriter *request = [YTProtoWriter writer];

    /**
     * Запрос собран по рабочему образцу — `buildRequestBody`
     * из TubeReplacer: состояние клиента, настройки подачи, перечень
     * набранного, все дорожки в предпочтениях и описание клиента.
     *
     * Главное здесь — **все** дорожки разом, а не выбранная. Выбирает
     * сервер: он знает про озвучки, про то, какие сочетания у него
     * готовы, и про то, с чего начинать. Назвать одну — значит решить
     * за него, а он этого не ждёт. Поле `selected_format_ids` мы
     * не посылаем по той же причине.
     */
    /**
     * Время плеера — на двенадцать секунд позади края сервера.
     *
     * Край — это голова эфира из части №31 (`liveHeadSeconds`): та
     * отметка, по которой сервер решает, отдать кусок или сказать
     * «подожди». Прямая проба со страницы браузера (H.264 включён
     * принудительно, как у h264ify; поля тела меняли по одному) дала
     * порог однозначно:
     *
     *  - время плеера до края или до +8 с за ним — сервер отдаёт
     *    следующий кусок, при нужде придержав соединение на такт;
     *  - время плеера за краем на +20 с — сервер держит соединение
     *    семь секунд и возвращает **пустой** ответ с частями
     *    58, 47, 52, 31, 35 и без единого куска. Это в точности наш
     *    «Ответ 0 КБ … начало метка эфир правила» из журнала.
     *
     * Прежняя формула считала время плеера от конца набранного, а не
     * от края сервера. Сразу после `restartSession` сплошной ряд
     * короткий (три куска), `head` подтягивался к концу, и время
     * плеера садилось к самому концу набранного — а тот обгонял край,
     * который сервер обновляет в части №31 реже, чем отдаёт куски.
     * Выходил пустой ответ, перезапуск, снова короткий ряд — тот самый
     * двадцатисекундный круг.
     *
     * Web-плеер так не делает: он держит время плеера на ~12 с позади
     * края независимо от длины буфера. Повторяем за ним. Край берём
     * наименьшим из головы сервера и конца набранного (оба — «самое
     * свежее известное»), отступаем двенадцать секунд, но не подходим
     * к краю ближе двух и не заходим раньше начала набранного (иначе
     * сервер шлёт кусок заново — повтор).
     */
    int64_t playerMs = startMs;

    if (_liveMode) {
        NSArray *runs = [self heldRuns:YES];

        if ([runs count] > 0) {
            int64_t bufStart = [[[runs objectAtIndex:0] objectAtIndex:2] longLongValue];
            int64_t bufEnd = [[[runs lastObject] objectAtIndex:3] longLongValue];

            /**
             * Время плеера отмеряем от КРАЯ, а не от конца своего буфера.
             *
             * Это оказалось причиной всех долгих провалов, и доказано оно
             * прямой пробой в браузере нашими же байтами. При одном и том
             * же перечне набранного менялось только поле 28:
             *
             *     край−30  → два куска
             *     край−60  → пусто, часть №69
             *     край−85  → пусто, часть №69
             *     край−225 → пусто, часть №69
             *
             * То есть сервер обслуживает по времени плеера, и оно обязано
             * держаться у края. Браузер потому и играет ровно: у него это
             * настоящая голова показа, она идёт в реальном времени и
             * отстаёт от эфира секунд на сорок-восемьдесят. В сплошном
             * прогоне отказы начинались ровно в тот миг, когда отставание
             * переваливало за девяносто секунд.
             *
             * А мы считали его от `bufEnd` — от конца **своего** буфера.
             * Стоит подаче запнуться, и конец буфера замирает: время
             * плеера уползает назад вместе с ним, сервер начинает
             * отказывать, отчего подача стоит ещё дольше, и время плеера
             * уползает ещё дальше. Ловушка сама себя кормила, и вылезали
             * мы из неё только прыжком — теми самыми сторожами, которые
             * весь вечер лечили следствие.
             *
             * Тридцать секунд отступа: у края сервер отдаёт, а запас до
             * опасной границы (около девяноста) остаётся тройной.
             */
            int64_t limitMs = (int64_t)(_liveSeekSeconds * 1000.0);

            if (limitMs <= 0 && _liveHeadSeconds > 0) {
                limitMs = (int64_t)(_liveHeadSeconds * 1000.0) - 10000;
            }

            if (limitMs > 0) {
                playerMs = limitMs - 30000;

                /**
                 * И не раньше конца набранного — иначе сервер шлёт заново
                 * то, что у нас уже есть.
                 *
                 * Это вторая половина правила, и без неё первая ломает
                 * начало показа. Журнал 66: список верно начался с №3152801,
                 * а дальше сервер прислал этот же кусок **пятнадцать раз
                 * подряд** и ни разу следующий. Причина ровно та: время
                 * плеера стояло на `край − 30`, то есть указывало на уже
                 * набранный №3152801, и сервер послушно отдавал его снова.
                 * Сорок семь секунд простоя на пустом месте.
                 *
                 * Сервер отдаёт то, что идёт **после** времени плеера, —
                 * значит время плеера должно стоять в конце набранного,
                 * а не там, где мы уже были. Край при этом остаётся
                 * страховкой: если подача встала и конец набранного
                 * замер, `край − 30` окажется больше и вытянет нас
                 * вперёд, не давая уползти в отказ (ради чего правило
                 * и вводилось в 1.4-119).
                 */
                if (playerMs < bufEnd) {
                    playerMs = bufEnd;
                }

                if (playerMs < bufStart) {
                    playerMs = bufStart;
                }

                if (playerMs > limitMs - 2000) {
                    playerMs = limitMs - 2000;
                }
            } else {
                // Края ещё не знаем — держимся конца набранного, как прежде.
                if (bufEnd > bufStart) {
                    playerMs = bufEnd - 12000;

                    if (playerMs < bufStart) {
                        playerMs = bufStart;
                    }
                }
            }
        }
    }

    [request putMessage:[self clientState:playerMs] field:1];

    [request putData:_config field:5];

    /**
     * Перечень того, что уже набрано.
     *
     * Одного печенья воспроизведения оказалось мало: сервер продолжал
     * слать те же первые фрагменты, сколько ни проси. Он ждёт, чтобы
     * мы **сами** сказали, чем владеем, — и лишь тогда отдаёт следующее.
     */
    [self putBufferedRange:request format:_gotVideo video:YES];
    [self putBufferedRange:request format:_gotAudio video:NO];

    /**
     * Перечень дорожек — раз на сессию, а не в каждом запросе.
     *
     * В дампе движения youtube.com/tv на сто десять запросов приходится
     * ровно одно поле 17 — в тот миг, когда человек сменил качество
     * вручную, — и ни одного поля 16. Всё остальное время сервер выбирает
     * сам, по сведениям о клиенте и размеру кадра.
     *
     * Мы же называли весь набор в каждом запросе. Для сервера это не
     * «напоминание», а новое заявление о намерениях: он вправе заново
     * решать, чем нас кормить, и заново присылать сведения о дорожке.
     * Первую просьбу сессии оставляем как была — иначе выбирать ему
     * не из чего, — а дальше молчим, как молчит браузер.
     */
    BOOL tellFormats = !_toldFormats;

    _toldFormats = YES;

    for (YTSabrFormat *format in _allAudio) {
        if (!tellFormats) {
            break;
        }

        [request putMessage:[self formatId:format] field:16];
    }

    /**
     * Перечисляем ровно то, из чего серверу позволено выбирать.
     *
     * Закреплена дорожка — называем её одну: выбирать не из чего,
     * и качество не поедет посреди ролика. Не закреплена (первый запрос
     * при «Авто») — называем весь набор, иначе сервер вправе отказать.
     */
    for (YTSabrFormat *format in _allVideo) {
        if (!tellFormats) {
            break;
        }

        /**
         * У эфира называем все — выбирает сервер.
         *
         * Закрепление здесь ни к чему: у трансляции нет своего набора
         * заранее, сервер держит на живом краю то, что успел нарезать,
         * и сам переходит с дорожки на дорожку (в журнале — «прислал
         * itag 135 вместо закреплённой 134»). Назвав одну, мы просим
         * то, чего у него в этот миг может не быть, — и получаем
         * пустоту. Ровно так делает и Android-версия, где эфиры идут.
         */
        if (!_liveMode && _pinnedVideo != nil && format.itag != _pinnedVideo.itag) {
            continue;
        }

        [request putMessage:[self formatId:format] field:17];
    }

    [request putMessage:[self streamerContext] field:19];

    if (_ackResumePoint) {
        YTProtoWriter *ack = [YTProtoWriter writer];
        [ack putVarint:7 field:8];
        [request putMessage:ack field:24];

        _ackResumePoint = NO;
    }

    return [request data];
}

/** Время из запомненного, мс: 0 — начало, 1 — длительность. */
- (int64_t)msIn:(NSDictionary *)times sequence:(NSInteger)sequence part:(NSUInteger)part {
    NSArray *pair = [times objectForKey:[NSNumber numberWithInteger:sequence]];

    if ([pair count] <= part) {
        return 0;
    }

    return [[pair objectAtIndex:part] longLongValue];
}

/**
 * Все сплошные ряды набранного, по порядку:
 * `[первый, последний, начало первого, конец последнего, начало последнего]`.
 *
 * Считаем по памяти, а не по счётчикам. Счётчики помнили крайние номера
 * — «от первого пришедшего до последнего», — и этим скрывали и дыры,
 * и выброшенное: сервер, услышав «всё это у меня есть», не присылал
 * ни пропущенного, ни выброшенного. У записи это лечилось повтором
 * с чистого листа, а у эфира лечить нечем: перемотать некуда, и показ
 * просто вставал на пустых ответах, пока трансляция уходила вперёд.
 * Ряд же, оборванный на дыре, честен.
 */
- (NSArray *)heldRuns:(BOOL)isVideo {
    NSDictionary *storage = isVideo ? _videoSegments : _audioSegments;
    NSDictionary *times = isVideo ? _videoTimes : _audioTimes;

    NSArray *keys;

    @synchronized (self) {
        NSMutableSet *all = [NSMutableSet setWithArray:[storage allKeys]];

        // К настоящим кускам добавляем перенятые у прежней подачи номера.
        [all unionSet:(isVideo ? _claimedVideo : _claimedAudio)];

        keys = [[all allObjects] sortedArrayUsingSelector:@selector(compare:)];
    }

    NSMutableArray *runs = [NSMutableArray array];

    NSInteger first = 0;
    NSInteger last = 0;

    for (NSNumber *key in keys) {
        NSInteger sequence = [key integerValue];

        if (first != 0 && sequence == last + 1) {
            last = sequence;

            continue;
        }

        if (first != 0) {
            [runs addObject:[self runFrom:first to:last times:times]];
        }

        first = sequence;
        last = sequence;
    }

    if (first != 0) {
        [runs addObject:[self runFrom:first to:last times:times]];
    }

    return runs;
}

/**
 * Первый кусок эфира, что у нас вообще был, и его время.
 *
 * Память мы чистим по мере показа, но серверу об этом знать незачем:
 * перемотать эфир некуда, и однажды полученное нам больше не нужно.
 * Сказав же «этого у меня нет», мы получаем это заново — в журнале
 * видно, как одни и те же фрагменты приходят по два и по три раза,
 * занимая место свежих.
 */
- (void)noteLiveSeen:(NSInteger)sequence at:(int64_t)startMs {
    if (!_liveMode || _liveSeenSeq > 0 || sequence <= 0) {
        return;
    }

    _liveSeenSeq = sequence;
    _liveSeenMs = startMs;
}

- (NSArray *)runFrom:(NSInteger)first to:(NSInteger)last times:(NSDictionary *)times {
    int64_t head = [self msIn:times sequence:first part:0];
    int64_t tail = [self msIn:times sequence:last part:0];

    // Длину последнего берём только настоящую: обещать выдуманное нельзя.
    int64_t span = [self msIn:times sequence:last part:1];

    return [NSArray arrayWithObjects:
        [NSNumber numberWithInteger:first],
        [NSNumber numberWithInteger:last],
        [NSNumber numberWithLongLong:head],
        [NSNumber numberWithLongLong:tail + span],
        [NSNumber numberWithLongLong:tail],
        nil];
}

/** Записи перечня для дорожки — по одной на каждый сплошной ряд. */
- (void)putBufferedRange:(YTProtoWriter *)request
                  format:(YTSabrFormat *)format
                   video:(BOOL)isVideo {
    if (format == nil) {
        return;
    }

    NSArray *runs = [self heldRuns:isVideo];

    /**
     * Заявляем только то, что держим на самом деле.
     *
     * Здесь стояла одна запись на весь эфир — от начала показа до хвоста,
     * — и дыры внутри неё объявлялись нашими намеренно: мол, пропущенного
     * сервер всё равно не отдаёт, а спрашивать его значит получать уже
     * виденное. Рассуждение было ошибочным, и журнал 84 показал цену.
     *
     * В запросе стояло `4=3161923 5=3161962`: «куски с 3161923 по 3161962
     * у меня есть». А сервер в том же ответе просил продолжить с куска
     * №3161938 — то есть из середины этого самого промежутка. Он хотел
     * дать нам ровно то, что мы объявили своим, и потому не давал ничего.
     * Восемьдесят четыре секунды тишины, и выхода из неё нет: хвост стоит,
     * значит и заявление не меняется, значит и ответ тот же.
     *
     * Своей ложью мы сами себя и запирали. Теперь перечень — настоящий:
     * сплошные ряды того, что лежит в памяти, с разрывами там, где они
     * есть. Увидев разрыв, сервер либо закроет его, либо шагнёт дальше, —
     * но молчать ему будет нечего.
     *
     * Браузер в дампе так и делает: у него один-два ряда на дорожку, и
     * `4`/`5` в них — настоящие номера первого и последнего куска.
     */
    if (_liveMode && [runs count] > 0) {
        NSMutableString *said = [NSMutableString string];

        for (NSArray *held in runs) {
            [said appendFormat:@"%@%ld…%ld", [said length] > 0 ? @", " : @"",
                (long)[[held objectAtIndex:0] integerValue],
                (long)[[held objectAtIndex:1] integerValue]];
        }

        if (_liveMode && [self shouldSayRuns]) {
            NSLog(@"[YouTube/Подача] Эфир: заявляем набранное — %@", said);
        }
    }

    for (NSArray *held in runs) {
        [self putOneRange:request format:format held:held];
    }
}

/** Перечень набранного в журнал — не чаще раза в полминуты. */
- (BOOL)shouldSayRuns {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    if (now - _runsSaidAt < 30.0) {
        return NO;
    }

    _runsSaidAt = now;

    return YES;
}

- (void)putOneRange:(YTProtoWriter *)request
             format:(YTSabrFormat *)format
               held:(NSArray *)held {
    NSInteger first = [[held objectAtIndex:0] integerValue];
    NSInteger last = [[held objectAtIndex:1] integerValue];

    int64_t head = [[held objectAtIndex:2] longLongValue];
    int64_t end = [[held objectAtIndex:3] longLongValue];

    if (last <= 0 || first <= 0) {
        return;
    }

    /**
     * Перечень описывает **тот кусок, что набран сейчас**, а не «всё
     * с начала ролика».
     *
     * Здесь стояли единица и ноль — «у нас есть всё от первого
     * фрагмента». После перемотки на середину это становилось неправдой:
     * сервер верил на слово и продолжал от начала, а мы складывали
     * присланное рядом с тем, что играем. Звук уходил от картинки
     * на минуты — ровно на столько, на сколько перемотали.
     */
    YTProtoWriter *range = [YTProtoWriter writer];

    [range putMessage:[self formatId:format] field:1];
    [range putVarint:(uint64_t)head field:2];
    [range putVarint:(uint64_t)MAX((int64_t)0, end - head) field:3];
    [range putVarint:(uint64_t)first field:4];
    [range putVarint:(uint64_t)last field:5];

    [request putMessage:range field:3];
}

#pragma mark Разбор ответа

/**
 * Длина фрагмента по его собственной разметке, мс; 0 — не разобрался.
 *
 * Заголовок дорожки разбираем один раз и держим, пока он тот же:
 * `parseInit:` на каждый кусок — лишняя работа для iPad 2.
 */
- (int64_t)fragmentDurationMs:(NSData *)body video:(BOOL)isVideo {
    NSData *raw = isVideo ? _videoInit : _audioInit;

    if ([raw length] == 0 || [body length] == 0) {
        return 0;
    }

    YTTrackInit *init = isVideo ? _videoInitParsed : _audioInitParsed;
    NSData *from = isVideo ? _videoInitParsedFrom : _audioInitParsedFrom;

    if (init == nil || from != raw) {
        init = [YTMp4 parseInit:raw];

        if (isVideo) {
            _videoInitParsed = init;
            _videoInitParsedFrom = raw;
        } else {
            _audioInitParsed = init;
            _audioInitParsedFrom = raw;
        }
    }

    if (init == nil || init.timescale == 0) {
        return 0;
    }

    YTFragment *parsed = [YTMp4 parseFragment:body init:init];

    uint64_t ticks = 0;

    for (YTSample *sample in parsed.samples) {
        ticks += sample.duration;
    }

    return (int64_t)(ticks * 1000ULL / init.timescale);
}

/** Читает `MediaHeader` — из него нужны дорожка, номер и признак init. */
- (YTSabrHeader *)parseHeader:(NSData *)body {
    YTSabrHeader *header = [[YTSabrHeader alloc] init];

    /**
     * Заодно перечисляем все поля, какие в заголовке есть.
     *
     * Разбираем мы четыре из шестнадцати, и по журналу не отличить
     * «сервер не пометил сегмент начальным» от «мы не там посмотрели».
     * Заголовки приходят разной длины — 72 знака и 186, — и разница
     * где-то в этих полях.
     */
    NSMutableString *fields = [NSMutableString string];

    NSData *range = nil;

    YTProtoReader *reader = [YTProtoReader readerWithData:body];

    while ([reader next]) {
        NSUInteger number = [reader field];

        switch (number) {
            case 1: header.headerId = (NSUInteger)[reader takeVarint]; break;
            case 3: header.itag = (NSInteger)[reader takeVarint]; break;
            case 4: header.lastModified = [reader takeVarint]; break;
            case 8: header.isInit = ([reader takeVarint] != 0); break;
            case 9: header.sequence = (NSInteger)[reader takeVarint]; break;
            case 11: header.startMs = (int64_t)[reader takeVarint]; break;
            case 12: header.durationMs = (int64_t)[reader takeVarint]; break;
            case 15: range = [reader takeData]; break;
            default: break;
        }

        uint64_t value = [reader takeVarint];
        NSData *bytes = [reader takeData];

        [fields appendFormat:@"%@%lu=%@", [fields length] > 0 ? @" " : @"",
            (unsigned long)number,
            bytes != nil
                ? [NSString stringWithFormat:@"<%lu>", (unsigned long)[bytes length]]
                : [NSString stringWithFormat:@"%llu", value]];
    }

    if (header.durationMs <= 0 && range != nil) {
        [self applyTimeRange:range to:header];
    }

    /**
     * Заголовок печатается не всегда, а лишь когда времени в нём
     * не нашлось: у начального фрагмента его и не бывает, а у прочих
     * это беда — по времени собирается кусок. Перечень полей при этом
     * нужен целиком: сервер их состав меняет, и разбираться приходится
     * по тому, что пришло.
     */
    if (!header.isInit && header.durationMs <= 0) {
        NSLog(@"[YouTube/Подача] Заголовок без времени (%lu байт): %@",
              (unsigned long)[body length], fields);
    }

    return header;
}

/**
 * Время фрагмента из поля 15 — на случай, когда полей 11 и 12 в заголовке нет.
 *
 * Сервер сообщает одно и то же двумя способами: либо прямо в миллисекундах,
 * либо отсчётами своей шкалы — начало, длительность, делитель. Второй способ
 * приходит незалогиненным: в заголовках вертикальных роликов полей 11 и 12
 * просто не было, время каждого фрагмента получалось нулевым, окно куска
 * схлопывалось в точку, и **весь** звук отсеивался как «не попавший» —
 * в журнале «звук 0 кадров» при живых фрагментах.
 */
- (void)applyTimeRange:(NSData *)body to:(YTSabrHeader *)header {
    YTProtoReader *reader = [YTProtoReader readerWithData:body];

    int64_t start = 0;
    int64_t length = 0;
    int64_t scale = 0;

    while ([reader next]) {
        switch ([reader field]) {
            case 1: start = (int64_t)[reader takeVarint]; break;
            case 2: length = (int64_t)[reader takeVarint]; break;
            case 3: scale = (int64_t)[reader takeVarint]; break;
            default: break;
        }
    }

    if (scale <= 0) {
        return;
    }

    header.startMs = start * 1000 / scale;
    header.durationMs = length * 1000 / scale;
}

/** Читает `FormatInitializationMetadata` — сколько всего и как долго. */
- (void)parseFormatInit:(NSData *)body {
    /**
     * Раз в минуту — целиком в журнал.
     *
     * Когда эфир замолкает, сервер в каждом пустом ответе присылает
     * сведения о **обеих** дорожках заново (в рабочих — только об одной,
     * и то не всегда). Похоже на «дорожка обновилась, начни с нового
     * заголовка», но что именно в них сменилось, можно узнать только
     * прочитав.
     */
    NSTimeInterval said = [NSDate timeIntervalSinceReferenceDate];

    if (said - _formatInitSaidAt > 60.0) {
        _formatInitSaidAt = said;

        NSLog(@"[YouTube/Подача] Часть №42 (%lu байт): %@",
              (unsigned long)[body length], [self dumpProto:body depth:2]);
    }

    YTProtoReader *reader = [YTProtoReader readerWithData:body];

    NSInteger itag = 0;
    uint64_t lastModified = 0;
    NSInteger count = 0;
    int64_t durationMs = 0;

    while ([reader next]) {
        switch ([reader field]) {
            /**
             * Поле 2 — вложенный `FormatId`: номер дорожки и её версия
             * (`last_modified`). Версия нужна тоже — по ней сервер
             * отличает дорожку до перезапуска кодировщика от дорожки после.
             */
            case 2: {
                YTProtoReader *inner = [YTProtoReader readerWithData:[reader takeData]];

                while ([inner next]) {
                    if ([inner field] == 1) {
                        itag = (NSInteger)[inner takeVarint];
                    } else if ([inner field] == 2) {
                        lastModified = [inner takeVarint];
                    }
                }

                break;
            }

            /**
             * 3 — `end_time_ms`, длительность; 4 — `end_segment_number`,
             * число фрагментов. Раньше длительность бралась из поля 6,
             * а там лежит `init_range` — вложенное сообщение, а не число,
             * и выходил ноль.
             */
            case 3: durationMs = (int64_t)[reader takeVarint]; break;
            case 4: count = (NSInteger)[reader takeVarint]; break;
            default: break;
        }
    }

    /**
     * Сведения приходят на каждую дорожку, а длительность и число
     * фрагментов нам нужны от видео. Опознаём его по списку — сравнивать
     * с заранее выбранным номером нельзя: выбирает сервер, и в живом
     * прогоне он взял `298`, тогда как мы примерялись к `136`.
     */
    /**
     * Сменилась версия дорожки — перечень набранного ей больше не
     * принадлежит.
     *
     * У эфира дорожка может перезапуститься посреди показа (тот же
     * номер, новая версия): в журнале это короткий кусок в 69 КБ вместо
     * обычных 540, а за ним — тишина с повторными сведениями о дорожках
     * в каждом ответе. Мы же продолжали заявлять набранное от имени
     * старой версии и просить продолжения у неё. Берём новую версию
     * себе и начинаем счёт набранного заново — со следующего куска.
     */
    if (_liveMode && lastModified > 0) {
        YTSabrFormat *got = [self isVideoItag:itag] ? _gotVideo : _gotAudio;

        if (got != nil && got.itag == itag && got.lastModified != lastModified) {
            NSLog(@"[YouTube/Подача] Эфир: дорожка %ld сменила версию "
                  @"(%llu → %llu) — перечень набранного начинаем заново",
                  (long)itag, got.lastModified, lastModified);

            YTSabrFormat *fresh = [YTSabrFormat formatWithItag:itag
                                                  lastModified:lastModified];

            fresh.xtags = got.xtags;

            if ([self isVideoItag:itag]) {
                _gotVideo = fresh;
            } else {
                _gotAudio = fresh;
            }

            _liveSeenSeq = 0;
            _liveSeenMs = 0;
        }
    }

    if (![self isVideoItag:itag]) {
        return;
    }

    if (count > 0) {
        _videoSegmentCount = count;
    }

    if (durationMs > 0) {
        _duration = (NSTimeInterval)durationMs / 1000.0;
    }

    // Какую дорожку сервер выбрал на самом деле — это и покажет меню.
    _playingItag = itag;

    NSLog(@"[YouTube/Подача] Дорожка %ld: фрагментов %ld, %.0f с",
          (long)itag, (long)count, _duration);
}

/**
 * Перечисляет боксы mp4 в начале куска.
 *
 * Нужно, чтобы отличить два случая: фрагмент пришёл голым (`moof`+`mdat`,
 * и тогда заголовок дорожки надо добывать отдельно) — или вместе
 * с заголовком (`ftyp`+`moov`), и тогда добывать нечего.
 */
- (NSString *)boxesIn:(NSData *)data {
    NSMutableString *names = [NSMutableString string];

    const uint8_t *bytes = (const uint8_t *)[data bytes];
    NSUInteger length = [data length];
    NSUInteger at = 0;

    // Дальше трёх боксов смотреть незачем: нужное видно сразу.
    for (NSUInteger n = 0; n < 3 && at + 8 <= length; n++) {
        uint64_t size = ((uint64_t)bytes[at] << 24) | ((uint64_t)bytes[at + 1] << 16) |
                        ((uint64_t)bytes[at + 2] << 8) | (uint64_t)bytes[at + 3];

        [names appendFormat:@"%@%c%c%c%c(%llu)", n > 0 ? @" " : @"",
            bytes[at + 4], bytes[at + 5], bytes[at + 6], bytes[at + 7], size];

        if (size < 8) {
            break;
        }

        at += (NSUInteger)size;
    }

    return names;
}

/** Человеческое имя части — чтобы перечень читался. */
- (NSString *)nameOfPart:(NSUInteger)type {
    switch (type) {
        case YTUmpMediaHeader:          return @"заголовок";
        case YTUmpMedia:                return @"кусок";
        case YTUmpMediaEnd:             return @"конец";
        case YTUmpNextRequestPolicy:    return @"правила";
        case YTUmpFormatInitialization: return @"сведения";
        case YTUmpLiveHead:             return @"эфир";
        case YTUmpRedirect:             return @"переезд";
        case YTUmpError:                return @"отказ";
        case YTUmpProtectionStatus:     return @"подлинность";
        case YTUmpReload:               return @"перезапрос";
        case YTUmpStartPolicy:          return @"начало";
        case YTUmpRequestId:            return @"метка";
        case YTUmpCancelPolicy:         return @"отмена";
        default:                        return nil;
    }
}

/** Разбирает одну часть потока. */
- (void)handlePart:(YTUmpPart *)part {
    NSString *name = [self nameOfPart:part.type];

    [_seen appendFormat:@"%@%@:%lu",
        [_seen length] > 0 ? @" " : @"",
        name ?: [NSString stringWithFormat:@"#%lu", (unsigned long)part.type],
        (unsigned long)[part.body length]];

    switch (part.type) {
        case YTUmpMediaHeader: {
            YTSabrHeader *header = [self parseHeader:part.body];

            NSNumber *key = [NSNumber numberWithUnsignedInteger:header.headerId];

            [_openHeaders setObject:header forKey:key];
            [_openBodies setObject:[NSMutableData data] forKey:key];

            break;
        }

        case YTUmpMedia: {
            if ([part.body length] < 1) {
                break;
            }

            /**
             * Первый байт — номер заголовка, к которому кусок относится.
             * Дорожки приходят вперемешку, и это единственное, чем они
             * различаются.
             */
            uint8_t headerId = ((const uint8_t *)[part.body bytes])[0];

            NSMutableData *body = [_openBodies objectForKey:
                [NSNumber numberWithUnsignedInteger:headerId]];

            [body appendData:[part.body subdataWithRange:
                NSMakeRange(1, [part.body length] - 1)]];

            break;
        }

        case YTUmpMediaEnd: {
            if ([part.body length] < 1) {
                break;
            }

            NSNumber *key = [NSNumber numberWithUnsignedInteger:
                ((const uint8_t *)[part.body bytes])[0]];

            YTSabrHeader *header = [_openHeaders objectForKey:key];
            NSData *body = [_openBodies objectForKey:key];

            [_openHeaders removeObjectForKey:key];
            [_openBodies removeObjectForKey:key];

            if (header == nil || [body length] == 0) {
                break;
            }

            BOOL isVideo = [self isVideoItag:header.itag];

            /**
             * У эфира заголовок дорожки лежит **внутри каждого куска**.
             *
             * Обычный ролик сервер начинает отдельным заголовком (`ftyp`
             * и `moov`), помеченным как начальный, и дальше шлёт голые
             * куски. У идущей трансляции такого заголовка нет вовсе:
             * каждый кусок самодостаточен и несёт описание кодека
             * в себе — ведь подключиться к эфиру можно в любую секунду.
             *
             * Прежде мы ждали отдельного заголовка, не получали его
             * и объявляли подачу неподнявшейся: эфиры не игрались вовсе.
             * Теперь голову отрезаем сами: первую запоминаем как
             * заголовок дорожки, у остальных отбрасываем. Плееру нужен
             * один `moov` на дорожку, а не по одному на каждый кусок.
             */
            if (!header.isInit && [body length] > 8) {
                const uint8_t *bytes = [body bytes];

                if (memcmp(bytes + 4, "moof", 4) != 0) {
                    NSUInteger at = 0;
                    NSUInteger media = NSNotFound;

                    while (at + 8 <= [body length]) {
                        uint32_t size = ((uint32_t)bytes[at] << 24)
                                      | ((uint32_t)bytes[at + 1] << 16)
                                      | ((uint32_t)bytes[at + 2] << 8)
                                      | (uint32_t)bytes[at + 3];

                        if (memcmp(bytes + at + 4, "moof", 4) == 0) {
                            media = at;
                            break;
                        }

                        if (size < 8 || at + size > [body length]) {
                            break;
                        }

                        at += size;
                    }

                    if (media != NSNotFound && media > 0) {
                        NSData *head = [body subdataWithRange:NSMakeRange(0, media)];

                        if (isVideo && _videoInit == nil) {
                            _videoInit = head;
                            _videoInitItag = header.itag;

                            [self noteDeliveredVideoItag:header.itag];

                            NSLog(@"[YouTube/Подача] Эфир: заголовок дорожки %ld "
                                  @"взят из куска (%lu б)",
                                  (long)header.itag, (unsigned long)media);
                        } else if (!isVideo && _audioInit == nil) {
                            _audioInit = head;
                            _audioInitItag = header.itag;

                            NSLog(@"[YouTube/Подача] Эфир: заголовок звука %ld "
                                  @"взят из куска (%lu б)",
                                  (long)header.itag, (unsigned long)media);
                        }

                        body = [body subdataWithRange:
                            NSMakeRange(media, [body length] - media)];
                    }
                }
            }

            if (_liveMode && _liveStartSeconds <= 0 && isVideo && header.startMs > 0) {
                _liveStartSeconds = header.startMs / 1000.0;

                NSLog(@"[YouTube/Подача] Эфир: живой край на %lld с",
                      header.startMs / 1000);
            }

            if (header.isInit) {
                if (isVideo) {
                    _videoInit = body;

                    /**
                     * Запоминаем, чьи это SPS/PPS.
                     *
                     * Заголовок приходит заново при каждой смене дорожки —
                     * а сервер меняет её сам, когда сеть проседает. Номер
                     * нужен прокси: по нему он и узнаёт, что заголовок
                     * сменился и разбирать его надо заново. Без этого он
                     * склеивал кадры новой дорожки со старым заголовком,
                     * и картинка сыпалась до ближайшего явного кадра.
                     */
                    _videoInitItag = header.itag;

                    [self noteDeliveredVideoItag:header.itag];
                } else {
                    _audioInit = body;
                    _audioInitItag = header.itag;
                }

                break;
            }

            /**
             * Повтор уже имеющегося куска доставкой не считается.
             *
             * Иначе выходит замкнутый круг: сервер присылает тот же кусок,
             * качалка слышит «принесли», спит треть секунды и просит
             * снова — и так тысячи раз, при стоящем плеере, без единого
             * перезапуска, потому что «голода» по счётчику нет.
             */
            BOOL repeat = ([(isVideo ? _videoSegments : _audioSegments)
                objectForKey:[NSNumber numberWithInteger:header.sequence]] != nil);

            @synchronized (self) {
                [(isVideo ? _videoSegments : _audioSegments)
                    setObject:body
                       forKey:[NSNumber numberWithInteger:header.sequence]];
            }

            /**
             * Потолок на число хранимых фрагментов — последняя защита.
             *
             * Обычно лишнее выбрасывает `forgetBefore:` после сборки
             * куска. Но если кусок так и не собрался — а такое бывает,
             * когда мы просим у сервера не то время, — выбрасывать
             * становится некому, и фрагменты копятся, пока устройство
             * не снимет приложение. На 1080p это четыре мегабайта
             * за штуку: три десятка, и памяти нет.
             */
            [self capStorage:(isVideo ? _videoSegments : _audioSegments)
                        keep:(isVideo ? 24 : 16)];

            /**
             * Дорожку запоминаем по **каждому** куску, а не только
             * по заголовку.
             *
             * Прежде это делалось лишь при заводке дорожки, и панель
             * показаний рассказывала о той, что была объявлена вначале.
             * Сервер же вправе спуститься ниже и, если описание кодека
             * у новой дорожки то же, обходится без нового заголовка —
             * тогда объявление устаревает молча. На iPad 2 это выглядело
             * как «853x480, дорожка 136»: 136-я — это 720p, а картинка
             * давно шла 480p.
             */
            if (isVideo) {
                [self noteDeliveredVideoItag:header.itag];
            }

            /**
             * Запоминаем, докуда набрано. Дорожку берём из самого
             * заголовка — выбирает сервер, и это может быть не та,
             * которую мы прикидывали.
             */
            NSMutableDictionary *times = (isVideo ? _videoTimes : _audioTimes);

            int64_t span = header.durationMs;

            /**
             * У эфира куски приходят без длительности.
             *
             * Обычный ролик сервер размечает: начало и длина каждого
             * куска. У трансляции длины нет — и плейлист, собираемый
             * по этой разметке, обещал бы плееру нулевые куски. Длину
             * берём по соседям: расстояние между началами соседних
             * кусков и есть длина первого из них. Заодно дописываем её
             * предыдущему, у которого она была неизвестна.
             */
            /**
             * Длину берём из самого куска.
             *
             * В `trun` каждого фрагмента записаны длительности всех его
             * кадров; их сумма — точная длина куска, и известна она сразу,
             * как кусок пришёл. Прежняя оценка «по расстоянию до соседа»
             * ошибалась ровно тогда, когда сосед пропущен: кусок получал
             * десять секунд вместо пяти, в окно звука попадали два
             * звуковых фрагмента, а следующий кусок брал второй из них
             * снова — и звук откатывался назад при ровной картинке.
             * Вдобавок список эфира уже содержал строку с неверной длиной,
             * и наша ось времени расходилась с часами плеера.
             */
            if (_liveMode && span <= 0) {
                span = [self fragmentDurationMs:body video:isVideo];
            }

            if (_liveMode && span <= 0) {
                NSNumber *before = [NSNumber numberWithInteger:header.sequence - 1];

                NSArray *pair = [times objectForKey:before];

                if ([pair count] == 2) {
                    int64_t start = [[pair objectAtIndex:0] longLongValue];
                    int64_t gap = header.startMs - start;

                    /**
                     * Оценке нужен потолок.
                     *
                     * Номера кусков у эфира изредка идут с пропусками,
                     * и «предыдущий» оказывается не на пять секунд
                     * раньше, а на тридцать. Такая оценка уходит серверу
                     * как «у нас набрано тридцать секунд» — и он
                     * придерживает то, чего нам не хватает.
                     */
                    int64_t cap = MAX((int64_t)15000, [self typicalSpanMs:isVideo] * 5 / 2);

                    if (gap >= 100 && gap <= cap) {
                        span = gap;

                        [times setObject:[NSArray arrayWithObjects:
                                             [NSNumber numberWithLongLong:start],
                                             [NSNumber numberWithLongLong:gap],
                                             nil]
                                  forKey:before];
                    }
                }
            }

            [times setObject:[NSArray arrayWithObjects:
                              [NSNumber numberWithLongLong:header.startMs],
                              [NSNumber numberWithLongLong:span],
                              nil]
                   forKey:[NSNumber numberWithInteger:header.sequence]];

            YTSabrFormat *got = [YTSabrFormat formatWithItag:header.itag
                                                lastModified:header.lastModified];

            got.xtags = [self xtagsForItag:header.itag lastModified:header.lastModified];

            if (isVideo) {
                _gotVideo = got;
                _lastVideoSeq = MAX(_lastVideoSeq, header.sequence);
                _videoFilledMs = MAX(_videoFilledMs, header.startMs + header.durationMs);

                if (_firstVideoSeq == 0 || header.sequence < _firstVideoSeq) {
                    _firstVideoSeq = header.sequence;
                }

                [self noteLiveSeen:header.sequence at:header.startMs];
            } else {
                _gotAudio = got;
                _lastAudioSeq = MAX(_lastAudioSeq, header.sequence);
                _audioFilledMs = MAX(_audioFilledMs, header.startMs + header.durationMs);

                if (_firstAudioSeq == 0 || header.sequence < _firstAudioSeq) {
                    _firstAudioSeq = header.sequence;
                }
            }

            /**
             * Повтор — это тоже признак жизни, а не молчание.
             *
             * У эфира сервер сам, раз в двадцать секунд, отматывает нас
             * на три-четыре куска назад и тут же идёт дальше. В журнале
             * 28 это видно россыпью:
             *
             *     …3137464 [-4]3137461 [+3]3137465 3137466 3137467…
             *
             * Двадцать один повтор за сеанс — и **ни одной** мёртвой
             * получасовки: куски шли непрерывно, хотя часть №69 приходила
             * пятьдесят раз. То есть отмотка — обычный ход сервера, а не
             * беда. (Проверено и обратное: перечень, в котором дыры
             * объявлены своими, отказа не вызывает — шесть проб со стенда
             * с перечнем, расширенным на 12 и 40 кусков, дали ровно те же
             * куски, что честный.)
             *
             * А мы повтор считали за «ничего не принесли»: он не поднимал
             * `_delivered`, от этого прокси видел голод, копил пустые такты
             * и шёл перезаводить сессию и поток. Лечим раздельно: в
             * хранилище повтор не добавляем (иначе кусок уйдёт плееру
             * дважды), но как признак жизни он считается.
             */
            _received++;
            _lastMediaAt = [NSDate timeIntervalSinceReferenceDate];

            if (!repeat) {
                _delivered++;

                // Отказ кончился — указание сервера больше не действует.
                _liveResumeAt = 0;
                _liveRefusedSince = 0;
                _lastDeliveryAt = [NSDate timeIntervalSinceReferenceDate];

                [self restorePreferredRung];
            }

            NSLog(@"[YouTube/Подача] Фрагмент %@ №%ld: %lu КБ (itag %ld), "
                  @"%.2f + %.2f с, боксы: %@%@",
                  isVideo ? @"видео" : @"звука", (long)header.sequence,
                  (unsigned long)([body length] / 1024), (long)header.itag,
                  header.startMs / 1000.0, header.durationMs / 1000.0,
                  [self boxesIn:body], repeat ? @" (повтор)" : @"");

            break;
        }

        case YTUmpLiveHead: {
            /**
             * Докуда снята трансляция.
             *
             * Сервер сообщает это в каждом ответе эфира, а мы прежде
             * пропускали мимо: просили кусок, которого ещё нет, получали
             * пустоту и просили снова. Номер внутри — серверный, с нашими
             * номерами кусков не совпадает; берём время.
             */
            /**
             * Раз в минуту выписываем все поля — есть подозрение, что
             * поля 12/13 это не край, а **начало** окна перемотки: на
             * круглосуточной волне это время отставало от свежих кусков
             * на минуту и ехало с ними, а на молодом событии стояло
             * на месте, пока трансляция шла. Край тогда лежит в 14/15.
             * Проверить можно только цифрами из ответа.
             */
            NSTimeInterval said = [NSDate timeIntervalSinceReferenceDate];

            if (said - _liveHeadSaidAt > 60.0) {
                _liveHeadSaidAt = said;

                NSLog(@"[YouTube/Подача] Часть №31 (%lu байт): %@",
                      (unsigned long)[part.body length],
                      [self dumpProto:part.body depth:1]);
            }

            YTProtoReader *reader = [YTProtoReader readerWithData:part.body];

            /**
             * Край — поле 4, время головного куска в миллисекундах.
             *
             * Поля 12/13, которые мы читали прежде, — это **начало** окна
             * перемотки, и журнал это показал цифрами: на круглосуточной
             * волне оно отстаёт от головы на двенадцать часов
             * (12=8444828466666 при 4=8488028466), а на молодом событии
             * стоит на месте. Всё, что мы называли «краем», было началом
             * записи; отсюда и половина прежних загадок с молчанием.
             */
            int64_t headSeq = 0;
            int64_t headMs = 0;
            int64_t time = 0;
            int64_t scale = 0;
            int64_t seekMs = 0;
            int64_t seekScale = 0;

            while ([reader next]) {
                switch ([reader field]) {
                    case 3: headSeq = (int64_t)[reader takeVarint]; break;
                    case 4: headMs = (int64_t)[reader takeVarint]; break;
                    case 12: time = (int64_t)[reader takeVarint]; break;
                    case 13: scale = (int64_t)[reader takeVarint]; break;
                    case 14: seekMs = (int64_t)[reader takeVarint]; break;
                    case 15: seekScale = (int64_t)[reader takeVarint]; break;
                }
            }

            /**
             * Поля 14/15 — конец окна перемотки, и это **настоящий**
             * предел отдачи, на десять секунд позади головы (поля 4).
             *
             * Журнал `youtube(34).log` показал это цифрами, без всяких
             * догадок. Здоровые запросы (03:25:53, 03:26:53, 03:27:53)
             * имели время плеера ровно на этом пределе — круглое число
             * по границе куска: `player=15695910` при `14=15695910`.
             * А все запросы, на которые пришёл пустой ответ с частью
             * №69, стояли **за** пределом на 1,7–7 с: `player=15696182`
             * при `14=15696175`, `player=15696161` при `14=15696160`.
             * Голова (поле 4) в эти же мгновения была на десять секунд
             * выше предела, и именно на неё мы прежде ориентировались —
             * отсюда и промах.
             *
             * Стоит попросить за пределом хоть на полторы секунды, и
             * сервер вместо куска присылает №69 с пустотой; вернёшься
             * под предел — отдаёт сразу (03:24:26, `player=15695780`
             * при пределе 15695825, и показ ожил).
             */
            if (seekMs > 0 && seekScale > 0) {
                _liveSeekSeconds = (NSTimeInterval)seekMs / (NSTimeInterval)seekScale;
                _liveSeekSeenAt = [NSDate timeIntervalSinceReferenceDate];
            }

            if (headSeq > 0) {
                _liveHeadSequence = headSeq;
            }

            if (headMs > 0) {
                time = headMs;
                scale = 1000;

                // Запоминаем на случай перезапуска: новая сессия спросит сразу у края.
                [YTSabr rememberLiveHead:headMs / 1000.0 forVideo:[self videoId]];
            }

            if (time > 0 && scale > 0) {
                NSTimeInterval fresh = (NSTimeInterval)time / (NSTimeInterval)scale;

                if (_liveHeadSeconds <= 0) {
                    NSLog(@"[YouTube/Подача] Эфир: край на %.0f с", fresh);
                }

                _liveHeadSeconds = fresh;
            }

            break;
        }

        case YTUmpFormatInitialization:
            [self parseFormatInit:part.body];
            break;

        case YTUmpNextRequestPolicy: {
            /**
             * В правилах лежит печенье воспроизведения (поле 7). Оно
             * и есть память сервера о том, что уже отдано: вернём его
             * в следующем запросе — получим продолжение, не вернём —
             * те же первые фрагменты.
             *
             * Там же — поле 4, `backoff_time_ms`: сколько сервер просит
             * подождать перед следующим запросом. Просьбу эту стоит
             * исполнять: после прыжка по ролику он отвечал пустотой
             * (только правила да перечень дорожек), и два наших повтора
             * подряд, через полторы десятых секунды, получали ту же
             * пустоту. Перемотка от этого не доезжала вовсе.
             */
            YTProtoReader *reader = [YTProtoReader readerWithData:part.body];

            /**
             * Правила целиком — в журнал, раз в минуту.
             *
             * У браузера в дампе они выглядят так: `{1=120000 2=120000
             * 3=60000 7=печенье}` в шестидесяти трёх ответах из ста десяти,
             * и поля 4 (пауза) там нет вовсе. Что присылают нам, до сих пор
             * было не видно: читались только 4 и 7.
             */
            NSTimeInterval policyNow = [NSDate timeIntervalSinceReferenceDate];

            if (_liveMode && policyNow - _policySaidAt > 60.0) {
                _policySaidAt = policyNow;

                NSLog(@"[YouTube/Подача] Правила (%lu байт): %@",
                      (unsigned long)[part.body length],
                      [self dumpProto:part.body depth:1]);
            }

            while ([reader next]) {
                if ([reader field] == 7) {
                    _playbackCookie = [reader takeData];
                } else if ([reader field] == 4) {
                    _backoffMs = (int64_t)[reader takeVarint];
                }
            }

            break;
        }

        case YTUmpRedirect: {
            YTProtoReader *reader = [YTProtoReader readerWithData:part.body];

            while ([reader next]) {
                if ([reader field] == 1) {
                    NSString *moved = [reader takeString];

                    if ([moved length] > 0) {
                        /**
                         * Адрес переезда берём **как есть**.
                         *
                         * Сервер возвращает в нём наш же `n` — уже
                         * расшифрованный, — и второй проход превращает
                         * его в мусор. В живом прогоне это было видно
                         * прямо: `c_Sjv… → 6pZiV…` первым запросом,
                         * и тут же `6pZiV… → o4cXF…` перед переездом,
                         * а следом отказ 403.
                         */
                        _url = [moved copy];
                        _redirected = YES;

                        NSLog(@"[YouTube/Подача] Переезд на другой узел");
                    }
                }
            }

            break;
        }

        case YTUmpProtectionStatus: {
            YTProtoReader *reader = [YTProtoReader readerWithData:part.body];

            while ([reader next]) {
                if ([reader field] == 1) {
                    uint64_t status = [reader takeVarint];

                    /**
                     * 1 — «всё в порядке», 2 — «нужен PO-токен»,
                     * 3 — «токен просрочен». Второе и третье означают,
                     * что подача байтов не даст, сколько ни проси.
                     */
                    if (status != 1) {
                        NSLog(@"[YouTube/Подача] Требуется подтверждение "
                              @"подлинности (состояние %llu)", status);
                    }
                }
            }

            break;
        }

        case YTUmpReload: {
            /**
             * Сервер просит взять ответ `/player` заново: наш устарел.
             * Медиа он при этом не присылает вовсе — отсюда и пустые
             * ответы, которые раньше выглядели как отказ без причины.
             *
             * Внутри лежит токен, который полагается вернуть в `/player`
             * (`playbackContext.reloadPlaybackContext`), чтобы получить
             * свежий адрес подачи и настройки. Достаём его сразу: без
             * него перезапрос бессмыслен, а с ним — обычное обращение.
             */
            YTProtoReader *outer = [YTProtoReader readerWithData:part.body];

            while ([outer next]) {
                if ([outer field] != 1) {
                    continue;
                }

                YTProtoReader *inner = [YTProtoReader readerWithData:[outer takeData]];

                while ([inner next]) {
                    if ([inner field] == 1) {
                        _reloadToken = [[inner takeString] copy];
                    }
                }
            }

            NSLog(@"[YouTube/Подача] Сервер просит обновить ответ /player "
                  @"(токен %@)", [_reloadToken length] > 0
                      ? [NSString stringWithFormat:@"%lu знаков",
                            (unsigned long)[_reloadToken length]]
                      : @"не найден");

            _needsReload = YES;

            break;
        }

        case YTUmpError: {
            /**
             * В отказе первым полем лежит его название — короткая
             * строка вроде `sabr.malformed_config`. Она и есть всё
             * объяснение, и без неё отказ неотличим от любого другого.
             */
            NSString *reason = nil;

            YTProtoReader *reader = [YTProtoReader readerWithData:part.body];

            while ([reader next]) {
                if ([reader field] == 1) {
                    reason = [reader takeString];
                }
            }

            NSLog(@"[YouTube/Подача] Отказ: %@", reason ?: @"без объяснения");

            /**
             * «Ни одной дорожки не выбрано» — отказ поправимый.
             *
             * Он означает, что из названного нами сервер сейчас не может
             * дать ничего. Когда в перечне одна дорожка — а так бывает
             * при закреплении по выбору человека, — это не приговор
             * ролику, а приговор нашему упрямству: стоит предложить
             * остальные, и показ пойдёт. Прежде здесь всё кончалось
             * переходом на готовые адреса, а у эфира их нет.
             */
            if ([reason rangeOfString:@"no_video_selected"].location != NSNotFound) {
                _refusedNoVideo = YES;
            }

            break;
        }

        case YTUmpResumePoint: {
            /**
             * Часть №69 — не отказ, а сообщение, которое надо подтвердить.
             *
             * В дампе браузер получает её в двадцати двух ответах из ста
             * десяти, по одной на дорожку перед заголовком, — и в каждом из
             * этих ответов есть медиа. У нас (журнал 92) из тридцати пяти
             * ответов с №69 куски были в шести. Разница в одном: браузер в
             * следующем запросе шлёт поле 24 = {8: 7}, а мы не слали никогда.
             */
            _ackResumePoint = YES;

            /**
             * Сервер отказал и сам назвал место, с которого продолжить.
             *
             * Журнал `youtube(35).log`, 03:42:15 — 03:42:56: минуту
             * подряд пустые ответы, хотя время плеера честно стояло под
             * пределом отдачи (3–5 с ниже, правка 1.4-82 работала). Всё
             * это время часть №69 повторяла одно и то же:
             *
             *     1={1={… 9=3139458} 2=1 3=3139469 …}
             *     №31: 3=3139472 4=15696940000 14=15696930000
             *
             * Номер 3139458 — это семьдесят секунд позади головы. И
             * ожил показ ровно тогда, когда запрос случайно ушёл на
             * 15696865 с — то есть на **этот самый** кусок.
             *
             * Значит поле `1.1.9` — не «застрявший» кусок, как я думал
             * прежде (смутило `9=3139314` при `3=3139314`: там сервер
             * просто указывал на себя), а **место, с которого он готов
             * продолжить**. Раз в шесть минут он отодвигает это место
             * далеко назад и до тех пор у края не отдаёт ничего. Наше
             * дело — послушаться и уйти туда, а не топтаться у предела.
             *
             * Время считаем от головы: номера кусков у эфира идут подряд
             * и ровно по длине куска.
             */
            /**
             * Разбираем вслух раз в минуту — поля этой части менялись
             * у нас на глазах дважды, и читать её по памяти нельзя.
             */
            NSTimeInterval saidResume = [NSDate timeIntervalSinceReferenceDate];

            if (saidResume - _liveResumeDumpAt > 60.0) {
                _liveResumeDumpAt = saidResume;

                NSLog(@"[YouTube/Подача] Часть №69 (%lu байт): %@",
                      (unsigned long)[part.body length],
                      [self dumpProto:part.body depth:2]);
            }

            /**
             * Отметка отказа: пришла №69 — значит сервер сейчас в том
             * состоянии, когда он нам не отдаёт. Снимается первым же
             * принесённым куском (см. `absorb:`).
             */
            if (_liveRefusedSince <= 0) {
                _liveRefusedSince = [NSDate timeIntervalSinceReferenceDate];
            }

            int64_t resumeSeq = 0;

            YTProtoReader *outer = [YTProtoReader readerWithData:part.body];

            while ([outer next]) {
                if ([outer field] != 1) {
                    continue;
                }

                YTProtoReader *mid = [YTProtoReader readerWithData:[outer takeData]];

                while ([mid next]) {
                    if ([mid field] != 1) {
                        continue;
                    }

                    YTProtoReader *inner = [YTProtoReader readerWithData:[mid takeData]];

                    while ([inner next]) {
                        if ([inner field] == 9) {
                            resumeSeq = (int64_t)[inner takeVarint];
                        }
                    }
                }
            }

            if (resumeSeq > 0 && _liveHeadSequence > 0 && _liveHeadSeconds > 0) {
                int64_t behind = _liveHeadSequence - resumeSeq;

                if (behind > 0) {
                    NSTimeInterval span = [self typicalSpanMs:YES] / 1000.0;

                    if (span <= 0) {
                        span = 5.0;
                    }

                    NSTimeInterval at = _liveHeadSeconds - (NSTimeInterval)behind * span;

                    if (at > 0 && (_liveResumeAt <= 0 || ABS(at - _liveResumeAt) > 1.0)) {
                        _liveResumeAt = at;
                        _liveResumeSaidAt = [NSDate timeIntervalSinceReferenceDate];

                        NSLog(@"[YouTube/Подача] Эфир: сервер просит продолжить "
                              @"с куска №%lld — это %.0f с, на %.0f с позади края",
                              resumeSeq, at, _liveHeadSeconds - at);
                    }
                }
            }

            break;
        }

        default: {
            /**
             * Незнакомую часть разбираем вслух — первые три раза.
             *
             * Иначе о ней нечего сказать, кроме длины. А сказать есть что:
             * пустые ответы подачи у эфира отличаются от рабочих ровно
             * одним — в них дважды приходит часть №69, по одной на дорожку,
             * и ни одного куска. Похоже, сервер чего-то от нас ждёт,
             * а мы этого не возвращаем. Поля покажут, чего именно.
             */
            NSNumber *key = [NSNumber numberWithUnsignedInteger:part.type];

            if (_unknownSeen == nil) {
                _unknownSeen = [NSMutableDictionary dictionary];
            }

            /**
             * Печатаем первые три раза, а дальше раз в минуту.
             *
             * Только «первые три» оказалось мало: журнал у нас с потолком
             * в полмегабайта и сам себя подрезает, а эфир идёт часами —
             * начало сессии из файла вытесняется, и разбор вместе с ним.
             * Раз в минуту строка займёт немного, зато будет в любом
             * присланном хвосте.
             */
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            NSNumber *last = [_unknownSeen objectForKey:key];

            if (last == nil || now - [last doubleValue] > 60.0) {
                [_unknownSeen setObject:[NSNumber numberWithDouble:now]
                                 forKey:key];

                NSLog(@"[YouTube/Подача] Часть №%lu (%lu байт): %@",
                      (unsigned long)part.type,
                      (unsigned long)[part.body length],
                      [self dumpProto:part.body depth:2]);
            }

            break;
        }
    }
}

/**
 * Раскладывает сообщение на поля: «номер=значение», вложенные — в скобках.
 *
 * Служит одному: понять, что прислал сервер, когда разбирать это ещё
 * нечем. Числа печатаются как есть, строки — если печатаемы, прочее —
 * длиной и первыми байтами.
 */
- (NSString *)dumpProto:(NSData *)body depth:(NSInteger)depth {
    NSMutableString *out = [NSMutableString string];

    YTProtoReader *reader = [YTProtoReader readerWithData:body];

    while ([reader next]) {
        NSUInteger number = [reader field];

        uint64_t value = [reader takeVarint];
        NSData *bytes = [reader takeData];

        [out appendFormat:@"%@%lu=", [out length] > 0 ? @" " : @"",
            (unsigned long)number];

        if (bytes == nil) {
            [out appendFormat:@"%llu", value];

            continue;
        }

        NSString *text = [[NSString alloc] initWithData:bytes
                                               encoding:NSUTF8StringEncoding];

        BOOL printable = [text length] > 0;

        for (NSUInteger i = 0; printable && i < [text length]; i++) {
            unichar one = [text characterAtIndex:i];

            printable = (one >= 32 && one < 127);
        }

        if (printable) {
            [out appendFormat:@"\"%@\"", text];
        } else if (depth > 0 && [bytes length] > 0) {
            [out appendFormat:@"{%@}", [self dumpProto:bytes depth:depth - 1]];
        } else {
            const uint8_t *raw = [bytes bytes];

            NSMutableString *hex = [NSMutableString string];

            for (NSUInteger i = 0; i < MIN((NSUInteger)12, [bytes length]); i++) {
                [hex appendFormat:@"%02x", raw[i]];
            }

            [out appendFormat:@"<%lu:%@>", (unsigned long)[bytes length], hex];
        }
    }

    return out;
}

#pragma mark Запрос

static NSMutableDictionary *YTLiveHeads = nil;

+ (void)rememberLiveHead:(NSTimeInterval)seconds forVideo:(NSString *)videoId {
    if ([videoId length] == 0 || seconds <= 0) {
        return;
    }

    @synchronized ([YTSabr class]) {
        if (YTLiveHeads == nil) {
            YTLiveHeads = [NSMutableDictionary dictionary];
        }

        // Вместе со временем часов: через час край уже не тот.
        [YTLiveHeads setObject:[NSArray arrayWithObjects:
                                   [NSNumber numberWithDouble:seconds],
                                   [NSNumber numberWithDouble:[NSDate timeIntervalSinceReferenceDate]],
                                   nil]
                        forKey:videoId];
    }
}

+ (NSTimeInterval)rememberedLiveHeadForVideo:(NSString *)videoId {
    if ([videoId length] == 0) {
        return 0;
    }

    @synchronized ([YTSabr class]) {
        NSArray *pair = [YTLiveHeads objectForKey:videoId];

        if ([pair count] != 2) {
            return 0;
        }

        NSTimeInterval head = [[pair objectAtIndex:0] doubleValue];
        NSTimeInterval at = [[pair objectAtIndex:1] doubleValue];
        NSTimeInterval age = [NSDate timeIntervalSinceReferenceDate] - at;

        // Край идёт вместе с часами; дольше десяти минут не доверяем.
        if (age < 0 || age > 600) {
            return 0;
        }

        return head + age;
    }
}

- (BOOL)requestVideo:(YTSabrFormat *)video
               audio:(YTSabrFormat *)audio
              fromMs:(int64_t)startMs {
    /**
     * Переезд — это не ответ, а указание спросить в другом месте.
     *
     * Сервер отвечает одной частью «иди на такой-то узел» и больше
     * ничем; данных в таком ответе нет вовсе. Раньше мы запоминали
     * новый адрес и на этом останавливались — выходил пустой ответ
     * без объяснения. Теперь повторяем запрос туда же, куда послали.
     *
     * Ходов немного: узел, посылающий по кругу, — это уже беда, и
     * ходить по ней бесконечно незачем.
     */
    /**
     * Край с прошлой сессии — просим сразу у него.
     *
     * Первый запрос «с нуля» сервер понимает как «с начала окна
     * перемотки» — на круглосуточной волне это двенадцать часов назад,
     * и каждая новая сессия делала два лишних хода: кусок из вчера,
     * потом прыжок к краю. При перезапуске посреди показа край известен
     * с точностью до пяти секунд — с него и начинаем.
     */
    // Подмена подачи под идущим показом говорит, откуда продолжать.
    if (_liveMode && startMs == 0 && _liveStartHint > 0) {
        startMs = (int64_t)(_liveStartHint * 1000.0);

        NSLog(@"[YouTube/Подача] Эфир: продолжаем с %.0f с — там стоит показ",
              _liveStartHint);
    }

    if (_liveMode && startMs == 0) {
        NSTimeInterval known = [YTSabr rememberedLiveHeadForVideo:[self videoId]];

        if (known > 0) {
            /**
             * Минус пять секунд, а не тридцать.
             *
             * Полминуты назад уместны при открытии с нуля — это запас
             * на старт. При перезапуске посреди показа те же полминуты
             * оборачиваются повтором: новая сессия начинает с того, что
             * человек только что видел. Один кусок назад — и склейка
             * почти незаметна.
             */
            /**
             * Пятнадцать секунд, а не пять.
             *
             * Запомненное — это голова (поле 4), а отдаёт сервер только
             * до предела окна перемотки, который лежит на десять секунд
             * ниже. Прежние «минус пять» целили на пять секунд **за**
             * предел, и новая сессия начинала с пустого ответа и части
             * №69 — это видно в журнале 34 на каждом перезапуске.
             * Минус пятнадцать — это пять секунд под пределом: кусок
             * там уже нарезан, и плееру сразу достаётся запас.
             */
            startMs = (int64_t)(MAX(0.0, known - (NSTimeInterval)YTLiveCushion) * 1000.0);

            NSLog(@"[YouTube/Подача] Эфир: край помним с прошлой сессии — "
                  @"просим сразу с %.0f с", startMs / 1000.0);
        }
    }

    /**
     * Ничего не знаем о крае — говорим «играю прямо сейчас».
     *
     * Дальше по коду ноль отличается от подсказки и от запомненного края:
     * это случай первого захода, когда о ролике нам не известно ничего.
     * Сервер на ноль отвечает вчерашним куском, а на `YTLiveNow` — краем;
     * так спрашивает и сам TV-клиент.
     */
    /**
     * Отметка идёт **мимо** учёта, и это не мелочь.
     *
     * Положенная в `startMs`, она доходит до `prepareVideo:`, тот считает
     * её прыжком и зовёт `resetCounters:` — счётчик набранного становится
     * равен девяти квадриллионам миллисекунд. Дальше каждая просьба
     * кажется «слишком далеко позади», подача целится в 9007199254701 с,
     * и показ не начинается вовсе. Ровно это и вышло в 1.4-145
     * (журнал 76): одна трансляция не заиграла, вторая оборвалась.
     *
     * В `startMs` остаётся ноль — он же означает «о крае ничего не
     * известно» при разборе пустого первого ответа ниже.
     */
    if (_liveMode && startMs == 0) {
        _askLiveNow = YES;

        NSLog(@"[YouTube/Подача] Эфир: края не знаем — просим играющее сейчас");
    }

    for (NSInteger attempt = 0; attempt < 3; attempt++) {
        _redirected = NO;

        BOOL sent = [self sendVideo:video audio:audio fromMs:startMs];

        // Отметка разовая: край узнан, дальше просим по своему месту.
        _askLiveNow = NO;

        if (sent) {
            return [self stepToLiveEdge:video audio:audio];
        }

        if (!_redirected) {
            /**
             * Закреплённую дорожку сервер не принял — отпускаем и просим
             * снова, теперь со всем перечнем.
             *
             * Один раз за сессию: если и полный перечень не подошёл,
             * дело не в закреплении.
             */
            if (_refusedNoVideo && _hardPin && !_softenedPin && _pinnedVideo != nil) {
                NSLog(@"[YouTube/Подача] Закреплённую %ld сервер не принял — "
                      @"предлагаем весь перечень",
                      (long)_pinnedVideo.itag);

                _softenedPin = YES;
                _hardPin = NO;
                _refusedNoVideo = NO;
                _toldFormats = NO;

                continue;
            }

            /**
             * У эфира первый ответ бывает пуст — без единого куска и
             * заголовка, зато с краем в части №31. Прежде на этом всё
             * кончалось: «Подача не задалась», готовые адреса у эфира
             * не работают, и человек открывал ролик заново. Зная край,
             * можно попросить рядом с ним — и обычно этого хватает.
             */
            if (_liveMode && _liveHeadSeconds > 0 && startMs == 0) {
                return [self stepToLiveEdge:video audio:audio];
            }

            return NO;
        }
    }

    NSLog(@"[YouTube/Подача] Слишком много переездов");

    return NO;
}

- (BOOL)restartSession {
    if (!_liveMode) {
        return NO;
    }

    NSTimeInterval tail = [self liveNextTime];

    /**
     * Цель — сам край, а не «за полминуты до него» и не хвост.
     *
     * Во время перерыва сервер отдаёт этой и любой новой сессии ровно
     * одно: головной кусок, тот, что назван в части №31. Просьба с
     * хвоста (где мы застряли) и просьба за полминуты до края получают
     * «в ожидании» — пять мягких перезапусков подряд впустую в журнале
     * 00:29:40 — 00:30:14, все с хвоста. Просьба о головном — кусок сразу.
     */
    /**
     * Целим в запас позади края, а не в сам край.
     *
     * Журнал 42: паузу в сто пятьдесят семь секунд оборвал полный
     * перезапуск потока, и его новая сессия попросила `15704475` при
     * крае `15704570` — край минус девяносто пять. Заиграло сразу и со
     * здоровым запасом. Просьба же о самом крае даёт один кусок в пять
     * секунд, и запаса из неё не выходит (см. `YTLiveCushion`).
     */
    /**
     * Продолжаем с хвоста набранного, а не возвращаемся к запасу.
     *
     * Край минус запас — цель только для **пустого** начала. Посреди
     * показа это ошибка, и журнал 44 показал какая: пересадка просила
     * `15706550` при крае `15706640`, то есть ровно минус девяносто, —
     * а куски до хвоста у нас уже лежали. Сервер честно присылал их
     * заново, всё это считалось повторами, нового не появлялось, и
     * пересадки шли одна за другой без всякого движения.
     *
     * С хвоста же просьба попадает в то единственное, чего нам не
     * хватает. И запас от этого не страдает, а как раз набирается:
     * позади края куски уже нарезаны и идут пачкой, быстрее реального
     * времени, — тем и догоняем.
     */
    NSTimeInterval target = tail;

    /**
     * Живой хвост продолжаем, мёртвый — переступаем.
     *
     * Журнал 45 показал третий случай, которого я не предусмотрел ни в
     * 1.4-91 (целил всегда в край минус запас), ни в 1.4-93 (целил всегда
     * в хвост). Куски встали на `15709110` — и видео, и звук разом, —
     * а край уехал на `15709195`. Пересадка при этом просила снова и
     * снова `15709115`, то есть ровно ту точку, которой нет: «застряла
     * на 15709115 — заводим заново с 15709115», пять раз подряд.
     *
     * Переступ дыры сам бы это поправил, но он ждёт пятнадцати секунд
     * тишины, а сторож по отставанию будит нас через шесть — и сажает
     * обратно на мёртвую точку раньше, чем переступ получит право
     * сработать.
     *
     * Признак смерти простой: хвост отстал от предела отдачи больше чем
     * на два десятка секунд. Живого хвоста так не бывает — у края мы
     * идём вплотную. Значит там дыра, и садиться надо сразу за предел
     * минус десять, как делает переступ.
     */
    NSTimeInterval limit = _liveSeekSeconds > 0
        ? _liveSeekSeconds : (_liveHeadSeconds - 10.0);

    if (limit > 0 && (tail <= 0 || limit - tail > 20.0)) {
        /**
         * Садимся не вплотную к краю, а с запасом нарезанного впереди.
         *
         * Край минус десять — это место, где нагонять нечем: там подача
         * идёт ровно в скорость нарезки. Отступив на сорок секунд, мы
         * оставляем перед собой уже нарезанное, и заберём его пачкой,
         * быстрее реального времени, — тем и поднимем запас обратно.
         */
        /**
         * К самому пределу отдачи, а не на сорок секунд назад.
         *
         * Сорок секунд назад — остаток от отступа, которого больше нет.
         * Сервер, которому мы представились играющим сейчас, в прошлое
         * не идёт (журнал 79) и отвечает всё тем же краем; просьба
         * пропадает впустую, а сторож заводит нас снова через пару
         * секунд. Браузер назад не ходит ни разу за сто пять запросов —
         * и мы не ходим.
         */
        target = limit;
    }

    if (target <= 0 && _liveHeadSeconds > 0) {
        target = MAX(0.0, _liveHeadSeconds - (NSTimeInterval)YTLiveCushion);
    }

    if (target <= 0) {
        return NO;
    }

    /**
     * Застрявшую сессию подачи не лечат — её заводят заново.
     *
     * Сервер помнит по печенью воспроизведения, какой кусок он нам
     * «должен», и если этого куска у него нет, ждёт его вечно: не
     * помогает ни просьба с хвоста, ни просьба о головном куске — в
     * журнале восемь «перескакиваем на край» подряд и ноль кусков.
     * А стоило человеку переоткрыть ролик — новая сессия заиграла сразу.
     *
     * Делаем то же самое, только без перезапуска показа: печенье
     * и счёт запросов сбрасываем, набранное и ось времени остаются.
     * Для сервера мы новый зритель, просящий с края; для плеера ничего
     * не произошло, кроме склейки в кадре.
     */
    NSLog(@"[YouTube/Подача] Эфир: сессия застряла на %.0f с (край %.0f с) — "
          @"заводим подачу заново с %.0f с", tail, _liveHeadSeconds, target);

    /**
     * Смена ступени при застревании отключена.
     *
     * Она строилась на мысли, что у дорожки 136 дыра. Опыт в браузере
     * с принудительным H.264 её опроверг: в те же минуты сервер отдаёт
     * браузеру 136 без единого пропуска. Спуск на 480p ничего не лечил,
     * только портил картинку при каждом перезапуске.
     */
    _playbackCookie = nil;
    _requestNumber = 0;
    _failures = 0;
    _toldFormats = NO;

    [self resetCounters:(int64_t)(target * 1000.0)];

    return [self sendVideo:_video audio:_audio fromMs:(int64_t)(target * 1000.0)];
}

/**
 * Подводит эфир к живому краю.
 *
 * Первый запрос уходит «с нуля», и сервер волен ответить с начала окна
 * перемотки. У круглосуточной волны оно на двенадцать часов позади:
 * в журнале первый кусок лёг на 15637015 с при крае 15680105 с —
 * человек смотрел бы вчерашний вечер, считая его эфиром. Край к этому
 * моменту уже известен из части №31, поэтому, отстав больше чем на две
 * минуты, сбрасываем набранное и просим за полминуты до края — это
 * то же `LIVE_BEHIND`, что держит Android, только в нужную сторону.
 *
 * Вперёд сервер ходит охотно, это назад он не умеет. Возвращает,
 * есть ли после всего хоть один кусок.
 */
- (BOOL)stepToLiveEdge:(YTSabrFormat *)video audio:(YTSabrFormat *)audio {
    if (!_liveMode || _liveHeadSeconds <= 0) {
        return [_videoSegments count] > 0 || _videoInit != nil;
    }

    BOOL empty = ([_videoSegments count] == 0);
    NSTimeInterval behind = _liveHeadSeconds - _liveStartSeconds;

    /**
     * Порог «слишком далеко позади» обязан быть больше места набора.
     *
     * Здесь стояло ровно 120, и когда в 1.4-125 место набора подняли до
     * ста двадцати, пороги столкнулись: мы стартовали за 120 с, как и
     * задумано, а эта проверка тут же объявляла старт слишком далёким,
     * чистила хранилище и прыгала к краю. Журнал 71 говорит об этом
     * прямо: «просим сразу с 21040 с», а следом «первый кусок на 120 с
     * позади края — переходим к краю». Весь смысл глубокого старта
     * пропадал, и буфер вышел хуже прежнего — медиана 4,4.
     *
     * Считаем порог от самого места набора, чтобы они не спорили впредь.
     */
    if (!empty && (_liveStartSeconds <= 0
                   || behind < (NSTimeInterval)YTLiveCushion + 60.0)) {
        /**
         * Набираем запас заранее, пока показ ещё не начался.
         *
         * У самого края запас набрать **нельзя**, и это не наша
         * нерасторопность, а арифметика. С полем 29 сервер придерживает
         * запрос до нарезки и отдаёт ровно один кусок: значит подача
         * идёт точно в реальном времени минус накладные расходы. Журнал
         * 39 это и показал — кусок каждые 6,55 с там, где показ съедает
         * один за 5,00 с. Запас в таком ходу может только убывать: он
         * сполз с двух кусков до одного, потом до нуля, и дальше тишина.
         * (Человек то же увидел в окне статистики: скорость падала,
         * буфер истощался.) А в журнале 28, где зависаний не было вовсе,
         * куски шли каждые 3,5 с — быстрее реального времени.
         *
         * Позади края куски уже нарезаны, и сервер отдаёт их сразу и
         * пачкой: на стенде шесть кусков пришли за 674 мс. Потому
         * отступаем от края на минуту **до** начала показа: прокси ведёт
         * свою ось времени и начинает с самого старого набранного, так
         * что эта минута и становится запасом — и не тает, а работает.
         */
        /**
         * Запаса впрок не набираем — браузер этого не делает.
         *
         * Отступ на сто двадцать секунд был нашей выдумкой, заведённой
         * ради пятидесяти секунд запаса. Дамп движения youtube.com/tv
         * говорит, что у настоящего клиента таких секунд нет и в помине.
         * Впереди точки показа у него лежит: две секунды в начале, семь
         * в середине сессии, семнадцать в среднем за все сто пять живых
         * запросов. Шестьдесят шесть набираются только в самом конце,
         * когда показ уже остановлен и поле 28 перестало расти.
         *
         * Живёт он этим спокойно потому, что ответ приходит почти на
         * каждую просьбу: пустой один из ста пяти, промежуток две
         * секунды, четверть мегабайта за раз. Запас ему не нужен — ему
         * хватает того, что сервер не молчит.
         *
         * А нам этот отступ выходил боком дважды. Он спорил с первой
         * просьбой «играю прямо сейчас» (журнал 79: просили 15803190,
         * получили край), и ради него заведена вся возня с пересадками,
         * переступом дыр и перезапусками, которая половину этих полутора
         * сотен сборок нас и подводила.
         */
        return YES;
    }

    if (empty) {
        NSLog(@"[YouTube/Подача] Эфир: первый ответ пуст — просим у края");
    } else {
        NSLog(@"[YouTube/Подача] Эфир: первый кусок на %.0f с позади края — "
              @"переходим к краю", behind);
    }

    /**
     * Сначала за полминуты до края, потом — сам край.
     *
     * За полминуты до края сервер обычно отдаёт запас разом — показ
     * начинается с трёх кусков в руках. Но когда эфир только что
     * прерывался, на просьбу «за тридцать секунд до края» он отвечает
     * вечным «в ожидании», а на просьбу о самом головном куске —
     * отдаёт его сразу: в журнале одно и то же место, 00:30:47,
     * пустота на 15685380 и кусок на 15685410. Поэтому вторая попытка
     * целит ровно в край, без отступа.
     */
    /**
     * Сперва — на запас позади края, и только потом к самому краю.
     *
     * Журнал 40 показал, почему это важно: первым ответом сервер дал
     * кусок за двенадцать часов до края (начало окна перемотки), отчего
     * `behind` вышел огромным, набор запаса не сработал вовсе, и мы
     * ушли сюда — а тут целились в край минус тридцать и в край. Показ
     * начался с пяти-семи секунд запаса и тут же их проел.
     */
    NSTimeInterval targets[3] = {
        MAX(0.0, _liveHeadSeconds - (NSTimeInterval)YTLiveCushion),
        MAX(0.0, _liveHeadSeconds - 30.0),
        _liveHeadSeconds
    };

    for (NSInteger attempt = 0; attempt < 3; attempt++) {
        NSTimeInterval target = targets[attempt];

        [_videoSegments removeAllObjects];
        [_audioSegments removeAllObjects];
        [_videoTimes removeAllObjects];
        [_audioTimes removeAllObjects];

        /**
         * Уходим с этого места **новой** сессией, а не прыжком внутри
         * старой. Вот чем отличались удача и беда в журнале 41.
         *
         * Беда, 05:24:29. Края мы ещё не знали, первая просьба ушла без
         * места, и сервер поставил нас на начало окна перемотки — за
         * двенадцать часов до края. Отсюда мы прыгнули на край минус
         * девяносто, но печенье воспроизведения осталось прежним: для
         * сервера это была всё та же сессия, которую он уже поставил в
         * начало записи. Он отдал одну пачку — семь кусков за три
         * секунды — и отрезал насовсем: дальше два часа… две минуты
         * сплошных «Ответ 0 КБ» с частью №69, и просьбы что у старого
         * места, что у самого края получали ровно ничего.
         *
         * Удача, 05:26:34. Та же цель, край минус девяносто, но это была
         * **первая** просьба свежей сессии (край помнился с прошлого
         * раза). Заиграло сразу и набрало пятьдесят пять секунд запаса,
         * которые держались минутами.
         *
         * Значит дело не в месте, а в том, чьей первой просьбой оно
         * стало. Потому здесь сбрасываем печенье и счёт запросов — всё
         * то же, что делает `restartSession`, — и для сервера мы новый
         * зритель, чья первая просьба легла куда нам надо.
         */
        _playbackCookie = nil;
        _requestNumber = 0;
        _failures = 0;
        _toldFormats = NO;

        [self resetCounters:(int64_t)(target * 1000.0)];

        // Начало эфира назначит первый же кусок, пришедший с нового места.
        _liveStartSeconds = 0;

        if ([self sendVideo:video audio:audio fromMs:(int64_t)(target * 1000.0)]
            && [_videoSegments count] > 0) {
            return YES;
        }

        // Край мог сдвинуться, пока ходили, — вторая цель берётся свежей.
        targets[1] = _liveHeadSeconds;
    }

    return [_videoSegments count] > 0 || _videoInit != nil;
}

- (BOOL)sendVideo:(YTSabrFormat *)video
            audio:(YTSabrFormat *)audio
           fromMs:(int64_t)startMs {
    NSMutableURLRequest *request = [self prepareVideo:video audio:audio fromMs:startMs];

    if (request == nil) {
        return NO;
    }

    return [self absorb:[self perform:request]];
}

/**
 * Запрос к подаче разбит на три шага — подготовку, сеть и разбор.
 *
 * Причина — замок. Прокси держит подачу под одним замком на всё время
 * запроса, и пока качалка ждала ответа сервера (полсекунды-секунду,
 * а то и больше), сборка куска для плеера стояла в очереди за ней.
 * В журнале это «Сегмент … за 3434 мс», «за 7866 мс», «за 13730 мс» при
 * том, что сама склейка занимает сорок. На старте эфира это прямая
 * задержка первого кадра.
 *
 * Подготовка и разбор трогают общее состояние и идут под замком; сеть
 * между ними не трогает ничего и идёт без него.
 */
- (NSMutableURLRequest *)prepareRequestFrom:(NSTimeInterval)playerTime {
    return [self prepareVideo:_video audio:_audio fromMs:(int64_t)(playerTime * 1000.0)];
}

- (NSMutableURLRequest *)prepareVideo:(YTSabrFormat *)video
                                audio:(YTSabrFormat *)audio
                               fromMs:(int64_t)startMs {
    _video = video;
    _audio = audio;

    /**
     * Прыжок по ролику обнуляет накопленное — у записи. Запас в две
     * секунды — на обычное движение вперёд; у эфира заглядывают дальше,
     * и это не прыжок: просьба о следующем куске законно уходит за конец
     * набранного.
     */
    int64_t ahead = _liveMode ? 15000 : 2000;

    if (!_prefilling && _liveMode && _videoFilledMs > 0
        && startMs < _videoFilledMs - (int64_t)(YTLiveCushion + 30) * 1000) {
        NSLog(@"[YouTube/Подача] Эфир: просьба с %.0f с слишком далеко позади — "
              @"берём %.0f с", startMs / 1000.0, (_videoFilledMs - 40000) / 1000.0);

        startMs = _videoFilledMs - 40000;
    }

    // У эфира просьба назад — недоразумение, а не прыжок: подтягиваем к концу набранного.
    // Кроме набора запаса: там мы **нарочно** просим раньше набранного.
    if (!_prefilling && _liveMode && _rangeStartMs > 0 && startMs + 2000 < _rangeStartMs) {
        startMs = MAX(_videoFilledMs, _rangeStartMs);
    }

    if (startMs + 2000 < _rangeStartMs || startMs > _videoFilledMs + ahead) {
        /**
         * У эфира набранное при прыжке остаётся: куски позади дыры плеер
         * ещё не забрал, они стоят в списке, и без них он встанет навсегда.
         */
        if (!_liveMode) {
            [_videoSegments removeAllObjects];
            [_audioSegments removeAllObjects];
            [_videoTimes removeAllObjects];
            [_audioTimes removeAllObjects];
        }

        [self resetCounters:startMs];

        NSLog(@"[YouTube/Подача] Прыжок на %.0f с — %@",
              startMs / 1000.0,
              _liveMode ? @"набранное остаётся" : @"набранное сброшено");
    }

    // Перед первым запросом правим `n` в адресе — сервер ждёт его преобразованным.
    if (!_fixed) {
        _url = [[[YTNSig shared] fixUrl:_url] copy];
        _fixed = YES;
    }

    /**
     * Метка показа в адресе — ею сервер связывает просьбы в один просмотр.
     *
     * В дампе youtube.com/tv `cpn` стоит в каждом обращении за видео и
     * держится одним на весь показ. У нас его не было вовсе — ни разу, ни
     * в одном запросе, — то есть каждая просьба приходила от неизвестно
     * кого. Ему неоткуда было знать, что это продолжение того же показа.
     *
     * `cver` там же и берётся оттуда же: версия TV-клиента, которой мы и
     * так представляемся в сведениях о себе.
     */
    // `alr=yes` стоит в каждом адресе у браузера; чему служит — не знаю.
    NSString *address = [NSString stringWithFormat:@"%@&alr=yes&cpn=%@&cver=%@&rn=%ld",
        _url,
        [YTApi playbackNonceForVideo:_videoId],
        [YTApi clientVersion:@"TVHTML5"],
        (long)_requestNumber];

    _requestNumber++;

    NSMutableURLRequest *request =
        YTRequest(address, NSURLRequestReloadIgnoringLocalCacheData, 30.0);

    if (request == nil) {
        return nil;
    }

    /**
     * Заголовки — по дампу yttv5. У браузера их два десятка, и среди них
     * нет `Content-Type`, а `Accept` — «всё»; есть `Origin` и `Referer`
     * на youtube.com и четвёрка `X-Browser-`. Мы слали свои
     * `application/x-protobuf` и `vnd.yt-ump`, которых у него нет.
     * Сжатие оставляем выключенным: ответ идёт потоком частей, и ему
     * нужен `identity`, — единственное намеренное отличие.
     */
    [request setHTTPMethod:@"POST"];
    [request setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [request setValue:[YTApi mediaUserAgent] forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"https://www.youtube.com" forHTTPHeaderField:@"Origin"];
    [request setValue:@"https://www.youtube.com/" forHTTPHeaderField:@"Referer"];
    [request setValue:@"stable" forHTTPHeaderField:@"X-Browser-Channel"];
    [request setValue:@"2026" forHTTPHeaderField:@"X-Browser-Year"];
    [request setValue:@"Copyright 2026 Google LLC. All Rights Reserved."
   forHTTPHeaderField:@"X-Browser-Copyright"];
    [request setHTTPShouldHandleCookies:NO];

    NSData *body = [self requestBodyFrom:startMs];

    [request setHTTPBody:body];

    /**
     * Слепок для повтора в браузере — один раз за сессию эфира.
     *
     * Просил человек: чтобы это же поведение можно было воспроизвести на
     * стенде. Для повтора нужны ровно две вещи — адрес подачи (в нём и
     * `n`, и подпись, и срок) и тело запроса целиком, потому что в теле
     * лежат настройки ustreamer (поле 5), сведения о клиенте TVHTML5
     * (поле 19.1) и PO-токен сеанса (поле 19.2.6). Тело пишем как есть,
     * base64: расшифрованный дамп рядом уже есть, а повторить можно
     * только точные байты.
     *
     * Осторожно: строки содержат токен сеанса и подписанный адрес. Они
     * годны считанные часы и привязаны к этому устройству, но в чужие
     * руки журнал с ними лучше не отдавать.
     */
    /**
     * Один слепок на запуск приложения, а не на каждую сессию.
     *
     * Признак был обычным полем, а подача у эфира сменяется по многу раз:
     * в журнале 62 слепок выписался тридцать шесть раз и занял под
     * полсотни килобайт. Для повтора довольно одного.
     */
    static BOOL replaySaid = NO;

    if (_liveMode && !replaySaid) {
        replaySaid = YES;

        NSLog(@"[YouTube/Повтор] Ролик %@, адрес подачи: %@",
              [self videoId], address);

        NSLog(@"[YouTube/Повтор] Тело запроса (%lu байт, base64): %@",
              (unsigned long)[body length],
              [self base64Of:body]);
    }

    /**
     * Слепок запроса — раз в минуту.
     *
     * У web-плеера запрос к тому же эфиру перехвачен и разобран по полям;
     * наш до сих пор был известен лишь по исходнику. Сравнивать надо
     * то, что ушло на самом деле.
     */
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    if (_liveMode && now - _requestSaidAt > 60.0) {
        _requestSaidAt = now;

        NSLog(@"[YouTube/Подача] Запрос (%lu байт): %@",
              (unsigned long)[body length], [self dumpProto:body depth:2]);
    }

    /**
     * Короткая строка о каждом живом запросе — для сверки с дампом.
     *
     * Полный слепок раз в минуту не даёт увидеть такт и то, что меняется
     * от просьбы к просьбе: место показа, перечень, печенье. Здесь всё это
     * в одну строку, как в таблице из дампа.
     */
    if (_liveMode) {
        NSMutableString *held = [NSMutableString string];

        for (NSArray *run in [self heldRuns:YES]) {
            [held appendFormat:@"%@%ld…%ld", [held length] ? @"," : @"",
                (long)[[run objectAtIndex:0] integerValue],
                (long)[[run objectAtIndex:1] integerValue]];
        }

        NSLog(@"[YouTube/Такт] rn=%ld 28=%lld 29=%lld печенье=%@ видео=%@ голова=%.0f",
              (long)_requestNumber - 1,
              (long long)(_askLiveNow ? YTLiveNow : MAX((int64_t)0, startMs)),
              (long long)_lastWatchedMs,
              _playbackCookie != nil ? @"да" : @"нет",
              [held length] ? held : @"—",
              _liveHeadSeconds);
    }

    return request;
}

/** Сеть — и только сеть: ничего общего здесь не трогается. */
- (YTHttpResponse *)perform:(NSMutableURLRequest *)request {
    NSTimeInterval startedAt = [NSDate timeIntervalSinceReferenceDate];

    YTHttpResponse *response = [YTHttp send:request bodyLimit:0 caching:NO];

    [YTPlaybackStats noteTransfer:[response.body length]
                          elapsed:[NSDate timeIntervalSinceReferenceDate] - startedAt
                            paced:_liveMode];

    return response;
}

- (BOOL)absorb:(YTHttpResponse *)response {
    if (![response isSuccessful] || [response.body length] == 0) {
        _failures++;

        NSLog(@"[YouTube/Подача] Запрос %ld не удался: код %ld, отказ подряд %ld",
              (long)_requestNumber - 1, (long)response.statusCode, (long)_failures);

        /**
         * Отказ два раза подряд — сессия подачи кончилась: адрес мёртв,
         * нового он не даст. Лечится тем же, чем и просьба сервера:
         * сходить в `/player` заново.
         */
        if (_failures >= 2 && !_needsReload) {
            _needsReload = YES;
            _reloadToken = nil;

            NSLog(@"[YouTube/Подача] Подача мертва — просим свежий ответ /player");
        }

        return NO;
    }

    _failures = 0;

    NSUInteger tail = 0;

    [YTUmp read:response.body remainder:&tail handler:^(YTUmpPart *part) {
        [self handlePart:part];
    }];

    NSLog(@"[YouTube/Подача] Части ответа: %@",
          [_seen length] > 0 ? _seen : @"пусто");

    [_seen setString:@""];

    NSLog(@"[YouTube/Подача] Ответ %lu КБ: видео %lu фрагментов, звук %lu, "
          @"заголовки %@/%@%@",
          (unsigned long)([response.body length] / 1024),
          (unsigned long)[_videoSegments count],
          (unsigned long)[_audioSegments count],
          _videoInit != nil ? @"есть" : @"нет",
          _audioInit != nil ? @"есть" : @"нет",
          tail > 0 ? @", хвост не разобран" : @"");

    return ([_videoSegments count] > 0 || _videoInit != nil);
}

- (NSUInteger)delivered {
    return _delivered;
}

/** Сколько кусков пришло всего, считая повторы: признак жизни подачи. */
- (NSUInteger)received {
    return _received;
}

#pragma mark Забранное

- (NSData *)videoInit { return _videoInit; }

- (NSInteger)videoInitItag { return _videoInitItag; }
- (NSData *)audioInit { return _audioInit; }

- (NSData *)videoSegment:(NSInteger)sequence {
    id body = [_videoSegments objectForKey:[NSNumber numberWithInteger:sequence]];

    return [body isKindOfClass:[NSData class]] ? body : nil;
}

- (NSData *)audioSegment:(NSInteger)sequence {
    id body = [_audioSegments objectForKey:[NSNumber numberWithInteger:sequence]];

    return [body isKindOfClass:[NSData class]] ? body : nil;
}

/**
 * Обычная длина куска этой дорожки, мс.
 *
 * Нужна там, где длина последнего куска ещё не известна: у эфира сервер
 * её не присылает вовсе, а вычисляется она по расстоянию до следующего
 * куска — которого в этот миг ещё нет. Берём среднее по известным;
 * не известно ничего — отвечаем привычным: пять секунд у видео, десять
 * у звука.
 */
- (int64_t)typicalSpanMs:(BOOL)isVideo {
    NSDictionary *times = isVideo ? _videoTimes : _audioTimes;

    int64_t sum = 0;
    NSInteger count = 0;

    for (NSArray *pair in [times allValues]) {
        if ([pair count] >= 2) {
            int64_t span = [[pair objectAtIndex:1] longLongValue];

            if (span > 0) {
                sum += span;
                count++;
            }
        }
    }

    if (count > 0) {
        return sum / count;
    }

    return isVideo ? 5000 : 10000;
}

/**
 * Докуда просить дальше по этой дорожке.
 *
 * Конец последнего ряда — а если длина последнего куска ещё неизвестна
 * (у эфира её вычисляют по следующему куску, которого пока нет), то его
 * начало плюс обычная длина. Иначе выйдет просьба о том, что уже
 * набрано, и сервер правомерно ответит пустотой.
 */
- (NSTimeInterval)needAfter:(BOOL)isVideo {
    NSArray *runs = [self heldRuns:isVideo];

    if ([runs count] == 0) {
        return 0;
    }

    /**
     * У эфира берём последний ряд — ближний к краю; первый остался бы
     * в прошлом, и просьба, отмеренная от него, целила бы в набранное.
     *
     * Дыру просить бесполезно — это проверено. Сервер, замолчав, потом
     * отдаёт не пропущенное, а своё нынешнее место: в журнале после
     * молчания за 350067 пришёл сразу 350072. Значит пропущенных кусков
     * нам не дадут никогда, и целить в них — значит стоять вечно.
     * Дыру переступает плейлист, объявляя разрыв, а подача тянет хвост.
     */
    NSArray *held = _liveMode ? [runs lastObject] : [runs objectAtIndex:0];

    int64_t end = [[held objectAtIndex:3] longLongValue];
    int64_t tail = [[held objectAtIndex:4] longLongValue];

    if (end <= tail) {
        return (tail + [self typicalSpanMs:isVideo]) / 1000.0;
    }

    return end / 1000.0;
}

/**
 * Докуда сервер вообще отдаёт, в секундах. Ноль — пока не знаем.
 */
- (int64_t)liveHeadSequence {
    return _liveHeadSequence;
}

- (void)setLiveStartHint:(NSTimeInterval)seconds {
    _liveStartHint = seconds;
}

/**
 * base64 своими руками: `base64EncodedStringWithOptions:` появился в iOS 7,
 * а мы держим 5.1.
 */
- (NSString *)base64Of:(NSData *)data {
    static const char *alphabet =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    const uint8_t *bytes = (const uint8_t *)[data bytes];
    NSUInteger length = [data length];

    NSMutableString *out = [NSMutableString stringWithCapacity:(length + 2) / 3 * 4];

    for (NSUInteger at = 0; at < length; at += 3) {
        NSUInteger left = length - at;
        uint32_t block = (uint32_t)bytes[at] << 16;

        if (left > 1) {
            block |= (uint32_t)bytes[at + 1] << 8;
        }

        if (left > 2) {
            block |= (uint32_t)bytes[at + 2];
        }

        [out appendFormat:@"%c%c%c%c",
            alphabet[(block >> 18) & 0x3f],
            alphabet[(block >> 12) & 0x3f],
            (left > 1) ? alphabet[(block >> 6) & 0x3f] : '=',
            (left > 2) ? alphabet[block & 0x3f] : '='];
    }

    return out;
}

- (NSTimeInterval)liveLimitSeconds {
    return _liveSeekSeconds;
}

/**
 * Докуда набрано видео, в секундах. Это и есть честное мерило хода.
 *
 * Брать для этого `liveNextTime` нельзя, и на этом я уже споткнулся
 * в 1.4-92: в нём сидит переступ дыры, который сам уходит к краю, и
 * «ход» выглядел ровным как раз тогда, когда не приходило ничего. В
 * журнале 44 сторож поэтому не сработал ни разу.
 */
/** Сколько секунд прошло с тех пор, как предел отдачи нам назвали. */
- (NSTimeInterval)liveLimitSeenAgo {
    if (_liveSeekSeenAt <= 0) {
        return 0;
    }

    return MAX(0.0, [NSDate timeIntervalSinceReferenceDate] - _liveSeekSeenAt);
}

/** Обычная длина куска эфира, в секундах. */
- (NSTimeInterval)typicalLiveSpan {
    NSTimeInterval span = [self typicalSpanMs:YES] / 1000.0;

    return (span > 0.5) ? span : 5.0;
}

- (NSTimeInterval)liveFilledSeconds {
    return _videoFilledMs > 0 ? (NSTimeInterval)_videoFilledMs / 1000.0 : 0.0;
}

/**
 * Сервер сейчас отказывает — и ломиться к нему бесполезно.
 *
 * Раз в шесть минут подача на минуту с лишним перестаёт отдавать что бы
 * то ни было: журнал 38, 04:35:39 — 04:37:01. Сперва сервер отматывает
 * нас назад (четыре раза присылает кусок №3140102, который у нас уже
 * есть), потом молчит, а часть №69 всё это время называет кусок
 * №3140106 — тот самый, что нам нужен, — и не присылает его. Куски с
 * 3140106 по 3140117 не пришли вовсе, ни одного за шестьдесят секунд.
 *
 * Отказ **не** в нашем положении: время плеера всё это время честно
 * стояло на 4–9 с ниже предела отдачи. И не в дорожке: часть №69
 * приходит дважды, по одной на видео и на звук, и звук замолкает
 * вместе с картинкой. Значит отказывают сессии целиком, а не формату.
 *
 * Кончился отказ сам: сервер прислал часть №45 (перескок) и сразу за
 * ней кусок №3140118. Ни мягкие перезапуски сессии, ни жёсткие
 * перезапуски потока его не ускорили — в журнале их пять, и все впустую.
 * А вреда от них довольно: каждый жёсткий тянет заново `/player`, и
 * показ теряет набранное. Потому, пока отказ длится, сидим тихо и ждём
 * перескока — лишь бы сессия была жива, когда он придёт.
 */
- (BOOL)liveServerRefusing {
    if (!_liveMode || _liveRefusedSince <= 0) {
        return NO;
    }

    // Дольше двух минут это уже не «окно», а настоящая беда — лечим как прежде.
    return [NSDate timeIntervalSinceReferenceDate] - _liveRefusedSince < 120.0;
}

- (NSTimeInterval)liveNextTime {
    NSTimeInterval video = [self needAfter:YES];
    NSTimeInterval audio = [self needAfter:NO];

    NSTimeInterval next;

    if (video <= 0) {
        next = audio;
    } else if (audio <= 0) {
        next = video;
    } else {
        // По отставшей дорожке: обогнав её, мы оставили бы её без продолжения.
        next = MIN(video, audio);
    }


    /**
     * За край не просим — там нам отвечают отказом и запоминают его.
     *
     * Журнал 81, 09:55:04: «просим с 15805670 с, край 15805665 с». Кусок
     * ещё не нарезан, и сервер отвечает пустотой с частью №69. Дальше он
     * держит нас ровно в этой точке: край уходит на 15805675, 15805685,
     * 15805700 — а указание всё то же, «продолжи с №3161218». Двадцать
     * секунд запас тает до нуля, и вытаскивает нас только случайность.
     *
     * До 1.4-152 этого не случалось: отступ в сто двадцать секунд держал
     * нас позади, и просьба всегда попадала в нарезанное. Убрав отступ,
     * мы встали вплотную к краю — и стали перешагивать его на один кусок.
     *
     * Браузер за край не просит никогда: поле 28 у него — место **показа**,
     * оно всегда позади набранного (в дампе на 2–66 секунд), а что слать
     * дальше, сервер решает сам по перечню набранного. Поэтому просьбу
     * ограничиваем пределом отдачи: нечего просить — подождём такт.
     */
    NSTimeInterval servable = _liveSeekSeconds > 0
        ? _liveSeekSeconds : _liveHeadSeconds;

    if (servable > 0 && next > servable) {
        next = servable;
    }

    /**
     * Край ушёл далеко — пропущенное не выпрашиваем.
     *
     * Журнал 03:11:38 — 03:12:48: кусок №3139097 не пришёл, и мы просили
     * его шестьдесят семь секунд. Сервер на это отвечал частью №69, где
     * сам называл застрявший номер: `9=3139097` при своём текущем
     * `3=3139108`. То есть он знал, чего мы ждём, и отдавать это
     * не собирался — у эфира пропущенного не отдают никогда, край живёт
     * своей жизнью. Ни мягкий перезапуск сессии, ни новая сессия с
     * новым адресом этого не лечили: пока мы целили в дыру, ответ был
     * пуст. Помогло только то, что целью стал край.
     *
     * Потому: отстав от края больше чем на три куска, дыру переступаем
     * и просим рядом с краем. Показу это ничем не грозит — прокси ведёт
     * **свою** ось времени (`liveStartFor:span:`: часы идут на длину
     * выданного куска, а не на номер источника), и пропуск в нумерации
     * источника для плеера невидим: следующий выданный кусок просто
     * займёт следующее место на оси.
     *
     * Десять секунд позади края, а не сам край: там кусок уже нарезан,
     * и это ровно то окно, в котором сервер отдаёт (проба со стенда:
     * до края и до +8 с за ним — отдаёт, +20 с — пустой ответ).
     */
    /**
     * Указание сервера — только когда он просит **отступить**.
     *
     * Журнал 36 показал, что поле `1.1.9` чаще всего называет просто
     * следующий нужный нам кусок: «продолжить с №3139746» при нашем же
     * `next` ровно там. Слушаться такого указания буквально — значит
     * прибить просьбу к одному числу: пока этот кусок не придёт, мы
     * никуда не сдвинемся, а переступ дыры окажется отключён, потому
     * что до него дело не дойдёт. Именно так и вышло.
     *
     * Польза от указания была в журнале 35, где сервер просил уйти на
     * семьдесят секунд назад. Вот этот случай и берём: слушаемся, когда
     * он просит отступить заметно назад, и не даём указанию жить дольше
     * двадцати секунд без единого куска — иначе оно само станет ловушкой.
     */
    /**
     * Указание из части №69 больше не выполняем — оно пустое.
     *
     * Журнал 40, 05:06:39: сервер велел продолжить с куска №3140466, мы
     * попросили **ровно** там (`просим с 15701910 с`) — и получили
     * «Ответ 0 КБ» подряд, раз за разом, пока он повторял то же самое
     * указание. То же в журнале 38. Значит поле 1.1.9 называет место, а
     * отдавать с него сервер всё равно не собирается; слушаться его —
     * значит прибить просьбу к мёртвой точке и потерять те секунды, за
     * которые можно было бы двигаться. В журнал по-прежнему пишем: как
     * примета состояния сервера оно полезно.
     */

    /**
     * Переступ — только когда куски и правда перестали идти.
     *
     * Прежде он срабатывал по одному расстоянию до края, а теперь мы
     * **нарочно** держимся в минуте позади: по старому правилу переступ
     * тут же утащил бы нас к краю и отнял весь запас. Значит мерило
     * другое — давно ли приходил кусок.
     */
    BOOL stale = (_lastDeliveryAt <= 0)
        || ([NSDate timeIntervalSinceReferenceDate] - _lastDeliveryAt > 15.0);

    if (_liveMode && stale && next > 0 && _liveHeadSeconds > next + 15.0) {
        /**
         * Целим под предел отдачи, а не в голову.
         *
         * Голова (поле 4) на десять секунд выше предела (поля 14/15),
         * и прежний `голова − 10` попадал ровно на границу, где кусок
         * ещё не дорезан. Берём предел и отступаем от него десять
         * секунд: и кусок там уже есть, и плееру достаётся запас.
         */
        NSTimeInterval limit = _liveSeekSeconds > 0
            ? _liveSeekSeconds : (_liveHeadSeconds - 10.0);

        /**
         * Переступаем дыру на три куска, а не прыгаем к краю.
         *
         * Вот отчего запас, однажды просев, уже не поднимался. Подача у
         * края идёт ровно в скорость нарезки: четыре куска на двадцать
         * секунд, ни одного лишнего (журнал 46, и так все четыре минуты).
         * Значит набрать запас можно только из уже нарезанного — из того,
         * что лежит между нами и краем. Это единственный запас впрок,
         * какой у нас бывает.
         *
         * А прежний переступ прыгал сразу к краю минус десять — и всё
         * это нарезанное выбрасывал. Семнадцать раз за четыре минуты
         * (тот же журнал): каждая дыра не только стоила нам своих пяти
         * секунд, но и отнимала возможность нагнать, пришпиливая нас к
         * краю, где нагонять нечем.
         *
         * Теперь шагаем ровно через дыру — три куска вперёд. Если за ней
         * пусто, переступ позовут снова, и он шагнёт ещё; а всё, что
         * лежит дальше, останется нам на восстановление запаса, и
         * возьмём мы его пачкой, быстрее реального времени.
         */
        /**
         * Шагаем от прошлого переступа, а не от застрявшего места.
         *
         * Журнал 82 показал, чем это кончалось. Сервер восемьдесят восемь
         * секунд называл один и тот же кусок №3161362, а переступ
         * сработал четырежды — 10:07:25, :31, :37, :42 — и встал.
         * Причина в счёте: шаг брался от `next`, то есть от той самой
         * мёртвой точки, которая не двигается. Первый раз он давал
         * `next + 15`, а дальше — ровно то же число, и мы стояли на нём
         * до конца. Поток ожил сам в 10:08:46, на куске №3161374 — через
         * двенадцать кусков после застрявшего; то есть выйти нужно было
         * просто дальше, а мы перестали идти.
         *
         * Теперь каждый пропуск сдвигает нас ещё на пятнадцать секунд от
         * прошлого переступа. Дыра любой длины перешагивается за
         * несколько тактов, а не по счастливой случайности.
         */
        NSTimeInterval from = MAX(next, _liveSkippedTo);

        /**
         * Отстали далеко — идём к краю сразу, а не по пятнадцать секунд.
         *
         * Журнал 87 показал выход из тупика с точностью до секунды. Дыра
         * на куске №3167342, край ушёл на сто секунд, и вытащил нас
         * именно переступ: в 18:27:07 шаг, в 18:27:12 ещё шаг, в 18:27:15
         * пошли данные. Всё верно — только до этих двух шагов мы
         * добирались девяносто одну секунду, шагая по пятнадцать при
         * отставании в сотню.
         *
         * Шаг по пятнадцать имеет смысл, пока за дырой лежит нужное нам
         * продолжение: его мы и подбираем. Но когда край впереди больше
         * чем на минуту, подбирать нечего — показ всё равно туда не
         * дотянется, а отступ мы отменили ещё в 1.4-152. Значит нужно
         * сразу к пределу отдачи, откуда сервер и начнёт кормить.
         */
        NSTimeInterval edge = (_liveHeadSeconds - from > 60.0)
            ? MAX(0.0, limit - 10.0)
            : MIN(from + 15.0, MAX(0.0, limit - 10.0));

        if (edge > next) {
            if (_liveSkippedTo < edge) {
                _liveSkippedTo = edge;

                NSLog(@"[YouTube/Подача] Эфир: край ушёл на %.0f с вперёд — "
                      @"пропущенное не ждём, просим с %.0f с",
                      _liveHeadSeconds - next, edge);
            }

            return edge;
        }
    }

    return next;
}

- (BOOL)requestMoreFrom:(NSTimeInterval)playerTime {
    /**
     * Считаем пришедшее, а не размер хранилища.
     *
     * По размеру выходила ложь: старое вытесняется по мере показа, и на
     * пришедший фрагмент размер оставался прежним — качалка слышала
     * «подача не дала» там, где дала, и укладывалась спать на все пять
     * секунд, которые просит сервер. А кусок эфира живёт как раз пять
     * секунд: пока мы спали, следующий успевал уйти безвозвратно.
     * В журнале это ровные пропуски через один: 360680, 360682, 360684.
     *
     * Ровно так же считает и Android-версия.
     */
    NSUInteger before = _delivered;

    [self sendVideo:_video audio:_audio fromMs:(int64_t)(playerTime * 1000.0)];

    return _delivered > before;
}

- (NSString *)reloadToken {
    return _needsReload ? _reloadToken : nil;
}

/** Время из запомненного: 0 — начало, 1 — длительность. */
- (NSTimeInterval)timeIn:(NSDictionary *)times
                sequence:(NSInteger)sequence
                    part:(NSUInteger)part {
    NSArray *pair = [times objectForKey:[NSNumber numberWithInteger:sequence]];

    if ([pair count] <= part) {
        return 0;
    }

    return [[pair objectAtIndex:part] longLongValue] / 1000.0;
}

- (NSTimeInterval)videoSegmentStart:(NSInteger)sequence {
    return [self timeIn:_videoTimes sequence:sequence part:0];
}

- (NSTimeInterval)videoSegmentDuration:(NSInteger)sequence {
    return [self timeIn:_videoTimes sequence:sequence part:1];
}

- (NSTimeInterval)audioSegmentStart:(NSInteger)sequence {
    return [self timeIn:_audioTimes sequence:sequence part:0];
}

- (NSTimeInterval)audioSegmentDuration:(NSInteger)sequence {
    return [self timeIn:_audioTimes sequence:sequence part:1];
}

- (NSArray *)audioSequences {
    return [[_audioSegments allKeys] sortedArrayUsingSelector:@selector(compare:)];
}

- (NSArray *)videoSequences {
    return [[_videoSegments allKeys] sortedArrayUsingSelector:@selector(compare:)];
}

- (int64_t)backoffMs {
    return _backoffMs;
}

- (NSTimeInterval)backoff {
    // Потолок — полторы секунды: дольше ждать нет смысла, у плеера
    // свой сторож, а сервер обычно просит десятые доли.
    return MIN(1.5, MAX(0.0, (double)_backoffMs / 1000.0));
}

/** Счётчики набранного — к началу отрезка. */
- (void)resetCounters:(int64_t)startMs {
    /**
     * Начало перечня эфира **не** сбрасываем.
     *
     * Перечень набранного — это заявление о том, что у нас есть, и оно
     * остаётся правдой после любого перезапуска сессии: куски никуда
     * не делись. Сбрасывая его, мы каждый раз начинали перечень с двух
     * последних кусков, и всё, что старше, для сервера пропадало —
     * а он отдаёт строго то, чего нет в перечне, начиная с позиции
     * плеера. Отсюда и повторы. У браузера перечень тянется на минуты.
     */
    if (!_liveMode) {
        _liveSeenSeq = 0;
        _liveSeenMs = 0;
    }

    _firstVideoSeq = 0;
    _firstAudioSeq = 0;
    _lastVideoSeq = 0;
    _lastAudioSeq = 0;

    /**
     * У эфира отметку набранного назад не двигаем.
     *
     * По той же причине, что и начало перечня: куски от смены сессии
     * никуда не делись, и отметка «докуда набрано» остаётся правдой.
     * А сбрасывая её на место новой просьбы, мы эту правду теряли — и
     * получался круг, который и съедал запас.
     *
     * Журнал 49 показал его в числах. Три минуты всё шло ровно: буфер
     * 50-54 с, отставание −5 с. Потом, с 08:12:08, набранное начало
     * болтаться туда-сюда: 15713080 → 15713035 → 15713075 → 15713017 →
     * 15713075, то есть откатываться на сорок пять и пятьдесят восемь
     * секунд и возвращаться. Каждый откат — это `resetCounters:` от
     * очередной пересадки. А сторож мерит отставание как раз по этой
     * отметке: она падает — он видит отставание в девяносто секунд,
     * пересаживает снова, отметка падает снова. Круг сам себя кормит, и
     * буфер под ним стекает с пятидесяти двух до нуля за минуту.
     *
     * Берём наибольшее: вперёд отметка идти может, назад — нет.
     */
    if (_liveMode) {
        _videoFilledMs = MAX(_videoFilledMs, startMs);
        _audioFilledMs = MAX(_audioFilledMs, startMs);
    } else {
        _videoFilledMs = startMs;
        _audioFilledMs = startMs;
    }

    _rangeStartMs = startMs;
}

/** То же, но без выбрасывания времён: они пригодятся для отсчёта. */
- (void)resetRunFrom:(int64_t)startMs {
    [self resetCounters:startMs];
}

- (void)rewindTo:(NSTimeInterval)seconds {
    [self resetRunFrom:(int64_t)(seconds * 1000.0)];

    NSLog(@"[YouTube/Подача] Возврат на %.0f с — перечень набранного очищен", seconds);
}

- (NSTimeInterval)startForSequence:(NSInteger)sequence average:(NSTimeInterval)average {
    NSTimeInterval known = [self videoSegmentStart:sequence];

    if (known > 0 || sequence == 1) {
        return known;
    }

    /**
     * Ближайший известный кусок перед нужным — но только **ближайший**.
     *
     * Оглядываться дальше нескольких кусков нельзя, и это стоило
     * бесконечной закачки. После перемотки набранным остаётся начало
     * ролика; поиск доходил до него, возвращал время конца набранного —
     * секунд триста при цели в тысячу, — сервер послушно слал кусок
     * оттуда, а нужного всё не было. Каждая попытка отодвигала край
     * на один кусок вперёд, по четыре мегабайта, и так до тех пор,
     * пока памяти не оставалось вовсе.
     *
     * Далёкий сосед всё равно ничего не подсказывает: между ним и нами
     * сотни кусков, и сумма их длин известна не лучше, чем по средней.
     */
    for (NSInteger back = 1; back <= 8; back++) {
        NSInteger n = sequence - back;

        if (n < 1) {
            break;
        }

        NSTimeInterval start = [self videoSegmentStart:n];
        NSTimeInterval length = [self videoSegmentDuration:n];

        if (length > 0) {
            return start + length + (NSTimeInterval)(back - 1) * average;
        }
    }

    return (NSTimeInterval)(sequence - 1) * average;
}

/** Оставляет в хранилище лишь последние по номеру фрагменты. */
- (void)capStorage:(NSMutableDictionary *)storage keep:(NSUInteger)keep {
    if ([storage count] <= keep) {
        return;
    }

    NSArray *keys = [[storage allKeys] sortedArrayUsingSelector:@selector(compare:)];

    NSUInteger extra = [keys count] - keep;

    [storage removeObjectsForKeys:
        [keys subarrayWithRange:NSMakeRange(0, extra)]];
}

- (void)forgetBefore:(NSTimeInterval)seconds {
    [self forget:_videoSegments times:_videoTimes before:seconds];
    [self forget:_audioSegments times:_audioTimes before:seconds];
}

/** Выбрасывает из хранилища всё, что кончилось раньше указанного мига. */
- (void)forget:(NSMutableDictionary *)storage
         times:(NSDictionary *)times
        before:(NSTimeInterval)seconds {
    NSMutableArray *gone = [NSMutableArray array];

    /**
     * Перебираем снимок ключей, а не сам словарь.
     *
     * Здесь и было падение из отчёта за 18:09:55. Чистку зовёт поток
     * раздачи после сборки куска, а куски в тот же словарь кладёт поток
     * подачи — и быстрый перебор `for (key in storage)` встречает
     * изменение под собой. CoreFoundation на это бросает исключение, а
     * ловить его некому: поток падает и уносит приложение.
     *
     * Гонка была и раньше, но столкновение выпадало редко. Правки
     * 1.4-154 и 1.4-158 добавили к тем же словарям ещё двух читателей на
     * каждый запрос — и редкое стало частым.
     */
    NSArray *stored;

    @synchronized (self) {
        stored = [storage allKeys];
    }

    for (NSNumber *key in stored) {
        NSArray *pair = [times objectForKey:key];

        if ([pair count] < 2) {
            continue;
        }

        NSTimeInterval end = ([[pair objectAtIndex:0] longLongValue] +
                              [[pair objectAtIndex:1] longLongValue]) / 1000.0;

        if (end < seconds) {
            [gone addObject:key];
        }
    }

    @synchronized (self) {
        [storage removeObjectsForKeys:gone];
    }
}

- (NSTimeInterval)bufferedSeconds {
    return (NSTimeInterval)_videoFilledMs / 1000.0;
}

- (NSInteger)videoSegmentCount { return _videoSegmentCount; }
- (NSTimeInterval)duration { return _duration; }

@end
