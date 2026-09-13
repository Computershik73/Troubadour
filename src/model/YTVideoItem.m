#import "YTVideoItem.h"

#import "YTJson.h"
#import "YTSettings.h"

/**
 * Имена рендереров, за которыми стоит ролик. Порт `VideoRendererMarkers`.
 *
 * `reelItemRenderer` и `shortsLockupViewModel` в списке **намеренно
 * отсутствуют**, хотя в оригинале они есть. Там этот набор общий на все
 * поверхности, а Shorts разложены по своим — у поиска в UWP отдельные
 * вкладки «Видео», Shorts, «Плейлисты» и «Каналы». Здесь же разбор один
 * на всех, и с ними в обычную выдачу попадали вертикальные карточки
 * без длительности: в ответе поиска их два с половиной десятка.
 *
 * Когда появится раздел Shorts, он будет разбирать их сам — своим
 * списком имён.
 */
static NSArray *YTVideoRendererNames(void) {
    static NSArray *names = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        names = [[NSArray alloc] initWithObjects:
            @"videoRenderer",
            @"gridVideoRenderer",
            @"compactVideoRenderer",
            @"playlistVideoRenderer",
            @"playlistPanelVideoRenderer",
            @"lockupViewModel",
            @"tileRenderer",
            nil];
    });

    return names;
}

/**
 * Идентификатор подборки узнаётся по началу — так же, как в UWP-версии
 * (`ParsePlaylistLockupViewModel`, где проверяются PL/VL/LL/WL). Сюда
 * добавлены миксы `RD…`, которых в ленте и поиске больше всего, и `UL…`
 * с `OLA…`, которыми размечены подборки YouTube Music.
 */
static BOOL YTLooksLikePlaylistId(NSString *identifier) {
    static NSArray *prefixes = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        prefixes = [[NSArray alloc] initWithObjects:
            @"RD", @"PL", @"VL", @"LL", @"WL", @"UL", @"OLA", @"FL", nil];
    });

    if ([identifier length] < 10) {
        return NO;
    }

    for (NSString *prefix in prefixes) {
        if ([identifier hasPrefix:prefix]) {
            return YES;
        }
    }

    return NO;
}


/**
 * Превью у `lockupViewModel` — по известному пути, а не поиском по имени.
 *
 * Ключ `image` в такой карточке не один: свои есть у значка «ещё»,
 * у листа с действиями, у наложений. Общий поиск брал первый попавшийся,
 * а порядок ключей в разборе JSON не обещан — у подборок в выдаче поиска
 * он и брал не то, и превью не показывалось вовсе.
 *
 * Ролик держит его в `contentImage.thumbnailViewModel`, подборка —
 * в `contentImage.collectionThumbnailViewModel.primaryThumbnail`
 * (стопка обложек, первая из которых и есть превью).
 */
static NSString *YTLockupThumbnail(NSDictionary *renderer, NSInteger minWidth) {
    NSDictionary *content = [YTJson objectIn:renderer key:@"contentImage"];

    if (content == nil) {
        return nil;
    }

    NSDictionary *view = [YTJson objectIn:content key:@"thumbnailViewModel"];

    if (view == nil) {
        NSDictionary *stack = [YTJson objectIn:content key:@"collectionThumbnailViewModel"];

        view = [YTJson objectIn:[YTJson objectIn:stack key:@"primaryThumbnail"]
                            key:@"thumbnailViewModel"];
    }

    if (view == nil) {
        return nil;
    }

    return [YTJson thumbnailIn:[YTJson objectIn:view key:@"image"]
                           key:@"sources"
                      minWidth:minWidth];
}


/**
 * Пункт строки метаданных у новых view-model — порт `ExtractLockupMetadataPart`.
 *
 * Раскладка, как её читает и оригинал:
 *     строка 0, пункт 0 — автор;
 *     строка 1, пункт 0 — просмотры, пункт 1 — давность.
 */
/** Сколько строк метаданных у карточки: по ним видно, что в них лежит. */
static NSUInteger YTLockupMetadataRows(NSDictionary *renderer) {
    NSDictionary *holder = [YTJson findFirst:@"contentMetadataViewModel"
                                          in:renderer limit:600];

    return [[YTJson arrayIn:holder key:@"metadataRows"] count];
}

