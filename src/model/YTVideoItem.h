#import <Foundation/Foundation.h>

/**
 * Текст пункта строки метаданных плитки TV-клиента.
 *
 * Порт `ExtractTileLineItemText`: строка — это `lineRenderer` со списком
 * `items`, у каждого внутри `lineItemRenderer.text`. Отрицательный номер
 * отсчитывается с конца — так в оригинале, потому что число пунктов гуляет:
 * последний всегда давность, третий с конца — просмотры.
 *
 * Наружу вынесена потому, что плитками описаны не только ролики, но и
 * подборки, а разбирают их разные места.
 */
NSString *YTTileLineText(NSDictionary *line, NSInteger index);


/**
 * Карточка ролика в ленте.
 *
 * Порт `VideoCardItem` из UWP-версии — те же поля и та же сборка строки
 * метаданных. Отдельного класса под каждый вид рендерера нет намеренно:
 * `videoRenderer`, `gridVideoRenderer`, `compactVideoRenderer`,
 * `playlistVideoRenderer`, `lockupViewModel` и `reelItemRenderer` описывают
 * одно и то же разными словами, и разбор сводит их сюда.
 */
@interface YTVideoItem : NSObject

@property (nonatomic, copy) NSString *videoId;

/**
 * Идентификатор подборки, если карточка — не ролик, а плейлист или микс.
 *
 * Миксы (`RD…`) и плейлисты (`PL…`, `LL…`, `UL…`, `OLA…`) приходят в тех же
 * списках и теми же рендерерами, что ролики, и раньше отсеивались по длине
 * идентификатора. Отсев был прав по сути — открывать их как ролик нельзя, —
 * но лишал ленту половины содержимого: в выдаче поиска миксов заметно
 * много, и на их месте зияла дыра.
 *
 * У таких карточек `videoId` пуст, а в `duration` лежит пометка, которую
 * прислал сервер: «Микс», «50 видео». Придумывать её не нужно и нельзя —
 * она уже размечена в ответе.
 */
@property (nonatomic, copy) NSString *playlistId;

/** Карточка ведёт на подборку, а не на ролик. */
- (BOOL)isPlaylist;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *channelTitle;
@property (nonatomic, copy) NSString *channelId;
@property (nonatomic, copy) NSString *channelThumbnail;
@property (nonatomic, copy) NSString *thumbnail;

/** Как пришло от сервера: «9:26», «LIVE» либо пусто у Shorts. */
@property (nonatomic, copy) NSString *duration;

/** «1 тыс. просмотров» — уже готовой строкой, сервер сам её и склеивает. */
@property (nonatomic, copy) NSString *viewCount;

/** «3 часа назад». */
@property (nonatomic, copy) NSString *published;

/** Признак прямого эфира — плашка длительности у них другая. */
@property (nonatomic, assign) BOOL isLive;

/**
 * Доля просмотренного от 0 до 1, как её сообщает сервер.
 *
 * Приходит в `thumbnailOverlayResumePlaybackRenderer` рядом со значком
 * длительности: `percentDurationWatched`, целые проценты. Минус один —
 * «сервер не сказал», и тогда берётся своя запись.
 */
@property (nonatomic, assign) double watchedShare;

/**
 * С какой секунды продолжать, по слову сервера.
 *
 * Приходит в `watchEndpoint.startTimeSeconds` у той же плитки, где лежит
 * доля просмотра. Ноль — начинать сначала: так сервер отвечает и о
 * недосмотренных с самого начала, и о досмотренных до конца.
 */
@property (nonatomic, assign) NSTimeInterval resumeAt;

/**
 * Вертикальный ролик. Отмечается при разборе Shorts и нужен карточке:
 * у такого превью пропорция 9:16, и в место под 16:9 оно вписывалось
 * с обрезкой по бокам — от кадра оставалась узкая полоса посередине.
 */
@property (nonatomic, assign) BOOL isShort;

/**
 * Пропуск на ленту Shorts, начинающуюся с этого ролика.
 *
 * Приходит вместе с карточкой и нужен, чтобы открыть листалку не с
 * начала, а отсюда: с ним запрос за лентой возвращает выбранный ролик
 * первым, а за ним — продолжение по вкусу сервера.
 */
@property (nonatomic, copy) NSString *shortsSequence;

/**
 * Вторая строка карточки: «автор • просмотры • давность».
 *
 * Склеивается здесь, а не в ячейке, ровно как `MetadataLine` в UWP-версии:
 * разделитель нужно ставить только между непустыми кусками, иначе у ролика
 * без счётчика просмотров строка начиналась бы с висящей точки.
 */
- (NSString *)metadataLine;

/** Разбор одного рендерера в карточку; nil, если это не ролик. */
+ (YTVideoItem *)fromRenderer:(NSDictionary *)renderer;

/**
 * Собирает все карточки из ответа InnerTube, каким бы ни была его форма.
 *
 * Ищет по всему дереву известные имена рендереров — так же поступала
 * UWP-версия (`VideoRendererMarkers`), и по той же причине: ответ у одного
 * и того же экрана меняет форму от клиента к клиенту и от недели к неделе,
 * а список роликов в нём всё равно узнаётся по имени узла.
 */
+ (NSArray *)parseFrom:(id)tree;

/**
 * Только вертикальные ролики — `reelItemRenderer` и `shortsLockupViewModel`.
 *
 * Общий разбор их намеренно не берёт: в обычную выдачу они попадали бы
 * карточками без длительности. А вот для вкладки Shorts в поиске нужны
 * ровно они — «ParseShortResults below then keeps only genuine Shorts
 * renderers», как сказано в оригинале.
 */
+ (NSArray *)parseShortsFrom:(id)tree;

/**
 * Только каналы — `channelRenderer` из вкладки «Каналы» в поиске.
 *
 * Общий разбор их не берёт и брать не должен: у канала нет ни ролика,
 * ни подборки, и карточка ему нужна другая. Поля заполняются по смыслу:
 * `title` — имя канала, `channelTitle` — собачка, `viewCount` — число
 * подписчиков, `published` — строка описания, `thumbnail` — кружок.
 */
+ (NSArray *)parseChannelsFrom:(id)tree;

@end
