#import "YTAppIconView.h"

#import "YTAppIcon.h"
#import "YTMetrics.h"
#import "YTStrings.h"
#import "YTTheme.h"
#import "YTUtil.h"

/** Метка окна с вопросом про перезапуск оболочки. */
#define YTIconRespringTag 7311

@interface YTAppIconViewController () <UIAlertViewDelegate, UITextFieldDelegate>
@end

@implementation YTAppIconViewController {
    UIView *_bar;
    UIButton *_back;
    UILabel *_heading;

    UIScrollView *_scroll;

    UIImageView *_preview;
    UILabel *_source;

    UITextField *_name;

    UIButton *_pick;
    UIButton *_apply;
    UIButton *_restore;

    UILabel *_status;

    /** Значок, выбранный из темы, но ещё не поставленный. */
    UIImage *_chosen;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return YES;
}

- (UIButton *)buttonTitled:(NSString *)title action:(SEL)action filled:(BOOL)filled {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];

    [[button titleLabel] setFont:YTFontSemiBold(16)];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:filled ? [YTTheme primaryActionForeground]
                                 : [YTTheme primaryText]
                 forState:UIControlStateNormal];

    [button setBackgroundColor:filled ? [YTTheme primaryActionBackground]
                                  : [YTTheme surface]];

    [[button layer] setCornerRadius:10];

    [button addTarget:self action:action
     forControlEvents:UIControlEventTouchUpInside];

    [_scroll addSubview:button];

    return button;
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
    [_heading setText:YTLoc(@"Значок приложения")];
    [_bar addSubview:_heading];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_scroll];

    _preview = [[UIImageView alloc] initWithFrame:CGRectZero];

    [_preview setContentMode:UIViewContentModeScaleAspectFill];
    [_preview setClipsToBounds:YES];
    [[_preview layer] setCornerRadius:20];
    [_scroll addSubview:_preview];

    _source = YTLabel(YTFontRegular(13), [YTTheme mutedText], 2);
    [_source setTextAlignment:NSTextAlignmentCenter];
    [_scroll addSubview:_source];

    /**
     * Поле имени — обычное, с рамкой: это единственное место
     * в приложении, где человек что-то печатает не для поиска,
     * и выглядеть оно должно как поле, а не как подпись.
     */
    _name = [[UITextField alloc] initWithFrame:CGRectZero];

    [_name setFont:YTFontRegular(16)];
    [_name setTextColor:[YTTheme primaryText]];
    [_name setBackgroundColor:[YTTheme surface]];
    [_name setBorderStyle:UITextBorderStyleNone];
    [_name setPlaceholder:YTLoc(@"Название под значком")];
    [_name setAutocorrectionType:UITextAutocorrectionTypeNo];
    [_name setAutocapitalizationType:UITextAutocapitalizationTypeNone];
    [_name setClearButtonMode:UITextFieldViewModeWhileEditing];
    [_name setReturnKeyType:UIReturnKeyDone];
    [_name setDelegate:self];
    [[_name layer] setCornerRadius:10];

    /* Отступ внутри поля: без него текст лип бы к самому краю. */
    UIView *pad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];

    [_name setLeftView:pad];
    [_name setLeftViewMode:UITextFieldViewModeAlways];

    [_scroll addSubview:_name];

    _pick = [self buttonTitled:YTLoc(@"Выбрать тему (.zip)")
                        action:@selector(pickTheme)
                        filled:NO];

    _apply = [self buttonTitled:YTLoc(@"Применить")
                         action:@selector(applyChoice)
                         filled:YES];

    _restore = [self buttonTitled:YTLoc(@"Вернуть свой значок")
                           action:@selector(restoreOwn)
                           filled:NO];

    _status = YTLabel(YTFontRegular(13), [YTTheme mutedText], 0);
    [_scroll addSubview:_status];

    [self refresh];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];

    CGRect bounds = [[self view] bounds];

    CGFloat top = YTStatusBarHeight();

    [_bar setFrame:CGRectMake(0, 0, bounds.size.width, top + 44)];
    [_back setFrame:CGRectMake(4, top, 44, 44)];
    [_heading setFrame:CGRectMake(52, top, bounds.size.width - 68, 44)];

    [_scroll setFrame:CGRectMake(0, top + 44, bounds.size.width,
                                 bounds.size.height - top - 44)];

    CGFloat width = bounds.size.width;
    CGFloat side = 16;
    CGFloat inner = width - side * 2;

    CGFloat at = 20;

    [_preview setFrame:CGRectMake((width - 96) / 2, at, 96, 96)];

    at += 96 + 8;

    [_source setFrame:CGRectMake(side, at, inner, 34)];

    at += 34 + 12;

    [_name setFrame:CGRectMake(side, at, inner, 44)];

    at += 44 + 14;

    [_pick setFrame:CGRectMake(side, at, inner, 44)];

    at += 44 + 10;

    [_apply setFrame:CGRectMake(side, at, inner, 44)];

    at += 44 + 10;

    [_restore setFrame:CGRectMake(side, at, inner, 44)];

    at += 44 + 16;

    CGSize said = [[_status text] length] > 0
        ? [[_status text] sizeWithFont:[_status font]
                     constrainedToSize:CGSizeMake(inner, 400)
                         lineBreakMode:NSLineBreakByWordWrapping]
        : CGSizeZero;

    [_status setFrame:CGRectMake(side, at, inner, said.height)];

    at += said.height + 24;

    [_scroll setContentSize:CGSizeMake(width, at)];
}

