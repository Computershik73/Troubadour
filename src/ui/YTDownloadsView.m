#import "YTSimpleScreens.h"

#import "YTStrings.h"

#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>

#import "YTDownloads.h"
#import "YTSettingsSheet.h"
#import "YTFeedViews.h"
#import "YTMetrics.h"
#import "YTRoundedImageView.h"
#import "YTTheme.h"
#import "YTUtil.h"

/** Размеры полосы — те же, что у истории: полосы стоят рядом. */
static const CGFloat YTDownCard = 160;
static const CGFloat YTDownThumb = 90;

/** Вертикальный список: превью 160×90 с полями 16 и текстом справа. */
static const CGFloat YTDownRowThumb = 160;
static const CGFloat YTDownRowThumbHeight = 90;
static const CGFloat YTDownRowGap = 12;


/**
 * Превью с диска — на своей очереди.
 *
 * Разбор картинки стоит десятков миллисекунд, а карточек на полосе
 * с десяток: делать это на главном потоке значит уронить прокрутку
 * на iPad 2. Очередь одна на всех — читаем с диска по очереди,
 * а не десятью потоками разом.
 */
static void YTLoadLocalThumb(NSString *path, YTRoundedImageView *into,
                             void (^done)(BOOL got)) {
    static dispatch_queue_t queue = NULL;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        queue = dispatch_queue_create("yt.downloads.thumbs", NULL);
    });

    if ([path length] == 0) {
        if (done != nil) { done(NO); }

        return;
    }

    dispatch_async(queue, ^{
        UIImage *picture = [UIImage imageWithContentsOfFile:path];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (picture != nil) {
                [into setImage:picture];
            }

            /**
             * Об исходе сообщаем всегда, и картинки нет — тоже исход.
             *
             * Карточка по нему решает, считать ли превью показанным.
             * Раньше она считала так сразу, до чтения с диска, и если
             * файла ещё не было — а превью приезжает позже записи, —
             * то повтора не случалось уже никогда: карточка помнила,
             * что «показала», и на месте картинки оставался чёрный
             * прямоугольник до перезапуска.
             */
            if (done != nil) { done(picture != nil); }
        });
    });
}


/**
 * Открыть скачанный файл системным проигрывателем.
 *
 * Ради этого файл и качается склеенным MP4: `MPMoviePlayerViewController`
 * играет его сам, без нашего прокси, без демуксера и без сети. Он же
 * и есть тот «системный проигрыватель», о котором речь: с iOS 5 и до
 * нынешних он открывает обычный MP4 одинаково.
 */
/**
 * Показанный проигрыватель держим у себя.
 *
 * `presentMoviePlayerViewControllerAnimated:` берёт контроллер на себя,
 * но ссылку рядом держать всё равно надёжнее: без неё ARC вправе снять
 * его в тот же миг, если представление почему-то не состоялось.
 */
static MPMoviePlayerViewController *YTShownPlayer = nil;

/**
 * Слушатель проигрывателя — он один знает, почему закрылся.
 *
 * `MPMoviePlayerViewController` при негодном файле не жалуется на экране:
 * открывается и сразу уходит. Причину он при этом **сообщает** — в
 * `MPMoviePlayerPlaybackDidFinishNotification` лежит и повод, и ошибка.
 * Без этого отличить «не разобрал контейнер» от «нечем декодировать»
 * или «не нашёл дорожек» нельзя, а лечатся они по-разному.
 */
@interface YTPlaybackWatch : NSObject
@end

@implementation YTPlaybackWatch

+ (YTPlaybackWatch *)shared {
    static YTPlaybackWatch *one = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{ one = [[YTPlaybackWatch alloc] init]; });

    return one;
}

- (void)watch:(MPMoviePlayerController *)player {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    [center removeObserver:self];

    [center addObserver:self selector:@selector(finished:)
                   name:MPMoviePlayerPlaybackDidFinishNotification
                 object:player];

    [center addObserver:self selector:@selector(loadState:)
                   name:MPMoviePlayerLoadStateDidChangeNotification
                 object:player];
}

- (void)loadState:(NSNotification *)note {
    MPMoviePlayerController *player = [note object];

    NSLog(@"[YouTube/Скачано] Проигрыватель: готовность %ld, длительность %.1f с",
          (long)[player loadState], [player duration]);
}

