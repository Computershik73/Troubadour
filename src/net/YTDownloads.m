#import "YTDownloads.h"

#import "YTApi.h"
#import "YTHttp.h"
#import "YTSabr.h"
#import "YTStreams.h"
#import "YTMp4Writer.h"
#import "YTStrings.h"
#import "YTVideoItem.h"

NSString *const YTDownloadsChangedNotification = @"YTDownloadsChanged";

/**
 * Как часто оповещать об одной и той же загрузке.
 *
 * Куски приходят десятками в секунду, и оповещать на каждый — значит
 * перекладывать список чаще, чем экран успевает рисовать. На iPad 2 это
 * видно сразу: полоса дёргается, прокрутка встаёт.
 */
static const NSTimeInterval YTDownloadTick = 0.5;

/**
 * Места на диске — записи о них знать положено, а наружу отдавать незачем.
 */
@interface YTDownloads (Places)

+ (NSString *)folder;
+ (NSString *)thumbsFolder;

@end


@implementation YTDownloadItem

- (float)progress {
    if (_complete) {
        return 1.0f;
    }

    if (_totalBytes <= 0) {
        return 0.0f;
    }

    float part = (float)_gotBytes / (float)_totalBytes;

    return part < 0 ? 0 : (part > 1 ? 1 : part);
}

- (NSString *)filePath {
    /**
     * Имя файла — из ролика **и качества**.
     *
     * Иначе второе скачивание того же ролика в другом качестве писало бы
     * поверх первого: имя-то одно. У «готового» качества номера нет,
     * поэтому у него своё слово.
     */
    NSString *mark = _height > 0
        ? [NSString stringWithFormat:@"%ld", (long)_height] : @"ready";

    return [[YTDownloads folder] stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@_%@.mp4", _videoId, mark]];
}

- (NSString *)thumbnailPath {
    return [[YTDownloads thumbsFolder] stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.jpg", _videoId]];
}

@end


@implementation YTDownloads

/** Перечень в памяти — он же то, что пишется на диск. */
static NSMutableArray *YTItems = nil;

/**
 * Какие загрузки идут сейчас и какие просили бросить.
 *
 * Раньше занятость была одна на всё приложение: качать можно было
 * только по одному, а нажатие кнопки при занятости означало «останови».
 * Из-за этого второе качество не поставить в работу, не бросив первое.
 *
 * Теперь идущих может быть несколько. Их всё же не бесконечно много:
 * `YTDownloadAtOnce` держит потолок, а остальные ждут своей очереди.
 * На iPad 2 десяток разом отобрал бы у воспроизведения и сеть, и память.
 */
static NSMutableSet *YTBusyKeys = nil;
static NSMutableSet *YTStopKeys = nil;

/** Сколько загрузок идёт одновременно; остальные ждут в очереди. */
static const NSUInteger YTDownloadAtOnce = 2;

static dispatch_queue_t YTDownloadQueue = NULL;

/** Пропуск: столько загрузок держится в работе, прочие ждут его. */
static dispatch_semaphore_t YTDownloadGate = NULL;

/**
 * Очередь и пропуск заводятся вместе и ровно один раз.
 *
 * Порознь их заводить нельзя, и это стоило падения: меню качеств
 * создавало очередь у себя, а пропуск — нет, и заводило его первым.
 * К началу загрузки очередь уже была, ветка создания не срабатывала,
 * и `dispatch_semaphore_wait` получал пустой пропуск. Отказ по адресу
 * 0x28 на потоке `yt.downloads` — это ровно он.
 */
+ (void)ensureQueue {
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        YTDownloadQueue = dispatch_queue_create("yt.downloads",
                                                DISPATCH_QUEUE_CONCURRENT);

        YTDownloadGate = dispatch_semaphore_create(YTDownloadAtOnce);
    });
}

#pragma mark Места на диске

+ (NSString *)folder {
    static NSString *path = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        NSString *documents = [NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES) lastObject];

        path = [documents stringByAppendingPathComponent:@"Downloads"];

        [[NSFileManager defaultManager] createDirectoryAtPath:path
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:NULL];
    });

    return path;
}

+ (NSString *)thumbsFolder {
    static NSString *path = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        path = [[self folder] stringByAppendingPathComponent:@"thumbs"];

        [[NSFileManager defaultManager] createDirectoryAtPath:path
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:NULL];
    });

    return path;
}

+ (NSString *)indexPath {
    return [[self folder] stringByAppendingPathComponent:@"index.plist"];
}

#pragma mark Перечень

/**
 * Перечень — обычный plist рядом с файлами.
 *
 * Не база и не свои настройки: записей десятки, читается он один раз
 * за запуск, а лежать должен там же, где ролики, — чтобы вычистить
 * скачанное можно было одной папкой, ничего не рассогласовав.
 */
+ (NSMutableArray *)stored {
    @synchronized ([YTDownloads class]) {
        if (YTItems != nil) {
            return YTItems;
        }

        YTItems = [NSMutableArray array];

        NSArray *saved = [NSArray arrayWithContentsOfFile:[self indexPath]];

        for (NSDictionary *row in saved) {
            YTDownloadItem *item = [[YTDownloadItem alloc] init];

            item.videoId = [row objectForKey:@"videoId"];
            item.title = [row objectForKey:@"title"];
            item.channelTitle = [row objectForKey:@"channelTitle"];
            item.published = [row objectForKey:@"published"];
            item.viewCount = [row objectForKey:@"viewCount"];
            item.duration = [row objectForKey:@"duration"];
            item.thumbnailUrl = [row objectForKey:@"thumbnailUrl"];
            item.totalBytes = [[row objectForKey:@"totalBytes"] longLongValue];
            item.height = [[row objectForKey:@"height"] integerValue];
            item.complete = [[row objectForKey:@"complete"] boolValue];
            item.addedAt = [[row objectForKey:@"addedAt"] doubleValue];

            if ([item.videoId length] == 0) {
                continue;
            }

            /**
             * Сколько скачано — по самому файлу, а не по записи.
             *
             * Запись могла не успеть обновиться: приложение снимают
             * во время загрузки, и последние куски в неё не попадают.
             * Файл же на диске лежит ровно такой, какой есть, и он
             * и есть правда о том, с какого места продолжать.
             */
            NSDictionary *about = [[NSFileManager defaultManager]
                attributesOfItemAtPath:[item filePath] error:NULL];

            item.gotBytes = (long long)[about fileSize];

            if (about == nil) {
                // Файла нет вовсе — запись о нём бессмысленна.
                continue;
            }

            /**
             * Готовый, но битый файл — выбрасываем.
             *
             * Такой остаётся после прерванной сборки: запись говорит
             * «скачано», а в файле нет ни `moov`, ни половины данных.
             * Он хуже отсутствия — выглядит готовым, занимает место
             * и не играет. Проверяем только те, что помечены готовыми:
             * недокачанным обрубок положен по существу.
             */
            if (item.complete && ![self looksWhole:[item filePath]]) {
                NSLog(@"[YouTube/Скачано] %@ (%ldp) битый — убираем",
                      item.videoId, (long)item.height);

                [[NSFileManager defaultManager]
                    removeItemAtPath:[item filePath] error:NULL];

                continue;
            }

            [YTItems addObject:item];
        }

        [self sort];

        return YTItems;
    }
}

