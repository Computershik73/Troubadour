#import "YTCrashWatch.h"

#ifdef YT_NO_LOG

// Готовая сборка журнала не пишет — и следить ей не за чем.
void YTCrashWatchStart(void) {}
void YTCrashWatchForeground(BOOL foreground) {}
void YTCrashWatchClean(void) {}
void YTCrashWatchUpdating(void) {}

#else

#import <UIKit/UIKit.h>

#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

/** Пути — заранее, строками C: в обработчике сигнала Objective-C нельзя. */
static char YTCrashLogPath[1024];
static char YTCrashMarkPath[1024];

static volatile sig_atomic_t YTCrashHandling = 0;
static NSUncaughtExceptionHandler *YTCrashPreviousHandler = NULL;
static NSTimeInterval YTCrashLaunchedAt = 0;

/** Где лежат отчёты системы: на iOS 5–16 одно и то же место. */
static NSString *const YTCrashReports = @"/var/mobile/Library/Logs/CrashReporter";

/** Последний отчёт системы, уже переписанный в журнал. */
static NSString *const YTCrashSeenKey = @"YTCrashReportSeen";

static NSString *YTCrashFolder(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)
            objectAtIndex:0];
}

static NSString *YTCrashStatePath(void) {
    return [YTCrashFolder() stringByAppendingPathComponent:@"youtube.state"];
}

#pragma mark Сигналы — только то, что можно в обработчике

static void YTCrashPut(int fd, const char *text) {
    write(fd, text, strlen(text));
}

static void YTCrashPutHex(int fd, unsigned long value) {
    char buffer[24];
    int at = (int)sizeof(buffer) - 1;

    buffer[at] = '\0';

    do {
        buffer[--at] = "0123456789abcdef"[value % 16];
        value /= 16;
    } while (value != 0 && at > 0);

    YTCrashPut(fd, buffer + at);
}

static const char *YTCrashSignalName(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS:  return "SIGBUS";
        case SIGILL:  return "SIGILL";
        case SIGFPE:  return "SIGFPE";
        case SIGABRT: return "SIGABRT";
        case SIGTRAP: return "SIGTRAP";
        default:      return "?";
    }
}

/**
 * Обработчик сигнала: строка и стек — прямо в файл журнала.
 *
 * Здесь можно только то, что не берёт замков и не выделяет памяти:
 * open, write, close, backtrace. Файл открывается по пути, а не держится
 * открытым: журнал по достижении предела переезжает в youtube-prev.log,
 * и старый описатель писал бы уже туда.
 *
 * После записи сигнал отдаётся системе как был — её отчёт о падении
 * должен появиться так же, как без нас.
 */
static void YTCrashOnSignal(int sig, siginfo_t *info, void *context) {
    if (!YTCrashHandling) {
        YTCrashHandling = 1;

        int fd = open(YTCrashLogPath, O_WRONLY | O_APPEND | O_CREAT, 0644);

        if (fd >= 0) {
            YTCrashPut(fd, "!!! [YouTube/Падение] Сигнал ");
            YTCrashPut(fd, YTCrashSignalName(sig));
            YTCrashPut(fd, ", адрес 0x");
            YTCrashPutHex(fd, (unsigned long)(info != NULL ? info->si_addr : 0));
            YTCrashPut(fd, ", стек:\n");

            void *frames[64];
            int count = backtrace(frames, 64);

            backtrace_symbols_fd(frames, count, fd);
            close(fd);
        }

        int mark = open(YTCrashMarkPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);

        if (mark >= 0) {
            YTCrashPut(mark, "сигнал ");
            YTCrashPut(mark, YTCrashSignalName(sig));
            close(mark);
        }
    }

    signal(sig, SIG_DFL);
    raise(sig);
}

/**
 * Необработанное исключение — со стеком, и записью сразу.
 *
 * `YTLogWriteNow` ждёт очередь журнала, а очередь последовательная:
 * всё, что стояло в ней до исключения, ляжет в файл раньше.
 */