- (void)finished:(NSNotification *)note {
    NSDictionary *about = [note userInfo];

    NSInteger reason = [[about objectForKey:
        MPMoviePlayerPlaybackDidFinishReasonUserInfoKey] integerValue];

    NSError *trouble = [about objectForKey:@"error"];

    NSString *why = @"неизвестно";

    if (reason == MPMovieFinishReasonPlaybackEnded)      { why = @"доиграл"; }
    if (reason == MPMovieFinishReasonUserExited)         { why = @"закрыли"; }
    if (reason == MPMovieFinishReasonPlaybackError)      { why = @"ошибка"; }

    NSLog(@"[YouTube/Скачано] Проигрыватель кончил: %@ (%ld)%@", why, (long)reason,
          trouble != nil
              ? [NSString stringWithFormat:@" — %@ / %@ %ld",
                 [trouble localizedDescription], [trouble domain], (long)[trouble code]]
              : @"");
}

@end

static void YTPlayLocal(UIViewController *from, NSString *path) {
    NSDictionary *about = [[NSFileManager defaultManager]
        attributesOfItemAtPath:path error:NULL];

    if (about == nil) {
        NSLog(@"[YouTube/Скачано] Открывать нечего: %@ нет", [path lastPathComponent]);

        return;
    }

    if (from == nil) {
        NSLog(@"[YouTube/Скачано] Открывать негде — экрана нет");

        return;
    }

    /**
     * Показываем от того, кто наверху, а не от навигации.
     *
     * Если поверх навигации уже что-то показано — свернувшийся плеер,
     * панель, — то модальное окно от неё не появится вовсе: система
     * требует показывать от самого верхнего.
     */
    UIViewController *top = from;

    while ([top presentedViewController] != nil) {
        top = [top presentedViewController];
    }

    NSURL *url = [NSURL fileURLWithPath:path];

    YTShownPlayer = [[MPMoviePlayerViewController alloc] initWithContentURL:url];

    NSLog(@"[YouTube/Скачано] Открываем %@ (%@) в %@",
          [path lastPathComponent],
          [YTDownloads sizeText:(long long)[about fileSize]],
          NSStringFromClass([top class]));

    [[YTPlaybackWatch shared] watch:[YTShownPlayer moviePlayer]];

    [top presentMoviePlayerViewControllerAnimated:YTShownPlayer];
}

/** Панель выбора качества — одна на весь раздел, зачем плодить. */
static YTSettingsSheet *YTQualitySheet = nil;

/**
 * Открыть скачанный ролик, спросив о качестве, если их несколько.
 *
 * Один и тот же ролик держат скачанным по-разному, и решать за человека,
 * какое из качеств он хотел посмотреть, не стоит: 1080p дома и 360p
 * в дороге — разные намерения. Качество одно — спрашивать не о чем,
 * открываем сразу.
 *
 * Битые записи сюда не доходят: их выбрасывает `YTDownloads` при чтении
 * перечня. Но файл мог испортиться и после — проверяем перед открытием
 * и убираем, а не показываем чёрный экран.
 */
static void YTOpenDownload(NSString *videoId) {
    UIViewController *host = [YTNav controller];

    if (host == nil || [videoId length] == 0) {
        return;
    }

    NSArray *have = [YTDownloads itemsFor:videoId];

    NSMutableArray *good = [NSMutableArray array];

    for (YTDownloadItem *one in have) {
        if (one.complete && ![YTDownloads looksWhole:[one filePath]]) {
            NSLog(@"[YouTube/Скачано] %@ (%ldp) испортился — убираем",
                  videoId, (long)one.height);

            [YTDownloads remove:videoId height:one.height];

            continue;
        }

        [good addObject:one];
    }

    if ([good count] == 0) {
        return;
    }

    if ([good count] == 1) {
        YTPlayLocal(host, [[good objectAtIndex:0] filePath]);

        return;
    }

    NSMutableArray *rows = [NSMutableArray array];

    for (YTDownloadItem *one in good) {
        NSString *title = [YTDownloads titleForHeight:one.height];

        // Объём рядом с качеством: по нему и выбирают, когда место
        // на устройстве на исходе.
        title = [title stringByAppendingFormat:@"  ·  %@",
                 [YTDownloads sizeText:one.gotBytes]];

        if (!one.complete) {
            title = [title stringByAppendingFormat:@"  (%.0f%%)",
                     [one progress] * 100];
        }

        NSString *path = [one filePath];

        [rows addObject:[YTSheetRow choice:title picked:NO action:^{
            [YTQualitySheet close];

            /**
             * Проигрыватель — **после** того, как панель уедет.
             *
             * Показывать модальное окно поверх уходящей анимации нельзя:
             * система откладывает показ и чаще всего теряет его совсем.
             * Со стороны это выглядит так, будто нажатие не сработало.
             */
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                YTPlayLocal(host, path);
            });
        }]];
    }

    if (YTQualitySheet == nil) {
        YTQualitySheet = [[YTSettingsSheet alloc] initWithDark:NO];
    }

    [YTQualitySheet setTitle:YTLoc(@"В каком качестве смотреть") rows:rows];
    [YTQualitySheet openIn:[host view]];
}


