#import "YTAppIcon.h"

#import "YTSettings.h"
#import "YTZip.h"

#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>

extern char **environ;

/** Размеры значков — те же, что перечислены в `CFBundleIconFiles`. */
static const NSInteger YTIconSizes[] = { 57, 72, 76, 114, 120, 144, 152, 180 };
static const NSUInteger YTIconSizeCount = 8;

@implementation YTAppIcon

#pragma mark Места

+ (NSString *)helperPath {
    return [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"iconswitch"];
}

/**
 * Свой угол под приготовленное.
 *
 * Лежит в `Library`, а не в `Documents`: это не то, что человек кладёт
 * сам, и показывать это среди его файлов незачем.
 */
+ (NSString *)workFolder {
    NSString *root = [NSSearchPathForDirectoriesInDomains(
        NSLibraryDirectory, NSUserDomainMask, YES) lastObject];

    NSString *folder = [root stringByAppendingPathComponent:@"AppIcon"];

    [[NSFileManager defaultManager] createDirectoryAtPath:folder
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:NULL];

    return folder;
}

+ (NSString *)stagingFolder {
    NSString *folder = [[self workFolder] stringByAppendingPathComponent:@"staging"];

    [[NSFileManager defaultManager] createDirectoryAtPath:folder
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:NULL];

    return folder;
}

/** Копия выбранного значка — для предпросмотра, когда экран открыт снова. */
+ (NSString *)chosenPath {
    return [[self workFolder] stringByAppendingPathComponent:@"chosen.png"];
}

#pragma mark Состояние

+ (BOOL)helperReady {
    struct stat where;

    if (stat([[self helperPath] fileSystemRepresentation], &where) != 0) {
        return NO;
    }

    /**
     * Мало того, что файл есть, — на нём должен стоять бит setuid
     * и владельцем должен быть root. Без этого помощник запустится
     * и честно откажется: прав у него будет ровно столько же, сколько
     * у нас самих.
     */
    return (where.st_mode & S_ISUID) != 0 && where.st_uid == 0;
}

+ (BOOL)usesAlternate {
    return [YTSettings usesAlternateIcon];
}

+ (NSString *)currentName {
    /**
     * Сперва смотрим на локализованное имя, и только потом на `Info.plist`.
     *
     * Подпись под значком SpringBoard берёт из `<язык>.lproj/InfoPlist.strings`,
     * когда такой файл есть, — локализация старше. У нас их два, и пока
     * мы читали один `Info.plist`, поле показывало не то, что видно
     * на рабочем столе.
     */
    NSString *localized = [[[NSBundle mainBundle] localizedInfoDictionary]
        objectForKey:@"CFBundleDisplayName"];

    if ([localized length] > 0) {
        return localized;
    }

    NSString *plist = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Info.plist"];

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];

    NSString *name = [info objectForKey:@"CFBundleDisplayName"];

    return [name length] > 0 ? name : @"Troubadour";
}

+ (UIImage *)currentIcon {
    NSString *chosen = [self chosenPath];

    if ([self usesAlternate] &&
        [[NSFileManager defaultManager] fileExistsAtPath:chosen]) {

        UIImage *saved = [UIImage imageWithContentsOfFile:chosen];

        if (saved != nil) {
            return saved;
        }
    }

    NSString *own = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Icons/troubadour/Icon-180.png"];

    UIImage *image = [UIImage imageWithContentsOfFile:own];

    if (image != nil) {
        return image;
    }

    return [UIImage imageNamed:@"Icon-180.png"];
}

#pragma mark Тема

/**
 * Насколько запись похожа на нужный значок.
 *
 * Темы для Anemone кладут значки под именем связки приложения, которому
 * они предназначены: `IconBundles/com.google.ios.youtube.png`. Рядом
 * лежат соседи с похожими именами — музыка, студия, детский, — и они нам
 * не нужны, поэтому у них вес отрицательный.
 *
 * Крупные варианты (`@3x`, `@2x`) ценнее: значок потом уменьшается,
 * и чем крупнее исходник, тем лучше выйдут мелкие размеры.
 */
