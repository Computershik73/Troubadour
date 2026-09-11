#import "YTJson.h"

#import "YTText.h"

/**
 * Достаёт значение по ключу, сводя к nil обе разновидности пустоты:
 * отсутствующий ключ и присланный сервером null (он приходит как NSNull).
 */
static id YTValue(NSDictionary *parent, NSString *key) {
    if (![parent isKindOfClass:[NSDictionary class]] || key == nil) {
        return nil;
    }

    id value = [parent objectForKey:key];
    if (value == nil || value == [NSNull null]) {
        return nil;
    }

    return value;
}

@implementation YTJson

+ (id)parseAny:(NSData *)data {
    if ([data length] == 0) {
        return nil;
    }

    NSError *error = nil;

    return [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
}

+ (NSDictionary *)parse:(NSData *)data {
    id result = [self parseAny:data];

    // Верхним уровнем InnerTube всегда отдаёт объект; массив приходит только
    // внутри полей, поэтому чужой тип здесь означает не тот ответ.
    if (![result isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    return result;
}

+ (NSData *)encode:(id)object {
    if (object == nil) {
        object = [NSDictionary dictionary];
    }

    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];

    return data ?: [NSData data];
}

+ (NSDictionary *)objectIn:(NSDictionary *)parent key:(NSString *)key {
    id value = YTValue(parent, key);
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

+ (NSArray *)arrayIn:(NSDictionary *)parent key:(NSString *)key {
    id value = YTValue(parent, key);
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

+ (NSDictionary *)objectAt:(NSArray *)array index:(NSUInteger)index {
    if (![array isKindOfClass:[NSArray class]] || index >= [array count]) {
        return nil;
    }

    id value = [array objectAtIndex:index];
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

+ (NSString *)textIn:(NSDictionary *)parent key:(NSString *)key {
    NSString *value = [self stringIn:parent key:key];
    return [value length] > 0 ? value : nil;
}

+ (NSString *)stringIn:(NSDictionary *)parent key:(NSString *)key {
    return [self stringIn:parent key:key fallback:nil];
}

/**
 * Строка из ответа — уже проверенная.
 *
 * Здесь единственная воронка, через которую весь текст сервера входит
 * в приложение: и названия, и имена каналов, и подписи кнопок в панелях.
 * Проверка стоит именно тут, а не у каждой подписи, потому что показать
 * этот текст можно по-разному — подписью, заголовком кнопки, строкой
 * системного листа, — а испортить его достаточно один раз.
 *
 * Разбирается ответ на чужом потоке, но проверка ни на что в приложении
 * не смотрит и помнит уже спрошенное, так что чужому потоку не мешает.
 */
+ (NSString *)stringIn:(NSDictionary *)parent key:(NSString *)key
              fallback:(NSString *)fallback {
    id value = YTValue(parent, key);
    if (value == nil) {
        return fallback;
    }

    if ([value isKindOfClass:[NSString class]]) {
        return YTSafeText(value);
    }

    // Числа приходят то числом, то строкой — `lengthSeconds` тому пример.
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value stringValue];
    }

    return fallback;
}

+ (NSInteger)intIn:(NSDictionary *)parent key:(NSString *)key {
    return [self intIn:parent key:key fallback:0];
}

+ (NSInteger)intIn:(NSDictionary *)parent key:(NSString *)key
          fallback:(NSInteger)fallback {
    id value = YTValue(parent, key);
    if (value == nil) {
        return fallback;
    }

    if ([value isKindOfClass:[NSNumber class]]) {
        return [value integerValue];
    }

    if ([value isKindOfClass:[NSString class]]) {
        // `integerValue` у не-числа даёт 0, а нам нужен именно fallback:
        // «0 просмотров» и «поле не пришло» — разные вещи.
        NSScanner *scanner = [NSScanner scannerWithString:value];
        long long parsed = 0;

        if ([scanner scanLongLong:&parsed] && [scanner isAtEnd]) {
            return (NSInteger)parsed;
        }
    }

    return fallback;
}

+ (double)doubleIn:(NSDictionary *)parent key:(NSString *)key
          fallback:(double)fallback {
    id value = YTValue(parent, key);
    if (value == nil) {
        return fallback;
    }

    if ([value isKindOfClass:[NSNumber class]]) {
        return [value doubleValue];
    }

    if ([value isKindOfClass:[NSString class]]) {
        NSScanner *scanner = [NSScanner scannerWithString:value];
        double parsed = 0;

        if ([scanner scanDouble:&parsed] && [scanner isAtEnd]) {
            return parsed;
        }
    }

    return fallback;
}

+ (BOOL)boolIn:(NSDictionary *)parent key:(NSString *)key {
    return [self boolIn:parent key:key fallback:NO];
}

+ (BOOL)boolIn:(NSDictionary *)parent key:(NSString *)key fallback:(BOOL)fallback {
    id value = YTValue(parent, key);
    if (value == nil) {
        return fallback;
    }

    if ([value isKindOfClass:[NSNumber class]]) {
        return [value boolValue];
    }

    if ([value isKindOfClass:[NSString class]]) {
        return [value caseInsensitiveCompare:@"true"] == NSOrderedSame;
    }

    return fallback;
}

#pragma mark Формы InnerTube

+ (NSString *)renderedValue:(NSDictionary *)node {
    if (![node isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSString *simple = [self textIn:node key:@"simpleText"];
    if (simple != nil) {
        return simple;
    }

    /**
     * Третья форма, которой в UWP-версии ещё не было: `{"content": "…"}`.
     *
     * Так размечены новые view-model — `lockupMetadataViewModel`,
     * `contentMetadataViewModel` и прочие, которыми WEB-клиент теперь
     * присылает похожие ролики. Разбор знал только `simpleText` и `runs`,
     * и у таких карточек не находилось ни названия, ни автора: оставалось
     * одно превью, собранное по идентификатору.
     */
    NSString *content = [self textIn:node key:@"content"];
    if (content != nil) {
        return content;
    }

    NSArray *runs = [self arrayIn:node key:@"runs"];
    if (runs == nil) {
        return nil;
    }

    NSMutableString *joined = [NSMutableString string];

    for (id item in runs) {
        NSString *text = [self stringIn:item key:@"text"];
        if (text != nil) {
            [joined appendString:text];
        }
    }

    return [joined length] > 0 ? joined : nil;
}

+ (NSString *)renderedText:(NSDictionary *)parent key:(NSString *)key {
    return [self renderedValue:[self objectIn:parent key:key]];
}

+ (NSString *)thumbnailIn:(NSDictionary *)parent key:(NSString *)key minWidth:(CGFloat)width {
    /**
     * Список картинок приходит четырьмя видами, и все они здесь.
     *
     *     {"sources": [ … ]}                      — новые view-model
     *     {"thumbnails": [ … ]}                   — старые рендереры
     *     {"thumbnail": {"thumbnails": [ … ]}}    — они же, завёрнутые
     *
     * Первый вид долго не читался вовсе: у него список лежит **прямо**
     * под ключом, а помощник ждал под ним объект и искал внутри
     * `thumbnails`. Оттого пропадали превью подборок на странице канала
     * и подложка у новой шапки: их адреса лежат именно в `sources`.
     */
    NSArray *list = [self arrayIn:parent key:key];

    if (list == nil) {
        NSDictionary *holder = [self objectIn:parent key:key];

        list = [self arrayIn:holder key:@"thumbnails"];

        if (list == nil) {
            list = [self arrayIn:holder key:@"sources"];
        }

        if (list == nil) {
            NSDictionary *inner = [self objectIn:holder key:@"thumbnail"];
            list = [self arrayIn:inner key:@"thumbnails"];
        }
    }

    if ([list count] == 0) {
        return nil;
    }

    NSString *best = nil;

    for (id item in list) {
        NSString *url = [self textIn:item key:@"url"];
        if (url == nil) {
            continue;
        }

        best = url;

        // Список идёт от мелкой к крупной: как только дошли до достаточно
        // широкой, дальше смотреть незачем — крупнее только тяжелее.
        if (width > 0 && [self intIn:item key:@"width"] >= (NSInteger)width) {
            break;
        }
    }

    if (best == nil) {
        return nil;
    }

    // Часть адресов приходит без схемы: «//i.ytimg.com/…». NSURL на такой
    // отвечает адресом без хоста, и запрос уходит в никуда.
    if ([best hasPrefix:@"//"]) {
        return [@"https:" stringByAppendingString:best];
    }

    return best;
}

#pragma mark Обход дерева

/** Общий обход: собирает найденное в out, пока не кончится лимит узлов. */
static void YTWalk(NSString *key, id node, NSMutableArray *out,
                   NSUInteger limit, NSUInteger *visited, BOOL stopAtFirst) {
    if (*visited >= limit) {
        return;
    }

    if ([node isKindOfClass:[NSDictionary class]]) {
        (*visited)++;

        id found = [node objectForKey:key];

        if ([found isKindOfClass:[NSDictionary class]]) {
            [out addObject:found];

            if (stopAtFirst) {
                return;
            }
        }

        for (id child in [node allValues]) {
            YTWalk(key, child, out, limit, visited, stopAtFirst);

            if (stopAtFirst && [out count] > 0) {
                return;
            }

            if (*visited >= limit) {
                return;
            }
        }

        return;
    }

    if ([node isKindOfClass:[NSArray class]]) {
        for (id child in node) {
            YTWalk(key, child, out, limit, visited, stopAtFirst);

            if (stopAtFirst && [out count] > 0) {
                return;
            }

            if (*visited >= limit) {
                return;
            }
        }
    }
}

+ (NSDictionary *)findFirst:(NSString *)key in:(id)tree limit:(NSUInteger)limit {
    NSMutableArray *out = [NSMutableArray array];
    NSUInteger visited = 0;

    YTWalk(key, tree, out, limit > 0 ? limit : NSUIntegerMax, &visited, YES);

    return [out count] > 0 ? [out objectAtIndex:0] : nil;
}

+ (NSArray *)findAll:(NSString *)key in:(id)tree limit:(NSUInteger)limit {
    NSMutableArray *out = [NSMutableArray array];
    NSUInteger visited = 0;

    YTWalk(key, tree, out, limit > 0 ? limit : NSUIntegerMax, &visited, NO);

    return out;
}

/**
 * Тот же обход, но берущий строку, а не словарь.
 *
 * Отдельной веткой, а не признаком у YTWalk: тот кладёт найденное
 * в общий список объектов, и подмешивать туда строки значило бы
 * заставить всех зовущих проверять род каждого найденного.
 */
static NSString *YTWalkString(NSString *key, id node,
                              NSUInteger limit, NSUInteger *visited) {
    if (*visited >= limit) {
        return nil;
    }

    if ([node isKindOfClass:[NSDictionary class]]) {
        (*visited)++;

        id found = [node objectForKey:key];

        if ([found isKindOfClass:[NSString class]] && [found length] > 0) {
            return found;
        }

        for (id child in [node allValues]) {
            NSString *deeper = YTWalkString(key, child, limit, visited);

            if (deeper != nil) {
                return deeper;
            }

            if (*visited >= limit) {
                return nil;
            }
        }

        return nil;
    }

    if ([node isKindOfClass:[NSArray class]]) {
        for (id child in node) {
            NSString *deeper = YTWalkString(key, child, limit, visited);

            if (deeper != nil) {
                return deeper;
            }

            if (*visited >= limit) {
                return nil;
            }
        }
    }

    return nil;
}

+ (NSString *)findString:(NSString *)key in:(id)tree limit:(NSUInteger)limit {
    NSUInteger visited = 0;

    return YTWalkString(key, tree, limit > 0 ? limit : NSUIntegerMax, &visited);
}

/** Тот же обход, но проверяющий сразу целый набор имён. */
static void YTWalkAny(NSSet *keys, id node, NSMutableArray *out,
                      NSUInteger limit, NSUInteger *visited) {
    if (*visited >= limit) {
        return;
    }

    if ([node isKindOfClass:[NSDictionary class]]) {
        (*visited)++;

        for (NSString *key in [node allKeys]) {
            if (![keys containsObject:key]) {
                continue;
            }

            id found = [node objectForKey:key];

            if ([found isKindOfClass:[NSDictionary class]]) {
                [out addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                    key, @"name", found, @"node", nil]];
            }
        }

        for (id child in [node allValues]) {
            YTWalkAny(keys, child, out, limit, visited);

            if (*visited >= limit) {
                return;
            }
        }

        return;
    }

    if ([node isKindOfClass:[NSArray class]]) {
        for (id child in node) {
            YTWalkAny(keys, child, out, limit, visited);

            if (*visited >= limit) {
                return;
            }
        }
    }
}

+ (NSArray *)findAllOfAny:(NSArray *)keys in:(id)tree limit:(NSUInteger)limit {
    NSMutableArray *out = [NSMutableArray array];
    NSUInteger visited = 0;

    YTWalkAny([NSSet setWithArray:keys], tree, out,
              limit > 0 ? limit : NSUIntegerMax, &visited);

    return out;
}

@end