+ (void)sort {
    [YTItems sortUsingComparator:^NSComparisonResult(YTDownloadItem *a, YTDownloadItem *b) {
        if (a.addedAt > b.addedAt) { return NSOrderedAscending; }
        if (a.addedAt < b.addedAt) { return NSOrderedDescending; }

        return NSOrderedSame;
    }];
}

+ (void)save {
    @synchronized ([YTDownloads class]) {
        NSMutableArray *rows = [NSMutableArray array];

        for (YTDownloadItem *item in YTItems) {
            NSMutableDictionary *row = [NSMutableDictionary dictionary];

            [row setObject:item.videoId ?: @"" forKey:@"videoId"];
            [row setObject:item.title ?: @"" forKey:@"title"];
            [row setObject:item.channelTitle ?: @"" forKey:@"channelTitle"];
            [row setObject:item.published ?: @"" forKey:@"published"];
            [row setObject:item.viewCount ?: @"" forKey:@"viewCount"];
            [row setObject:item.duration ?: @"" forKey:@"duration"];
            [row setObject:item.thumbnailUrl ?: @"" forKey:@"thumbnailUrl"];

            [row setObject:[NSNumber numberWithLongLong:item.totalBytes]
                    forKey:@"totalBytes"];
            [row setObject:[NSNumber numberWithInteger:item.height]
                    forKey:@"height"];
            [row setObject:[NSNumber numberWithBool:item.complete]
                    forKey:@"complete"];
            [row setObject:[NSNumber numberWithDouble:item.addedAt]
                    forKey:@"addedAt"];

            [rows addObject:row];
        }

        [rows writeToFile:[self indexPath] atomically:YES];
    }
}

+ (NSArray *)items {
    @synchronized ([YTDownloads class]) {
        return [[self stored] copy];
    }
}

/** Ключ загрузки: ролик и качество вместе. */
+ (NSString *)keyFor:(NSString *)videoId height:(NSInteger)height {
    return [NSString stringWithFormat:@"%@#%ld", videoId, (long)height];
}

+ (YTDownloadItem *)itemFor:(NSString *)videoId height:(NSInteger)height {
    if ([videoId length] == 0) {
        return nil;
    }

    @synchronized ([YTDownloads class]) {
        for (YTDownloadItem *item in [self stored]) {
            if ([item.videoId isEqualToString:videoId] && item.height == height) {
                return item;
            }
        }
    }

    return nil;
}

+ (NSArray *)videos {
    NSMutableArray *one = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    @synchronized ([YTDownloads class]) {
        for (YTDownloadItem *item in [self stored]) {
            if ([seen containsObject:item.videoId]) {
                continue;
            }

            [seen addObject:item.videoId];

            /**
             * Кого показать за весь ролик: готовое и самое высокое,
             * а из недокачанных — то, что ближе к концу.
             */
            YTDownloadItem *best = nil;

            for (YTDownloadItem *other in [self itemsFor:item.videoId]) {
                if (best == nil) { best = other; continue; }

                if (other.complete != best.complete) {
                    if (other.complete) { best = other; }

                    continue;
                }

                if (best.complete) {
                    if (other.height > best.height) { best = other; }
                } else if ([other progress] > [best progress]) {
                    best = other;
                }
            }

            if (best != nil) { [one addObject:best]; }
        }
    }

    return one;
}

+ (long long)bytesFor:(NSString *)videoId {
    long long sum = 0;

    for (YTDownloadItem *one in [self itemsFor:videoId]) {
        sum += one.gotBytes;
    }

    return sum;
}

+ (NSArray *)itemsFor:(NSString *)videoId {
    NSMutableArray *found = [NSMutableArray array];

    if ([videoId length] == 0) {
        return found;
    }

    @synchronized ([YTDownloads class]) {
        for (YTDownloadItem *item in [self stored]) {
            if ([item.videoId isEqualToString:videoId]) {
                [found addObject:item];
            }
        }
    }

    [found sortUsingComparator:^NSComparisonResult(YTDownloadItem *a, YTDownloadItem *b) {
        if (a.height < b.height) { return NSOrderedAscending; }
        if (a.height > b.height) { return NSOrderedDescending; }

        return NSOrderedSame;
    }];

    return found;
}

+ (BOOL)haveAny:(NSString *)videoId {
    return [[self itemsFor:videoId] count] > 0;
}

+ (BOOL)isBusy:(NSString *)videoId height:(NSInteger)height {
    @synchronized ([YTDownloads class]) {
        return [YTBusyKeys containsObject:[self keyFor:videoId height:height]];
    }
}

+ (BOOL)isBusyAny:(NSString *)videoId {
    @synchronized ([YTDownloads class]) {
        NSString *mark = [videoId stringByAppendingString:@"#"];

        for (NSString *key in YTBusyKeys) {
            if ([key hasPrefix:mark]) {
                return YES;
            }
        }

        return NO;
    }
}

+ (void)announce {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:YTDownloadsChangedNotification object:nil];
    });
}

#pragma mark Превью

