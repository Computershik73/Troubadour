#import "YTQuickJS.h"

#import <malloc/malloc.h>

#import "quickjs.h"
#import "YTUtil.h"

/** Накладные на блок, которые QuickJS сам прибавляет к счёту (MALLOC_OVERHEAD в quickjs.c). */
static const size_t YTQJSOverhead = 8;

/**
 * Предел кучи движка.
 *
 * Подъём решателя на компьютере (64 бита) занимает 33 МБ, на 32-битном
 * iPad меньше. Дальше предела — уже не решатель, а беда в скрипте плеера:
 * пусть лучше подъём откажет с «out of memory», чем систему попросят
 * снять приложение.
 */
static const size_t YTQJSMemoryLimit = 64 * 1024 * 1024;

/** Предел стека скрипта: у потока 8 МБ, остаток — самому движку и C. */
static const size_t YTQJSStackLimit = 6 * 1024 * 1024;

#pragma mark Память движка — из его зоны

/*
 * Те же функции, что js_def_malloc/js_def_free/js_def_realloc в quickjs.c,
 * только память берётся из зоны движка (она в `opaque`). Счёт ведётся так
 * же: по нему движок решает, когда собирать мусор и где предел.
 */

static size_t YTQJSUsable(const void *ptr) {
    return malloc_size(ptr);
}

static void *YTQJSMalloc(JSMallocState *state, size_t size) {
    if (state->malloc_size + size > state->malloc_limit) {
        return NULL;
    }

    void *ptr = malloc_zone_malloc((malloc_zone_t *)state->opaque, MAX(size, (size_t)1));

    if (ptr == NULL) {
        return NULL;
    }

    state->malloc_count++;
    state->malloc_size += malloc_size(ptr) + YTQJSOverhead;

    return ptr;
}

static void YTQJSFree(JSMallocState *state, void *ptr) {
    if (ptr == NULL) {
        return;
    }

    state->malloc_count--;
    state->malloc_size -= malloc_size(ptr) + YTQJSOverhead;

    malloc_zone_free((malloc_zone_t *)state->opaque, ptr);
}

static void *YTQJSRealloc(JSMallocState *state, void *ptr, size_t size) {
    if (ptr == NULL) {
        return (size == 0) ? NULL : YTQJSMalloc(state, size);
    }

    size_t old = malloc_size(ptr);

    if (size == 0) {
        YTQJSFree(state, ptr);

        return NULL;
    }

    if (state->malloc_size + size - old > state->malloc_limit) {
        return NULL;
    }

    ptr = malloc_zone_realloc((malloc_zone_t *)state->opaque, ptr, size);

    if (ptr == NULL) {
        return NULL;
    }

    state->malloc_size += malloc_size(ptr) - old;

    return ptr;
}

static const JSMallocFunctions YTQJSAllocator = {
    YTQJSMalloc,
    YTQJSFree,
    YTQJSRealloc,
    YTQJSUsable,
};

#pragma mark Строки

/** Значение строкой; nil, если и `String()` от него бросает. */
static NSString *YTQJSText(JSContext *context, JSValueConst value) {
    size_t length = 0;
    const char *bytes = JS_ToCStringLen(context, &length, value);

    if (bytes == NULL) {
        JS_FreeValue(context, JS_GetException(context));

        return nil;
    }

    NSString *text = [[NSString alloc] initWithBytes:bytes
                                              length:length
                                            encoding:NSUTF8StringEncoding];

    JS_FreeCString(context, bytes);

    return text;
}

/** Текст брошенного исключения, со стеком, если он есть. */
static NSString *YTQJSFailure(JSContext *context) {
    JSValue exception = JS_GetException(context);
    NSString *text = YTQJSText(context, exception) ?: @"исключение без текста";

    if (JS_IsError(context, exception)) {
        JSValue stack = JS_GetPropertyStr(context, exception, "stack");
        NSString *where = JS_IsUndefined(stack) ? nil : YTQJSText(context, stack);

        JS_FreeValue(context, stack);

        if ([where length] > 0) {
            where = [where stringByReplacingOccurrencesOfString:@"\n" withString:@" | "];

            if ([where length] > 300) {
                where = [[where substringToIndex:300] stringByAppendingString:@"…"];
            }

            text = [NSString stringWithFormat:@"%@ (%@)", text, where];
        }
    }

    JS_FreeValue(context, exception);

    return text;
}

/** `console.log` движка — в общий журнал. */
static JSValue YTQJSLog(JSContext *context, JSValueConst receiver, int count, JSValueConst *arguments) {
    if (count > 0) {
        NSString *line = YTQJSText(context, arguments[0]);

        if ([line length] > 0) {
            NSLog(@"[YouTube/JS] %@", line);
        }
    }

    return JS_UNDEFINED;
}

#pragma mark Байткод плеера

