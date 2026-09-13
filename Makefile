export THEOS ?= $(HOME)/theos

# 9.3 — последний SDK, где ещё живы заголовки эпохи iOS 5 (MPMoviePlayerController
# и прочее), и в котором есть срез armv7. Нижняя граница 5.1: там уже есть
# TLS 1.2 в Secure Transport, NSJSONSerialization и ARC.
#
# Почему не 4.х: YouTube и googlevideo отвечают только по TLS 1.2 — их фронт
# давно не согласовывает ни SSLv3, ни TLS 1.0. В iOS Secure Transport умеет
# 1.2 начиная с 5.0, в iOS 4 максимум 1.0. То есть на четвёрке приложение
# не сделало бы ни одного запроса, не принеся с собой чужую реализацию TLS.
TARGET := iphone:9.3:5.1

# armv7 покрывает всё от iPhone 3GS до iPhone 5; arm64 — всё, что новее.
ARCHS := armv7 arm64

# dpkg-deb отказывается паковать каталог с правами 777, а именно их выдаёт
# диску Windows подсистема WSL — chmod там ничего не меняет. Поэтому дерево,
# из которого собирается пакет, складывается в файловую систему Linux.
export THEOS_STAGING_DIR ?= /tmp/theos-troubadour/_

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = Troubadour

Troubadour_FILES = $(shell find src -name '*.m')
Troubadour_CFLAGS  = -fobjc-arc -Wall -Wno-deprecated-declarations
Troubadour_CFLAGS += $(addprefix -I,$(shell find src -type d))

# Подменяет NSLog во всех файлах разом: всё, что уходит в системный журнал,
# попадает ещё и в Documents/youtube.log — оттуда его можно просто забрать
# с устройства. Подробности в src/YTLog.h.
Troubadour_CFLAGS += -include src/YTLog.h

# Готовая сборка молчит: ни файла журнала, ни системного журнала.
#
#     make package ipa                 обычная — пишет всё, как раньше
#     make package ipa FINALPACKAGE=1  готовая — вызовы NSLog выброшены
#
# Именно выброшены, а не отключены: строки исчезают на разборе вместе
# со склейкой формата, а её на каждый кусок потока и на каждую картинку
# набегает больше, чем хотелось бы отдавать зря.
ifeq ($(FINALPACKAGE),1)
Troubadour_CFLAGS += -DYT_NO_LOG
endif
Troubadour_CFLAGS += -Wno-unused-variable -fvisibility=hidden

# Отладочная сборка без проверки сертификатов:
#
#     make package INSECURE_TLS=1
#
# Нужна ровно для одного — смотреть трафик перехватчиком (Charles и прочие).
# Тот подменяет сертификат своим, и честная проверка его не пропустит:
# цепочка и правда чужая.
#
# По умолчанию выключено, и «выключено» здесь означает, что кода нет
# в бинарнике вовсе — он выброшен `#ifdef` ещё на разборе. Случайно попасть
# в обычный пакет ему неоткуда.
#
# Более аккуратный путь, если перехватчик нужен надолго: положить его корень
# в Resources/certs/ обычным .der — оттуда берутся все файлы подряд, и
# проверка при этом остаётся включённой.
ifeq ($(INSECURE_TLS),1)
Troubadour_CFLAGS += -DYT_INSECURE_TLS
endif

# CoreText — чтобы спрашивать у системы, есть ли у неё глиф для знака:
# нарисовать то, чего нет ни в одном шрифте, она не умеет и падает.
Troubadour_FRAMEWORKS = UIKit CoreGraphics QuartzCore ImageIO AVFoundation \
                     CoreMedia MediaPlayer Security SystemConfiguration \
                     CoreText

# AVKit — слабо, и только слабо.
#
# Оттуда нужен один класс, AVPictureInPictureController. Сам AVKit появился
# в iOS 8, класс — в iOS 9, а нижняя граница у нас 5.1: на iPhone 4 с iOS 7
# такой библиотеки в системе нет вовсе, и обычная линковка означала бы отказ
# dyld ещё до main. Со слабой отсутствующая библиотека не беда — класс просто
# не находится по имени, и плеер обходится без окна.
Troubadour_LDFLAGS += -weak_framework AVKit

# zlib: ею разворачиваются файлы внутри выбранной человеком темы.
Troubadour_LDFLAGS += -lz

