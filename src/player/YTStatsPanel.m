#import "YTStatsPanel.h"

#import <AVFoundation/AVFoundation.h>

#import "YTApi.h"
#import "YTPlaybackStats.h"
#import "YTSabr.h"

static const CGFloat YTStatsPad = 8;
static const CGFloat YTStatsRow = 16;
static const CGFloat YTStatsLabel = 128;
static const CGFloat YTStatsGap = 8;
static const CGFloat YTStatsGraphValue = 80;
static const CGFloat YTStatsRows = 11;

@implementation YTStatsSnapshot
@end

/**
 * Полоска истории — столбики за последнюю минуту, справа свежее.
 * Высота столбика — доля от наибольшего значения в окне.
 */
@interface YTSparkline : UIView

@property (nonatomic, strong) UIColor *color;

- (void)push:(float)value;
- (void)clear;

@end

@implementation YTSparkline {
    float _values[60];
    NSUInteger _count;
}

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self setBackgroundColor:[UIColor blackColor]];
        [self setOpaque:YES];
    }

    return self;
}

- (void)push:(float)value {
    if (_count < 60) {
        _values[_count++] = value;
    } else {
        memmove(_values, _values + 1, sizeof(float) * 59);
        _values[59] = value;
    }

    [self setNeedsDisplay];
}

- (void)clear {
    _count = 0;

    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();

    [[UIColor blackColor] setFill];
    CGContextFillRect(context, [self bounds]);

    if (_count == 0) {
        return;
    }

    float top = 0;

    for (NSUInteger i = 0; i < _count; i++) {
        if (_values[i] > top) {
            top = _values[i];
        }
    }

    if (top <= 0) {
        return;
    }

    CGFloat width = [self bounds].size.width;
    CGFloat height = [self bounds].size.height;
    CGFloat step = width / 60;

    [(_color ?: [UIColor whiteColor]) setFill];

    for (NSUInteger i = 0; i < _count; i++) {
        CGFloat x = width - (_count - i) * step;
        CGFloat h = height * _values[i] / top;

        CGContextFillRect(context, CGRectMake(x, height - h, step - 1, h));
    }
}

@end

@implementation YTStatsPanel {
    NSMutableArray *_labels;
    NSMutableArray *_values;

    YTSparkline *_speedGraph;
    YTSparkline *_activityGraph;
    YTSparkline *_bufferGraph;

    UIButton *_close;

    NSTimer *_timer;

    long long _lastBytes;

    NSDateFormatter *_clock;

}

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self setBackgroundColor:[UIColor colorWithWhite:0 alpha:0.85]];

        _labels = [NSMutableArray array];
        _values = [NSMutableArray array];

        NSArray *names = @[
            @"Video ID / sCPN", @"Viewport / Frames", @"Current / Optimal Res",
            @"Volume / Normalized", @"Codecs", @"Color",
            @"Connection Speed", @"Network Activity", @"Buffer Health",
            @"Mystery Text", @"Date"
        ];

        for (NSString *name in names) {
            UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];

            [label setText:name];
            [label setFont:[UIFont boldSystemFontOfSize:11]];
            [label setTextColor:[UIColor whiteColor]];
            [label setBackgroundColor:[UIColor clearColor]];
            [label setTextAlignment:NSTextAlignmentRight];

            [self addSubview:label];
            [_labels addObject:label];

            UILabel *value = [[UILabel alloc] initWithFrame:CGRectZero];

            [value setFont:[UIFont systemFontOfSize:11]];
            [value setTextColor:[UIColor whiteColor]];
            [value setBackgroundColor:[UIColor clearColor]];
            [value setLineBreakMode:NSLineBreakByTruncatingTail];

            [self addSubview:value];
            [_values addObject:value];
        }

        _speedGraph = [[YTSparkline alloc] initWithFrame:CGRectZero];
        [_speedGraph setColor:[UIColor colorWithRed:0.30 green:0.82 blue:0.77 alpha:1]];

        _activityGraph = [[YTSparkline alloc] initWithFrame:CGRectZero];
        [_activityGraph setColor:[UIColor whiteColor]];

        _bufferGraph = [[YTSparkline alloc] initWithFrame:CGRectZero];
        [_bufferGraph setColor:[UIColor colorWithRed:0.95 green:0.71 blue:0.36 alpha:1]];

        for (YTSparkline *graph in @[_speedGraph, _activityGraph, _bufferGraph]) {
            [self addSubview:graph];
        }

        for (NSUInteger i = 6; i <= 8; i++) {
            [[_values objectAtIndex:i] setTextAlignment:NSTextAlignmentRight];
        }

        _close = [UIButton buttonWithType:UIButtonTypeCustom];

        [_close setTitle:@"[X]" forState:UIControlStateNormal];
        [[_close titleLabel] setFont:[UIFont boldSystemFontOfSize:11]];
        [_close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [_close addTarget:self
                   action:@selector(closeTapped)
         forControlEvents:UIControlEventTouchUpInside];

        [self addSubview:_close];

        _lastBytes = -1;

        _clock = [[NSDateFormatter alloc] init];

        [_clock setLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"]];
        [_clock setDateFormat:@"EEE MMM dd yyyy HH:mm:ss"];
    }

    return self;
}

