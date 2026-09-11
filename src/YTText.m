#import "YTText.h"

#import <CoreText/CoreText.h>

/**
 * Есть ли в системе хоть один шрифт с глифом для этого знака.
 *
 * Сперва спрашиваем прямо у шрифта значков. Через подбор
 * (`CTFontCreateForString`) спрашивать нельзя: на незнакомый знак система
 * отдаёт шрифт-последнюю-надежду, а у того глиф есть на всё подряд —
 * пустая рамка. Ответ выходил «нарисую», знак оставался в подписи,
 * и на нём всё падало.
 *
 * Обычные знаки — стрелки, ноты, редкие письменности — значкового шрифта
 * не касаются, их по-прежнему ищет подбор, но теперь с проверкой, кого он
 * вернул: последняя надежда за ответ не считается.
 */
static BOOL YTSystemCanDraw(NSString *piece) {
    static CTFontRef emoji = NULL;
    static CTFontRef plain = NULL;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        emoji = CTFontCreateWithName(CFSTR("AppleColorEmoji"), 14, NULL);
        plain = CTFontCreateWithName(CFSTR("Helvetica"), 14, NULL);
    });

    NSUInteger length = MIN([piece length], (NSUInteger)2);

    unichar units[2] = {0, 0};

    [piece getCharacters:units range:NSMakeRange(0, length)];

    // Пара — только когда это суррогаты; иначе спрашиваем про один знак.
    if (length == 2 && !(units[0] >= 0xD800 && units[0] <= 0xDBFF)) {
        length = 1;
    }

    CGGlyph glyphs[2] = {0, 0};

    if (emoji != NULL) {
        CTFontGetGlyphsForCharacters(emoji, units, glyphs, (CFIndex)length);

        // У пары суррогатов глиф один и лежит в первой ячейке; во второй
        // ноль — потому судим по первой, а не по ответу «да/нет».
        if (glyphs[0] != 0) {
            return YES;
        }
    }

    if (plain == NULL) {
        return YES;
    }

    NSString *scalar = [NSString stringWithCharacters:units length:length];

    CTFontRef found = CTFontCreateForString(plain, (__bridge CFStringRef)scalar,
                                            CFRangeMake(0, (CFIndex)length));

    if (found == NULL) {
        return NO;
    }

    NSString *name = CFBridgingRelease(CTFontCopyPostScriptName(found));

    BOOL lastResort = [name rangeOfString:@"LastResort"].location != NSNotFound;

    glyphs[0] = 0;
    glyphs[1] = 0;

    CTFontGetGlyphsForCharacters(found, units, glyphs, (CFIndex)length);

    CFRelease(found);

    return !lastResort && glyphs[0] != 0;
}

/**
 * То же, но с памятью об уже спрошенном.
 *
 * Знаков в обиходе немного, а строк с ними — тысячи: одни и те же значки
 * ходят по всей ленте. Спрашивать систему о каждом заново незачем,
 * тем более что разбор ответа идёт на чужом потоке и торопится.
 */
static BOOL YTSystemCanDrawCached(NSString *piece) {
    static NSMutableDictionary *known = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        known = [[NSMutableDictionary alloc] init];
    });

    @synchronized (known) {
        NSNumber *answer = [known objectForKey:piece];

        if (answer != nil) {
            return [answer boolValue];
        }
    }

    BOOL drawable = YTSystemCanDraw(piece);

    @synchronized (known) {
        // Потолок на всякий случай: словарь растёт от чужих данных,
        // а расти ему бесконечно незачем.
        if ([known count] > 4000) {
            [known removeAllObjects];
        }

        [known setObject:[NSNumber numberWithBool:drawable] forKey:piece];
    }

    return drawable;
}

/** Выбрасывает знаки, которых нет ни в одном шрифте системы. */
static NSString *YTDrawableText(NSString *text) {
    NSUInteger count = [text length];

    /**
     * Быстрая проверка: пока все единицы ниже 0x2000, это обычный текст —
     * буквы, цифры, знаки препинания, — и ни один шрифт на нём не споткнётся.
     * Такова подавляющая часть строк, и до разбора дело не доходит.
     */
    BOOL exotic = NO;

    for (NSUInteger i = 0; i < count; i++) {
        if ([text characterAtIndex:i] >= 0x2000) {
            exotic = YES;
            break;
        }
    }

    if (!exotic) {
        return text;
    }

    NSMutableString *kept = [NSMutableString stringWithCapacity:count];
    __block NSUInteger dropped = 0;

    [text enumerateSubstringsInRange:NSMakeRange(0, count)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *piece, NSRange range,
                                       NSRange enclosing, BOOL *stop) {
        if ([piece length] == 1 && [piece characterAtIndex:0] < 0x2000) {
            [kept appendString:piece];
            return;
        }

        if (YTSystemCanDrawCached(piece)) {
            [kept appendString:piece];
            return;
        }

        dropped++;
    }];

    if (dropped == 0) {
        return text;
    }

    NSLog(@"[YouTube/Текст] Нет глифов для %lu знаков, убираю их из «%@»",
          (unsigned long)dropped, text);

    return kept;
}

NSString *YTSafeText(NSString *text) {
    if ([text length] == 0) {
        return text;
    }

    /**
     * Строка, которую нельзя записать в UTF-8, — это строка с половиной
     * суррогатной пары. Правильный UTF-16 в UTF-8 переводится всегда,
     * так что проверка заодно и быстрая.
     */
    if ([text canBeConvertedToEncoding:NSUTF8StringEncoding]) {
        return YTDrawableText(text);
    }

    NSUInteger count = [text length];
    unichar *units = malloc(count * sizeof(unichar));

    if (units == NULL) {
        return @"";
    }

    [text getCharacters:units range:NSMakeRange(0, count)];

    for (NSUInteger i = 0; i < count; i++) {
        unichar unit = units[i];

        // Старшая половина: годна, только если за ней идёт младшая.
        if (unit >= 0xD800 && unit <= 0xDBFF) {
            if (i + 1 < count && units[i + 1] >= 0xDC00 && units[i + 1] <= 0xDFFF) {
                i++;
                continue;
            }

            units[i] = 0xFFFD;
            continue;
        }

        // Младшая половина сама по себе — всегда обломок.
        if (unit >= 0xDC00 && unit <= 0xDFFF) {
            units[i] = 0xFFFD;
        }
    }

    NSString *fixed = [NSString stringWithCharacters:units length:count];

    free(units);

    NSLog(@"[YouTube/Текст] Оборванная пара UTF-16, чиню: «%@»", fixed);

    return YTDrawableText(fixed);
}
