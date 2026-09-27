#import "YTImageLoader.h"

#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>

#import "YTHttp.h"
#import "YTSettings.h"

static NSString *const YTImageTag = @"YTImageRequestedUrl";

/**
 * Устройство с небольшой памятью: полгигабайта и меньше.
 *
 * Порог — три четверти гигабайта, а не ровно 512 МБ, и это не придирка:
 * система отдаёт не круглое число, а то, что осталось после её собственных
 * нужд. iPhone 4 при своих номинальных 512 МБ сообщает 504, и на другой
 * сборке прошивки это может оказаться другое число — хоть и 520. Ступени
 * же у железа редкие: 256, 512, гигабайт. Порог посередине между второй
 * и третьей ни с чем не спутает, где бы ни легло сообщённое.
 */
static BOOL YTSmallMemory(void) {
    static BOOL small = NO;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        unsigned long long memory = [[NSProcessInfo processInfo] physicalMemory];

        small = memory < 768ULL * 1024 * 1024;

        NSLog(@"[YouTube/Превью] Памяти у устройства %llu МБ — бережный путь %@",
              memory / 1024 / 1024, small ? @"включён" : @"не нужен");
    });

    return small;
}

/**
 * Потолок ширины декодирования.
 *
 * Карточка во всю ширину на iPad просит превью ровно такого размера, а это
 * мегабайты на кадр. По высоте карточке всё равно нужно немного, и растяжение
 * вдвое на глаз почти незаметно. На устройствах с большой памятью ограничение
 * снимается.
 */
static CGFloat YTMaxDecodeWidth(void) {
    return YTSmallMemory() ? 640.0 : 1280.0;
}

#pragma mark - Очередь с разбором с конца

/**
 * Очередь заданий, которая отдаёт последнее поставленное.
 *
 * NSOperationQueue так не умеет: приоритет там задаётся заранее и не меняет
 * порядок уже стоящих в очереди. Поэтому свой стек и свои рабочие потоки.
 */
@interface YTImageQueue : NSObject {
    NSMutableArray *_stack;
    NSCondition *_condition;
}

- (id)initWithThreads:(NSInteger)threads;
- (void)push:(void (^)(void))block;

@end

@implementation YTImageQueue

- (id)initWithThreads:(NSInteger)threads {
    self = [super init];

    if (self == nil) {
        return nil;
    }

    _stack = [[NSMutableArray alloc] init];
    _condition = [[NSCondition alloc] init];

    for (NSInteger i = 0; i < threads; i++) {
        [NSThread detachNewThreadSelector:@selector(work) toTarget:self withObject:nil];
    }

    return self;
}

- (void)push:(void (^)(void))block {
    [_condition lock];
    [_stack addObject:[block copy]];
    [_condition signal];
    [_condition unlock];
}

- (void)work {
    while (YES) {
        @autoreleasepool {
            void (^job)(void) = nil;

            [_condition lock];

            while ([_stack count] == 0) {
                [_condition wait];
            }

            job = [_stack lastObject];
            [_stack removeLastObject];
            [_condition unlock];

            if (job != nil) {
                job();
            }
        }
    }
}

@end


@implementation UIImageView (YTImageTarget)
@end


#pragma mark - Загрузчик

@implementation YTImageLoader

/**
 * Память под превью. Ключ — только адрес, без размера.
 *
 * Одна и та же картинка нужна в разных местах разного размера (кружок канала
 * 36 и 60, карточка 360 и 640), и если бы каждый размер заводил свою запись,
 * выходила бы лишняя загрузка, лишнее декодирование и лишняя память. Теперь
 * хранится один кадр, а кадр крупнее нужного годится и для мелкого места —
 * показывающий вид ужмёт его сам.
 */
+ (NSCache *)cache {
    static NSCache *cache = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];

        unsigned long long memory = [[NSProcessInfo processInfo] physicalMemory];

        /**
         * На iPad 1 (256 МБ на всё) — четыре мегабайта, а не восемь.
         *
         * Систему там снимает приложение на 80–95 МБ, и каждый мегабайт,
         * который можно взять заново с диска, лучше не держать: превью
         * и так лежат в кеше кадров на диске.
         */
        unsigned long long divisor = memory < 300ULL * 1024 * 1024
            ? 64 : (YTSmallMemory() ? 32 : 12);

        NSUInteger limit = (NSUInteger)(memory / divisor);

        // NSCache считает не память процесса, а нашу же оценку в байтах,
        // поэтому доля берётся от физической памяти устройства, а не от кучи:
        // понятия «максимальный размер кучи» на iOS попросту нет.
        [cache setTotalCostLimit:MAX(limit, 4 * 1024 * 1024)];
    });

    return cache;
}

/**
 * Адреса, у которых исходник мельче запрошенного.
 *
 * Кружок канала нередко лежит в 88 пикселей и крупнее не существует; без
 * этой пометки такая картинка перезагружалась бы при каждом показе, потому
 * что в кеше она всегда «мельче нужного».
 */
