#import <Foundation/Foundation.h>

/** Кусок ролика, который стоит пропустить. */
@interface YTSponsorSegment : NSObject

@property (nonatomic, assign) NSTimeInterval start;
@property (nonatomic, assign) NSTimeInterval end;
@property (nonatomic, copy) NSString *category;

@end


/**
 * Клиент общей базы SponsorBlock — порт `SponsorBlock.cs`.
 *
 * Спрашиваем по приставке хеша: наружу уходят четыре первых знака SHA-256
 * от номера ролика, а не сам номер, — сервер так и не узнаёт, что именно
 * смотрят. В ответе все ролики с такой приставкой, нужный отбирается
 * у нас.
 */
@interface YTSponsorBlock : NSObject

/**
 * Куски, которые стоит пропустить, по возрастанию времени.
 *
 * Ходит в сеть — зовётся из фона. Пустой массив вместо ошибки: служба
 * посторонняя, и её молчание не повод чему-либо ломаться.
 */
+ (NSArray *)segmentsFor:(NSString *)videoId;

@end
