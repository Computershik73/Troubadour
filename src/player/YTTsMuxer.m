#import "YTTsMuxer.h"

#import "YTMp4.h"

/**
 * Идентификаторы потоков внутри TS.
 *
 * Числа произвольные — важно лишь, чтобы они совпадали в таблице PMT
 * и в самих пакетах. Взяты привычные, те же, что ставит большинство
 * упаковщиков: так проще смотреть поток сторонними средствами.
 */
static const uint16_t YTPidPat   = 0x0000;
static const uint16_t YTPidPmt   = 0x1000;
static const uint16_t YTPidVideo = 0x0100;
static const uint16_t YTPidAudio = 0x0101;

/** Размер пакета TS неизменен и равен 188 байтам. */
static const NSUInteger YTTsPacketSize = 188;

/**
 * Часы MPEG — 90 кГц. К ним приводятся времена обеих дорожек, у которых
 * шкалы свои: у видео обычно 90000 или 30000, у звука — частота
 * дискретизации.
 */
static const uint64_t YTMpegClock = 90000;

/** Частоты дискретизации по индексу из AudioSpecificConfig. */
static const uint32_t YTAacRates[16] = {
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
    16000, 12000, 11025, 8000, 7350, 0, 0, 0
};


@implementation YTTsMuxer {
    NSMutableData *_output;

    YTTrackInit *_video;
    YTTrackInit *_audio;

    /**
     * Счётчики непрерывности — по одному на каждый идентификатор потока.
     *
     * Четыре бита, которые обязаны увеличиваться на единицу в каждом
     * следующем пакете этого потока. Декодер по ним определяет потерю
     * пакета; если считать неправильно, он решит, что поток рвётся,
     * и начнёт пропускать кадры.
     */
    uint8_t _videoCounter;
    uint8_t _audioCounter;
    uint8_t _patCounter;
    uint8_t _pmtCounter;

    /** Заголовок SPS/PPS в виде Annex B — собирается один раз. */
    NSData *_parameterSets;

    BOOL _wroteTables;
}

- (id)initWithVideo:(YTTrackInit *)videoInit audio:(YTTrackInit *)audioInit {
    self = [super init];

    if (self == nil) {
        return nil;
    }

    _output = [NSMutableData data];
    _video = videoInit;
    _audio = audioInit;

    if (_video != nil) {
        _parameterSets = [self buildParameterSets];
    }

    return self;
}

#pragma mark Служебные таблицы

/**
 * Пишет один пакет TS.
 *
 * `payload` может не поместиться целиком — тогда вызывающий зовёт снова.
 * Возвращает, сколько байт удалось положить.
 *
 * Устройство пакета: четырёхбайтовый заголовок, затем необязательное
 * «поле адаптации» и полезная нагрузка. Поле адаптации нужно в двух
 * случаях — когда надо передать часы (PCR) и когда нагрузки не хватает
 * до конца пакета: пакеты обязаны быть ровно по 188 байт, и недостачу
 * добивают именно им.
 */