+ (NSInteger)weightForEntry:(NSString *)name {
    NSString *lower = [name lowercaseString];

    if (![lower hasSuffix:@".png"]) {
        return -1;
    }

    // Служебное добро самих архивов.
    if ([lower rangeOfString:@"__macosx"].location != NSNotFound) {
        return -1;
    }

    if ([lower rangeOfString:@"youtube"].location == NSNotFound &&
        [lower rangeOfString:@"you_tube"].location == NSNotFound) {

        return -1;
    }

    if ([lower rangeOfString:@"music"].location != NSNotFound ||
        [lower rangeOfString:@"creator"].location != NSNotFound ||
        [lower rangeOfString:@"ytcreator"].location != NSNotFound ||
        [lower rangeOfString:@"kids"].location != NSNotFound ||
        [lower rangeOfString:@"studio"].location != NSNotFound ||
        [lower rangeOfString:@"tv"].location != NSNotFound ||
        [lower rangeOfString:@"gaming"].location != NSNotFound) {

        return -1;
    }

    NSInteger weight = 1;

    if ([lower rangeOfString:@"com.google.ios.youtube"].location != NSNotFound) {
        weight += 100;
    }

    if ([lower rangeOfString:@"iconbundles/"].location != NSNotFound) {
        weight += 50;
    }

    if ([lower rangeOfString:@"@3x"].location != NSNotFound) {
        weight += 8;
    } else if ([lower rangeOfString:@"@2x"].location != NSNotFound) {
        weight += 4;
    }

    if ([lower rangeOfString:@"-large"].location != NSNotFound) {
        weight += 2;
    }

    return weight;
}

+ (UIImage *)iconFromTheme:(NSString *)archive found:(NSString **)entry {
    NSArray *names = [YTZip namesInArchive:archive];

    if ([names count] == 0) {
        NSLog(@"[YouTube/Значок] Архив не читается или пуст: %@", archive);

        return nil;
    }

    NSString *best = nil;
    NSInteger bestWeight = 0;

    for (NSString *name in names) {
        NSInteger weight = [self weightForEntry:name];

        if (weight > bestWeight) {
            bestWeight = weight;
            best = name;
        }
    }

    if (best == nil) {
        NSLog(@"[YouTube/Значок] В теме нет значка YouTube (записей %lu)",
              (unsigned long)[names count]);

        return nil;
    }

    NSData *data = [YTZip dataForEntry:best inArchive:archive];

    UIImage *image = data != nil ? [UIImage imageWithData:data] : nil;

    if (image == nil) {
        NSLog(@"[YouTube/Значок] Запись %@ не разобралась как картинка", best);

        return nil;
    }

    NSLog(@"[YouTube/Значок] Из темы взято %@ — %.0f×%.0f",
          best, [image size].width, [image size].height);

    if (entry != NULL) {
        *entry = best;
    }

    return image;
}

#pragma mark Приготовление

/**
 * Квадратный значок нужного размера, без прозрачности.
 *
 * Прозрачность убирается нарочно: iOS рисует значок непрозрачным,
 * и на месте прозрачных точек у неё выходит чёрное. Тема же почти всегда
 * присылает картинку с прозрачными углами — их скругляет сама система.
 */
+ (NSData *)pngFrom:(UIImage *)image side:(NSInteger)side {
    CGSize box = CGSizeMake(side, side);

    /*
      * Множитель ставим единицей нарочно: значку нужен точный размер
      * в точках изображения, а не в точках экрана. С множителем экрана
      * на «ретине» вышел бы файл вдвое крупнее заказанного.
      */
    UIGraphicsBeginImageContextWithOptions(box, YES, 1.0);

    [[UIColor whiteColor] setFill];

    UIRectFill(CGRectMake(0, 0, side, side));

    CGSize size = [image size];

    /**
     * Вписываем по короткой стороне и обрезаем по краям: значок должен
     * занять квадрат целиком, а не встать в нём с полями.
     */
    CGFloat scale = MAX(side / size.width, side / size.height);

    CGFloat width = size.width * scale;
    CGFloat height = size.height * scale;

    [image drawInRect:CGRectMake((side - width) / 2, (side - height) / 2,
                                 width, height)];

    UIImage *ready = UIGraphicsGetImageFromCurrentImageContext();

    UIGraphicsEndImageContext();

    return UIImagePNGRepresentation(ready);
}

/** `Info.plist` связки с другой подписью — всё остальное как было. */
+ (BOOL)writePlistWithName:(NSString *)name to:(NSString *)folder {
    NSString *source = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Info.plist"];

    NSMutableDictionary *info =
        [NSMutableDictionary dictionaryWithContentsOfFile:source];

    if (info == nil) {
        NSLog(@"[YouTube/Значок] Не прочитать %@", source);

        return NO;
    }

    if ([name length] > 0) {
        [info setObject:name forKey:@"CFBundleDisplayName"];
        [info setObject:name forKey:@"CFBundleName"];
    }

    NSString *target = [folder stringByAppendingPathComponent:@"Info.plist"];

    return [info writeToFile:target atomically:YES];
}

