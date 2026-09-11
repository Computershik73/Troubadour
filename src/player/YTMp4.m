#import "YTMp4.h"

@implementation YTTrackInit

- (id)init {
    self = [super init];

    if (self != nil) {
        _nalLengthSize = 4;
    }

    return self;
}

- (BOOL)isVideo {
    return [_sps count] > 0;
}

@end

@implementation YTSample
@end

@implementation YTFragment
@end

@implementation YTSidxEntry
@end


#pragma mark - Чтение чисел

/**
 * Все числа в MP4 — с прямым порядком байтов (старший первый), независимо
 * от того, на чём мы работаем. Читаем побайтно, а не приведением указателя:
 * armv7 не обязан разрешать невыровненный доступ, а границы боксов
 * выравниванию не подчиняются.
 */
static uint32_t YTRead32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16)
         | ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
}

static uint16_t YTRead16(const uint8_t *bytes) {
    return (uint16_t)(((uint16_t)bytes[0] << 8) | (uint16_t)bytes[1]);
}

static uint64_t YTRead64(const uint8_t *bytes) {
    return ((uint64_t)YTRead32(bytes) << 32) | (uint64_t)YTRead32(bytes + 4);
}


#pragma mark - Обход боксов

/**
 * Находит бокс с таким именем среди прямых потомков области.
 *
 * Возвращает смещение **тела** бокса и кладёт его длину в `size`.
 * Ищем перебором, а не по заранее известному пути: порядок боксов внутри
 * контейнера стандартом не закреплён, и у разных дорожек он разный.
 */
static BOOL YTFindBox(const uint8_t *bytes, NSUInteger length,
                      const char *name, NSUInteger *bodyOffset, NSUInteger *bodySize) {
    NSUInteger cursor = 0;

    while (cursor + 8 <= length) {
        uint32_t size = YTRead32(bytes + cursor);
        NSUInteger header = 8;

        // Размер 1 означает, что настоящий лежит следом восемью байтами;
        // размер 0 — «до конца области».
        uint64_t boxSize = size;

        if (size == 1) {
            if (cursor + 16 > length) {
                return NO;
            }

            boxSize = YTRead64(bytes + cursor + 8);
            header = 16;
        } else if (size == 0) {
            boxSize = length - cursor;
        }

        if (boxSize < header || cursor + boxSize > length) {
            return NO;
        }

        if (memcmp(bytes + cursor + 4, name, 4) == 0) {
            *bodyOffset = cursor + header;
            *bodySize = (NSUInteger)(boxSize - header);

            return YES;
        }

        cursor += (NSUInteger)boxSize;
    }

    return NO;
}

/** То же, но по цепочке вложенных имён: «moov», «trak», «mdia»… */
static BOOL YTFindPath(const uint8_t *bytes, NSUInteger length,
                       NSArray *path, NSUInteger *bodyOffset, NSUInteger *bodySize) {
    NSUInteger offset = 0;
    NSUInteger size = length;

    for (NSString *name in path) {
        NSUInteger childOffset = 0;
        NSUInteger childSize = 0;

        if (!YTFindBox(bytes + offset, size,
                       [name UTF8String], &childOffset, &childSize)) {
            return NO;
        }

        offset += childOffset;
        size = childSize;
    }

    *bodyOffset = offset;
    *bodySize = size;

    return YES;
}


@implementation YTMp4

#pragma mark Init-сегмент