- (NSUInteger)writePacket:(const uint8_t *)payload
                   length:(NSUInteger)length
                      pid:(uint16_t)pid
                  counter:(uint8_t *)counter
                    start:(BOOL)start
                      pcr:(int64_t)pcr
             randomAccess:(BOOL)randomAccess {
    uint8_t packet[188];

    memset(packet, 0xFF, sizeof(packet));

    packet[0] = 0x47;                                        // признак начала
    packet[1] = (uint8_t)((start ? 0x40 : 0x00) | ((pid >> 8) & 0x1F));
    packet[2] = (uint8_t)(pid & 0xFF);

    NSUInteger header = 4;
    NSUInteger adaptationLength = 0;

    BOOL needsPcr = (pcr >= 0);

    // Сколько места останется под нагрузку, если поля адаптации не будет.
    NSUInteger available = YTTsPacketSize - header;

    if (needsPcr) {
        adaptationLength = 8;   // длина (1) + флаги (1) + PCR (6)
    } else if (length < available) {
        // Нагрузки не хватает — добиваем полем адаптации.
        adaptationLength = available - length;

        if (adaptationLength < 2) {
            // Меньше двух байт полем адаптации не выразить: один байт
            // означает «длина 0», то есть ровно один лишний байт.
            adaptationLength = (adaptationLength == 1) ? 1 : 0;
        }
    }

    if (adaptationLength > 0) {
        packet[3] = (uint8_t)(0x30 | (*counter & 0x0F));     // адаптация + нагрузка

        packet[4] = (uint8_t)(adaptationLength - 1);

        if (adaptationLength >= 2) {
            /**
             * Признак точки входа (`random_access_indicator`, 0x40).
             *
             * Им помечается пакет, с которого можно начать разбор потока
             * не с начала: дальше идёт ключевой кадр со своими заголовками.
             * Без этой пометки плеер не знает ни одной точки входа в поток
             * и считает, что ход быстрее обычного невозможен, — `AVPlayer`
             * тогда отвечает `canPlayFastForward = NO` и молча срезает
             * любую скорость выше единицы до неё же.
             *
             * Ровно это и было: ускорение не работало не оттого, что мы
             * не так его просили, а оттого, что наши куски выглядели
             * потоком без единой точки входа.
             */
            packet[5] = (uint8_t)((needsPcr ? 0x10 : 0x00) |
                                  (randomAccess ? 0x40 : 0x00));

            if (needsPcr) {
                uint64_t base = (uint64_t)pcr;

                packet[6] = (uint8_t)((base >> 25) & 0xFF);
                packet[7] = (uint8_t)((base >> 17) & 0xFF);
                packet[8] = (uint8_t)((base >> 9) & 0xFF);
                packet[9] = (uint8_t)((base >> 1) & 0xFF);
                packet[10] = (uint8_t)(((base & 0x01) << 7) | 0x7E);
                packet[11] = 0x00;
            }

            // Остаток поля адаптации — заполнитель.
            for (NSUInteger i = 6 + (needsPcr ? 6 : 0); i < 4 + adaptationLength; i++) {
                packet[i] = 0xFF;
            }
        }

        header += adaptationLength;
    } else {
        packet[3] = (uint8_t)(0x10 | (*counter & 0x0F));     // только нагрузка
    }

    NSUInteger room = YTTsPacketSize - header;
    NSUInteger take = MIN(room, length);

    if (take > 0) {
        memcpy(packet + header, payload, take);
    }

    *counter = (uint8_t)((*counter + 1) & 0x0F);

    [_output appendBytes:packet length:YTTsPacketSize];

    return take;
}

/** Разбивает нагрузку на столько пакетов, сколько нужно. */
- (void)writePayload:(NSData *)payload
                 pid:(uint16_t)pid
             counter:(uint8_t *)counter
                 pcr:(int64_t)pcr
        randomAccess:(BOOL)randomAccess {
    const uint8_t *bytes = [payload bytes];
    NSUInteger remaining = [payload length];
    BOOL start = YES;

    while (remaining > 0) {
        /*
         * Пометка ставится только на первый пакет нагрузки: точка входа
         * — это начало кадра, а не каждый его кусок.
         */
        NSUInteger written = [self writePacket:bytes
                                        length:remaining
                                           pid:pid
                                       counter:counter
                                         start:start
                                           pcr:start ? pcr : -1
                                  randomAccess:start && randomAccess];

        bytes += written;
        remaining -= written;
        start = NO;
    }
}

/**
 * Подсчёт CRC-32 в том виде, в каком его требует MPEG-2 — с прямым
 * порядком бит и полиномом 0x04C11DB7. Это не тот CRC, что в zip:
 * значения совпадать не будут, и подставить готовую реализацию нельзя.
 */
static uint32_t YTCrc32(const uint8_t *bytes, NSUInteger length) {
    uint32_t crc = 0xFFFFFFFFu;

    for (NSUInteger i = 0; i < length; i++) {
        crc ^= (uint32_t)bytes[i] << 24;

        for (int bit = 0; bit < 8; bit++) {
            crc = (crc & 0x80000000u) ? ((crc << 1) ^ 0x04C11DB7u) : (crc << 1);
        }
    }

    return crc;
}