static void YTCrashOnException(NSException *exception) {
    YTCrashHandling = 1;

    YTLogWriteNow(@"!!! [YouTube/Падение] Исключение %@: %@\n%@",
                  [exception name], [exception reason],
                  [[exception callStackSymbols] componentsJoinedByString:@"\n"]);

    [[NSString stringWithFormat:@"исключение %@", [exception name]]
        writeToFile:[NSString stringWithUTF8String:YTCrashMarkPath]
         atomically:NO encoding:NSUTF8StringEncoding error:NULL];

    if (YTCrashPreviousHandler != NULL) {
        YTCrashPreviousHandler(exception);
    }
}

static void YTCrashInstall(void) {
    strlcpy(YTCrashLogPath, [YTLogPath() fileSystemRepresentation], sizeof(YTCrashLogPath));
    strlcpy(YTCrashMarkPath,
            [[YTCrashFolder() stringByAppendingPathComponent:@"youtube.crash"]
                fileSystemRepresentation],
            sizeof(YTCrashMarkPath));

    YTCrashPreviousHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(YTCrashOnException);

    struct sigaction action;

    memset(&action, 0, sizeof(action));
    action.sa_sigaction = YTCrashOnSignal;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);

    int signals[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP };

    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        sigaction(signals[i], &action, NULL);
    }
}

#pragma mark Состояние между запусками

static void YTCrashWriteState(NSString *state) {
    NSString *line = [NSString stringWithFormat:@"%@ %.0f %.0f", state,
                      YTCrashLaunchedAt, [[NSDate date] timeIntervalSince1970]];

    [line writeToFile:YTCrashStatePath() atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

void YTCrashWatchForeground(BOOL foreground) {
    YTCrashWriteState(foreground ? @"screen" : @"background");
}

void YTCrashWatchClean(void) {
    YTCrashWriteState(@"clean");
}

void YTCrashWatchUpdating(void) {
    YTCrashWriteState(@"update");
}

#pragma mark Отчёты системы

/** Мегабайты из страниц отчёта о памяти. */
static double YTCrashPagesMegabytes(id pages, double pageSize) {
    return [pages doubleValue] * pageSize / (1024.0 * 1024.0);
}

/**
 * Отчёт о снятии по памяти: кто сколько занимал и что сделали с нами.
 *
 * На iOS 5/6 это plist со списком процессов (`processes`: имя, страницы,
 * состояние, причина). Поздние системы пишут JSON — тогда просто
 * вынимаем строки с нашим именем.
 */
static void YTCrashTellMemory(NSString *path, NSString *name) {
    NSDictionary *report = [NSDictionary dictionaryWithContentsOfFile:path];
    NSArray *processes = [report objectForKey:@"processes"];

    if (![processes isKindOfClass:[NSArray class]]) {
        NSString *text = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding error:NULL];
        NSMutableArray *ours = [NSMutableArray array];

        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            if ([line rangeOfString:@"Troubadour"].location != NSNotFound && [ours count] < 4) {
                [ours addObject:[line stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]]];
            }
        }

        NSLog(@"[YouTube/Падение] Отчёт системы о памяти %@: %@", name,
              [ours count] > 0 ? [ours componentsJoinedByString:@" | "] : @"нас в нём нет");
        return;
    }

    double pageSize = [[report objectForKey:@"pageSize"] doubleValue];

    if (pageSize <= 0) {
        pageSize = 4096;
    }

    // Записи бывают и без страниц — `compare:` с nil уронил бы нас прямо здесь.
    NSArray *sorted = [processes sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        double left = [a isKindOfClass:[NSDictionary class]]
            ? [[a objectForKey:@"rpages"] doubleValue] : 0;
        double right = [b isKindOfClass:[NSDictionary class]]
            ? [[b objectForKey:@"rpages"] doubleValue] : 0;

        return (left > right) ? NSOrderedAscending
             : (left < right) ? NSOrderedDescending : NSOrderedSame;
    }];

    NSMutableArray *top = [NSMutableArray array];
    NSString *ours = @"нас в списке нет";

    for (NSDictionary *process in sorted) {
        if (![process isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        NSString *who = [[process objectForKey:@"name"] description] ?: @"?";
        NSString *reason = [[process objectForKey:@"reason"] description];
        NSString *state = [[process objectForKey:@"state"] description];

        NSString *entry = [NSString stringWithFormat:@"%@ %.0f МБ%@%@", who,
                           YTCrashPagesMegabytes([process objectForKey:@"rpages"], pageSize),
                           [state length] > 0 ? [NSString stringWithFormat:@" (%@)", state] : @"",
                           [reason length] > 0 ? [NSString stringWithFormat:@" — %@", reason] : @""];

        if ([who rangeOfString:@"Troubadour"].location != NSNotFound) {
            ours = entry;
        }

        if ([top count] < 5) {
            [top addObject:entry];
        }
    }

    NSLog(@"[YouTube/Падение] Отчёт системы о памяти %@: мы — %@; свободно %.0f МБ; "
          @"больше всех: %@", name, ours,
          YTCrashPagesMegabytes([report objectForKey:@"freePages"], pageSize),
          [top componentsJoinedByString:@", "]);
}

/**
 * Отчёт о падении: вид исключения и стек упавшего потока.
 *
 * На iOS 5/6 это plist с текстом в `description`, позже — сам текст.
 * Строку загрузки нашего бинарника берём тоже: по ней адреса стека
 * переводятся в места в коде.
 */
static void YTCrashTellCrash(NSString *path, NSString *name) {
    NSDictionary *wrapped = [NSDictionary dictionaryWithContentsOfFile:path];
    NSString *text = [wrapped objectForKey:@"description"];

    if (![text isKindOfClass:[NSString class]]) {
        text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    }

    if ([text length] == 0) {
        NSLog(@"[YouTube/Падение] Отчёт системы о падении %@ не прочитался", name);
        return;
    }

    NSMutableArray *kept = [NSMutableArray array];
    NSInteger crashedFrames = -1;
    BOOL images = NO;

    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"Exception Type"] || [line hasPrefix:@"Exception Codes"] ||
            [line hasPrefix:@"Crashed Thread"] || [line hasPrefix:@"OS Version"] ||
            [line hasPrefix:@"Hardware Model"] || [line hasPrefix:@"Version:"]) {
            [kept addObject:line];
            continue;
        }

        if ([line rangeOfString:@" Crashed:"].location != NSNotFound) {
            crashedFrames = 0;
            [kept addObject:line];
            continue;
        }

        if (crashedFrames >= 0 && crashedFrames < 30) {
            if ([line length] == 0) {
                crashedFrames = -2;
            } else {
                [kept addObject:line];
                crashedFrames++;
            }

            continue;
        }

        if ([line hasPrefix:@"Binary Images"]) {
            images = YES;
            continue;
        }

        if (images && [line rangeOfString:@"Troubadour"].location != NSNotFound) {
            [kept addObject:[@"Образ: " stringByAppendingString:
                [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]]];
            images = NO;
        }
    }

    NSLog(@"[YouTube/Падение] Отчёт системы о падении %@:\n%@", name,
          [kept componentsJoinedByString:@"\n"]);
}