- (void)repaintColours {
    [[self view] setBackgroundColor:[YTTheme background]];

    [_bar setBackgroundColor:[YTTheme background]];

    [_heading setTextColor:[YTTheme primaryText]];
    [_back setTitleColor:[YTTheme primaryText] forState:UIControlStateNormal];

    [_name setTextColor:[YTTheme primaryText]];
    [_name setBackgroundColor:[YTTheme surface]];

    [_source setTextColor:[YTTheme mutedText]];
    [_status setTextColor:[YTTheme mutedText]];

    [_pick setBackgroundColor:[YTTheme surface]];
    [_restore setBackgroundColor:[YTTheme surface]];
    [_apply setBackgroundColor:[YTTheme primaryActionBackground]];
}

- (void)refresh {
    [self repaintColours];

    [_preview setImage:_chosen != nil ? _chosen : [YTAppIcon currentIcon]];

    if ([[_name text] length] == 0) {
        [_name setText:[YTAppIcon currentName]];
    }

    /**
     * Кнопку «вернуть своё» держим доступной только тогда, когда есть
     * что возвращать: нажатие, которое ничего не делает, хуже
     * отсутствующей кнопки.
     */
    [_restore setEnabled:[YTAppIcon usesAlternate]];
    [_restore setAlpha:[YTAppIcon usesAlternate] ? 1.0f : 0.4f];

    if (![YTAppIcon helperReady]) {
        [self say:YTLoc(@"Помощник не может менять значок: у него нет прав "
                        @"root. Переустановите пакет из источника — права "
                        @"проставляются при установке")];
    }

    [[self view] setNeedsLayout];
}

- (void)say:(NSString *)text {
    [_status setText:text];

    [[self view] setNeedsLayout];
}

- (void)goBack {
    [YTNav pop];
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    [field resignFirstResponder];

    return YES;
}

#pragma mark Выбор темы

- (void)pickTheme {
    __weak YTAppIconViewController *weakSelf = self;

    YTThemePickerViewController *picker = [[YTThemePickerViewController alloc]
        initWithChoice:^(NSString *archive) {
            [weakSelf loadTheme:archive];
        }];

    [YTNav push:picker];
}

- (void)loadTheme:(NSString *)archive {
    [self say:YTLocF(@"Читаю %@…", [archive lastPathComponent])];

    __weak YTAppIconViewController *weakSelf = self;

    YTAsync(^{
        NSString *entry = nil;

        UIImage *icon = [YTAppIcon iconFromTheme:archive found:&entry];

        YTMain(^{
            YTAppIconViewController *strong = weakSelf;

            if (strong == nil) {
                return;
            }

            [strong tookIcon:icon from:entry archive:archive];
        });
    });
}

- (void)tookIcon:(UIImage *)icon from:(NSString *)entry archive:(NSString *)archive {
    if (icon == nil) {
        [self say:YTLoc(@"В этой теме значка YouTube нет. Обычно он лежит "
                        @"в IconBundles под именем com.google.ios.youtube.png")];

        return;
    }

    _chosen = icon;

    [_source setText:[entry lastPathComponent]];

    [self say:YTLocF(@"Значок взят из «%@». Нажмите «Применить»",
                     [archive lastPathComponent])];

    [self refresh];
}

#pragma mark Подмена