/** Оборачивает тело таблицы в секцию с длиной и контрольной суммой. */
- (NSData *)wrapSection:(NSMutableData *)body tableId:(uint8_t)tableId {
    NSMutableData *section = [NSMutableData data];

    uint8_t header[3];

    // Длина считается от следующего байта и включает четыре байта CRC.
    NSUInteger sectionLength = [body length] + 4;

    header[0] = tableId;
    header[1] = (uint8_t)(0xB0 | ((sectionLength >> 8) & 0x0F));
    header[2] = (uint8_t)(sectionLength & 0xFF);

    [section appendBytes:header length:3];
    [section appendData:body];

    uint32_t crc = YTCrc32([section bytes], [section length]);

    uint8_t tail[4] = {
        (uint8_t)((crc >> 24) & 0xFF),
        (uint8_t)((crc >> 16) & 0xFF),
        (uint8_t)((crc >> 8) & 0xFF),
        (uint8_t)(crc & 0xFF)
    };

    [section appendBytes:tail length:4];

    // Перед секцией идёт указатель на её начало — у нас всегда ноль.
    NSMutableData *payload = [NSMutableData data];
    uint8_t pointer = 0;

    [payload appendBytes:&pointer length:1];
    [payload appendData:section];

    return payload;
}

/** PAT: единственная программа, её описание лежит в PMT. */
- (void)writePat {
    NSMutableData *body = [NSMutableData data];

    uint8_t bytes[9] = {
        0x00, 0x01,             // идентификатор потока данных
        0xC1,                   // версия 0, таблица действует
        0x00, 0x00,             // номер секции и последней секции
        0x00, 0x01,             // номер программы
        (uint8_t)(0xE0 | ((YTPidPmt >> 8) & 0x1F)),
        (uint8_t)(YTPidPmt & 0xFF)
    };

    [body appendBytes:bytes length:sizeof(bytes)];

    [self writePayload:[self wrapSection:body tableId:0x00]
                   pid:YTPidPat
               counter:&_patCounter
                   pcr:-1
          randomAccess:NO];
}

/** PMT: какие дорожки есть в программе и какого они типа. */
- (void)writePmt {
    NSMutableData *body = [NSMutableData data];

    // Часы программы берутся из видеопотока — он идёт равномернее звука.
    uint16_t pcrPid = (_video != nil) ? YTPidVideo : YTPidAudio;

    uint8_t head[7] = {
        0x00, 0x01,             // номер программы
        0xC1,                   // версия 0, таблица действует
        0x00, 0x00,             // номер секции и последней секции
        (uint8_t)(0xE0 | ((pcrPid >> 8) & 0x1F)),
        (uint8_t)(pcrPid & 0xFF)
    };

    [body appendBytes:head length:sizeof(head)];

    uint8_t infoLength[2] = { 0xF0, 0x00 };     // описателей программы нет

    [body appendBytes:infoLength length:2];

    if (_video != nil) {
        // 0x1B — H.264.
        uint8_t entry[5] = {
            0x1B,
            (uint8_t)(0xE0 | ((YTPidVideo >> 8) & 0x1F)),
            (uint8_t)(YTPidVideo & 0xFF),
            0xF0, 0x00
        };

        [body appendBytes:entry length:sizeof(entry)];
    }

    if (_audio != nil) {
        // 0x0F — AAC в обёртке ADTS.
        uint8_t entry[5] = {
            0x0F,
            (uint8_t)(0xE0 | ((YTPidAudio >> 8) & 0x1F)),
            (uint8_t)(YTPidAudio & 0xFF),
            0xF0, 0x00
        };

        [body appendBytes:entry length:sizeof(entry)];
    }

    [self writePayload:[self wrapSection:body tableId:0x02]
                   pid:YTPidPmt
               counter:&_pmtCounter
                   pcr:-1
          randomAccess:NO];
}

- (void)ensureTables {
    if (_wroteTables) {
        return;
    }

    _wroteTables = YES;

    [self writePat];
    [self writePmt];
}

#pragma mark PES

/**
 * Записывает время в том виде, в каком его ждёт заголовок PES: 33 бита,
 * разложенные по пяти байтам вперемешку с обязательными единицами.
 */
static void YTWriteTimestamp(uint8_t *out, uint64_t value, uint8_t marker) {
    out[0] = (uint8_t)(marker | (((value >> 30) & 0x07) << 1) | 0x01);
    out[1] = (uint8_t)((value >> 22) & 0xFF);
    out[2] = (uint8_t)((((value >> 15) & 0x7F) << 1) | 0x01);
    out[3] = (uint8_t)((value >> 7) & 0xFF);
    out[4] = (uint8_t)(((value & 0x7F) << 1) | 0x01);
}