+ (NSMutableSet *)exhausted {
    static NSMutableSet *set = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{ set = [[NSMutableSet alloc] init]; });

    return set;
}

/**
 * Замки по адресам. Одну и ту же картинку нередко просят сразу несколько
 * карточек — без замка каждая полезла бы в сеть сама. Второй поток ждёт
 * первый и берёт готовое из кеша.
 */
+ (id)lockFor:(NSString *)url {
    static NSMutableDictionary *locks = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{ locks = [[NSMutableDictionary alloc] init]; });

    @synchronized (locks) {
        id lock = [locks objectForKey:url];

        if (lock == nil) {
            lock = [[NSObject alloc] init];
            [locks setObject:lock forKey:url];
        }

        return lock;
    }
}

/**
 * Сколько превью тянем одновременно.
 *
 * Смотрим и на память, и на число ядер. iPhone 4 — это 512 МБ и **одно
 * ядро**: по памяти он проходит как «не слабый» и получил бы четыре потока,
 * которые на единственном ядре отнимают время у самой прокрутки. Двух там
 * не медленнее.
 */
+ (YTImageQueue *)queue {
    static YTImageQueue *queue = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        NSUInteger cores = [[NSProcessInfo processInfo] activeProcessorCount];
        NSInteger threads = 2;

        if (cores > 1 && !YTSmallMemory()) {
            threads = MAX(4, MIN(8, (NSInteger)cores));
        }

        NSLog(@"[YouTube/Превью] Потоков загрузки: %ld", (long)threads);

        queue = [[YTImageQueue alloc] initWithThreads:threads];
    });

    return queue;
}

#pragma mark Кеш

/**
 * Готовый кадр из памяти. Годится и тот, что крупнее нужного: показать его
 * можно как есть, а лишний раз ходить в сеть незачем. Мельче нужного
 * не берём — иначе картинка будет мылом; исключение только для тех,
 * у кого крупнее просто нет.
 */
+ (UIImage *)cachedFor:(NSString *)url pixelWidth:(CGFloat)width {
    UIImage *image = [[self cache] objectForKey:url];

    if (image == nil) {
        return nil;
    }

    CGFloat have = CGImageGetWidth([image CGImage]);

    if (have >= width) {
        return image;
    }

    @synchronized ([self exhausted]) {
        return [[self exhausted] containsObject:url] ? image : nil;
    }
}

#pragma mark Адрес

/**
 * Ступень превью у i.ytimg.com.
 *
 *   default.jpg       120×90
 *   mqdefault.jpg     320×180
 *   hqdefault.jpg     480×360
 *   sddefault.jpg     640×480
 *   maxresdefault.jpg 1280×720
 *
 * Подменяется только имя файла и только на самом i.ytimg.com: на чужих
 * хостах адрес остаётся нетронутым.
 *
 * Тонкость: `maxresdefault` есть далеко не у всякого ролика — у старых
 * и у тех, что залиты в низком разрешении, его просто нет, и CDN отвечает
 * 404. Поэтому выше `hqdefault` не поднимаемся: он есть всегда, а разницы
 * с `sddefault` на превью карточки не видно. Отказ по 404 при этом всё
 * равно обработан — см. `fetch:`, где неудачная ступень откатывается
 * к исходному адресу.
 */