/** Новые отчёты системы — с прошлого запуска, не больше трёх, без повторов. */
static void YTCrashTellReports(NSTimeInterval since) {
    NSFileManager *files = [NSFileManager defaultManager];
    NSError *failure = nil;
    NSArray *names = [files contentsOfDirectoryAtPath:YTCrashReports error:&failure];

    /**
     * Не открылась — так и пишем.
     *
     * Из IPA приложение в песочнице, и папка ему не видна, — это не беда.
     * Но молчание здесь не отличить от «отчётов нет»: в журнале 30.10.2026
     * обрыв на экране прошёл без единой строки об отчёте, и понять,
     * писала ли система что-нибудь, было нельзя.
     */
    if (names == nil) {
        NSLog(@"[YouTube/Падение] Папка отчётов системы не открылась: %@",
              [failure localizedDescription] ?: @"причина неизвестна");
        return;
    }

    NSUserDefaults *settings = [NSUserDefaults standardUserDefaults];
    NSTimeInterval seen = [settings doubleForKey:YTCrashSeenKey];
    NSTimeInterval from = MAX(seen, since - 60.0);

    NSMutableArray *fresh = [NSMutableArray array];

    // Самый свежий файл папки, чей угодно: виден ли там хоть какой-то след.
    NSString *newestName = nil;
    NSDate *newestDate = nil;

    for (NSString *name in names) {
        NSDate *date = [[files attributesOfItemAtPath:
            [YTCrashReports stringByAppendingPathComponent:name] error:NULL] fileModificationDate];

        if (date != nil && (newestDate == nil || [date compare:newestDate] == NSOrderedDescending)) {
            newestDate = date;
            newestName = name;
        }
    }

    for (NSString *name in names) {
        BOOL memory = [name hasPrefix:@"LowMemory"] || [name hasPrefix:@"JetsamEvent"];
        BOOL crash = [name hasPrefix:@"Troubadour"];

        if (!memory && !crash) {
            continue;
        }

        NSString *path = [YTCrashReports stringByAppendingPathComponent:name];
        NSDate *date = [[files attributesOfItemAtPath:path error:NULL] fileModificationDate];

        if (date == nil || [date timeIntervalSince1970] <= from) {
            continue;
        }

        [fresh addObject:[NSArray arrayWithObjects:date, name, nil]];
    }

    if ([fresh count] == 0) {
        NSLog(@"[YouTube/Падение] Свежих отчётов о нас в папке системы нет "
              @"(файлов %lu, самый новый: %@ от %@)", (unsigned long)[names count],
              newestName ?: @"—", newestDate ?: (id)@"—");
        return;
    }

    [fresh sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [[a objectAtIndex:0] compare:[b objectAtIndex:0]];
    }];

    NSArray *latest = [fresh subarrayWithRange:
        NSMakeRange([fresh count] > 3 ? [fresh count] - 3 : 0, MIN([fresh count], (NSUInteger)3))];

    for (NSArray *entry in latest) {
        NSString *name = [entry objectAtIndex:1];
        NSString *path = [YTCrashReports stringByAppendingPathComponent:name];

        if ([name hasPrefix:@"Troubadour"]) {
            YTCrashTellCrash(path, name);
        } else {
            YTCrashTellMemory(path, name);
        }
    }

    [settings setDouble:[[[latest lastObject] objectAtIndex:0] timeIntervalSince1970]
                 forKey:YTCrashSeenKey];
}