/**
 * Локализованные названия — по одному на каждый язык связки.
 *
 * Именно их и читает SpringBoard: `Info.plist` он спрашивает лишь тогда,
 * когда для языка устройства ничего не нашлось. Поэтому подпись меняется
 * сразу везде — иначе на русском телефоне осталось бы прежнее имя,
 * а на английском появилось бы новое.
 *
 * Пишем в той же записи, что и наши собственные файлы: UTF-16
 * с меткой порядка байт. Её понимают все прошивки от пятой до
 * четырнадцатой, а UTF-8 в старых разбирается не всегда.
 */
+ (BOOL)writeLocalizedName:(NSString *)name to:(NSString *)folder {
    if ([name length] == 0) {
        return YES;
    }

    NSFileManager *files = [NSFileManager defaultManager];

    NSString *bundle = [[NSBundle mainBundle] bundlePath];

    NSArray *inside = [files contentsOfDirectoryAtPath:bundle error:NULL];

    NSString *safe = [[name stringByReplacingOccurrencesOfString:@"\\"
                                                      withString:@"\\\\"]
        stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];

    NSString *body = [NSString stringWithFormat:
        @"\"CFBundleDisplayName\" = \"%@\";\n\"CFBundleName\" = \"%@\";\n",
        safe, safe];

    NSUInteger written = 0;

    for (NSString *entry in inside) {
        if (![[entry pathExtension] isEqualToString:@"lproj"]) {
            continue;
        }

        NSString *source = [[bundle stringByAppendingPathComponent:entry]
            stringByAppendingPathComponent:@"InfoPlist.strings"];

        if (![files fileExistsAtPath:source]) {
            continue;
        }

        NSString *target = [folder stringByAppendingPathComponent:entry];

        [files createDirectoryAtPath:target
         withIntermediateDirectories:YES
                          attributes:nil
                               error:NULL];

        NSData *data = [body dataUsingEncoding:NSUTF16LittleEndianStringEncoding];

        /* Метка порядка байт — первой, как в исходных файлах связки. */
        NSMutableData *whole = [NSMutableData data];

        const unsigned char mark[] = { 0xFF, 0xFE };

        [whole appendBytes:mark length:2];
        [whole appendData:data];

        NSString *file = [target
            stringByAppendingPathComponent:@"InfoPlist.strings"];

        if (![whole writeToFile:file atomically:YES]) {
            NSLog(@"[YouTube/Значок] Не записать %@", file);

            return NO;
        }

        written++;
    }

    NSLog(@"[YouTube/Значок] Локализованных названий приготовлено: %lu",
          (unsigned long)written);

    return YES;
}

#pragma mark Запуск чужого

/**
 * Запуск чужого двоичного файла и всё, что он сказал.
 *
 * Вывод забирается через временный файл, а не через канал: канал надо
 * читать, пока процесс пишет, иначе оба встанут на полном буфере, —
 * а нам нужны две строчки от заведомо короткой работы.
 */
+ (int)run:(NSString *)tool arguments:(NSArray *)arguments {
    NSString *log = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"iconswitch.out"];

    posix_spawn_file_actions_t actions;

    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO,
                                     [log fileSystemRepresentation],
                                     O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);

    NSMutableArray *all = [NSMutableArray arrayWithObject:tool];

    [all addObjectsFromArray:arguments];

    char **argv = calloc([all count] + 1, sizeof(char *));

    for (NSUInteger i = 0; i < [all count]; i++) {
        argv[i] = strdup([[all objectAtIndex:i] fileSystemRepresentation]);
    }

    pid_t child = 0;

    int started = posix_spawn(&child, [tool fileSystemRepresentation],
                              &actions, NULL, argv, environ);

    for (NSUInteger i = 0; i < [all count]; i++) {
        free(argv[i]);
    }

    free(argv);

    posix_spawn_file_actions_destroy(&actions);

    if (started != 0) {
        NSLog(@"[YouTube/Значок] Не запустился %@: %s",
              [tool lastPathComponent], strerror(started));

        return -1;
    }

    int state = 0;

    while (waitpid(child, &state, 0) < 0 && errno == EINTR) {
        // Ожидание прервал сигнал — ждём дальше.
    }

    NSString *said = [NSString stringWithContentsOfFile:log
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];

    [[NSFileManager defaultManager] removeItemAtPath:log error:NULL];

    int code = WIFEXITED(state) ? WEXITSTATUS(state) : -1;

    NSLog(@"[YouTube/Значок] %@ %@ → код %d%@",
          [tool lastPathComponent],
          [arguments componentsJoinedByString:@" "],
          code,
          [said length] > 0
              ? [NSString stringWithFormat:@", сказал: %@",
                    [said stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]]]
              : @"");

    return code;
}