+ (NSString *)sized:(NSString *)url pixelWidth:(CGFloat)width {
    // Кружок канала: сторона зашита в адрес как «=s88-…».
    if ([url rangeOfString:@"ggpht.com"].location != NSNotFound ||
        [url rangeOfString:@"googleusercontent.com"].location != NSNotFound) {

        NSRange marker = [url rangeOfString:@"=s" options:NSBackwardsSearch];

        if (marker.location == NSNotFound) {
            return url;
        }

        NSInteger side = 88;
        if (width > 176) { side = 240; }
        else if (width > 88) { side = 176; }

        return [NSString stringWithFormat:@"%@=s%ld-c-k-c0x00ffffff-no-rj",
                [url substringToIndex:marker.location], (long)side];
    }

    if ([url rangeOfString:@"ytimg.com"].location == NSNotFound) {
        return url;
    }

    NSString *step = @"hqdefault";

    if (width <= 120) { step = @"default"; }
    else if (width <= 320) { step = @"mqdefault"; }

    /**
     * Адрес собирается заново, а не правится.
     *
     * Выглядит грубее, чем подмена имени файла, но иначе нельзя.
     * У превью из выдачи адрес такой:
     *
     *     i.ytimg.com/vi/<id>/hq720.jpg?sqp=-oaymwEcCNAF…&rs=AOn4CL…
     *
     * И `sqp` здесь — не украшение: это подписанное указание, как
     * приготовить картинку, включая **формат**. С ним CDN отдаёт WebP,
     * несмотря на `.jpg` в имени. ImageIO научился читать WebP только
     * в iOS 14, поэтому на iOS 7 такой ответ молча разбирается в nil —
     * запрос успешен, 43 килобайта на месте, превью нет. В журнале это
     * видно первыми байтами `52 49 46 46`, то есть `RIFF`.
     *
     * Имён файлов при этом больше, чем список известных ступеней:
     * встречаются `hq720`, `hq2`, `sd1` и прочие. Поэтому и не подменяем
     * имя, а берём из адреса только идентификатор ролика и собираем
     * простой адрес без параметров — на него CDN отвечает настоящим JPEG.
     */
    /**
     * Каталогов у превью несколько: `/vi/` — обычные, `/vi_webp/` —
     * заведомо в WebP, `/vi_lc/` — с подписью на языке зрителя
     * (`hqdefault_ru.jpg`). Последний встречается редко, и потому долго
     * оставался неучтённым: адрес возвращался как есть, вместе с `sqp`,
     * CDN отдавал по нему WebP, а ImageIO до iOS 14 такого не знает —
     * в журнале это «Не разобралось (25406 байт, 52 49 46 46)».
     */
    NSRange folder = [url rangeOfString:@"/vi/"];

    if (folder.location == NSNotFound) {
        folder = [url rangeOfString:@"/vi_webp/"];
    }

    if (folder.location == NSNotFound) {
        folder = [url rangeOfString:@"/vi_lc/"];
    }

    if (folder.location == NSNotFound) {
        return url;
    }

    NSString *rest = [url substringFromIndex:folder.location + folder.length];
    NSRange next = [rest rangeOfString:@"/"];

    if (next.location == NSNotFound) {
        return url;
    }

    NSString *videoId = [rest substringToIndex:next.location];

    if ([videoId length] == 0) {
        return url;
    }

    return [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/%@.jpg", videoId, step];
}

#pragma mark Кеш разобранных кадров

/**
 * Готовые пиксели рядом с приложением — чтобы не разбирать одно и то же дважды.
 *
 * Дисковый кеш HTTP хранит **джипег**, и каждый его показ снова стоит разбора:
 * на A4 это около ста шестидесяти миллисекунд на картинку, вчетверо дороже
 * всего остального вместе взятого. Здесь же лежит уже разобранный и уложенный
 * в шестнадцать бит кадр: показать его — это отобразить файл в память и
 * обернуть в `CGImage`, без единого умножения.
 *
 * Формат нарочно тот самый, в который кладёт `repack16bit`: RGB555, два байта
 * на точку, старший бит не используется. Ничего другого сюда не попадает —
 * иначе пришлось бы описывать в файле цветовое пространство и способ укладки,
 * а это уже свой формат картинок, и притом худший, чем существующие.
 *
 * Размеры кадра — в имени файла, а не в заголовке: тогда файл целиком есть
 * пиксели, и его можно отдать `CGImage` прямо из отображённой памяти, ничего
 * не копируя.
 */
static const NSUInteger YTFrameCacheLimit = 32 * 1024 * 1024;

/** Освобождение отображённого файла — когда `CGImage` больше не нужен. */
static void YTFrameDataRelease(void *info, const void *data, size_t size) {
    if (info != NULL) {
        CFRelease((CFDataRef)info);
    }
}

+ (NSString *)frameDirectory {
    static NSString *path = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        NSString *caches = [NSSearchPathForDirectoriesInDomains(
            NSCachesDirectory, NSUserDomainMask, YES) lastObject];

        path = [caches stringByAppendingPathComponent:@"frames"];

        [[NSFileManager defaultManager] createDirectoryAtPath:path
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:NULL];

        // Подрезка — в стороне от первой картинки: перебор каталога
        // на неспешной вспышке занимает заметное время.
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            [self trimFrames];
        });
    });

    return path;
}

/** Имя без размеров: по нему ищем, каким бы кадр ни оказался. */
+ (NSString *)frameKeyFor:(NSString *)address width:(CGFloat)width {
    NSString *full = [NSString stringWithFormat:@"%@@%ld", address, (long)width];

    const char *bytes = [full UTF8String];

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];

    CC_SHA1(bytes, (CC_LONG)strlen(bytes), digest);

    NSMutableString *name = [NSMutableString stringWithCapacity:40];

    for (NSUInteger i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [name appendFormat:@"%02x", digest[i]];
    }

    return name;
}

