# QuickJS

Движок JavaScript Фабриса Беллара — https://github.com/bellard/quickjs,
коммит `19d6bd865e709e2b5717fb4f2290c0cecc57ee4b` (26.10.2026, версия
2026-06-04). Лицензия MIT — файл `LICENSE` рядом.

Взято только ядро: `quickjs.c`, `cutils.c`, `dtoa.c`, `libregexp.c`,
`libunicode.c` и их заголовки. Без `quickjs-libc` (файлы, ОС, таймеры
не нужны) и без Intl и Temporal (`CONFIG_TEMPORAL_INTL` не задан).

## Зачем

Решатель `n` (`Resources/nsig.js`) исполняет скрипт плеера целиком.
В JavaScriptCore iOS 5/6 его куча после выгрузки так и остаётся у процесса:
на iPad 2 из 31 МБ возвращались 5. QuickJS принимает свои функции
выделения памяти, и `YTQuickJS` даёт ему отдельную зону malloc: после
расчёта зона уничтожается целиком, и система получает назад всё.

## Изменения

- `quickjs.c`: `CONFIG_ATOMICS` выключается ключом `YT_QJS_NO_ATOMICS`
  (Atomics решателю не нужны, а C11-атомики на iOS 5 armv7 — лишний риск);
  вызов `js_atomics_free_waiters` в `JS_FreeRuntime` взят под тот же ключ —
  без Atomics этой функции нет, и сборка не линкуется.
- `quickjs.h`: на iOS доли больших чисел по 32 бита и на arm64 — в SDK сборки
  нет `__udivti3`, которым компилятор делит 128-битные числа.

Ключи сборки — в `Makefile` (`src/quickjs/*.c_CFLAGS`).
