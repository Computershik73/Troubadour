#import "YTMp4Writer.h"

#import "YTMp4.h"

/**
 * Шкала времени файла. 1000 — то же, что кладут почти все: миллисекунда
 * достаточно мелка для длительности, а мельче ни к чему.
 */
static const uint32_t YTMovieScale = 1000;

/** Сколько читать за раз, когда переливаем сэмплы в `mdat`. */
static const NSUInteger YTCopyChunk = 256 * 1024;


#pragma mark - Мелкая запись

static void YTPut8(NSMutableData *out, uint8_t value) {
    [out appendBytes:&value length:1];
}

static void YTPut16(NSMutableData *out, uint16_t value) {
    uint8_t bytes[2] = { (uint8_t)(value >> 8), (uint8_t)value };

    [out appendBytes:bytes length:2];
}

static void YTPut32(NSMutableData *out, uint32_t value) {
    uint8_t bytes[4] = { (uint8_t)(value >> 24), (uint8_t)(value >> 16),
                         (uint8_t)(value >> 8), (uint8_t)value };

    [out appendBytes:bytes length:4];
}

static void YTPutTag(NSMutableData *out, const char *tag) {
    [out appendBytes:tag length:4];
}

/** Бокс с уже готовым телом: длина, имя, тело. */
static NSMutableData *YTBox(const char *tag, NSData *body) {
    NSMutableData *out = [NSMutableData data];

    YTPut32(out, (uint32_t)(8 + [body length]));
    YTPutTag(out, tag);

    if (body != nil) { [out appendData:body]; }

    return out;
}

/** Полный бокс: версия и флаги перед телом. */
static NSMutableData *YTFullBox(const char *tag, uint8_t version,
                                uint32_t flags, NSData *body) {
    NSMutableData *inner = [NSMutableData data];

    YTPut32(inner, ((uint32_t)version << 24) | (flags & 0x00FFFFFF));

    if (body != nil) { [inner appendData:body]; }

    return YTBox(tag, inner);
}


#pragma mark - Разобранная дорожка

/**
 * Дорожка целиком: описание кодека и таблица сэмплов.
 *
 * Сэмплы держатся плоскими массивами, а не объектами. У часового ролика
 * их под сотню тысяч, и сотня тысяч `YTSample` — это и память, и время
 * на пересчёт ссылок там, где нужны четыре числа.
 */
@interface YTTrackPlan : NSObject {
@public
    YTTrackInit *init;

    /** Где в исходном файле лежит сэмпл и какой он длины. */
    uint64_t *offsets;
    uint32_t *sizes;
    uint32_t *durations;
    int32_t *shifts;
    uint32_t *syncs;

    NSUInteger count;
    NSUInteger capacity;
    NSUInteger syncCount;

    uint64_t totalBytes;
    uint64_t totalTicks;

    /** Куда лёг первый сэмпл в собранном файле. */
    uint64_t chunkStart;
}
@end

@implementation YTTrackPlan

- (void)dealloc {
    free(offsets);
    free(sizes);
    free(durations);
    free(shifts);
    free(syncs);
}

- (void)room {
    if (count < capacity) {
        return;
    }

    capacity = capacity > 0 ? capacity * 2 : 4096;

    offsets = realloc(offsets, capacity * sizeof(uint64_t));
    sizes = realloc(sizes, capacity * sizeof(uint32_t));
    durations = realloc(durations, capacity * sizeof(uint32_t));
    shifts = realloc(shifts, capacity * sizeof(int32_t));
    syncs = realloc(syncs, capacity * sizeof(uint32_t));
}

@end


@implementation YTMp4Writer

#pragma mark Чтение дорожки

