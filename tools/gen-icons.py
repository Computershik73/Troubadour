# -*- coding: utf-8 -*-
"""
Рисует значок «Трубадура» и раскладывает его по размерам, которые нужны iOS.

Родство с «Трубачом» намеренное: та же фигура — труба, повёрнутая раструбом
вверх-вправо, — и та же геометрия, вплоть до чисел. Приложения из одной
семьи и должны узнаваться как родня.

Отличие в палитре, и оно здесь главное. У «Трубача» плитка тёмно-фиолетовая
с красным пятном в углу; у нас цвета YouTube и ничего больше: красная плитка
#FF0000 и белая труба. Пятно в углу осталось на месте, но стало тёмно-красным
#CC0000 — на красном оно читается как тень, а не как вторая фигура.

Отдельно про раструб. У «Трубача» в жерле белый треугольник на цвете плитки —
то есть у нас он выходит белым на красном, ровно так же, как в значке самого
YouTube. Ничего подгонять для этого не пришлось: так легли краски.

Что не делаем:

* не скругляем углы — их обрезает сама система, вышел бы двойной радиус;
* не рисуем блик — в Info.plist стоит UIPrerenderedIcon;
* не делаем адаптивный значок — у iOS нет оболочек, двигающих слои.

Размеры не по плотностям, а по устройствам: 57 и 114 — iPhone до iOS 7,
120 — iPhone с iOS 7, 72 и 144 — iPad, 76 и 152 — iPad с iOS 7, 180 — Plus.
Всё перечислено в CFBundleIconFiles.

Рисуется вчетверо крупнее и уменьшается: у PIL нет сглаживания фигур,
и без этого края выходят рваными.

    python tools/gen-icons.py
"""
import math
import os

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(ROOT, "Resources")

RED = (255, 0, 0, 255)         # #FF0000 — красный YouTube, фон плитки
DEEP = (204, 0, 0, 255)        # #CC0000 — тень в углу, тот же красный темнее
WHITE = (255, 255, 255, 255)
CLEAR = (0, 0, 0, 0)

SIZES = [57, 72, 76, 114, 120, 144, 152, 180]

# Экраны запуска.
#
# Это не украшение: по наличию картинки нужного размера iOS решает, умеет ли
# приложение работать на этом экране. Без Default-568h@2x на iPhone 5 оно
# запускается в 320x480 — с чёрными полосами сверху и снизу.
LAUNCH = [
    ("Default.png", 320, 480),              # 3,5 дюйма, без ретины
    ("Default@2x.png", 640, 960),           # iPhone 4 и 4S
    ("Default-568h@2x.png", 640, 1136),     # iPhone 5, 5s, SE
    ("Default-667h@2x.png", 750, 1334),     # iPhone 6, 7, 8
    ("Default-736h@3x.png", 1242, 2208),    # iPhone 6 Plus и новее
    ("Default-Portrait~ipad.png", 768, 1024),
    ("Default-Portrait@2x~ipad.png", 1536, 2048),
    ("Default-Landscape~ipad.png", 1024, 768),
    ("Default-Landscape@2x~ipad.png", 2048, 1536),
]

SCALE = 4

# Наклон трубы и её доля от стороны значка: раструб смотрит в тёмное пятно.
ANGLE = 45
FIGURE = 0.82

# Центр жерла у горизонтальной трубы, в сотых долях стороны.
MOUTH = (87.0, 50.0)

# Пятно строится от жерла: центр уносится вдоль оси трубы на CIRCLE_FAR долей
# стороны, радиус берётся чуть больше — на CIRCLE_BITE, поэтому граница
# проходит внутри раструба и труба на пятно налезает.
CIRCLE_FAR = 0.55
CIRCLE_BITE = 0.04


