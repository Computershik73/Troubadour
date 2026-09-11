# -*- coding: utf-8 -*-
"""
Проверяет собранный бинарник: платформу, нижние границы, подпись.

Всё, что здесь проверяется, компоновщик молча делает неправильно, а сборка
при этом идёт без единого предупреждения. Замечается такое уже на устройстве,
и хуже всего, что не на всяком: приложение с платформой macOS запускается
на iOS 6 и не запускается на iOS 8, причём без записи в журнале падений —
процесс не падает, его просто не пускают.

    python3 tools/check-macho.py packages/YouTube.ipa
    python3 tools/check-macho.py /путь/к/YouTube.app/YouTube

Возвращает 1, если хоть одна проверка не прошла — годится для CI.
"""
import io
import os
import re
import struct
import sys
import tempfile
import zipfile

# Команды загрузки, которые нас интересуют. Числа соседние и легко
# переставляются местами — они выписаны из mach-o/loader.h как есть.
LC_VERSION_MIN_MACOSX = 0x24
LC_VERSION_MIN_IPHONEOS = 0x25
LC_CODE_SIGNATURE = 0x1D
LC_BUILD_VERSION = 0x32

# Тип процессора в заголовке.
CPU_ARM = 12
CPU_ARM64 = 0x0100000C

# Нижняя граница, объявленная в Makefile. Она одна на оба среза: поднять её
# у arm64 отдельно theos не даёт, подробности — в самом Makefile.
EXPECTED_MIN = {"armv7": (5, 1), "arm64": (5, 1)}

# Платформа в LC_BUILD_VERSION (новые цепочки пишут её вместо VERSION_MIN).
PLATFORM_IOS = 2


def version(value):
    return (value >> 16, (value >> 8) & 0xFF, value & 0xFF)


def slice_name(cputype, cpusubtype):
    if cputype == CPU_ARM64:
        return "arm64"
    if cputype == CPU_ARM:
        return {9: "armv7", 11: "armv7s", 6: "armv6"}.get(cpusubtype & 0xFF, "arm?")
    return "cpu:%d" % cputype


# Что внутри подписи.
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02

CSSLOT_ALTERNATE_CODEDIRECTORY = 0x1000

CS_ADHOC = 0x2

# Виды сводок: SHA-1 понимают старые системы, SHA-256 требуют начиная
# с iOS 11. Второй здесь «усечённый» (тип 2) — так его кладёт ldid,
# и системе этого довольно.
CS_HASHTYPE_SHA1 = 1
CS_HASHTYPE_SHA256_TRUNC = 2
CS_HASHTYPE_SHA256 = 5

# Имя связки: с ним должно совпадать имя в подписи.
#
# Берётся из Resources/Info.plist, а не задаётся числом: иначе при
# переименовании пакета скрипт начинает ругаться на правильную сборку,
# и его правку легко забыть.
def _bundle_identifier():
    here = os.path.dirname(os.path.abspath(__file__))
    plist = os.path.join(here, "..", "Resources", "Info.plist")

    try:
        with io.open(plist, encoding="utf-8") as handle:
            text = handle.read()
    except IOError:
        return ""

    match = re.search(
        r"<key>CFBundleIdentifier</key>\s*<string>([^<]+)</string>", text)

    return match.group(1) if match else ""


BUNDLE_IDENTIFIER = _bundle_identifier()


