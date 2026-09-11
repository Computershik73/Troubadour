#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

/**
 * Мелкие обёртки над NSJSONSerialization.
 *
 * Смысл тот же, что у `Json.cs` в UWP-версии: ответы InnerTube — это дерево
 * «рендереров» глубиной в десяток уровней, где почти любое поле может
 * отсутствовать, прийти пустым или оказаться другого типа, чем в прошлый раз.
 * Разбор от этого падать не должен: пропавший заголовок стоит пустой строки,
 * а не пустого экрана.
 *
 * Разница с C# одна: там был `JsonObject` с его `GetNamedString(key, fallback)`,
 * здесь — обычный NSDictionary, в котором отсутствующее поле даёт nil,
 * а присланный null даёт NSNull. Обе разновидности пустоты сводятся к nil.
 *
 * Внешней библиотеки нет намеренно: NSJSONSerialization есть в системе
 * с iOS 5.0, то есть ровно с нашей нижней границы.
 */
@interface YTJson : NSObject

/** Разбор тела ответа. Возвращает nil, если это не объект JSON. */
+ (NSDictionary *)parse:(NSData *)data;

/**
 * То же, но каким бы ни был верхний уровень: годится и массив.
 *
 * Нужен для чужих служб. InnerTube всегда начинает ответ объектом, и
 * `parse:` на этом стоит намеренно — чужой тип там означает не тот ответ.
 * А вот SponsorBlock отдаёт массив, и разбор молча возвращал пустоту:
 * запрос уходил, ответ приходил, вставок не находилось никогда.
 */
+ (id)parseAny:(NSData *)data;

/** Обратно в данные — для тел запросов к InnerTube. */
+ (NSData *)encode:(id)object;

+ (NSDictionary *)objectIn:(NSDictionary *)parent key:(NSString *)key;
+ (NSArray *)arrayIn:(NSDictionary *)parent key:(NSString *)key;
+ (NSDictionary *)objectAt:(NSArray *)array index:(NSUInteger)index;

/**
 * Строка, но пустая считается отсутствующей.
 *
 * У InnerTube это встречается постоянно: пустая строка вместо отсутствующего
 * поля — обычный ответ, и без такой проверки запасные варианты («нет автора —
 * возьми из другого места») не срабатывали бы никогда.
 */
+ (NSString *)textIn:(NSDictionary *)parent key:(NSString *)key;

+ (NSString *)stringIn:(NSDictionary *)parent key:(NSString *)key;
+ (NSString *)stringIn:(NSDictionary *)parent key:(NSString *)key
              fallback:(NSString *)fallback;

+ (NSInteger)intIn:(NSDictionary *)parent key:(NSString *)key;
+ (NSInteger)intIn:(NSDictionary *)parent key:(NSString *)key
          fallback:(NSInteger)fallback;

+ (double)doubleIn:(NSDictionary *)parent key:(NSString *)key
          fallback:(double)fallback;

+ (BOOL)boolIn:(NSDictionary *)parent key:(NSString *)key;
+ (BOOL)boolIn:(NSDictionary *)parent key:(NSString *)key fallback:(BOOL)fallback;

/**
 * Текст «рендерера»: `{"simpleText": "…"}` либо `{"runs": [{"text": "…"}, …]}`.
 *
 * Это самая частая форма в ответах InnerTube и одновременно самая
 * коварная: одно и то же поле у разных рендереров приходит то одним видом,
 * то другим — название ролика в `videoRenderer` обычно `runs`, а в
 * `compactVideoRenderer` бывает `simpleText`. Порт `ExtractTextFromField`
 * из VideoAPI.cs, где ровно эти две ветки и разбираются.
 */
+ (NSString *)renderedText:(NSDictionary *)parent key:(NSString *)key;

/** То же, но объект уже сам является текстовым рендерером. */
+ (NSString *)renderedValue:(NSDictionary *)node;

/**
 * Адрес самой крупной картинки из `{"thumbnails": [...]}`.
 *
 * Список приходит от мелкой к крупной, и в UWP-версии брался нулевой
 * элемент — то есть самая мелкая. Для кружка канала в 36 точек это разумно,
 * а для превью карточки давало мыло, поэтому здесь берётся нужная по ширине:
 * первая, что не уже запрошенной, иначе последняя.
 */
+ (NSString *)thumbnailIn:(NSDictionary *)parent key:(NSString *)key minWidth:(CGFloat)width;

/**
 * Обходит дерево и возвращает первый найденный объект с таким ключом.
 *
 * Ответы InnerTube меняют форму от клиента к клиенту и от недели к неделе:
 * тот же список видео лежит то в `richGridRenderer`, то в
 * `sectionListRenderer`, то на два уровня глубже. UWP-версия по этой же
 * причине искала маркеры по всему дереву (`MaxObjectsToScanForVideoCards`),
 * а не ходила по известному пути.
 *
 * Ограничение по числу просмотренных узлов оттуда же и по той же причине:
 * ответ «Главной» — это мегабайты JSON, и полный обход в поисках того, чего
 * там нет, стоит на A4 заметного времени.
 *
 * **Находятся только словари.** Значение под искомым ключом берётся лишь
 * тогда, когда это объект: искать так строку, число или список — значит
 * всегда получать nil, и притом молча. Оба метода задуманы для поиска
 * рендереров, и это не изъян, а их назначение; за строкой есть
 * `findString:in:limit:`.
 *
 * Оговорка не теоретическая: на ней уже потеряно два захода отладки.
 * `createCommentParams` — строка, и поиск её через `findAll:` не мог
 * сработать ни при каком потолке.
 */
+ (NSDictionary *)findFirst:(NSString *)key in:(id)tree limit:(NSUInteger)limit;

/** Все объекты с таким ключом, в порядке обхода. Только словари — см. выше. */
+ (NSArray *)findAll:(NSString *)key in:(id)tree limit:(NSUInteger)limit;

/**
 * Первая **строка** под таким ключом.
 *
 * Пара к `findFirst:`, для случая, когда искомое — не рендерер, а значение:
 * непрозрачная метка, идентификатор, готовый адрес. Пустые строки
 * пропускаются: в ответах они попадаются как заглушки.
 */
+ (NSString *)findString:(NSString *)key in:(id)tree limit:(NSUInteger)limit;

/**
 * То же, но сразу по нескольким именам — за один обход.
 *
 * Нужно там, где имён много: `findAll:` на каждое имя проходит дерево
 * заново, и потолок в узлах каждый раз отсчитывается с нуля, то есть
 * дальше первых `limit` узлов не заглядывает ни один из проходов. На ленте
 * подписок это и вылезало: ответ TV-клиента больше мегабайта, ролики в нём
 * разложены по полке на канал, и все проходы упирались в первую полку —
 * лента показывала ролики одного канала.
 *
 * Возвращает пары: словарь с ключами `name` (имя рендерера) и `node`.
 * Имя нужно разбору — по нему видно, чем считать узел.
 */
+ (NSArray *)findAllOfAny:(NSArray *)keys in:(id)tree limit:(NSUInteger)limit;

@end
