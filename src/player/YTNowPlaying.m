#import "YTNowPlaying.h"

#import <MediaPlayer/MediaPlayer.h>

#import "YTImageLoader.h"

/** Что показано сейчас — чтобы обновление времени не стирало остального. */
static NSString *YTCardTitle = nil;
static NSString *YTCardChannel = nil;
static NSString *YTCardArtworkUrl = nil;
static UIImage *YTCardArtwork = nil;

@implementation YTNowPlaying

/**
 * Длительность в том виде, в каком её принимает система.
 *
 * Сутки — не длительность ролика, а признак того, что число мусорное:
 * у только что созданного плеера время бывает неопределённым, и такое
 * значение система показала бы ползунком на весь экран.
 */
+ (NSTimeInterval)sane:(NSTimeInterval)duration {
    if (isnan(duration) || isinf(duration)) {
        return 0;
    }

    return (duration > 0 && duration < 24 * 60 * 60) ? duration : 0;
}

+ (void)showTitle:(NSString *)title
          channel:(NSString *)channel
          artwork:(NSString *)artworkUrl
           player:(AVPlayer *)player
         duration:(NSTimeInterval)duration {
    YTCardTitle = [title copy];
    YTCardChannel = [channel copy];

    // Обложка та же — картинку заново не добываем.
    if (![YTCardArtworkUrl isEqualToString:artworkUrl]) {
        YTCardArtworkUrl = [artworkUrl copy];
        YTCardArtwork = nil;

        [self loadArtwork:artworkUrl];
    }

    [self refreshWithPlayer:player duration:duration];
}

+ (void)refreshWithPlayer:(AVPlayer *)player duration:(NSTimeInterval)duration {
    if (player == nil) {
        [self clear];
        return;
    }

    NSMutableDictionary *card = [NSMutableDictionary dictionary];

    [card setObject:([YTCardTitle length] > 0 ? YTCardTitle : @"YouTube")
             forKey:MPMediaItemPropertyTitle];

    if ([YTCardChannel length] > 0) {
        [card setObject:YTCardChannel forKey:MPMediaItemPropertyArtist];
    }

    NSTimeInterval length = [self sane:duration];

    if (length > 0) {
        [card setObject:[NSNumber numberWithDouble:length]
                 forKey:MPMediaItemPropertyPlaybackDuration];
    }

    NSTimeInterval elapsed = [self sane:CMTimeGetSeconds([player currentTime])];

    [card setObject:[NSNumber numberWithDouble:elapsed]
             forKey:MPNowPlayingInfoPropertyElapsedPlaybackTime];

    [card setObject:[NSNumber numberWithFloat:[player rate]]
             forKey:MPNowPlayingInfoPropertyPlaybackRate];

    if (YTCardArtwork != nil) {
        [card setObject:[[MPMediaItemArtwork alloc] initWithImage:YTCardArtwork]
                 forKey:MPMediaItemPropertyArtwork];
    }

    [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:card];
}

+ (void)clear {
    [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:nil];

    YTCardTitle = nil;
    YTCardChannel = nil;
    YTCardArtworkUrl = nil;
    YTCardArtwork = nil;
}

#pragma mark Кнопки на замке

/** Кому исполнять кнопки сейчас; меняется вместе с тем, кто играет. */
static void (^YTCommandPlay)(void) = nil;
static void (^YTCommandPause)(void) = nil;
static void (^YTCommandSkip)(NSTimeInterval) = nil;
static void (^YTCommandSeek)(NSTimeInterval) = nil;

/** Заведены ли уже обработчики в центре команд — заводим один раз. */
static BOOL YTCommandsWired = NO;

/** Шаг кнопок «назад» и «вперёд» — тот же, что у двойного тапа по кадру. */
static const NSTimeInterval YTCommandStep = 10.0;

+ (void)takeCommandsPlay:(void (^)(void))play
                   pause:(void (^)(void))pause
                    skip:(void (^)(NSTimeInterval seconds))skip
                  seekTo:(void (^)(NSTimeInterval seconds))seekTo {
    YTCommandPlay = [play copy];
    YTCommandPause = [pause copy];
    YTCommandSkip = [skip copy];
    YTCommandSeek = [seekTo copy];

    [self wireCommands];
}

+ (void)releaseCommands {
    YTCommandPlay = nil;
    YTCommandPause = nil;
    YTCommandSkip = nil;
    YTCommandSeek = nil;

    [self enableCommands:NO];
}

/**
 * Заводит обработчики один раз на всё время работы.
 *
 * Сами обработчики ничего не решают: они лишь зовут блок, который лежит
 * в переменной. Так смена играющего — страница на окно и обратно — стоит
 * присваивания, а не перезаведения команд; повторное `addTarget` иначе
 * копило бы обработчики, и одно нажатие срабатывало бы дважды.
 */
