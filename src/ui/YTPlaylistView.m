#import "YTSimpleScreens.h"

#import "YTStrings.h"

#import <QuartzCore/QuartzCore.h>

#import "YTApi.h"
#import "YTFeedViews.h"
#import "YTImageLoader.h"
#import "YTMetrics.h"
#import "YTRoundedImageView.h"
#import "YTSkin.h"
#import "YTTheme.h"
#import "YTUtil.h"
#import "YTVideoItem.h"

/**
 * Числа — из Playlist.xaml.
 *
 *     содержимое  Padding="0,8,0,24"
 *     обложка     Height="185", CornerRadius="12", Margin="16,0,16,0"
 *     сведения    Margin="16,14,16,14";
 *                 название 30, автор 16 с кружком 30 и отступом 8 сверху,
 *                 счётчик 15 с отступом 6, описание 15 с отступом 12
 */
static const CGFloat YTPlSide = 16;
static const CGFloat YTPlCover = 185;


#pragma mark - Шапка

@interface YTPlaylistHeader : UIView

- (void)bind:(NSDictionary *)playlist;
- (CGFloat)heightForWidth:(CGFloat)width;
- (void)applyTheme;

@end

@implementation YTPlaylistHeader {
    YTRoundedImageView *_cover;
    UILabel *_title;
    UILabel *_owner;
    UILabel *_meta;

    BOOL _hasCover;
    CGFloat _titleHeight;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    _cover = [[YTRoundedImageView alloc] initWithFrame:CGRectZero];
    [_cover setCornerRadius:12];
    [self addSubview:_cover];

    _title = YTLabel(YTFontSemiBold(30), [YTTheme primaryText], 3);
    [self addSubview:_title];

    _owner = YTLabel(YTFontRegular(16), [YTTheme primaryText], 1);
    [self addSubview:_owner];

    _meta = YTLabel(YTFontRegular(15), [YTTheme secondaryText], 1);
    [self addSubview:_meta];

    return self;
}

- (void)bind:(NSDictionary *)playlist {
    NSString *cover = [playlist objectForKey:@"thumbnail"];

    _hasCover = [cover length] > 0;

    [_cover setHidden:!_hasCover];

    if (_hasCover) {
        [YTImageLoader loadInto:_cover url:cover targetWidth:[self bounds].size.width];
    }

    [_title setText:[playlist objectForKey:@"title"]];
    [_owner setText:[playlist objectForKey:@"channelTitle"]];
    [_meta setText:[playlist objectForKey:@"subtitle"]];

    [self applyTheme];
    [self setNeedsLayout];
}

- (void)applyTheme {
    [_cover setPlaceholderColor:[YTTheme surfaceAlt]];

    [_title setTextColor:[YTTheme primaryText]];
    [_owner setTextColor:[YTTheme primaryText]];
    [_meta setTextColor:[YTTheme secondaryText]];
}

- (CGFloat)heightForWidth:(CGFloat)width {
    CGFloat y = 8;

    if (_hasCover) {
        y += YTPlCover;
    }

    y += 14;

    _titleHeight = YTTextHeight([_title text], [_title font],
                                width - YTPlSide * 2, 3);

    y += _titleHeight;

    if ([[_owner text] length] > 0) { y += 8 + 20; }
    if ([[_meta text] length] > 0)  { y += 6 + 20; }

    return y + 14;
}

- (void)layoutSubviews {
    CGFloat width = [self bounds].size.width;
    CGFloat y = 8;

    if (_hasCover) {
        [_cover setFrame:CGRectMake(YTPlSide, y, width - YTPlSide * 2, YTPlCover)];

        y += YTPlCover;
    } else {
        [_cover setFrame:CGRectZero];
    }

    y += 14;

    CGFloat textWidth = width - YTPlSide * 2;

    [_title setFrame:CGRectMake(YTPlSide, y, textWidth, _titleHeight)];

    y += _titleHeight;

    if ([[_owner text] length] > 0) {
        [_owner setFrame:CGRectMake(YTPlSide, y + 8, textWidth, 20)];

        y += 8 + 20;
    } else {
        [_owner setFrame:CGRectZero];
    }

    if ([[_meta text] length] > 0) {
        [_meta setFrame:CGRectMake(YTPlSide, y + 6, textWidth, 20)];
    } else {
        [_meta setFrame:CGRectZero];
    }
}

@end


#pragma mark - Экран

@interface YTPlaylistViewController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation YTPlaylistViewController {
    NSString *_playlistId;
    NSString *_titleText;

    UIView *_bar;
    UIButton *_back;
    UILabel *_barTitle;

    UITableView *_table;
    YTPlaylistHeader *_header;
    YTStatusView *_status;

    NSMutableArray *_items;
    NSMutableArray *_rows;

    YTPager *_pager;
    YTGeneration *_generation;

    NSInteger _columns;
    CGFloat _laidOutWidth;
}