+ (UIImage *)frameFor:(NSString *)address width:(CGFloat)width {
    if (!YTSmallMemory()) {
        return nil;
    }

    NSTimeInterval started = CFAbsoluteTimeGetCurrent();

    NSString *key = [self frameKeyFor:address width:width];
    NSString *directory = [self frameDirectory];

    /**
     * Размеры кадра заранее неизвестны — они зависят от того, что прислал
     * сервер, — поэтому имя ищется по началу. Файлов в каталоге тысячи,
     * и перебирать его целиком нельзя; спрашиваем систему об одном имени,
     * перебирая известные окончания, — но окончание тут одно на кадр,
     * и хранится оно рядом, в спутнике с тем же именем.
     */
    NSString *sizePath = [directory stringByAppendingPathComponent:
        [key stringByAppendingPathExtension:@"size"]];

    NSString *size = [NSString stringWithContentsOfFile:sizePath
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];

    NSArray *parts = [size componentsSeparatedByString:@"x"];

    if ([parts count] != 2) {
        return nil;
    }

    size_t pixelWidth = (size_t)[[parts objectAtIndex:0] integerValue];
    size_t pixelHeight = (size_t)[[parts objectAtIndex:1] integerValue];

    if (pixelWidth == 0 || pixelHeight == 0) {
        return nil;
    }

    NSString *path = [directory stringByAppendingPathComponent:
        [key stringByAppendingPathExtension:@"rgb555"]];

    NSData *data = [NSData dataWithContentsOfFile:path
                                          options:NSDataReadingMappedIfSafe
                                            error:NULL];

    size_t stride = pixelWidth * 2;

    if ([data length] != stride * pixelHeight) {
        return nil;
    }

    CGDataProviderRef provider = CGDataProviderCreateWithData(
        (void *)CFBridgingRetain(data), [data bytes], [data length],
        YTFrameDataRelease);

    if (provider == NULL) {
        return nil;
    }

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();

    CGImageRef frame = CGImageCreate(
        pixelWidth, pixelHeight, 5, 16, stride, space,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder16Little,
        provider, NULL, false, kCGRenderingIntentDefault);

    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);

    if (frame == NULL) {
        return nil;
    }

    UIImage *image = [UIImage imageWithCGImage:frame];

    CGImageRelease(frame);

    [self recordFrame:CFAbsoluteTimeGetCurrent() - started];

    return image;
}

/**
 * Отчёт о готовых кадрах — отдельной строкой и своим счётом.
 *
 * В общий замер их класть нельзя: там средние на загрузку, а здесь
 * загрузки нет вовсе. Зато сравнить две строки между собой — это и есть
 * ответ на вопрос, стоил ли кеш кадров хлопот.
 */
static NSInteger YTFrameCount = 0;
static NSTimeInterval YTFrameSeconds = 0;

+ (void)recordFrame:(NSTimeInterval)seconds {
    @synchronized (self) {
        YTFrameCount++;
        YTFrameSeconds += seconds;

        // По десятку, а не по двадцать пять: экран карточек — это меньше
        // десяти картинок, и при прежнем счёте отчёта можно было ждать
        // до вечера, гадая, работает ли кеш вообще.
        if (YTFrameCount < 10) {
            return;
        }

        NSLog(@"[YouTube/Превью] %ld готовых кадров из своего кеша, "
              @"на картинку %ld мс",
              (long)YTFrameCount, (long)(YTFrameSeconds * 1000 / YTFrameCount));

        YTFrameCount = 0;
        YTFrameSeconds = 0;
    }
}

+ (void)storeFrame:(UIImage *)image for:(NSString *)address width:(CGFloat)width {
    if (!YTSmallMemory() || image == nil) {
        return;
    }

    CGImageRef frame = [image CGImage];

    // Кладём только своё: чужую укладку этот формат не описывает.
    if (frame == NULL ||
        CGImageGetBitsPerComponent(frame) != 5 ||
        CGImageGetBitsPerPixel(frame) != 16 ||
        CGImageGetBytesPerRow(frame) != CGImageGetWidth(frame) * 2) {

        return;
    }

    CGDataProviderRef provider = CGImageGetDataProvider(frame);

    if (provider == NULL) {
        return;
    }

    CFDataRef pixels = CGDataProviderCopyData(provider);

    if (pixels == NULL) {
        return;
    }

    NSString *key = [self frameKeyFor:address width:width];
    NSString *directory = [self frameDirectory];

    NSString *path = [directory stringByAppendingPathComponent:
        [key stringByAppendingPathExtension:@"rgb555"]];

    NSString *sizePath = [directory stringByAppendingPathComponent:
        [key stringByAppendingPathExtension:@"size"]];

    // Сперва пиксели, потом размеры: спутник и есть признак готовности,
    // и по недописанному кадру мы его не прочтём.
    if ([(__bridge NSData *)pixels writeToFile:path atomically:YES]) {
        [[NSString stringWithFormat:@"%lux%lu",
            (unsigned long)CGImageGetWidth(frame),
            (unsigned long)CGImageGetHeight(frame)]
            writeToFile:sizePath atomically:YES
               encoding:NSUTF8StringEncoding error:NULL];

        // Один раз за запуск — чтобы «кеш не работает» и «кеш пуст»
        // не выглядели в журнале одинаково.
        static dispatch_once_t once;

        dispatch_once(&once, ^{
            NSLog(@"[YouTube/Превью] Кеш кадров пишется: %lu×%lu, %lu КБ на кадр, "
                  @"каталог %@",
                  (unsigned long)CGImageGetWidth(frame),
                  (unsigned long)CGImageGetHeight(frame),
                  (unsigned long)(CFDataGetLength(pixels) / 1024),
                  directory);
        });
    }

    CFRelease(pixels);

    /**
     * Подрезка не только при запуске.
     *
     * Кадр весит под четыреста килобайт, и долгий заход по лентам
     * складывает их куда быстрее, чем случится следующий запуск:
     * сотня карточек — это уже сорок мегабайт, то есть выше потолка.
     * Считаем сохранённые и время от времени прибираемся.
     */
    static NSInteger stored = 0;
    BOOL trim = NO;

    @synchronized (self) {
        stored++;

        if (stored >= 64) {
            stored = 0;
            trim = YES;
        }
    }

    if (trim) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            [self trimFrames];
        });
    }
}

