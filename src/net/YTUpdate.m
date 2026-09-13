#import "YTUpdate.h"

#import "YTHttp.h"
#import "YTStrings.h"

#include <CommonCrypto/CommonDigest.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>

extern char **environ;

static NSString *const YTUpdateBetaKey = @"YTUpdateBeta";
static NSString *const YTUpdateSeenKey = @"YTUpdateSeenVersion";
static NSString *const YTUpdateAskedKey = @"YTUpdateAskedAt";

/** Наш пакет — по этому имени его ищут и в `dpkg`, и в списке источника. */
static NSString *const YTPackage = @"ru.computershik.troubadour";

static NSString *const YTRepo = @"https://computershik73.github.io/repo/";

@implementation YTUpdate

#pragma mark Версия установленного

/**
 * Где `dpkg` держит свою опись.
 *
 * На старых джейлбрейках это `/var/lib/dpkg`, на новых — он же, но через
 * ссылку `/Library/dpkg`; на rootless-сборках всё лежит под `/var/jb`.
 * Перебираем известные места и берём первое, где файл есть.
 */
+ (NSString *)statusPath {
    NSArray *places = [NSArray arrayWithObjects:
        @"/var/lib/dpkg/status",
        @"/Library/dpkg/status",
        @"/var/jb/var/lib/dpkg/status",
        @"/var/jb/Library/dpkg/status", nil];

    NSFileManager *files = [NSFileManager defaultManager];

    for (NSString *path in places) {
        if ([files fileExistsAtPath:path]) {
            return path;
        }
    }

    return nil;
}

/**
 * Значение поля в описи пакета.
 *
 * Опись — это записи, разделённые пустой строкой, в каждой строки вида
 * `Поле: значение`. Разбираем ровно столько, сколько нужно: найти запись
 * своего пакета и взять из неё версию.
 */
+ (NSString *)field:(NSString *)name inStanza:(NSString *)stanza {
    NSString *prefix = [name stringByAppendingString:@": "];

    for (NSString *line in [stanza componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:prefix]) {
            return [[line substringFromIndex:[prefix length]]
                stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]];
        }
    }

    return nil;
}

+ (NSString *)installedVersion {
    NSString *path = [self statusPath];

    NSString *text = (path != nil)
        ? [NSString stringWithContentsOfFile:path
                                    encoding:NSUTF8StringEncoding error:NULL]
        : nil;

    if ([text length] > 0) {
        for (NSString *stanza in [text componentsSeparatedByString:@"\n\n"]) {
            if (![[self field:@"Package" inStanza:stanza] isEqualToString:YTPackage]) {
                continue;
            }

            /**
             * Пакет мог быть удалён, но запись о нём осталась: `dpkg`
             * помнит снятые пакеты со статусом `deinstall`. Такую версию
             * за установленную считать нельзя.
             */
            NSString *state = [self field:@"Status" inStanza:stanza];

            if (state != nil && [state rangeOfString:@"installed"].location == NSNotFound) {
                continue;
            }

            NSString *version = [self field:@"Version" inStanza:stanza];

            if ([version length] > 0) {
                return version;
            }
        }
    }

    /**
     * Описи нет или нас в ней нет — остаётся связка.
     *
     * Там короткая версия без номера сборки, и сравнение с источником
     * по ней даст «обновление есть» на любую бету. Это лучше, чем молчать:
     * человек хотя бы увидит, что свежее существует.
     */
    NSString *plist = [[[NSBundle mainBundle] infoDictionary]
        objectForKey:@"CFBundleVersion"];

    return [plist length] > 0 ? plist : @"0";
}

#pragma mark Канал

+ (BOOL)usesBeta {
    NSUserDefaults *store = [NSUserDefaults standardUserDefaults];
    id kept = [store objectForKey:YTUpdateBetaKey];

    if (kept != nil) {
        return [kept boolValue];
    }

    /**
     * Не выбирали — смотрим, что стоит.
     *
     * У отладочных сборок версия оканчивается на `+debug`, и они лежат
     * только в канале бет. Ставить такому человеку выпуски значило бы
     * при первом же обновлении молча увести его с канала, на котором он
     * сидит.
     */
    return [[self installedVersion] rangeOfString:@"debug"].location != NSNotFound;
}