- (id)initWithPlaylistId:(NSString *)playlistId title:(NSString *)title {
    self = [super init];

    if (self != nil) {
        _playlistId = [playlistId copy];
        _titleText = [title copy];
    }

    return self;
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

    _items = [NSMutableArray array];
    _rows = [NSMutableArray array];
    _pager = [[YTPager alloc] init];
    _generation = [[YTGeneration alloc] init];
    _columns = 1;

    [[self view] setBackgroundColor:[YTTheme background]];

    _bar = [[UIView alloc] initWithFrame:CGRectZero];
    [YTSkin paintBar:_bar];
    [[self view] addSubview:_bar];

    _back = [UIButton buttonWithType:UIButtonTypeCustom];
    [[_back titleLabel] setFont:YTFontRegular(24)];
    [_back setTitle:@"‹" forState:UIControlStateNormal];
    [_back setTitleColor:[YTTheme primaryText] forState:UIControlStateNormal];
    [_back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_back];

    _barTitle = YTLabel(YTFontSemiBold(17), [YTTheme primaryText], 1);
    [_barTitle setText:_titleText];
    [_bar addSubview:_barTitle];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    [_table setDataSource:self];
    [_table setDelegate:self];
    [_table setSeparatorStyle:UITableViewCellSeparatorStyleNone];
    [_table setBackgroundColor:[YTTheme background]];
    [_table setBackgroundView:nil];
    [[self view] addSubview:_table];

    _header = [[YTPlaylistHeader alloc] initWithFrame:CGRectZero];

    _status = [[YTStatusView alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_status];

    [self load];
}

- (void)goBack {
    [YTNav pop];
}

- (void)load {
    NSInteger generation = [_generation next];

    [_pager reset];
    [_status showBusy];

    NSString *playlistId = _playlistId;

    YTAsync(^{
        NSDictionary *playlist = [YTApi playlist:playlistId];

        YTMain(^{
            if (![_generation isCurrent:generation]) {
                return;
            }

            if (playlist == nil) {
                [_status showOffline:YTLoc(@"Подборка не открылась")
                                hint:YTLoc(@"Проверьте подключение и попробуйте снова")
                         actionTitle:YTLoc(@"Повторить")
                              action:^{
                    [self load];
                }];

                return;
            }

            NSString *title = [playlist objectForKey:@"title"];

            if ([title length] > 0) {
                [_barTitle setText:title];
            }

            [_header bind:playlist];

            [_items removeAllObjects];

            /**
             * Каждому ролику проставляется идентификатор подборки, из которой
             * его открывают: без него страница ролика не покажет очередь,
             * а переключение внутри подборки превратится в обычные переходы.
             */
            for (YTVideoItem *item in [playlist objectForKey:@"items"]) {
                item.playlistId = playlistId;

                [_items addObject:item];
            }

            [_pager setToken:[playlist objectForKey:@"continuation"]];

            if ([_items count] == 0) {
                [_status showMessage:YTLoc(@"В подборке пусто")];
            } else {
                [_status hide];
            }

            [self rebuildRows];
            [self layoutHeader];
            [_table reloadData];
        });
    });
}

- (void)layoutHeader {
    CGFloat width = [[self view] bounds].size.width;
    CGFloat height = [_header heightForWidth:width];

    [_header setFrame:CGRectMake(0, 0, width, height)];
    [_header layoutIfNeeded];

    [_table setTableHeaderView:_header];
}

- (void)rebuildRows {
    [_rows removeAllObjects];

    NSMutableArray *current = nil;

    for (YTVideoItem *item in _items) {
        if (current == nil || [current count] >= (NSUInteger)_columns) {
            current = [NSMutableArray array];
            [_rows addObject:current];
        }

        [current addObject:item];
    }
}

#pragma mark Таблица

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[_rows count];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path {
    NSArray *row = [_rows objectAtIndex:[path row]];

    CGFloat available = [[self view] bounds].size.width - YTFeedPadding * 2;
    CGFloat cardWidth = floor((available - YTCardSpacing * (_columns - 1)) / _columns);

    CGFloat height = 0;

    for (YTVideoItem *item in row) {
        height = MAX(height, [YTVideoCard heightForWidth:cardWidth item:item]);
    }

    return height + YTCardSpacing;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)path {
    static NSString *identifier = @"row";

    YTFeedRowCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];

    if (cell == nil) {
        cell = [[YTFeedRowCell alloc] initWithStyle:UITableViewCellStyleDefault
                                    reuseIdentifier:identifier];
    }

    [cell bindRow:[_rows objectAtIndex:[path row]]
            width:[[self view] bounds].size.width
          columns:_columns];

    return cell;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (![_pager claimOn:scrollView]) {
        return;
    }

    NSInteger generation = [_generation current];
    NSString *token = [_pager token];

    YTAsync(^{
        NSDictionary *feed = [YTApi browseContinuation:token];

        YTMain(^{
            [_pager finish];

            if (![_generation isCurrent:generation]) {
                return;
            }

            NSArray *items = [feed objectForKey:@"items"];

            if ([items count] == 0) {
                [_pager setToken:nil];
                return;
            }

            [_pager setToken:[feed objectForKey:@"continuation"]];

            for (YTVideoItem *item in items) {
                item.playlistId = _playlistId;

                [_items addObject:item];
            }

            [self rebuildRows];
            [_table reloadData];
        });
    });
}

#pragma mark Раскладка

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];

    CGRect box = [[self view] bounds];
    CGFloat top = YTStatusBarHeight();

    [_bar setFrame:CGRectMake(0, top, box.size.width, YTNavBarHeight)];
    [_back setFrame:CGRectMake(4, 8, 40, 40)];
    [_barTitle setFrame:CGRectMake(48, 8, box.size.width - 64, 40)];

    CGFloat contentTop = top + YTNavBarHeight;

    [_table setFrame:CGRectMake(0, contentTop, box.size.width,
                                box.size.height - contentTop)];
    [_status setFrame:[_table frame]];

    if (_laidOutWidth == box.size.width) {
        return;
    }

    _laidOutWidth = box.size.width;

    NSInteger columns = YTColumnsForWidth(box.size.width - YTFeedPadding * 2);

    if (columns != _columns) {
        _columns = columns;
        [self rebuildRows];
    }

    [self layoutHeader];
    [_table reloadData];
}

@end
