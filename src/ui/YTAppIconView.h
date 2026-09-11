#import <UIKit/UIKit.h>

/**
 * Экран «Значок приложения».
 *
 * Здесь человек выбирает тему для Anemone (обычный zip), из неё берётся
 * значок YouTube, и здесь же задаётся подпись под ним. Работу делает
 * `YTAppIcon`; экран только показывает, что получится, и говорит,
 * чем всё кончилось.
 */
@interface YTAppIconViewController : UIViewController
@end

/** Список найденных тем — открывается кнопкой с этого экрана. */
@interface YTThemePickerViewController : UIViewController

- (id)initWithChoice:(void (^)(NSString *archive))choice;

@end
