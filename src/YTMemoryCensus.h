#import <Foundation/Foundation.h>

/**
 * Перепись памяти: раз в двадцать секунд — строка в журнал, кто сколько держит.
 *
 * Одна цифра «занято N МБ» не говорит, на что ушла память, а на iPad 1
 * именно это и надо было знать: снимало на 51 МБ, и непонятно, чьи это
 * мегабайты. Каждая часть приложения, у которой есть что сказать,
 * подписывается на уведомление и дописывает в `notes` свою строку.
 *
 * Только в отладочной сборке; в готовой нет ни таймера, ни строк.
 */
extern NSString *const YTMemoryCensusNotification;

/** Ключ в userInfo: изменяемый массив строк, куда отвечают подписчики. */
extern NSString *const YTMemoryCensusNotesKey;

/** Завести перепись (зовётся при запуске). */
void YTMemoryCensusStart(void);

/** Перепись прямо сейчас — например, когда открылась страница ролика. */
void YTMemoryCensusNow(NSString *reason);

/**
 * Счётчик наполнения NSCache: сам кеш своей суммы не говорит.
 *
 * Ставится кешу делегатом; вес каждого объекта запоминается при
 * добавлении (`noteObject:cost:`) и вычитается, когда кеш его выбрасывает.
 */
@interface YTCacheTally : NSObject <NSCacheDelegate>

- (void)noteObject:(id)object cost:(NSUInteger)cost;

/** «N шт., X МБ» — для переписи. */
- (NSString *)summary;

@end
