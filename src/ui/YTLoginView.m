#import "YTSimpleScreens.h"

#import "YTStrings.h"

#import <QuartzCore/QuartzCore.h>

#import "YTApi.h"
#import "YTAuth.h"
#import "YTHttp.h"
#import "YTJson.h"
#import "YTMetrics.h"
#import "YTTheme.h"
#import "YTUtil.h"

/**
 * Числа — из Login.xaml.
 *
 *     подпись сверху  18, AppPrimaryText, по центру, Margin="0,0,0,20"
 *     рамка QR        белая, CornerRadius="5.33", Padding="6.67", не больше 200
 *     код             24 Bold, Margin="0,20,0,0", CharacterSpacing="200"
 *     подпись под ним 14, AppMutedText, Margin="0,4,0,0"
 *     кнопка          обводка 2, скругление 32, высота 54, ширина от 173,
 *                     подпись 13.33 SemiBold, Margin="0,20,0,0"
 */
static const CGFloat YTQrSide = 200;

/**
 * Меньше этого код не ужимаем: мелкий QR камера соседнего телефона уже
 * не разбирает, а ради него весь экран и существует.
 */
static const CGFloat YTQrLeast = 132;

/** Строка «О программе» под кнопкой обновления. */
static const CGFloat YTLoginAboutHeight = 30;
static const CGFloat YTQrPadding = 6.67;
static const CGFloat YTLoginButtonHeight = 54;
static const CGFloat YTLoginButtonWidth = 173.33;


/**
 * Разбор base64.
 *
 * Штатный `initWithBase64EncodedString:` появился в iOS 7, а нижняя
 * граница у нас 5.1 — на ней приложение упало бы на неизвестном селекторе.
 * Своя реализация короче, чем проверка версии с двумя путями.
 */
static NSData *YTDecodeBase64(NSString *text) {
    static const int8_t table[128] = {
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,62,-1,-1,-1,63,
        52,53,54,55,56,57,58,59,60,61,-1,-1,-1,-1,-1,-1,
        -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,
        15,16,17,18,19,20,21,22,23,24,25,-1,-1,-1,-1,-1,
        -1,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,
        41,42,43,44,45,46,47,48,49,50,51,-1,-1,-1,-1,-1
    };

    NSData *ascii = [text dataUsingEncoding:NSASCIIStringEncoding];

    if (ascii == nil) {
        return nil;
    }

    const uint8_t *bytes = [ascii bytes];
    NSUInteger length = [ascii length];

    NSMutableData *out = [NSMutableData dataWithCapacity:length * 3 / 4];

    uint32_t buffer = 0;
    int bits = 0;

    for (NSUInteger i = 0; i < length; i++) {
        uint8_t c = bytes[i];

        if (c >= 128 || table[c] < 0) {
            continue;   // «=» и переводы строк просто пропускаем
        }

        buffer = (buffer << 6) | (uint32_t)table[c];
        bits += 6;

        if (bits >= 8) {
            bits -= 8;

            uint8_t byte = (uint8_t)((buffer >> bits) & 0xFF);

            [out appendBytes:&byte length:1];
        }
    }

    return out;
}


