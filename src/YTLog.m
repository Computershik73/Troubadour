#import "YTLog.h"

/**
 * Здесь NSLog нужен настоящий.
 *
 * Ключ -include подставляет YTLog.h в самое начало каждого файла, включая
 * этот, — раньше любых наших строк. Поэтому объявить что-либо «до» подмены
 * нельзя, её можно только снять, и делается это здесь.
 */
#undef NSLog

/**
 * И собственные имена тоже: в молчаливой сборке они подменены пустышкой,
 * а пустышка на месте определения превратила бы его в бессмыслицу.
 * Сами определения остаются в любой сборке — они коротки, а звать их
 * оттуда просто некому.
 */
#undef YTLogWrite
#undef YTLogWriteNow

#ifdef YT_NO_LOG

/**
 * Молчаливая сборка: имена остаются, дела за ними нет.
 *
 * Вызовы NSLog до сюда не доходят вовсе — их выбросил разбор, — но пустые
 * определения оставлены нарочно. Во-первых, на них может сослаться код,
 * забывший про пометку, и такая ссылка должна связаться, а не свалить
 * сборку в непонятную ошибку компоновщика. Во-вторых, так видно с одного
 * взгляда: в готовой сборке журнал не «пишется тихо», его нет —
 * ни очереди, ни файла, ни даже пути к нему.
 */
NSString *YTLogPath(void) {
    return @"";
}

void YTLogClear(void) {
}

void YTLogWrite(NSString *format, ...) {
}

void YTLogWriteNow(NSString *format, ...) {
}

#else

/**
 * Потолок на размер журнала.
 *
 * Приложение пишет немало — каждый запрос к InnerTube, каждая порция превью, —
 * и без потолка файл рос бы неограниченно. По достижении предела он
 * откладывается в сторону и начинается новый: так под рукой всегда есть
 * не меньше полумегабайта истории, а больше мегабайта файлы не занимают.
 */
static const unsigned long long YTLogLimit = 512 * 1024;

static NSString *YTLogFolder(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES);
    return [paths objectAtIndex:0];
}

NSString *YTLogPath(void) {
    return [YTLogFolder() stringByAppendingPathComponent:@"youtube.log"];
}

static NSString *YTLogPreviousPath(void) {
    return [YTLogFolder() stringByAppendingPathComponent:@"youtube-prev.log"];
}

/** Очередь одна на всё: писать в файл из нескольких потоков разом нельзя. */
static dispatch_queue_t YTLogQueue(void) {
    static dispatch_queue_t queue = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        queue = dispatch_queue_create("ru.computershik.troubadour.log", DISPATCH_QUEUE_SERIAL);
    });

    return queue;
}

static NSDateFormatter *YTLogClock(void) {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"HH:mm:ss.SSS"];
    });

    return formatter;
}

void YTLogClear(void) {
    dispatch_sync(YTLogQueue(), ^{
        NSFileManager *manager = [NSFileManager defaultManager];

        [manager removeItemAtPath:YTLogPath() error:NULL];
        [manager removeItemAtPath:YTLogPreviousPath() error:NULL];
    });
}

/** Само письмо в файл. Зовётся только с очереди журнала. */
static void YTLogAppend(NSString *message) {
    @autoreleasepool {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                          [YTLogClock() stringFromDate:[NSDate date]], message];

        NSFileManager *manager = [NSFileManager defaultManager];
        NSString *path = YTLogPath();

        if (![manager fileExistsAtPath:path]) {
            [manager createFileAtPath:path contents:nil attributes:nil];
        }

        NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
        if (file == nil) {
            return;
        }

        unsigned long long size = [file seekToEndOfFile];
        [file writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [file closeFile];

        if (size + [line length] < YTLogLimit) {
            return;
        }

        // Предел достигнут: нынешний файл становится предыдущим.
        [manager removeItemAtPath:YTLogPreviousPath() error:NULL];
        [manager moveItemAtPath:path toPath:YTLogPreviousPath() error:NULL];
    }
}

void YTLogWrite(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);

    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];

    va_end(arguments);

    // В системный журнал тоже: при отладке через 3uTools или SSH удобнее
    // видеть строки сразу, а не доставать файл.
    NSLog(@"%@", message);

    dispatch_async(YTLogQueue(), ^{
        YTLogAppend(message);
    });
}

void YTLogWriteNow(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);

    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];

    va_end(arguments);

    NSLog(@"%@", message);

    dispatch_sync(YTLogQueue(), ^{
        YTLogAppend(message);
    });
}

#endif
