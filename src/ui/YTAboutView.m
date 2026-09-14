#import "YTSimpleScreens.h"

#import "YTStrings.h"

#import <QuartzCore/QuartzCore.h>

#import "YTMetrics.h"
#import "YTSkin.h"
#import "YTTheme.h"
#import "YTUtil.h"
#import "YTLog.h"

/**
 * «О программе» — отдельная страница, а не всплывающий список.
 *
 * Устроена как в «Трубаче»: прокрутка, внутри стопка строк, у каждой
 * свой отступ сверху — им и задаются отбивки между блоками. Строки
 * бывают двух видов, обычная надпись и нажимаемая; больше здесь ничего
 * не нужно, а раскладка от этого умещается в один проход.
 *
 * Сведения о разработчике те же, что в «Трубаче»: приложения разные,
 * а человек за ними один.
 */
@implementation YTAboutViewController {
    UIView *_bar;
    UIButton *_back;

    UIScrollView *_page;
    UIView *_panel;

    /** Отступ сверху для каждой строки. */
    NSMutableArray *_gaps;

    UILabel *_notice;
}

- (void)loadView {
    [super loadView];

    _gaps = [NSMutableArray array];

    _bar = [[UIView alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_bar];

    _back = [UIButton buttonWithType:UIButtonTypeCustom];
    [[_back titleLabel] setFont:YTFontRegular(24)];
    [_back setTitle:@"‹" forState:UIControlStateNormal];
    [_back addTarget:self action:@selector(goBack)
    forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_back];

    _page = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [[self view] addSubview:_page];

    _panel = [[UIView alloc] initWithFrame:CGRectZero];
    [_page addSubview:_panel];

    [self buildRows];
    [self applyTheme];
}

- (void)buildRows {
    NSString *version = [[[NSBundle mainBundle] infoDictionary]
        objectForKey:@"CFBundleShortVersionString"];

    NSString *system = [[UIDevice currentDevice] systemVersion];

    [self addText:YTLoc(@"Трубадур") font:YTFontSemiBold(22) muted:NO gap:0];

    [self addText:YTLocF(@"Версия %@", version ?: @"1.0")
             font:YTFontRegular(15) muted:YES gap:4];

    /**
     * Чей это клиент, сказано отдельной строкой: ставить «YouTube»
     * первым словом в названии приложения нельзя, магазины такое
     * отклоняют. В «Трубаче» ровно та же оговорка.
     */
    [self addText:YTLoc(@"Неофициальный клиент YouTube для iOS 5.1 и новее.")
             font:YTFontRegular(15) muted:YES gap:18];

    [self addText:YTLoc(@"Разработчик: Computershik")
             font:YTFontRegular(15) muted:NO gap:22];

    /**
     * Откуда приложение взялось — отдельной строкой и с именем автора
     * исходного клиента. Это не формальность: почти вся повадка, разбор
     * ответов и вид экранов перенесены оттуда, и умолчать об этом было бы
     * нечестно.
     */
    [self addText:YTLoc(@"Вдохновлено клиентом YouTube UWP для Windows 10 Mobile "
                        @"от zemonkamin — в его разработке я тоже участвовал.")
             font:YTFontRegular(14) muted:YES gap:14];

    [self addLink:YTLoc(@"Страница на 4PDA")
              url:@"https://4pda.to/forum/index.php?showuser=4458524" gap:14];

    [self addLink:YTLoc(@"Telegram-канал") url:@"https://t.me/cmplog" gap:10];

    [self addLink:YTLoc(@"Поддержать финансово")
              url:@"https://pay.cloudtips.ru/p/83821e32" gap:10];

    [self addText:YTLocF(@"Система: iOS %@", system)
             font:YTFontRegular(13) muted:YES gap:26];

    /**
     * Про журнал — только там, где он есть.
     *
     * Готовая сборка не пишет ни строки, и обещать в ней файл, которого
     * не будет, значит отправить человека искать пустое место. А в
     * обычной сборке эта пара строк — единственный способ объяснить,
     * что присылать, когда что-то пошло не так.
     */
#ifndef YT_NO_LOG
    [self addText:YTLocF(@"Журнал работы пишется в %@. Если что-то пошло не так, "
                         @"нужен именно этот файл.", YTLogPath())
             font:YTFontRegular(13) muted:YES gap:6];

    __weak YTAboutViewController *weakSelf = self;

    [self addAction:YTLoc(@"Очистить журнал") gap:12 block:^{
        YTLogClear();

        NSLog(@"[YouTube] Журнал очищен");

        [weakSelf noteCleared];
    }];
#endif
}

#pragma mark Строки

- (void)addText:(NSString *)text font:(UIFont *)font muted:(BOOL)muted gap:(CGFloat)gap {
    UILabel *label = YTLabel(font, muted ? [YTTheme secondaryText] : [YTTheme primaryText], 0);

    [label setText:text];

    [_panel addSubview:label];
    [_gaps addObject:[NSNumber numberWithFloat:gap]];
}

- (void)addLink:(NSString *)text url:(NSString *)address gap:(CGFloat)gap {
    [self addAction:text gap:gap block:^{
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:address]];
    }];
}