+ (YTTrackInit *)parseInit:(NSData *)data {
    if ([data length] < 16) {
        return nil;
    }

    const uint8_t *bytes = [data bytes];
    NSUInteger length = [data length];

    NSUInteger trakOffset = 0;
    NSUInteger trakSize = 0;

    if (!YTFindPath(bytes, length,
                    [NSArray arrayWithObjects:@"moov", @"trak", nil],
                    &trakOffset, &trakSize)) {
        NSLog(@"[YouTube/MP4] В init нет moov/trak");
        return nil;
    }

    YTTrackInit *track = [[YTTrackInit alloc] init];

    // tkhd: версия в первом байте, дальше идентификатор дорожки.
    NSUInteger tkhdOffset = 0;
    NSUInteger tkhdSize = 0;

    if (YTFindBox(bytes + trakOffset, trakSize, "tkhd", &tkhdOffset, &tkhdSize)) {
        const uint8_t *tkhd = bytes + trakOffset + tkhdOffset;

        // Поля до идентификатора: версия+флаги (4), затем два времени —
        // по 4 байта в версии 0 и по 8 в версии 1.
        NSUInteger idAt = (tkhd[0] == 1) ? 4 + 16 : 4 + 8;

        if (tkhdSize >= idAt + 4) {
            track.trackId = YTRead32(tkhd + idAt);
        }
    }

    // mdhd: там шкала времени дорожки.
    NSUInteger mdhdOffset = 0;
    NSUInteger mdhdSize = 0;

    if (YTFindPath(bytes + trakOffset, trakSize,
                   [NSArray arrayWithObjects:@"mdia", @"mdhd", nil],
                   &mdhdOffset, &mdhdSize)) {
        const uint8_t *mdhd = bytes + trakOffset + mdhdOffset;

        NSUInteger scaleAt = (mdhd[0] == 1) ? 4 + 16 : 4 + 8;

        if (mdhdSize >= scaleAt + 4) {
            track.timescale = YTRead32(mdhd + scaleAt);
        }
    }

    NSUInteger stsdOffset = 0;
    NSUInteger stsdSize = 0;

    if (!YTFindPath(bytes + trakOffset, trakSize,
                    [NSArray arrayWithObjects:@"mdia", @"minf", @"stbl", @"stsd", nil],
                    &stsdOffset, &stsdSize)) {
        NSLog(@"[YouTube/MP4] В init нет stsd");
        return nil;
    }

    const uint8_t *stsd = bytes + trakOffset + stsdOffset;

    // stsd: версия+флаги (4), число записей (4), дальше сами записи.
    if (stsdSize < 8) {
        return nil;
    }

    const uint8_t *entry = stsd + 8;
    NSUInteger entrySize = stsdSize - 8;

    if (entrySize < 8) {
        return nil;
    }

    uint32_t sampleEntrySize = YTRead32(entry);

    if (sampleEntrySize > entrySize) {
        sampleEntrySize = (uint32_t)entrySize;
    }

    if (memcmp(entry + 4, "avc1", 4) == 0 || memcmp(entry + 4, "avc3", 4) == 0) {
        [self parseVideoEntry:entry size:sampleEntrySize into:track];
    } else if (memcmp(entry + 4, "mp4a", 4) == 0) {
        [self parseAudioEntry:entry size:sampleEntrySize into:track];
    } else {
        NSLog(@"[YouTube/MP4] Неизвестный формат дорожки: %.4s", (const char *)(entry + 4));
        return nil;
    }

    return track;
}

/**
 * `avc1` — визуальная запись. Её заголовок фиксированной длины (78 байт
 * вместе с общими восемью), а за ним лежат вложенные боксы, среди которых
 * нужен `avcC`.
 */
+ (void)parseVideoEntry:(const uint8_t *)entry size:(uint32_t)size into:(YTTrackInit *)track {
    if (size < 86) {
        return;
    }

    track.width = YTRead16(entry + 32);
    track.height = YTRead16(entry + 34);

    NSUInteger avccOffset = 0;
    NSUInteger avccSize = 0;

    if (!YTFindBox(entry + 86, size - 86, "avcC", &avccOffset, &avccSize)) {
        NSLog(@"[YouTube/MP4] В avc1 нет avcC");
        return;
    }

    const uint8_t *avcc = entry + 86 + avccOffset;

    if (avccSize < 6) {
        return;
    }

    /**
     * Раскладка avcC: версия, три байта профиля, потом байт, младшие два
     * бита которого — длина поля длины NALU минус один, потом байт с числом
     * SPS в младших пяти битах.
     */
    track.nalLengthSize = (uint8_t)((avcc[4] & 0x03) + 1);

    NSUInteger cursor = 5;
    NSUInteger count = avcc[cursor] & 0x1F;

    cursor++;

    NSMutableArray *sps = [NSMutableArray array];

    for (NSUInteger i = 0; i < count && cursor + 2 <= avccSize; i++) {
        uint16_t length = YTRead16(avcc + cursor);

        cursor += 2;

        if (cursor + length > avccSize) {
            break;
        }

        [sps addObject:[NSData dataWithBytes:avcc + cursor length:length]];
        cursor += length;
    }

    track.sps = sps;

    if (cursor >= avccSize) {
        return;
    }

    count = avcc[cursor];
    cursor++;

    NSMutableArray *pps = [NSMutableArray array];

    for (NSUInteger i = 0; i < count && cursor + 2 <= avccSize; i++) {
        uint16_t length = YTRead16(avcc + cursor);

        cursor += 2;

        if (cursor + length > avccSize) {
            break;
        }

        [pps addObject:[NSData dataWithBytes:avcc + cursor length:length]];
        cursor += length;
    }

    track.pps = pps;
}