@implementation YTLoginView {
    UILabel *_status;
    UIView *_qrFrame;
    UIImageView *_qr;
    UILabel *_code;
    UILabel *_codeCaption;

    YTPillView *_refreshFill;
    UIButton *_refresh;
    UIButton *_about;
    UIButton *_settings;

    /** Развёрнутый во весь экран QR-код и подсказка под ним. */
    UIView *_zoom;
    UIImageView *_zoomImage;
    UILabel *_zoomHint;

    NSTimer *_poll;
    YTGeneration *_generation;
    BOOL _busy;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self == nil) {
        return nil;
    }

    _generation = [[YTGeneration alloc] init];

    [self setBackgroundColor:[YTTheme background]];

    _status = YTLabel(YTFontRegular(18), [YTTheme primaryText], 0);
    [_status setTextAlignment:NSTextAlignmentCenter];
    [_status setText:YTLoc(@"Отсканируйте QR-код, чтобы войти")];
    [self addSubview:_status];

    // Рамка QR всегда белая — это не цвет темы, а фон самого кода:
    // на тёмной подложке он не читается сканером.
    _qrFrame = [[UIView alloc] initWithFrame:CGRectZero];
    [_qrFrame setBackgroundColor:[UIColor whiteColor]];
    [[_qrFrame layer] setCornerRadius:5.33];
    [self addSubview:_qrFrame];

    _qr = [[UIImageView alloc] initWithFrame:CGRectZero];
    [_qr setContentMode:UIViewContentModeScaleAspectFit];
    [_qrFrame addSubview:_qr];

    /**
     * Нажатие по коду разворачивает его во весь экран.
     *
     * На iPhone 4 под код остаётся полторы сотни точек, а сканирует его
     * камера соседнего телефона — с такого квадрата она ловит его через
     * раз. Развёрнутый занимает почти весь экран, и наводить уже не нужно.
     */
    UITapGestureRecognizer *zoom =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zoomIn)];

    [_qrFrame setUserInteractionEnabled:YES];
    [_qrFrame addGestureRecognizer:zoom];

    _code = YTLabel(YTFontBold(24), [YTTheme primaryText], 1);
    [_code setTextAlignment:NSTextAlignmentCenter];
    [self addSubview:_code];

    _codeCaption = YTLabel(YTFontRegular(14), [YTTheme mutedText], 1);
    [_codeCaption setTextAlignment:NSTextAlignmentCenter];
    [_codeCaption setText:YTLoc(@"Код подтверждения")];
    [self addSubview:_codeCaption];

    _refreshFill = [[YTPillView alloc] initWithFrame:CGRectZero];
    [_refreshFill setCornerRadius:32];
    [_refreshFill setFillColor:[YTTheme background]];
    [self addSubview:_refreshFill];

    _refresh = [UIButton buttonWithType:UIButtonTypeCustom];
    [[_refresh titleLabel] setFont:YTFontSemiBold(13.33)];
    [_refresh setTitle:YTLoc(@"Обновить QR-код") forState:UIControlStateNormal];
    [_refresh setTitleColor:[YTTheme primaryText] forState:UIControlStateNormal];
    [_refresh addTarget:self action:@selector(restart) forControlEvents:UIControlEventTouchUpInside];

    // Обводка 2 точки — `BorderThickness="2"` у PillOutlineButtonStyle.
    [[_refresh layer] setBorderWidth:2];
    [[_refresh layer] setCornerRadius:32];
    [[_refresh layer] setBorderColor:[[YTTheme divider] CGColor]];

    [self addSubview:_refresh];

    /**
     * «Настройки» и «О программе» — прямо здесь, потому что иначе до них
     * не добраться.
     *
     * Обычно они открываются из строки с лупой и шестерёнкой наверху
     * вкладки «Вы». Но пока входа нет, экран входа занимает вкладку
     * целиком и эту строку закрывает — а нужны они как раз тогда: язык
     * приложения, тема, способ воспроизведения и вход через браузер
     * решаются до всякой учётной записи, а в сведениях лежит путь
     * к журналу, по которому и спрашивают о неполадках.
     *
     * Обе в один ряд: строкой ниже они съели бы место у самого кода.
     */
    _settings = [self footerButton:YTLoc(@"Настройки") action:@selector(openSettings)];
    _about = [self footerButton:YTLoc(@"О программе") action:@selector(openAbout)];

    return self;
}

/** Приглушённая надпись-кнопка в подвале экрана. */
- (UIButton *)footerButton:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];

    [[button titleLabel] setFont:YTFontRegular(13)];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[YTTheme mutedText] forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    [self addSubview:button];

    return button;
}

- (void)openAbout {
    [YTNav push:[[YTAboutViewController alloc] init]];
}