/** Заголовок файла байткода: под какой текст плеера и какую сборку приложения он записан. */
typedef struct {
    char magic[4];
    uint32_t format;
    uint32_t pointer;
    uint32_t length;
    uint32_t hash;
} YTQJSBytecodeHeader;

/** Растёт, когда меняется то, как плеер превращается в байткод. */
static const uint32_t YTQJSBytecodeFormat = 1;

static uint32_t YTQJSHash(uint32_t hash, const char *bytes, size_t length) {
    for (size_t i = 0; i < length; i++) {
        hash = (hash ^ (uint8_t)bytes[i]) * 16777619u;
    }

    return hash;
}

/**
 * Заголовок для этого текста.
 *
 * В счёт идёт и сборка приложения: с ней мог смениться сам QuickJS или
 * ключи его сборки, а байткод другого движка он читать не обязан. Так
 * после обновления плеер один раз разбирается заново.
 */
static YTQJSBytecodeHeader YTQJSHeaderFor(const char *text, size_t length) {
    YTQJSBytecodeHeader header;
    const char *build = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]
                         UTF8String] ?: "";

    memset(&header, 0, sizeof(header));
    memcpy(header.magic, "TQJB", 4);
    header.format = YTQJSBytecodeFormat;
    header.pointer = (uint32_t)sizeof(void *);
    header.length = (uint32_t)length;
    header.hash = YTQJSHash(YTQJSHash(2166136261u, build, strlen(build)), text, length);

    return header;
}

/**
 * Разбирает плеер так же, как `Function(code)`: телом функции. Выходит
 * разобранная, но ещё не созданная функция — её и можно записать.
 */
static JSValue YTQJSCompile(JSContext *context, const char *text, size_t length) {
    static const char head[] = "(function(){\n";
    static const char tail[] = "\n})";
    size_t total = (sizeof(head) - 1) + length + (sizeof(tail) - 1);
    char *source = js_malloc(context, total + 1);

    if (source == NULL) {
        return JS_EXCEPTION;
    }

    memcpy(source, head, sizeof(head) - 1);
    memcpy(source + sizeof(head) - 1, text, length);
    memcpy(source + sizeof(head) - 1 + length, tail, sizeof(tail));

    JSValue compiled = JS_Eval(context, source, total, "<player>",
                               JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);

    js_free(context, source);

    return compiled;
}

@interface YTQuickJS ()
- (JSValue)run:(JSContext *)context player:(JSValueConst)code;
@end

/** `__ytRun(code)` — исполняет плеер, разобрав его или прочитав байткод (см. nsig.js). */
static JSValue YTQJSRun(JSContext *context, JSValueConst receiver, int count, JSValueConst *arguments) {
    YTQuickJS *engine = (__bridge YTQuickJS *)JS_GetContextOpaque(context);

    if (count < 1 || engine == nil) {
        return JS_ThrowTypeError(context, "__ytRun: нет текста плеера");
    }

    return [engine run:context player:arguments[0]];
}

#pragma mark Поток движка

/** Цикл выполнения, пока не отменят (как у YTJSEngine). */
@interface YTQuickJSThread : NSThread
@end

@implementation YTQuickJSThread

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

#pragma mark Движок

@implementation YTQuickJS {
    YTQuickJSThread *_thread;
    malloc_zone_t *_zone;
    JSRuntime *_runtime;
    JSContext *_context;
}

+ (YTQuickJS *)engine {
    YTQuickJS *engine = [[YTQuickJS alloc] init];

    return (engine != nil && engine->_context != NULL) ? engine : nil;
}

- (instancetype)init {
    if ((self = [super init])) {
        _thread = [[YTQuickJSThread alloc] init];

        [_thread setName:@"ru.computershik.troubadour.quickjs"];
        [_thread setStackSize:8 * 1024 * 1024];
        [_thread start];

        // Всё — на потоке движка: по месту создания он отмеряет свой стек.
        [self onThread:^{
            malloc_zone_t *zone = malloc_create_zone(0, 0);

            if (zone == NULL) {
                NSLog(@"[YouTube/JS] QuickJS: зона памяти не создалась");

                return;
            }

            malloc_set_zone_name(zone, "troubadour.quickjs");
            self->_zone = zone;

            JSRuntime *runtime = JS_NewRuntime2(&YTQJSAllocator, zone);

            if (runtime == NULL) {
                NSLog(@"[YouTube/JS] QuickJS: движок не создался");

                return;
            }

            JS_SetMemoryLimit(runtime, YTQJSMemoryLimit);
            JS_SetMaxStackSize(runtime, YTQJSStackLimit);

            // Исходник функций нужен только их toString, номера строк — только
            // текстам ошибок. Без них куча после подъёма 7,6 МБ против 13,5
            // (компьютер, плеер 11a45ffb), байткод 2,4 МБ против 11.
            JS_SetStripInfo(runtime, JS_STRIP_SOURCE | JS_STRIP_DEBUG);

            JSContext *context = JS_NewContext(runtime);

            self->_runtime = runtime;

            if (context == NULL) {
                NSLog(@"[YouTube/JS] QuickJS: контекст не создался");

                return;
            }

            // Движок живёт дольше контекста, ссылка без удержания безопасна.
            JS_SetContextOpaque(context, (__bridge void *)self);

            JSValue global = JS_GetGlobalObject(context);

            JS_SetPropertyStr(context, global, "__ytLog",
                              JS_NewCFunction(context, YTQJSLog, "__ytLog", 1));
            JS_SetPropertyStr(context, global, "__ytRun",
                              JS_NewCFunction(context, YTQJSRun, "__ytRun", 1));
            JS_FreeValue(context, global);

            static const char console[] =
                "var console = { log: function (s) { __ytLog(String(s)); } };";

            JS_FreeValue(context, JS_Eval(context, console, sizeof(console) - 1, "<console>",
                                          JS_EVAL_TYPE_GLOBAL));

            self->_context = context;
        }];
    }

    return self;
}

