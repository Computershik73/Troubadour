#import <UIKit/UIKit.h>

@class YTVideoItem;

/**
 * Карточка ролика — порт `ItemTemplate` из Home.xaml.
 *
 * Раскладка оттуда же, число в число:
 *
 *     превью        во всю ширину карточки, 16:9, скругление 8,
 *                   подложка AppSurfaceAlt
 *     плашка        снизу справа, отступ 8, поля 6×2, скругление 4,
 *                   фон #CC000000, подпись 12 Medium белая
 *     отступ        12 до строки с автором
 *     кружок        36×36 слева, круглый
 *     отступ        10 до текста
 *     название      14 Medium, AppPrimaryText, одна строка с многоточием
 *     отступ        4
 *     метаданные    12 Regular, AppMutedText, одна строка с многоточием
 *
 * Кружок канала пропадает вместе со своей колонкой, если картинки нет:
 * в оригинале он тоже показывается не всегда, и название в таком случае
 * начинается от края.
 */
@interface YTVideoCard : UIView

/** Высота карточки при такой ширине — нужна списку до создания ячейки. */
+ (CGFloat)heightForWidth:(CGFloat)width item:(YTVideoItem *)item;

/**
 * Скругление превью. В ленте это 8 (`CornerRadius="8"` в Home.xaml),
 * а в списке похожих на странице видео — 0: там у шаблона
 * `CornerRadius="0"`, углы прямые.
 */
@property (nonatomic, assign) CGFloat thumbRadius;

- (void)bind:(YTVideoItem *)item;

@end


/**
 * Ячейка таблицы с одним рядом карточек.
 *
 * Список — `UITableView`, а не `UICollectionView`: последний появился
 * только в iOS 6. Поэтому колонки собираются вручную: один ряд таблицы
 * держит столько карточек, сколько их помещается по ширине
 * (`ItemsWrapGrid` в оригинале делал ровно это).
 */
@interface YTFeedRowCell : UITableViewCell

/** Ставит ряд карточек; лишние прячутся, а не пересоздаются. */
- (void)bindRow:(NSArray *)items width:(CGFloat)width columns:(NSInteger)columns;

@end


/**
 * Ряд карточек-заглушек — порт `SkeletonCardsList` из Home.xaml.
 *
 * В оригинале это картинка `Assets/yt_skeleton/video.png`, растянутая
 * по ширине карточки: серые прямоугольники на месте превью, кружка канала
 * и двух подписей. Показывается, пока лента не пришла, и остаётся, если
 * сервер ответил, но роликов не прислал.
 */
@interface YTSkeletonRowCell : UITableViewCell

/** Высота ряда при такой ширине — пропорция берётся у самой картинки. */
+ (CGFloat)heightForWidth:(CGFloat)width columns:(NSInteger)columns;

- (void)bindColumns:(NSInteger)columns;

@end


/**
 * «Таблетка» категории над лентой — порт `CategoryChipButtonStyle`:
 * высота 36, скругление 9, поля по 14, подпись 14 SemiBold.
 *
 * Выбранная заливается `PrimaryActionBackground` с подписью
 * `PrimaryActionForeground` — в тёмной теме это белая таблетка с чёрным
 * текстом, ровно как на снимке экрана оригинала.
 */
@interface YTChipView : UIView

@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) BOOL selected;
@property (nonatomic, copy) dispatch_block_t onTap;

/** Ширина под текущую подпись. */
- (CGFloat)widthForTitle;

/**
 * Перекрасить под текущую тему.
 *
 * Отдельным методом, а не внутри `setTitle:`, потому что полоса категорий
 * переживает смену темы целиком: таблетки не пересоздаются, и цвет,
 * взятый однажды, так и остался бы прежним.
 */
- (void)applyState;

@end
