#import <UIKit/UIKit.h>

/**
 * Строка панели настроек плеера.
 *
 * Двух видов, как в оригинале. Раздел — значок 24×24, название 16,
 * значение 14 приглушённым справа и стрелка `skip.png`: он ведёт
 * в список. Пункт списка — столбец 28 под галочку и название, у
 * выбранного полужирное.
 */
@interface YTSheetRow : NSObject

@property (nonatomic, copy) NSString *icon;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *value;
@property (nonatomic, assign) BOOL chevron;
@property (nonatomic, assign) BOOL checkable;
@property (nonatomic, assign) BOOL checked;
@property (nonatomic, copy) dispatch_block_t action;

/** Кружок и вторая строка — только у строки канала. */
@property (nonatomic, copy) NSString *avatar;
@property (nonatomic, copy) NSString *subtitle;

/** Пояснение, а не пункт: не нажимается, текст во столько строк, сколько нужно. */
@property (nonatomic, assign) BOOL isNote;

/** Раздел первой страницы: значок, название, значение, стрелка. */
+ (YTSheetRow *)section:(NSString *)icon
                  title:(NSString *)title
                  value:(NSString *)value
                 action:(dispatch_block_t)action;

/** То же, но без стрелки — как «Перезагрузить видео» в оригинале. */
+ (YTSheetRow *)command:(NSString *)icon
                  title:(NSString *)title
                 action:(dispatch_block_t)action;

/**
 * Строка канала: кружок, имя, подпись под ним и галочка у выбранного.
 *
 * Заведена для списка аккаунтов и повторяет то немногое, что в нём
 * действительно нужно: по чему канал узнают (кружок и имя), чем он
 * отличается от соседа (собачка или пометка «YouTube Детям») и какой
 * из них сейчас выбран.
 */
+ (YTSheetRow *)account:(NSString *)title
               subtitle:(NSString *)subtitle
                 avatar:(NSString *)avatar
                 picked:(BOOL)picked
                 action:(dispatch_block_t)action;

/** Пункт списка с галочкой у выбранного. */
+ (YTSheetRow *)choice:(NSString *)title
                picked:(BOOL)picked
                action:(dispatch_block_t)action;

/**
 * Пояснение под списком.
 *
 * Нужно там, где список чего-то **не** показывает, и человеку неоткуда
 * узнать, почему: у качества это ступени, которые ролик отдаёт только
 * в шестидесяти кадрах.
 */
+ (YTSheetRow *)note:(NSString *)text;

/** Возврат к первой странице. */
+ (YTSheetRow *)back:(dispatch_block_t)action;

@end


/**
 * Всплывающая панель настроек плеера — порт `SettingsBottomSheetPanel`
 * из `Video.xaml` и её близнеца `ShortsSettingsSheet` из `Shorts.xaml`.
 *
 * Числа оттуда же: карточка прижата к низу с полем 10, скругление 15,
 * сверху область захвата 40 с полосой 40×4, содержимое с полями 20,
 * строки высотой 44. Затемнение под ней — `#80000000`, нажатие по нему
 * закрывает панель, как `OverlayGrid`.
 *
 * Своя, а не `UIActionSheet`: тот объявлен устаревшим с iOS 8 и на новых
 * системах ведёт себя непредсказуемо, а `UIAlertController` появился
 * только в iOS 8 — при нижней границе 5.1 пришлось бы держать два пути.
 *
 * Одна на две страницы: у ролика и у Shorts панель в оригинале одна
 * и та же, только на Shorts она всегда тёмная — карточка `#222222`
 * с белыми подписями, потому что лежит поверх кадра.
 */
@interface YTSettingsSheet : UIView

/** `dark` — всегда тёмная, независимо от темы приложения (Shorts). */
- (id)initWithDark:(BOOL)dark;

- (BOOL)isOpen;

/** Показывает панель поверх вида и выводит её снизу. */
- (void)openIn:(UIView *)host;

/** Прячет с обратной привычкой. */
- (void)close;

/**
 * Заполняет содержимое. Заголовок пустой — первая страница: в оригинале
 * у неё заголовка нет, а у списков он есть.
 */
- (void)setTitle:(NSString *)title rows:(NSArray *)rows;

/**
 * Меняет подпись уже показанной строки, не пересобирая панель.
 *
 * Нужно тому, у кого подпись живёт: проценты идущей загрузки меняются
 * дважды в секунду, и пересобирать ради них все строки нельзя — вместе
 * с видами пропадает и палец, лежащий на строке, а с ним и нажатие.
 *
 * Ничего не делает, если такой строки нет или подпись не изменилась.
 */
- (void)retitleRowAt:(NSUInteger)index to:(NSString *)title;

/**
 * То же, но вместо строк — сплошной текст с прокруткой: так в оригинале
 * показано описание канала (`DescriptionBottomSheetPanel` в `Channel.xaml`,
 * заголовок 18 полужирным, текст 14).
 */
- (void)setTitle:(NSString *)title text:(NSString *)text;

/**
 * То же со строкой сведений над текстом.
 *
 * У описания ролика это просмотры и дата — как в оригинале, где над
 * описанием стоит та же строка, что и под названием. Пишется мельче
 * и приглушённым цветом, чтобы читаться сведениями, а не первой строкой
 * описания. Пустая подпись просто не показывается.
 */
- (void)setTitle:(NSString *)title note:(NSString *)note text:(NSString *)text;

@end