/**
 * Держит каталог в пределах потолка, выбрасывая самое давнее.
 *
 * Кадр весит куда больше своего джипега — под четыреста килобайт против
 * двадцати трёх, — и без присмотра каталог рос бы до последнего свободного
 * байта на устройстве.
 */
+ (void)trimFrames {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *directory = [self frameDirectory];

    NSArray *names = [manager contentsOfDirectoryAtPath:directory error:NULL];

    NSMutableArray *files = [NSMutableArray array];

    unsigned long long total = 0;

    for (NSString *name in names) {
        NSString *path = [directory stringByAppendingPathComponent:name];

        NSDictionary *attributes = [manager attributesOfItemAtPath:path error:NULL];

        if (attributes == nil) {
            continue;
        }

        unsigned long long size = [attributes fileSize];

        total += size;

        [files addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            path, @"path",
            [attributes fileModificationDate] ?: [NSDate distantPast], @"date",
            [NSNumber numberWithUnsignedLongLong:size], @"size",
            nil]];
    }

    if (total <= YTFrameCacheLimit) {
        return;
    }

    [files sortUsingComparator:^NSComparisonResult(id first, id second) {
        return [[first objectForKey:@"date"] compare:[second objectForKey:@"date"]];
    }];

    NSUInteger dropped = 0;

    for (NSDictionary *file in files) {
        if (total <= YTFrameCacheLimit) {
            break;
        }

        if ([manager removeItemAtPath:[file objectForKey:@"path"] error:NULL]) {
            total -= [[file objectForKey:@"size"] unsignedLongLongValue];
            dropped++;
        }
    }

    NSLog(@"[YouTube/Превью] Кеш кадров подрезан: выброшено %lu файлов, "
          @"осталось %lu МБ",
          (unsigned long)dropped, (unsigned long)(total / 1024 / 1024));
}

+ (UIImage *)decode:(NSData *)data pixelWidth:(CGFloat)width {
    CGImageSourceRef source =
        CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);

    if (source == NULL) {
        return nil;
    }

    // `kCGImageSourceShouldCacheImmediately` сюда просится — он заставляет
    // разобрать пиксели сразу, в этом самом фоновом потоке, а не при первой
    // отрисовке. Но появился он только в iOS 7, а константа эта — символ,
    // который разрешается при загрузке приложения: на 5.1 и 6 приложение
    // не запустилось бы вовсе с «Symbol not found». Обходимся без него.
    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
        (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailFromImageAlways,
        [NSNumber numberWithInt:(int)width], (id)kCGImageSourceThumbnailMaxPixelSize,
        nil];

    CGImageRef thumbnail =
        CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);

    CFRelease(source);

    if (thumbnail == NULL) {
        return nil;
    }

    UIImage *image = nil;

    if (YTSmallMemory()) {
        image = [self repack16bit:thumbnail];
    }

    if (image == nil) {
        image = [UIImage imageWithCGImage:thumbnail];
    }

    CGImageRelease(thumbnail);

    return image;
}

/**
 * Перекладывает кадр в 16 бит на пиксель: вдвое меньше памяти, а
 * на фотографии разница не видна.
 *
 * Делается только на устройствах с небольшой памятью: там это разница между
 * работающей лентой и закрытием по памяти. На остальных лишнее преобразование
 * каждого кадра дороже сэкономленного.
 *
 * Картинки с прозрачностью через это не пропускаем, и это не мелочь.
 * В RGB555 альфы нет вовсе (`kCGImageAlphaNoneSkipFirst`), а буфер под неё
 * CoreGraphics выдаёт обнулённым, то есть чёрным. Прозрачный PNG,
 * нарисованный в такой буфер, чернеет целиком.
 */