def check_signature(data, offset, name, problems):
    """
    Смотрит, поймёт ли подпись **весь** ряд систем, а не какая-то одна.

    Требований два, и они тянут в разные стороны. Джейлбрейк iOS 6 снимал
    проверку целиком; iOS 8 её разбирает и знает только SHA-1. А с iOS 11
    система считает cdhash по SHA-256 и подпись без неё не принимает вовсе.
    Значит в файле должны лежать **обе** сводки сразу: SHA-1 в основном
    слоте и SHA-256 в дополнительном.

    Отказ в обе стороны молчаливый — процесс просто не заводят, — поэтому
    проверяется здесь. Одна пропущенная сводка стоила сборки, которая
    ставилась через 3uTools и падала через AppSync.
    """
    magic, _, count = struct.unpack_from(">III", data, offset)

    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        problems.append("%s: подпись не разбирается (magic 0x%x)" % (name, magic))
        return

    has_sha1 = False
    has_sha256 = False

    for i in range(count):
        slot, where = struct.unpack_from(">II", data, offset + 12 + i * 8)
        blob = offset + where
        blob_magic = struct.unpack_from(">I", data, blob)[0]

        if blob_magic != CSMAGIC_CODEDIRECTORY:
            continue

        (_, _, _, flags, _, ident_offset,
         _, _, _, hash_size, hash_type, _, _, _) = struct.unpack_from(">IIIIIIIIIBBBBI", data, blob)

        if hash_type == CS_HASHTYPE_SHA1 and hash_size == 20:
            has_sha1 = True
        elif hash_type in (CS_HASHTYPE_SHA256, CS_HASHTYPE_SHA256_TRUNC):
            has_sha256 = True

        # Имя и признак adhoc лежат в основном слоте; у дополнительного
        # они те же, и печатать их дважды незачем.
        if slot == CSSLOT_ALTERNATE_CODEDIRECTORY:
            continue

        identifier = data[blob + ident_offset:data.index(b"\0", blob + ident_offset)]
        identifier = identifier.decode("utf-8", "replace")

        print("    подпись: %s, имя %s"
              % ("adhoc" if flags & CS_ADHOC else "НЕ adhoc", identifier))

        if not flags & CS_ADHOC:
            problems.append("%s: в подписи снят признак adhoc — система пойдёт искать "
                            "удостоверяющую часть, которой в файле нет. Подписывать "
                            "надо с -Cadhoc" % name)

        if identifier != BUNDLE_IDENTIFIER:
            problems.append("%s: имя в подписи «%s», а связка называется «%s» — "
                            "подписывать надо с -I%s"
                            % (name, identifier, BUNDLE_IDENTIFIER, BUNDLE_IDENTIFIER))

    print("    сводки: %s%s"
          % ("SHA-1 " if has_sha1 else "", "SHA-256" if has_sha256 else ""))

    if not has_sha1:
        problems.append("%s: в подписи нет сводки SHA-1 — её ждут iOS 8 и старше" % name)

    if not has_sha256:
        problems.append("%s: в подписи нет сводки SHA-256 — с iOS 11 подпись без неё "
                        "не принимается, и приложение снимут при запуске. "
                        "Убрать -Hsha1 из флагов подписи" % name)


def check_slice(data, offset, problems):
    magic = struct.unpack_from("<I", data, offset)[0]
    wide = magic == 0xFEEDFACF

    cputype, cpusubtype = struct.unpack_from("<ii", data, offset + 4)
    ncmds = struct.unpack_from("<I", data, offset + 16)[0]

    name = slice_name(cputype & 0xFFFFFFFF, cpusubtype)
    print("  срез %s" % name)

    platform = None
    minimum = None
    signed = False

    position = offset + (32 if wide else 28)

    for _ in range(ncmds):
        command, size = struct.unpack_from("<II", data, position)

        if command in (LC_VERSION_MIN_IPHONEOS, LC_VERSION_MIN_MACOSX):
            _, _, low, sdk = struct.unpack_from("<IIII", data, position)
            platform = "iOS" if command == LC_VERSION_MIN_IPHONEOS else "macOS"
            minimum = version(low)
            print("    %s, нижняя граница %d.%d, SDK %d.%d"
                  % ((platform,) + minimum[:2] + version(sdk)[:2]))

        if command == LC_BUILD_VERSION:
            _, _, which, low, sdk, _ = struct.unpack_from("<IIIIII", data, position)
            platform = "iOS" if which == PLATFORM_IOS else "платформа %d" % which
            minimum = version(low)
            print("    %s, нижняя граница %d.%d, SDK %d.%d"
                  % ((platform,) + minimum[:2] + version(sdk)[:2]))

        if command == LC_CODE_SIGNATURE:
            signed = True
            _, _, sig_offset, _ = struct.unpack_from("<IIII", data, position)
            check_signature(data, offset + sig_offset, name, problems)

        position += size

    if platform is None:
        problems.append("%s: платформа не объявлена вовсе — нет ни "
                        "LC_VERSION_MIN_*, ни LC_BUILD_VERSION" % name)
    elif platform != "iOS":
        problems.append("%s: платформа %s вместо iOS — смотрите тройку цели "
                        "(-target) в Makefile" % (name, platform))

    expected = EXPECTED_MIN.get(name)

    if expected is not None and minimum is not None and minimum[:2] != expected:
        problems.append("%s: нижняя граница %d.%d, а ожидалась %d.%d"
                        % ((name,) + minimum[:2] + expected))

    if not signed:
        problems.append("%s: нет подписи (LC_CODE_SIGNATURE). На iOS 8 и новее "
                        "такой файл не запустится даже с AppSync — нужен "
                        "хотя бы ldid -S" % name)
        print("    подпись: НЕТ")