/**
 * Собирает пакет PES вокруг готовой нагрузки.
 *
 * `dts` отрицательный означает «времена совпадают» — тогда в заголовок
 * пишется только PTS, как того и требует стандарт: дублировать одинаковые
 * значения нельзя.
 */
- (NSData *)buildPes:(NSData *)payload
           streamId:(uint8_t)streamId
                pts:(uint64_t)pts
                dts:(int64_t)dts {
    BOOL bothTimes = (dts >= 0 && (uint64_t)dts != pts);

    NSUInteger headerLength = bothTimes ? 10 : 5;

    NSMutableData *pes = [NSMutableData data];

    uint8_t head[9];

    head[0] = 0x00;
    head[1] = 0x00;
    head[2] = 0x01;
    head[3] = streamId;

    /**
     * Длина пакета. У видео её принято оставлять нулём — «до конца», —
     * потому что кадр запросто превышает 65535 байт, а поле всего
     * двухбайтовое. У звука длина известна и помещается, но ноль допустим
     * и там, и одинаковый путь проще.
     */
    NSUInteger declared = [payload length] + 3 + headerLength;

    if (declared > 0xFFFF) {
        declared = 0;
    }

    head[4] = (uint8_t)((declared >> 8) & 0xFF);
    head[5] = (uint8_t)(declared & 0xFF);

    head[6] = 0x80;                                  // без шифрования, без приоритета
    head[7] = bothTimes ? 0xC0 : 0x80;               // какие времена присутствуют
    head[8] = (uint8_t)headerLength;

    [pes appendBytes:head length:sizeof(head)];

    uint8_t times[10];

    YTWriteTimestamp(times, pts, bothTimes ? 0x30 : 0x20);

    if (bothTimes) {
        YTWriteTimestamp(times + 5, (uint64_t)dts, 0x10);
    }

    [pes appendBytes:times length:headerLength];
    [pes appendData:payload];

    return pes;
}

#pragma mark Видео

/** SPS и PPS со стартовыми кодами — то, что идёт перед ключевым кадром. */
- (NSData *)buildParameterSets {
    NSMutableData *sets = [NSMutableData data];

    uint8_t startCode[4] = { 0x00, 0x00, 0x00, 0x01 };

    for (NSData *sps in _video.sps) {
        /**
         * Разряд и уровень H.264 — прямо в журнал.
         *
         * Это решающее свидетельство, когда картинка выходит зелёной
         * с полосой мусора: так ведёт себя аппаратный декодер, которому
         * дали поток тяжелее, чем он умеет. Догадываться по номеру itag
         * не нужно — в первых трёх байтах SPS написано ровно то, что мы
         * ему скармливаем.
         *
         * Уровень — число, делённое на десять: 41 значит 4.1. У A5
         * (iPad 2, iPhone 4S) потолок — High 4.1, то есть 1080p при
         * тридцати кадрах. Всё, что выше, даёт как раз зелёный кадр.
         */
        if ([sps length] >= 4) {
            const uint8_t *bytes = [sps bytes];

            NSLog(@"[YouTube/Упаковка] H.264: разряд %u, уровень %u.%u",
                  bytes[1], bytes[3] / 10, bytes[3] % 10);
        }

        [sets appendBytes:startCode length:4];
        [sets appendData:sps];
    }

    for (NSData *pps in _video.pps) {
        [sets appendBytes:startCode length:4];
        [sets appendData:pps];
    }

    return sets;
}

/**
 * Переписывает сэмпл из формата MP4 в Annex B.
 *
 * В MP4 сэмпл — это цепочка «длина, потом NALU»; длина занимает столько
 * байт, сколько сказано в `avcC`. В потоке TS длин нет вовсе, вместо
 * каждой стоит стартовый код, а границу следующего NALU декодер находит
 * по нему же.
 */
- (NSData *)annexBFrom:(NSData *)sample {
    NSMutableData *out = [NSMutableData dataWithCapacity:[sample length] + 64];

    const uint8_t *bytes = [sample bytes];
    NSUInteger length = [sample length];
    NSUInteger cursor = 0;

    uint8_t lengthSize = _video.nalLengthSize;
    uint8_t startCode[4] = { 0x00, 0x00, 0x00, 0x01 };

    while (cursor + lengthSize <= length) {
        uint32_t naluLength = 0;

        for (uint8_t i = 0; i < lengthSize; i++) {
            naluLength = (naluLength << 8) | bytes[cursor + i];
        }

        cursor += lengthSize;

        if (naluLength == 0 || cursor + naluLength > length) {
            break;
        }

        [out appendBytes:startCode length:4];
        [out appendBytes:bytes + cursor length:naluLength];

        cursor += naluLength;
    }

    return out;
}