/** Заголовок бокса по смещению: длина и имя. NO — дальше читать нечего. */
+ (BOOL)readHeaderIn:(NSFileHandle *)file
                  at:(uint64_t)position
                size:(uint64_t *)size
                 tag:(char *)tag {
    @try {
        [file seekToFileOffset:position];
    } @catch (NSException *trouble) {
        return NO;
    }

    NSData *head = [file readDataOfLength:8];

    if ([head length] < 8) {
        return NO;
    }

    const uint8_t *bytes = [head bytes];

    uint64_t boxSize = ((uint64_t)bytes[0] << 24) | ((uint64_t)bytes[1] << 16) |
                       ((uint64_t)bytes[2] << 8) | (uint64_t)bytes[3];

    memcpy(tag, bytes + 4, 4);

    tag[4] = 0;

    // Длина 1 означает, что настоящая лежит следом восемью байтами.
    if (boxSize == 1) {
        NSData *large = [file readDataOfLength:8];

        if ([large length] < 8) {
            return NO;
        }

        const uint8_t *big = [large bytes];

        boxSize = 0;

        for (int i = 0; i < 8; i++) {
            boxSize = (boxSize << 8) | big[i];
        }
    }

    if (boxSize < 8) {
        return NO;
    }

    *size = boxSize;

    return YES;
}

/**
 * Проходит дорожку по боксам и собирает таблицу сэмплов.
 *
 * `sidx` не читается вовсе, и это нарочно: карта фрагментов нужна тому,
 * кто хочет прыгнуть в середину, а мы идём подряд от начала до конца.
 * Пары `moof`+`mdat` в файле лежат по порядку — этого довольно.
 */
+ (YTTrackPlan *)planFor:(NSString *)path {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];

    if (file == nil) {
        return nil;
    }

    NSDictionary *about = [[NSFileManager defaultManager]
        attributesOfItemAtPath:path error:NULL];

    uint64_t length = (uint64_t)[about fileSize];

    YTTrackPlan *plan = [[YTTrackPlan alloc] init];

    uint64_t position = 0;

    while (position + 8 <= length) {
        uint64_t size = 0;
        char tag[5];

        if (![self readHeaderIn:file at:position size:&size tag:tag]) {
            break;
        }

        if (position + size > length) {
            break;
        }

        if (strcmp(tag, "moov") == 0) {
            /**
             * Описание кодека. Разбору нужен `ftyp` вместе с `moov`,
             * поэтому отдаём начало файла целиком до конца этого бокса.
             */
            [file seekToFileOffset:0];

            NSData *head = [file readDataOfLength:(NSUInteger)(position + size)];

            plan->init = [YTMp4 parseInit:head];
        } else if (strcmp(tag, "moof") == 0) {
            /**
             * За `moof` всегда идёт `mdat` — в нём и лежат сэмплы.
             * Читаем пару целиком: разбору нужен `moof`, а данные
             * мы отсюда только адресуем, не копируем.
             */
            uint64_t mdatSize = 0;
            char mdatTag[5];

            if (![self readHeaderIn:file at:position + size
                               size:&mdatSize tag:mdatTag]) {
                break;
            }

            if (strcmp(mdatTag, "mdat") != 0 ||
                position + size + mdatSize > length) {
                break;
            }

            [file seekToFileOffset:position];

            NSData *pair = [file readDataOfLength:(NSUInteger)size];

            YTFragment *fragment = [YTMp4 parseFragment:pair init:plan->init];

            for (YTSample *sample in fragment.samples) {
                [plan room];

                plan->offsets[plan->count] =
                    position + fragment.dataOffset + sample.offset;
                plan->sizes[plan->count] = sample.size;
                plan->durations[plan->count] = sample.duration;
                plan->shifts[plan->count] = sample.compositionOffset;
                plan->syncs[plan->count] = sample.isSync ? 1 : 0;

                if (sample.isSync) { plan->syncCount++; }

                plan->totalBytes += sample.size;
                plan->totalTicks += sample.duration;

                plan->count++;
            }

            position += size + mdatSize;

            continue;
        }

        position += size;
    }

    [file closeFile];

    if (plan->init == nil || plan->count == 0) {
        NSLog(@"[YouTube/Сборка] %@: разбор не дал ни описания, ни сэмплов",
              [path lastPathComponent]);

        return nil;
    }

    /**
     * Всё, чем дорожка описана, — в журнал.
     *
     * Негодный файл на устройстве выглядит одинаково при любой причине:
     * проигрыватель открывается и сразу закрывается. Отличить «не нашли
     * SPS» от «не та частота» по этому виду нельзя, а по этим числам —
     * можно за один взгляд.
     */
    YTTrackInit *init = plan->init;

    NSLog(@"[YouTube/Сборка] %@: %@, шкала %u, сэмплов %lu, тиков %llu",
          [path lastPathComponent],
          [init isVideo] ? @"видео" : @"звук",
          init.timescale, (unsigned long)plan->count, plan->totalTicks);

    if ([init isVideo]) {
        NSData *sps = [init.sps count] > 0 ? [init.sps objectAtIndex:0] : nil;

        NSLog(@"[YouTube/Сборка]   %ux%u, SPS %lu (%lu байт), PPS %lu, "
              @"длина NALU %u, ключевых %lu",
              init.width, init.height,
              (unsigned long)[init.sps count], (unsigned long)[sps length],
              (unsigned long)[init.pps count], init.nalLengthSize,
              (unsigned long)plan->syncCount);
    } else {
        NSLog(@"[YouTube/Сборка]   род %u, частота №%u, каналов %u",
              init.audioObjectType, init.samplingFrequencyIndex,
              init.channelConfig);
    }

    return plan;
}

