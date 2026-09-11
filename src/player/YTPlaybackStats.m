#import "YTPlaybackStats.h"

static unsigned long long _bytes = 0;
static double _kbps = 0;

@implementation YTPlaybackStats

+ (void)noteTransfer:(NSUInteger)bytes elapsed:(NSTimeInterval)seconds {
    if (bytes == 0) {
        return;
    }

    @synchronized (self) {
        _bytes += bytes;

        /**
         * Скорость — только по переносам не короче полусекунды и не легче
         * шестнадцати килобайт: по остальным она врёт.
         */
        if (seconds >= 0.5 && bytes >= 16 * 1024) {
            double sample = bytes * 8.0 / seconds / 1000.0;

            _kbps = (_kbps <= 0) ? sample : _kbps * 0.7 + sample * 0.3;
        }
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