+ (void)keepThumbnail:(NSString *)videoId url:(NSString *)url {
    if ([videoId length] == 0 || [url length] == 0) {
        return;
    }

    // Превью общее на все качества — годится запись любого из них.
    YTDownloadItem *item = [[self itemsFor:videoId] firstObject];

    NSString *path = item != nil
        ? [item thumbnailPath]
        : [[self thumbsFolder] stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.jpg", videoId]];

    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return;
    }

    NSMutableURLRequest *request = YTRequest(url, NSURLRequestUseProtocolCachePolicy, 20.0);

    if (request == nil) {
        return;
    }

    YTHttpResponse *response = [YTHttp send:request bodyLimit:2 * 1024 * 1024];

    if (![response isSuccessful] || [response.body length] == 0) {
        NSLog(@"[YouTube/Скачано] Превью %@ не забралось", videoId);

        return;
    }

    [response.body writeToFile:path atomically:YES];

    [self announce];
}

#pragma mark Загрузка

+ (NSArray *)offeredHeights {
    return [NSArray arrayWithObjects:
        [NSNumber numberWithInteger:0],
        [NSNumber numberWithInteger:144],
        [NSNumber numberWithInteger:240],
        [NSNumber numberWithInteger:360],
        [NSNumber numberWithInteger:480],
        [NSNumber numberWithInteger:720],
        [NSNumber numberWithInteger:1080], nil];
}

+ (void)askHeightsFor:(NSString *)videoId
                 done:(void (^)(NSArray *heights))done {
    if ([videoId length] == 0 || done == nil) {
        return;
    }

    [self ensureQueue];

    dispatch_async(YTDownloadQueue, ^{
        /**
         * Спрашиваем тем же клиентом, что и сама загрузка.
         *
         * Иначе меню и загрузка расходились бы во мнениях: у TV-клиента
         * с подачей дорожки есть, а адресов нет — предложить можно,
         * скачать нельзя.
         */
        NSDictionary *player = [YTApi androidVrPlayerResponse:videoId];

        NSArray *formats = [YTStreams formatsFrom:player];

        if ([formats count] == 0) {
            player = [YTApi playerResponse:videoId];
            formats = [YTStreams formatsFrom:player];
        }

        NSMutableArray *heights = [NSMutableArray array];

        // Готовый склеенный поток — если он вообще есть у этого ролика.
        if ([[YTStreams progressiveUrlIn:player] length] > 0) {
            [heights addObject:[NSNumber numberWithInteger:0]];
        }

        [heights addObjectsFromArray:[YTStreams heightsIn:formats]];

        /**
         * Ни одного адреса — значит, ролик отдаётся подачей SABR.
         *
         * Это не «забрать нечего»: дорожки у него есть и описаны, просто
         * лежат они не за ссылками, а за живым сеансом. Забирать оттуда
         * мы умеем — тем же кодом, что и смотрим, — поэтому список надо
         * показать, а не отговариваться. Прежде здесь выходил пустой
         * массив, и человек видел «YouTube не дал ни одной дорожки»
         * у ролика, который в этот самый миг прекрасно играл.
         */
        if ([heights count] == 0) {
            NSDictionary *sabrSide = [YTApi playerResponse:videoId];

            [heights addObjectsFromArray:[YTStreams heightsInResponse:sabrSide]];

            if ([heights count] > 0) {
                NSLog(@"[YouTube/Скачано] У %@ адресов нет — ступени взяты "
                      @"из описаний дорожек, забирать будем подачей", videoId);
            }
        }

        NSLog(@"[YouTube/Скачано] У %@ качеств: %@", videoId,
              [heights componentsJoinedByString:@", "]);

        dispatch_async(dispatch_get_main_queue(), ^{
            done(heights);
        });
    });
}

+ (NSString *)titleForHeight:(NSInteger)height {
    if (height <= 0) {
        return YTLoc(@"Готовое (360p)");
    }

    return [NSString stringWithFormat:@"%ldp", (long)height];
}

+ (void)start:(NSString *)videoId
        title:(NSString *)title
      details:(NSDictionary *)details
         item:(id)videoItem
       height:(NSInteger)height {
    if ([videoId length] == 0) {
        return;
    }

    YTDownloadItem *have = [self itemFor:videoId height:height];

    if (have != nil && have.complete) {
        NSLog(@"[YouTube/Скачано] %@ (%ldp) уже скачан", videoId, (long)height);

        return;
    }

    @synchronized ([YTDownloads class]) {
        if (YTBusyKeys == nil) { YTBusyKeys = [NSMutableSet set]; }
        if (YTStopKeys == nil) { YTStopKeys = [NSMutableSet set]; }

        NSString *key = [self keyFor:videoId height:height];

        if ([YTBusyKeys containsObject:key]) {
            NSLog(@"[YouTube/Скачано] %@ уже качается", key);

            return;
        }

        [YTBusyKeys addObject:key];
        [YTStopKeys removeObject:key];

        /**
         * Очередь общая, а одновременность держит пропуск: заявок может
         * быть сколько угодно, а в работе всегда не больше
         * `YTDownloadAtOnce`. Остальные ждут на пропуске, ничего
         * не занимая, кроме места в очереди.
         */
        [self ensureQueue];
    }

    /**
     * Запись заводится **до** первого байта.
     *
     * Так у полосы сразу появляется карточка с названием и превью,
     * а не пустое место на минуту, пока идут запросы. Недокачанная
     * запись честно показывает проценты; брошенная — остаётся
     * недокачанной, и её видно.
     */
    YTDownloadItem *item = have;

    if (item == nil) {
        item = [[YTDownloadItem alloc] init];

        item.videoId = videoId;
        item.height = height;
        item.addedAt = [[NSDate date] timeIntervalSince1970];

        @synchronized ([YTDownloads class]) {
            [[self stored] insertObject:item atIndex:0];
        }
    }

    [self describe:item title:title details:details item:videoItem];

    [self save];
    [self announce];

    NSString *key = [self keyFor:videoId height:height];

    dispatch_async(YTDownloadQueue, ^{
        // Пропуск держит одновременность: сверх потолка заявки ждут здесь.
        dispatch_semaphore_wait(YTDownloadGate, DISPATCH_TIME_FOREVER);

        [self run:item key:key];

        dispatch_semaphore_signal(YTDownloadGate);
    });
}