/**
 * `uicache` зовём от себя, то есть от `mobile`.
 *
 * Он перечитывает связку и обновляет список приложений, а список этот
 * у каждого пользователя свой: позови его помощник, работающий от root, —
 * обновился бы чужой.
 */
+ (void)refreshSpringBoard {
    [self run:@"/usr/bin/uicache" arguments:[NSArray array]];
}

#pragma mark Подмена

+ (BOOL)applyIcon:(UIImage *)icon name:(NSString *)name {
    if (![self helperReady]) {
        NSLog(@"[YouTube/Значок] Помощника нет или он без прав root");

        return NO;
    }

    NSString *folder = [self stagingFolder];

    NSFileManager *files = [NSFileManager defaultManager];

    if (icon != nil) {
        for (NSUInteger i = 0; i < YTIconSizeCount; i++) {
            NSInteger side = YTIconSizes[i];

            NSData *png = [self pngFrom:icon side:side];

            NSString *target = [folder stringByAppendingPathComponent:
                [NSString stringWithFormat:@"Icon-%ld.png", (long)side]];

            if (png == nil || ![png writeToFile:target atomically:YES]) {
                NSLog(@"[YouTube/Значок] Не записать %@", target);

                return NO;
            }
        }

        [UIImagePNGRepresentation(icon) writeToFile:[self chosenPath]
                                         atomically:YES];
    } else {
        /**
         * Значок не меняем, меняем только подпись — тогда в набор кладём
         * то, что стоит сейчас: помощник ставит набор целиком.
         */
        for (NSUInteger i = 0; i < YTIconSizeCount; i++) {
            NSString *file = [NSString stringWithFormat:@"Icon-%ld.png",
                              (long)YTIconSizes[i]];

            NSString *from = [[[NSBundle mainBundle] bundlePath]
                stringByAppendingPathComponent:file];

            NSString *to = [folder stringByAppendingPathComponent:file];

            [files removeItemAtPath:to error:NULL];

            if (![files copyItemAtPath:from toPath:to error:NULL]) {
                NSLog(@"[YouTube/Значок] Не скопировать %@", file);

                return NO;
            }
        }
    }

    if (![self writePlistWithName:name to:folder]) {
        return NO;
    }

    if (![self writeLocalizedName:name to:folder]) {
        return NO;
    }

    if ([self run:[self helperPath]
        arguments:[NSArray arrayWithObjects:@"apply", folder, nil]] != 0) {

        return NO;
    }

    [YTSettings setUsesAlternateIcon:YES];

    [self refreshSpringBoard];

    return YES;
}

+ (BOOL)restore {
    if (![self helperReady]) {
        NSLog(@"[YouTube/Значок] Помощника нет или он без прав root");

        return NO;
    }

    if ([self run:[self helperPath]
        arguments:[NSArray arrayWithObject:@"restore"]] != 0) {

        return NO;
    }

    [[NSFileManager defaultManager] removeItemAtPath:[self chosenPath] error:NULL];

    [YTSettings setUsesAlternateIcon:NO];

    [self refreshSpringBoard];

    return YES;
}

+ (BOOL)respring {
    return [self run:@"/usr/bin/killall"
           arguments:[NSArray arrayWithObject:@"SpringBoard"]] == 0;
}

#pragma mark Откуда брать темы

+ (NSArray *)themeFolders {
    NSMutableArray *folders = [NSMutableArray array];

    NSString *documents = [NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES) lastObject];

    if ([documents length] > 0) {
        [folders addObject:documents];
        [folders addObject:[documents stringByAppendingPathComponent:@"Inbox"]];
    }

    /**
     * Дальше — общие места, куда складывают скачанное.
     *
     * Пустит ли нас туда песочница, заранее не известно и зависит
     * от прошивки; те, что закрыты, просто не дадут перечня, и в списке
     * их не будет.
     */
    [folders addObject:@"/var/mobile/Documents"];
    [folders addObject:@"/var/mobile/Downloads"];
    [folders addObject:@"/var/mobile/Media/Downloads"];
    [folders addObject:@"/var/mobile/Library/Mobile Documents"];

    return folders;
}

+ (NSArray *)themeArchives {
    NSFileManager *files = [NSFileManager defaultManager];

    NSMutableArray *found = [NSMutableArray array];

    for (NSString *folder in [self themeFolders]) {
        NSArray *names = [files contentsOfDirectoryAtPath:folder error:NULL];

        for (NSString *name in names) {
            if (![[name pathExtension] isEqualToString:@"zip"]) {
                continue;
            }

            [found addObject:[folder stringByAppendingPathComponent:name]];
        }
    }

    NSLog(@"[YouTube/Значок] Тем найдено: %lu", (unsigned long)[found count]);

    return found;
}

@end
