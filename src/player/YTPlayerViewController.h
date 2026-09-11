#import <UIKit/UIKit.h>

/**
 * Страница ролика — порт Video.xaml вместе с CustomVideoPlayer.
 *
 * Сверху кадр 16:9 со своим пультом, под ним название, строка канала
 * с кнопкой подписки, ряд кнопок (оценка, «Поделиться») и комментарии.
 *
 * Пульт свой, а не штатный. `MPMoviePlayerController` даёт готовый, но
 * не пускает внутрь себя и на современных iOS уже не работает — а срез
 * arm64 мы собираем именно для них. Поэтому всё нарисовано: кнопка
 * воспроизведения, полоса, время, разворот, шестерёнка настроек.
 */
@interface YTPlayerViewController : UIViewController

- (id)initWithVideoId:(NSString *)videoId title:(NSString *)title;

/** Ролик, открытый из подборки: её список показывается очередью. */
- (id)initWithVideoId:(NSString *)videoId
                title:(NSString *)title
             playlist:(NSString *)playlistId;

@end