+ (void)setUsesBeta:(BOOL)beta {
    [[NSUserDefaults standardUserDefaults] setBool:beta forKey:YTUpdateBetaKey];
}

+ (NSString *)channelUrl {
    return [self usesBeta] ? [YTRepo stringByAppendingString:@"beta/"] : YTRepo;
}

#pragma mark Сравнение версий

/**
 * Порядок знаков по правилам dpkg.
 *
 * Буквы идут раньше всего остального, а тильда — раньше пустоты: это
 * нужно, чтобы `1.0~rc1` оказалась старше `1.0`. Нам хватило бы и
 * простого сравнения, но правило дешёвое, а расхождение с `dpkg`
 * однажды обернулось бы «обновление есть всегда».
 */
static int YTVersionOrder(unichar letter) {
    if (letter == '~') { return -1; }
    if (letter == 0)   { return 0; }

    if ((letter >= 'a' && letter <= 'z') || (letter >= 'A' && letter <= 'Z')) {
        return (int)letter;
    }

    return (int)letter + 256;
}

static NSComparisonResult YTCompareChunk(NSString *left, NSString *right) {
    NSUInteger a = 0;
    NSUInteger b = 0;

    while (a < [left length] || b < [right length]) {
        // Сперва кусок без цифр — знак за знаком, по порядку выше.
        while (a < [left length] || b < [right length]) {
            unichar one = 0;
            unichar two = 0;

            if (a < [left length]) {
                one = [left characterAtIndex:a];

                if (one >= '0' && one <= '9') { one = 0; }
            }

            if (b < [right length]) {
                two = [right characterAtIndex:b];

                if (two >= '0' && two <= '9') { two = 0; }
            }

            if (one == 0 && two == 0) {
                break;
            }

            int first = YTVersionOrder(one);
            int second = YTVersionOrder(two);

            if (first != second) {
                return first < second ? NSOrderedAscending : NSOrderedDescending;
            }

            if (one != 0) { a++; }
            if (two != 0) { b++; }
        }

        // Затем кусок из цифр — числом, а не строкой: 99 меньше 206.
        NSUInteger fromA = a;
        NSUInteger fromB = b;

        while (a < [left length] &&
               [left characterAtIndex:a] >= '0' && [left characterAtIndex:a] <= '9') {
            a++;
        }

        while (b < [right length] &&
               [right characterAtIndex:b] >= '0' && [right characterAtIndex:b] <= '9') {
            b++;
        }

        long long one = [[left substringWithRange:NSMakeRange(fromA, a - fromA)]
            longLongValue];
        long long two = [[right substringWithRange:NSMakeRange(fromB, b - fromB)]
            longLongValue];

        if (one != two) {
            return one < two ? NSOrderedAscending : NSOrderedDescending;
        }

        if (fromA == a && fromB == b) {
            break;
        }
    }

    return NSOrderedSame;
}

+ (NSComparisonResult)compareVersion:(NSString *)left with:(NSString *)right {
    if ([left length] == 0 || [right length] == 0) {
        return NSOrderedSame;
    }

    // Эпоху отбрасываем: у наших пакетов её нет, а правила с ней те же.
    NSArray *a = [left componentsSeparatedByString:@"-"];
    NSArray *b = [right componentsSeparatedByString:@"-"];

    NSComparisonResult head = YTCompareChunk([a objectAtIndex:0],
                                             [b objectAtIndex:0]);

    if (head != NSOrderedSame) {
        return head;
    }

    NSString *tailA = [a count] > 1
        ? [[a subarrayWithRange:NSMakeRange(1, [a count] - 1)]
              componentsJoinedByString:@"-"] : @"";
    NSString *tailB = [b count] > 1
        ? [[b subarrayWithRange:NSMakeRange(1, [b count] - 1)]
              componentsJoinedByString:@"-"] : @"";

    return YTCompareChunk(tailA, tailB);
}

#pragma mark Проверка