def check_cfnetwork(data, problems):
    """
    CFNetwork в списке библиотек — почти всегда ошибка.

    Семья NSURL* переезжала между Foundation и CFNetwork: в SDK 9.3
    `NSURLRequest`, `NSURLResponse` и родня числятся за CFNetwork, а на
    iOS 7 и старше живут в Foundation. Двухуровневые имена означают, что
    dyld ищет класс ровно в названной библиотеке и, не найдя, отказывает
    целиком — приложение умирает до main, без единой записи в журнале
    падений:

        Symbol not found: _OBJC_CLASS_$_NSURLRequest
        Expected in: CFNetwork.framework/CFNetwork

    Ловится это одной строкой: путь библиотеки лежит в LC_LOAD_DYLIB
    обычным текстом, и если мы её не линкуем, его в файле нет вовсе.
    Само упоминание CFNetwork появляется ровно тогда, когда в коде
    сослались на такой класс, — то есть проверка бьёт по причине,
    а не по следствию.

    Лечение: пользоваться изменяемым родственником (`NSMutableURLRequest`),
    он остался за Foundation в обеих версиях.
    """
    if data.find(b"CFNetwork.framework") >= 0:
        problems.append(
            "линкуется CFNetwork — где-то ссылка на класс семьи NSURL*; "
            "возьмите изменяемый вариант (NSMutableURLRequest)")


def check(path, problems):
    data = open(path, "rb").read()

    if len(data) < 8:
        problems.append("%s: файл пуст" % path)
        return

    check_cfnetwork(data, problems)

    magic = struct.unpack_from(">I", data, 0)[0]

    if magic in (0xCAFEBABE, 0xCAFEBABF):
        count = struct.unpack_from(">I", data, 4)[0]
        print("%s: универсальный файл, срезов %d" % (os.path.basename(path), count))

        for i in range(count):
            _, _, offset, _, _ = struct.unpack_from(">iiIII", data, 8 + i * 20)
            check_slice(data, offset, problems)

        names = set()
        for i in range(count):
            cputype, cpusubtype, _, _, _ = struct.unpack_from(">iiIII", data, 8 + i * 20)
            names.add(slice_name(cputype & 0xFFFFFFFF, cpusubtype))

        # armv7 — всё от iPhone 3GS до iPhone 5 и оба iPad mini первого
        # поколения; arm64 — всё, что новее. Без одного из срезов половина
        # заявленных устройств останется без приложения.
        for wanted in ("armv7", "arm64"):
            if wanted not in names:
                problems.append("нет среза %s" % wanted)
    else:
        print("%s: один срез" % os.path.basename(path))
        check_slice(data, 0, problems)


def binary_from_ipa(path):
    with zipfile.ZipFile(path) as archive:
        names = [n for n in archive.namelist()
                 if n.startswith("Payload/") and n.count("/") == 2
                 and n.endswith("/" + n.split("/")[1].replace(".app", ""))]

        if not names:
            print("В %s не нашлось исполняемого файла" % path, file=sys.stderr)
            sys.exit(2)

        target = os.path.join(tempfile.mkdtemp(), os.path.basename(names[0]))

        with open(target, "wb") as out:
            out.write(archive.read(names[0]))

        return target


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)

    path = sys.argv[1]

    if path.endswith(".ipa"):
        path = binary_from_ipa(path)

    problems = []
    check(path, problems)

    if not problems:
        print("\nВсё в порядке.")
        return 0

    print("\nНе в порядке:")
    for problem in problems:
        print("  * %s" % problem)

    return 1


if __name__ == "__main__":
    sys.exit(main())