/** Подписи карточки — из того, что дала страница ролика. */
+ (void)describe:(YTDownloadItem *)item
           title:(NSString *)title
         details:(NSDictionary *)details
            item:(id)videoItem {
    if ([title length] > 0) { item.title = title; }

    NSString *fromDetails = [details objectForKey:@"title"];

    if ([item.title length] == 0 && [fromDetails length] > 0) {
        item.title = fromDetails;
    }

    NSString *channel = [details objectForKey:@"channelTitle"];

    if ([channel length] > 0) { item.channelTitle = channel; }

    NSString *published = [details objectForKey:@"published"];

    if ([published length] > 0) { item.published = published; }

    NSString *views = [details objectForKey:@"views"];

    if ([views length] > 0) { item.viewCount = views; }

    /**
     * Карточка из ленты, если её передали, — там лежат превью
     * и длительность, которых на странице ролика нет.
     */
    if ([videoItem isKindOfClass:[YTVideoItem class]]) {
        YTVideoItem *card = videoItem;

        if ([card.thumbnail length] > 0) { item.thumbnailUrl = card.thumbnail; }
        if ([card.duration length] > 0)  { item.duration = card.duration; }
        if ([item.title length] == 0)    { item.title = card.title; }
        if ([item.channelTitle length] == 0) { item.channelTitle = card.channelTitle; }
    }

    /**
     * Превью без карточки — по постоянному адресу.
     *
     * У YouTube он собирается из идентификатора и не меняется:
     * `i.ytimg.com/vi/<ролик>/hqdefault.jpg`. Спрашивать ради картинки
     * отдельную страницу незачем.
     */
    if ([item.thumbnailUrl length] == 0) {
        item.thumbnailUrl = [NSString stringWithFormat:
            @"https://i.ytimg.com/vi/%@/hqdefault.jpg", item.videoId];
    }
}

/**
 * Сама загрузка: адрес, дозапрос остатка, запись в файл.
 *
 * Идёт на своей очереди, не на главной. Всё, что видит экран, — это
 * запись в перечне и оповещение.
 */
/**
 * Одна дорожка в один файл: дозапрос остатка, потоковая запись.
 *
 * Общая часть обоих путей — и готового потока, и раздельных дорожек.
 * `onTotal` зовётся, когда сервер назвал длину; `onChunk` — на каждый
 * кусок, и его NO обрывает загрузку.
 */
/**
 * Сколько просить за один заход.
 *
 * Раздача googlevideo придерживает долгий поток: первые мегабайты
 * отдаются быстро, а дальше скорость прижимается примерно к той,
 * с какой ролик смотрят. Для просмотра это разумно — незачем гнать
 * гигабайт тому, кто уйдёт на второй минуте, — но скачивание от этого
 * растягивается на длительность ролика.
 *
 * Обходится это не просьбой отдавать быстрее (такой просьбы нет),
 * а тем, что берём кусками: каждый новый `Range` начинается со своей
 * быстрой порции. Восемь мегабайт — размер, при котором заходов
 * немного, а придержать нас не успевают.
 */
static const long long YTFetchChunk = 8 * 1024 * 1024;

/** Полная длина из `Content-Range: bytes 0-8388607/135406598`. */
+ (long long)totalIn:(NSDictionary *)headers {
    NSString *range = nil;

    for (NSString *name in headers) {
        if ([name caseInsensitiveCompare:@"Content-Range"] == NSOrderedSame) {
            range = [headers objectForKey:name];
            break;
        }
    }

    NSRange slash = [range rangeOfString:@"/" options:NSBackwardsSearch];

    if (slash.location == NSNotFound) {
        return 0;
    }

    return [[range substringFromIndex:slash.location + 1] longLongValue];
}

+ (BOOL)fetch:(NSString *)url
           to:(NSString *)path
      onTotal:(void (^)(long long total))onTotal
      onChunk:(BOOL (^)(long long added))onChunk {
    if ([url length] == 0) {
        return NO;
    }

    NSFileManager *files = [NSFileManager defaultManager];

    if (![files fileExistsAtPath:path]) {
        [files createFileAtPath:path contents:nil attributes:nil];
    }

    __block long long total = 0;

    NSTimeInterval began = [NSDate timeIntervalSinceReferenceDate];

    long long startedAt =
        (long long)[[files attributesOfItemAtPath:path error:NULL] fileSize];

    while (YES) {
        long long already =
            (long long)[[files attributesOfItemAtPath:path error:NULL] fileSize];

        if (total > 0 && already >= total) {
            break;
        }

        NSMutableURLRequest *request =
            YTRequest(url, NSURLRequestReloadIgnoringLocalCacheData, 60.0);

        if (request == nil) {
            return NO;
        }

        [request setValue:[YTApi mediaUserAgent] forHTTPHeaderField:@"User-Agent"];

        /**
         * Кусок с ясными краями, а не «всё от сих и до конца».
         *
         * Открытый `Range` раздача считает просмотром и придерживает;
         * закрытый — обычным запросом куска, и отдаёт его целиком
         * на полной скорости.
         */
        long long last = already + YTFetchChunk - 1;

        if (total > 0 && last > total - 1) { last = total - 1; }

        [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld",
                           already, last]
       forHTTPHeaderField:@"Range"];

        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];

        if (handle == nil) {
            return NO;
        }

        [handle seekToEndOfFile];

        __block BOOL torn = NO;
        __block long long got = 0;

        [YTHttp stream:request onHeaders:^(YTHttpResponse *head) {
            if (total > 0) {
                return;
            }

            /**
             * Полную длину берём из `Content-Range`, а не из длины ответа:
             * та говорит про кусок, а нам нужен весь файл.
             */
            total = [self totalIn:head.headers];

            if (total <= 0 && head.expectedLength > 0) {
                total = already + head.expectedLength;
            }

            if (total > 0 && onTotal != nil) {
                onTotal(total);
            }
        } onChunk:^BOOL(NSData *piece) {
            @try {
                [handle writeData:piece];
            } @catch (NSException *trouble) {
                NSLog(@"[YouTube/Скачано] Запись не удалась — %@", [trouble reason]);

                torn = YES;

                return NO;
            }

            got += (long long)[piece length];

            if (onChunk != nil && !onChunk((long long)[piece length])) {
                torn = YES;

                return NO;
            }

            return YES;
        }];

        [handle closeFile];

        if (torn) {
            return NO;
        }

        /**
         * Кусок не принёс ничего — дальше идти некуда.
         *
         * Так бывает и в конце файла (когда длину мы не узнали), и при
         * отказе раздачи. Различать их незачем: в обоих случаях
         * продолжать нечем, а целость проверит тот, кто звал.
         */
        if (got == 0) {
            break;
        }
    }

    long long moved =
        (long long)[[files attributesOfItemAtPath:path error:NULL] fileSize] - startedAt;

    NSTimeInterval spent = [NSDate timeIntervalSinceReferenceDate] - began;

    if (spent > 0.5 && moved > 0) {
        NSLog(@"[YouTube/Скачано] %@: %@ за %.0f с — %.1f МБ/с",
              [path lastPathComponent], [self sizeText:moved], spent,
              (double)moved / 1048576.0 / spent);
    }

    return YES;
}

