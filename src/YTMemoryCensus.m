#import "YTMemoryCensus.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "YTUtil.h"

NSString *const YTMemoryCensusNotification = @"YTMemoryCensus";
NSString *const YTMemoryCensusNotesKey = @"notes";

static char YTCacheTallyCost;

@implementation YTCacheTally {
    long long _bytes;
    NSInteger _count;
}

- (void)noteObject:(id)object cost:(NSUInteger)cost {
    if (object == nil) {
        return;
    }

    objc_setAssociatedObject(object, &YTCacheTallyCost,
                             [NSNumber numberWithUnsignedInteger:cost],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    @synchronized (self) {
        _bytes += cost;
        _count++;
    }
}

- (void)cache:(NSCache *)cache willEvictObject:(id)object {
    NSNumber *cost = objc_getAssociatedObject(object, &YTCacheTallyCost);

    if (cost == nil) {
        return;
    }

    objc_setAssociatedObject(object, &YTCacheTallyCost, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    @synchronized (self) {
        _bytes -= [cost unsignedIntegerValue];
        _count--;
    }
}

- (NSString *)summary {
    @synchronized (self) {
        return [NSString stringWithFormat:@"%ld шт., %.1f МБ",
                (long)_count, _bytes / 1048576.0];
    }
}

@end

#ifdef YT_NO_LOG

void YTMemoryCensusStart(void) {}
void YTMemoryCensusNow(NSString *reason) {}

#else

void YTMemoryCensusNow(NSString *reason) {
    void (^census)(void) = ^{
        NSMutableArray *notes = [NSMutableArray array];

        [[NSNotificationCenter defaultCenter]
            postNotificationName:YTMemoryCensusNotification
                          object:nil
                        userInfo:[NSDictionary dictionaryWithObject:notes
                                                             forKey:YTMemoryCensusNotesKey]];

        NSLog(@"[YouTube/Память] Перепись%@: занято %.0f МБ%@%@",
              [reason length] > 0 ? [NSString stringWithFormat:@" (%@)", reason] : @"",
              YTResidentMegabytes(),
              [notes count] > 0 ? @"; " : @"",
              [notes componentsJoinedByString:@"; "]);
    };

    // Подписчики трогают виды — только с главного потока.
    if ([NSThread isMainThread]) {
        census();
    } else {
        dispatch_async(dispatch_get_main_queue(), census);
    }
}

@interface YTMemoryCensusTimer : NSObject
@end

@implementation YTMemoryCensusTimer

+ (void)tick:(NSTimer *)timer {
    // В фоне переписывать нечего: интерфейс не меняется, а строки копятся.
    if ([[UIApplication sharedApplication] applicationState] == UIApplicationStateBackground) {
        return;
    }

    YTMemoryCensusNow(nil);
}

@end

void YTMemoryCensusStart(void) {
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        [NSTimer scheduledTimerWithTimeInterval:20.0
                                         target:[YTMemoryCensusTimer class]
                                       selector:@selector(tick:)
                                       userInfo:nil
                                        repeats:YES];
    });
}

#endif