+ (UIImage *)repack16bit:(CGImageRef)source {
    size_t width = CGImageGetWidth(source);
    size_t height = CGImageGetHeight(source);

    if (width == 0 || height == 0) {
        return nil;
    }

    CGImageAlphaInfo alpha = CGImageGetAlphaInfo(source);

    BOOL opaque = (alpha == kCGImageAlphaNone ||
                   alpha == kCGImageAlphaNoneSkipFirst ||
                   alpha == kCGImageAlphaNoneSkipLast);

    if (!opaque) {
        // Возвращаем nil — вызывающий оставит картинку как есть.
        return nil;
    }

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();

    // 5 бит на составляющую при 16 битах на пиксель — это RGB555 с одним
    // неиспользуемым битом; ближайшее к RGB565, что понимает CoreGraphics.
    CGContextRef context = CGBitmapContextCreate(
        NULL, width, height, 5, width * 2, space,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder16Little);

    CGColorSpaceRelease(space);

    if (context == NULL) {
        return nil;
    }

    CGContextDrawImage(context, CGRectMake(0, 0, width, height), source);

    CGImageRef packed = CGBitmapContextCreateImage(context);
    CGContextRelease(context);

    if (packed == NULL) {
        return nil;
    }

    UIImage *image = [UIImage imageWithCGImage:packed];
    CGImageRelease(packed);

    return image;
}

#pragma mark Замеры

/**
 * Сколько превью уже загружено и сколько на это ушло. Отношение одного
 * к другому — единственный честный ответ на вопрос «почему картинки идут
 * долго»: видно и сеть, и декодирование.
 */
/**
 * Всего загружено за запуск — и то же самое за последнюю двадцатку.
 *
 * Средние считаются по двадцатке, а не за всё время: связь по дороге
 * меняется — сеть, VPN, вышка, — и накопленное среднее показывает
 * позавчерашнюю погоду вместо нынешней.
 */
static NSInteger YTLoadedCount = 0;
static NSInteger YTBatchCount = 0;

static NSTimeInterval YTLoadedSeconds = 0;
static NSTimeInterval YTNetSeconds = 0;
static NSTimeInterval YTWaitSeconds = 0;
static NSTimeInterval YTBatchStarted = 0;
static long long YTLoadedBytes = 0;

/** Счётчик проверок доверия на прошлом отчёте — чтобы считать разницу. */
static NSInteger YTLastTrustChecks = 0;
static NSTimeInterval YTLastTrustSeconds = 0;

/**
 * Сетевое время делится надвое: ожидание ответа и приём тела.
 *
 * Половины эти лечатся разным. Долгое ожидание — это дорога до сервера
 * и его раздумья; долгий приём — размер картинки. А третья доля,
 * декодер, к сети не относится вовсе, и на неспешном железе она же
 * и главная: её видно только порознь.
 */
+ (void)recordStarted:(NSTimeInterval)started
              headers:(NSTimeInterval)headers
           downloaded:(NSTimeInterval)downloaded
                bytes:(NSUInteger)bytes {
    @synchronized (self) {
        NSTimeInterval now = CFAbsoluteTimeGetCurrent();

        if (YTBatchCount == 0) {
            YTBatchStarted = started;
        }

        YTLoadedCount++;
        YTBatchCount++;
        YTLoadedSeconds += now - started;
        YTNetSeconds += downloaded - started;
        YTLoadedBytes += bytes;

        // Заголовков могло и не быть — ответ из кеша приходит сразу телом.
        if (headers > started) {
            YTWaitSeconds += headers - started;
        }

        if (YTBatchCount < 25) {
            return;
        }

        /**
         * Скорость — за последние двадцать пять картинок.
         *
         * Прежде она считалась от самой первой за запуск, а между
         * порциями приложение просто ждёт человека: пока он не листает,
         * картинки не нужны. Простой попадал в делитель, и «1 в секунду»
         * означало не медленную загрузку, а долгий взгляд на экран.
         */
        NSTimeInterval wall = now - YTBatchStarted;
        long perSecond = wall > 0 ? (long)(YTBatchCount / wall) : 0;

        /**
         * Проверка цепочки — приписка, и только когда она была.
         *
         * Обычно её нет вовсе: система разбирает цепочку сама и нас
         * не спрашивает, так что нули в строке означали бы не «соединений
         * не было», а «нас не спросили». Такую цифру лучше не показывать,
         * чем показывать: по ней сразу тянет сделать неверный вывод.
         */
        NSInteger checks = [YTHttp trustChecks];
        NSTimeInterval checkSeconds = [YTHttp trustSeconds];

        NSInteger checksNow = checks - YTLastTrustChecks;
        NSTimeInterval checkNow = checkSeconds - YTLastTrustSeconds;

        YTLastTrustChecks = checks;
        YTLastTrustSeconds = checkSeconds;

        NSString *trust = checksNow > 0
            ? [NSString stringWithFormat:@"; проверок цепочки %ld по %ld мс",
                   (long)checksNow, (long)(checkNow * 1000 / checksNow)]
            : @"";

        NSLog(@"[YouTube/Превью] %ld штук по %ld КБ, %ld в секунду, на картинку "
              @"%ld мс (ожидание %ld, тело %ld, декодер %ld)%@",
              (long)YTLoadedCount,
              (long)(YTLoadedBytes / 1024 / YTBatchCount),
              perSecond,
              (long)(YTLoadedSeconds * 1000 / YTBatchCount),
              (long)(YTWaitSeconds * 1000 / YTBatchCount),
              (long)((YTNetSeconds - YTWaitSeconds) * 1000 / YTBatchCount),
              (long)((YTLoadedSeconds - YTNetSeconds) * 1000 / YTBatchCount),
              trust);

        YTBatchCount = 0;
        YTLoadedSeconds = 0;
        YTNetSeconds = 0;
        YTWaitSeconds = 0;
        YTLoadedBytes = 0;
    }
}

