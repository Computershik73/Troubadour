# Переносит значки из UWP-версии в связку приложения.
#
# Зачем вообще перенос, а не отрисовка фигурами: требование к порту —
# дизайн должен совпадать с оригиналом в точности, а самый надёжный способ
# получить тот же значок — взять тот же файл. В UWP они лежат в двух наборах,
# Dark и Light, и различаются цветом глифа (белый и чёрный); выбор набора
# делает ThemeAsset.Path. Здесь то же самое делает YTAsset.
#
# Уменьшать приходится: в оригинале значки лежат по 400–512 точек в стороне,
# потому что UWP масштабирует их сам под плотность экрана. iOS выбирает
# готовый файл по суффиксу — @2x, @3x, — и класть в связку полтысячи точек
# ради значка в 24 значило бы держать в памяти в четыреста раз больше, чем
# нужно. На iPhone 4 это заметно.
#
# Скрипт идемпотентный: повторный запуск просто перезаписывает файлы.
# Запускать из Windows (в WSL нет System.Drawing) один раз, результат
# лежит в Resources/Assets и в сборке уже участвует как есть.

Add-Type -AssemblyName System.Drawing

$src = Join-Path $PSScriptRoot "..\..\youtube_uwp\YouTube\Assets"
$dst = Join-Path $PSScriptRoot "..\Resources\Assets"

if (-not (Test-Path $src)) { throw "Не найден каталог значков UWP: $src" }
New-Item -ItemType Directory -Force -Path $dst | Out-Null

# Что переносим и в какой точечный размер. Размеры взяты из XAML: Width/Height
# у Image в Tabbar.xaml, Navbar.xaml, Video.xaml и CustomVideoPlayer.xaml.
$icons = @(
    @{ src = "tabbar\home-icon.png";          name = "tab_home";        size = 24 },
    @{ src = "tabbar\home-icon-active.png";   name = "tab_home_on";     size = 24 },
    @{ src = "tabbar\shorts-icon.png";        name = "tab_shorts";      size = 24 },
    @{ src = "tabbar\shorts-icon-active.png"; name = "tab_shorts_on";   size = 24 },
    @{ src = "tabbar\sub-icon.png";           name = "tab_subs";        size = 24 },
    @{ src = "tabbar\sub-icon-active.png";    name = "tab_subs_on";     size = 24 },
    @{ src = "tabbar\user-icon.png";          name = "tab_you";         size = 24 },
    @{ src = "tabbar\user-icon-active.png";   name = "tab_you_on";      size = 24 },

    @{ src = "search.png";                    name = "search";          size = 24 },
    @{ src = "notifications.png";             name = "notifications";   size = 24 },
    @{ src = "all_notifications.png";         name = "notifications_all"; size = 24 },
    @{ src = "none_notifications.png";        name = "notifications_none"; size = 24 },
    @{ src = "share.png";                     name = "share";           size = 20 },
    @{ src = "more.png";                      name = "more";            size = 24 },
    @{ src = "down_arrow.png";                name = "down_arrow";      size = 16 },
    @{ src = "microphone.png";                name = "microphone";      size = 22 },
    @{ src = "copy.png";                      name = "copy";            size = 22 },
    @{ src = "link.png";                      name = "link";            size = 22 },
    @{ src = "info.png";                      name = "info";            size = 22 },
    @{ src = "languages.png";                 name = "languages";       size = 22 },
    @{ src = "theme.png";                     name = "theme";           size = 22 },
    @{ src = "log_out.png";                   name = "log_out";         size = 22 },
    @{ src = "unsubscribe.png";               name = "unsubscribe";     size = 22 },
    @{ src = "qr.png";                        name = "qr";              size = 22 },

    @{ src = "player\play.png";               name = "pl_play";         size = 48 },
    @{ src = "player\pause.png";              name = "pl_pause";        size = 48 },
    @{ src = "player\replay.png";             name = "pl_replay";       size = 48 },
    @{ src = "player\back.png";               name = "pl_back";         size = 36 },
    @{ src = "player\skip.png";               name = "pl_skip";         size = 36 },
    @{ src = "player\fullscreen.png";         name = "pl_fullscreen";   size = 24 },
    @{ src = "player\exit_fullscreen.png";    name = "pl_exit_fullscreen"; size = 24 },
    @{ src = "player\settings.png";           name = "pl_settings";     size = 24 },
    @{ src = "player\quality.png";            name = "pl_quality";      size = 24 },
    @{ src = "player\speed.png";              name = "pl_speed";        size = 24 },
    @{ src = "player\down_arrow.png";         name = "pl_collapse";     size = 24 },
    @{ src = "player\like.png";               name = "pl_like";         size = 22 },
    @{ src = "player\like_clicked.png";       name = "pl_like_on";      size = 22 },
    @{ src = "player\dislike.png";            name = "pl_dislike";      size = 22 },
    @{ src = "player\dislike_clicked.png";    name = "pl_dislike_on";   size = 22 },
    @{ src = "player\comments.png";           name = "pl_comments";     size = 22 },
    @{ src = "player\send.png";               name = "pl_send";         size = 22 },
    @{ src = "player\reload.png";             name = "pl_reload";       size = 24 },
    @{ src = "player\download.png";           name = "pl_download";     size = 24 },

    # Затемнение под нижним рядом пульта. В оригинале это картинка
    # (`Assets/player/bg.png`), растянутая на всю ширину полосы: сверху
    # прозрачная, книзу почти чёрная. Растягивается она всё равно, поэтому
    # квадратная копия годится — по вертикали переход сохраняется.
    @{ src = "player\bg.png";                 name = "pl_scrim";        size = 96 }
)