#pragma mark Описание кодека

/** `avcC` — то же, что лежало в исходной дорожке, собранное заново. */
+ (NSData *)avccFor:(YTTrackInit *)init {
    NSData *sps = [init.sps count] > 0 ? [init.sps objectAtIndex:0] : nil;

    if ([sps length] < 4) {
        NSLog(@"[YouTube/Сборка] SPS негоден (%lu байт) — описание кодека "
              @"собрать нечем", (unsigned long)[sps length]);

        return nil;
    }

    const uint8_t *head = [sps bytes];

    NSMutableData *out = [NSMutableData data];

    YTPut8(out, 1);          // версия
    YTPut8(out, head[1]);    // профиль
    YTPut8(out, head[2]);    // совместимость профиля
    YTPut8(out, head[3]);    // уровень

    // Шесть единиц в старших битах, затем длина поля длины минус один.
    YTPut8(out, (uint8_t)(0xFC | (init.nalLengthSize - 1)));

    YTPut8(out, (uint8_t)(0xE0 | [init.sps count]));

    for (NSData *one in init.sps) {
        YTPut16(out, (uint16_t)[one length]);
        [out appendData:one];
    }

    YTPut8(out, (uint8_t)[init.pps count]);

    for (NSData *one in init.pps) {
        YTPut16(out, (uint16_t)[one length]);
        [out appendData:one];
    }

    return out;
}

/**
 * `esds` для AAC.
 *
 * Дескрипторы MPEG-4 с длиной в переменном формате; длины здесь малы,
 * поэтому один байт на каждую — этого хватает всегда, пока
 * AudioSpecificConfig занимает два байта, а он занимает два.
 */
+ (NSData *)esdsFor:(YTTrackInit *)init {
    uint8_t asc[2];

    asc[0] = (uint8_t)((init.audioObjectType << 3) |
                       (init.samplingFrequencyIndex >> 1));
    asc[1] = (uint8_t)(((init.samplingFrequencyIndex & 1) << 7) |
                       (init.channelConfig << 3));

    NSMutableData *out = [NSMutableData data];

    YTPut32(out, 0);   // версия и флаги

    // ES_Descriptor
    YTPut8(out, 0x03);
    YTPut8(out, 25);
    YTPut16(out, 0);
    YTPut8(out, 0);

    // DecoderConfigDescriptor
    YTPut8(out, 0x04);
    YTPut8(out, 17);
    YTPut8(out, 0x40);   // MPEG-4 AAC
    YTPut8(out, 0x15);   // звуковой поток
    YTPut8(out, 0); YTPut16(out, 0);   // размер буфера
    YTPut32(out, 0);     // наибольший битрейт
    YTPut32(out, 0);     // средний битрейт

    // DecoderSpecificInfo
    YTPut8(out, 0x05);
    YTPut8(out, 2);
    [out appendBytes:asc length:2];

    // SLConfigDescriptor
    YTPut8(out, 0x06);
    YTPut8(out, 1);
    YTPut8(out, 0x02);

    return out;
}