#pragma mark - Карточка полосы

@implementation YTDownloadTile {
    YTRoundedImageView *_thumb;
    YTPillView *_badgePill;
    UILabel *_badge;
    UILabel *_title;
    UILabel *_subtitle;

    NSString *_videoId;
    NSString *_path;

    /** Легла ли уже картинка — своего вопроса вид не отвечает. */
    BOOL _thumbShown;
}

+ (CGFloat)cardWidth  { return YTDownCard; }
+ (CGFloat)cardHeight { return YTDownThumb + 57; }

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    [self setHighlights:NO];

    _thumb = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];
    [_thumb setCornerRadius:YTThumbRadius];
    [self addSubview:_thumb];

    _badgePill = [[YTPillView alloc] initWithFrame:CGRectZero];
    [_badgePill setCornerRadius:4];
    [self addSubview:_badgePill];

    _badge = YTLabel(YTFontSemiBold(10), [UIColor whiteColor], 1);
    [_badge setTextAlignment:NSTextAlignmentCenter];
    [self addSubview:_badge];

    _title = YTLabel(YTFontRegular(13), [YTTheme primaryText], 2);
    [self addSubview:_title];

    _subtitle = YTLabel(YTFontRegular(11), [YTTheme secondaryText], 1);
    [self addSubview:_subtitle];

    __weak YTDownloadTile *weakSelf = self;

    [self setOnTap:^{
        YTDownloadTile *tile = weakSelf;

        if (tile == nil) {
            return;
        }

        [tile play];
    }];

    return self;
}

/**
 * Нажатие: доигранное открываем, недокачанное — тоже.
 *
 * Недокачанный MP4 воспроизводится с начала и обрывается там, где
 * кончился файл: заголовок у прогрессивного потока лежит спереди,
 * и проигрыватель понимает такой обрубок. Запрещать открытие незачем —
 * посмотреть скачанную половину лучше, чем ничего.
 */
- (void)play {
    YTOpenDownload(_videoId);
}

- (void)applyTheme {
    [_thumb setPlaceholderColor:[YTTheme surfaceAlt]];
    [_title setTextColor:[YTTheme primaryText]];
    [_subtitle setTextColor:[YTTheme secondaryText]];
    [_badgePill setFillColor:[UIColor colorWithWhite:0 alpha:0.82]];
}