/**
 * В какой строке метаданных лежит имя канала — и какое оно.
 *
 * Считать строки для этого нельзя, и это выяснилось дважды. На ленте
 * строк две (автор, затем числа), на странице канала одна — и в ней
 * не автор, а просмотры. Отсюда взялось правило «автор есть, только
 * если строк две». В истории же строка **одна, и в ней как раз автор**:
 * даты просмотренному ролику YouTube не показывает. По прежнему правилу
 * автор там терялся целиком, а в просмотры попадало его же имя.
 *
 * Поэтому смотрим не на число строк, а на то, что в них: **имя канала
 * ведёт на канал.** У пункта с автором внутри лежит переход
 * `browseEndpoint` на `UC…`; у просмотров и давности ссылки нет никакой.
 * Признак не зависит ни от языка, ни от числа строк.
 *
 * Возвращает номер строки либо -1, а имя кладёт в `name`.
 */
static NSInteger YTLockupAuthorRow(NSDictionary *renderer, NSString **name) {
    NSDictionary *holder = [YTJson findFirst:@"contentMetadataViewModel"
                                          in:renderer limit:600];

    NSArray *rows = [YTJson arrayIn:holder key:@"metadataRows"];

    for (NSUInteger row = 0; row < [rows count]; row++) {
        NSArray *parts = [YTJson arrayIn:[YTJson objectAt:rows index:row]
                                     key:@"metadataParts"];

        for (NSUInteger index = 0; index < [parts count]; index++) {
            NSDictionary *part = [YTJson objectAt:parts index:index];

            NSDictionary *browse = [YTJson findFirst:@"browseEndpoint"
                                                  in:part limit:200];

            NSString *browseId = [YTJson textIn:browse key:@"browseId"];

            if (![browseId hasPrefix:@"UC"]) {
                continue;
            }

            NSString *text = [YTJson renderedText:part key:@"text"];

            if ([text length] == 0) {
                continue;
            }

            if (name != NULL) { *name = text; }

            return (NSInteger)row;
        }
    }

    return -1;
}

static NSString *YTLockupMetadataPart(NSDictionary *renderer,
                                      NSUInteger row, NSUInteger part) {
    NSDictionary *holder = [YTJson findFirst:@"contentMetadataViewModel"
                                          in:renderer limit:600];

    NSArray *rows = [YTJson arrayIn:holder key:@"metadataRows"];

    if (row >= [rows count]) {
        return nil;
    }

    NSArray *parts = [YTJson arrayIn:[YTJson objectAt:rows index:row] key:@"metadataParts"];

    if (part >= [parts count]) {
        return nil;
    }

    return [YTJson renderedText:[YTJson objectAt:parts index:part] key:@"text"];
}

NSString *YTTileLineText(NSDictionary *line, NSInteger index) {
    NSArray *items = [YTJson arrayIn:[YTJson objectIn:line key:@"lineRenderer"] key:@"items"];

    NSInteger count = (NSInteger)[items count];
    NSInteger resolved = index < 0 ? count + index : index;

    if (resolved < 0 || resolved >= count) {
        return nil;
    }

    NSDictionary *item = [YTJson objectAt:items index:(NSUInteger)resolved];

    return [YTJson renderedText:[YTJson objectIn:item key:@"lineItemRenderer"] key:@"text"];
}

@implementation YTVideoItem

/**
 * Доля просмотра по умолчанию — минус один, «сервер не сказал».
 *
 * Ноль здесь был бы утверждением «ролик не начинали», и карточка не
 * смогла бы отличить его от молчания сервера — а значит не заглянула бы
 * в свою запись.
 */
- (id)init {
    self = [super init];

    if (self != nil) {
        _watchedShare = -1;
    }

    return self;
}

- (BOOL)isPlaylist {
    return [_playlistId length] > 0 && [_videoId length] == 0;
}


/**
 * Эфир узнаётся по любому из значков, а не по одному.
 *
 * Раньше смотрелся только `thumbnailOverlayTimeStatusRenderer.style`,
 * и плашка появлялась у одних трансляций и не появлялась у других —
 * ровно потому, что разметка у ленты не одна. Старая ставит признак
 * в тот самый значок; классическая — в `badges` строкой вида
 * `BADGE_STYLE_TYPE_LIVE_NOW`; новая — в `thumbnailBadgeViewModel`,
 * где он зовётся `badgeStyle` либо именем значка.
 *
 * Ищем по всем трём и сравниваем по вхождению «LIVE»: точные строки
 * у этих разметок разные и со временем меняются, а слово стоит во всех.
 */
