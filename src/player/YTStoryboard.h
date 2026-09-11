#import <UIKit/UIKit.h>

/** Один кадр раскадровки: где он лежит и какое место занимает на листе. */
@interface YTStoryboardFrame : NSObject

@property (nonatomic, copy) NSString *sheet;
@property (nonatomic, assign) NSInteger column;
@property (nonatomic, assign) NSInteger row;
@property (nonatomic, assign) NSInteger width;
@property (nonatomic, assign) NSInteger height;

@end


/**
 * Раскадровка для перемотки — порт `StoryboardThumbnails.cs`.
 *
 * YouTube кладёт мелкие кадры ролика на общие листы-спрайты, а как их
 * читать, описано одной строкой в ответе `/player`
 * (`storyboards.playerStoryboardSpecRenderer.spec`): адрес с подстановками
 * и через `|` — уровни, каждый со своим размером кадра, числом кадров,
 * сеткой и шагом по времени.
 */
@interface YTStoryboard : NSObject

/** Разбирает строку описания; nil, если она пуста или непонятна. */
+ (YTStoryboard *)parse:(NSString *)spec;

/** Строка описания из ответа `/player`. */
+ (NSString *)specIn:(NSDictionary *)playerResponse;

/** Кадр, который приходится на эту секунду. */
- (YTStoryboardFrame *)frameAt:(NSTimeInterval)seconds;

@end
