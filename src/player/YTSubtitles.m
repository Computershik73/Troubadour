#import "YTSubtitles.h"

#import "YTHttp.h"
#import "YTJson.h"
#import "YTStrings.h"

@implementation YTSubtitleTrack

- (NSString *)displayName {
    if ([_name length] == 0) {
        return _language ?: @"";
    }

    // Пометка та же, что в оригинале: машинную дорожку надо отличать.
    return _automatic
        ? [_name stringByAppendingString:YTLoc(@" (авто)")]
        : _name;
}

@end


@implementation YTSubtitleCue
@end


@implementation YTSubtitles

+ (NSArray *)tracksIn:(NSDictionary *)playerResponse {
    NSDictionary *renderer =
        [YTJson objectIn:[YTJson objectIn:playerResponse key:@"captions"]
                     key:@"playerCaptionsTracklistRenderer"];

    NSMutableArray *tracks = [NSMutableArray array];

    for (NSDictionary *node in [YTJson arrayIn:renderer key:@"captionTracks"]) {
        NSString *url = [YTJson textIn:node key:@"baseUrl"];

        if ([url length] == 0) {
            continue;
        }

        YTSubtitleTrack *track = [[YTSubtitleTrack alloc] init];

        track.url = url;
        track.language = [YTJson textIn:node key:@"languageCode"];
        track.name = [YTJson renderedText:node key:@"name"];

        /**
         * Машинная дорожка узнаётся по виду: `kind: "asr"` — это
         * автоматическое распознавание речи. Так же её метит и оригинал.
         */
        track.automatic = [[YTJson textIn:node key:@"kind"] isEqualToString:@"asr"];

        if ([track.name length] == 0) {
            track.name = track.language;
        }

        [tracks addObject:track];
    }

    NSLog(@"[YouTube/Субтитры] дорожек: %lu", (unsigned long)[tracks count]);

    return tracks;
}

+ (NSArray *)cuesFor:(YTSubtitleTrack *)track {
    NSMutableArray *cues = [NSMutableArray array];

    if ([track.url length] == 0) {
        return cues;
    }

    // `json3` просим явно: иначе приходит XML, а его разбор нам ни к чему.
    NSString *address = [track.url stringByAppendingString:@"&fmt=json3"];

    NSMutableURLRequest *request =
        YTRequest(address, NSURLRequestUseProtocolCachePolicy, 20.0);

    if (request == nil) {
        return cues;
    }

    YTHttpResponse *response = [YTHttp send:request
                                  bodyLimit:4 * 1024 * 1024
                                cacheForTTL:600];

    if (![response isSuccessful]) {
        NSLog(@"[YouTube/Субтитры] Дорожка не взялась: код %ld",
              (long)response.statusCode);

        return cues;
    }

    NSDictionary *root = [YTJson parse:response.body];

    for (NSDictionary *event in [YTJson arrayIn:root key:@"events"]) {
        NSInteger start = [YTJson intIn:event key:@"tStartMs"];
        NSInteger length = [YTJson intIn:event key:@"dDurationMs"];

        NSMutableString *text = [NSMutableString string];

        /**
         * Реплика собрана из кусочков — у машинных дорожек так размечено
         * каждое слово отдельно. Склеиваем подряд, ничего не разделяя:
         * пробелы уже внутри кусочков.
         */
        for (NSDictionary *piece in [YTJson arrayIn:event key:@"segs"]) {
            NSString *part = [YTJson stringIn:piece key:@"utf8" fallback:@""];

            if ([part length] > 0) {
                [text appendString:part];
            }
        }

        NSString *plain = [text stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        if ([plain length] == 0 || length <= 0) {
            continue;
        }

        YTSubtitleCue *cue = [[YTSubtitleCue alloc] init];

        cue.start = start / 1000.0;
        cue.end = (start + length) / 1000.0;
        cue.text = plain;

        [cues addObject:cue];
    }

    NSLog(@"[YouTube/Субтитры] реплик: %lu", (unsigned long)[cues count]);

    return cues;
}

@end
