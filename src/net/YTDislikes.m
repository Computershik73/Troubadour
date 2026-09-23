#import "YTDislikes.h"

#import "YTHttp.h"
#import "YTJson.h"

@implementation YTDislikes

+ (NSNumber *)countFor:(NSString *)videoId {
    if ([videoId length] == 0) {
        return nil;
    }

    NSString *address = [@"https://returnyoutubedislikeapi.com/votes?videoId="
        stringByAppendingString:YTEncodeParameter(videoId)];

    NSMutableURLRequest *request =
        YTRequest(address, NSURLRequestUseProtocolCachePolicy, 15.0);

    if (request == nil) {
        return nil;
    }

    /**
     * Десять минут в кеше: число меняется медленно, а ролик нередко
     * открывают по нескольку раз подряд — назад и снова, из очереди
     * и из истории.
     */
    YTHttpResponse *response = [YTHttp send:request
                                  bodyLimit:64 * 1024
                                cacheForTTL:600];

    NSDictionary *json = [YTJson parse:[response body]];

    id dislikes = [json objectForKey:@"dislikes"];

    if (![dislikes respondsToSelector:@selector(longLongValue)]
        || [dislikes longLongValue] < 0) {
        NSLog(@"[YouTube/Дизлайки] %@: ответа нет (код %ld)",
              videoId, (long)[response statusCode]);

        return nil;
    }

    NSLog(@"[YouTube/Дизлайки] %@: %lld", videoId, [dislikes longLongValue]);

    return [NSNumber numberWithLongLong:[dislikes longLongValue]];
}

@end
