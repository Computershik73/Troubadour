#!/bin/sh
# Заплатки к iPhoneOS9.3.sdk из github.com/theos/sdks.
#
# В этом наборе .tbd перегенерированы, а не взяты у Apple, и при перегенерации
# потерялась часть символов. Пока в проекте не было ничего, кроме пустого
# UIViewController, это не замечалось; по мере роста кода вылезает по очереди:
#
#   1. Нет usr/lib/system/liblaunch.tbd, хотя libSystem.tbd реэкспортирует
#      /usr/lib/system/liblaunch.dylib. ld идёт по списку реэкспорта и падает:
#      «file not found: /usr/lib/system/liblaunch.dylib». На самой iOS
#      liblaunch давно слита с libxpc и своих символов не имеет, поэтому
#      пустой заглушки хватает: ld нужен сам файл, а не его содержимое.
#
#   2. В libsystem_c.tbd потеряно семейство memset/memcpy/memmove/memcmp.
#      Физически на iOS 7+ они лежат в libsystem_platform и попадают наружу
#      реэкспортом. На arm64 промаха не видно — clang разворачивает мелкие
#      копирования на месте, вызова не возникает; на armv7 линковка встаёт.
#
#      Дописываем их именно в libsystem_c: эта библиотека есть и на iOS 5.1,
#      и на современных, и на 5.1 memset лежит ровно в ней. Если записать их
#      в libsystem_platform, ld при двухуровневом пространстве имён пропишет
#      источником libsystem_platform.dylib — а его на iOS 5.1 ещё нет.
#
#   3. В libunwind.tbd есть только SjLj-варианты раскрутки стека (их использует
#      armv7) и нет обычных DWARF (их использует arm64). Всплывает на первом же
#      @synchronized или @try: там компилятор ставит вызов _Unwind_Resume.
#
#   4. Четвёртая заплатка не про потерянный символ, а про лишний.
#
#      libobjc.tbd честно объявляет _OBJC_CLASS_$_NSObject: в iOS 9.3 класс
#      и правда лежит там. Но переехал он в libobjc только в iOS 6 — до неё
#      NSObject живёт в CoreFoundation. Компоновщик записывает источником
#      libobjc, а двухуровневые имена означают, что dyld ищет символ ровно
#      в названной библиотеке. На iPad 1 с iOS 5.1.1 он его там не находит
#      и отказывает целиком, ещё до main:
#
#        Symbol not found: _OBJC_CLASS_$_NSObject
#        Expected in: /usr/lib/libobjc.A.dylib
#
#      Убираем обе записи — класса и метакласса. Тогда компоновщик не может
#      привязать их к библиотеке, а -U в Makefile разрешает оставить их
#      неразрешёнными: такие символы dyld ищет во всём, что загружено,
#      и находит там, где они есть на этой версии системы.
#
#      Дописать их в CoreFoundation.tbd было бы проще, но это потребовало бы
#      знать наперёд, отдаёт ли их CoreFoundation на iOS 9. Поиск по всем
#      библиотекам знать этого не требует.
#
# Символы дописываются отдельным блоком exports — ld не возражает против
# нескольких блоков с одинаковым набором архитектур.
#
# Запускать один раз после установки SDK:
#   sh tools/patch-sdk.sh
set -e

SDK="${THEOS:-$HOME/theos}/sdks/iPhoneOS9.3.sdk"
ARCHS="[ armv7, armv7s, arm64, i386, x86_64 ]"

if [ ! -d "$SDK" ]; then
	echo "Нет $SDK — сначала поставьте SDK, см. README" >&2
	exit 1
fi

# ensure <файл tbd> <имена как в C...>
#
# В .tbd символы записаны так, как их видит компоновщик, то есть с ведущим
# подчёркиванием: функция C memset попадает туда как _memset, а функция
# _Unwind_Resume — как __Unwind_Resume. Поэтому здесь передаются имена как в
# исходниках C, а подчёркивание дописывается само.
#
# Проверяем по границам слова: в libsystem_c уже есть __platform_memset и
# _memset_chk, а в libunwind — __Unwind_SjLj_Resume, и простой поиск подстроки
# на них ложно срабатывает.
ensure() {
	file="$1"
	shift

	if [ ! -f "$file" ]; then
		echo "Нет $file — пропускаю" >&2
		return 0
	fi

	missing=""
	for sym in "$@"; do
		if grep -qE "(^|[^_A-Za-z0-9])_$sym([,]|[[:space:]]|\])" "$file"; then
			continue
		fi
		missing="$missing _$sym,"
	done

	if [ -z "$missing" ]; then
		echo "$(basename "$file"): всё на месте"
		return 0
	fi

	syms=$(echo "$missing" | sed 's/,$//; s/^ //')

	tmp=$(mktemp)
	sed '$ d' "$file" > "$tmp"          # снимаем последнюю строку «...»
	cat >> "$tmp" <<EOF
  - archs:              $ARCHS
    symbols:            [ $syms ]
...
EOF
	mv "$tmp" "$file"

	echo "$(basename "$file"): дописаны$missing"
}

# --- 1. Заглушка liblaunch ---------------------------------------------------

STUB="$SDK/usr/lib/system/liblaunch.tbd"

if [ -f "$STUB" ]; then
	echo "liblaunch.tbd уже на месте"
else
	cat > "$STUB" <<EOF
---
archs:                 $ARCHS
platform:              ios
install-name:          /usr/lib/system/liblaunch.dylib
current-version:       1
compatibility-version: 1
exports:
  - archs:              $ARCHS
    symbols:            [ ___liblaunch_stub ]
...
EOF
	echo "Создана заглушка liblaunch.tbd"
fi

# --- 2. Память и строки ------------------------------------------------------

ensure "$SDK/usr/lib/system/libsystem_c.tbd" \
	memset memcpy memmove memcmp memchr bzero \
	memset_pattern4 memset_pattern8 memset_pattern16

# --- 3. Раскрутка стека ------------------------------------------------------

ensure "$SDK/usr/lib/system/libunwind.tbd" \
	_Unwind_Resume _Unwind_Resume_or_Rethrow _Unwind_RaiseException \
	_Unwind_Backtrace _Unwind_FindEnclosingFunction

# --- 4. NSObject: снять привязку к libobjc -----------------------------------
#
# Готовых символов _OBJC_CLASS_$_… в .tbd нет: класс объявлен строкой
#
#   objc-classes:       [ _NSObject, _Object, _Protocol, … ]
#
# а пару «класс и метакласс» компоновщик выводит из неё сам. Значит,
# и убирать надо оттуда.
#
# Границы слова обязательны: рядом в том же списке лежит _Object, и простой
# поиск подстроки задел бы его.
unbind_class() {
	file="$1"
	name="$2"

	if [ ! -f "$file" ]; then
		echo "Нет $file — пропускаем" >&2
		return
	fi

	if ! grep -q "objc-classes:.*\\b_$name\\b" "$file"; then
		echo "  $name уже не значится в $(basename "$file")"
		return
	fi

	sed -i "/objc-classes:/ {
		s/\\b_$name\\b, //
		s/, \\b_$name\\b//
		s/\\b_$name\\b//
	}" "$file"

	echo "  $name откреплён от $(basename "$file")"
}

for tbd in "$SDK/usr/lib/libobjc.tbd" "$SDK/usr/lib/libobjc.A.tbd"; do
	unbind_class "$tbd" NSObject
done