- (void)bind:(YTDownloadItem *)item {
    [self applyTheme];

    // Кого показывали до сих пор — по нему решается, перечитывать ли превью.
    NSString *was = _videoId;

    _videoId = [item.videoId copy];
    _path = [[item filePath] copy];

    [_title setText:item.title];

    /**
     * Вторая строка: автор, а у недокачанного — доля вместо автора.
     *
     * Место одно, и важнее здесь то, что ролик неполон: имя канала
     * человек и так видит по названию, а вот что файл обрезан — нет.
     */
    if (!item.complete) {
        [_subtitle setText:YTLocF(@"Скачано %.0f%%", [item progress] * 100)];
    } else {
        [_subtitle setText:item.channelTitle];
    }

    [_badge setText:item.duration];

    BOOL hasDuration = [item.duration length] > 0;

    [_badge setHidden:!hasDuration];
    [_badgePill setHidden:!hasDuration];

    /**
     * Превью перечитывается **только при смене ролика**.
     *
     * Карточка перепривязывается дважды в секунду, пока идёт загрузка, —
     * это двигаются проценты. Прежде на каждой перепривязке картинка
     * сбрасывалась в пустоту и читалась с диска заново, и полоса
     * мерцала всё время загрузки. Ролик при этом тот же самый, и
     * картинка у него та же.
     */
    if (![was isEqualToString:_videoId] || !_thumbShown) {
        [_thumb setImage:nil];

        __weak YTDownloadTile *weakSelf = self;

        YTLoadLocalThumb([item thumbnailPath], _thumb, ^(BOOL got) {
            YTDownloadTile *tile = weakSelf;

            if (tile != nil) { tile->_thumbShown = got; }
        });
    }

    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat width = [self bounds].size.width;

    [_thumb setFrame:CGRectMake(0, 0, width, YTDownThumb)];

    CGSize badge = [[_badge text] sizeWithFont:[_badge font]];

    CGFloat badgeWidth = ceil(badge.width) + 8;

    [_badgePill setFrame:CGRectMake(width - badgeWidth - 4,
                                    YTDownThumb - 16 - 4, badgeWidth, 16)];
    [_badge setFrame:[_badgePill frame]];

    CGFloat y = YTDownThumb + 6;

    CGFloat titleHeight = ceil([[_title font] lineHeight]) * 2;

    [_title setFrame:CGRectMake(0, y, width, titleHeight)];

    y += titleHeight + 3;

    [_subtitle setFrame:CGRectMake(0, y, width, ceil([[_subtitle font] lineHeight]))];
}

@end


#pragma mark - Строка вертикального списка

@interface YTDownloadRow : YTTappableView

- (void)bind:(YTDownloadItem *)item;
- (void)applyTheme;

+ (CGFloat)heightForWidth:(CGFloat)width;

@end

@implementation YTDownloadRow {
    YTRoundedImageView *_thumb;
    UILabel *_title;
    UILabel *_subtitle;
    UILabel *_size;

    /** Полоска доли под превью — только у недокачанных. */
    UIView *_barBack;
    UIView *_barFill;

    float _progress;
    BOOL _partial;

    NSString *_path;

    /** Кого показываем — по нему решается, перечитывать ли превью. */
    NSString *_videoId;
    BOOL _thumbShown;
}

+ (CGFloat)heightForWidth:(CGFloat)width {
    return YTDownRowThumbHeight + 24;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    [self setHighlights:YES];

    _thumb = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];
    [_thumb setCornerRadius:YTThumbRadius];
    [self addSubview:_thumb];

    _barBack = [[UIView alloc] initWithFrame:CGRectZero];
    [self addSubview:_barBack];

    _barFill = [[UIView alloc] initWithFrame:CGRectZero];
    [self addSubview:_barFill];

    _title = YTLabel(YTFontRegular(14), [YTTheme primaryText], 2);
    [self addSubview:_title];

    _subtitle = YTLabel(YTFontRegular(12), [YTTheme secondaryText], 1);
    [self addSubview:_subtitle];

    _size = YTLabel(YTFontRegular(12), [YTTheme mutedText], 1);
    [self addSubview:_size];

    __weak YTDownloadRow *weakSelf = self;

    [self setOnTap:^{
        YTDownloadRow *row = weakSelf;

        if (row == nil) {
            return;
        }

        // Строка стоит за ролик целиком — качество спросим, если их несколько.
        YTOpenDownload(row->_videoId);
    }];

    return self;
}

- (void)applyTheme {
    [_thumb setPlaceholderColor:[YTTheme surfaceAlt]];
    [_title setTextColor:[YTTheme primaryText]];
    [_subtitle setTextColor:[YTTheme secondaryText]];
    [_size setTextColor:[YTTheme mutedText]];

    [_barBack setBackgroundColor:[YTTheme surface]];
    [_barFill setBackgroundColor:[YTTheme brandRed]];
}