/** Частота по номеру из AudioSpecificConfig. */
+ (uint32_t)rateFor:(uint8_t)index {
    static const uint32_t rates[] = {
        96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
        16000, 12000, 11025, 8000, 7350, 0, 0, 0
    };

    return rates[index & 0x0F];
}

#pragma mark Таблицы сэмплов

+ (NSData *)stblFor:(YTTrackPlan *)plan {
    YTTrackInit *init = plan->init;

    BOOL video = [init isVideo];

    // stsd — описание кодека.
    NSMutableData *entry = [NSMutableData data];

    uint8_t reserved[6] = { 0, 0, 0, 0, 0, 0 };

    [entry appendBytes:reserved length:6];
    YTPut16(entry, 1);   // номер источника данных

    if (video) {
        /**
         * Ровно шестнадцать байт до ширины — ни байтом больше.
         *
         * По спецификации здесь `pre_defined` (2), `reserved` (2) и
         * `pre_defined[3]` (12). В первом заходе я написал лишнее слово,
         * и всё, что дальше, съехало на четыре байта: ширина, высота
         * и сам `avcC`. Файл при этом собирался и открывался, звук играл,
         * а картинки не было вовсе — описание видеодорожки читалось
         * как мусор.
         */
        YTPut16(entry, 0);                       // pre_defined
        YTPut16(entry, 0);                       // reserved
        YTPut32(entry, 0); YTPut32(entry, 0); YTPut32(entry, 0);

        YTPut16(entry, (uint16_t)init.width);
        YTPut16(entry, (uint16_t)init.height);

        YTPut32(entry, 0x00480000);   // 72 точки на дюйм по горизонтали
        YTPut32(entry, 0x00480000);   // и по вертикали
        YTPut32(entry, 0);
        YTPut16(entry, 1);            // кадров на сэмпл

        uint8_t name[32];

        memset(name, 0, sizeof(name));

        [entry appendBytes:name length:32];

        YTPut16(entry, 0x0018);       // глубина цвета
        YTPut16(entry, 0xFFFF);       // таблицы цветов нет

        [entry appendData:YTBox("avcC", [self avccFor:init])];
    } else {
        YTPut32(entry, 0); YTPut32(entry, 0);
        YTPut16(entry, (uint16_t)init.channelConfig);
        YTPut16(entry, 16);           // бит на отсчёт
        YTPut16(entry, 0); YTPut16(entry, 0);

        // Частота записывается как 16.16; старшего слова довольно.
        YTPut16(entry, (uint16_t)[self rateFor:init.samplingFrequencyIndex]);
        YTPut16(entry, 0);

        [entry appendData:YTBox("esds", [self esdsFor:init])];
    }

    NSMutableData *sample = YTBox(video ? "avc1" : "mp4a", entry);

    NSMutableData *stsdBody = [NSMutableData data];

    YTPut32(stsdBody, 1);
    [stsdBody appendData:sample];

    NSMutableData *stbl = [NSMutableData data];

    [stbl appendData:YTFullBox("stsd", 0, 0, stsdBody)];

    /**
     * stts — длительности, сжатые пробегами.
     *
     * У видео с постоянной частотой кадров пробег выходит один на всю
     * дорожку: вместо сотни тысяч записей — одна.
     */
    NSMutableData *stts = [NSMutableData data];

    uint32_t runs = 0;

    {
        NSUInteger i = 0;

        while (i < plan->count) {
            uint32_t value = plan->durations[i];
            uint32_t same = 1;

            while (i + same < plan->count &&
                   plan->durations[i + same] == value) {
                same++;
            }

            YTPut32(stts, same);
            YTPut32(stts, value);

            runs++;
            i += same;
        }
    }

    NSMutableData *sttsBody = [NSMutableData data];

    YTPut32(sttsBody, runs);
    [sttsBody appendData:stts];

    [stbl appendData:YTFullBox("stts", 0, 0, sttsBody)];

    /**
     * ctts — сдвиг показа, и **всегда нулевой версии**.
     *
     * В первой версии сдвиг знаковый, и это удобно: `trun` у YouTube
     * приносит и отрицательные. Но версия эта появилась поздней правкой
     * к стандарту, и разборщик iOS её не берёт — файл целиком получал
     * отказ «не удаётся открыть» ещё до дорожек. VLC такое прощает,
     * AVFoundation нет.
     *
     * Поэтому приводим к нулевой: если среди сдвигов есть отрицательные,
     * поднимаем все на одну и ту же величину. Взаимный порядок кадров
     * от этого не меняется — сдвигается только точка отсчёта показа,
     * общая для всей дорожки, и на слух с картинкой это неразличимо.
     */
    int32_t lift = 0;

    for (NSUInteger i = 0; i < plan->count; i++) {
        if (plan->shifts[i] < lift) { lift = plan->shifts[i]; }
    }

    lift = -lift;

    BOOL shifted = NO;

    for (NSUInteger i = 0; i < plan->count; i++) {
        if (plan->shifts[i] != 0) { shifted = YES; break; }
    }

    if (shifted) {
        NSMutableData *ctts = [NSMutableData data];

        uint32_t entries = 0;
        NSUInteger i = 0;

        while (i < plan->count) {
            int32_t value = plan->shifts[i];
            uint32_t same = 1;

            while (i + same < plan->count && plan->shifts[i + same] == value) {
                same++;
            }

            YTPut32(ctts, same);
            YTPut32(ctts, (uint32_t)(value + lift));

            entries++;
            i += same;
        }

        NSMutableData *body = [NSMutableData data];

        YTPut32(body, entries);
        [body appendData:ctts];

        [stbl appendData:YTFullBox("ctts", 0, 0, body)];

        if (lift != 0) {
            NSLog(@"[YouTube/Сборка] Сдвиги показа подняты на %ld — "
                  @"нулевая версия ctts знака не знает", (long)lift);
        }
    }

    // stss — ключевые кадры; у звука ключевые все, и бокс не нужен.
    if (video && plan->syncCount > 0 && plan->syncCount < plan->count) {
        NSMutableData *body = [NSMutableData data];

        YTPut32(body, (uint32_t)plan->syncCount);

        for (NSUInteger i = 0; i < plan->count; i++) {
            if (plan->syncs[i]) {
                YTPut32(body, (uint32_t)(i + 1));
            }
        }

        [stbl appendData:YTFullBox("stss", 0, 0, body)];
    }

    /**
     * stsc и stco — одна порция на всю дорожку.
     *
     * Мы сами кладём сэмплы дорожки подряд, без чередования, поэтому
     * порция ровно одна и смещение у неё одно. Обычные файлы дробят
     * дорожку на порции ради чередования видео со звуком; нам это
     * не нужно — файл лежит на диске, а не течёт по сети.
     */
    NSMutableData *stscBody = [NSMutableData data];

    YTPut32(stscBody, 1);
    YTPut32(stscBody, 1);                        // первая порция
    YTPut32(stscBody, (uint32_t)plan->count);    // сэмплов в порции
    YTPut32(stscBody, 1);                        // описание кодека

    [stbl appendData:YTFullBox("stsc", 0, 0, stscBody)];

    NSMutableData *stszBody = [NSMutableData data];

    YTPut32(stszBody, 0);                        // размеры разные
    YTPut32(stszBody, (uint32_t)plan->count);

    for (NSUInteger i = 0; i < plan->count; i++) {
        YTPut32(stszBody, plan->sizes[i]);
    }

    [stbl appendData:YTFullBox("stsz", 0, 0, stszBody)];

    /**
     * co64, а не stco: файл легко перевалит за четыре гигабайта? Нет,
     * но смещение первой порции звука лежит за всем видео, и у длинного
     * ролика в 32 бита оно уже не всегда влезает. Восемь байт — одна
     * запись на дорожку, дешевле, чем гадать.
     */
    NSMutableData *co64Body = [NSMutableData data];

    YTPut32(co64Body, 1);
    YTPut32(co64Body, (uint32_t)(plan->chunkStart >> 32));
    YTPut32(co64Body, (uint32_t)(plan->chunkStart & 0xFFFFFFFF));

    [stbl appendData:YTFullBox("co64", 0, 0, co64Body)];

    return YTBox("stbl", stbl);
}