/** Не просили ли бросить именно эту загрузку. */
+ (BOOL)stopping:(NSString *)key {
    @synchronized ([YTDownloads class]) {
        return [YTStopKeys containsObject:key];
    }
}

/**
 * Дорожка нужного качества — или ближайшая к нему.
 *
 * Точного совпадения у ролика может не быть вовсе: набор высот
 * у каждого свой, и 1080p есть далеко не везде. Тогда берём ту,
 * что ближе всего по высоте, — это лучше, чем отказ.
 */
+ (YTFormat *)videoNear:(NSInteger)height in:(NSArray *)formats {
    YTFormat *best = nil;
    NSInteger bestGap = 0;

    for (YTFormat *one in formats) {
        if (!one.hasVideo || one.hasAudio || [one.url length] == 0) {
            continue;
        }

        // Только H.264: остальное старые системы не декодируют.
        if (![one isH264]) {
            continue;
        }

        /**
         * Сравниваем по ступени, а не по сырой высоте.
         *
         * Меню предлагает привычные ступени (720p, 1080p), а `height`
         * у широкого кадра в них не попадает — там 712 и 1068. По сырой
         * высоте выходило, что просимого качества «нет», и запись
         * заводилась заново под другим числом: тот самый случай, когда
         * один ролик расползался по списку на несколько строк.
         * У вертикального ролика та же беда с другой стороны: `height`
         * там длинная сторона.
         */
        NSInteger gap = [one qualityTier] - height;

        if (gap < 0) { gap = -gap; }

        if (best == nil || gap < bestGap) {
            best = one;
            bestGap = gap;
        }
    }

    return best;
}

/**
 * Сама загрузка.
 *
 * Идёт на своей очереди, не на главной. Всё, что видит экран, — это
 * запись в перечне и оповещение.
 */
+ (void)run:(YTDownloadItem *)item key:(NSString *)key {
    NSString *videoId = item.videoId;

    [self keepThumbnail:videoId url:item.thumbnailUrl];

    /**
     * Ответ спрашиваем у ANDROID_VR, а не у TV-клиента.
     *
     * `playerResponse:` при включённой подаче отдаёт ответ телевизора,
     * а там **адресов нет вовсе**: дорожки описаны, но забирать их
     * положено по SABR, кусок за куском, через живой сеанс. Плеер так
     * и делает, а скачивание на этом вставало намертво — «дорожек 29,
     * готовых 0», и загрузка висела на нуле при любом качестве.
     *
     * `androidVrPlayerResponse:` заведомо без подачи: у него в дорожках
     * готовые подписанные ссылки, которые можно просто скачать.
     */
    NSDictionary *player = [YTApi androidVrPlayerResponse:videoId];

    if ([[YTStreams formatsFrom:player] count] == 0) {
        NSLog(@"[YouTube/Скачано] У ANDROID_VR пусто — спросим обычным путём");

        player = [YTApi playerResponse:videoId];
    }

    if (item.duration == nil) {
        NSTimeInterval length = [YTStreams lengthIn:player];

        if (length > 0) {
            item.duration = [NSString stringWithFormat:@"%ld:%02ld",
                (long)(length / 60), (long)((long)length % 60)];
        }
    }

    BOOL ok;

    if (item.height <= 0) {
        ok = [self runReady:item key:key player:player];
    } else if ([[YTStreams formatsFrom:player] count] > 0) {
        ok = [self runTracks:item key:key player:player];
    } else {
        /**
         * Адресов нет ни у кого — ролик отдаётся подачей SABR.
         *
         * Прежде здесь всё и кончалось: `runTracks:` не находил дорожек
         * и возвращал отказ. Но подача — не запрет, а другой способ
         * доставки, и забирать оттуда мы умеем: тем же кодом, каким
         * смотрим. Разница только в источнике байтов, а дальше та же
         * склейка в обычный MP4.
         */
        ok = [self runSabr:item key:key player:player];
    }

    /**
     * Дошло — проверяем, что вышло.
     *
     * Своя же сборка может дать негодный файл: ошибка в таблицах видна
     * не по коду возврата, а по тому, что боксы не сходятся. Пусть
     * лучше запись пропадёт сразу, чем человек откроет чёрный экран.
     */
    if (ok && ![self looksWhole:[item filePath]]) {
        NSLog(@"[YouTube/Скачано] %@ (%ldp) собрался битым — убираем",
              videoId, (long)item.height);

        [[NSFileManager defaultManager] removeItemAtPath:[item filePath] error:NULL];

        ok = NO;
    }

    item.complete = ok;

    [self save];
    [self finish:key];
}

/**
 * Готовый склеенный поток — один файл, никакой сборки.
 *
 * Качество тут какое дадут: обычно itag 18, 360p. Зато он приезжает
 * готовым и играет сразу, даже недокачанный.
 */
+ (BOOL)runReady:(YTDownloadItem *)item
             key:(NSString *)key
          player:(NSDictionary *)player {
    NSString *url = [YTStreams progressiveUrlIn:player];

    if ([url length] == 0) {
        NSLog(@"[YouTube/Скачано] У %@ нет склеенного потока", item.videoId);

        return NO;
    }

    __block NSTimeInterval told = 0;

    item.gotBytes = (long long)[[[NSFileManager defaultManager]
        attributesOfItemAtPath:[item filePath] error:NULL] fileSize];

    BOOL whole = [self fetch:url to:[item filePath] onTotal:^(long long total) {
        item.totalBytes = total;
    } onChunk:^BOOL(long long added) {
        if ([self stopping:key]) {
            return NO;
        }

        item.gotBytes += added;

        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

        if (now - told >= YTDownloadTick) {
            told = now;

            [self announce];
        }

        return YES;
    }];

    whole = whole && item.totalBytes > 0 && item.gotBytes >= item.totalBytes;

    NSLog(@"[YouTube/Скачано] %@ готовым потоком: %@ (%lld из %lld)",
          item.videoId, whole ? @"готов" : @"не дошёл",
          item.gotBytes, item.totalBytes);

    return whole;
}

