#import "YTUpdatePrompt.h"

#import "YTUpdate.h"
#import "YTStrings.h"

@interface YTUpdatePrompt () <UIAlertViewDelegate>
@end

@implementation YTUpdatePrompt {
    NSDictionary *_found;
    UIAlertView *_offer;
    UIAlertView *_working;
}

/**
 * Живёт одна на приложение.
 *
 * У `UIAlertView` получатель не удерживается, и объект, заведённый на
 * время окна, успевал исчезнуть до нажатия: окно оставалось, а отвечать
 * на нажатие было некому.
 */
+ (YTUpdatePrompt *)shared {
    static YTUpdatePrompt *one = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{ one = [[YTUpdatePrompt alloc] init]; });

    return one;
}

+ (void)listen {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:@"YTUpdateFound"
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        NSDictionary *found = [note object];

        /**
         * Об одной и той же версии говорим один раз.
         *
         * Отложивший обновление не должен видеть то же окно при каждом
         * запуске — это не напоминание, а надоедание. Появится следующая
         * сборка — скажем снова, уже о ней.
         */
        NSString *version = [found objectForKey:@"version"];

        if ([version isEqualToString:[YTUpdate announcedVersion]]) {
            return;
        }

        [YTUpdate setAnnouncedVersion:version];

        [YTUpdatePrompt offer:found];
    }];
}

+ (void)checkAloud {
    [[self shared] checkAloud];
}

+ (void)offer:(NSDictionary *)found {
    [[self shared] offer:found];
}

- (void)checkAloud {
    if (![YTUpdate canInstall]) {
        [self say:YTLoc(@"Обновление")
             text:YTLoc(@"Ставить пакет нечем: в системе нет dpkg. "
                        @"Обновление поверх себя работает только "
                        @"с джейлбрейком.")];

        return;
    }

    [self say:YTLoc(@"Обновление") text:YTLoc(@"Спрашиваем источник…")];

    [YTUpdate check:^(NSDictionary *found) {
        [_working dismissWithClickedButtonIndex:0 animated:NO];

        _working = nil;

        if (found == nil) {
            [self say:YTLoc(@"Обновление")
                 text:YTLocF(@"Установлена свежая версия: %@",
                             [YTUpdate installedVersion])];

            return;
        }

        [self offer:found];
    }];
}

- (void)offer:(NSDictionary *)found {
    if (found == nil || _offer != nil) {
        return;
    }

    _found = found;

    long long size = [[found objectForKey:@"size"] longLongValue];

    NSString *text = YTLocF(@"Доступна версия %@ (%.1f МБ). Установить сейчас?",
                            [found objectForKey:@"version"], size / 1048576.0);

    _offer = [[UIAlertView alloc] initWithTitle:YTLoc(@"Обновление")
                                        message:text
                                       delegate:self
                              cancelButtonTitle:YTLoc(@"Потом")
                              otherButtonTitles:YTLoc(@"Установить"), nil];

    [_offer show];
}

- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index {
    if (alert != _offer) {
        return;
    }

    _offer = nil;

    if (index == [alert cancelButtonIndex]) {
        return;
    }

    [self say:YTLoc(@"Обновление") text:YTLoc(@"Скачиваем…")];

    [YTUpdate install:_found state:^(NSString *what) {
        [_working setMessage:what];
    } done:^(NSString *failure) {
        [_working dismissWithClickedButtonIndex:0 animated:NO];

        _working = nil;

        if (failure != nil) {
            [self say:YTLoc(@"Не вышло") text:failure];

            return;
        }

        /**
         * Поставили — и дальше работать нельзя.
         *
         * Связка на диске уже новая, а в памяти — прежняя: её код,
         * её ресурсы, её же открытые файлы. Дальше это не приложение,
         * а половина одного и половина другого. Поэтому закрываемся,
         * и говорим об этом прямо.
         */
        UIAlertView *bye = [[UIAlertView alloc]
            initWithTitle:YTLoc(@"Готово")
                  message:YTLoc(@"Новая версия установлена. Приложение "
                                @"закроется — откройте его заново.")
                 delegate:self
        cancelButtonTitle:YTLoc(@"Закрыть")
        otherButtonTitles:nil];

        [bye show];

        [self performSelector:@selector(quit) withObject:nil afterDelay:3.0];
    }];
}

- (void)quit {
    NSLog(@"[YouTube/Обновление] Ставили поверх себя — закрываемся");

    exit(0);
}

/** Окно без выбора: показать и оставить, пока не уберём сами. */
- (void)say:(NSString *)title text:(NSString *)text {
    [_working dismissWithClickedButtonIndex:0 animated:NO];

    _working = [[UIAlertView alloc] initWithTitle:title
                                          message:text
                                         delegate:nil
                                cancelButtonTitle:YTLoc(@"Закрыть")
                                otherButtonTitles:nil];

    [_working show];
}

@end