#pragma mark Запуск

void YTCrashWatchStart(void) {
    YTCrashLaunchedAt = [[NSDate date] timeIntervalSince1970];

    NSString *statePath = YTCrashStatePath();
    NSString *markPath = [YTCrashFolder() stringByAppendingPathComponent:@"youtube.crash"];

    NSString *state = [NSString stringWithContentsOfFile:statePath
                                                encoding:NSUTF8StringEncoding error:NULL];
    NSString *mark = [NSString stringWithContentsOfFile:markPath
                                               encoding:NSUTF8StringEncoding error:NULL];

    NSArray *parts = [state componentsSeparatedByString:@" "];
    NSString *how = ([parts count] > 0) ? [parts objectAtIndex:0] : nil;
    NSTimeInterval launched = ([parts count] > 1) ? [[parts objectAtIndex:1] doubleValue] : 0;
    NSTimeInterval last = ([parts count] > 2) ? [[parts objectAtIndex:2] doubleValue] : 0;

    if ([mark length] > 0) {
        NSLog(@"[YouTube/Падение] Прошлый запуск упал: %@ — подробности выше в журнале, "
              @"строкой «!!!»", mark);
    } else if ([how isEqualToString:@"screen"]) {
        NSLog(@"[YouTube/Падение] Прошлый запуск оборвался на экране без записи о падении — "
              @"так выглядит снятие системой (память) или SIGKILL");
    } else if ([how isEqualToString:@"background"]) {
        NSLog(@"[YouTube/Падение] Прошлый запуск кончился в фоне — фоновые система вправе снимать");
    } else if ([how isEqualToString:@"update"]) {
        NSLog(@"[YouTube/Падение] Прошлый запуск закончился установкой обновления — это не обрыв");
    }

    if (last > 0 && ![how isEqualToString:@"clean"] && ![how isEqualToString:@"update"]) {
        NSLog(@"[YouTube/Падение] Прошлый запуск: с %@ по последнюю отметку %@",
              [NSDate dateWithTimeIntervalSince1970:launched],
              [NSDate dateWithTimeIntervalSince1970:last]);
    }

    [[NSFileManager defaultManager] removeItemAtPath:markPath error:NULL];

    YTCrashTellReports(launched > 0 ? launched : YTCrashLaunchedAt - 2 * 86400.0);

    YTCrashInstall();
    YTCrashWriteState(@"screen");
}

#endif