#pragma mark Дорожка целиком

+ (NSData *)trakFor:(YTTrackPlan *)plan number:(uint32_t)number {
    YTTrackInit *init = plan->init;

    BOOL video = [init isVideo];

    uint64_t seconds = init.timescale > 0
        ? (plan->totalTicks * YTMovieScale) / init.timescale : 0;

    NSMutableData *tkhdBody = [NSMutableData data];

    YTPut32(tkhdBody, 0);              // создан
    YTPut32(tkhdBody, 0);              // изменён
    YTPut32(tkhdBody, number);
    YTPut32(tkhdBody, 0);
    YTPut32(tkhdBody, (uint32_t)seconds);
    YTPut32(tkhdBody, 0); YTPut32(tkhdBody, 0);
    YTPut16(tkhdBody, 0);              // слой
    YTPut16(tkhdBody, 0);              // группа
    YTPut16(tkhdBody, video ? 0 : 0x0100);   // громкость
    YTPut16(tkhdBody, 0);

    // Единичная матрица преобразования.
    uint32_t matrix[9] = { 0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000 };

    for (int i = 0; i < 9; i++) { YTPut32(tkhdBody, matrix[i]); }

    YTPut32(tkhdBody, video ? (uint32_t)(init.width << 16) : 0);
    YTPut32(tkhdBody, video ? (uint32_t)(init.height << 16) : 0);

    // Флаг 3: дорожка участвует и в фильме, и в показе.
    NSMutableData *trak = [NSMutableData data];

    [trak appendData:YTFullBox("tkhd", 0, 3, tkhdBody)];

    NSMutableData *mdhdBody = [NSMutableData data];

    YTPut32(mdhdBody, 0);
    YTPut32(mdhdBody, 0);
    YTPut32(mdhdBody, init.timescale);
    YTPut32(mdhdBody, (uint32_t)plan->totalTicks);
    YTPut16(mdhdBody, 0x55C4);   // «und» — язык не указан
    YTPut16(mdhdBody, 0);

    NSMutableData *mdia = [NSMutableData data];

    [mdia appendData:YTFullBox("mdhd", 0, 0, mdhdBody)];

    NSMutableData *hdlrBody = [NSMutableData data];

    YTPut32(hdlrBody, 0);
    YTPutTag(hdlrBody, video ? "vide" : "soun");
    YTPut32(hdlrBody, 0); YTPut32(hdlrBody, 0); YTPut32(hdlrBody, 0);
    YTPut8(hdlrBody, 0);   // имя обработчика — пустое

    [mdia appendData:YTFullBox("hdlr", 0, 0, hdlrBody)];

    NSMutableData *minf = [NSMutableData data];

    if (video) {
        NSMutableData *vmhd = [NSMutableData data];

        YTPut16(vmhd, 0);
        YTPut16(vmhd, 0); YTPut16(vmhd, 0); YTPut16(vmhd, 0);

        [minf appendData:YTFullBox("vmhd", 0, 1, vmhd)];
    } else {
        NSMutableData *smhd = [NSMutableData data];

        YTPut16(smhd, 0);
        YTPut16(smhd, 0);

        [minf appendData:YTFullBox("smhd", 0, 0, smhd)];
    }

    // dinf/dref: данные лежат в этом же файле — одна запись с флагом 1.
    NSMutableData *drefBody = [NSMutableData data];

    YTPut32(drefBody, 1);
    [drefBody appendData:YTFullBox("url ", 0, 1, nil)];

    NSMutableData *dinf = [NSMutableData data];

    [dinf appendData:YTFullBox("dref", 0, 0, drefBody)];

    [minf appendData:YTBox("dinf", dinf)];
    [minf appendData:[self stblFor:plan]];

    [mdia appendData:YTBox("minf", minf)];

    [trak appendData:YTBox("mdia", mdia)];

    return YTBox("trak", trak);
}

