#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Сверяет надписи в коде с таблицами перевода.

Ключ перевода — сама русская строка, поэтому «что нужно перевести»
выводится прямо из исходников: ищем каждый вызов YTLoc и YTLocF и
собираем его первый довод, склеивая соседние литералы так же, как это
делает компилятор.

Запуск:

    python3 tools/check-strings.py           перечень недостающего
    python3 tools/check-strings.py --json    то же в виде заготовки

Пустой вывод и «Всё на месте» означают, что каждая надпись переведена
на все языки, а лишних ключей в таблицах нет.
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANGS = os.path.join(ROOT, 'Resources', 'lang')

# Литерал вида @"…" с учётом экранированных кавычек.
PIECE = re.compile(r'@"((?:[^"\\]|\\.)*)"')

CALL = re.compile(r'\bYTLocF?\s*\(')

# Подстановки вида %@, %ld, %.2f — переведённая строка сама становится
# образцом для форматирования, и лишняя или иная подстановка означает
# не кривой перевод, а падение на ровном месте.
#
# `%2$ld` — та же подстановка, но с указанием, какой по счёту довод брать.
# Без неё перевод, которому нужен другой порядок слов, пришлось бы писать
# с переставленными подстановками — и числа поменялись бы местами.
SLOT = re.compile(r'%(\d+\$)?[0-9.#+ -]*((?:l{1,2}|h{1,2}|z|q)?[@diouxXfegcs%])')


def slots(text):
    """Подстановки строки: (по порядку, с перестановкой или нет)."""
    found = SLOT.findall(text)

    return ([kind for _, kind in found],
            any(position for position, _ in found))


def slots_agree(key, value):
    wanted, _ = slots(key)
    given, moved = slots(value)

    # Перестановка меняет порядок нарочно — тогда важен только состав.
    return sorted(wanted) == sorted(given) if moved else wanted == given


def unescape(text):
    return (text.replace('\\"', '"')
                .replace('\\n', '\n')
                .replace('\\t', '\t')
                .replace('\\\\', '\\'))


def keys_in(source):
    """Первые доводы всех YTLoc/YTLocF в одном файле."""
    found = []

    for call in CALL.finditer(source):
        at = call.end()

        # Склеиваем идущие подряд литералы: перенос строки и отступы
        # между ними компилятор не замечает, и мы не должны.
        parts = []

        while True:
            space = re.compile(r'\s*').match(source, at)
            piece = PIECE.match(source, space.end())

            if piece is None:
                break

            parts.append(unescape(piece.group(1)))
            at = piece.end()

        if parts:
            found.append(''.join(parts))

    return found


def sources():
    for base, _, files in os.walk(os.path.join(ROOT, 'src')):
        for name in files:
            if name.endswith(('.m', '.h')):
                yield os.path.join(base, name)


def main():
    wanted = set()

    for path in sources():
        with open(path, encoding='utf-8') as handle:
            wanted.update(keys_in(handle.read()))

    if not wanted:
        print('Ни одной надписи не нашлось — похоже, сломан разбор')

        return 1

    trouble = False

    for name in sorted(os.listdir(LANGS)):
        if not name.endswith('.json'):
            continue

        with open(os.path.join(LANGS, name), encoding='utf-8') as handle:
            table = json.load(handle)

        missing = sorted(wanted - set(table))
        extra = sorted(set(table) - wanted)

        # Подстановки должны совпасть и числом, и порядком.
        broken = sorted(key for key, value in table.items()
                        if not slots_agree(key, value))

        if not missing and not extra and not broken:
            continue

        trouble = True

        print('%s: надписей %d, не переведено %d, лишних %d, с чужой подстановкой %d'
              % (name, len(wanted), len(missing), len(extra), len(broken)))

        for key in broken:
            print('    подстановка: %s → %s' % (key, table[key]))

        if '--json' in sys.argv:
            print(json.dumps({key: '' for key in missing},
                             ensure_ascii=False, indent=0))
        else:
            for key in missing:
                print('    нет: %s' % key)

            for key in extra:
                print('    лишний: %s' % key)

    if not trouble:
        print('Всё на месте: надписей %d, языков %d'
              % (len(wanted), len(os.listdir(LANGS))))

    return 1 if trouble else 0


if __name__ == '__main__':
    sys.exit(main())