#pragma mark Загрузка

+ (UIImage *)fetch:(NSString *)url pixelWidth:(CGFloat)width {
    NSTimeInterval started = CFAbsoluteTimeGetCurrent();

    NSString *address = [self sized:url pixelWidth:width];

    /**
     * Сперва — свой кеш разобранных кадров: ни сети, ни разбора.
     *
     * Он же и объясняет, почему замер сюда не попадает: считать нечего,
     * все три доли — ожидание, тело, декодер — здесь равны нулю, и
     * попав в среднее, они рассказывали бы не о загрузке, а о том,
     * сколько раз человек прошёлся по одной и той же ленте.
     */
    UIImage *ready = [self frameFor:address width:width];

    if (ready != nil) {
        return ready;
    }

    NSMutableURLRequest *request =
        YTRequest(address, NSURLRequestUseProtocolCachePolicy, 20.0);

    YTHttpResponse *response = [YTHttp send:request bodyLimit:0];

    if (![response isSuccessful]) {
        // Выбранной ступени у этого ролика нет — берём адрес как есть.
        if (![address isEqualToString:url]) {
            return [self fetch:url pixelWidth:width];
        }

        NSLog(@"[YouTube/Превью] Не забралось (%ld): %@",
              (long)response.statusCode, address);

        return nil;
    }

    NSTimeInterval downloaded = CFAbsoluteTimeGetCurrent();

    UIImage *image = [self decode:response.body pixelWidth:width];

    if (image == nil) {
        /**
         * Ответ пришёл, а картинки из него не вышло. Почти всегда это
         * формат, которого система не знает: WebP до iOS 14, AVIF и далее.
         * Первые байты в журнал — по ним формат опознаётся сразу
         * («RIFF» это WebP, 0xFFD8 — JPEG, 0x89PNG — PNG).
         */
        const uint8_t *head = [response.body bytes];

        NSLog(@"[YouTube/Превью] Не разобралось (%lu байт, %02X %02X %02X %02X): %@",
              (unsigned long)[response.body length],
              [response.body length] > 3 ? head[0] : 0,
              [response.body length] > 3 ? head[1] : 0,
              [response.body length] > 3 ? head[2] : 0,
              [response.body length] > 3 ? head[3] : 0,
              address);

        return nil;
    }

    [self recordStarted:started
                headers:response.headersAt
             downloaded:downloaded
                  bytes:[response.body length]];

    [self storeFrame:image for:address width:width];

    return image;
}

/**
 * Адреса, которые уже не отвечали.
 *
 * Без этого списка неудача повторялась при каждом появлении карточки
 * на экране: список переиспользует ячейки, ячейка при каждой привязке
 * просит картинку заново, и один и тот же 404 уходил в сеть по восемь раз
 * на прокрутку. Ошибка при этом не «пока не получилось», а окончательная:
 * превью, которого нет, не появится и через минуту.
 *
 * Список не растёт бесконечно: он очищается вместе с кешем картинок —
 * то есть по нехватке памяти.
 */
+ (NSMutableSet *)failures {
    static NSMutableSet *failures = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{ failures = [[NSMutableSet alloc] init]; });

    return failures;
}

+ (BOOL)hasFailed:(NSString *)url {
    NSMutableSet *failures = [self failures];

    @synchronized (failures) {
        return [failures containsObject:url];
    }
}

+ (void)rememberFailure:(NSString *)url {
    NSMutableSet *failures = [self failures];

    @synchronized (failures) {
        // Потолок на всякий случай: за долгий сеанс список не должен
        // становиться заметной величиной.
        if ([failures count] > 2000) {
            [failures removeAllObjects];
        }

        [failures addObject:url];
    }
}

+ (UIImage *)download:(NSString *)url pixelWidth:(CGFloat)width {
    UIImage *image = [self fetch:url pixelWidth:width];

    if (image == nil) {
        [self rememberFailure:url];

        return nil;
    }

    CGFloat have = CGImageGetWidth([image CGImage]);

    // Исходник оказался мельче запрошенного — больше не просим.
    if (have < width) {
        @synchronized ([self exhausted]) {
            [[self exhausted] addObject:url];
        }
    }

    NSUInteger cost = (NSUInteger)(have * CGImageGetHeight([image CGImage]) *
                                   (YTSmallMemory() ? 2 : 4));

    [[self cache] setObject:image forKey:url cost:cost];

    return image;
}

#pragma mark Точки входа