- (void)bind:(YTDownloadItem *)item {
    [self applyTheme];

    NSString *was = _videoId;

    _videoId = [item.videoId copy];
    _path = [[item filePath] copy];
    _progress = [item progress];
    _partial = !item.complete;

    [_title setText:item.title];

    /**
     * Обычные сведения о ролике — те же, что на карточке в ленте:
     * автор, просмотры, давность. Всё это лежит рядом с файлом,
     * поэтому строка собирается и без сети.
     */
    NSMutableArray *parts = [NSMutableArray array];

    if ([item.channelTitle length] > 0) { [parts addObject:item.channelTitle]; }
    if ([item.viewCount length] > 0)    { [parts addObject:item.viewCount]; }
    if ([item.published length] > 0)    { [parts addObject:item.published]; }

    /**
     * Качества — все, какие скачаны, через запятую.
     *
     * Иначе строка не отличима от соседней у того же ролика, а теперь
     * строка одна, и сказать, что за ней стоит, больше негде.
     */
    NSMutableArray *marks = [NSMutableArray array];

    for (YTDownloadItem *one in [YTDownloads itemsFor:item.videoId]) {
        [marks addObject:[YTDownloads titleForHeight:one.height]];
    }

    if ([marks count] > 0) {
        [parts addObject:[marks componentsJoinedByString:@", "]];
    }

    [_subtitle setText:[parts componentsJoinedByString:@" • "]];

    /**
     * Объём — всегда, доля — только у недокачанных.
     *
     * У целого файла проценты не нужны: он целый, и сотня рядом с ним
     * только сорит. У обрезанного важно и то и другое: сколько уже
     * лежит на диске и какая это часть ролика.
     */
    /**
     * Объём — по всем качествам ролика, а не по одному.
     *
     * Строка стоит за весь ролик, и место на устройстве он занимает
     * всеми своими качествами разом. Показывать долю от одного было бы
     * враньём в меньшую сторону.
     */
    NSString *size = [YTDownloads sizeText:[YTDownloads bytesFor:item.videoId]];

    /**
     * Сборка — состояние само по себе, и проценты в нём не про загрузку.
     *
     * Дорожки уже скачаны, идёт перекладывание в один файл: показывать
     * в этот миг долю скачанного значило бы врать, будто что-то ещё едет.
     */
    if (item.muxing) {
        [_size setText:YTLoc(@"Собираем файл…")];
    } else if (_partial) {
        [_size setText:YTLocF(@"%@ • %.0f%% из %@", size, _progress * 100,
                              [YTDownloads sizeText:item.totalBytes])];
    } else {
        [_size setText:size];
    }

    [_barBack setHidden:!_partial];
    [_barFill setHidden:!_partial];

    // Тот же ролик — та же картинка: перечитывать её значит мигать
    // на каждом обновлении процентов, а они идут дважды в секунду.
    if (![was isEqualToString:_videoId] || !_thumbShown) {
        [_thumb setImage:nil];

        __weak YTDownloadRow *weakSelf = self;

        YTLoadLocalThumb([item thumbnailPath], _thumb, ^(BOOL got) {
            YTDownloadRow *row = weakSelf;

            if (row != nil) { row->_thumbShown = got; }
        });
    }

    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat width = [self bounds].size.width;

    CGFloat left = 16;
    CGFloat top = 12;

    [_thumb setFrame:CGRectMake(left, top, YTDownRowThumb, YTDownRowThumbHeight)];

    // Полоска доли — по нижнему краю превью, как у YouTube.
    CGFloat barY = top + YTDownRowThumbHeight - 3;

    [_barBack setFrame:CGRectMake(left, barY, YTDownRowThumb, 3)];
    [_barFill setFrame:CGRectMake(left, barY, YTDownRowThumb * _progress, 3)];

    CGFloat textLeft = left + YTDownRowThumb + YTDownRowGap;
    CGFloat textWidth = width - textLeft - 16;

    CGFloat titleHeight = ceil([[_title font] lineHeight]) * 2;
    CGFloat lineHeight = ceil([[_subtitle font] lineHeight]);

    [_title setFrame:CGRectMake(textLeft, top, textWidth, titleHeight)];

    CGFloat y = top + titleHeight + 4;

    [_subtitle setFrame:CGRectMake(textLeft, y, textWidth, lineHeight)];

    y += lineHeight + 3;

    [_size setFrame:CGRectMake(textLeft, y, textWidth, lineHeight)];
}

@end


#pragma mark - Экран

@interface YTDownloadsViewController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation YTDownloadsViewController {
    UIView *_bar;
    UIButton *_back;
    UILabel *_heading;
    UITableView *_table;
    YTStatusView *_status;