# NSObject ищем по всем библиотекам, а не в той, где он лежит сегодня.
#
# Класс переехал в libobjc только в iOS 6; до неё он живёт в CoreFoundation.
# SDK у нас от 9.3 — по нему компоновщик и записывает «спрашивать в libobjc».
# Двухуровневые имена означают, что dyld ищет символ ровно в названной
# библиотеке и, не найдя, отказывает целиком: приложение умирает до main,
# и это не «падение», а отказ загрузчика — в журнале от него не остаётся
# ничего.
#
# -U снимает привязку к библиотеке ровно для названного символа. Работает
# только вместе с tools/patch-sdk.sh, который убирает _NSObject из
# objc-classes в libobjc.tbd: пока символ в .tbd есть, компоновщик спокойно
# находит его и привязывает как обычно, и -U не делает ничего.
#
# Доллар закрывается дважды: \$$ превращается в \$ на разборе make, а уже \$
# доживает до ld как $ — между ними ещё оболочка, для которой $_NSObject это
# имя переменной. С одинарным экранированием флаг молча уходит в ld пустым.
Troubadour_LDFLAGS += -Wl,-U,_OBJC_CLASS_\$$_NSObject
Troubadour_LDFLAGS += -Wl,-U,_OBJC_METACLASS_\$$_NSObject

# Подпись — обеими сводками сразу, и это принципиально.
#
# ldid по умолчанию кладёт имя «Troubadour.<хеш>.unsigned» вместо имени пакета
# и снимает признак adhoc — то есть заявляет «подпись настоящая, спросите центр
# сертификации», хотя удостоверяющей части в файле нет вовсе. Джейлбрейк iOS 6
# снимал проверку целиком, iOS 8 её разбирает и отказывает молча. Это чинят
# `-Cadhoc` и `-I…`.
#
#   -Cadhoc  признак «подпись сама себе удостоверение» — то, чем она и является;
#   -I…      имя, совпадающее с CFBundleIdentifier, — по нему система сверяет
#            подпись со связкой.
#
# А вот `-Hsha1` здесь стоял и **ломал iOS 11 и 12**. Он оставляет в подписи
# одну сводку SHA-1, и это верно для iOS 8, но с iOS 11 система считает
# cdhash по SHA-256 и подпись без неё не принимает вовсе: приложение
# снимается при запуске, без записи в журнале падений. Снаружи это выглядело
# так, что установка через 3uTools и Sideloadly работает, а через AppSync —
# нет; те два просто переподписывают заново, своим сертификатом и обеими
# сводками.
#
# Без `-H` ldid кладёт обе: SHA-1 в основной слот (0x0000) и SHA-256
# в дополнительный (0x1000). Старая система читает первую и довольна,
# новая берёт лучшую из имеющихся. Одна подпись на весь ряд от iOS 5 до 12 —
# ровно то, что нам и нужно; проверяет это `tools/check-macho.py`.
Troubadour_CODESIGN_FLAGS = -Cadhoc -Iru.computershik.troubadour -S

include $(THEOS_MAKE_PATH)/application.mk

# Помощник, который меняет значок и название.
#
# Приложение работает от `mobile` и свою же связку переписать не может:
# она принадлежит root, да и песочница туда не пускает. Поэтому подмену
# делает отдельный маленький файл с битом setuid — он лежит в той же
# связке и запускается приложением.
#
# Подпись у него своя и пустая: entitlements ему не нужны, а без подписи
# вовсе iOS его не запустит.
TOOL_NAME = iconswitch

iconswitch_FILES = src/helper/iconswitch.c
iconswitch_CFLAGS = -Wall
iconswitch_CODESIGN_FLAGS = -S
iconswitch_INSTALL_PATH = /Applications/$(APPLICATION_NAME).app

include $(THEOS_MAKE_PATH)/tool.mk

# Права на файлы приложения.
#
# WSL выдаёт всему на диске Windows права 777, и chmod там ничего не меняет.
# Каталог сборки поэтому уносится в файловую систему Linux — но права
# приезжают туда вместе с файлами, и в пакет уходило бы дерево, где и связка,
# и исполняемый файл открыты на запись всему миру. На iOS 5 и 6 это сходит
# с рук, дальше — нет: связку с правами 777 LaunchServices не регистрирует,
# а исполняемый файл с такими правами не запускают. Отказ тихий и без единой
# записи в журнале.
after-stage::
	@find $(THEOS_STAGING_DIR) -type d -exec chmod 755 {} +
	@find $(THEOS_STAGING_DIR) -type f -exec chmod 644 {} +
	@chmod 755 $(THEOS_STAGING_DIR)/Applications/$(APPLICATION_NAME).app/$(APPLICATION_NAME)