- (void)openSettings {
    [YTNav push:[[YTSettingsViewController alloc] init]];
}

/**
 * Разворачивает QR-код поверх всего окна.
 *
 * Именно окна, а не своего вида: у вкладки внизу своя полоса, и код,
 * растянутый только по ней, вышел бы меньше, чем мог бы. Подложка
 * непрозрачно-белая, а не затемнение: сканеру нужен белый фон вокруг
 * кода, иначе он его не отделит от края экрана.
 */
- (void)zoomIn {
    if ([_qr image] == nil) {
        return;
    }

    UIView *host = [self window] ?: self;

    if (_zoom == nil) {
        _zoom = [[UIView alloc] initWithFrame:CGRectZero];
        [_zoom setBackgroundColor:[UIColor whiteColor]];

        _zoomImage = [[UIImageView alloc] initWithFrame:CGRectZero];
        [_zoomImage setContentMode:UIViewContentModeScaleAspectFit];
        [_zoom addSubview:_zoomImage];

        _zoomHint = YTLabel(YTFontRegular(13), [UIColor darkGrayColor], 1);
        [_zoomHint setTextAlignment:NSTextAlignmentCenter];
        [_zoomHint setText:YTLoc(@"Нажмите, чтобы закрыть")];
        [_zoom addSubview:_zoomHint];

        UITapGestureRecognizer *close =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zoomOut)];

        [_zoom addGestureRecognizer:close];
    }

    [_zoomImage setImage:[_qr image]];

    CGRect box = [host bounds];
    CGFloat side = MIN(box.size.width, box.size.height) - 32;

    [_zoom setFrame:box];
    [_zoomImage setFrame:CGRectMake((box.size.width - side) / 2,
                                    (box.size.height - side) / 2 - 12, side, side)];

    [_zoomHint setFrame:CGRectMake(0, (box.size.height + side) / 2 + 4,
                                   box.size.width, 18)];

    [host addSubview:_zoom];
}

- (void)zoomOut {
    [_zoom removeFromSuperview];
}

#pragma mark Вход

- (void)restart {
    if (_busy) {
        return;
    }

    _busy = YES;

    [_poll invalidate];
    _poll = nil;

    NSInteger generation = [_generation next];

    [_code setText:nil];
    [_qr setImage:nil];
    [_status setText:YTLoc(@"Запрашиваем код…")];

    YTAsync(^{
        NSString *userCode = [YTAuth beginDeviceFlow];
        UIImage *qr = userCode != nil ? [self fetchQrFor:userCode] : nil;

        YTMain(^{
            _busy = NO;

            if (![_generation isCurrent:generation]) {
                return;
            }

            if (userCode == nil) {
                [_status setText:YTLoc(@"Не удалось получить код. Повторите попытку.")];
                return;
            }

            [_status setText:YTLoc(@"Откройте youtube.com/activate и введите код")];
            [_code setText:userCode];
            [_qr setImage:qr];

            [self setNeedsLayout];

            [self schedulePoll];
        });
    });
}

/**
 * Опрос сервера: подтвердили ли код.
 *
 * Шаг задаёт сам сервер — в ответе на запрос кода приходит `interval`,
 * и опрашивать чаще нельзя: на это он отвечает `slow_down`, после чего
 * YTAuth сам увеличивает паузу.
 */
- (void)schedulePoll {
    [_poll invalidate];

    _poll = [NSTimer scheduledTimerWithTimeInterval:[YTAuth pollInterval]
                                             target:self
                                           selector:@selector(poll)
                                           userInfo:nil
                                            repeats:NO];
}

- (void)poll {
    NSInteger generation = [_generation current];

    YTAsync(^{
        NSInteger result = [YTAuth pollDeviceFlow];

        YTMain(^{
            if (![_generation isCurrent:generation]) {
                return;
            }

            if (result == 1) {
                // Вход выполнен: разделы перезагрузятся сами по уведомлению,
                // и вкладка сама сменит содержимое на профиль.
                [_status setText:YTLoc(@"Готово")];

                return;
            }

            if (result < 0) {
                [_status setText:YTLoc(@"Код больше не действует. Обновите его.")];
                return;
            }

            [self schedulePoll];
        });
    });
}

