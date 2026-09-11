#import "YTZip.h"

#include <zlib.h>

/** Подписи разделов zip: оглавление, его конец и заголовок записи. */
static const uint32_t YTZipCentral = 0x02014b50;
static const uint32_t YTZipEnd = 0x06054b50;
static const uint32_t YTZipLocal = 0x04034b50;

@implementation YTZip

/**
 * Архив читается отображением в память, а не целиком.
 *
 * Тема для Anemone — это десятки мегабайт картинок, а нужен из них один
 * файл. Читать всё в память ради него на телефоне с половиной гигабайта
 * значит получить отказ системы ровно тогда, когда человек нажал кнопку.
 */
+ (NSData *)mapArchive:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path
                                          options:NSDataReadingMappedIfSafe
                                            error:NULL];

    if ([data length] < 22) {
        return nil;
    }

    return data;
}

static uint16_t readSmall(const uint8_t *at) {
    return (uint16_t)(at[0] | (at[1] << 8));
}

static uint32_t readWide(const uint8_t *at) {
    return (uint32_t)(at[0] | (at[1] << 8) | (at[2] << 16) | ((uint32_t)at[3] << 24));
}

/**
 * Где начинается оглавление.
 *
 * Его положение записано в самом конце файла, в записи «конец
 * оглавления». Она короткая, но за ней может тянуться необязательный
 * хвост-примечание, поэтому подпись ищется с конца — но не дальше, чем
 * этот хвост может быть длинным.
 */
+ (BOOL)findCentral:(NSData *)data start:(NSUInteger *)start count:(NSUInteger *)count {
    const uint8_t *bytes = [data bytes];
    NSUInteger length = [data length];

    NSUInteger limit = length > (0xFFFF + 22) ? (length - 0xFFFF - 22) : 0;

    for (NSUInteger at = length - 22; ; at--) {
        if (readWide(bytes + at) == YTZipEnd) {
            *count = readSmall(bytes + at + 10);
            *start = readWide(bytes + at + 16);

            return *start < length;
        }

        if (at == limit) {
            break;
        }
    }

    return NO;
}

/**
 * Обход оглавления.
 *
 * `body` зовётся на каждую запись. Возврат `YES` из него прекращает
 * обход — так ищется одно имя, не читая остального.
 */
+ (void)walk:(NSData *)data
        body:(BOOL (^)(NSString *name, uint16_t method,
                       uint32_t packed, uint32_t plain, uint32_t offset))body {
    NSUInteger start = 0;
    NSUInteger count = 0;

    if (![self findCentral:data start:&start count:&count]) {
        return;
    }

    const uint8_t *bytes = [data bytes];
    NSUInteger length = [data length];

    NSUInteger at = start;

    for (NSUInteger index = 0; index < count; index++) {
        if (at + 46 > length || readWide(bytes + at) != YTZipCentral) {
            return;
        }

        uint16_t method = readSmall(bytes + at + 10);
        uint32_t packed = readWide(bytes + at + 20);
        uint32_t plain = readWide(bytes + at + 24);

        uint16_t nameLength = readSmall(bytes + at + 28);
        uint16_t extraLength = readSmall(bytes + at + 30);
        uint16_t commentLength = readSmall(bytes + at + 32);

        uint32_t offset = readWide(bytes + at + 42);

        if (at + 46 + nameLength > length) {
            return;
        }

        NSString *name = [[NSString alloc] initWithBytes:bytes + at + 46
                                                  length:nameLength
                                                encoding:NSUTF8StringEncoding];

        if (name == nil) {
            name = [[NSString alloc] initWithBytes:bytes + at + 46
                                            length:nameLength
                                          encoding:NSISOLatin1StringEncoding];
        }

        if (name != nil && body(name, method, packed, plain, offset)) {
            return;
        }

        at += 46 + nameLength + extraLength + commentLength;
    }
}

+ (NSArray *)namesInArchive:(NSString *)path {
    NSData *data = [self mapArchive:path];

    if (data == nil) {
        return [NSArray array];
    }

    NSMutableArray *names = [NSMutableArray array];

    [self walk:data body:^BOOL(NSString *name, uint16_t method,
                               uint32_t packed, uint32_t plain, uint32_t offset) {
        [names addObject:name];

        return NO;
    }];

    return names;
}

/** Развернуть кусок, сжатый deflate. Поток без заголовка — оттого −15. */
+ (NSData *)inflate:(const uint8_t *)bytes length:(uint32_t)length plain:(uint32_t)plain {
    if (plain == 0) {
        return [NSData data];
    }

    NSMutableData *out = [NSMutableData dataWithLength:plain];

    z_stream stream;

    memset(&stream, 0, sizeof(stream));

    stream.next_in = (Bytef *)bytes;
    stream.avail_in = length;
    stream.next_out = (Bytef *)[out mutableBytes];
    stream.avail_out = plain;

    if (inflateInit2(&stream, -15) != Z_OK) {
        return nil;
    }

    int state = inflate(&stream, Z_FINISH);

    inflateEnd(&stream);

    if (state != Z_STREAM_END) {
        return nil;
    }

    [out setLength:stream.total_out];

    return out;
}

+ (NSData *)dataForEntry:(NSString *)name inArchive:(NSString *)path {
    NSData *data = [self mapArchive:path];

    if (data == nil || [name length] == 0) {
        return nil;
    }

    const uint8_t *bytes = [data bytes];
    NSUInteger length = [data length];

    __block NSData *found = nil;

    [self walk:data body:^BOOL(NSString *entry, uint16_t method,
                               uint32_t packed, uint32_t plain, uint32_t offset) {
        if (![entry isEqualToString:name]) {
            return NO;
        }

        /**
         * Длины имени и довеска берутся у **местного** заголовка, а не
         * у оглавления: у одной и той же записи они бывают разными,
         * и по числам из оглавления мы попали бы мимо начала данных.
         */
        if (offset + 30 > length || readWide(bytes + offset) != YTZipLocal) {
            return YES;
        }

        uint16_t nameLength = readSmall(bytes + offset + 26);
        uint16_t extraLength = readSmall(bytes + offset + 28);

        NSUInteger at = offset + 30 + nameLength + extraLength;

        if (at + packed > length) {
            return YES;
        }

        if (method == 0) {
            found = [NSData dataWithBytes:bytes + at length:packed];
        } else if (method == 8) {
            found = [self inflate:bytes + at length:packed plain:plain];
        }

        return YES;
    }];

    return found;
}

@end
