#import "YTJSEngine.h"

#import <dlfcn.h>

/**
 * Типы C API JavaScriptCore — свои, без заголовков фреймворка.
 *
 * С заголовками компилятор принял бы прямые вызовы, и бинарник получил бы
 * ссылки на библиотеку, которой на iOS 5 среди открытых нет: приложение
 * не запустилось бы вовсе. Указатели на функции такого не делают.
 */
typedef const struct OpaqueJSContext *YTJSContextRef;
typedef struct OpaqueJSContext *YTJSGlobalContextRef;
typedef struct OpaqueJSString *YTJSStringRef;
typedef struct OpaqueJSClass *YTJSClassRef;
typedef const struct OpaqueJSValue *YTJSValueRef;
typedef struct OpaqueJSValue *YTJSObjectRef;
typedef unsigned short YTJSChar;

typedef YTJSValueRef (*YTJSCallback)(YTJSContextRef context, YTJSObjectRef function,
                                     YTJSObjectRef thisObject, size_t count,
                                     const YTJSValueRef arguments[], YTJSValueRef *exception);

static struct {
    YTJSGlobalContextRef (*contextCreate)(YTJSClassRef globalClass);
    void (*contextRelease)(YTJSGlobalContextRef context);
    YTJSObjectRef (*globalObject)(YTJSContextRef context);
    YTJSStringRef (*stringFromUTF8)(const char *text);
    YTJSStringRef (*stringFromChars)(const YTJSChar *chars, size_t count);
    void (*stringRelease)(YTJSStringRef string);
    size_t (*stringLength)(YTJSStringRef string);
    const YTJSChar *(*stringChars)(YTJSStringRef string);
    YTJSValueRef (*evaluate)(YTJSContextRef context, YTJSStringRef script, YTJSObjectRef thisObject,
                             YTJSStringRef sourceUrl, int line, YTJSValueRef *exception);
    YTJSStringRef (*valueToString)(YTJSContextRef context, YTJSValueRef value,
                                   YTJSValueRef *exception);
    YTJSValueRef (*makeString)(YTJSContextRef context, YTJSStringRef string);
    YTJSValueRef (*makeUndefined)(YTJSContextRef context);
    void (*setProperty)(YTJSContextRef context, YTJSObjectRef object, YTJSStringRef name,
                        YTJSValueRef value, unsigned attributes, YTJSValueRef *exception);
    YTJSObjectRef (*makeFunction)(YTJSContextRef context, YTJSStringRef name,
                                  YTJSCallback callback);
    void (*collect)(YTJSContextRef context);
} JSC;

/**
 * Берёт функции движка один раз за запуск.
 *
 * Библиотека лежит в разных местах: с iOS 7 среди открытых, до того —
 * среди закрытых. Обычно она уже загружена (её тянет UIKit через WebKit),
 * и dlopen лишь возвращает описатель.
 */
static BOOL YTJSLoad(void) {
    static BOOL loaded = NO;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        const char *paths[] = {
            "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore",
            "/System/Library/PrivateFrameworks/JavaScriptCore.framework/JavaScriptCore",
            NULL
        };

        void *library = NULL;
        const char *where = "уже загружена";

        for (int i = 0; paths[i] != NULL && library == NULL; i++) {
            library = dlopen(paths[i], RTLD_LAZY);

            if (library != NULL) {
                where = paths[i];
            }
        }

        if (library == NULL) {
            library = RTLD_DEFAULT;
        }

        NSMutableArray *missing = [NSMutableArray array];

#define YTJSTake(field, symbol) \
        JSC.field = (__typeof__(JSC.field))dlsym(library, symbol); \
        if (JSC.field == NULL) { [missing addObject:[NSString stringWithUTF8String:symbol]]; }

        YTJSTake(contextCreate, "JSGlobalContextCreate");
        YTJSTake(contextRelease, "JSGlobalContextRelease");
        YTJSTake(globalObject, "JSContextGetGlobalObject");
        YTJSTake(stringFromUTF8, "JSStringCreateWithUTF8CString");
        YTJSTake(stringFromChars, "JSStringCreateWithCharacters");
        YTJSTake(stringRelease, "JSStringRelease");
        YTJSTake(stringLength, "JSStringGetLength");
        YTJSTake(stringChars, "JSStringGetCharactersPtr");
        YTJSTake(evaluate, "JSEvaluateScript");
        YTJSTake(valueToString, "JSValueToStringCopy");
        YTJSTake(makeString, "JSValueMakeString");
        YTJSTake(makeUndefined, "JSValueMakeUndefined");
        YTJSTake(setProperty, "JSObjectSetProperty");
        YTJSTake(makeFunction, "JSObjectMakeFunctionWithCallback");
        YTJSTake(collect, "JSGarbageCollect");

#undef YTJSTake

        loaded = ([missing count] == 0);

        if (loaded) {
            NSLog(@"[YouTube/JS] Движок без веб-вида есть: JavaScriptCore (%s)", where);
        } else {
            NSLog(@"[YouTube/JS] Движка без веб-вида нет — не нашлись %@",
                  [missing componentsJoinedByString:@", "]);
        }
    });

    return loaded;
}

static YTJSStringRef YTJSString(NSString *text) {
    NSUInteger length = [text length];
    unichar *buffer = malloc(MAX(length, (NSUInteger)1) * sizeof(unichar));

    [text getCharacters:buffer range:NSMakeRange(0, length)];

    YTJSStringRef string = JSC.stringFromChars(buffer, length);

    free(buffer);

    return string;
}

static NSString *YTJSText(YTJSContextRef context, YTJSValueRef value) {
    if (value == NULL) {
        return nil;
    }

    YTJSStringRef string = JSC.valueToString(context, value, NULL);

    if (string == NULL) {
        return nil;
    }

    NSString *text = [NSString stringWithCharacters:JSC.stringChars(string)
                                             length:JSC.stringLength(string)];

    JSC.stringRelease(string);

    return text;
}