- (void)addVideoSample:(NSData *)sample
                   pts:(uint64_t)pts
                   dts:(uint64_t)dts
              keyframe:(BOOL)keyframe {
    if (_video == nil || [sample length] == 0) {
        return;
    }

    [self ensureTables];

    uint32_t scale = _video.timescale > 0 ? _video.timescale : 90000;

    uint64_t pts90 = pts * YTMpegClock / scale;
    uint64_t dts90 = dts * YTMpegClock / scale;

    NSMutableData *payload = [NSMutableData data];

    /**
     * Разделитель единиц доступа. Формально необязателен, но без него
     * часть декодеров не понимает, где кончается один кадр и начинается
     * следующий, — а нам важно, чтобы поток читался и на самых старых.
     */
    uint8_t aud[6] = { 0x00, 0x00, 0x00, 0x01, 0x09, 0xF0 };

    [payload appendBytes:aud length:sizeof(aud)];

    // Перед каждым ключевым кадром — наборы параметров. В MP4 они лежат
    // один раз в `avcC`, здесь обязаны повторяться: иначе плеер, начав
    // читать поток с середины, не знает, как его разбирать.
    if (keyframe && _parameterSets != nil) {
        [payload appendData:_parameterSets];
    }

    [payload appendData:[self annexBFrom:sample]];

    NSData *pes = [self buildPes:payload streamId:0xE0 pts:pts90 dts:(int64_t)dts90];

    // Часы передаются на ключевых кадрах: чаще незачем, реже — плеер
    // начинает гадать о скорости потока.
    [self writePayload:pes
                   pid:YTPidVideo
               counter:&_videoCounter
                   pcr:keyframe ? (int64_t)dts90 : -1
          randomAccess:keyframe];
}

#pragma mark Звук

/**
 * Заголовок ADTS — семь байт перед каждым кадром AAC.
 *
 * В MP4 эти сведения лежат один раз, в `esds`; в потоке TS кадр обязан
 * нести их с собой, потому что читать поток можно с любого места.
 */
- (NSData *)adtsHeaderFor:(NSUInteger)frameLength {
    uint8_t header[7];

    NSUInteger total = frameLength + 7;

    uint8_t profile = _audio.audioObjectType > 0 ? _audio.audioObjectType : 2;
    uint8_t rateIndex = _audio.samplingFrequencyIndex & 0x0F;
    uint8_t channels = _audio.channelConfig > 0 ? _audio.channelConfig : 2;

    header[0] = 0xFF;
    header[1] = 0xF1;                                  // MPEG-4, без проверки чётности

    // В ADTS тип объекта записан на единицу меньше, чем в AudioSpecificConfig.
    header[2] = (uint8_t)(((profile - 1) << 6) | (rateIndex << 2) | ((channels >> 2) & 0x01));
    header[3] = (uint8_t)(((channels & 0x03) << 6) | ((total >> 11) & 0x03));
    header[4] = (uint8_t)((total >> 3) & 0xFF);
    header[5] = (uint8_t)(((total & 0x07) << 5) | 0x1F);
    header[6] = 0xFC;

    return [NSData dataWithBytes:header length:sizeof(header)];
}

- (void)addAudioSample:(NSData *)sample pts:(uint64_t)pts {
    if (_audio == nil || [sample length] == 0) {
        return;
    }

    [self ensureTables];

    uint32_t scale = _audio.timescale;

    if (scale == 0) {
        scale = YTAacRates[_audio.samplingFrequencyIndex & 0x0F];
    }

    if (scale == 0) {
        scale = 44100;
    }

    uint64_t pts90 = pts * YTMpegClock / scale;

    NSMutableData *payload = [NSMutableData data];

    [payload appendData:[self adtsHeaderFor:[sample length]]];
    [payload appendData:sample];

    // У звука время показа и время декодирования всегда совпадают.
    NSData *pes = [self buildPes:payload streamId:0xC0 pts:pts90 dts:-1];

    [self writePayload:pes pid:YTPidAudio counter:&_audioCounter pcr:-1
              randomAccess:YES];
}

- (NSData *)finish {
    return _output;
}

@end
