#import <UIKit/UIKit.h>

/**
 * Шрифты, значки, отступы и мелкие общие виды.
 *
 * Числа перенесены из XAML UWP-версии как есть. Там размеры заданы
 * в эффективных пикселях, а в UIKit — в точках, и это одна и та же единица:
 * пересчитывать по дороге ничего не пришлось. Где число взято, сказано
 * в комментарии у каждого — по имени файла и элемента, чтобы при расхождении
 * было куда посмотреть.
 */

#pragma mark Шрифты

/**
 * Начертания Roboto.
 *
 * В UWP шрифт назначен всему тексту разом стилями в App.xaml, поэтому
 * насыщенность у каждой подписи стоит своя: `FontWeight="Medium"`
 * у названий роликов, `SemiBold` у заголовков, ничего (то есть Regular)
 * у подписей. Здесь то же самое, только начертания отдельными файлами —
 * см. tools/make-fonts.sh.
 *
 * Если шрифт почему-либо не зарегистрировался, вместо него берётся системный
 * той же насыщенности: пустой экран хуже чужого шрифта.
 */
UIFont *YTFontRegular(CGFloat size);
UIFont *YTFontMedium(CGFloat size);
UIFont *YTFontSemiBold(CGFloat size);
UIFont *YTFontBold(CGFloat size);

#pragma mark Значки

/**
 * Значок из набора UWP под текущую тему.
 *
 * Имя — без суффикса набора: `search`, `tab_home`, `pl_pause`. Тёмный или
 * светлый вариант выбирается сам, ровно как это делал `ThemeAsset.Path`
 * в оригинале.
 *
 * Файл под нужную плотность экрана выбирается здесь же, а не через
 * `imageNamed:`. Причина в том, что значки лежат в подкаталоге связки,
 * а разбор суффиксов `@2x`/`@3x` для подкаталогов на iOS 5 и 6 работает
 * не так надёжно, как хотелось бы: проще выбрать файл самим и собрать
 * картинку с явно указанным масштабом, чем выяснять это на устройстве.
 *
 * Результат кешируется: значки одни и те же на всех экранах.
 */
UIImage *YTIcon(NSString *name);

/**
 * Тот же значок, но перекрашенный.
 *
 * Нужен там, где состояние помечается цветом, а второго значка в наборе
 * нет: у лайка есть `pl_like_on`, а у стрелки скачивания — нет. Рисуем
 * исходный как трафарет и заливаем цветом.
 *
 * `tintColor` для этого не годится: он появился в iOS 7, а нижняя
 * граница у нас 5.1.
 */
UIImage *YTTintedImage(UIImage *picture, UIColor *color);

/**
 * Значок **всегда** из тёмного набора, какая бы тема ни стояла.
 *
 * В оригинале это записано прямо в разметке: у пульта плеера и у столбца
 * кнопок Shorts путь зашит как `Assets/Dark/…`, а не выбирается темой.
 * Причина простая — эти значки лежат поверх кадра, а кадр тёмный всегда.
 * Светлый набор на нём попросту не виден.
 */
UIImage *YTDarkIcon(NSString *name);

/** Картинка, одинаковая в обеих темах: заглушки, «нет сети». */
UIImage *YTImage(NSString *name);

/** Сбрасывает кеш значков — при смене темы набор меняется целиком. */
void YTIconCacheDrop(void);

#pragma mark Размеры

/**
 * Высота нижней панели без полосы над ней — `RowDefinition Height="50"`
 * в Tabbar.xaml. Полоса над ней — отдельные 2 точки, `Height="2"`.
 */
extern const CGFloat YTTabBarHeight;
extern const CGFloat YTTabBarDivider;

/** Высота верхней панели — `Height="56"` в Navbar.xaml. */
extern const CGFloat YTNavBarHeight;

/** Полоса «таблеток» категорий — `Height="48"` в Home.xaml. */
extern const CGFloat YTChipsBarHeight;

/** Сама «таблетка»: высота 36, скругление 9, отступы по 14 (Home.xaml). */
extern const CGFloat YTChipHeight;
extern const CGFloat YTChipRadius;
extern const CGFloat YTChipPadding;

/** Отступы ленты карточек — `Padding="8,8,8,16"` в Home.xaml. */
extern const CGFloat YTFeedPadding;

/** Между карточками — `Margin="0,0,0,16"` у шаблона карточки. */
extern const CGFloat YTCardSpacing;

/** Скругление превью — `CornerRadius="8"` у подложки карточки. */
extern const CGFloat YTThumbRadius;

/** Кружок канала в карточке — `Width="36" Height="36"`. */
extern const CGFloat YTCardAvatar;

/**
 * Желаемая ширина карточки. В UWP разбиение по колонкам делает
 * `ItemsWrapGrid ItemWidth="360" MaximumRowsOrColumns="3"`: сколько карточек
 * шириной 360 влезло, столько и колонок, но не больше трёх. Здесь то же
 * число и то же правило — см. YTColumnsForWidth.
 */
extern const CGFloat YTCardWidth;

/** Сколько карточек в ряду при такой ширине списка. */
NSInteger YTColumnsForWidth(CGFloat width);

#pragma mark Текст

/**
 * Высота текста в заданной ширине, но не больше maxLines строк.
 *
 * Считается через `sizeWithFont:constrainedToSize:` — метод устаревший, но
 * единственный, доступный на iOS 5.1: `boundingRectWithSize:` пришёл только
 * с iOS 7 вместе с TextKit.
 *
 * У потолка запас в точку, а наружу высота отдаётся обрезанной ровно
 * до maxLines. Без запаса случалось так: высота двух строк оказывалась
 * на доли точки больше, чем `lineHeight × 2`, в потолок помещалась одна,
 * и подпись, которой разрешено две строки, получала рамку в одну
 * и обрезалась многоточием.
 */
CGFloat YTTextHeight(NSString *text, UIFont *font, CGFloat width, NSInteger maxLines);

/**
 * Обрезает слишком длинный текст, добавляя многоточие.
 *
 * Нужно там, где число строк не ограничено, — в описании ролика
 * и в комментариях. Замер и отрисовка такого текста идут через CoreText,
 * и на A4 это секунды: приложение снималось системой с кодом 0x8badf00d,
 * когда у ролика набралось тридцать три тысячи знаков комментариев.
 */
NSString *YTClampText(NSString *text, NSUInteger limit);

/** Подпись с обрезкой по краю и заданным числом строк. Чинит битый текст. */
UILabel *YTLabel(UIFont *font, UIColor *color, NSInteger lines);

#pragma mark Общие виды

/**
 * Плашка длительности поверх превью.
 *
 * Порт шаблона из Home.xaml: `Background="#CC000000"`, `CornerRadius="4"`,
 * `Padding="6,2"`, подпись 12 точек начертанием Medium, белая.
 */
@interface YTBadgeLabel : UILabel

/** У карточки 6×2, у строки истории — 4×1 (Me.xaml). */
@property (nonatomic, assign) UIEdgeInsets padding;

/** Размер под текущий текст; пустой текст даёт нулевой размер. */
- (CGSize)badgeSize;

@end

/**
 * Прямоугольник со скруглением и заливкой — «таблетка» категории, кнопка
 * «Подписаться», подложка блока комментариев.
 *
 * Своим рисованием, а не `layer.cornerRadius`: тот заставляет систему
 * рисовать слой отдельным проходом, и на iPhone 4 в прокручиваемом списке
 * это заметно.
 */
@interface YTPillView : UIView

@property (nonatomic, strong) UIColor *fillColor;
@property (nonatomic, assign) CGFloat cornerRadius;

@end
