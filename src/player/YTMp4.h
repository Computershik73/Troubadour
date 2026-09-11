#import <Foundation/Foundation.h>

/**
 * Разбор фрагментированного MP4 — того, чем YouTube раздаёт дорожки DASH.
 *
 * Порт `DashDemuxer.cs` из UWP-версии в той части, что касается чтения
 * боксов. Устройство потока там описано точно, и повторять описание незачем;
 * важно, что дорожка состоит из трёх частей:
 *
 *     init      ftyp + moov — описание кодека: SPS/PPS у видео,
 *               AudioSpecificConfig у звука, шкала времени. Лежит
 *               по диапазону `initRange` из ответа /player;
 *     sidx      карта фрагментов: у каждого длина в байтах и длительность.
 *               Лежит по `indexRange`;
 *     фрагменты moof + mdat, идут подряд после sidx. `moof` говорит, где
 *               и какой длины каждый сэмпл внутри `mdat`.
 *
 * Ничего сверх этого нам не нужно: мы не декодируем, а перекладываем
 * сэмплы в другой контейнер.
 */

#pragma mark Описание дорожки

/** Что вычитано из `moov` — всё, что нужно, чтобы собрать заголовки TS. */
@interface YTTrackInit : NSObject

/** Тиков в секунду у этой дорожки (`mdhd`). */
@property (nonatomic, assign) uint32_t timescale;

/** Идентификатор дорожки (`tkhd`) — им помечены фрагменты. */
@property (nonatomic, assign) uint32_t trackId;

#pragma mark Видео

/**
 * Наборы параметров из `avcC`. В MP4 они лежат отдельно от кадров,
 * а в потоке TS обязаны идти перед каждым ключевым кадром.
 */
@property (nonatomic, strong) NSArray *sps;
@property (nonatomic, strong) NSArray *pps;

/**
 * Сколько байт занимает длина NALU в `mdat`.
 *
 * В MP4 каждый NALU предваряется своей длиной, а в TS вместо неё идёт
 * стартовый код `00 00 00 01`. Размер поля берётся из `avcC` и бывает
 * не только четвёркой — предполагать её нельзя.
 */
@property (nonatomic, assign) uint8_t nalLengthSize;

@property (nonatomic, assign) uint32_t width;
@property (nonatomic, assign) uint32_t height;

#pragma mark Звук

/** Из AudioSpecificConfig в `esds` — они же уходят в заголовок ADTS. */
@property (nonatomic, assign) uint8_t audioObjectType;
@property (nonatomic, assign) uint8_t samplingFrequencyIndex;
@property (nonatomic, assign) uint8_t channelConfig;

@property (nonatomic, readonly) BOOL isVideo;

@end


#pragma mark Сэмпл

/** Один сэмпл внутри `mdat`: где лежит, сколько длится и ключевой ли он. */
@interface YTSample : NSObject

@property (nonatomic, assign) uint32_t offset;
@property (nonatomic, assign) uint32_t size;
@property (nonatomic, assign) uint32_t duration;

/**
 * Сдвиг времени показа относительно времени декодирования.
 *
 * У кадров с обратным предсказанием порядок показа не совпадает с порядком
 * в потоке, и без этого сдвига картинка шла бы рывками. Знаковый: в 32-й
 * версии `trun` он может быть отрицательным.
 */
@property (nonatomic, assign) int32_t compositionOffset;

@property (nonatomic, assign) BOOL isSync;

@end


#pragma mark Фрагмент

/** Разобранный `moof`: список сэмплов и время начала фрагмента. */
@interface YTFragment : NSObject

/** Время первого сэмпла в тиках дорожки (`tfdt`). */
@property (nonatomic, assign) uint64_t baseMediaDecodeTime;

/** Смещение начала данных от начала `moof`. */
@property (nonatomic, assign) uint32_t dataOffset;

@property (nonatomic, strong) NSArray *samples;

@end


#pragma mark Запись карты фрагментов

/** Одна запись `sidx`: сколько байт и сколько времени занимает фрагмент. */
@interface YTSidxEntry : NSObject

/** Смещение от начала дорожки — считается при разборе. */
@property (nonatomic, assign) uint64_t offset;
@property (nonatomic, assign) uint32_t size;

/** Длительность в тиках шкалы `sidx`. */
@property (nonatomic, assign) uint32_t duration;

@end


@interface YTMp4 : NSObject

/** Разбирает init-сегмент (`ftyp` + `moov`). */
+ (YTTrackInit *)parseInit:(NSData *)data;

/**
 * Разбирает `sidx`. `firstOffset` — байт, с которого начинается первый
 * фрагмент: это конец диапазона `indexRange` плюс один.
 *
 * Возвращает массив YTSidxEntry, а шкалу времени кладёт в `timescale`.
 */
+ (NSArray *)parseSidx:(NSData *)data
           firstOffset:(uint64_t)firstOffset
             timescale:(uint32_t *)timescale;

/**
 * Разбирает `moof` в начале данных фрагмента.
 *
 * `init` нужен ради значений по умолчанию: `tfhd` вправе задать длину
 * и длительность сэмпла один раз на весь фрагмент вместо того, чтобы
 * повторять их в `trun` для каждого.
 */
+ (YTFragment *)parseFragment:(NSData *)data init:(YTTrackInit *)init;

@end
