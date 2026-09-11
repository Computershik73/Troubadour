#import "YTSponsorBlock.h"

#import <CommonCrypto/CommonDigest.h>

#import "YTHttp.h"
#import "YTJson.h"

/**
 * Что пропускаем без спроса.
 *
 * `sponsor` — оплаченная вставка, `selfpromo` — реклама самого автора,
 * `interaction` — просьба поставить лайк и подписаться. Заставка, титры
 * и посторонняя музыка нарочно не тронуты: это части самого ролика,
 * а не вставки в него. Список тот же, что в оригинале.
 */
static NSString *const YTSponsorCategories =
    @"[\"sponsor\",\"selfpromo\",\"interaction\"]";

@implementation YTSponsorSegment
@end


@implementation YTSponsorBlock

/** Первые четыре знака SHA-256 от номера ролика. */
+ (NSString *)hashPrefixFor:(NSString *)videoId {
    NSData *input = [videoId dataUsingEncoding:NSUTF8StringEncoding];

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];

    CC_SHA256([input bytes], (CC_LONG)[input length], digest);

    return [NSString stringWithFormat:@"%02x%02x", digest[0], digest[1]];
}

+ (NSArray *)segmentsFor:(NSString *)videoId {
    NSMutableArray *segments = [NSMutableArray array];

    if ([videoId length] == 0) {
        return segments;
    }

    /**
     * Перечень разрядов кодируется целиком, вместе со скобками.
     *
     * `stringByAddingPercentEscapesUsingEncoding:` их не трогает — по его
     * меркам квадратная скобка в адресе законна, — и в строке оставались
     * сырые `[` и `]`. А `NSURL` с ними разбирать адрес отказывается
     * и отвечает `nil`: запрос не уходил вовсе, ни к одному ролику.
     * Снаружи это выглядело как «SponsorBlock не работает никогда»,
     * и ровно так и было.
     */
    NSString *address = [NSString stringWithFormat:
        @"https://sponsor.ajay.app/api/skipSegments/%@?categories=%@",
        [self hashPrefixFor:videoId], YTEncodeParameter(YTSponsorCategories)];

    NSMutableURLRequest *request =
        YTRequest(address, NSURLRequestUseProtocolCachePolicy, 15.0);

    if (request == nil) {
        NSLog(@"[YouTube/SponsorBlock] Адрес не разобран: %@", address);

        return segments;
    }

    NSLog(@"[YouTube/SponsorBlock] → %@", address);

    YTHttpResponse *response = [YTHttp send:request
                                  bodyLimit:2 * 1024 * 1024
                                cacheForTTL:3600];

    NSLog(@"[YouTube/SponsorBlock] ← код %ld, %lu байт%@",
          (long)response.statusCode, (unsigned long)[response.body length],
          response.error != nil
              ? [NSString stringWithFormat:@", ошибка: %@", [response.error localizedDescription]]
              : @"");

    if (![response isSuccessful]) {
        // 404 значит лишь, что для этой приставки хеша никто ничего
        // не размечал, — обычное дело, не беда.
        NSLog(@"[YouTube/SponsorBlock] Ответ: код %ld", (long)response.statusCode);

        return segments;
    }

    // Именно `parseAny:`: у этой службы ответ начинается с массива,
    // а `parse:` пропускает только объект — на нём разбор и обрывался.
    id root = [YTJson parseAny:response.body];

    if (![root isKindOfClass:[NSArray class]]) {
        NSLog(@"[YouTube/SponsorBlock] Ответ не разобрался: пришло %@",
              NSStringFromClass([root class]));

        return segments;
    }

    NSLog(@"[YouTube/SponsorBlock] В ответе роликов: %lu, ищем %@",
          (unsigned long)[(NSArray *)root count], videoId);

    for (NSDictionary *video in (NSArray *)root) {
        if (![[YTJson textIn:video key:@"videoID"] isEqualToString:videoId]) {
            continue;
        }

        for (NSDictionary *node in [YTJson arrayIn:video key:@"segments"]) {
            /**
             * `mute` и `full` — не пропуск: первое приглушает звук, второе
             * помечает ролик целиком. Прыгать по ним нельзя.
             */
            NSString *action = [YTJson textIn:node key:@"actionType"];

            if ([action length] > 0 && ![action isEqualToString:@"skip"]) {
                continue;
            }

            NSArray *bounds = [YTJson arrayIn:node key:@"segment"];

            if ([bounds count] < 2) {
                continue;
            }

            double start = [[bounds objectAtIndex:0] doubleValue];
            double end = [[bounds objectAtIndex:1] doubleValue];

            // Пустой или вывернутый кусок заставил бы пропуск ходить по кругу.
            if (end - start < 0.5) {
                continue;
            }

            YTSponsorSegment *segment = [[YTSponsorSegment alloc] init];

            segment.start = start;
            segment.end = end;
            segment.category = [YTJson stringIn:node key:@"category" fallback:@"sponsor"];

            [segments addObject:segment];
        }
    }

    [segments sortUsingComparator:^NSComparisonResult(YTSponsorSegment *a, YTSponsorSegment *b) {
        if (a.start < b.start) { return NSOrderedAscending; }
        if (a.start > b.start) { return NSOrderedDescending; }

        return NSOrderedSame;
    }];

    NSLog(@"[YouTube/SponsorBlock] вставок: %lu у %@",
          (unsigned long)[segments count], videoId);

    return segments;
}

@end