#pragma mark Сборка

/** `moov` целиком — при уже известных местах порций. */
+ (NSData *)moovForVideo:(YTTrackPlan *)video audio:(YTTrackPlan *)audio {
    uint64_t seconds = video->init.timescale > 0
        ? (video->totalTicks * YTMovieScale) / video->init.timescale : 0;

    NSMutableData *mvhdBody = [NSMutableData data];

    YTPut32(mvhdBody, 0);
    YTPut32(mvhdBody, 0);
    YTPut32(mvhdBody, YTMovieScale);
    YTPut32(mvhdBody, (uint32_t)seconds);
    YTPut32(mvhdBody, 0x00010000);   // скорость
    YTPut16(mvhdBody, 0x0100);       // громкость
    YTPut16(mvhdBody, 0);
    YTPut32(mvhdBody, 0); YTPut32(mvhdBody, 0);

    uint32_t matrix[9] = { 0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000 };

    for (int i = 0; i < 9; i++) { YTPut32(mvhdBody, matrix[i]); }

    for (int i = 0; i < 6; i++) { YTPut32(mvhdBody, 0); }

    YTPut32(mvhdBody, audio != nil ? 3 : 2);   // следующий номер дорожки

    NSMutableData *moov = [NSMutableData data];

    [moov appendData:YTFullBox("mvhd", 0, 0, mvhdBody)];
    [moov appendData:[self trakFor:video number:1]];

    if (audio != nil) {
        [moov appendData:[self trakFor:audio number:2]];
    }

    return YTBox("moov", moov);
}