static BOOL YTMentionsLive(NSString *text) {
    return [text length] > 0
        && [text rangeOfString:@"LIVE"].location != NSNotFound;
}

/**
 * Докуда досмотрено — по слову сервера.
 *
 * Лежит в тех же `thumbnailOverlays`, что и значок длительности:
 * `thumbnailOverlayResumePlaybackRenderer.percentDurationWatched`,
 * целыми процентами. Я было решил, что TV-клиенту этого не присылают, и
 * завёл своё хранилище; дамп yttv6 показал обратное. Слову сервера
 * верим больше: оно знает и о просмотрах с других устройств.
 *
 * Минус один означает «не сказано» — это не ноль: ноль был бы
 * утверждением, что ролик не начинали.
 */
static double YTWatchedShareIn(id renderer) {
    NSDictionary *resume = [YTJson findFirst:@"thumbnailOverlayResumePlaybackRenderer"
                                          in:renderer limit:600];

    if (resume == nil) {
        return -1;
    }

    NSInteger percent = [YTJson intIn:resume key:@"percentDurationWatched"];

    if (percent <= 0) {
        return -1;
    }

    return MIN(1.0, (double)percent / 100.0);
}

/**
 * С какой секунды продолжать — по слову сервера.
 *
 * `watchEndpoint.startTimeSeconds`: дамп yttv7, плитка ролика
 * `cOEPwN4E3qo` со `startTimeSeconds: 1556` рядом с долей просмотра в
 * десять процентов. Своего хранилища для этого больше не нужно: сервер
 * знает и о просмотрах с других устройств, и о том, что ролик досмотрен.
 */
static NSTimeInterval YTResumeAtIn(id renderer) {
    NSDictionary *watch = [YTJson findFirst:@"watchEndpoint" in:renderer limit:600];

    return (NSTimeInterval)[YTJson intIn:watch key:@"startTimeSeconds"];
}

static BOOL YTRendererIsLive(id renderer, NSDictionary *badge) {
    if ([[YTJson textIn:badge key:@"style"] isEqualToString:@"LIVE"]) {
        return YES;
    }

    if (YTMentionsLive([YTJson textIn:[YTJson objectIn:badge key:@"icon"]
                                  key:@"iconType"])) {
        return YES;
    }

    NSArray *marks = [YTJson findAll:@"metadataBadgeRenderer"
                                  in:renderer limit:400];

    for (NSUInteger i = 0; i < [marks count]; i++) {
        if (YTMentionsLive([YTJson textIn:[marks objectAtIndex:i] key:@"style"])) {
            return YES;
        }
    }

    NSArray *models = [YTJson findAll:@"thumbnailBadgeViewModel"
                                   in:renderer limit:600];

    for (NSUInteger i = 0; i < [models count]; i++) {
        NSDictionary *model = [models objectAtIndex:i];

        if (YTMentionsLive([YTJson textIn:model key:@"badgeStyle"])
            || YTMentionsLive([YTJson findString:@"iconName" in:model limit:60])) {
            return YES;
        }
    }

    return NO;
}

- (NSString *)metadataLine {
    NSMutableArray *parts = [NSMutableArray array];

    if ([_channelTitle length] > 0) { [parts addObject:_channelTitle]; }
    if ([_viewCount length] > 0)    { [parts addObject:_viewCount]; }
    if ([_published length] > 0)    { [parts addObject:_published]; }

    return [parts componentsJoinedByString:@" • "];
}

/**
 * Плитка TV-клиента — порт `ParseTileRenderer`.
 *
 * Разбирается отдельно, а не общим ходом, потому что общего с остальными
 * рендерерами у неё почти ничего: ни `title`, ни `lengthText`, ни
 * `thumbnail` на своих местах нет. Именно этим и объяснялась «Главная»
 * из пустых карточек: лента у вошедшего приходит от TV-клиента, а он
 * присылает только плитки.
 *
 * Плитка ведёт либо на ролик (`watchEndpoint`), либо на микс
 * (`watchPlaylistEndpoint`) — и во втором случае в ней **тоже есть**
 * идентификатор ролика, с которого микс начинается. Карточка без него
 * не карточка: в оригинале такая плитка отбрасывается.
 */