- (void)addAction:(NSString *)text gap:(CGFloat)gap block:(dispatch_block_t)block {
    YTTappableView *row = [[YTTappableView alloc] initWithFrame:CGRectZero];

    [row setOnTap:block];

    UILabel *label = YTLabel(YTFontRegular(15), [YTTheme accentBlue], 1);

    [label setText:text];
    [row addSubview:label];

    [_panel addSubview:row];
    [_gaps addObject:[NSNumber numberWithFloat:gap]];
}

/** Подтверждение вместо окна: нажали — и видно, что сработало. */
- (void)noteCleared {
    if (_notice == nil) {
        _notice = YTLabel(YTFontRegular(14), [UIColor whiteColor], 1);

        [_notice setTextAlignment:NSTextAlignmentCenter];
        [_notice setBackgroundColor:[UIColor colorWithWhite:0 alpha:0.8]];
        [[_notice layer] setCornerRadius:14];
        [_notice setClipsToBounds:YES];
        [_notice setAlpha:0];

        [[self view] addSubview:_notice];
    }

    [_notice setText:YTLoc(@"Журнал очищен")];

    CGRect box = [[self view] bounds];
    CGFloat width = MIN(box.size.width - 48, (CGFloat)220);

    [_notice setFrame:CGRectMake((box.size.width - width) / 2,
                                 box.size.height - 100, width, 28)];

    [[self view] bringSubviewToFront:_notice];

    [UIView animateWithDuration:0.2 animations:^{ [_notice setAlpha:1]; }];

    [self performSelector:@selector(hideNotice) withObject:nil afterDelay:2.0];
}

- (void)hideNotice {
    [UIView animateWithDuration:0.3 animations:^{ [_notice setAlpha:0]; }];
}

#pragma mark Оформление и раскладка

- (void)applyTheme {
    [[self view] setBackgroundColor:[YTTheme background]];

    [YTSkin paintBar:_bar];
    [_back setTitleColor:[YTTheme barText] forState:UIControlStateNormal];
}

- (void)goBack {
    [YTNav pop];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];

    CGRect box = [[self view] bounds];
    CGFloat top = YTStatusBarHeight();

    [_bar setFrame:CGRectMake(0, top, box.size.width, YTNavBarHeight)];
    [_back setFrame:CGRectMake(4, 8, 40, 40)];

    CGFloat contentTop = top + YTNavBarHeight;

    [_page setFrame:CGRectMake(0, contentTop, box.size.width,
                               box.size.height - contentTop)];

    /**
     * Ширина ограничена сверху: на планшете строка во весь экран
     * читалась бы плохо — глаз теряет начало следующей строки.
     * Полоса текста центрируется, как и на любой книжной странице.
     */
    CGFloat side = 18;
    CGFloat width = MIN(box.size.width - side * 2, (CGFloat)560);
    CGFloat left = (box.size.width - width) / 2;

    CGFloat y = 16;
    NSArray *children = [_panel subviews];

    for (NSUInteger i = 0; i < [children count]; i++) {
        UIView *child = [children objectAtIndex:i];

        y += [[_gaps objectAtIndex:i] floatValue];

        if ([child isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)child;

            CGFloat height = YTTextHeight([label text], [label font], width, 0);

            [label setFrame:CGRectMake(0, y, width, height)];

            y += height;

            continue;
        }

        // Нажимаемая строка повыше подписи — чтобы удобно было попадать
        // пальцем, а не выцеливать пятнадцать точек текста.
        [child setFrame:CGRectMake(0, y, width, 30)];
        [[[child subviews] objectAtIndex:0] setFrame:CGRectMake(0, 0, width, 30)];

        y += 30;
    }

    [_panel setFrame:CGRectMake(left, 0, width, y + 24)];
    [_page setContentSize:CGSizeMake(box.size.width, y + 24)];
}

@end