- (void)applyChoice {
    [_name resignFirstResponder];

    if (![YTAppIcon helperReady]) {
        [self say:YTLoc(@"Помощника нет или он без прав root — менять нечем")];

        return;
    }

    NSString *wanted = [[_name text] stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (_chosen == nil && [wanted isEqualToString:[YTAppIcon currentName]]) {
        [self say:YTLoc(@"Менять нечего: значок не выбран, название прежнее")];

        return;
    }

    if (![YTAppIcon applyIcon:_chosen name:wanted]) {
        [self say:YTLoc(@"Не вышло. Что именно не вышло — в журнале, строки "
                        @"«[YouTube/Значок]»")];

        return;
    }

    _chosen = nil;

    [self refresh];

    [self askRespring];
}

- (void)restoreOwn {
    [_name resignFirstResponder];

    if (![YTAppIcon restore]) {
        [self say:YTLoc(@"Не вышло вернуть своё — подробности в журнале")];

        return;
    }

    _chosen = nil;

    [_source setText:@""];
    [_name setText:[YTAppIcon currentName]];

    [self refresh];

    [self askRespring];
}

- (void)askRespring {
    UIAlertView *ask = [[UIAlertView alloc]
        initWithTitle:YTLoc(@"Готово")
              message:YTLoc(@"Значок и название сменены. Чтобы их было видно, "
                            @"нужно перезапустить оболочку. Сделать это сейчас?")
             delegate:self
    cancelButtonTitle:YTLoc(@"Позже")
    otherButtonTitles:YTLoc(@"Перезапустить"), nil];

    [ask setTag:YTIconRespringTag];
    [ask show];
}

- (void)alertView:(UIAlertView *)view clickedButtonAtIndex:(NSInteger)index {
    if ([view tag] != YTIconRespringTag || index == [view cancelButtonIndex]) {
        return;
    }

    if (![YTAppIcon respring]) {
        [self say:YTLoc(@"Оболочка не перезапустилась — сделайте это сами")];
    }
}

@end

/**
 * Список тем.
 *
 * Выбирать файл на iOS 5 неоткуда: ни окна выбора, ни доступа к чужим
 * каталогам у приложения нет. Поэтому мы сами смотрим в те места, куда
 * обычно складывают скачанное, и показываем всё, что там нашлось.
 */
@interface YTThemePickerViewController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation YTThemePickerViewController {
    UIView *_bar;
    UIButton *_back;
    UILabel *_heading;
    UITableView *_table;
    UILabel *_empty;

    NSArray *_archives;

    void (^_choice)(NSString *archive);
}

- (id)initWithChoice:(void (^)(NSString *archive))choice {
    self = [super init];

    if (self != nil) {
        _choice = [choice copy];
    }

    return self;
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
    [_heading setText:YTLoc(@"Темы")];
    [_bar addSubview:_heading];

    _archives = [YTAppIcon themeArchives];

    _table = [[UITableView alloc] initWithFrame:CGRectZero
                                          style:UITableViewStylePlain];

    [_table setDataSource:self];
    [_table setDelegate:self];
    [_table setBackgroundColor:[YTTheme background]];
    [_table setSeparatorStyle:UITableViewCellSeparatorStyleNone];
    [[self view] addSubview:_table];

    _empty = YTLabel(YTFontRegular(14), [YTTheme mutedText], 0);

    [_empty setTextAlignment:NSTextAlignmentCenter];
    [_empty setText:YTLocF(@"Архивов не нашлось. Положите тему (.zip) в один "
                           @"из этих каталогов:\n\n%@",
                           [[YTAppIcon themeFolders] componentsJoinedByString:@"\n"])];

    [_empty setHidden:[_archives count] > 0];

    [[self view] addSubview:_empty];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];

    CGRect bounds = [[self view] bounds];

    CGFloat top = YTStatusBarHeight();

    [_bar setFrame:CGRectMake(0, 0, bounds.size.width, top + 44)];
    [_bar setBackgroundColor:[YTTheme background]];

    [_back setFrame:CGRectMake(4, top, 44, 44)];
    [_heading setFrame:CGRectMake(52, top, bounds.size.width - 68, 44)];

    [_table setFrame:CGRectMake(0, top + 44, bounds.size.width,
                                bounds.size.height - top - 44)];

    [_empty setFrame:CGRectMake(24, top + 80, bounds.size.width - 48,
                                bounds.size.height - top - 120)];
}

- (void)goBack {
    [YTNav pop];
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[_archives count];
}

- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    return 58;
}

- (UITableViewCell *)tableView:(UITableView *)table
         cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"theme"];

    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"theme"];
    }

    NSString *archive = [_archives objectAtIndex:(NSUInteger)[path row]];

    [cell setBackgroundColor:[YTTheme background]];

    [[cell textLabel] setFont:YTFontRegular(16)];
    [[cell textLabel] setTextColor:[YTTheme primaryText]];
    [[cell textLabel] setText:[archive lastPathComponent]];

    [[cell detailTextLabel] setFont:YTFontRegular(12)];
    [[cell detailTextLabel] setTextColor:[YTTheme mutedText]];
    [[cell detailTextLabel] setText:[archive stringByDeletingLastPathComponent]];

    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:NO];

    NSString *archive = [_archives objectAtIndex:(NSUInteger)[path row]];

    if (_choice != nil) {
        _choice(archive);
    }

    [YTNav pop];
}

@end
