#import "YTStoryboard.h"

#import "YTJson.h"

@implementation YTStoryboardFrame
@end


/** Один уровень описания: свой размер кадра, сетка и шаг по времени. */
@interface YTStoryboardLevel : NSObject {
@public
    NSInteger index;
    NSInteger width;
    NSInteger height;
    NSInteger total;
    NSInteger columns;
    NSInteger rows;
    NSInteger intervalMs;
    NSString *nameTemplate;
    NSString *sigh;
}
@end

@implementation YTStoryboardLevel
@end


@implementation YTStoryboard {
    NSString *_base;
    NSMutableArray *_levels;
}

+ (NSString *)specIn:(NSDictionary *)playerResponse {
    return [YTJson textIn:
        [YTJson objectIn:[YTJson objectIn:playerResponse key:@"storyboards"]
                     key:@"playerStoryboardSpecRenderer"] key:@"spec"];
}

+ (YTStoryboard *)parse:(NSString *)spec {
    if ([spec length] == 0) {
        return nil;
    }

    NSArray *parts = [spec componentsSeparatedByString:@"|"];

    if ([parts count] < 2) {
        return nil;
    }

    YTStoryboard *board = [[YTStoryboard alloc] init];

    board->_base = [[parts objectAtIndex:0] copy];
    board->_levels = [NSMutableArray array];

    for (NSUInteger i = 1; i < [parts count]; i++) {
        NSArray *fields = [[parts objectAtIndex:i] componentsSeparatedByString:@"#"];

        if ([fields count] < 8) {
            continue;
        }

        YTStoryboardLevel *level = [[YTStoryboardLevel alloc] init];

        level->index = (NSInteger)i - 1;
        level->width = [[fields objectAtIndex:0] integerValue];
        level->height = [[fields objectAtIndex:1] integerValue];
        level->total = [[fields objectAtIndex:2] integerValue];
        level->columns = [[fields objectAtIndex:3] integerValue];
        level->rows = [[fields objectAtIndex:4] integerValue];
        level->intervalMs = [[fields objectAtIndex:5] integerValue];
        level->nameTemplate = [fields objectAtIndex:6];
        level->sigh = [fields objectAtIndex:7];

        if (level->width > 0 && level->height > 0 && level->total > 0 &&
            level->columns > 0 && level->rows > 0 && level->intervalMs > 0) {

            [board->_levels addObject:level];
        }
    }

    if ([board->_levels count] == 0) {
        return nil;
    }

    return board;
}

/**
 * Уровень, которым показываем.
 *
 * Берём тот, у которого на одном листе **больше всего** кадров: чем плотнее
 * лист, тем меньше их придётся качать. Кадры при этом мельче, но при
 * перемотке важнее, чтобы картинка успевала появиться. При равенстве —
 * тот, что крупнее. Так же выбирает и оригинал.
 */
- (YTStoryboardLevel *)best {
    YTStoryboardLevel *best = nil;

    for (YTStoryboardLevel *level in _levels) {
        NSInteger perSheet = level->columns * level->rows;

        if (best == nil) {
            best = level;
            continue;
        }

        NSInteger bestPerSheet = best->columns * best->rows;

        if (perSheet > bestPerSheet ||
            (perSheet == bestPerSheet && level->width > best->width)) {

            best = level;
        }
    }

    return best;
}

- (YTStoryboardFrame *)frameAt:(NSTimeInterval)seconds {
    YTStoryboardLevel *level = [self best];

    if (level == nil) {
        return nil;
    }

    NSInteger perSheet = level->columns * level->rows;
    NSInteger frame = (NSInteger)floor(seconds * 1000.0 / (double)level->intervalMs);

    if (frame < 0) { frame = 0; }
    if (frame > level->total - 1) { frame = level->total - 1; }

    NSInteger sheet = frame / perSheet;
    NSInteger place = frame % perSheet;

    NSString *name = [level->nameTemplate stringByReplacingOccurrencesOfString:@"$M"
        withString:[NSString stringWithFormat:@"%ld", (long)sheet]];

    NSString *url = [_base stringByReplacingOccurrencesOfString:@"$L"
        withString:[NSString stringWithFormat:@"%ld", (long)level->index]];

    url = [url stringByReplacingOccurrencesOfString:@"$N" withString:name];

    url = [url stringByAppendingFormat:@"%@sigh=%@",
           [url rangeOfString:@"?"].location != NSNotFound ? @"&" : @"?",
           level->sigh];

    YTStoryboardFrame *result = [[YTStoryboardFrame alloc] init];

    result.sheet = url;
    result.column = place % level->columns;
    result.row = place / level->columns;
    result.width = level->width;
    result.height = level->height;

    return result;
}

@end