/**
 * `mp4a` — звуковая запись. Заголовок 28 байт вместе с общими восемью,
 * дальше `esds`, внутри которого лежит AudioSpecificConfig.
 */
+ (void)parseAudioEntry:(const uint8_t *)entry size:(uint32_t)size into:(YTTrackInit *)track {
    if (size < 36) {
        return;
    }

    NSUInteger esdsOffset = 0;
    NSUInteger esdsSize = 0;

    if (!YTFindBox(entry + 36, size - 36, "esds", &esdsOffset, &esdsSize)) {
        NSLog(@"[YouTube/MP4] В mp4a нет esds");
        return;
    }

    const uint8_t *esds = entry + 36 + esdsOffset;

    /**
     * Внутри esds — дескрипторы MPEG-4: у каждого тег, потом длина
     * в «растянутом» виде (по семь бит на байт, старший бит — признак
     * продолжения), потом тело. Нужен тег 0x05, DecoderSpecificInfo:
     * там и лежит AudioSpecificConfig.
     *
     * Идём по дескрипторам, а не по фиксированным смещениям: длины
     * необязательных полей внутри 0x03 и 0x04 плавают.
     */
    NSUInteger cursor = 4;  // версия и флаги

    while (cursor + 2 <= esdsSize) {
        uint8_t tag = esds[cursor];

        cursor++;

        NSUInteger length = 0;
        NSUInteger guard = 0;

        while (cursor < esdsSize && guard < 4) {
            uint8_t byte = esds[cursor];

            cursor++;
            guard++;

            length = (length << 7) | (byte & 0x7F);

            if ((byte & 0x80) == 0) {
                break;
            }
        }

        if (tag == 0x03) {
            // ES_Descriptor: идентификатор (2) и флаги (1), потом вложенные.
            if (cursor + 3 > esdsSize) {
                return;
            }

            uint8_t flags = esds[cursor + 2];

            cursor += 3;

            // Необязательные поля, если соответствующие биты подняты.
            if (flags & 0x80) { cursor += 2; }
            if (flags & 0x40) {
                if (cursor >= esdsSize) { return; }
                cursor += 1 + esds[cursor];
            }
            if (flags & 0x20) { cursor += 2; }

            continue;
        }

        if (tag == 0x04) {
            // DecoderConfigDescriptor: 13 байт до вложенных.
            cursor += 13;
            continue;
        }

        if (tag == 0x05) {
            if (cursor + 2 > esdsSize || length < 2) {
                return;
            }

            /**
             * AudioSpecificConfig: 5 бит типа объекта, 4 бита индекса
             * частоты, 4 бита числа каналов. Ровно эти три поля и уходят
             * в заголовок ADTS.
             */
            uint16_t config = YTRead16(esds + cursor);

            track.audioObjectType = (uint8_t)((config >> 11) & 0x1F);
            track.samplingFrequencyIndex = (uint8_t)((config >> 7) & 0x0F);
            track.channelConfig = (uint8_t)((config >> 3) & 0x0F);

            return;
        }

        cursor += length;
    }
}

#pragma mark Карта фрагментов