+ (void)wireCommands {
    Class centerClass = NSClassFromString(@"MPRemoteCommandCenter");

    // iOS 5 и 6: центра команд нет, там работает цепочка отвечающих.
    if (centerClass == nil) {
        return;
    }

    [self enableCommands:YES];

    if (YTCommandsWired) {
        return;
    }

    YTCommandsWired = YES;

    MPRemoteCommandCenter *center = [centerClass sharedCommandCenter];

    [[center playCommand] addTargetWithHandler:^MPRemoteCommandHandlerStatus(id event) {
        if (YTCommandPlay == nil) {
            return MPRemoteCommandHandlerStatusNoSuchContent;
        }

        YTCommandPlay();

        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [[center pauseCommand] addTargetWithHandler:^MPRemoteCommandHandlerStatus(id event) {
        if (YTCommandPause == nil) {
            return MPRemoteCommandHandlerStatusNoSuchContent;
        }

        YTCommandPause();

        return MPRemoteCommandHandlerStatusSuccess;
    }];

    /**
     * Переключатель приходит от гарнитуры и с наушников: одна кнопка
     * на оба действия, и решать, что делать, приходится нам.
     */
    [[center togglePlayPauseCommand] addTargetWithHandler:^MPRemoteCommandHandlerStatus(id event) {
        if (YTCommandPlay == nil || YTCommandPause == nil) {
            return MPRemoteCommandHandlerStatusNoSuchContent;
        }

        if ([[MPNowPlayingInfoCenter defaultCenter] nowPlayingInfo] != nil &&
            [[[[MPNowPlayingInfoCenter defaultCenter] nowPlayingInfo]
                objectForKey:MPNowPlayingInfoPropertyPlaybackRate] floatValue] > 0) {
            YTCommandPause();
        } else {
            YTCommandPlay();
        }

        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [[center skipForwardCommand] setPreferredIntervals:
        [NSArray arrayWithObject:[NSNumber numberWithDouble:YTCommandStep]]];

    [[center skipBackwardCommand] setPreferredIntervals:
        [NSArray arrayWithObject:[NSNumber numberWithDouble:YTCommandStep]]];

    [[center skipForwardCommand] addTargetWithHandler:^MPRemoteCommandHandlerStatus(id event) {
        if (YTCommandSkip == nil) {
            return MPRemoteCommandHandlerStatusNoSuchContent;
        }

        YTCommandSkip([self intervalOf:event]);

        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [[center skipBackwardCommand] addTargetWithHandler:^MPRemoteCommandHandlerStatus(id event) {
        if (YTCommandSkip == nil) {
            return MPRemoteCommandHandlerStatusNoSuchContent;
        }

        YTCommandSkip(-[self intervalOf:event]);

        return MPRemoteCommandHandlerStatusSuccess;
    }];

    /**
     * Перетаскивание ползунка — с iOS 9.1. На системах постарше команды
     * попросту нет, и ползунок на замке остаётся указателем.
     */
    if ([center respondsToSelector:@selector(changePlaybackPositionCommand)]) {
        [[center changePlaybackPositionCommand]
            addTargetWithHandler:^MPRemoteCommandHandlerStatus(id event) {
            if (YTCommandSeek == nil ||
                ![event respondsToSelector:@selector(positionTime)]) {
                return MPRemoteCommandHandlerStatusNoSuchContent;
            }

            YTCommandSeek([(MPChangePlaybackPositionCommandEvent *)event positionTime]);

            return MPRemoteCommandHandlerStatusSuccess;
        }];
    }
}

/** Шаг из события; если система его не назвала — наш собственный. */
+ (NSTimeInterval)intervalOf:(id)event {
    if (![event respondsToSelector:@selector(interval)]) {
        return YTCommandStep;
    }

    NSTimeInterval interval = [(MPSkipIntervalCommandEvent *)event interval];

    return (interval > 0) ? interval : YTCommandStep;
}

/**
 * Что показывать на замке.
 *
 * «Следующий» и «предыдущий» выключены намеренно: ролик один, переключать
 * нечего, а пока они включены, система рисует их вместо кнопок на десять
 * секунд назад и вперёд — тех самых, что нужны в видео.
 */
+ (void)enableCommands:(BOOL)enabled {
    Class centerClass = NSClassFromString(@"MPRemoteCommandCenter");

    if (centerClass == nil) {
        return;
    }

    MPRemoteCommandCenter *center = [centerClass sharedCommandCenter];

    [[center playCommand] setEnabled:enabled];
    [[center pauseCommand] setEnabled:enabled];
    [[center togglePlayPauseCommand] setEnabled:enabled];
    [[center skipForwardCommand] setEnabled:(enabled && YTCommandSkip != nil)];
    [[center skipBackwardCommand] setEnabled:(enabled && YTCommandSkip != nil)];

    [[center nextTrackCommand] setEnabled:NO];
    [[center previousTrackCommand] setEnabled:NO];

    if ([center respondsToSelector:@selector(changePlaybackPositionCommand)]) {
        [[center changePlaybackPositionCommand]
            setEnabled:(enabled && YTCommandSeek != nil)];
    }
}

/**
 * Обложка ролика. Триста точек: больше экрану блокировки не нужно даже
 * на ретине, а на iPhone 4 лишний разворот кадра в память заметен.
 */
+ (void)loadArtwork:(NSString *)url {
    if ([url length] == 0) {
        return;
    }

    NSString *wanted = [url copy];

    [YTImageLoader loadUrl:url targetWidth:300 completion:^(UIImage *image) {
        // Пока ходили за картинкой, мог смениться ролик — тогда она чужая.
        if (image == nil || ![YTCardArtworkUrl isEqualToString:wanted]) {
            return;
        }

        YTCardArtwork = image;

        /**
         * Карточка переписывается целиком, но только если она наша:
         * `nowPlayingInfo` мог уже обнулить тот, кто закончил играть.
         */
        NSDictionary *shown = [[MPNowPlayingInfoCenter defaultCenter] nowPlayingInfo];

        if ([shown count] == 0) {
            return;
        }

        NSMutableDictionary *card = [NSMutableDictionary dictionaryWithDictionary:shown];

        [card setObject:[[MPMediaItemArtwork alloc] initWithImage:image]
                 forKey:MPMediaItemPropertyArtwork];

        [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:card];
    }];
}

@end
