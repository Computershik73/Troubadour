#!/bin/sh
#
# Нарезает статические начертания Roboto из вариативного файла UWP-версии.
#
# Зачем. В UWP шрифт подключён как `/Assets/Roboto.ttf#Roboto` и назначен
# сразу всем TextBlock, TextBox и Button — то есть весь текст в приложении
# набран им. Файл там один, и внутри него **вариативный** шрифт: рядом
# с обычными таблицами лежат `fvar`, `gvar`, `avar`, `HVAR` и `STAT`, а сами
# начертания получаются не выбором из набора, а положением на осях `wght`
# и `wdth`. Windows это умеет, поэтому одного файла ей хватает на всё —
# и на Regular в подписях, и на Medium в названиях роликов, и на SemiBold
# в заголовках.
#
# iOS такого не умеет ни в одной версии, до которой мы опускаемся: поддержка
# вариативных шрифтов появилась много позже нашего диапазона. Положить файл
# как есть можно — он зарегистрируется, — но система возьмёт из него одно
# начертание по умолчанию (`wght=400`), и весь текст станет обычной
# насыщенности. Названия роликов и заголовки разделов перестали бы отличаться
# от подписей, а это заметная часть того, как оригинал выглядит.
#
# Поэтому нужные положения на оси выпекаются в отдельные файлы заранее —
# ровно те четыре, что встречаются в разметке UWP:
#
#     400  Regular   — подписи, метаданные, описание
#     500  Medium    — названия роликов в карточках («FontWeight="Medium"»)
#     600  SemiBold  — заголовки разделов и «таблетки» категорий
#     700  Bold      — название на странице видео
#
# `--update-name-table` берёт имена начертаний из таблицы `STAT` самого
# шрифта, а не выдумывает их: получаются семейства «Roboto», «Roboto Medium»,
# «Roboto SemiBold» — под этими именами их и спрашивает YTMetrics.
#
# Запускать один раз; результат лежит в Resources/Assets и участвует в сборке
# как обычные файлы. Нужен fontTools (`apt install python3-fonttools`).

set -e

here=$(cd "$(dirname "$0")" && pwd)
assets="$here/../Resources/Assets"
source="$assets/Roboto.ttf"

if [ ! -f "$source" ]; then
	echo "Не найден $source — сначала tools/import-assets.ps1" >&2
	exit 1
fi

if ! python3 -c "import fontTools" 2>/dev/null; then
	echo "Нужен fontTools: sudo apt-get install -y python3-fonttools" >&2
	exit 1
fi

# Ось ширины прижимается к 100 у всех четырёх: узкие начертания в разметке
# UWP не встречаются, а оставленная свободной ось не даёт статического файла.
for weight in 400 500 600 700; do
	case $weight in
		400) name="Roboto-Regular"  ;;
		500) name="Roboto-Medium"   ;;
		600) name="Roboto-SemiBold" ;;
		700) name="Roboto-Bold"     ;;
	esac

	python3 -m fontTools.varLib.instancer \
		"$source" "wght=$weight" "wdth=100" \
		--update-name-table \
		-o "$assets/$name.ttf"

	echo "$name.ttf"
done

# Сам вариативный файл в связке не нужен: он вчетверо тяжелее любого
# из выпеченных и на устройстве всё равно даст только Regular.
rm -f "$source"

echo "Готово. Не забыть про UIAppFonts в Resources/Info.plist."