/**
 * Раздельные дорожки: качаем обе и склеиваем в обычный MP4.
 *
 * Порядок именно такой — сначала обе целиком, потом сборка. Собирать
 * на ходу нельзя: таблицы сэмплов пишутся в конце файла и знают
 * смещения только тогда, когда все данные уже легли.
 */
+ (BOOL)runTracks:(YTDownloadItem *)item
              key:(NSString *)key
           player:(NSDictionary *)player {
    NSArray *formats = [YTStreams formatsFrom:player];

    YTFormat *video = [self videoNear:item.height in:formats];
    YTFormat *audio = [YTStreams chooseAudio:formats preferredTrack:nil];

    if (video == nil) {
        NSLog(@"[YouTube/Скачано] У %@ нет раздельных дорожек", item.videoId);

        return NO;
    }

    NSInteger got = [video qualityTier];

    if (got != item.height) {
        NSLog(@"[YouTube/Скачано] %ldp у %@ нет — берём ближайшее %ldp",
              (long)item.height, item.videoId, (long)got);
    }

    /**
     * Ближайшее качество — это уже **другая** запись.
     *
     * Просили 1080p, а у ролика их нет, и мы взяли 360p. Если оставить
     * запись под прежним номером, то следующее нажатие на 1080p снова
     * не найдёт её (там-то теперь 360) и заведёт вторую — и так на
     * каждую попытку. Поэтому сверяемся: есть ли уже запись на то
     * качество, которое вышло на самом деле.
     */
    if (got != item.height) {
        YTDownloadItem *twin = [self itemFor:item.videoId height:got];

        item.height = got;

        if (twin != nil && twin != item) {
            NSLog(@"[YouTube/Скачано] %ldp у %@ уже заведено — не двоим",
                  (long)got, item.videoId);

            @synchronized ([YTDownloads class]) {
                [YTItems removeObject:item];
            }

            item = twin;
        }
    }

    NSString *videoPath = [[item filePath] stringByAppendingString:@".v"];
    NSString *audioPath = [[item filePath] stringByAppendingString:@".a"];

    NSFileManager *files = [NSFileManager defaultManager];

    /**
     * Общий объём известен **до** первого байта.
     *
     * Прежде он складывался по мере дела: пока шло видео, знаменателем
     * был только его размер, доля добегала до сотни, а с началом звука
     * знаменатель подрастал — и проценты откатывались назад. Со стороны
     * это выглядело как второй круг загрузки.
     *
     * Сервер называет длину каждой дорожки в самом ответе, и обе цифры
     * есть у нас на руках ещё до запроса.
     */
    __block long long videoTotal = video.contentLength;
    __block long long audioTotal = audio != nil ? audio.contentLength : 0;

    __block NSTimeInterval told = 0;

    long long onDisk =
        (long long)[[files attributesOfItemAtPath:videoPath error:NULL] fileSize] +
        (long long)[[files attributesOfItemAtPath:audioPath error:NULL] fileSize];

    item.gotBytes = onDisk;

    BOOL (^tick)(long long) = ^BOOL(long long added) {
        if ([self stopping:key]) {
            return NO;
        }

        item.gotBytes += added;
        item.totalBytes = videoTotal + audioTotal;

        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

        if (now - told >= YTDownloadTick) {
            told = now;

            [self announce];
        }

        return YES;
    };

    if (![self fetch:video.url to:videoPath onTotal:^(long long total) {
        // Сервер сказал точнее — верим ему, а не описанию дорожки.
        videoTotal = total;
    } onChunk:tick]) {
        return NO;
    }

    if (audio != nil) {
        if (![self fetch:audio.url to:audioPath onTotal:^(long long total) {
            audioTotal = total;
        } onChunk:tick]) {
            return NO;
        }
    }

    /**
     * Дорожка целая, только если её длина сошлась с обещанной.
     *
     * Склеивать обрубок нельзя: разбор дойдёт до половины фрагмента
     * и остановится, а файл получится с виду готовым.
     */
    long long haveVideo =
        (long long)[[files attributesOfItemAtPath:videoPath error:NULL] fileSize];

    if (videoTotal > 0 && haveVideo < videoTotal) {
        NSLog(@"[YouTube/Скачано] %@: видео не дошло (%lld из %lld)",
              item.videoId, haveVideo, videoTotal);

        return NO;
    }

    return [self assemble:item
                      key:key
                    video:videoPath
                    audio:(audio != nil ? audioPath : nil)];
}

/**
 * Дорожки из подачи SABR.
 *
 * У части роликов адресов не бывает вовсе: сервер отдаёт их только
 * живым сеансом, кусок за куском. Плеер так и смотрит, а скачивание
 * до сих пор отговаривалось «YouTube не дал ни одной дорожки» —
 * притом что дорожки есть, просто лежат не за ссылками.
 *
 * Разница с обычным путём ровно в одном — откуда берутся байты.
 * Складываются они в те же два файла: заголовок дорожки, а следом
 * фрагменты подряд. Это тот же fMP4, что приезжает диапазонами байт,
 * и склейка о разнице не знает.
 *
 * Докачивать нечего: у нового сеанса своя нарезка, и половина прежнего
 * файла с хвостом нового не сойдётся. Поэтому начинаем всякий раз
 * с чистого листа.
 */
