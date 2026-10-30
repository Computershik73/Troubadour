#import "YTRoundedImageView.h"

#import <QuartzCore/QuartzCore.h>

#import "YTTheme.h"
#import "YTMemoryCensus.h"

/**
 * Кеш готовых скруглённых кадров.
 *
 * Скромнее, чем у самих превью: его задача — пережить прокрутку на пару
 * экранов назад, а не весь раздел. По нехватке памяти сбрасывается вместе
 * с ним.
 */
@interface YTFrameKey : NSObject <NSCopying>

@property (nonatomic, strong) UIImage *source;
@property (nonatomic, assign) CGSize size;
@property (nonatomic, assign) CGFloat radius;

@end

@implementation YTFrameKey

- (id)copyWithZone:(NSZone *)zone {
    YTFrameKey *copy = [[YTFrameKey allocWithZone:zone] init];

    copy.source = self.source;
    copy.size = self.size;
    copy.radius = self.radius;

    return copy;
}

- (NSUInteger)hash {
    // Адрес объекта в хеше участвует, но сам объект держится ссылкой —
    // иначе освободившийся адрес мог бы достаться другой картинке,
    // и из кеша вернулся бы чужой кадр.
    return (NSUInteger)(__bridge void *)self.source
         ^ (NSUInteger)(self.size.width * 4)
         ^ (NSUInteger)(self.size.height * 16)
         ^ (NSUInteger)(self.radius * 64);
}

- (BOOL)isEqual:(id)other {
    if (![other isKindOfClass:[YTFrameKey class]]) {
        return NO;
    }

    YTFrameKey *key = other;

    return key.source == self.source
        && CGSizeEqualToSize(key.size, self.size)
        && key.radius == self.radius;
}

@end


static YTCacheTally *YTFrameTally(void) {
    static YTCacheTally *tally = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{ tally = [[YTCacheTally alloc] init]; });

    return tally;
}

static NSCache *YTFrameCache(void) {
    static NSCache *cache = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        [cache setTotalCostLimit:6 * 1024 * 1024];
        [cache setDelegate:YTFrameTally()];

        [[NSNotificationCenter defaultCenter] addObserver:[YTRoundedImageView class]
                                                 selector:@selector(memoryCensus:)
                                                     name:YTMemoryCensusNotification
                                                   object:nil];
    });

    return cache;
}


@implementation YTRoundedImageView {
    UIImage *_image;
    CGSize _renderedFor;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    _cornerRadius = 0;
    _placeholderColor = [YTTheme videoPlaceholder];

    [self setOpaque:NO];
    [self setBackgroundColor:[UIColor clearColor]];

    // Только рисует — нажатие принимает то, внутри чего он лежит.
    // Без этого превью занимало бы большую часть карточки и молча забирало
    // касание себе: у UIView `userInteractionEnabled` включён с рождения.
    [self setUserInteractionEnabled:NO];

    return self;
}

- (void)setImage:(UIImage *)image {
    if (_image == image) {
        return;
    }

    _image = image;
    _renderedFor = CGSizeZero;

    [self rebuild];
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    _cornerRadius = cornerRadius;
    _renderedFor = CGSizeZero;

    [self rebuild];
}

- (void)setCircular:(BOOL)circular {
    _circular = circular;
    _renderedFor = CGSizeZero;

    [self rebuild];
}

- (void)setPlaceholderColor:(UIColor *)placeholderColor {
    _placeholderColor = placeholderColor;
    _renderedFor = CGSizeZero;

    [self rebuild];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    // Пересобираем только при смене размера: раскладка проходит гораздо
    // чаще, чем меняется место под картинку.
    if (!CGSizeEqualToSize(_renderedFor, [self bounds].size)) {
        [self rebuild];
    }
}

- (CGFloat)effectiveRadius {
    CGSize size = [self bounds].size;

    if (_circular) {
        return MIN(size.width, size.height) / 2;
    }

    return MIN(_cornerRadius, MIN(size.width, size.height) / 2);
}

- (void)rebuild {
    CGSize size = [self bounds].size;

    if (size.width <= 0 || size.height <= 0) {
        return;
    }

    _renderedFor = size;

    CGFloat radius = [self effectiveRadius];

    if (_image == nil) {
        [self showPlaceholder:radius];
        return;
    }

    YTFrameKey *key = [[YTFrameKey alloc] init];

    key.source = _image;
    key.size = size;
    key.radius = radius;

    UIImage *ready = [YTFrameCache() objectForKey:key];

    if (ready == nil) {
        ready = [self renderFrame:size radius:radius];

        if (ready != nil) {
            CGImageRef bitmap = [ready CGImage];
            NSUInteger cost = CGImageGetBytesPerRow(bitmap) * CGImageGetHeight(bitmap);

            [YTFrameTally() noteObject:ready cost:cost];
            [YTFrameCache() setObject:ready forKey:key cost:cost];
        }
    }

    // У кадра углы скруглены в нём самом — фон слоя под ним не нужен.
    [[self layer] setBackgroundColor:NULL];
    [[self layer] setCornerRadius:0];
    [[self layer] setContents:(__bridge id)[ready CGImage]];
}