/**
 * Отпускать движок по правилам (JS_FreeContext, JS_FreeRuntime) незачем:
 * всё, что у него есть, лежит в зоне, и зона уходит целиком. К тому же
 * JS_FreeRuntime проверяет, что объектов не осталось, и при остатке
 * роняет процесс — а после скрипта плеера остаток бывает всегда.
 */
- (void)dealloc {
    malloc_zone_t *zone = _zone;

    _zone = NULL;
    _runtime = NULL;
    _context = NULL;

    if (zone != NULL) {
        NSValue *value = [NSValue valueWithPointer:zone];

        if ([NSThread currentThread] == _thread) {
            [YTQuickJS destroyZone:value];
        } else {
            [YTQuickJS performSelector:@selector(destroyZone:)
                              onThread:_thread
                            withObject:value
                         waitUntilDone:YES];
        }
    }

    [_thread cancel];

    // Будим цикл, чтобы поток увидел отмену и вышел.
    [YTQuickJS performSelector:@selector(wake)
                      onThread:_thread
                    withObject:nil
                 waitUntilDone:NO];
}

+ (void)destroyZone:(NSValue *)value {
    malloc_zone_t *zone = (malloc_zone_t *)[value pointerValue];
    malloc_statistics_t stats;

    memset(&stats, 0, sizeof(stats));
    malloc_zone_statistics(zone, &stats);

    double before = YTResidentMegabytes();

    malloc_destroy_zone(zone);

    NSLog(@"[YouTube/JS] Зона QuickJS уничтожена: занято в ней %.1f МБ, взято у системы %.1f МБ; "
          @"память %.0f → %.0f МБ",
          stats.size_in_use / 1048576.0, stats.size_allocated / 1048576.0,
          before, YTResidentMegabytes());
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
        JSContext *context = self->_context;

        if (context == NULL) {
            failure = @"контекста нет";
            return;
        }

        // Движку нужен ноль на конце текста — у UTF8String он есть.
        const char *source = [script UTF8String];
        JSValue value = JS_Eval(context, source, strlen(source), "<troubadour>",
                                JS_EVAL_TYPE_GLOBAL);

        if (JS_IsException(value)) {
            failure = YTQJSFailure(context);
        } else {
            result = YTQJSText(context, value);
        }

        JS_FreeValue(context, value);
    }];

    if (error != NULL) {
        *error = failure;
    }

    return result;
}

- (BOOL)setGlobal:(NSString *)name utf8:(NSData *)bytes {
    __block BOOL ok = NO;

    [self onThread:^{
        JSContext *context = self->_context;

        if (context == NULL) {
            return;
        }

        // Скрипт плеера почти весь ASCII, и QuickJS держит его байтом на знак.
        JSValue value = JS_NewStringLen(context, (const char *)[bytes bytes], [bytes length]);

        if (JS_IsException(value)) {
            JS_FreeValue(context, JS_GetException(context));
            return;
        }

        JSValue global = JS_GetGlobalObject(context);

        ok = (JS_SetPropertyStr(context, global, [name UTF8String], value) > 0);

        if (!ok) {
            JS_FreeValue(context, JS_GetException(context));
        }

        JS_FreeValue(context, global);
    }];

    return ok;
}

