#import "YTSimpleScreens.h"

#import "YTStrings.h"

#import "YTApi.h"
#import "YTAuth.h"
#import "YTImageLoader.h"
#import "YTMetrics.h"
#import "YTRoundedImageView.h"
#import "YTTheme.h"
#import "YTUtil.h"
#import "YTVideoItem.h"

/**
 * Числа — из Notifications.xaml и `CreateNotificationRow`.
 *
 *     шапка      Height="64"; заголовок 26 SemiBold с отступом 24,
 *                лупа 64×64 со значком 28
 *     список     Padding="0,8,0,16"
 *     строка     MinHeight="68", Padding="0,0,16,0", отступ снизу 8;
 *                колонки 10 / 52 / * / 104;
 *                кружок непрочитанного 4 цветом #3A8ADC,
 *                кружок канала 38 с отступом 2 сверху,
 *                текст с отступами 8 слева и 10 справа:
 *                автор 15 SemiBold, сообщение 13 в две строки,
 *                время 12 secondary с отступом 2,
 *                превью 96×54 со скруглением 6
 */
static const CGFloat YTNoteBar = 64;
static const CGFloat YTNoteRow = 68;
static const CGFloat YTNoteAvatarColumn = 52;
static const CGFloat YTNoteAvatar = 38;
static const CGFloat YTNoteThumbColumn = 104;
static const CGFloat YTNoteThumbWidth = 96;
static const CGFloat YTNoteThumbHeight = 54;
static const CGFloat YTNoteGap = 8;


#pragma mark - Строка

@interface YTNotificationRow : YTTappableView

- (void)bindAuthor:(NSString *)author
           message:(NSString *)message
              time:(NSString *)time
            avatar:(NSString *)avatar
         thumbnail:(NSString *)thumbnail
           videoId:(NSString *)videoId;

@end

@implementation YTNotificationRow {
    YTRoundedImageView *_avatar;
    UILabel *_author;
    UILabel *_message;
    UILabel *_time;
    YTRoundedImageView *_thumb;
    NSString *_videoId;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    [self setHighlights:YES];

    _avatar = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];
    [_avatar setCircular:YES];
    [self addSubview:_avatar];

    _author = YTLabel(YTFontSemiBold(15), [YTTheme primaryText], 1);
    [self addSubview:_author];

    _message = YTLabel(YTFontRegular(13), [YTTheme primaryText], 2);
    [self addSubview:_message];

    _time = YTLabel(YTFontRegular(12), [YTTheme secondaryText], 1);
    [self addSubview:_time];

    _thumb = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];
    [_thumb setCornerRadius:6];
    [self addSubview:_thumb];

    __weak YTNotificationRow *weakSelf = self;

    [self setOnTap:^{
        YTNotificationRow *row = weakSelf;

        if (row != nil) {
            [YTNav openVideo:row->_videoId title:[row->_message text]];
        }
    }];

    return self;
}

- (void)bindAuthor:(NSString *)author
           message:(NSString *)message
              time:(NSString *)time
            avatar:(NSString *)avatar
         thumbnail:(NSString *)thumbnail
           videoId:(NSString *)videoId {
    _videoId = [videoId copy];

    [_avatar setPlaceholderColor:[YTTheme avatarPlaceholder]];
    [_thumb setPlaceholderColor:[YTTheme videoPlaceholder]];

    [_author setTextColor:[YTTheme primaryText]];
    [_message setTextColor:[YTTheme primaryText]];
    [_time setTextColor:[YTTheme secondaryText]];

    [_author setText:author];
    [_message setText:message];
    [_time setText:time];

    [YTImageLoader loadInto:_avatar url:avatar targetWidth:YTNoteAvatar];
    [YTImageLoader loadInto:_thumb url:thumbnail targetWidth:YTNoteThumbWidth];

    [self setNeedsLayout];
}

- (void)layoutSubviews {
    CGFloat width = [self bounds].size.width;

    [_avatar setFrame:CGRectMake(10 + (YTNoteAvatarColumn - YTNoteAvatar) / 2, 2,
                                 YTNoteAvatar, YTNoteAvatar)];

    CGFloat left = 10 + YTNoteAvatarColumn + 8;
    CGFloat right = width - 16 - YTNoteThumbColumn;
    CGFloat textWidth = MAX((CGFloat)0, right - left - 10);

    [_author setFrame:CGRectMake(left, 0, textWidth, 20)];
    [_message setFrame:CGRectMake(left, 21, textWidth, 34)];
    [_time setFrame:CGRectMake(left, 57, textWidth, 16)];

    [_thumb setFrame:CGRectMake(width - 16 - YTNoteThumbWidth, 0,
                                YTNoteThumbWidth, YTNoteThumbHeight)];
}

@end


#pragma mark - Экран

@implementation YTNotificationsViewController {
    UIView *_bar;
    UIButton *_back;
    UILabel *_title;
    UIButton *_search;

    UIScrollView *_page;
    NSMutableArray *_rows;

    YTStatusView *_status;
    YTGeneration *_generation;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    if (orientation == UIInterfaceOrientationPortraitUpsideDown) {
        return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad;
    }

    return YES;
}