+ (void)check:(void (^)(NSDictionary *found))found {
    if (found == nil) {
        return;
    }

    NSString *channel = [self channelUrl];
    NSString *mine = [self installedVersion];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSString *index = [channel stringByAppendingString:@"Packages"];

        /**
         * Список просим свежий.
         *
         * GitHub Pages отдаёт его с долгим сроком хранения, и кэш
         * системы показал бы вчерашний — а бета выходит по нескольку
         * штук в день.
         *
         * Запрос собирается `YTRequest`: класс запроса берётся по имени
         * в исполнении, а не привязывается при сборке — на нашем наборе
         * заголовков его символа нет вовсе.
         */
        NSMutableURLRequest *request = YTRequest(index,
            NSURLRequestReloadIgnoringLocalCacheData, 20.0);

        if (request == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{ found(nil); });

            return;
        }

        YTHttpResponse *answer = [YTHttp send:request bodyLimit:0];

        NSDictionary *best = nil;

        if ([answer isSuccessful] && [answer.body length] > 0) {
            best = [self bestIn:[[NSString alloc] initWithData:answer.body
                                                      encoding:NSUTF8StringEncoding]
                        channel:channel
                          newer:mine];
        } else {
            NSLog(@"[YouTube/Обновление] Список не забрался: код %ld",
                  (long)answer.statusCode);
        }

        NSLog(@"[YouTube/Обновление] Стоит %@, в источнике %@ (%@)", mine,
              best != nil ? [best objectForKey:@"version"] : @"ничего новее",
              [self usesBeta] ? @"беты" : @"выпуски");

        dispatch_async(dispatch_get_main_queue(), ^{ found(best); });
    });
}

/**
 * Самая свежая запись нашего пакета в списке источника.
 *
 * Список перечисляет **все** сборки подряд — их там под полторы сотни, —
 * и последняя в файле не обязана быть старшей. Поэтому идём по всем
 * и держим наибольшую.
 */
+ (NSDictionary *)bestIn:(NSString *)text
                 channel:(NSString *)channel
                   newer:(NSString *)mine {
    NSDictionary *best = nil;
    NSString *bestVersion = mine;

    for (NSString *stanza in [text componentsSeparatedByString:@"\n\n"]) {
        if (![[self field:@"Package" inStanza:stanza] isEqualToString:YTPackage]) {
            continue;
        }

        NSString *version = [self field:@"Version" inStanza:stanza];
        NSString *file = [self field:@"Filename" inStanza:stanza];

        if ([version length] == 0 || [file length] == 0) {
            continue;
        }

        if ([self compareVersion:version with:bestVersion] != NSOrderedDescending) {
            continue;
        }

        bestVersion = version;

        best = [NSDictionary dictionaryWithObjectsAndKeys:
            version, @"version",
            [channel stringByAppendingString:file], @"url",
            [NSNumber numberWithLongLong:
                [[self field:@"Size" inStanza:stanza] longLongValue]], @"size",
            [[self field:@"SHA256" inStanza:stanza] lowercaseString] ?: @"", @"sha256",
            nil];
    }

    return best;
}

#pragma mark Установка

+ (NSString *)helperPath {
    return [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"iconswitch"];
}

+ (BOOL)canInstall {
    NSFileManager *files = [NSFileManager defaultManager];

    if (![files isExecutableFileAtPath:[self helperPath]]) {
        return NO;
    }

    NSArray *places = [NSArray arrayWithObjects:
        @"/usr/bin/dpkg", @"/var/jb/usr/bin/dpkg", nil];

    for (NSString *path in places) {
        if ([files fileExistsAtPath:path]) {
            return YES;
        }
    }

    return NO;
}

/** Куда кладём скачанное: свой угол в `Library`, не на глаза человеку. */
+ (NSString *)downloadPath {
    NSString *root = [NSSearchPathForDirectoriesInDomains(
        NSLibraryDirectory, NSUserDomainMask, YES) lastObject];

    NSString *folder = [root stringByAppendingPathComponent:@"Update"];

    [[NSFileManager defaultManager] createDirectoryAtPath:folder
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];

    return [folder stringByAppendingPathComponent:@"update.deb"];
}

+ (NSString *)sha256Of:(NSData *)data {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];

    CC_SHA256([data bytes], (CC_LONG)[data length], digest);

    NSMutableString *text = [NSMutableString string];

    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [text appendFormat:@"%02x", digest[i]];
    }

    return text;
}