- (void)closeTapped {
    if (_onClose != nil) {
        _onClose();
    }
}

- (CGFloat)preferredHeight {
    return YTStatsPad * 2 + YTStatsRow * YTStatsRows;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat width = [self bounds].size.width;
    CGFloat valueLeft = YTStatsPad + YTStatsLabel + YTStatsGap;
    CGFloat valueWidth = width - valueLeft - YTStatsPad;

    CGFloat top = YTStatsPad;

    for (NSUInteger i = 0; i < [_labels count]; i++) {
        [[_labels objectAtIndex:i] setFrame:CGRectMake(YTStatsPad, top, YTStatsLabel, YTStatsRow)];

        YTSparkline *graph = nil;

        if (i == 6) {
            graph = _speedGraph;
        } else if (i == 7) {
            graph = _activityGraph;
        } else if (i == 8) {
            graph = _bufferGraph;
        }

        if (graph != nil) {
            CGFloat graphWidth = valueWidth - YTStatsGraphValue - YTStatsGap;

            [graph setFrame:CGRectMake(valueLeft, top + 1, graphWidth, YTStatsRow - 2)];
            [[_values objectAtIndex:i] setFrame:CGRectMake(
                valueLeft + graphWidth + YTStatsGap, top, YTStatsGraphValue, YTStatsRow)];
        } else {
            [[_values objectAtIndex:i] setFrame:CGRectMake(valueLeft, top, valueWidth, YTStatsRow)];
        }

        top += YTStatsRow;
    }

    // Крестик рисуется мелким, а нажимается крупным: палец не стилус.
    [_close setFrame:CGRectMake(width - 44, 0, 44, 36)];
}

#pragma mark Обновление

- (void)start {
    [self stop];

    _lastBytes = -1;

    [_speedGraph clear];
    [_activityGraph clear];
    [_bufferGraph clear];

    [self update];

    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                              target:self
                                            selector:@selector(update)
                                            userInfo:nil
                                             repeats:YES];
}

- (void)stop {
    [_timer invalidate];
    _timer = nil;
}

/**
 * Размер видеодорожки, каким он записан в самом потоке.
 *
 * Спрашивать сам показ (`presentationSize`) нельзя: он описывает слой
 * вывода, а не поток, и врал нам про 853×480. Снимать кадр с выхода
 * (`AVPlayerItemVideoOutput`) тоже пробовали — цифра выходила верная,
 * 1280×720, но добавленный вывод заставлял плеер перестраивать
 * раскодирование, и показ замирал на пару секунд каждый раз, когда
 * панель открывают или закрывают. Разовый ответ того не стоил.
 *
 * `naturalSize` даётся даром: она уже разобрана у дорожки.
 */
- (CGSize)trackSize:(AVPlayerItem *)item {
    for (AVPlayerItemTrack *piece in [item tracks]) {
        AVAssetTrack *track = [piece assetTrack];

        if ([[track mediaType] isEqualToString:AVMediaTypeVideo]) {
            return [track naturalSize];
        }
    }

    return CGSizeZero;
}