+ (BOOL)runSabr:(YTDownloadItem *)item
            key:(NSString *)key
         player:(NSDictionary *)player {
    YTSabr *sabr = [YTStreams detachedSabrFor:player maxHeight:item.height];

    if (sabr == nil || [[sabr videoInit] length] == 0) {
        NSLog(@"[YouTube/Скачано] %@: подача не поднялась — забирать нечем",
              item.videoId);

        return NO;
    }

    NSTimeInterval length = [sabr duration];

    if (length <= 0) {
        length = [YTStreams lengthIn:player];
    }

    if (length <= 0) {
        NSLog(@"[YouTube/Скачано] %@: подача не назвала длительности — "
              @"неизвестно, когда останавливаться", item.videoId);

        return NO;
    }

    NSData *audioInit = [sabr audioInit];

    NSString *videoPath = [[item filePath] stringByAppendingString:@".v"];
    NSString *audioPath = [[item filePath] stringByAppendingString:@".a"];

    NSFileManager *files = [NSFileManager defaultManager];

    [files removeItemAtPath:videoPath error:NULL];
    [files removeItemAtPath:audioPath error:NULL];

    [files createFileAtPath:videoPath contents:[sabr videoInit] attributes:nil];

    if ([audioInit length] > 0) {
        [files createFileAtPath:audioPath contents:audioInit attributes:nil];
    }

    NSFileHandle *videoFile = [NSFileHandle fileHandleForWritingAtPath:videoPath];
    NSFileHandle *audioFile = ([audioInit length] > 0)
        ? [NSFileHandle fileHandleForWritingAtPath:audioPath]
        : nil;

    if (videoFile == nil) {
        NSLog(@"[YouTube/Скачано] %@: некуда писать дорожку", item.videoId);

        return NO;
    }

    [videoFile seekToEndOfFile];
    [audioFile seekToEndOfFile];

    item.gotBytes = (long long)[[sabr videoInit] length] + (long long)[audioInit length];
    item.totalBytes = 0;

    NSInteger lastVideo = -1;
    NSInteger lastAudio = -1;

    NSTimeInterval videoEnd = 0;
    NSTimeInterval audioEnd = 0;

    /** Сколько кругов подряд подача молчала. */
    NSInteger idle = 0;

    NSTimeInterval told = 0;

    BOOL stopped = NO;

    while (YES) {
        if ([self stopping:key]) {
            stopped = YES;

            break;
        }

        BOOL wrote = NO;

        /**
         * Пишем строго подряд.
         *
         * Пропустить недостающий фрагмент и взять следующий нельзя:
         * в файле осталась бы дыра, а склейка честно сложила бы её
         * в готовый ролик — с прыжком посреди. Не пришёл — ждём его,
         * а не идём дальше.
         */
        for (NSNumber *number in [sabr videoSequences]) {
            NSInteger sequence = [number integerValue];

            if (sequence <= lastVideo) {
                continue;
            }

            if (lastVideo >= 0 && sequence != lastVideo + 1) {
                break;
            }

            NSData *chunk = [sabr videoSegment:sequence];

            if ([chunk length] == 0) {
                break;
            }

            [videoFile writeData:chunk];

            lastVideo = sequence;
            videoEnd = [sabr videoSegmentStart:sequence]
                     + [sabr videoSegmentDuration:sequence];

            item.gotBytes += (long long)[chunk length];

            wrote = YES;
        }

        for (NSNumber *number in [sabr audioSequences]) {
            if (audioFile == nil) {
                break;
            }

            NSInteger sequence = [number integerValue];

            if (sequence <= lastAudio) {
                continue;
            }

            if (lastAudio >= 0 && sequence != lastAudio + 1) {
                break;
            }

            NSData *chunk = [sabr audioSegment:sequence];

            if ([chunk length] == 0) {
                break;
            }

            [audioFile writeData:chunk];

            lastAudio = sequence;
            audioEnd = [sabr audioSegmentStart:sequence]
                     + [sabr audioSegmentDuration:sequence];

            item.gotBytes += (long long)[chunk length];

            wrote = YES;
        }

        if (wrote) {
            idle = 0;

            /**
             * Записанное из памяти выбрасываем: фрагменты весят
             * мегабайтами, а устройству с четвертью гигабайта и без
             * того тесно. Времена при этом остаются — по ним подача
             * понимает, что у нас уже есть.
             */
            [sabr forgetBefore:MIN(videoEnd, audioFile != nil ? audioEnd : videoEnd)];

            /**
             * Общий объём подача не называет — прикидываем по времени.
             *
             * Оценка сходится к правде по мере набора и в начале ролика
             * гуляет: у первых секунд битрейт свой. Показывать её лучше,
             * чем не показывать ничего: без знаменателя полоса стояла бы
             * на нуле до самого конца.
             */
            if (videoEnd > 1.0) {
                item.totalBytes =
                    (long long)((double)item.gotBytes * length / videoEnd);
            }

            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

            if (now - told >= YTDownloadTick) {
                told = now;

                [self announce];
            }
        }

        BOOL videoDone = videoEnd >= length - 0.5;
        BOOL audioDone = (audioFile == nil) || (audioEnd >= length - 0.5);

        if (videoDone && audioDone) {
            break;
        }

        /**
         * Просим с того места, где кончилось **отстающее** из двух:
         * подача шлёт то, чего у нас, по её сведениям, нет, и просить
         * с более позднего значило бы оставить дыру в другой дорожке.
         */
        NSTimeInterval from = (audioFile != nil) ? MIN(videoEnd, audioEnd) : videoEnd;

        if ([sabr requestMoreFrom:from] || wrote) {
            continue;
        }

        /**
         * Сервер мог не отказать, а попросить взять ответ `/player`
         * заново: сессия подачи живёт минуты, а длинный ролик качается
         * дольше. Пока просьбу не исполнят, байтов не будет вовсе.
         */
        if ([sabr needsReload] && [YTStreams renewSabr:sabr]) {
            continue;
        }

        idle++;

        if (idle >= 6) {
            NSLog(@"[YouTube/Скачано] %@: подача смолкла на %.0f с из %.0f",
                  item.videoId, videoEnd, length);

            break;
        }

        [NSThread sleepForTimeInterval:MAX(0.25, [sabr backoff])];
    }

    [videoFile closeFile];
    [audioFile closeFile];

    if (stopped) {
        return NO;
    }

    /**
     * Обрубок склеивать нельзя: разбор дойдёт до конца набранного
     * и остановится, а файл выйдет с виду готовым.
     */
    if (videoEnd < length - 1.0) {
        NSLog(@"[YouTube/Скачано] %@: подачей набрано %.0f с из %.0f — "
              @"недобор, не склеиваем", item.videoId, videoEnd, length);

        return NO;
    }

    NSLog(@"[YouTube/Скачано] %@: подача отдала %.0f с, фрагментов %ld",
          item.videoId, videoEnd, (long)(lastVideo + 1));

    return [self assemble:item
                      key:key
                    video:videoPath
                    audio:(audioFile != nil ? audioPath : nil)];
}