+ (CGFloat)pixelWidthFor:(CGFloat)targetWidth {
    CGFloat scale = 1.0;

    if ([[UIScreen mainScreen] respondsToSelector:@selector(scale)]) {
        scale = [[UIScreen mainScreen] scale];
    }

    /**
     * Ширина по умолчанию нужна не для красоты: карточка нередко просит
     * картинку до первой раскладки, когда её ширина ещё нулевая.
     * С нулём загрузчик просил у CDN самую мелкую ступень, а декодер
     * с потолком в ноль пикселей не разбирал и её — картинки не было
     * вовсе, причём при совершенно исправном ответе.
     *
     * А вот поднимать до ста двадцати **названную** ширину нельзя.
     * Кружок канала просят в сорок точек — на удвоенном экране это
     * восемьдесят пикселей, ступень `s88`. Со старой границей выходило
     * сто двадцать точек, двести сорок пикселей и ступень `s240`:
     * вчетверо больше точек, чем помещается, и вчетверо больше памяти
     * под каждую картинку. В дампе это видно прямо — все кружки
     * приезжали с пометкой `=s240-`.
     */
    CGFloat asked = (targetWidth > 0) ? targetWidth : (CGFloat)120;

    CGFloat width = MIN(MAX(asked, (CGFloat)40), YTMaxDecodeWidth()) * scale;

    /**
     * Выбранное в настройках качество превью — потолок, а не замена:
     * просить у CDN больше, чем помещается на экране, незачем и так,
     * а «низкое» здесь означает «не выше этого», как и в оригинале,
     * где `ThumbnailQuality` тоже ограничивает ступень.
     */
    NSInteger chosen = [YTSettings thumbnailWidth];

    if (chosen > 0) {
        width = MIN(width, (CGFloat)chosen);
    }

    return width;
}

+ (void)loadInto:(UIView<YTImageTarget> *)view
             url:(NSString *)url
     targetWidth:(CGFloat)targetWidth {
    if (view == nil) {
        return;
    }

    // Какой адрес сейчас ждёт эта карточка. Связанный объект вместо таблицы
    // со слабыми ключами: NSMapTable появилась только в iOS 6, а здесь метка
    // и так живёт ровно столько же, сколько сама карточка.
    objc_setAssociatedObject(view, (__bridge const void *)YTImageTag,
                             url, OBJC_ASSOCIATION_COPY_NONATOMIC);

    if ([url length] == 0) {
        [view setImage:nil];
        return;
    }

    CGFloat width = [self pixelWidthFor:targetWidth];

    UIImage *ready = [self cachedFor:url pixelWidth:width];

    if (ready != nil) {
        [view setImage:ready];
        return;
    }

    [view setImage:nil];

    // Этот адрес уже не отвечал — второй раз не спрашиваем.
    if ([self hasFailed:url]) {
        return;
    }

    __weak UIView<YTImageTarget> *weakView = view;

    [[self queue] push:^{
        @autoreleasepool {
            // Пока запрос ждал очереди, карточку могли отдать другому ролику.
            UIView<YTImageTarget> *target = weakView;

            if (target == nil) {
                return;
            }

            NSString *wanted = objc_getAssociatedObject(target,
                                                        (__bridge const void *)YTImageTag);

            if (![wanted isEqualToString:url]) {
                return;
            }

            UIImage *image = nil;

            @synchronized ([self lockFor:url]) {
                // Пока ждали замок, картинку мог принести соседний поток.
                image = [self cachedFor:url pixelWidth:width];

                if (image == nil) {
                    image = [self download:url pixelWidth:width];
                }
            }

            if (image == nil) {
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                UIView<YTImageTarget> *late = weakView;
                NSString *still = objc_getAssociatedObject(late,
                                                           (__bridge const void *)YTImageTag);

                if ([still isEqualToString:url]) {
                    [late setImage:image];
                }
            });
        }
    }];
}

+ (void)loadUrl:(NSString *)url
    targetWidth:(CGFloat)targetWidth
     completion:(void (^)(UIImage *image))completion {
    if ([url length] == 0) {
        completion(nil);
        return;
    }

    CGFloat width = [self pixelWidthFor:targetWidth];

    UIImage *ready = [self cachedFor:url pixelWidth:width];

    if (ready != nil) {
        completion(ready);
        return;
    }

    [[self queue] push:^{
        @autoreleasepool {
            UIImage *image = nil;

            @synchronized ([self lockFor:url]) {
                image = [self cachedFor:url pixelWidth:width];

                if (image == nil) {
                    image = [self download:url pixelWidth:width];
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                completion(image);
            });
        }
    }];
}

+ (void)dropCache {
    [[self cache] removeAllObjects];

    @synchronized ([self exhausted]) {
        [[self exhausted] removeAllObjects];
    }
}

+ (void)trim {
    [[self cache] removeAllObjects];

    // Список неудач уходит вместе с кешем: если память кончилась, то и
    // повторить попытку не грех — вдруг за это время превью появилось.
    NSMutableSet *failures = [self failures];

    @synchronized (failures) {
        [failures removeAllObjects];
    }
}

@end