# Карточка-заглушка ленты. В оригинале это `Assets/yt_skeleton/video.png`,
# растянутый по ширине карточки: серые прямоугольники на месте превью,
# кружка канала и двух подписей. Показывается, пока лента не пришла —
# и остаётся, если она пришла пустой.
$skeletons = @(
    @{ src = "yt_skeleton\video.png"; name = "skeleton_video"; width = 360 }
)

# Словесный знак: у него своя пропорция (433x130), поэтому задаётся высотой.
$wordmarks = @(
    @{ src = "ytlogo.png"; name = "ytlogo"; height = 32 }
)

# Общие для обеих тем — они не глифы, а картинки.
$shared = @(
    @{ src = "failed_loading.png"; name = "failed_loading"; size = 170 },
    @{ src = "none_search.png";    name = "none_search";    size = 170 },
    @{ src = "placeholder.png";    name = "placeholder";     width = 320; height = 180 }
)

function Save-Scaled($sourcePath, $targetPath, $width, $height) {
    $image = [System.Drawing.Image]::FromFile($sourcePath)
    try {
        $bitmap = New-Object System.Drawing.Bitmap $width, $height
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                $graphics.Clear([System.Drawing.Color]::Transparent)
                $graphics.DrawImage($image, 0, 0, $width, $height)
            } finally { $graphics.Dispose() }
            $bitmap.Save($targetPath, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally { $bitmap.Dispose() }
    } finally { $image.Dispose() }
}

# Суффиксы iOS: без суффикса — @1x, дальше @2x и @3x. Тройная плотность
# нужна только Plus-моделям, но лишний файл дешевле, чем мыло на них.
$scales = @( @{ suffix = ""; factor = 1 }, @{ suffix = "@2x"; factor = 2 }, @{ suffix = "@3x"; factor = 3 } )

$made = 0

foreach ($theme in @("Dark", "Light")) {
    # Имя набора в связке — суффикс _dark / _light: подкаталогов у ресурсов
    # приложения нет, imageNamed: ищет по плоскому имени.
    $suffixTheme = if ($theme -eq "Dark") { "_dark" } else { "_light" }

    foreach ($icon in $icons) {
        $from = Join-Path $src (Join-Path $theme $icon.src)
        if (-not (Test-Path $from)) { Write-Warning "нет файла: $from"; continue }

        foreach ($scale in $scales) {
            $side = [int]($icon.size * $scale.factor)
            $to = Join-Path $dst ("{0}{1}{2}.png" -f $icon.name, $suffixTheme, $scale.suffix)
            Save-Scaled $from $to $side $side
            $made++
        }
    }

    foreach ($mark in $skeletons) {
        $from = Join-Path $src (Join-Path $theme $mark.src)
        if (-not (Test-Path $from)) { Write-Warning "нет файла: $from"; continue }

        $image = [System.Drawing.Image]::FromFile($from)
        $ratio = $image.Height / $image.Width
        $image.Dispose()

        foreach ($scale in $scales) {
            $w = [int]($mark.width * $scale.factor)
            $h = [int][Math]::Round($w * $ratio)
            $to = Join-Path $dst ("{0}{1}{2}.png" -f $mark.name, $suffixTheme, $scale.suffix)
            Save-Scaled $from $to $w $h
            $made++
        }
    }

    foreach ($mark in $wordmarks) {
        $from = Join-Path $src (Join-Path $theme $mark.src)
        if (-not (Test-Path $from)) { Write-Warning "нет файла: $from"; continue }

        $image = [System.Drawing.Image]::FromFile($from)
        $ratio = $image.Width / $image.Height
        $image.Dispose()

        foreach ($scale in $scales) {
            $h = [int]($mark.height * $scale.factor)
            $w = [int][Math]::Round($h * $ratio)
            $to = Join-Path $dst ("{0}{1}{2}.png" -f $mark.name, $suffixTheme, $scale.suffix)
            Save-Scaled $from $to $w $h
            $made++
        }
    }
}

foreach ($item in $shared) {
    $from = Join-Path $src $item.src
    if (-not (Test-Path $from)) { Write-Warning "нет файла: $from"; continue }

    foreach ($scale in $scales) {
        if ($item.ContainsKey("width")) {
            $w = [int]($item.width * $scale.factor)
            $h = [int]($item.height * $scale.factor)
        } else {
            $w = [int]($item.size * $scale.factor)
            $h = $w
        }
        $to = Join-Path $dst ("{0}{1}.png" -f $item.name, $scale.suffix)
        Save-Scaled $from $to $w $h
        $made++
    }
}

# Шрифт. В UWP он подключён как /Assets/Roboto.ttf#Roboto и назначен всем
# TextBlock, TextBox и Button разом — то есть весь текст в приложении набран
# им. Системного Roboto в iOS нет ни в одной версии, поэтому файл едет
# в связку и объявляется в Info.plist через UIAppFonts.
$font = Join-Path $src "Roboto.ttf"
if (Test-Path $font) {
    Copy-Item $font (Join-Path $dst "Roboto.ttf") -Force
    $made++
} else {
    Write-Warning "нет Roboto.ttf — текст будет набран системным шрифтом"
}

Write-Host "Готово: $made файлов в $dst"
