#import "YTPlaybackStats.h"

static unsigned long long _bytes = 0;
static double _kbps = 0;

@implementation YTPlaybackStats

+ (void)noteTransfer:(NSUInteger)bytes elapsed:(NSTimeInterval)seconds {
    [self noteTransfer:bytes elapsed:seconds paced:NO];
}

+ (void)noteTransfer:(NSUInteger)bytes
             elapsed:(NSTimeInterval)seconds
               paced:(BOOL)paced {
    if (bytes == 0) {
        return;
    }

    @synchronized (self) {
        _bytes += bytes;

        /**
         * Замер годен по объёму, а не по длительности.
         *
         * Прежде здесь стояло «не короче полусекунды», и это выворачивало
         * замер наизнанку: на быстрой связи сто килобайт приезжают
         * за треть секунды — такой перенос отбрасывался, — а проходили
         * только медленные. То есть из всех замеров мы оставляли ровно
         * те, что говорят о связи хуже всего, и объявляли их скоростью.
         */
        if (bytes < 16 * 1024 || seconds <= 0.01) {
            return;
        }

        double sample = bytes * 8.0 / seconds / 1000.0;

        if (_kbps <= 0) {
            _kbps = sample;

            return;
        }

        /**
         * Придержанный ответ — нижняя граница, и только.
         *
         * Он доказывает, что столько связь тянет, и ничего не говорит
         * о том, сколько она тянет ещё. Потому вверх такой замер двигает
         * оценку сразу, а вниз — по чуть-чуть: иначе эфир сам себе
         * назначал бы потолок, равный битрейту нынешней дорожки, и выше
         * неё не поднялся бы никогда.
         */
        if (paced) {
            _kbps = (sample > _kbps) ? sample : _kbps * 0.95 + sample * 0.05;

            return;
        }

        _kbps = _kbps * 0.7 + sample * 0.3;
    }
}

+ (unsigned long long)totalBytes {
    @synchronized (self) {
        return _bytes;
    }
}

+ (double)speedKbps {
    @synchronized (self) {
        return _kbps;
    }
}

@end
