#import "YTRoundedImageView.h"

#import <QuartzCore/QuartzCore.h>

#import "YTTheme.h"

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


static NSCache *YTFrameCache(void) {
    static NSCache *cache = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        [cache setTotalCostLimit:6 * 1024 * 1024];
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
        // Заглушка рисуется тем же путём, что и кадр, — иначе у пустого
        // места были бы прямые углы, а у заполненного скруглённые, и при
        // догрузке картинки форма менялась бы на глазах.
        [[self layer] setContents:(__bridge id)[[self renderPlaceholder:size radius:radius] CGImage]];
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
            NSUInteger cost = (NSUInteger)(size.width * size.height * 4);
            [YTFrameCache() setObject:ready forKey:key cost:cost];
        }
    }

    [[self layer] setContents:(__bridge id)[ready CGImage]];
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

- (UIImage *)renderPlaceholder:(CGSize)size radius:(CGFloat)radius {
    UIGraphicsBeginImageContextWithOptions(size, NO, [self screenScale]);

    CGContextRef context = UIGraphicsGetCurrentContext();
    CGRect box = CGRectMake(0, 0, size.width, size.height);

    [self addRoundedPath:context rect:box radius:radius];

    CGContextSetFillColorWithColor(context,
        [(_placeholderColor ?: [YTTheme videoPlaceholder]) CGColor]);
    CGContextFillPath(context);

    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return result;
}

- (UIImage *)renderFrame:(CGSize)size radius:(CGFloat)radius {
    UIGraphicsBeginImageContextWithOptions(size, NO, [self screenScale]);

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
    CGSize source = CGSizeMake(CGImageGetWidth([_image CGImage]),
                               CGImageGetHeight([_image CGImage]));

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

+ (void)trimFrames {
    [YTFrameCache() removeAllObjects];
}

@end
