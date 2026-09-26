#import <Foundation/Foundation.h>
#import <objc/runtime.h>

/**
 * Индексация скобками — `dict[key]`, `array[i]` — на iOS 5.
 *
 * Компилятор превращает скобки в вызовы `objectForKeyedSubscript:`,
 * `setObject:forKeyedSubscript:`, `objectAtIndexedSubscript:` и
 * `setObject:atIndexedSubscript:`. В Foundation они есть с iOS 6, а на
 * iOS 5 их подкладывает библиотека arclite, которую Xcode линкует сам.
 * Наша сборка её не линкует — и первый же `dict[key]` падал с
 * «unrecognized selector».
 *
 * Своё приложение пишет `objectForKey:`, а вот код обхода блокировок
 * (Dante-WARP) — скобками повсюду. Обход на iOS 5 падал сразу после
 * включения, а раз он включён, то и на каждом следующем запуске.
 *
 * Делаем то же, что arclite: если метода у класса нет — добавляем его,
 * через давно существующие `objectForKey:` и прочие. Если есть (iOS 6
 * и новее) — не трогаем ничего.
 */

static id YTDictionaryGet(NSDictionary *me, SEL _cmd, id key) {
    return [me objectForKey:key];
}

static void YTDictionarySet(NSMutableDictionary *me, SEL _cmd, id object, id key) {
    // Присвоение nil по скобкам убирает ключ — так ведёт себя и iOS 6.
    if (object == nil) {
        [me removeObjectForKey:key];
    } else {
        [me setObject:object forKey:key];
    }
}

static id YTArrayGet(NSArray *me, SEL _cmd, NSUInteger index) {
    return [me objectAtIndex:index];
}

static void YTArraySet(NSMutableArray *me, SEL _cmd, id object, NSUInteger index) {
    // Индекс сразу за концом — добавление, как у iOS 6.
    if (index == [me count]) {
        [me addObject:object];
    } else {
        [me replaceObjectAtIndex:index withObject:object];
    }
}

static void YTAddIfMissing(Class cls, SEL selector, IMP imp, const char *types) {
    if (cls == Nil || [cls instancesRespondToSelector:selector]) {
        return;
    }

    class_addMethod(cls, selector, imp, types);
}

__attribute__((constructor))
static void YTInstallSubscripting(void) {
    @autoreleasepool {
        YTAddIfMissing([NSDictionary class], @selector(objectForKeyedSubscript:),
                       (IMP)YTDictionaryGet, "@@:@");

        YTAddIfMissing([NSMutableDictionary class], @selector(setObject:forKeyedSubscript:),
                       (IMP)YTDictionarySet, "v@:@@");

        // NSUInteger на armv7 — это I, на arm64 — Q; берём у компилятора.
        NSString *get = [NSString stringWithFormat:@"@@:%s", @encode(NSUInteger)];
        NSString *set = [NSString stringWithFormat:@"v@:@%s", @encode(NSUInteger)];

        YTAddIfMissing([NSArray class], @selector(objectAtIndexedSubscript:),
                       (IMP)YTArrayGet, [get UTF8String]);

        YTAddIfMissing([NSMutableArray class], @selector(setObject:atIndexedSubscript:),
                       (IMP)YTArraySet, [set UTF8String]);
    }
}