+ (NSArray *)parseSidx:(NSData *)data
           firstOffset:(uint64_t)firstOffset
             timescale:(uint32_t *)timescale {
    if ([data length] < 12) {
        return nil;
    }

    const uint8_t *bytes = [data bytes];
    NSUInteger length = [data length];

    NSUInteger bodyOffset = 0;
    NSUInteger bodySize = 0;

    if (!YTFindBox(bytes, length, "sidx", &bodyOffset, &bodySize)) {
        NSLog(@"[YouTube/MP4] В indexRange нет sidx");
        return nil;
    }

    const uint8_t *sidx = bytes + bodyOffset;

    if (bodySize < 12) {
        return nil;
    }

    uint8_t version = sidx[0];

    // Версия+флаги (4), reference_ID (4), timescale (4).
    NSUInteger cursor = 8;

    uint32_t scale = YTRead32(sidx + cursor);

    cursor += 4;

    if (timescale != NULL) {
        *timescale = scale;
    }

    // Дальше earliest_presentation_time и first_offset: по 4 байта
    // в нулевой версии и по 8 в первой.
    uint64_t sidxFirstOffset = 0;

    if (version == 0) {
        if (bodySize < cursor + 8) { return nil; }
        sidxFirstOffset = YTRead32(sidx + cursor + 4);
        cursor += 8;
    } else {
        if (bodySize < cursor + 16) { return nil; }
        sidxFirstOffset = YTRead64(sidx + cursor + 8);
        cursor += 16;
    }

    // reserved (2) и число записей (2).
    if (bodySize < cursor + 4) {
        return nil;
    }

    uint16_t count = YTRead16(sidx + cursor + 2);

    cursor += 4;

    NSMutableArray *entries = [NSMutableArray array];

    uint64_t offset = firstOffset + sidxFirstOffset;

    for (uint16_t i = 0; i < count; i++) {
        if (bodySize < cursor + 12) {
            break;
        }

        uint32_t first = YTRead32(sidx + cursor);
        uint32_t duration = YTRead32(sidx + cursor + 4);

        cursor += 12;

        // Старший бит — признак «ссылка на другой sidx», а не на фрагмент.
        // У дорожек YouTube такого не встречается, но проверить дешевле,
        // чем разбирать мусор как фрагмент.
        if ((first & 0x80000000u) != 0) {
            continue;
        }

        uint32_t size = first & 0x7FFFFFFFu;

        YTSidxEntry *entry = [[YTSidxEntry alloc] init];

        entry.offset = offset;
        entry.size = size;
        entry.duration = duration;

        [entries addObject:entry];

        offset += size;
    }

    return entries;
}

#pragma mark Фрагмент