/**
 * Заглушка — цветом фона слоя, а не картинкой.
 *
 * Прежде она рисовалась тем же путём, что и кадр, — отдельным растром
 * во весь размер места: так у пустого места были те же скруглённые углы.
 * Но растр заглушки весит ровно столько же, сколько кадр, и на iPad 2
 * карточка похожих шириной в 720 точек держала 1,2 МБ, даже не получив
 * картинки: двадцать карточек — 23 МБ одних заглушек, и ленивая
 * загрузка ничего не давала. Скругление фона слоя даёт ту же форму без
 * единого байта растра.
 */
- (void)showPlaceholder:(CGFloat)radius {
    CALayer *layer = [self layer];

    [layer setContents:nil];
    [layer setBackgroundColor:[(_placeholderColor ?: [YTTheme videoPlaceholder]) CGColor]];
    [layer setCornerRadius:radius];
}

- (CGFloat)screenScale {
    if ([[UIScreen mainScreen] respondsToSelector:@selector(scale)]) {
        return [[UIScreen mainScreen] scale];
    }

    return 1.0;
}

- (void)addRoundedPath:(CGContextRef)context rect:(CGRect)box radius:(CGFloat)radius {
    CGContextBeginPath(context);
    CGContextMoveToPoint(context, CGRectGetMinX(box) + radius, CGRectGetMinY(box));
    CGContextAddArcToPoint(context, CGRectGetMaxX(box), CGRectGetMinY(box),
                           CGRectGetMaxX(box), CGRectGetMaxY(box), radius);
    CGContextAddArcToPoint(context, CGRectGetMaxX(box), CGRectGetMaxY(box),
                           CGRectGetMinX(box), CGRectGetMaxY(box), radius);
    CGContextAddArcToPoint(context, CGRectGetMinX(box), CGRectGetMaxY(box),
                           CGRectGetMinX(box), CGRectGetMinY(box), radius);
    CGContextAddArcToPoint(context, CGRectGetMinX(box), CGRectGetMinY(box),
                           CGRectGetMaxX(box), CGRectGetMinY(box), radius);
    CGContextClosePath(context);
}

- (UIImage *)renderFrame:(CGSize)size radius:(CGFloat)radius {
    CGSize source = CGSizeMake(CGImageGetWidth([_image CGImage]),
                               CGImageGetHeight([_image CGImage]));

    /**
     * Растр — не плотнее самого исходника.
     *
     * Кадр рисовался в размер места на экране, сколько бы точек ни было
     * в превью: на iPad 2 исходник в 368 точек шириной ложился в карточку
     * на 720 — растр вчетверо больше по площади, а резче от этого
     * не становилось ничего. Теперь плотность растра ограничена плотностью
     * исходника, и слой растягивает его на место сам — тем же самым
     * сглаживанием, каким растягивал бы его рисунок.
     */
    CGFloat scale = [self screenScale];

    if (source.width > 0 && source.height > 0) {
        CGFloat available = MAX(source.width / size.width, source.height / size.height);

        scale = MAX((CGFloat)0.25, MIN(scale, available));
    }

    UIGraphicsBeginImageContextWithOptions(size, NO, scale);

    CGContextRef context = UIGraphicsGetCurrentContext();
    CGRect box = CGRectMake(0, 0, size.width, size.height);

    [self addRoundedPath:context rect:box radius:radius];
    CGContextClip(context);

    /**
     * Заполнение с сохранением пропорций — то же, что `Stretch="UniformToFill"`
     * у Image в XAML: картинка занимает всё место, лишнее по длинной стороне
     * обрезается. Превью роликов приходят 16:9, место под них тоже 16:9,
     * так что обрезать обычно нечего; а вот кружок канала приходит квадратным
     * и без этого растянулся бы.
     */
    if (source.width > 0 && source.height > 0) {
        CGFloat scale = MAX(size.width / source.width, size.height / source.height);

        CGFloat width = source.width * scale;
        CGFloat height = source.height * scale;

        [_image drawInRect:CGRectMake((size.width - width) / 2,
                                      (size.height - height) / 2,
                                      width, height)];
    }

    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return result;
}

+ (void)memoryCensus:(NSNotification *)note {
    [[[note userInfo] objectForKey:YTMemoryCensusNotesKey] addObject:
        [@"кеш скруглённых кадров " stringByAppendingString:[YTFrameTally() summary]]];
}

- (NSUInteger)contentsBytes {
    CGImageRef image = (__bridge CGImageRef)[[self layer] contents];

    return (image != NULL) ? CGImageGetBytesPerRow(image) * CGImageGetHeight(image) : 0;
}

- (void)dropContents {
    _image = nil;

    // Размер считаем «уже отрисованным»: раскладке перерисовывать нечего.
    _renderedFor = [self bounds].size;

    // Заглушка теперь цветом фона и памяти не стоит — пусть место не пустует.
    [self showPlaceholder:[self effectiveRadius]];
}

+ (void)trimFrames {
    [YTFrameCache() removeAllObjects];
}

@end