- (NSInteger)trackHeight:(AVPlayerItem *)item {
    return (NSInteger)[self trackSize:item].height;
}

- (void)set:(NSUInteger)index text:(NSString *)text {
    [[_values objectAtIndex:index] setText:text];
}

/** Описание дорожки в ответе `/player` — по номеру либо по высоте. */
- (NSDictionary *)formatIn:(NSDictionary *)json itag:(NSInteger)itag height:(NSInteger)height {
    NSDictionary *streaming = [json objectForKey:@"streamingData"];

    if (![streaming isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    for (NSString *key in @[@"adaptiveFormats", @"formats"]) {
        NSArray *list = [streaming objectForKey:key];

        if (![list isKindOfClass:[NSArray class]]) {
            continue;
        }

        for (NSDictionary *format in list) {
            if (![format isKindOfClass:[NSDictionary class]]) {
                continue;
            }

            if (itag > 0) {
                if ([[format objectForKey:@"itag"] integerValue] == itag) {
                    return format;
                }
            } else if (height > 0) {
                NSString *mime = [format objectForKey:@"mimeType"];

                if ([[format objectForKey:@"height"] integerValue] == height &&
                    [mime rangeOfString:@"avc1"].location != NSNotFound) {
                    return format;
                }
            }
        }
    }

    return nil;
}

- (NSString *)codecOf:(NSDictionary *)format itag:(NSInteger)itag {
    NSString *mime = [format objectForKey:@"mimeType"];
    NSRange quoted = [mime rangeOfString:@"codecs=\""];

    if (mime == nil || quoted.location == NSNotFound) {
        return @"—";
    }

    NSString *tail = [mime substringFromIndex:NSMaxRange(quoted)];
    NSRange end = [tail rangeOfString:@"\""];

    NSString *name = (end.location == NSNotFound) ? tail : [tail substringToIndex:end.location];

    return (itag > 0) ? [NSString stringWithFormat:@"%@ (%ld)", name, (long)itag] : name;
}

- (NSString *)shortColor:(NSString *)value {
    if ([value length] == 0) {
        return @"—";
    }

    NSRange cut = [value rangeOfString:@"_" options:NSBackwardsSearch];

    NSString *tail = (cut.location == NSNotFound) ? value : [value substringFromIndex:NSMaxRange(cut)];

    return [tail lowercaseString];
}

- (void)update {
    YTStatsSnapshot *s = (_source != nil) ? _source() : nil;

    if (s == nil) {
        return;
    }

    AVPlayer *player = s.player;
    AVPlayerItem *item = [player currentItem];
    NSDictionary *json = s.playerJson;
    YTSabr *sabr = s.sabr;

    [self set:0 text:[NSString stringWithFormat:@"%@ / %@",
        [s.videoId length] > 0 ? s.videoId : @"—",
        [YTApi playbackNonceForVideo:s.videoId]]];

    CGFloat scale = [[UIScreen mainScreen] scale];

    AVPlayerItemAccessLogEvent *event = [[[item accessLog] events] lastObject];

    long long dropped = 0;

    for (AVPlayerItemAccessLogEvent *each in [[item accessLog] events]) {
        if ([each numberOfDroppedVideoFrames] > 0) {
            dropped += [each numberOfDroppedVideoFrames];
        }
    }

    [self set:1 text:[NSString stringWithFormat:@"%.0fx%.0f*%.2f / %lld dropped",
        s.viewport.width, s.viewport.height, scale, dropped]];

    /**
     * Спрашиваем ту дорожку, что и вправду идёт.
     *
     * Прежде здесь стояла объявленная (`playingItag`), и строка выходила
     * склеенной из двух разных: размер брался у настоящей картинки,
     * а кадровая частота и кодек — у объявленной. На iPad 2 это выглядело
     * как «853x480@60 … avc1 (299)»: 299-я дорожка — это 1080p60, её
     * сервер завёл в начале и тут же спустился ниже, а объявление
     * не повторил.
     */
    NSInteger playingItag = [sabr deliveredVideoItag] > 0
        ? [sabr deliveredVideoItag] : [sabr playingItag];
    NSInteger audioItag = [sabr audioItag];

    NSDictionary *videoFormat = [self formatIn:json
                                          itag:playingItag
                                        height:(NSInteger)[self trackHeight:item]];
    NSDictionary *audioFormat = (audioItag > 0) ? [self formatIn:json itag:audioItag height:0] : nil;

    NSInteger fps = [[videoFormat objectForKey:@"fps"] integerValue];

    /**
     * Показываем размер и частоту самой дорожки — те, что записаны
     * в потоке, который мы отдаём декодеру.
     *
     * `presentationSize` отсюда убран намеренно. Он описывает слой
     * вывода, а не поток: на iPad 2 он показывал 853×480 и при 720p,
     * и при 1080p60, и мы полдня искали занижение, которого нет —
     * снятый с декодера кадр оказался ровно 1280×720. Прибор врал,
     * а не картинка.
     */
    NSInteger trackWidth = [[videoFormat objectForKey:@"width"] integerValue];
    NSInteger trackHeight = [[videoFormat objectForKey:@"height"] integerValue];

    NSString *current = @"—";

    if (trackWidth > 0 && trackHeight > 0) {
        current = [NSString stringWithFormat:@"%ldx%ld%@",
            (long)trackWidth, (long)trackHeight,
            fps > 0 ? [NSString stringWithFormat:@"@%ld", (long)fps] : @""];
    } else if ([self trackHeight:item] > 0) {
        // Дорожки в ответе не нашлось — берём размер у самого потока.
        CGSize natural = [self trackSize:item];

        current = [NSString stringWithFormat:@"%.0fx%.0f%@",
            natural.width, natural.height,
            fps > 0 ? [NSString stringWithFormat:@"@%ld", (long)fps] : @""];
    }

    /**
     * «Оптимальное» — это лучшее, что имеет смысл на **этом окне**,
     * а не вообще у ролика.
     *
     * Так это и понимает панель на сайте: она отвечает на вопрос «выше
     * какого разрешения показывать бессмысленно». Мы же писали сюда
     * наибольшее из доступных, и на iPad 2 с окном 1024×768 выходило
     * «1920x1080» — цифра, которой это устройство не покажет никогда
     * и не сможет раскодировать.
     */
    NSInteger fits = (NSInteger)(s.viewport.height > 0 ? s.viewport.height : 0);

    NSInteger best = 0;

    for (NSNumber *number in s.heights) {
        NSInteger height = [number integerValue];

        if (height > best && (fits <= 0 || height <= fits)) {
            best = height;
        }
    }

    // Ничего не помещается — берём наименьшее из того, что есть.
    if (best == 0) {
        for (NSNumber *number in s.heights) {
            NSInteger height = [number integerValue];

            if (best == 0 || height < best) {
                best = height;
            }
        }
    }

    NSString *optimal = (best > 0)
        ? [NSString stringWithFormat:@"%ldx%ld", (long)(best * 16 / 9), (long)best]
        : @"—";

    [self set:2 text:[NSString stringWithFormat:@"%@ / %@", current, optimal]];

    /**
     * Громкость у плеера спрашиваем с оглядкой.
     *
     * `volume` у `AVPlayer` появилась в iOS 7, а мы живём и на шестой,
     * и на пятой. Там это неизвестный вызов — исключение и мгновенное
     * падение: панель открывалась и тут же уносила с собой всё
     * приложение. На iPad 2 с iOS 6.1 так и было.
     *
     * Где спросить нельзя — показываем сотню: своей громкости
     * приложение не убавляет, а системную эта панель и не описывает.
     */
    float level = [player respondsToSelector:@selector(volume)] ? [player volume] : 1.0f;

    NSInteger volume = (NSInteger)(level * 100);

    NSDictionary *audioConfig = [[json objectForKey:@"playerConfig"] objectForKey:@"audioConfig"];
    NSNumber *loudness = [audioConfig isKindOfClass:[NSDictionary class]]
        ? [audioConfig objectForKey:@"loudnessDb"] : nil;

    [self set:3 text:[NSString stringWithFormat:@"%ld%% / %ld%%%@", (long)volume, (long)volume,
        loudness != nil
            ? [NSString stringWithFormat:@" (content loudness %.1fdB)", [loudness doubleValue]]
            : @""]];

    [self set:4 text:[NSString stringWithFormat:@"%@ / %@",
        [self codecOf:videoFormat itag:playingItag],
        audioFormat != nil ? [self codecOf:audioFormat itag:audioItag] : @"—"]];

    NSDictionary *color = [videoFormat objectForKey:@"colorInfo"];

    if (videoFormat == nil) {
        [self set:5 text:@"—"];
    } else if (![color isKindOfClass:[NSDictionary class]]) {
        // Обычные дорожки без описания — это bt709, как и на сайте.
        [self set:5 text:@"bt709 / bt709"];
    } else {
        [self set:5 text:[NSString stringWithFormat:@"%@ / %@",
            [self shortColor:[color objectForKey:@"primaries"]],
            [self shortColor:[color objectForKey:@"transferCharacteristics"]]]];
    }

    // Сеть: скорость сглаженная, деятельность — за прошедшую секунду.
    double speed = [YTPlaybackStats speedKbps];

    if (speed <= 0 && event != nil && [event observedBitrate] > 0) {
        speed = [event observedBitrate] / 1000.0;
    }

    long long total = (long long)[YTPlaybackStats totalBytes];
    long long delta = (_lastBytes < 0) ? 0 : total - _lastBytes;

    _lastBytes = total;

    [_speedGraph push:(float)speed];
    [_activityGraph push:(float)(delta / 1024.0)];

    [self set:6 text:[NSString stringWithFormat:@"%.0f Kbps", speed]];
    [self set:7 text:[NSString stringWithFormat:@"%lld KB", delta / 1024]];

    double now = CMTimeGetSeconds([player currentTime]);
    double health = 0;

    for (NSValue *value in [item loadedTimeRanges]) {
        CMTimeRange range = [value CMTimeRangeValue];
        double start = CMTimeGetSeconds(range.start);
        double end = start + CMTimeGetSeconds(range.duration);

        if (now >= start - 0.5 && now <= end && end - now > health) {
            health = end - now;
        }
    }

    [_bufferGraph push:(float)health];

    [self set:8 text:[NSString stringWithFormat:@"%.2f s", health]];

    NSMutableString *mystery = [NSMutableString string];

    [mystery appendString:(sabr != nil) ? @"SABR" : @"DIRECT"];

    if (sabr != nil) {
        [mystery appendFormat:@", rn:%ld, itag:%ld/%ld",
            (long)[sabr requests], (long)playingItag, (long)audioItag];
    }

    /**
     * Размер дорожки, каким его видит сам плеер, — рядом с тем,
     * что он показывает.
     *
     * `presentationSize` — это картинка на выходе, а `naturalSize`
     * дорожки — то, что записано в самом потоке. Если они расходятся,
     * значит устройство уменьшает картинку при раскодировании; если
     * совпадают и оба меньше нашей дорожки — значит поток к плееру
     * приходит уже уменьшенным, и виноват наш ремуксер. Одной цифрой
     * это не различить, и мы полдня гадали.
     */
    CGSize natural = [self trackSize:item];

    if (natural.width > 0) {
        [mystery appendFormat:@", nat:%.0fx%.0f", natural.width, natural.height];
    }

    [mystery appendFormat:@", s:%ld, b:%.3f-%.3f, rate:%.2f, AVPlayer",
        (long)[item status], now, now + health, s.rate];

    [self set:9 text:mystery];

    NSDate *date = [NSDate date];
    NSTimeZone *zone = [NSTimeZone localTimeZone];
    NSInteger offset = [zone secondsFromGMTForDate:date] / 60;

    [self set:10 text:[NSString stringWithFormat:@"%@ GMT%@%02ld%02ld (%@)",
        [_clock stringFromDate:date], offset < 0 ? @"-" : @"+",
        (long)(labs(offset) / 60), (long)(labs(offset) % 60),
        [zone localizedName:([zone isDaylightSavingTimeForDate:date]
                                 ? NSTimeZoneNameStyleDaylightSaving
                                 : NSTimeZoneNameStyleStandard)
                     locale:[NSLocale currentLocale]]]];
}

- (void)dealloc {
    [_timer invalidate];
}

@end