/**
 * QR-код с самим кодом внутри.
 *
 * Рисует его не приложение, а YouTube: запрос `mdx/handoff` возвращает
 * готовую картинку в `qrCodeImage`, причём прямо в теле ответа — адресом
 * вида `data:image/png;base64,…`. Порт `GetTvQrBase64Async`.
 */
- (UIImage *)fetchQrFor:(NSString *)userCode {
    NSDictionary *client = [NSDictionary dictionaryWithObjectsAndKeys:
        @"TVHTML5", @"clientName",
        @"7.20251217.19.00", @"clientVersion",
        @"Samsung", @"deviceMake",
        @"SmartTV", @"deviceModel",
        @"TV", @"platform",
        @"ru", @"hl",
        @"RU", @"gl",
        nil];

    NSDictionary *rapid = [NSDictionary dictionaryWithObjectsAndKeys:
        @"HANDOFF_QR_LIMITED_PRESET_STYLE_MODERN_BIG_DOTS_INVERT_WITH_YT_LOGO", @"qrPresetStyle",
        userCode, @"userCode",
        @"RAPID_QR_FEATURE_DEFAULT", @"rapidQrFeature",
        nil];

    NSDictionary *payload = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSDictionary dictionaryWithObject:client forKey:@"client"], @"context",
        [NSDictionary dictionaryWithObject:rapid forKey:@"rapidQrParams"], @"handoffQrParams",
        nil];

    NSMutableURLRequest *request = YTRequest(
        @"https://www.youtube.com/youtubei/v1/mdx/handoff"
        @"?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8",
        NSURLRequestReloadIgnoringLocalCacheData, 20.0);

    if (request == nil) {
        return nil;
    }

    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0)" forHTTPHeaderField:@"User-Agent"];
    [request setHTTPBody:[YTJson encode:payload]];

    YTHttpResponse *response = [YTHttp send:request bodyLimit:2 * 1024 * 1024 caching:NO];

    if (![response isSuccessful]) {
        NSLog(@"[YouTube/Вход] QR не получен: код %ld", (long)response.statusCode);
        return nil;
    }

    NSDictionary *json = [YTJson parse:response.body];

    /**
     * Ответ уложен так: `rapidQrRenderer → qrCodeRenderer → qrCodeImage →
     * thumbnails[0].url`. Ищем **владельца** `qrCodeImage`, а не саму
     * картинку: `thumbnailIn:` ждёт ключ, за которым лежит объект
     * с массивом `thumbnails`, и передавать ему сам массив бесполезно —
     * он молча вернёт nil. На этом QR и не появлялся.
     */
    NSDictionary *renderer = [YTJson findFirst:@"qrCodeRenderer" in:json limit:2000];

    NSString *url = [YTJson thumbnailIn:renderer key:@"qrCodeImage" minWidth:0];

    if ([url length] == 0) {
        NSLog(@"[YouTube/Вход] В ответе нет картинки QR");
        return nil;
    }

    NSRange marker = [url rangeOfString:@"base64,"];

    if (marker.location == NSNotFound) {
        // Обычный адрес — забираем как файл.
        NSMutableURLRequest *plain =
            YTRequest(url, NSURLRequestUseProtocolCachePolicy, 20.0);

        YTHttpResponse *picture = [YTHttp send:plain bodyLimit:2 * 1024 * 1024];

        return [picture isSuccessful] ? [UIImage imageWithData:picture.body] : nil;
    }

    NSData *data = YTDecodeBase64([url substringFromIndex:marker.location + marker.length]);

    return [UIImage imageWithData:data];
}

#pragma mark Раскладка