def horizontal(big, depth):
    """
    Труба вдоль оси X на прозрачном холсте. depth — цвет глубины жерла
    и прорези вентиля: это фон плитки.
    """
    layer = Image.new("RGBA", (big, big), CLEAR)
    draw = ImageDraw.Draw(layer)
    u = big / 100.0

    def p(x, y):
        return (x * u, y * u)

    # Мундштук и трубка.
    draw.ellipse([p(4, 43), p(18, 57)], fill=WHITE)
    draw.rounded_rectangle([p(12, 45.5), p(58, 54.5)], radius=int(4 * u), fill=WHITE)

    # Вентиль поперёк трубки, с прорезью.
    draw.rounded_rectangle([p(30, 37), p(48, 63)], radius=int(5 * u), fill=WHITE)
    draw.rounded_rectangle([p(34.5, 41.5), p(43.5, 58.5)], radius=int(4 * u), fill=depth)

    # Раструб: радиус растёт степенью, оттого профиль вогнутый. Прямой конус
    # выглядел бы мегафоном.
    steps = 28
    top, bottom = [], []
    for i in range(steps + 1):
        t = i / float(steps)
        x = 56 + (86 - 56) * t
        r = 5 + (29 - 5) * (t ** 2.3)

        top.append(p(x, 50 - r))
        bottom.append(p(x, 50 + r))

    draw.polygon(top + bottom[::-1], fill=WHITE)

    # Жерло: белый ободок, красная глубина и белый треугольник внутри —
    # то самое место, где значок совпадает со значком YouTube.
    draw.ellipse([p(78, 20), p(96, 80)], fill=WHITE)
    draw.ellipse([p(80.4, 27), p(93.6, 73)], fill=depth)
    draw.polygon([p(83, 38), p(83, 62), p(91, 50)], fill=WHITE)

    return layer


def figure(big, depth, scale=FIGURE):
    """Та же труба, повёрнутая раструбом вверх-вправо и вписанная в холст."""
    layer = horizontal(big, depth).rotate(ANGLE, resample=Image.BICUBIC, expand=False)

    side = max(1, int(big * scale))
    layer = layer.resize((side, side), Image.LANCZOS)

    canvas = Image.new("RGBA", (big, big), CLEAR)
    canvas.paste(layer, ((big - side) // 2, (big - side) // 2), layer)

    return canvas


def mouth_centre(big, scale):
    """Куда уезжает центр жерла после поворота и уменьшения."""
    u = big / 100.0
    centre = big / 2.0

    dx, dy = MOUTH[0] * u - centre, MOUTH[1] * u - centre
    angle = math.radians(ANGLE)

    x = centre + (dx * math.cos(angle) + dy * math.sin(angle)) * scale
    y = centre + (-dx * math.sin(angle) + dy * math.cos(angle)) * scale

    return x, y


def circle_box(big, scale):
    """
    Тёмное пятно: центр далеко за жерлом по оси трубы, радиус чуть больше
    расстояния до него. Получается широкая дуга — она заливает верхний правый
    угол и подходит вплотную к раструбу.
    """
    x, y = mouth_centre(big, scale)

    far = big * CIRCLE_FAR
    radius = far + big * CIRCLE_BITE

    step = far * math.sqrt(0.5)
    cx, cy = x + step, y - step

    return [cx - radius, cy - radius, cx + radius, cy + radius]


def tile(size):
    """Прямоугольная плитка с тенью в углу и трубой. Углы скругляет система."""
    big = size * SCALE

    image = Image.new("RGBA", (big, big), RED)
    ImageDraw.Draw(image).ellipse(circle_box(big, FIGURE), fill=DEEP)

    # Глубина жерла — цвета плитки, а не тени: треугольник должен лежать
    # на ровном красном, как в значке YouTube.
    image = Image.alpha_composite(image, figure(big, RED))

    return image.resize((size, size), Image.LANCZOS)


def launch(width, height):
    """
    Экран запуска: красное поле и труба по центру.

    Пятна здесь нет намеренно — оно строится от угла значка, а на вытянутом
    экране угол далеко, и дуга превратилась бы в полосу поперёк.
    """
    image = Image.new("RGBA", (width, height), RED)

    side = int(min(width, height) * 0.34)
    mark = figure(side * SCALE, RED).resize((side, side), Image.LANCZOS)

    image.paste(mark, ((width - side) // 2, (height - side) // 2), mark)

    return image.convert("RGB")


if __name__ == "__main__":
    if not os.path.isdir(RESOURCES):
        os.makedirs(RESOURCES)

    for size in SIZES:
        name = "Icon-%d.png" % size
        path = os.path.join(RESOURCES, name)

        # iOS не любит альфу в значке: прозрачные места станут чёрными.
        tile(size).convert("RGB").save(path)
        print(name, size)

    for name, width, height in LAUNCH:
        launch(width, height).save(os.path.join(RESOURCES, name))
        print(name, "%dx%d" % (width, height))