+ (YTVideoItem *)fromTile:(NSDictionary *)tile {
    NSDictionary *onSelect = [YTJson objectIn:tile key:@"onSelectCommand"];
    NSDictionary *watch = [YTJson objectIn:onSelect key:@"watchEndpoint"];

    if (watch == nil) {
        watch = [YTJson objectIn:onSelect key:@"watchPlaylistEndpoint"];
    }

    NSString *videoId = [YTJson textIn:watch key:@"videoId"];

    if ([videoId length] != 11) {
        return nil;
    }

    YTVideoItem *item = [[YTVideoItem alloc] init];

    item.videoId = videoId;

    // Плитка TV-клиента ведёт на Shorts тем же `reelWatchEndpoint`.
    if ([YTJson findFirst:@"reelWatchEndpoint" in:tile limit:400] != nil) {
        item.isShort = YES;
    }

    /**
     * Идентификатор подборки сохраняется, но карточка остаётся карточкой
     * ролика: у микса он нужен, чтобы очередь пережила нажатие. `WL` и `LL`
     * отбрасываются — это «Посмотреть позже» и «Понравившиеся», личные
     * списки, а не подборка (`IsReservedPersonalPlaylistId`).
     */
    NSString *playlistId = [YTJson textIn:watch key:@"playlistId"];

    if (playlistId != nil
        && ![playlistId hasPrefix:@"WL"] && ![playlistId hasPrefix:@"LL"]) {
        item.playlistId = playlistId;
    }

    NSDictionary *metadata = [YTJson objectIn:[YTJson objectIn:tile key:@"metadata"]
                                          key:@"tileMetadataRenderer"];

    item.title = [YTJson renderedText:metadata key:@"title"] ?: @"";

    NSArray *lines = [YTJson arrayIn:metadata key:@"lines"];

    // lines[0] — автор; lines[1] — просмотры и давность, отсчитываемые
    // с конца, потому что число пунктов в ней разное.
    if ([lines count] > 0) {
        item.channelTitle = YTTileLineText([YTJson objectAt:lines index:0], 0);
    }

    if ([lines count] > 1) {
        NSDictionary *second = [YTJson objectAt:lines index:1];

        item.published = YTTileLineText(second, -1);
        item.viewCount = YTTileLineText(second, -3);
    }

    NSDictionary *header = [YTJson objectIn:[YTJson objectIn:tile key:@"header"]
                                        key:@"tileHeaderRenderer"];

    NSDictionary *badge = [YTJson findFirst:@"thumbnailOverlayTimeStatusRenderer"
                                         in:header limit:400];

    item.duration = [YTJson renderedText:badge key:@"text"];

    if (YTRendererIsLive(tile, badge)) {
        item.isLive = YES;
    }

    item.watchedShare = YTWatchedShareIn(tile);
    item.resumeAt = YTResumeAtIn(tile);

    NSDictionary *browse = [YTJson findFirst:@"browseEndpoint" in:tile limit:400];
    NSString *browseId = [YTJson textIn:browse key:@"browseId"];

    if ([browseId hasPrefix:@"UC"]) {
        item.channelId = browseId;
    }

    /**
     * Превью собирается из идентификатора, а не берётся из ответа, — так
     * же поступает `BuildMqThumbnailUrl` в оригинале. У плитки картинка
     * лежит в `tileHeaderRenderer`, но приходит подписанной и в WebP,
     * который ImageIO до iOS 14 не читает.
     */
    item.thumbnail = [NSString stringWithFormat:
        @"https://i.ytimg.com/vi/%@/hqdefault.jpg", videoId];

    item.channelThumbnail =
        [YTJson thumbnailIn:tile key:@"channelThumbnailSupportedRenderers" minWidth:88];

    if (item.channelThumbnail == nil) {
        item.channelThumbnail = [YTJson thumbnailIn:tile key:@"channelThumbnail" minWidth:88];
    }

    return item;
}