+ (BOOL)writeTo:(NSString *)path
      videoPath:(NSString *)videoPath
      audioPath:(NSString *)audioPath
       progress:(BOOL (^)(float part))progress {
    YTTrackPlan *video = [self planFor:videoPath];

    if (video == nil) {
        NSLog(@"[YouTube/Сборка] Видеодорожка не разобралась");

        return NO;
    }

    /**
     * Видеодорожка обязана быть видеодорожкой.
     *
     * `isVideo` у разбора означает «нашлись SPS». Не нашлись — и всё
     * дальнейшее пойдёт по звуковой ветке: дорожка получит описание
     * `mp4a` и обработчик `soun`, а внутри будет H.264. Файл при этом
     * соберётся и даже пройдёт проверку целости, но проигрыватель
     * откроет его и сразу закроет — декодировать такое нечем.
     */
    if (![video->init isVideo]) {
        NSLog(@"[YouTube/Сборка] У видеодорожки нет SPS — собирать нечего");

        return NO;
    }

    YTTrackPlan *audio = [audioPath length] > 0 ? [self planFor:audioPath] : nil;

    NSLog(@"[YouTube/Сборка] Видео: сэмплов %lu, %llu байт; звук: %@",
          (unsigned long)video->count, video->totalBytes,
          audio != nil ? [NSString stringWithFormat:@"%lu сэмплов",
                          (unsigned long)audio->count] : @"нет");

    NSFileManager *files = [NSFileManager defaultManager];

    [files removeItemAtPath:path error:NULL];
    [files createFileAtPath:path contents:nil attributes:nil];

    NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:path];

    if (out == nil) {
        return NO;
    }

    // ftyp: обычный `isom`, какой понимают все.
    NSMutableData *ftyp = [NSMutableData data];

    YTPutTag(ftyp, "isom");
    YTPut32(ftyp, 512);
    YTPutTag(ftyp, "isom");
    YTPutTag(ftyp, "iso2");
    YTPutTag(ftyp, "avc1");
    YTPutTag(ftyp, "mp41");

    NSData *header = YTBox("ftyp", ftyp);

    /**
     * `moov` пишется **перед** данными, а не после них.
     *
     * Хвостовой `moov` стандарт допускает, и VLC такой файл играет.
     * Но разборщику iOS он не нравится: тот отвечал отказом «не удаётся
     * открыть» ещё до дорожек. Порядок «описание, потом данные» — тот,
     * что кладут все, и спорить с ним себе дороже.
     *
     * Сложность в том, что таблицы содержат места порций, а места
     * зависят от длины самого `moov`. Выход простой: собрать `moov`
     * дважды. Длина от значений смещений не меняется — `co64` хранит
     * их по восемь байт независимо от величины, — поэтому второй сбор
     * даёт ровно тот же размер, что и первый.
     */
    video->chunkStart = 0;

    if (audio != nil) { audio->chunkStart = video->totalBytes; }

    NSData *draft = [self moovForVideo:video audio:audio];

    uint64_t dataStart = [header length] + [draft length] + 16;

    video->chunkStart = dataStart;

    if (audio != nil) { audio->chunkStart = dataStart + video->totalBytes; }

    NSData *moov = [self moovForVideo:video audio:audio];

    if ([moov length] != [draft length]) {
        NSLog(@"[YouTube/Сборка] Описание изменило длину (%lu → %lu) — "
              @"места порций сошлись бы неверно",
              (unsigned long)[draft length], (unsigned long)[moov length]);

        [out closeFile];
        [files removeItemAtPath:path error:NULL];

        return NO;
    }

    [out writeData:header];
    [out writeData:moov];

    /**
     * `mdat` с длиной в 64 бита, и длина известна заранее: это сумма
     * размеров сэмплов плюс собственный заголовок. Править её потом
     * не придётся.
     */
    uint64_t payload = video->totalBytes + (audio != nil ? audio->totalBytes : 0);
    uint64_t mdatSize = payload + 16;

    NSMutableData *mdatHead = [NSMutableData data];

    YTPut32(mdatHead, 1);
    YTPutTag(mdatHead, "mdat");
    YTPut32(mdatHead, (uint32_t)(mdatSize >> 32));
    YTPut32(mdatHead, (uint32_t)(mdatSize & 0xFFFFFFFF));

    [out writeData:mdatHead];

    uint64_t done = 0;

    YTTrackPlan *plans[2] = { video, audio };
    NSString *paths[2] = { videoPath, audioPath };

    for (int which = 0; which < 2; which++) {
        YTTrackPlan *plan = plans[which];

        if (plan == nil) {
            continue;
        }

        NSFileHandle *source = [NSFileHandle fileHandleForReadingAtPath:paths[which]];

        if (source == nil) {
            [out closeFile];
            [files removeItemAtPath:path error:NULL];

            return NO;
        }

        for (NSUInteger i = 0; i < plan->count; i++) {
            @autoreleasepool {
                [source seekToFileOffset:plan->offsets[i]];

                uint32_t left = plan->sizes[i];

                while (left > 0) {
                    NSUInteger take = left < YTCopyChunk ? left : YTCopyChunk;

                    NSData *piece = [source readDataOfLength:take];

                    if ([piece length] == 0) {
                        break;
                    }

                    [out writeData:piece];

                    left -= (uint32_t)[piece length];
                    done += [piece length];
                }
            }

            if ((i & 0x3F) == 0 && progress != nil) {
                if (!progress(payload > 0 ? (float)done / (float)payload : 0)) {
                    [source closeFile];
                    [out closeFile];
                    [files removeItemAtPath:path error:NULL];

                    NSLog(@"[YouTube/Сборка] Брошена по просьбе");

                    return NO;
                }
            }
        }

        [source closeFile];
    }

    uint64_t written = [out offsetInFile];

    [out closeFile];

    NSLog(@"[YouTube/Сборка] Готово: %@ (%llu байт, описание %lu байт впереди)",
          [path lastPathComponent], written, (unsigned long)[moov length]);

    return YES;
}

@end