    NSArray *_items;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return YES;
}

- (void)loadView {
    YTUseFullScreenLayout(self);

    [self setView:[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]]];

    [[self view] setBackgroundColor:[YTTheme background]];

    _bar = [[UIView alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_bar];

    _back = [UIButton buttonWithType:UIButtonTypeCustom];

    [[_back titleLabel] setFont:YTFontRegular(24)];
    [_back setTitle:@"‹" forState:UIControlStateNormal];
    [_back setTitleColor:[YTTheme primaryText] forState:UIControlStateNormal];
    [_back addTarget:self action:@selector(goBack)
    forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_back];

    _heading = YTLabel(YTFontSemiBold(18), [YTTheme primaryText], 1);
    [_heading setText:YTLoc(@"Скачанные")];
    [_bar addSubview:_heading];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];

    [_table setDataSource:self];
    [_table setDelegate:self];
    [_table setSeparatorStyle:UITableViewCellSeparatorStyleNone];
    [_table setBackgroundColor:[YTTheme background]];
    [_table setBackgroundView:nil];
    [[self view] addSubview:_table];

    _status = [[YTStatusView alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_status];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reload)
                                                 name:YTDownloadsChangedNotification
                                               object:nil];

    [self reload];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)goBack {
    [YTNav pop];
}

- (void)reload {
    // По одной строке на ролик: качества — не разные ролики.
    _items = [YTDownloads videos];

    if ([_items count] == 0) {
        [_status showMessage:YTLoc(@"Ничего не скачано")];
    } else {
        [_status hide];
    }

    [_table reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[_items count];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path {
    return [YTDownloadRow heightForWidth:[tableView bounds].size.width];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)path {
    static NSString *identifier = @"down";

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];

    YTDownloadRow *row = nil;

    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:identifier];

        [cell setSelectionStyle:UITableViewCellSelectionStyleNone];
        [cell setBackgroundColor:[UIColor clearColor]];

        row = [[YTDownloadRow alloc] initWithFrame:CGRectZero];

        [row setTag:717];
        [[cell contentView] addSubview:row];
    } else {
        row = (YTDownloadRow *)[[cell contentView] viewWithTag:717];
    }

    [row setFrame:[[cell contentView] bounds]];
    [row setAutoresizingMask:UIViewAutoresizingFlexibleWidth |
                             UIViewAutoresizingFlexibleHeight];

    NSUInteger index = (NSUInteger)[path row];

    if (index < [_items count]) {
        [row bind:[_items objectAtIndex:index]];
    }

    return cell;
}

/**
 * Смахнуть строку — убрать ролик вместе с файлом.
 *
 * Иначе скачанное копилось бы навсегда: своей страницы у ролика здесь
 * нет, а на страницу видео за этим ходить далеко.
 */
- (BOOL)tableView:(UITableView *)tableView
        canEditRowAtIndexPath:(NSIndexPath *)path {
    return YES;
}

- (void)tableView:(UITableView *)tableView
        commitEditingStyle:(UITableViewCellEditingStyle)style
         forRowAtIndexPath:(NSIndexPath *)path {
    if (style != UITableViewCellEditingStyleDelete) {
        return;
    }

    NSUInteger index = (NSUInteger)[path row];

    if (index >= [_items count]) {
        return;
    }

    YTDownloadItem *item = [_items objectAtIndex:index];

    [YTDownloads remove:item.videoId height:item.height];
}

- (void)viewWillLayoutSubviews {
    CGRect box = [[self view] bounds];

    CGFloat top = YTStatusBarHeight();
    CGFloat barHeight = 44;

    [_bar setFrame:CGRectMake(0, top, box.size.width, barHeight)];
    [_back setFrame:CGRectMake(4, 0, 40, barHeight)];
    [_heading setFrame:CGRectMake(48, 0, box.size.width - 64, barHeight)];

    CGRect rest = CGRectMake(0, top + barHeight, box.size.width,
                             box.size.height - top - barHeight);

    [_table setFrame:rest];
    [_status setFrame:rest];

    [[self view] setBackgroundColor:[YTTheme background]];
    [_table setBackgroundColor:[YTTheme background]];
    [_heading setTextColor:[YTTheme primaryText]];
    [_back setTitleColor:[YTTheme primaryText] forState:UIControlStateNormal];
}

@end