# Свой набор значков — на случай возврата.
#
# Собирается здесь же, из того, что уже лежит в связке: так он не
# разъедется с настоящим значком, как разъехался бы отдельный список
# файлов в хранилище. Чужой набор в поставку не входит вовсе — его
# приносит человек, выбрав тему у себя на устройстве.
#
# Бит setuid ставится последним: предыдущее правило снимает его заодно
# со всеми правами.
	@app=$(THEOS_STAGING_DIR)/Applications/$(APPLICATION_NAME).app; \
	 mkdir -p $$app/Icons/troubadour; \
	 cp $$app/Icon-*.png $$app/Icons/troubadour/; \
	 cp $$app/Info.plist $$app/Icons/troubadour/Info.plist; \
	 for lproj in $$app/*.lproj; do \
	   [ -f "$$lproj/InfoPlist.strings" ] || continue; \
	   mkdir -p "$$app/Icons/troubadour/`basename $$lproj`"; \
	   cp "$$lproj/InfoPlist.strings" \
	      "$$app/Icons/troubadour/`basename $$lproj`/InfoPlist.strings"; \
	 done; \
	 chmod 755 $$app/iconswitch; \
	 chmod u+s $$app/iconswitch

# То же для служебного каталога пакета, и отдельным шагом: layout/DEBIAN
# переносится сюда позже — уже при упаковке, — так что предыдущее правило
# его ещё не застаёт.
before-package::
	@chmod 755 "$(THEOS_STAGING_DIR)/DEBIAN"
	@for script in preinst postinst prerm postrm; do \
		[ -f "$(THEOS_STAGING_DIR)/DEBIAN/$$script" ] && \
			chmod 755 "$(THEOS_STAGING_DIR)/DEBIAN/$$script"; \
	done; true
	@[ -f "$(THEOS_STAGING_DIR)/DEBIAN/control" ] && \
		chmod 644 "$(THEOS_STAGING_DIR)/DEBIAN/control"; true

# Настоящая версия сборки — в связку.
#
# В `Resources/Info.plist` лежит короткая «1.4»: номер сборки theos
# дописывает сам, и до связки он не доходил. А приложению он нужен —
# по нему оно решает, есть ли в источнике что-то свежее. Спрашивать
# у `dpkg` оказалось нельзя: он помнит последний поставленный **пакет**,
# а приложение нередко ставят из `.ipa`, и тогда его запись отстаёт
# на сотню сборок.
#
# Берём номер из служебного `control`, который к этому шагу уже собран
# со всеми добавками (`+debug` в том числе), и вписываем в строку под
# ключом `CFBundleVersion`. `CFBundleShortVersionString` не трогаем:
# он для человека и остаётся коротким.
	@control="$(THEOS_STAGING_DIR)/DEBIAN/control"; \
	 plist="$(THEOS_STAGING_DIR)/Applications/$(APPLICATION_NAME).app/Info.plist"; \
	 version=`sed -n 's/^Version: //p' "$$control"`; \
	 if [ -n "$$version" ] && [ -f "$$plist" ]; then \
	   sed -i "/<key>CFBundleVersion<\/key>/{n;s|<string>.*</string>|<string>$$version</string>|;}" "$$plist"; \
	   echo "версия в связке: $$version"; \
	 fi

# Payload/Troubadour.app в zip — то же дерево, что кладётся в .deb.
#
# Имя берётся у только что собранного пакета: рядом с
# `ru.computershik.troubadour_1.4-22+debug_iphoneos-arm.deb` ложится
# `ru.computershik.troubadour_1.4-22+debug.ipa`. Один номер версии
# у обоих файлов — и видно, что это одна и та же сборка.
#
# Раньше имя было постоянное, `Troubadour-debug.ipa`, и сборки молча
# перетирали друг друга: отличить их можно было разве что по времени.
# Отладочную от готовой различает сама версия: theos дописывает к ней
# `+debug`, когда FINALPACKAGE не задан.
ipa:: package
	@rm -rf $(THEOS_STAGING_DIR)-ipa
	@mkdir -p $(THEOS_STAGING_DIR)-ipa/Payload
	@cp -r $(THEOS_STAGING_DIR)/Applications/$(APPLICATION_NAME).app \
	       $(THEOS_STAGING_DIR)-ipa/Payload/
	@stem=`ls -t packages/*.deb | head -1 | xargs -n1 basename | sed 's/_iphoneos-arm.deb$$//'`; \
	 cd $(THEOS_STAGING_DIR)-ipa && zip -qry $(CURDIR)/packages/$$stem.ipa Payload; \
	 echo "packages/$$stem.ipa"
