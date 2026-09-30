# Troubadour

Клиент YouTube для iOS 5.1 и новее. Собирается под armv7 и arm64, так что
работает на iPhone 4, iPad 1 и всём, что вышло после них.

Начинался как порт [youtube_uwp](https://github.com/zemonkamin/youtube_uwp),
клиента для Windows 10 Mobile. Внешний вид и многие решения взяты оттуда,
а дальше приложение развивалось само по себе.

Основа воспроизведения через SABR (`src/player/YTSabr.m`, `YTUmp.m`,
`YTProto.m`) перенесена из TubeReplacer, а многое поверх неё я дописал сам
(что именно — ниже, в «Спасибо»). Когда в мае–июне 2026 года youtube_uwp
сломался и перестал играть видео, воспроизведение там починил тоже я,
а это главная часть клиента YouTube. Оба проекта шли параллельно,
и когда у меня не было времени переносить свои наработки в youtube_uwp,
я отдавал исходники zemonkamin, и он добавлял их туда. Так что часть кода
youtube_uwp пришла отсюда.

## Установка

Готовые пакеты лежат в источнике для Cydia и Sileo:

```
https://computershik73.github.io/repo/
```

Беты, с подробным журналом, здесь:

```
https://computershik73.github.io/repo/beta/
```

Там же есть `.ipa` для установки без джейлбрейка.

## Что умеет

Главная, подписки, Shorts, поиск, каналы, плейлисты и миксы, история,
уведомления. Вход по QR-коду и в браузере, переключение между каналами
одной учётной записи. Лайки, дизлайки (число берётся у Return YouTube
Dislike), подписка, комментарии, «Сохранить» в плейлист.

Ролики до 1080p и 60 кадров, прямые трансляции с чатом, субтитры, главы,
SponsorBlock, мини-плеер, звук в фоне, скачивание роликов. Продолжает с того
места, где остановились.

Встроенный обход блокировок через Cloudflare WARP. Работает внутри
приложения, отдельный VPN не нужен.

Двенадцать языков интерфейса, светлая и тёмная тема, сменные значки.

## Сборка

Нужны WSL2 с Ubuntu и [Theos](https://theos.dev). Используется тулчейн,
который ставит сам Theos.

SDK берётся 9.3: в более новых нет заголовков, нужных для iOS 5.

```bash
git clone --filter=blob:none --sparse --depth 1 https://github.com/theos/sdks.git
cd sdks && git sparse-checkout set iPhoneOS9.3.sdk
mv iPhoneOS9.3.sdk ~/theos/sdks/
```

В `.tbd` из набора Theos не хватает нескольких символов, их дописывает скрипт
(его можно запускать повторно):

```bash
sh tools/patch-sdk.sh
```

Дальше обычная сборка:

```bash
export THEOS=$HOME/theos
make package ipa                  # отладочная, пишет журнал
make package ipa FINALPACKAGE=1   # выпускная, без журнала
```

`.deb` и `.ipa` появляются в `packages/`.

### Ключи WARP

Ключей WARP в репозитории нет. Без них приложение собирается и работает,
а для обхода сразу пробует зарегистрировать свою личность у Cloudflare.
Где регистрацию блокируют (в России так бывает), без ключей обход
не поднимется. Ключи кладутся рядом с образцами:

- `src/warp/AWGSecrets.h` (образец `AWGSecrets.example.h`);
- `Resources/warp_bootstrap.json` и `Resources/warp_verified_seeds.json`
  (образцы `*.example.json`).

Все три файла внесены в `.gitignore`.

## Что где лежит

- `src/net` — InnerTube, вход, HTTP со своими корневыми сертификатами,
  расшифровка `n` и PO-токен;
- `src/player` — воспроизведение: SABR, разбор MP4, перекладка в MPEG-TS
  и локальный HLS-прокси для AVPlayer;
- `src/ui` — экраны;
- `src/warp` — обход блокировок, подробности в `src/warp/NOTICE.md`;
- `Resources` — картинки, шрифты, переводы, сертификаты.

`PORTING.md` — что пригодится при переносе на другую платформу; по нему
делалась версия для Android.

## История

История в git начинается с версии 1.4-168 (11 сентября 2026). Всё, что было
до неё, от 1.0 в августе 2026, делалось без git. Тех шагов здесь нет.

## Спасибо

- [zemonkamin](https://github.com/zemonkamin) за youtube_uwp, с которого всё
  началось;
- [qwertyu1opz](https://github.com/qwertyu1opz) за
  [Dante](https://github.com/qwertyu1opz/Dante), откуда взят код WARP;
- [Preloading](https://github.com/Preloading) за
  [TubeReplacer](https://github.com/Preloading/TubeReplacer), откуда взяты
  основа подачи SABR, описания протокола и получение PO-токена. Поверх этого
  я сам дописал прямые трансляции через SABR, перемотку, смену дорожки
  посреди ролика, запасной путь на случай, когда сервер не отдаёт выбранное
  качество, и сборку запросов без сгенерированных классов protobuf, чтобы
  всё работало на iOS 5. Расшифровку `n` я переделал целиком: в TubeReplacer
  функцию для неё готовит сервер автора (`preloading.dev`), а устройство
  только исполняет присланное. В Troubadour скрипт плеера YouTube целиком
  исполняется на самом устройстве, и нужное преобразование находится там же,
  без сторонних серверов. Перестанет работать чужой сервер — воспроизведение
  у Troubadour от этого не сломается;
- Monocypher (Loup Vaillant), Return YouTube Dislike, SponsorBlock.

## Лицензия

GPL-3.0, полный текст в `LICENSE`. Код Dante в `src/warp` и то, что взято
из youtube_uwp, распространяются на тех же условиях с согласия их авторов.
Код из TubeReplacer сам выпущен под GPL-3.0.

У сторонних частей свои лицензии:

- Monocypher (`src/warp/monocypher.*`): BSD-2-Clause или CC0-1.0;
- шрифт Roboto (`Resources/Assets/Roboto*.ttf`): Apache 2.0;
- набор картинок `Resources/Skins/ios6` под лицензию проекта не подпадает.

## Автор

Computershik: [4PDA](https://4pda.to/forum/index.php?showuser=4458524),
[Telegram](https://t.me/cmplog),
[поддержать](https://pay.cloudtips.ru/p/83821e32).
