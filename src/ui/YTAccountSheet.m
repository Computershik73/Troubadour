#import "YTAccountSheet.h"

#import "YTStrings.h"

#import "YTApi.h"
#import "YTAuth.h"
#import "YTSettingsSheet.h"
#import "YTUtil.h"

@implementation YTAccountSheet

/**
 * Панель одна на приложение: её зовут и со страницы «Вы», и с нижней
 * панели, а показана она может быть только в одном месте разом.
 */
static YTSettingsSheet *YTAccountPanel = nil;

/** Пока список едет, повторные нажатия не заводят второй запрос. */
static BOOL YTAccountBusy = NO;

+ (void)openIn:(UIView *)host {
    if (host == nil) {
        return;
    }

    if (![YTAuth isSignedIn]) {
        NSLog(@"[YouTube/Аккаунт] Список каналов просят, но мы не вошли");

        return;
    }

    if (YTAccountBusy || [YTAccountPanel isOpen]) {
        return;
    }

    NSLog(@"[YouTube/Аккаунт] Открываем список каналов");

    YTAccountBusy = YES;

    YTAsync(^{
        NSArray *accounts = [YTApi accountsList];

        YTMain(^{
            YTAccountBusy = NO;

            [self show:accounts in:host];
        });
    });
}

+ (void)raiseIn:(UIView *)host {
    if (YTAccountPanel == nil || [YTAccountPanel superview] != host) {
        return;
    }

    [host bringSubviewToFront:YTAccountPanel];
}

+ (void)show:(NSArray *)accounts in:(UIView *)host {
    if ([accounts count] < 2) {
        NSLog(@"[YouTube/Аккаунт] Каналов в учётной записи: %u — "
              @"выбирать не из чего", (unsigned)[accounts count]);

        return;
    }

    /**
     * Список каналов — своей панелью, а не системным листом.
     *
     * У листа строка может быть только надписью, а узнают канал по
     * кружку: имена вроде «Кирилл» и «Кирилл 5 лет» без картинок
     * различаются с трудом. Панель та же, что у настроек плеера,
     * поэтому список выглядит частью приложения, а не системным окном.
     *
     * Из официального клиента взято только нужное: кружок, имя, вторая
     * строка с собачкой или пометкой и галочка у выбранного. Кнопок
     * управления учётной записью здесь нет — им место в настройках,
     * а не в списке выбора.
     */
    NSString *chosen = [YTApi activeAccountPage];

    NSMutableArray *rows = [NSMutableArray array];

    for (NSDictionary *account in accounts) {
        NSString *page = [account objectForKey:@"page"];

        BOOL current = ([chosen length] > 0)
            ? [page isEqualToString:chosen]
            : [[account objectForKey:@"primary"] boolValue];

        /**
         * Вторая строка: собачка, если канал её имеет, иначе пометка
         * владельца. У детских профилей собачки нет вовсе, и без
         * пометки они выглядели бы безымянными двойниками.
         */
        NSString *under = [account objectForKey:@"handle"];

        if ([under length] == 0) {
            under = YTLoc(@"Профиль аккаунта");
        }

        [rows addObject:[YTSheetRow account:[account objectForKey:@"name"]
                                   subtitle:under
                                     avatar:[account objectForKey:@"avatar"]
                                     picked:current
                                     action:^{
            [self switchTo:account];
        }]];
    }

    if (YTAccountPanel == nil) {
        YTAccountPanel = [[YTSettingsSheet alloc] initWithDark:NO];
    }

    [YTAccountPanel setTitle:YTLoc(@"Аккаунты") rows:rows];
    [YTAccountPanel openIn:host];
}

+ (void)switchTo:(NSDictionary *)account {
    [YTAccountPanel close];

    NSString *page = [account objectForKey:@"page"];

    if ([page length] == 0) {
        NSLog(@"[YouTube/Аккаунт] У канала «%@» нет приметы владельца — "
              @"переключиться нечем", [account objectForKey:@"name"]);

        return;
    }

    /**
     * Дальше делать ничего не нужно: `setActiveAccountPage:` рассылает
     * `YTAuthChangedNotification`, а по нему перечитываются и страница
     * «Вы», и кружок в нижней панели. Здесь мы не знаем, кто из них
     * сейчас на виду, и знать не должны.
     */
    [YTApi setActiveAccountPage:page
                       datasync:[account objectForKey:@"datasync"]];
}

@end