- (void)loadView {
    YTUseFullScreenLayout(self);

    [super loadView];

    _rows = [NSMutableArray array];
    _generation = [[YTGeneration alloc] init];

    [[self view] setBackgroundColor:[YTTheme background]];

    _bar = [[UIView alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_bar];

    _back = [UIButton buttonWithType:UIButtonTypeCustom];
    [[_back titleLabel] setFont:YTFontRegular(24)];
    [_back setTitle:@"‹" forState:UIControlStateNormal];
    [_back setTitleColor:[YTTheme primaryText] forState:UIControlStateNormal];
    [_back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_back];

    _title = YTLabel(YTFontSemiBold(26), [YTTheme primaryText], 1);
    [_title setText:YTLoc(@"Уведомления")];
    [_bar addSubview:_title];

    _search = [UIButton buttonWithType:UIButtonTypeCustom];
    [_search setImage:YTIcon(@"search") forState:UIControlStateNormal];
    [[_search imageView] setContentMode:UIViewContentModeScaleAspectFit];

    // Кнопка 64×64 со значком 28 — отступ (64−28)/2 = 18 со всех сторон.
    [_search setImageEdgeInsets:UIEdgeInsetsMake(18, 18, 18, 18)];
    [_search addTarget:self action:@selector(openSearch)
      forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_search];

    _page = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_page];

    _status = [[YTStatusView alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_status];

    [self load];
}

- (void)goBack {
    [YTNav pop];
}

- (void)openSearch {
    [YTNav push:[[YTSearchViewController alloc] init]];
}

/**
 * Источник — лента подписок, и это не упрощение, а перенос: в оригинале
 * `GetNotificationsAsync` ходит только туда, о чём там же и написано —
 * `/notification/get_notification_menu` с TV-токеном отвечает 400
 * INVALID_ARGUMENT.
 *
 * Кружки авторов подставляются из списка подписок по имени канала, ровно
 * как в `GetNotificationUploadsFallbackAsync`.
 */
- (void)load {
    if (![YTAuth isSignedIn]) {
        [_status showOffline:YTLoc(@"Войдите в аккаунт")
                        hint:YTLoc(@"Здесь появятся новые ролики каналов, на которые вы подписаны")
                 actionTitle:YTLoc(@"Войти")
                      action:^{
            [YTNav pop];
            [YTNav selectTab:3];
        }];

        return;
    }

    NSInteger generation = [_generation next];

    [_status showBusy];

    YTAsync(^{
        NSDictionary *feed = [YTApi subscriptionsFeed:nil];
        NSArray *channels = [YTApi subscriptions];

        NSMutableDictionary *avatars = [NSMutableDictionary dictionary];

        for (NSDictionary *channel in channels) {
            NSString *name = [channel objectForKey:@"title"];
            NSString *thumbnail = [channel objectForKey:@"thumbnail"];

            if ([name length] > 0 && [thumbnail length] > 0
                && [avatars objectForKey:name] == nil) {
                [avatars setObject:thumbnail forKey:name];
            }
        }

        YTMain(^{
            if (![_generation isCurrent:generation]) {
                return;
            }

            [self show:[feed objectForKey:@"items"] avatars:avatars];
        });
    });
}

- (void)show:(NSArray *)items avatars:(NSDictionary *)avatars {
    for (UIView *row in _rows) {
        [row removeFromSuperview];
    }

    [_rows removeAllObjects];

    for (YTVideoItem *item in items) {
        if ([item isPlaylist]) {
            continue;
        }

        YTNotificationRow *row = [[YTNotificationRow alloc] initWithFrame:CGRectZero];

        NSString *author = [item.channelTitle length] > 0 ? item.channelTitle : @"YouTube";

        NSString *message = [item.title length] > 0
            ? YTLocF(@"Загрузил(а) видео «%@»", item.title)
            : YTLoc(@"Загрузил(а) видео");

        [row bindAuthor:author
                message:message
                   time:YTLoc(@"Из подписок")
                 avatar:[avatars objectForKey:author]
              thumbnail:item.thumbnail
                videoId:item.videoId];

        [_page addSubview:row];
        [_rows addObject:row];
    }

    if ([_rows count] == 0) {
        [_status showMessage:YTLoc(@"Уведомлений нет")];
    } else {
        [_status hide];
    }

    [[self view] setNeedsLayout];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];

    CGRect box = [[self view] bounds];
    CGFloat top = YTStatusBarHeight();

    [_bar setFrame:CGRectMake(0, top, box.size.width, YTNoteBar)];
    [_back setFrame:CGRectMake(4, (YTNoteBar - 40) / 2, 40, 40)];
    [_title setFrame:CGRectMake(48, 0, box.size.width - 48 - YTNoteBar, YTNoteBar)];
    [_search setFrame:CGRectMake(box.size.width - YTNoteBar, 0, YTNoteBar, YTNoteBar)];

    CGFloat contentTop = top + YTNoteBar;

    [_page setFrame:CGRectMake(0, contentTop, box.size.width,
                               box.size.height - contentTop)];
    [_status setFrame:[_page frame]];

    // `Padding="0,8,0,16"` у списка.
    CGFloat y = 8;

    for (YTNotificationRow *row in _rows) {
        [row setFrame:CGRectMake(0, y, box.size.width, YTNoteRow)];

        y += YTNoteRow + YTNoteGap;
    }

    [_page setContentSize:CGSizeMake(box.size.width, y + 16)];
}

@end
