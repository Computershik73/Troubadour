#import "YTSkinView.h"

#import "YTMetrics.h"
#import "YTSkin.h"
#import "YTStrings.h"
#import "YTTheme.h"
#import "YTUtil.h"

/** Одна плитка выбора: снимок, название, пояснение и галочка. */
@interface YTSkinTile : YTTappableView

- (void)bind:(NSString *)skin picked:(BOOL)picked;

+ (CGFloat)heightForWidth:(CGFloat)width;

@end

@implementation YTSkinTile {
    NSString *_skin;

    UIImageView *_shot;
    UILabel *_title;
    UILabel *_hint;
    UILabel *_check;
}

/** Снимок — в пропорции экрана телефона, чтобы читался как экран. */
+ (CGFloat)shotHeightForWidth:(CGFloat)width {
    return floor(width * 0.52);
}

+ (CGFloat)heightForWidth:(CGFloat)width {
    return [self shotHeightForWidth:width] + 58;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    [self setHighlights:YES];

    _shot = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_shot setContentMode:UIViewContentModeScaleAspectFill];
    [_shot setClipsToBounds:YES];
    [[_shot layer] setCornerRadius:8];
    [[_shot layer] setBorderWidth:1];
    [self addSubview:_shot];

    _title = YTLabel(YTFontSemiBold(16), [YTTheme primaryText], 1);
    [self addSubview:_title];

    _hint = YTLabel(YTFontRegular(12), [YTTheme secondaryText], 2);
    [self addSubview:_hint];

    _check = YTLabel(YTFontRegular(18), [YTTheme primaryText], 1);
    [_check setTextAlignment:NSTextAlignmentRight];
    [self addSubview:_check];

    return self;
}

- (void)bind:(NSString *)skin picked:(BOOL)picked {
    _skin = [skin copy];

    [_title setText:[YTSkin titleFor:skin]];
    [_title setTextColor:[YTTheme primaryText]];

    [_hint setText:[YTSkin hintFor:skin]];
    [_hint setTextColor:[YTTheme secondaryText]];

    [_check setText:picked ? @"✓" : @""];
    [_check setTextColor:[YTTheme primaryText]];

    [[_shot layer] setBorderColor:[[YTTheme divider] CGColor]];

    [self setNeedsLayout];
}

- (void)layoutSubviews {
    CGFloat width = [self bounds].size.width;
    CGFloat shot = [[self class] shotHeightForWidth:width];

    [_shot setFrame:CGRectMake(0, 0, width, shot)];

    /**
     * Снимок рисуется под свой размер, а не тянется.
     *
     * Растянутая картинка выдала бы себя первой: у оформления, которое
     * она показывает, всё держится на волосяных линиях в одну точку,
     * а они при растяжении расплываются.
     */
    [_shot setImage:[YTSkin previewFor:_skin size:CGSizeMake(width, shot)]];

    [_title setFrame:CGRectMake(0, shot + 8, width - 30, 20)];
    [_check setFrame:CGRectMake(width - 26, shot + 8, 26, 20)];
    [_hint setFrame:CGRectMake(0, shot + 30, width, 28)];
}

@end


@implementation YTSkinViewController {
    UIView *_bar;
    UIButton *_back;
    UILabel *_barTitle;

    UIScrollView *_page;
    NSMutableArray *_tiles;
}

- (void)loadView {
    YTUseFullScreenLayout(self);

    [super loadView];

    _tiles = [NSMutableArray array];

    _bar = [[UIView alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_bar];

    _back = [UIButton buttonWithType:UIButtonTypeCustom];
    [[_back titleLabel] setFont:YTFontRegular(24)];
    [_back setTitle:@"‹" forState:UIControlStateNormal];
    [_back addTarget:self action:@selector(goBack)
    forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_back];

    _barTitle = YTLabel(YTFontSemiBold(17), [YTTheme primaryText], 1);
    [_barTitle setText:YTLoc(@"Оформление")];
    [_bar addSubview:_barTitle];

    _page = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_page];

    __weak YTSkinViewController *weakSelf = self;

    for (NSString *skin in [YTSkin options]) {
        YTSkinTile *tile = [[YTSkinTile alloc] initWithFrame:CGRectZero];

        NSString *name = [skin copy];

        [tile setOnTap:^{ [weakSelf pick:name]; }];

        [_page addSubview:tile];
        [_tiles addObject:tile];
    }

    [self refresh];
}

- (void)goBack {
    [YTNav pop];
}

- (void)pick:(NSString *)skin {
    if ([skin isEqualToString:[YTSkin current]]) {
        return;
    }

    [YTSkin setCurrent:skin];

    [self refresh];
    [[self view] setNeedsLayout];
}

- (void)refresh {
    [[self view] setBackgroundColor:[YTTheme background]];
    [_page setBackgroundColor:[YTTheme background]];

    [YTSkin paintBar:_bar];

    [_back setTitleColor:[YTTheme primaryText] forState:UIControlStateNormal];
    [_barTitle setTextColor:[YTTheme primaryText]];

    NSArray *options = [YTSkin options];
    NSString *now = [YTSkin current];

    for (NSUInteger i = 0; i < [_tiles count] && i < [options count]; i++) {
        NSString *skin = [options objectAtIndex:i];

        [[_tiles objectAtIndex:i] bind:skin
                                picked:[skin isEqualToString:now]];
    }
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];

    CGRect box = [[self view] bounds];
    CGFloat top = YTStatusBarHeight();

    [_bar setFrame:CGRectMake(0, top, box.size.width, YTNavBarHeight)];
    [_back setFrame:CGRectMake(4, 8, 40, 40)];
    [_barTitle setFrame:CGRectMake(48, 8, box.size.width - 96, 40)];

    // Полосу красим после того, как она получила высоту: рисунок под неё.
    [YTSkin paintBar:_bar];

    CGFloat contentTop = top + YTNavBarHeight;

    [_page setFrame:CGRectMake(0, contentTop, box.size.width,
                               box.size.height - contentTop)];

    CGFloat side = 16;
    CGFloat width = MIN(box.size.width - side * 2, (CGFloat)480);
    CGFloat left = (box.size.width - width) / 2;

    CGFloat y = 16;

    for (YTSkinTile *tile in _tiles) {
        CGFloat height = [YTSkinTile heightForWidth:width];

        [tile setFrame:CGRectMake(left, y, width, height)];

        y += height + 18;
    }

    [_page setContentSize:CGSizeMake(box.size.width, y + 16)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    [self refresh];
}

@end