+ (YTVideoItem *)fromRenderer:(NSDictionary *)renderer {
    if (![renderer isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSString *videoId = [YTJson textIn:renderer key:@"videoId"];

    // `lockupViewModel` — новая форма: идентификатор лежит в contentId.
    if (videoId == nil) {
        videoId = [YTJson textIn:renderer key:@"contentId"];
    }

    // `tileRenderer` прячет его в onSelectCommand → watchEndpoint.
    if (videoId == nil) {
        NSDictionary *watch = [YTJson findFirst:@"watchEndpoint" in:renderer limit:400];
        videoId = [YTJson textIn:watch key:@"videoId"];
    }

    /**
     * Идентификатор ролика — ровно одиннадцать знаков; это не догадка,
     * а формат: одиннадцать символов из base64url, других длин не бывает.
     *
     * Всё, что длиннее, — подборка: `lockupViewModel` описывает миксы
     * и плейлисты теми же словами, что ролики, и кладёт в `contentId`
     * то `PLp9rb04py…`, то `RDQM…`. Раньше такие карточки просто
     * выбрасывались — иначе превью запрашивалось по несуществующему
     * адресу `i.ytimg.com/vi/PL…/hqdefault.jpg`, а нажатие открывало
     * пустой плеер. Теперь они остаются, но помечены как подборки
     * и открываются своим экраном.
     */
    NSString *playlistId = nil;

    if ([videoId length] != 11) {
        NSString *candidate = [YTJson textIn:renderer key:@"playlistId"];

        if (candidate == nil) {
            NSDictionary *watch = [YTJson findFirst:@"watchEndpoint" in:renderer limit:400];
            candidate = [YTJson textIn:watch key:@"playlistId"];
        }

        if (candidate == nil) {
            candidate = videoId;
        }

        /**
         * `VL` — это приставка, которой размечен запрос страницы плейлиста
         * (`browseId = "VL" + playlistId`), а не сам идентификатор. Снимаем
         * её, иначе в запрос ушло бы «VLVLPL…».
         */
        if ([candidate hasPrefix:@"VL"]) {
            candidate = [candidate substringFromIndex:2];
        }

        if (!YTLooksLikePlaylistId(candidate)) {
            return nil;
        }

        playlistId = candidate;
        videoId = nil;
    }

    YTVideoItem *item = [[YTVideoItem alloc] init];

    item.videoId = videoId;
    item.playlistId = playlistId;

    /**
     * Вертикальный ли это ролик — по тому, куда он ведёт.
     *
     * Признак надёжнее прочих: у Shorts переход описан `reelWatchEndpoint`,
     * а не `watchEndpoint`, и так у всех поверхностей разом. Судить
     * по отсутствию длительности нельзя — её нет и у прямых эфиров;
     * по пропорции превью тоже: она приходит не всегда.
     *
     * Помечаем даже там, где Shorts не прячут: карточке этот признак
     * нужен и сам по себе — у вертикального превью пропорция 9:16,
     * и в место под 16:9 оно вписывается иначе.
     */
    if ([YTJson findFirst:@"reelWatchEndpoint" in:renderer limit:400] != nil) {
        item.isShort = YES;
    }

    // Название: у разных рендереров оно то в `title`, то в `headline`,
    // то внутри `metadata` у новых view-model.
    NSString *title = [YTJson renderedText:renderer key:@"title"];

    if (title == nil) { title = [YTJson renderedText:renderer key:@"headline"]; }
    if (title == nil) { title = [YTJson textIn:renderer key:@"title"]; }

    if (title == nil) {
        NSDictionary *meta = [YTJson findFirst:@"lockupMetadataViewModel" in:renderer limit:400];
        title = [YTJson renderedText:meta key:@"title"];
    }

    item.title = title ?: @"";

    /**
     * Автор. `longBylineText` предпочтительнее `shortBylineText`: второй
     * у части рендереров содержит не имя канала, а число просмотров.
     * Порядок тот же, что в `ParseCompactVideoRenderer` UWP-версии.
     */
    NSString *channel = [YTJson renderedText:renderer key:@"longBylineText"];

    if (channel == nil) { channel = [YTJson renderedText:renderer key:@"shortBylineText"]; }
    if (channel == nil) { channel = [YTJson renderedText:renderer key:@"ownerText"]; }

    /**
     * Новая разметка: автора узнаём по ссылке на канал, а не по счёту строк.
     *
     * Подробности — над `YTLockupAuthorRow`. Коротко: имя канала ведёт
     * на канал, а просмотры и давность никуда не ведут, и этот признак
     * верен и на ленте, и на странице канала, и в истории.
     */
    NSString *linked = nil;

    NSInteger authorRow = YTLockupAuthorRow(renderer, &linked);

    if (channel == nil && [linked length] > 0) {
        channel = linked;
    }

    item.channelTitle = channel;

    // Идентификатор канала — в navigationEndpoint у имени автора.
    NSDictionary *browse = [YTJson findFirst:@"browseEndpoint" in:renderer limit:400];
    NSString *browseId = [YTJson textIn:browse key:@"browseId"];

    if ([browseId hasPrefix:@"UC"]) {
        item.channelId = browseId;
    }

    item.thumbnail = [YTJson thumbnailIn:renderer key:@"thumbnail" minWidth:480];

    if (item.thumbnail == nil) {
        item.thumbnail = YTLockupThumbnail(renderer, 480);
    }

    if (item.thumbnail == nil) {
        // У новых view-model превью лежит глубже, но всё так же под
        // ключом `thumbnails` — общий поиск его находит.
        NSDictionary *image = [YTJson findFirst:@"image" in:renderer limit:400];
        item.thumbnail = [YTJson thumbnailIn:image key:@"sources" minWidth:480];
    }

    if (item.thumbnail == nil && videoId != nil) {
        // Последний ход: у i.ytimg.com превью лежит по предсказуемому адресу.
        // Это не догадка — так же поступала UWP-версия в ParseCompactVideoRenderer.
        // Для подборки такого адреса нет: у неё превью только своё.
        item.thumbnail = [NSString stringWithFormat:
            @"https://i.ytimg.com/vi/%@/hqdefault.jpg", videoId];
    }

    item.channelThumbnail =
        [YTJson thumbnailIn:renderer key:@"channelThumbnailSupportedRenderers" minWidth:88];

    if (item.channelThumbnail == nil) {
        item.channelThumbnail = [YTJson thumbnailIn:renderer key:@"channelThumbnail" minWidth:88];
    }

    item.duration = [YTJson renderedText:renderer key:@"lengthText"];

    if (item.duration == nil) {
        item.duration = [YTJson renderedText:renderer key:@"thumbnailOverlayTimeStatusRenderer"];
    }

    /**
     * Эфир узнаётся по значку, а не по отсутствию длительности: у Shorts
     * длительности тоже нет, а эфиром они не являются.
     */
    NSDictionary *badge = [YTJson findFirst:@"thumbnailOverlayTimeStatusRenderer"
                                         in:renderer limit:400];

    if (YTRendererIsLive(renderer, badge)) {
        item.isLive = YES;
        item.duration = @"LIVE";
    }

    item.watchedShare = YTWatchedShareIn(renderer);
    item.resumeAt = YTResumeAtIn(renderer);

    if (item.duration == nil) {
        item.duration = [YTJson renderedText:badge key:@"text"];
    }

    // У новых view-model длительность — в значке поверх превью.
    if (item.duration == nil && playlistId == nil) {
        NSDictionary *overlay = [YTJson findFirst:@"thumbnailBadgeViewModel"
                                               in:renderer limit:600];

        item.duration = [YTJson textIn:overlay key:@"text"];
    }

    /**
     * Пометка подборки — «Микс», «50 видео» — стоит на месте длительности.
     *
     * Её не нужно собирать самому: сервер присылает её готовой строкой.
     * В новой разметке это `thumbnailBadgeViewModel.text`, в старой —
     * нижняя полоса превью `thumbnailOverlayBottomPanelRenderer.text`
     * либо `videoCountShortText` у `playlistRenderer`.
     */
    if ([item.duration length] == 0 && playlistId != nil) {
        NSDictionary *mark = [YTJson findFirst:@"thumbnailBadgeViewModel"
                                            in:renderer limit:600];

        item.duration = [YTJson textIn:mark key:@"text"];

        if (item.duration == nil) {
            NSDictionary *panel = [YTJson findFirst:@"thumbnailOverlayBottomPanelRenderer"
                                                 in:renderer limit:600];

            item.duration = [YTJson renderedText:panel key:@"text"];
        }

        if (item.duration == nil) {
            item.duration = [YTJson renderedText:renderer key:@"videoCountShortText"];
        }

        if (item.duration == nil) {
            item.duration = [YTJson renderedText:renderer key:@"videoCountText"];
        }
    }

    item.viewCount = [YTJson renderedText:renderer key:@"shortViewCountText"];

    if (item.viewCount == nil) {
        item.viewCount = [YTJson renderedText:renderer key:@"viewCountText"];
    }

    /**
     * Просмотры и давность — в последней строке, **кроме той, где автор**.
     *
     * Оговорка не лишняя: в истории строка всего одна и занята автором.
     * Прежний разбор брал последнюю строку всегда, и в просмотры попадало
     * имя канала — то же самое, что уже стоит автором.
     */
    NSInteger last = (NSInteger)YTLockupMetadataRows(renderer) - 1;

    if (last == authorRow) { last -= 1; }

    if (last >= 0) {
        if (item.viewCount == nil) {
            item.viewCount = YTLockupMetadataPart(renderer, (NSUInteger)last, 0);
        }
    }

    item.published = [YTJson renderedText:renderer key:@"publishedTimeText"];

    if (item.published == nil && last >= 0) {
        item.published = YTLockupMetadataPart(renderer, (NSUInteger)last, 1);
    }

    return item;
}

+ (NSArray *)parseFrom:(id)tree {
    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    /**
     * Один обход на все имена сразу.
     *
     * Раньше здесь был `findAll:` в цикле по именам, и каждый проход
     * отсчитывал свой потолок узлов с нуля — то есть дальше первых пяти
     * тысяч не заглядывал ни один. На ленте подписок это резало выдачу
     * до первой полки: ответ TV-клиента больше мегабайта, ролики в нём
     * разложены по полке на канал, и в ленту попадал один канал.
     *
     * Потолок поднят, потому что теперь он один на всё: обойти дерево
     * целиком дешевле, чем семь раз обойти его начало. Обход идёт
     * в фоне (YTAsync), так что даже на A4 это не задерживает экран.
     */
    NSArray *found = [YTJson findAllOfAny:YTVideoRendererNames()
                                       in:tree
                                    limit:200000];

    for (NSDictionary *hit in found) {
        NSDictionary *node = [hit objectForKey:@"node"];

        // Плитка разбирается своим ходом: общего с остальными рендерерами
        // у неё нет ничего, кроме того, что за ней тоже стоит ролик.
        YTVideoItem *item = [[hit objectForKey:@"name"] isEqualToString:@"tileRenderer"]
            ? [self fromTile:node]
            : [self fromRenderer:node];

        if (item == nil) {
            continue;
        }

        /**
         * Отсев вертикальных — здесь, и это выбор места, а не удобство.
         *
         * `parseFrom:` — единственная дверь, через которую ролики попадают
         * во **все** обычные ленты: «Главную», подписки, канал, подборки,
         * историю и похожие. Отсеивать по местам значило бы завести пять
         * одинаковых проверок и забыть шестую — ту, которую заведут
         * позже. Здесь забыть нельзя.
         *
         * Разбор модели за настройкой обычно не ходит, и это исключение
         * оправдано ровно тем же: полнота тут важнее чистоты слоя.
         */
        if (item.isShort && [YTSettings hidesShorts]) {
            continue;
        }

        // Один и тот же ролик приходит и как `videoRenderer`, и внутри
        // соседнего блока: без этого лента шла бы с повторами.
        NSString *key = [item.videoId length] > 0 ? item.videoId : item.playlistId;

        if (key == nil || [seen containsObject:key]) {
            continue;
        }

        [seen addObject:key];
        [items addObject:item];
    }

    return items;
}

+ (NSArray *)parseShortsFrom:(id)tree {
    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    NSArray *names = [NSArray arrayWithObjects:
        @"reelItemRenderer", @"shortsLockupViewModel", nil];

    NSArray *found = [YTJson findAllOfAny:names in:tree limit:200000];

    for (NSDictionary *hit in found) {
        NSDictionary *node = [hit objectForKey:@"node"];

        YTVideoItem *item = [self fromRenderer:node];

        if (item == nil) {
            item = [[YTVideoItem alloc] init];
        }

        /**
         * У новой модели `shortsLockupViewModel` идентификатор лежит
         * не там, где у прочих рендереров, — он в `reelWatchEndpoint`
         * внутри команды нажатия. Общий разбор его не находит,
         * поэтому достаём отдельно.
         */
        NSDictionary *endpoint = [YTJson findFirst:@"reelWatchEndpoint"
                                                in:node limit:800];

        if ([item.videoId length] != 11) {
            item.videoId = [YTJson textIn:endpoint key:@"videoId"];
        }

        if ([item.videoId length] != 11) {
            continue;
        }

        /**
         * Пропуск на ленту, начинающуюся с этого ролика.
         *
         * Сервер кладёт его в ту же команду нажатия: с ним запрос
         * `reel_watch_sequence` возвращает не случайную ленту, а ту,
         * что начинается отсюда, — ровно так листалка и открывается
         * из выдачи поиска в оригинале.
         */
        item.shortsSequence = [YTJson textIn:endpoint key:@"sequenceParams"];

        /**
         * Подписи у той же модели лежат в `overlayMetadata`: название
         * в `primaryText`, просмотры в `secondaryText`. Общий разбор ищет
         * их там, где они у обычных карточек, и не находит ничего.
         *
         * Добирались они прежде только у карточек без идентификатора —
         * то есть у тех, что и так разбирались наполовину. А стоило
         * идентификатору найтись, как всё прочее оставалось пустым:
         * в выдаче поиска по Shorts это выглядело как ряд картинок
         * без единой надписи.
         */
        if ([item.title length] == 0 || [item.viewCount length] == 0) {
            NSDictionary *overlay = [YTJson findFirst:@"overlayMetadata"
                                                   in:node limit:800];

            if ([item.title length] == 0) {
                item.title = [YTJson renderedText:overlay key:@"primaryText"];
            }

            if ([item.viewCount length] == 0) {
                item.viewCount = [YTJson renderedText:overlay key:@"secondaryText"];
            }

            /**
             * Если разметку опять переложат — ищем те же поля где угодно
             * внутри карточки. Имена у них редкие, спутать не с чем,
             * а обёртка вокруг них за последний год менялась дважды.
             */
            if ([item.title length] == 0) {
                item.title = [YTJson renderedValue:
                    [YTJson findFirst:@"primaryText" in:node limit:800]];
            }

            if ([item.viewCount length] == 0) {
                item.viewCount = [YTJson renderedValue:
                    [YTJson findFirst:@"secondaryText" in:node limit:800]];
            }
        }

        if ([item.title length] == 0) {
            item.title = [YTJson renderedText:node key:@"headline"] ?: @"Shorts";
        }

        if ([item.thumbnail length] == 0) {
            item.thumbnail = [NSString stringWithFormat:
                @"https://i.ytimg.com/vi/%@/hqdefault.jpg", item.videoId];
        }

        if ([seen containsObject:item.videoId]) {
            continue;
        }

        item.isShort = YES;

        [seen addObject:item.videoId];
        [items addObject:item];
    }

    return items;
}

+ (NSArray *)parseChannelsFrom:(id)tree {
    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    for (NSDictionary *node in [YTJson findAll:@"channelRenderer" in:tree limit:200000]) {
        NSString *channelId = [YTJson textIn:node key:@"channelId"];

        if ([channelId length] == 0 || [seen containsObject:channelId]) {
            continue;
        }

        [seen addObject:channelId];

        YTVideoItem *item = [[YTVideoItem alloc] init];

        item.channelId = channelId;
        item.title = [YTJson renderedText:node key:@"title"];
        item.thumbnail = [YTJson thumbnailIn:node key:@"thumbnail" minWidth:176];
        item.channelThumbnail = item.thumbnail;

        /**
         * Имена полей у канала переставлены местами, и это не описка:
         * число подписчиков сервер кладёт в `videoCountText`, а собачку —
         * в `subscriberCountText`. Так и приходит, проверено по ответу.
         */
        item.viewCount = [YTJson renderedText:node key:@"videoCountText"];
        item.channelTitle = [YTJson renderedText:node key:@"subscriberCountText"];
        item.published = [YTJson renderedText:node key:@"descriptionSnippet"];

        [items addObject:item];
    }

    return items;
}

@end
