#import <UIKit/UIKit.h>

#import "YTAppDelegate.h"

/**
 * Переносит язык и список клавиатур из общих настроек системы в свои.
 *
 * В поиске нельзя сменить язык: на клавиатуре нет глобуса. Дело не в поле
 * ввода и не в объявленных языках — приложение вообще не видит общих
 * настроек. И `AppleKeyboards`, и `AppleLanguages` читаются как
 * отсутствующие, отчего система считает устройство английским
 * (`NSLocale preferredLanguages` отдаёт `en` на русском iPad), а UIKit,
 * не найдя списка клавиатур, оставляет одну английскую. Переключать
 * не на что — глобус и не рисуется.
 *
 * Причина в том, где приложение живёт. Общие настройки лежат
 * в `.GlobalPreferences.plist` в домашнем каталоге пользователя, и обычному
 * приложению их подаёт система; программе, установленной в `/Applications`
 * мимо App Store, — не подаёт. Файл при этом никуда не делся и читается
 * обычным чтением файла, чем мы и пользуемся: берём оттуда нужные ключи
 * и кладём в собственный раздел настроек. Дальше их находит уже сам UIKit —
 * свой раздел он просматривает раньше общего.
 *
 * Решает дело при этом `AppleLanguages`, а не `AppleKeyboards`: последнего
 * в файле может не оказаться вовсе, список клавиатур UIKit строит от языков
 * системы. Забираем всё равно оба.
 *
 * Делается это до UIApplicationMain намеренно: и язык, и клавиатуры UIKit
 * читает один раз при запуске, и позже подменять их поздно.
 *
 * Значения не «дописываются, если пусто», а перезаписываются каждый запуск:
 * иначе однажды взятый список пережил бы смену языка в настройках системы.
 */
static void YTAdoptSystemPreferences(void) {
    NSArray *places = [NSArray arrayWithObjects:
        [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/Preferences/.GlobalPreferences.plist"],
        @"/var/mobile/Library/Preferences/.GlobalPreferences.plist",
        nil];

    NSDictionary *global = nil;

    for (NSString *path in places) {
        global = [NSDictionary dictionaryWithContentsOfFile:path];

        if (global != nil) {
            NSLog(@"[YouTube/Настройки] Общие настройки прочитаны: %@", path);
            break;
        }
    }

    if (global == nil) {
        NSLog(@"[YouTube/Настройки] Общие настройки не читаются — язык "
              @"и клавиатуры останутся такими, какими их видит система");
        return;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *adopted = @"";

    // AppleLocale нужен рядом с языком: по нему считаются форматы дат и чисел.
    NSArray *keys = [NSArray arrayWithObjects:
        @"AppleLanguages", @"AppleKeyboards", @"AppleLocale", nil];

    for (NSString *key in keys) {
        id value = [global objectForKey:key];

        if (value == nil) {
            continue;
        }

        [defaults setObject:value forKey:key];
        adopted = [adopted stringByAppendingFormat:
            adopted.length > 0 ? @", %@" : @"%@", key];
    }

    [defaults synchronize];

    // Целиком список языков не пишем: их там три десятка, и в журнале
    // они заняли бы больше места, чем весь запуск приложения.
    NSArray *languages = [global objectForKey:@"AppleLanguages"];

    NSLog(@"[YouTube/Настройки] Перенесено: %@ (язык %@, всего языков %lu)",
          adopted.length > 0 ? adopted : @"ничего",
          [global objectForKey:@"AppleLocale"] ?: @"неизвестен",
          (unsigned long)[languages count]);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        YTAdoptSystemPreferences();

        return UIApplicationMain(argc, argv, nil, NSStringFromClass([YTAppDelegate class]));
    }
}
