#import <UIKit/UIKit.h>

/** Шлётся при смене темы — открытые экраны перекрашиваются. */
extern NSString *const YTThemeChangedNotification;

extern NSString *const YTThemeSystem;
extern NSString *const YTThemeLight;
extern NSString *const YTThemeDark;

/**
 * Светлая и тёмная темы плюс вся палитра.
 *
 * Значения перенесены из `App.xaml` версии для UWP один в один, вместе
 * с именами: там они лежат в двух `ResourceDictionary` — `Dark` и `Light`, —
 * и здесь получаются двумя ветками одного метода. Числа не пересчитывались:
 * в XAML цвета заданы в #RRGGBB, а размеры — в эффективных пикселях, что
 * для UIKit означает те же самые точки.
 *
 * Устройство переключателя от UWP отличается. Там тему подставляла сама
 * система: `ThemeResource` разрешается на лету, и при смене `RequestedTheme`
 * все кисти перечитываются. В UIKit ресурсных словарей нет, поэтому цвет
 * спрашивается у этого класса в момент отрисовки, а при смене темы экраны
 * перекрашиваются по уведомлению.
 *
 * Отсюда же правило, которое стоит держать в голове по всему проекту:
 * **всё, что зависит от темы, назначается там же, где данные** — в `bind`
 * ячейки, а не в её конструкторе. Ячейки живут в пуле переработки и смену
 * темы переживают: `reloadData` их не пересоздаёт, а перепривязывает, и
 * взятый однажды цвет так и остался бы прежним.
 *
 * «Как в системе» на iOS до 13 всегда означает тёмную: системного ночного
 * режима там нет, а YouTube по умолчанию тёмный — в UWP-версии стоит
 * ровно то же.
 */
@interface YTTheme : NSObject

+ (NSString *)mode;
+ (void)setMode:(NSString *)mode;
+ (NSString *)titleForMode:(NSString *)mode;

/** Тёмная ли тема сейчас — с учётом выбора пользователя и системы. */
+ (BOOL)isDark;

#pragma mark Фирменные цвета

/** Красный значка YouTube. В темноте не меняется: по нему приложение узнаётся. */
+ (UIColor *)brandRed;

/**
 * Голубой ссылок и кнопки «Повторить» — `#3EA6FF` из `Home.xaml`.
 * Тоже одинаковый в обеих темах: в оригинале он записан числом, а не кистью.
 */
+ (UIColor *)accentBlue;

#pragma mark Палитра App.xaml

/** `AppBackgroundColor` — фон страницы. */
+ (UIColor *)background;

/** `AppSurfaceColor` — подложка «таблеток» категорий и кнопок под роликом. */
+ (UIColor *)surface;

/** `AppSurfaceAltColor` — место превью и карточка комментариев. */
+ (UIColor *)surfaceAlt;

/** `AppSurfaceHoverColor` — нажатое состояние. */
+ (UIColor *)surfaceHover;

/** `AppPrimaryTextColor` — название ролика, заголовки. */
+ (UIColor *)primaryText;

/** `AppSecondaryTextColor` — подписи, число подписчиков. */
+ (UIColor *)secondaryText;

/** `AppMutedTextColor` — строка «автор • просмотры • давность» под названием. */
+ (UIColor *)mutedText;

/** `AppDividerColor` — разделители и полоса над нижней панелью. */
+ (UIColor *)divider;

/** `VideoPlaceholderColor` — фон кадра плеера. */
+ (UIColor *)videoPlaceholder;

/** `AvatarPlaceholderColor` — кружок канала, пока картинка не пришла. */
+ (UIColor *)avatarPlaceholder;

/** `LoadingRingColor` — кольцо ожидания. */
+ (UIColor *)loadingRing;

/**
 * `PrimaryActionBackgroundColor` / `PrimaryActionForegroundColor` — заливка
 * главных кнопок («Подписаться», выбранная «таблетка») и цвет подписи на них.
 * Отдельно от primaryText: в тёмной теме основной текст белый, и белая
 * подпись на белой заливке пропала бы.
 */
+ (UIColor *)primaryActionBackground;
+ (UIColor *)primaryActionForeground;

/**
 * Плашка длительности поверх превью — `#CC000000` из шаблона карточки.
 * Она одинакова в обеих темах: лежит поверх кадра, а не поверх страницы.
 */
+ (UIColor *)badge;

/** Стиль строки состояния под текущую тему. */
/**
 * Цвет подписей на верхней и нижней полосе.
 *
 * Обычно это тот же основной текст. Но у объёмного оформления полоса
 * своя — тёмная в обеих темах, такой она и была в ту пору, — и чёрная
 * подпись на ней пропадает. Поэтому цвет спрашивается отдельно, а не
 * берётся у текста страницы.
 */
+ (UIColor *)barText;

/**
 * Цвет подписей на карточке.
 *
 * Обычно это тот же основной текст. Но у объёмного оформления ячейка
 * светлая в обеих темах — так было в ту пору, тёмный хром и светлые
 * списки, — и белая подпись на ней пропала бы.
 */
+ (UIColor *)cardText;
+ (UIColor *)cardSecondaryText;

+ (UIStatusBarStyle)statusBarStyle;

@end

/** #RRGGBB или #AARRGGBB — как в XAML. */
UIColor *YTColor(uint32_t argb);