/** Зовётся разделом при показе и при уходе с вкладки. */
- (void)activate {
    if ([_code text] == nil && !_busy) {
        [self restart];
    }
}

- (void)deactivate {
    // Ушли с вкладки — опрос прекращается: иначе таймер продолжал бы
    // ходить в сеть с невидимого раздела.
    [_generation next];

    [_poll invalidate];
    _poll = nil;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect bounds = [self bounds];
    CGFloat top = 0;

    // Содержимое по центру, `Margin="20,0,20,0"`.
    CGFloat width = bounds.size.width - 40;

    CGFloat statusHeight = YTTextHeight([_status text], [_status font], width, 0);
    CGFloat codeHeight = ceil([[_code font] lineHeight]);
    CGFloat captionHeight = ceil([[_codeCaption font] lineHeight]);

    /**
     * Сперва считаем всё, кроме кода, — и только оставшимся местом
     * распоряжается сам QR.
     *
     * Раньше его сторона была задана числом (200), и на невысоком экране
     * содержимое переставало помещаться: подпись сверху бывает в две
     * строки — «Откройте youtube.com/activate и введите код» на 320 точках
     * не умещается в одну, — а снизу прибавилась строка «О программе».
     * На iPhone 4 нижняя кнопка от этого уезжала за край. Теперь наоборот:
     * что не заняли подписи, то и достаётся коду.
     *
     * Ниже YTQrLeast не ужимаем: слишком мелкий код камера не разбирает,
     * и лучше показать его как есть — прокрутки здесь нет, но и обрезка
     * заметнее, чем польза от сжатия.
     */
    CGFloat fixed = statusHeight + 20 + 20 + codeHeight + 4
                  + captionHeight + 20 + YTLoginButtonHeight
                  + 12 + YTLoginAboutHeight;

    CGFloat qrSide = MIN(YTQrSide, width);

    if (bounds.size.height > 0) {
        CGFloat room = bounds.size.height - fixed - 16;

        if (room < qrSide) {
            qrSide = MAX(YTQrLeast, room);
        }
    }

    CGFloat total = fixed + qrSide;

    CGFloat y = top + (bounds.size.height - total) / 2;

    if (y < top) {
        y = top;
    }

    [_status setFrame:CGRectMake(20, y, width, statusHeight)];
    y += statusHeight + 20;

    [_qrFrame setFrame:CGRectMake((bounds.size.width - qrSide) / 2, y, qrSide, qrSide)];
    [_qr setFrame:CGRectMake(YTQrPadding, YTQrPadding,
                             qrSide - YTQrPadding * 2, qrSide - YTQrPadding * 2)];

    [_qrFrame setHidden:([_qr image] == nil)];

    y += qrSide + 20;

    [_code setFrame:CGRectMake(20, y, width, codeHeight)];
    y += codeHeight + 4;

    [_codeCaption setFrame:CGRectMake(20, y, width, captionHeight)];
    [_codeCaption setHidden:([[_code text] length] == 0)];

    y += captionHeight + 20;

    CGFloat buttonWidth = MAX(YTLoginButtonWidth, 0);

    CGRect button = CGRectMake((bounds.size.width - buttonWidth) / 2, y,
                               buttonWidth, YTLoginButtonHeight);

    [_refreshFill setFrame:button];
    [_refresh setFrame:button];

    [[_refresh layer] setBorderColor:[[YTTheme divider] CGColor]];

    y += YTLoginButtonHeight + 12;

    // Две надписи в один ряд: каждой по половине ширины.
    CGFloat half = width / 2;

    [_settings setFrame:CGRectMake(20, y, half, YTLoginAboutHeight)];
    [_about setFrame:CGRectMake(20 + half, y, half, YTLoginAboutHeight)];

    [_settings setTitleColor:[YTTheme mutedText] forState:UIControlStateNormal];
    [_about setTitleColor:[YTTheme mutedText] forState:UIControlStateNormal];
}

@end
