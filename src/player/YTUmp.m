#import "YTUmp.h"

@implementation YTUmpPart

@synthesize type = _type;
@synthesize body = _body;

@end

@implementation YTUmp

/**
 * Число переменной длины по правилам UMP.
 *
 * Длину задаёт первый байт своими старшими битами, а сами разряды
 * идут младшими вперёд. Пять байт — особый случай: тогда первый байт
 * не несёт разрядов вовсе, и число лежит в четырёх следующих.
 *
 * Возвращает NO, если байтов не хватило: это не порча потока, а обычное
 * дело — часть пришла не целиком и дочитается следующим куском.
 */
static BOOL YTUmpVarint(const uint8_t *bytes, NSUInteger length,
                        NSUInteger *at, uint64_t *out) {
    if (*at >= length) {
        return NO;
    }

    uint8_t first = bytes[*at];
    NSUInteger size;
    uint64_t value;

    if ((first & 0x80) == 0x00) {
        size = 1;
        value = first;
    } else if ((first & 0xC0) == 0x80) {
        size = 2;
        value = first & 0x3F;
    } else if ((first & 0xE0) == 0xC0) {
        size = 3;
        value = first & 0x1F;
    } else if ((first & 0xF0) == 0xE0) {
        size = 4;
        value = first & 0x0F;
    } else if (first == 0xF0) {
        size = 5;
        value = 0;
    } else {
        return NO;
    }

    if (*at + size > length) {
        return NO;
    }

    /**
     * Разряды из первого байта уже взяты; остальные байты добавляются
     * старше их. Для пятибайтового случая разрядов в первом нет,
     * поэтому сдвиг начинается с нуля.
     */
    NSUInteger shift = (size == 5) ? 0 : (8 - size);

    for (NSUInteger i = 1; i < size; i++) {
        value |= ((uint64_t)bytes[*at + i]) << shift;

        shift += 8;
    }

    *at += size;
    *out = value;

    return YES;
}

+ (void)read:(NSData *)data
   remainder:(NSUInteger *)remainder
     handler:(void (^)(YTUmpPart *part))handler {
    const uint8_t *bytes = (const uint8_t *)[data bytes];
    NSUInteger length = [data length];
    NSUInteger at = 0;

    while (at < length) {
        /**
         * Начало части запоминаем до чтения заголовка: если тела
         * не хватило, отступить надо к самому началу части, а не
         * к тому месту, где кончились байты.
         */
        NSUInteger start = at;

        uint64_t type = 0;
        uint64_t size = 0;

        if (!YTUmpVarint(bytes, length, &at, &type) ||
            !YTUmpVarint(bytes, length, &at, &size) ||
            at + (NSUInteger)size > length) {
            at = start;
            break;
        }

        YTUmpPart *part = [[YTUmpPart alloc] init];

        part.type = (NSUInteger)type;
        part.body = [data subdataWithRange:NSMakeRange(at, (NSUInteger)size)];

        at += (NSUInteger)size;

        handler(part);
    }

    if (remainder != NULL) {
        *remainder = length - at;
    }
}

@end