/** Плеер: байткод из кеша или разбор с записью байткода, потом исполнение. На потоке движка. */
- (JSValue)run:(JSContext *)context player:(JSValueConst)code {
    size_t length = 0;
    const char *text = JS_ToCStringLen(context, &length, code);

    if (text == NULL) {
        return JS_EXCEPTION;
    }

    NSTimeInterval started = [NSDate timeIntervalSinceReferenceDate];
    YTQJSBytecodeHeader header = YTQJSHeaderFor(text, length);
    NSString *path = [self bytecodePath];
    JSValue compiled = (path != nil) ? [self read:context bytecode:path header:&header]
                                     : JS_UNDEFINED;
    BOOL cached = !JS_IsUndefined(compiled);

    if (!cached) {
        compiled = YTQJSCompile(context, text, length);
    }

    JS_FreeCString(context, text);

    if (JS_IsException(compiled)) {
        return compiled;
    }

    NSTimeInterval parsed = [NSDate timeIntervalSinceReferenceDate];
    size_t written = 0;

    if (!cached && path != nil) {
        written = [self write:context bytecode:compiled path:path header:&header];
    }

    // Забирает разобранное себе; выходит сама функция плеера.
    JSValue function = JS_EvalFunction(context, compiled);

    if (JS_IsException(function)) {
        return function;
    }

    NSTimeInterval ready = [NSDate timeIntervalSinceReferenceDate];
    JSValue result = JS_Call(context, function, JS_UNDEFINED, 0, NULL);

    JS_FreeValue(context, function);

    NSString *how = cached ? @"прочитан из байткода"
                  : (written > 0) ? [NSString stringWithFormat:@"разобран, байткод %lu КБ записан",
                                     (unsigned long)(written / 1024)]
                  : @"разобран";

    NSLog(@"[YouTube/JS] Плеер %@ за %.1f с, исполнен за %.1f с", how,
          parsed - started, [NSDate timeIntervalSinceReferenceDate] - ready);

    return result;
}

/** Байткод из файла, если он записан под этот же текст; иначе undefined. */
- (JSValue)read:(JSContext *)context
       bytecode:(NSString *)path
         header:(const YTQJSBytecodeHeader *)expected {
    // Файл подменяется только переименованием (см. write:), и отображение
    // в память безопасно: прочитанное движок копирует к себе.
    NSData *file = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];

    if ([file length] <= sizeof(*expected)) {
        return JS_UNDEFINED;
    }

    if (memcmp([file bytes], expected, sizeof(*expected)) != 0) {
        NSLog(@"[YouTube/JS] Байткод плеера записан под другой текст или сборку — разбираем заново");

        return JS_UNDEFINED;
    }

    JSValue compiled = JS_ReadObject(context, (const uint8_t *)[file bytes] + sizeof(*expected),
                                     [file length] - sizeof(*expected), JS_READ_OBJ_BYTECODE);

    if (JS_IsException(compiled)) {
        NSLog(@"[YouTube/JS] Байткод плеера не прочитался (%@) — разбираем заново",
              YTQJSFailure(context));

        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];

        return JS_UNDEFINED;
    }

    return compiled;
}

/**
 * Записывает байткод: во временный файл, потом переименованием. Оборвись
 * запись на полпути — останется недописанный временный, а не битый байткод.
 * Возвращает размер записанного, 0 — не вышло.
 */
- (size_t)write:(JSContext *)context
       bytecode:(JSValueConst)compiled
           path:(NSString *)path
         header:(const YTQJSBytecodeHeader *)header {
    size_t size = 0;
    uint8_t *bytes = JS_WriteObject(context, &size, compiled, JS_WRITE_OBJ_BYTECODE);

    if (bytes == NULL) {
        NSLog(@"[YouTube/JS] Байткод плеера не собрался: %@", YTQJSFailure(context));

        return 0;
    }

    NSString *temporary = [path stringByAppendingPathExtension:@"part"];
    FILE *file = fopen([temporary fileSystemRepresentation], "wb");
    BOOL ok = (file != NULL &&
               fwrite(header, sizeof(*header), 1, file) == 1 &&
               fwrite(bytes, 1, size, file) == size);

    if (file != NULL) {
        ok = (fclose(file) == 0) && ok;
    }

    js_free(context, bytes);

    ok = ok && rename([temporary fileSystemRepresentation], [path fileSystemRepresentation]) == 0;

    if (!ok) {
        unlink([temporary fileSystemRepresentation]);

        NSLog(@"[YouTube/JS] Байткод плеера не записался (%s)", strerror(errno));

        return 0;
    }

    return size;
}

- (void)collect {
    [self onThread:^{
        if (self->_runtime != NULL) {
            JS_RunGC(self->_runtime);
        }
    }];
}

- (NSString *)censusNote {
    malloc_statistics_t stats;

    memset(&stats, 0, sizeof(stats));

    if (_zone != NULL) {
        malloc_zone_statistics(_zone, &stats);
    }

    return [NSString stringWithFormat:@"в QuickJS, зона %.1f МБ (у системы %.1f)",
            stats.size_in_use / 1048576.0, stats.size_allocated / 1048576.0];
}

@end