+ (YTFragment *)parseFragment:(NSData *)data init:(YTTrackInit *)init {
    if ([data length] < 8) {
        return nil;
    }

    const uint8_t *bytes = [data bytes];
    NSUInteger length = [data length];

    NSUInteger moofOffset = 0;
    NSUInteger moofSize = 0;

    if (!YTFindBox(bytes, length, "moof", &moofOffset, &moofSize)) {
        return nil;
    }

    NSUInteger trafOffset = 0;
    NSUInteger trafSize = 0;

    if (!YTFindBox(bytes + moofOffset, moofSize, "traf", &trafOffset, &trafSize)) {
        return nil;
    }

    const uint8_t *traf = bytes + moofOffset + trafOffset;

    YTFragment *fragment = [[YTFragment alloc] init];

    // Значения по умолчанию из tfhd — ими `trun` вправе не повторяться.
    uint32_t defaultDuration = 0;
    uint32_t defaultSize = 0;
    uint32_t defaultFlags = 0;

    NSUInteger tfhdOffset = 0;
    NSUInteger tfhdSize = 0;

    if (YTFindBox(traf, trafSize, "tfhd", &tfhdOffset, &tfhdSize)) {
        const uint8_t *tfhd = traf + tfhdOffset;

        uint32_t flags = YTRead32(tfhd) & 0x00FFFFFF;
        NSUInteger cursor = 8;  // версия+флаги (4), track_ID (4)

        if (flags & 0x000001) { cursor += 8; }   // base_data_offset

        if (flags & 0x000002) { cursor += 4; }   // sample_description_index

        if ((flags & 0x000008) && tfhdSize >= cursor + 4) {
            defaultDuration = YTRead32(tfhd + cursor);
            cursor += 4;
        }

        if ((flags & 0x000010) && tfhdSize >= cursor + 4) {
            defaultSize = YTRead32(tfhd + cursor);
            cursor += 4;
        }

        if ((flags & 0x000020) && tfhdSize >= cursor + 4) {
            defaultFlags = YTRead32(tfhd + cursor);
        }
    }

    NSUInteger tfdtOffset = 0;
    NSUInteger tfdtSize = 0;

    if (YTFindBox(traf, trafSize, "tfdt", &tfdtOffset, &tfdtSize)) {
        const uint8_t *tfdt = traf + tfdtOffset;

        if (tfdt[0] == 1 && tfdtSize >= 12) {
            fragment.baseMediaDecodeTime = YTRead64(tfdt + 4);
        } else if (tfdtSize >= 8) {
            fragment.baseMediaDecodeTime = YTRead32(tfdt + 4);
        }
    }

    NSUInteger trunOffset = 0;
    NSUInteger trunSize = 0;

    if (!YTFindBox(traf, trafSize, "trun", &trunOffset, &trunSize)) {
        return nil;
    }

    const uint8_t *trun = traf + trunOffset;

    if (trunSize < 8) {
        return nil;
    }

    uint8_t version = trun[0];
    uint32_t flags = YTRead32(trun) & 0x00FFFFFF;
    uint32_t count = YTRead32(trun + 4);

    NSUInteger cursor = 8;

    /**
     * Смещение данных считается **от начала `moof`**, а не от начала traf
     * или mdat. Это частый источник ошибок: если отсчитать от `mdat`,
     * первые кадры окажутся сдвинутыми на длину заголовка.
     */
    int32_t dataOffset = 0;

    if ((flags & 0x000001) && trunSize >= cursor + 4) {
        dataOffset = (int32_t)YTRead32(trun + cursor);
        cursor += 4;
    }

    uint32_t firstSampleFlags = 0;
    BOOL hasFirstSampleFlags = NO;

    if ((flags & 0x000004) && trunSize >= cursor + 4) {
        firstSampleFlags = YTRead32(trun + cursor);
        hasFirstSampleFlags = YES;
        cursor += 4;
    }

    fragment.dataOffset = (uint32_t)(moofOffset - 8 + (NSUInteger)dataOffset);

    NSMutableArray *samples = [NSMutableArray array];

    uint32_t running = 0;

    for (uint32_t i = 0; i < count; i++) {
        uint32_t duration = defaultDuration;
        uint32_t size = defaultSize;
        uint32_t sampleFlags = defaultFlags;
        int32_t composition = 0;

        if (flags & 0x000100) {
            if (trunSize < cursor + 4) { break; }
            duration = YTRead32(trun + cursor);
            cursor += 4;
        }

        if (flags & 0x000200) {
            if (trunSize < cursor + 4) { break; }
            size = YTRead32(trun + cursor);
            cursor += 4;
        }

        if (flags & 0x000400) {
            if (trunSize < cursor + 4) { break; }
            sampleFlags = YTRead32(trun + cursor);
            cursor += 4;
        }

        if (flags & 0x000800) {
            if (trunSize < cursor + 4) { break; }

            // В нулевой версии сдвиг беззнаковый, в первой — знаковый.
            uint32_t raw = YTRead32(trun + cursor);

            composition = (version == 0) ? (int32_t)raw : (int32_t)((int32_t)raw);
            cursor += 4;
        }

        if (i == 0 && hasFirstSampleFlags) {
            sampleFlags = firstSampleFlags;
        }

        YTSample *sample = [[YTSample alloc] init];

        sample.offset = running;
        sample.size = size;
        sample.duration = duration;
        sample.compositionOffset = composition;

        /**
         * Ключевой кадр: бит `sample_is_non_sync_sample` снят.
         *
         * У звука все сэмплы ключевые, и там этот бит обычно не выставлен
         * вовсе — что нас устраивает: перед каждым кадром AAC всё равно
         * идёт свой заголовок.
         */
        sample.isSync = ((sampleFlags & 0x00010000) == 0);

        [samples addObject:sample];

        running += size;
    }

    fragment.samples = samples;

    return fragment;
}

@end
