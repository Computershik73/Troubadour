#import "YTProto.h"

/** Тип поля: целое переменной длины. */
static const NSUInteger YTProtoVarint = 0;

/** Тип поля: длина, а за ней столько байт. */
static const NSUInteger YTProtoBytes = 2;

#pragma mark Сборка

@implementation YTProtoWriter {
    NSMutableData *_body;
}

+ (YTProtoWriter *)writer {
    return [[YTProtoWriter alloc] init];
}

- (id)init {
    self = [super init];

    if (self != nil) {
        _body = [NSMutableData data];
    }

    return self;
}

/**
 * Целое переменной длины: по семь бит на байт, старший бит — признак
 * того, что байт не последний. Маленькие числа занимают один байт,
 * и на этом весь формат и держится.
 */
static void YTAppendVarint(NSMutableData *body, uint64_t value) {
    uint8_t byte;

    do {
        byte = (uint8_t)(value & 0x7F);
        value >>= 7;

        if (value != 0) {
            byte |= 0x80;
        }

        [body appendBytes:&byte length:1];
    } while (value != 0);
}

/** Заголовок поля: номер и тип, слитые в одно число. */
- (void)putTag:(NSUInteger)field type:(NSUInteger)type {
    YTAppendVarint(_body, ((uint64_t)field << 3) | (uint64_t)type);
}

- (void)putVarint:(uint64_t)value field:(NSUInteger)field {
    [self putTag:field type:YTProtoVarint];

    YTAppendVarint(_body, value);
}

- (void)putBool:(BOOL)value field:(NSUInteger)field {
    [self putVarint:(value ? 1 : 0) field:field];
}

- (void)putFloat:(float)value field:(NSUInteger)field {
    // Тип 5 — ровно четыре байта, без длины.
    [self putTag:field type:5];

    /**
     * Число кладётся так, как лежит в памяти, младшим байтом вперёд.
     * Все наши устройства — ARM в обычном порядке байт, так что просто
     * копируем и расписываем по одному.
     */
    uint32_t bits = 0;

    memcpy(&bits, &value, sizeof(bits));

    for (NSUInteger i = 0; i < 4; i++) {
        uint8_t byte = (uint8_t)((bits >> (i * 8)) & 0xFF);

        [_body appendBytes:&byte length:1];
    }
}

- (void)putData:(NSData *)value field:(NSUInteger)field {
    if (value == nil) {
        return;
    }

    [self putTag:field type:YTProtoBytes];

    YTAppendVarint(_body, (uint64_t)[value length]);

    [_body appendData:value];
}

- (void)putString:(NSString *)value field:(NSUInteger)field {
    if ([value length] == 0) {
        return;
    }

    [self putData:[value dataUsingEncoding:NSUTF8StringEncoding] field:field];
}

- (void)putMessage:(YTProtoWriter *)value field:(NSUInteger)field {
    if (value == nil) {
        return;
    }

    [self putData:[value data] field:field];
}

- (NSData *)data {
    return _body;
}

@end

#pragma mark Разбор

@implementation YTProtoReader {
    NSData *_body;
    NSUInteger _at;

    NSUInteger _field;
    NSUInteger _type;

    /** Границы значения текущего поля. */
    NSUInteger _valueAt;
    NSUInteger _valueLength;

    /** Значение поля-числа: у него границ нет, оно уже прочитано. */
    uint64_t _value;
}

+ (YTProtoReader *)readerWithData:(NSData *)data {
    YTProtoReader *reader = [[YTProtoReader alloc] init];

    reader->_body = data;

    return reader;
}

/**
 * Читает целое переменной длины. Возвращает NO, если байты кончились
 * посреди числа, — так распознаётся обрыв.
 */
- (BOOL)readVarint:(uint64_t *)out {
    const uint8_t *bytes = (const uint8_t *)[_body bytes];
    NSUInteger length = [_body length];

    uint64_t result = 0;
    NSUInteger shift = 0;

    while (_at < length) {
        uint8_t byte = bytes[_at++];

        result |= ((uint64_t)(byte & 0x7F)) << shift;

        if ((byte & 0x80) == 0) {
            *out = result;

            return YES;
        }

        shift += 7;

        // Больше десяти байт в 64-битное число не влезет — значит, мусор.
        if (shift > 63) {
            return NO;
        }
    }

    return NO;
}

- (BOOL)next {
    NSUInteger length = [_body length];

    if (_at >= length) {
        return NO;
    }

    uint64_t tag = 0;

    if (![self readVarint:&tag]) {
        return NO;
    }

    _field = (NSUInteger)(tag >> 3);
    _type = (NSUInteger)(tag & 0x07);

    _value = 0;
    _valueAt = 0;
    _valueLength = 0;

    if (_type == YTProtoVarint) {
        return [self readVarint:&_value];
    }

    if (_type == YTProtoBytes) {
        uint64_t size = 0;

        if (![self readVarint:&size] || _at + (NSUInteger)size > length) {
            return NO;
        }

        _valueAt = _at;
        _valueLength = (NSUInteger)size;

        _at += (NSUInteger)size;

        return YES;
    }

    /**
     * Остальные типы нам не встречаются, но пропустить их надо
     * правильно, иначе разбор поедет. 1 — восемь байт, 5 — четыре;
     * групп (3 и 4) в этих сообщениях нет.
     */
    if (_type == 1 || _type == 5) {
        NSUInteger skip = (_type == 1) ? 8 : 4;

        if (_at + skip > length) {
            return NO;
        }

        _at += skip;

        return YES;
    }

    return NO;
}

- (NSUInteger)field {
    return _field;
}

- (uint64_t)takeVarint {
    return (_type == YTProtoVarint) ? _value : 0;
}

- (NSData *)takeData {
    if (_type != YTProtoBytes) {
        return nil;
    }

    return [_body subdataWithRange:NSMakeRange(_valueAt, _valueLength)];
}

- (NSString *)takeString {
    NSData *data = [self takeData];

    if (data == nil) {
        return nil;
    }

    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

@end
