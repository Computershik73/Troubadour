#import <Foundation/Foundation.h>

/**
 * Субтитры — порт `Subtitles.cs`.
 *
 * Дорожки перечислены в ответе `/player`, в
 * `captions.playerCaptionsTracklistRenderer`. Сам текст лежит отдельно,
 * по адресу дорожки; просим его в `json3` — там время в миллисекундах
 * и разбирать нечего, тогда как обычный ответ приходит XML-ом.
 */
@interface YTSubtitleTrack : NSObject

@property (nonatomic, copy) NSString *language;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, assign) BOOL automatic;

/** Как показать в списке: у машинных дорожек к имени добавляется пометка. */
- (NSString *)displayName;

@end


/** Одна реплика: с какой по какую секунду и что показать. */
@interface YTSubtitleCue : NSObject

@property (nonatomic, assign) NSTimeInterval start;
@property (nonatomic, assign) NSTimeInterval end;
@property (nonatomic, copy) NSString *text;

@end


@interface YTSubtitles : NSObject

/** Дорожки из ответа `/player`; пустой массив, если субтитров нет. */
+ (NSArray *)tracksIn:(NSDictionary *)playerResponse;

/**
 * Реплики дорожки. Ходит в сеть, поэтому зовётся из фона.
 *
 * Пустой массив вместо ошибки: субтитров может не оказаться, и это
 * не повод чему-либо ломаться.
 */
+ (NSArray *)cuesFor:(YTSubtitleTrack *)track;

@end