/**
 * Склейка двух дорожек в обычный MP4 и уборка за собой.
 *
 * Общий хвост обоих раздельных путей — и того, что качает диапазонами
 * байт, и того, что забирает подачей. Дальше этой черты они не
 * различаются вовсе: на диске в обоих случаях лежат те же fMP4.
 */
+ (BOOL)assemble:(YTDownloadItem *)item
             key:(NSString *)key
           video:(NSString *)videoPath
           audio:(NSString *)audioPath {
    NSFileManager *files = [NSFileManager defaultManager];

    NSLog(@"[YouTube/Скачано] %@: дорожки на месте, собираем %ldp",
          item.videoId, (long)item.height);

    item.muxing = YES;

    [self announce];

    __block NSTimeInterval told = 0;

    BOOL built = [YTMp4Writer writeTo:[item filePath]
                            videoPath:videoPath
                            audioPath:audioPath
                             progress:^BOOL(float part) {
        if ([self stopping:key]) {
            return NO;
        }

        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

        if (now - told >= YTDownloadTick) {
            told = now;

            [self announce];
        }

        return YES;
    }];

    item.muxing = NO;

    if (!built) {
        return NO;
    }

    /**
     * Дорожки убираем: они втрое тяжелее собранного файла и больше
     * ни на что не годны. Оборвалась сборка — остаются, и следующий
     * заход начнёт прямо со склейки, ничего не качая заново.
     */
    [files removeItemAtPath:videoPath error:NULL];

    if (audioPath != nil) {
        [files removeItemAtPath:audioPath error:NULL];
    }

    item.gotBytes = (long long)[[files attributesOfItemAtPath:[item filePath]
                                                        error:NULL] fileSize];
    item.totalBytes = item.gotBytes;

    return YES;
}


/**
 * Загрузка кончилась — освобождаем место следующей.
 *
 * Ключ здесь не сверяется: занятость одна на всё приложение, и кончиться
 * может только та загрузка, что шла. Сверка по ролику была ошибкой
 * перехода на ключ «ролик и качество» — она не совпадала никогда,
 * и занятость не снималась бы вовсе.
 */
+ (void)finish:(NSString *)key {
    @synchronized ([YTDownloads class]) {
        [YTBusyKeys removeObject:key];
        [YTStopKeys removeObject:key];
    }

    [self announce];
}

+ (void)stop:(NSString *)videoId height:(NSInteger)height {
    @synchronized ([YTDownloads class]) {
        NSString *key = [self keyFor:videoId height:height];

        if ([YTBusyKeys containsObject:key]) {
            if (YTStopKeys == nil) { YTStopKeys = [NSMutableSet set]; }

            [YTStopKeys addObject:key];
        }
    }
}

+ (void)remove:(NSString *)videoId height:(NSInteger)height {
    [self stop:videoId height:height];

    YTDownloadItem *item = [self itemFor:videoId height:height];

    if (item == nil) {
        return;
    }

    NSFileManager *files = [NSFileManager defaultManager];

    [files removeItemAtPath:[item filePath] error:NULL];
    [files removeItemAtPath:[[item filePath] stringByAppendingString:@".v"] error:NULL];
    [files removeItemAtPath:[[item filePath] stringByAppendingString:@".a"] error:NULL];

    // Превью общее на все качества ролика — убираем, только если это
    // была последняя его запись.
    if ([[self itemsFor:videoId] count] <= 1) {
        [files removeItemAtPath:[item thumbnailPath] error:NULL];
    }

    @synchronized ([YTDownloads class]) {
        [YTItems removeObject:item];
    }

    [self save];
    [self announce];

    NSLog(@"[YouTube/Скачано] %@ убран", videoId);
}

#pragma mark Мелочи

+ (BOOL)looksWhole:(NSString *)path {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];

    if (file == nil) {
        return NO;
    }

    uint64_t length = (uint64_t)[[[NSFileManager defaultManager]
        attributesOfItemAtPath:path error:NULL] fileSize];

    uint64_t position = 0;
    BOOL sawMoov = NO;

    while (position + 8 <= length) {
        @try {
            [file seekToFileOffset:position];
        } @catch (NSException *trouble) {
            break;
        }

        NSData *head = [file readDataOfLength:8];

        if ([head length] < 8) {
            break;
        }

        const uint8_t *bytes = [head bytes];

        uint64_t size = ((uint64_t)bytes[0] << 24) | ((uint64_t)bytes[1] << 16) |
                        ((uint64_t)bytes[2] << 8) | (uint64_t)bytes[3];

        char tag[5];

        memcpy(tag, bytes + 4, 4);

        tag[4] = 0;

        if (size == 1) {
            NSData *large = [file readDataOfLength:8];

            if ([large length] < 8) {
                break;
            }

            const uint8_t *big = [large bytes];

            size = 0;

            for (int i = 0; i < 8; i++) { size = (size << 8) | big[i]; }
        }

        if (size < 8) {
            break;
        }

        if (strcmp(tag, "moov") == 0) { sawMoov = YES; }

        position += size;
    }

    [file closeFile];

    /**
     * Целым считаем тот файл, у которого боксы сошлись ровно с длиной
     * и среди них нашёлся `moov`.
     *
     * У обрубка последний бокс обещает больше байт, чем есть, — цикл
     * выходит раньше конца, и `position` до длины не дотягивает.
     * Ни описания, ни таблиц у такого файла нет, и играть его нечем.
     */
    return sawMoov && position == length && length > 0;
}

+ (NSString *)sizeText:(long long)bytes {
    if (bytes <= 0) {
        return @"—";
    }

    double value = (double)bytes;

    if (value < 1024) {
        return YTLocF(@"%.0f Б", value);
    }

    value /= 1024;

    if (value < 1024) {
        return YTLocF(@"%.0f КБ", value);
    }

    value /= 1024;

    if (value < 1024) {
        return YTLocF(@"%.1f МБ", value);
    }

    return YTLocF(@"%.2f ГБ", value / 1024);
}

@end
