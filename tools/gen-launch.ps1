# Рисует картинки запуска и значки приложения.
#
# Картинка запуска — не украшение, а **объявление поддерживаемого экрана.**
# По наличию файла нужного размера iOS решает, умеет ли приложение работать
# на этом дисплее. Без `Default-568h@2x.png` четырёхдюймовый iPhone SE
# запускает приложение в рамке 320×480: сверху и снизу остаются чёрные
# полосы по 44 точки, а вся раскладка считается для чужого размера. Ровно
# это и выглядело как «приложение не адаптируется под экран».
#
# Понятия «объявить экран картинкой» в UWP нет вовсе, поэтому при переносе
# взяться этим файлам было неоткуда — в исходном проекте им нет соответствия.
#
# Современные iPhone (X и новее) объявить картинкой уже нельзя: там нужен
# либо launch storyboard (несовместим с iOS 5.1 и требует ibtool, которого
# в Theos под Linux нет), либо ключ `UILaunchScreen` — он появился в iOS 14
# и задаётся прямо в Info.plist, без единого файла. Второе и сделано: старые
# системы ключа не понимают и берут картинки, новые понимают и берут ключ.
#
# Запускать из Windows (в WSL нет System.Drawing); повторный запуск просто
# перезаписывает файлы.

Add-Type -AssemblyName System.Drawing

$assets = Join-Path $PSScriptRoot "..\Resources\Assets"
$out = Join-Path $PSScriptRoot "..\Resources"

# Фон — `AppBackgroundColor` тёмной темы из App.xaml. Приложение по умолчанию
# тёмное, и светлая заставка перед тёмным экраном мигала бы белым.
$background = [System.Drawing.Color]::FromArgb(255, 15, 15, 15)

$logoPath = Join-Path $assets "ytlogo_dark@3x.png"

if (-not (Test-Path $logoPath)) { throw "Не найден $logoPath — сначала tools/import-assets.ps1" }

$logo = [System.Drawing.Image]::FromFile($logoPath)
$logoRatio = $logo.Width / $logo.Height

# Классические имена: их читают iOS 5 и 6, где списка UILaunchImages ещё нет.
# Список в Info.plist — для iOS 7 и новее.
$screens = @(
    @{ name = "Default";                    w = 320;  h = 480  },
    @{ name = "Default@2x";                 w = 640;  h = 960  },
    @{ name = "Default-568h@2x";            w = 640;  h = 1136 },
    @{ name = "Default-667h@2x";            w = 750;  h = 1334 },
    @{ name = "Default-736h@3x";            w = 1242; h = 2208 },
    @{ name = "Default-Portrait~ipad";      w = 768;  h = 1024 },
    @{ name = "Default-Portrait@2x~ipad";   w = 1536; h = 2048 },
    @{ name = "Default-Landscape~ipad";     w = 1024; h = 768  },
    @{ name = "Default-Landscape@2x~ipad";  w = 2048; h = 1536 }
)

# Значки. Углы скругляет сама система, поэтому рисуем прямоугольник.
$icons = @(57, 72, 76, 114, 120, 144, 152, 180)

function New-Canvas($width, $height, $logoFraction) {
    $bitmap = New-Object System.Drawing.Bitmap $width, $height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

    try {
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.Clear($background)

        $logoWidth = [int]($width * $logoFraction)
        $logoHeight = [int]($logoWidth / $logoRatio)

        $x = [int](($width - $logoWidth) / 2)
        $y = [int](($height - $logoHeight) / 2)

        $graphics.DrawImage($logo, $x, $y, $logoWidth, $logoHeight)
    } finally {
        $graphics.Dispose()
    }

    return $bitmap
}

foreach ($screen in $screens) {
    $bitmap = New-Canvas $screen.w $screen.h 0.55
    $bitmap.Save((Join-Path $out ($screen.name + ".png")), [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}

foreach ($side in $icons) {
    # У значка знак крупнее: там нет свободного места по краям.
    $bitmap = New-Canvas $side $side 0.82
    $bitmap.Save((Join-Path $out ("Icon-" + $side + ".png")), [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}

$logo.Dispose()

Write-Host ("Готово: " + ($screens.Count + $icons.Count) + " файлов в " + $out)