/** `console.log` движка — в общий журнал. */
static YTJSValueRef YTJSConsoleLog(YTJSContextRef context, YTJSObjectRef function,
                                   YTJSObjectRef thisObject, size_t count,
                                   const YTJSValueRef arguments[], YTJSValueRef *exception) {
    if (count > 0) {
        NSString *line = YTJSText(context, arguments[0]);

        if ([line length] > 0) {
            NSLog(@"[YouTube/JS] %@", line);
        }
    }

    return JSC.makeUndefined(context);
}

/** Поток движка: цикл выполнения, пока не отменят. */
@interface YTJSThread : NSThread
@end

@implementation YTJSThread

- (void)main {
    @autoreleasepool {
        NSRunLoop *loop = [NSRunLoop currentRunLoop];

        // Без источника цикл выполнения завершается сразу.
        [loop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];

        while (![self isCancelled]) {
            @autoreleasepool {
                [loop runMode:NSDefaultRunLoopMode
                   beforeDate:[NSDate dateWithTimeIntervalSinceNow:10.0]];
            }
        }
    }
}

@end

@implementation YTJSEngine {
    YTJSThread *_thread;
    YTJSGlobalContextRef _context;
}

+ (BOOL)available {
    return YTJSLoad();
}

+ (YTJSEngine *)engine {
    if (!YTJSLoad()) {
        return nil;
    }

    YTJSEngine *engine = [[YTJSEngine alloc] init];

    return (engine != nil && engine->_context != NULL) ? engine : nil;
}

- (instancetype)init {
    if ((self = [super init])) {
        _thread = [[YTJSThread alloc] init];

        [_thread setName:@"ru.computershik.troubadour.js"];
        [_thread setStackSize:8 * 1024 * 1024];
        [_thread start];

        [self onThread:^{
            self->_context = JSC.contextCreate(NULL);

            if (self->_context == NULL) {
                return;
            }

            YTJSStringRef name = YTJSString(@"__ytLog");
            YTJSObjectRef log = JSC.makeFunction(self->_context, name, YTJSConsoleLog);

            JSC.setProperty(self->_context, JSC.globalObject(self->_context), name,
                            (YTJSValueRef)log, 0, NULL);
            JSC.stringRelease(name);

            YTJSStringRef console = YTJSString(
                @"var console = { log: function (s) { __ytLog(String(s)); } };");

            JSC.evaluate(self->_context, console, NULL, NULL, 1, NULL);
            JSC.stringRelease(console);
        }];
    }

    return self;
}

- (void)dealloc {
    YTJSGlobalContextRef context = _context;

    _context = NULL;

    if (context != NULL) {
        if ([NSThread currentThread] == _thread) {
            JSC.contextRelease(context);
        } else {
            [YTJSEngine performSelector:@selector(releaseContext:)
                               onThread:_thread
                             withObject:[NSValue valueWithPointer:context]
                          waitUntilDone:YES];
        }
    }

    [_thread cancel];

    // Будим цикл, чтобы поток увидел отмену и вышел.
    [YTJSEngine performSelector:@selector(wake)
                       onThread:_thread
                     withObject:nil
                  waitUntilDone:NO];
}

+ (void)releaseContext:(NSValue *)context {
    JSC.contextRelease((YTJSGlobalContextRef)[context pointerValue]);
}

+ (void)wake {
}

/** Исполняет блок на потоке движка и ждёт его. */
- (void)onThread:(dispatch_block_t)block {
    if ([NSThread currentThread] == _thread) {
        block();
        return;
    }

    [self performSelector:@selector(runBlock:)
                 onThread:_thread
               withObject:[block copy]
            waitUntilDone:YES];
}

- (void)runBlock:(dispatch_block_t)block {
    @autoreleasepool {
        block();
    }
}

- (NSString *)evaluate:(NSString *)script error:(NSString **)error {
    __block NSString *result = nil;
    __block NSString *failure = nil;

    [self onThread:^{
        if (self->_context == NULL) {
            failure = @"контекста нет";
            return;
        }

        YTJSStringRef source = YTJSString(script);
        YTJSValueRef exception = NULL;

        YTJSValueRef value = JSC.evaluate(self->_context, source, NULL, NULL, 1, &exception);

        JSC.stringRelease(source);

        if (exception != NULL) {
            failure = YTJSText(self->_context, exception) ?: @"исключение без текста";
        } else {
            result = YTJSText(self->_context, value);
        }
    }];

    if (error != NULL) {
        *error = failure;
    }

    return result;
}

- (BOOL)setGlobal:(NSString *)name utf8:(NSData *)bytes {
    // Движку нужна строка с нулём на конце; копия в байтах вдвое меньше копии в знаках.
    NSMutableData *text = [NSMutableData dataWithCapacity:[bytes length] + 1];

    [text appendData:bytes];
    [text appendBytes:"" length:1];

    __block BOOL ok = NO;

    [self onThread:^{
        if (self->_context == NULL) {
            return;
        }

        YTJSStringRef value = JSC.stringFromUTF8((const char *)[text bytes]);
        YTJSStringRef key = YTJSString(name);
        YTJSValueRef exception = NULL;

        JSC.setProperty(self->_context, JSC.globalObject(self->_context), key,
                        JSC.makeString(self->_context, value), 0, &exception);

        JSC.stringRelease(key);
        JSC.stringRelease(value);

        ok = (exception == NULL);
    }];

    return ok;
}

- (void)collect {
    [self onThread:^{
        if (self->_context != NULL) {
            JSC.collect(self->_context);
        }
    }];
}

@end