+ (void)install:(NSDictionary *)found
          state:(void (^)(NSString *what))state
           done:(void (^)(NSString *failure))done {
    if (found == nil || done == nil) {
        return;
    }

    NSString *url = [found objectForKey:@"url"];
    NSString *want = [found objectForKey:@"sha256"];
    long long size = [[found objectForKey:@"size"] longLongValue];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (state != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                state(YTLoc(@"Скачиваем…"));
            });
        }

        NSMutableURLRequest *request = YTRequest(url,
            NSURLRequestReloadIgnoringLocalCacheData, 120.0);

        if (request == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(YTLoc(@"Неверный адрес пакета"));
            });

            return;
        }

        YTHttpResponse *answer = [YTHttp send:request bodyLimit:0];

        if (![answer isSuccessful] || [answer.body length] == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(YTLoc(@"Пакет не скачался"));
            });

            return;
        }

        /**
         * Сверяем то, что приехало, с тем, что обещано.
         *
         * Пакет уходит к `dpkg` с правами root, и класть туда что попало
         * нельзя. Размер и сводка названы в том же списке, по которому мы
         * узнали о новой версии, — проверить их стоит одного прохода.
         */
        if (size > 0 && (long long)[answer.body length] != size) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(YTLoc(@"Скачанное не совпало по размеру"));
            });

            return;
        }

        if ([want length] == 64 &&
            ![[self sha256Of:answer.body] isEqualToString:want]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(YTLoc(@"Скачанное не совпало по контрольной сумме"));
            });

            return;
        }

        NSString *path = [self downloadPath];

        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];

        if (![answer.body writeToFile:path atomically:YES]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(YTLoc(@"Не удалось сохранить пакет"));
            });

            return;
        }

        if (state != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                state(YTLoc(@"Устанавливаем…"));
            });
        }

        int code = [self runHelperOn:path];

        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];

        dispatch_async(dispatch_get_main_queue(), ^{
            done(code == 0 ? nil : [NSString stringWithFormat:
                YTLoc(@"Установка не удалась (код %d)"), code]);
        });
    });
}

/**
 * Запуск помощника и его код возврата.
 *
 * Вывод уводим в файл: канал пришлось бы читать, пока `dpkg` пишет,
 * а работа тут короткая и нас интересует только «получилось или нет».
 * Сам вывод остаётся на диске — по нему видно, на чём `dpkg` споткнулся.
 */
+ (int)runHelperOn:(NSString *)deb {
    NSString *log = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"update.out"];

    posix_spawn_file_actions_t actions;

    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO,
                                     [log fileSystemRepresentation],
                                     O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);

    NSString *tool = [self helperPath];

    char *argv[4];

    argv[0] = strdup([tool fileSystemRepresentation]);
    argv[1] = strdup("install");
    argv[2] = strdup([deb fileSystemRepresentation]);
    argv[3] = NULL;

    pid_t child = 0;

    int started = posix_spawn(&child, [tool fileSystemRepresentation],
                              &actions, NULL, argv, environ);

    free(argv[0]);
    free(argv[1]);
    free(argv[2]);

    posix_spawn_file_actions_destroy(&actions);

    if (started != 0) {
        NSLog(@"[YouTube/Обновление] Помощник не запустился: %s", strerror(started));

        return -1;
    }

    int status = 0;

    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
        // Ожидание прервал сигнал — ждём дальше.
    }

    NSString *said = [NSString stringWithContentsOfFile:log
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];

    if ([said length] > 0) {
        NSLog(@"[YouTube/Обновление] dpkg: %@",
              [said stringByTrimmingCharactersInSet:
                  [NSCharacterSet whitespaceAndNewlineCharacterSet]]);
    }

    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

#pragma mark Проверка при запуске

+ (NSString *)announcedVersion {
    return [[NSUserDefaults standardUserDefaults] stringForKey:YTUpdateSeenKey];
}

+ (void)setAnnouncedVersion:(NSString *)version {
    [[NSUserDefaults standardUserDefaults] setObject:(version ?: @"")
                                              forKey:YTUpdateSeenKey];
}

+ (void)checkOnLaunch {
    if (![self canInstall]) {
        return;
    }

    NSUserDefaults *store = [NSUserDefaults standardUserDefaults];

    NSTimeInterval last = [store doubleForKey:YTUpdateAskedKey];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    if (last > 0 && now - last < 6 * 3600) {
        return;
    }

    [store setDouble:now forKey:YTUpdateAskedKey];

    [self check:^(NSDictionary *best) {
        if (best == nil) {
            return;
        }

        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"YTUpdateFound" object:best];
    }];
}

@end
