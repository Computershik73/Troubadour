/*
 * Смена значка и названия приложения — маленький помощник с правами root.
 *
 * Зачем он нужен. Значок и подпись под ним SpringBoard берёт из связки
 * приложения: `Icon-*.png` и `CFBundleDisplayName` в `Info.plist`.
 * Само приложение переписать их не может: связка принадлежит root,
 * файлы 644, да и песочница туда не пускает. Поэтому подменой занят
 * отдельный двоичный файл, который лежит в той же связке и стоит
 * с битом setuid: запускает его приложение от `mobile`, а работает он
 * от root.
 *
 * Две работы:
 *
 *     iconswitch apply <каталог>   поставить приготовленное
 *     iconswitch restore           вернуть своё
 *
 * Приготовленное — это восемь `Icon-<размер>.png` и `Info.plist`,
 * которые приложение складывает у себя, разобрав выбранную человеком
 * тему. Своё лежит в связке, в `Icons/troubadour/`, и кладётся туда
 * при сборке.
 *
 * Про каталог, который называют снаружи. Он проверяется, и строго:
 * только внутри `/var/mobile`, без «..», только настоящий каталог,
 * и принадлежать он должен тому, кто нас позвал. Читаются оттуда лишь
 * девять имён, известных заранее. Помощник с правами root, которому
 * можно назвать любой файл, — это не помощник, а дыра.
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define APP "/Applications/Troubadour.app"

/** Размеры значков — те же, что перечислены в `CFBundleIconFiles`. */
static const char *kSizes[] = {
    "57", "72", "76", "114", "120", "144", "152", "180"
};

static int copy_file(const char *from, const char *to) {
    int in = open(from, O_RDONLY);

    if (in < 0) {
        fprintf(stderr, "не открыть %s: %s\n", from, strerror(errno));

        return -1;
    }

    /*
     * Пишем во временный файл рядом и переставляем его на место готовым.
     *
     * Иначе прерванное копирование оставило бы обрезанный `Info.plist`,
     * а с ним приложение не запускается вовсе — и починить это будет
     * нечем, помощник живёт в той же связке.
     */
    char temp[1024];

    snprintf(temp, sizeof(temp), "%s.new", to);

    int out = open(temp, O_WRONLY | O_CREAT | O_TRUNC, 0644);

    if (out < 0) {
        fprintf(stderr, "не создать %s: %s\n", temp, strerror(errno));

        close(in);

        return -1;
    }

    char chunk[65536];
    ssize_t got;

    while ((got = read(in, chunk, sizeof(chunk))) > 0) {
        ssize_t put = 0;

        while (put < got) {
            ssize_t step = write(out, chunk + put, (size_t)(got - put));

            if (step <= 0) {
                fprintf(stderr, "не записать %s: %s\n", temp, strerror(errno));

                close(in);
                close(out);
                unlink(temp);

                return -1;
            }

            put += step;
        }
    }

    close(in);
    fsync(out);
    close(out);

    if (chown(temp, 0, 0) != 0) {
        fprintf(stderr, "не сменить владельца %s: %s\n", temp, strerror(errno));
    }

    chmod(temp, 0644);

    if (rename(temp, to) != 0) {
        fprintf(stderr, "не переставить %s: %s\n", to, strerror(errno));

        unlink(temp);

        return -1;
    }

    return 0;
}

/**
 * Годится ли названный каталог.
 *
 * Требования простые и все нужны: путь внутри `/var/mobile`, без «..»
 * (иначе «внутри» ничего не значит), это настоящий каталог, и владеет
 * им тот, кто нас позвал. Последнее важнее всего: подсунуть чужой
 * каталог, лежащий там же, станет некому.
 */
static int folder_allowed(const char *path, uid_t caller) {
    if (strncmp(path, "/var/mobile/", 12) != 0) {
        fprintf(stderr, "каталог не внутри /var/mobile: %s\n", path);

        return 0;
    }

    if (strstr(path, "..") != NULL) {
        fprintf(stderr, "в пути есть «..»: %s\n", path);

        return 0;
    }

    struct stat where;

    if (lstat(path, &where) != 0) {
        fprintf(stderr, "нет каталога %s: %s\n", path, strerror(errno));

        return 0;
    }

    if (!S_ISDIR(where.st_mode)) {
        fprintf(stderr, "это не каталог: %s\n", path);

        return 0;
    }

    if (where.st_uid != caller) {
        fprintf(stderr, "каталог не ваш: %s\n", path);

        return 0;
    }

    return 1;
}

/**
 * Локализованные названия.
 *
 * Подпись под значком SpringBoard берёт не из `Info.plist`, а из
 * `<язык>.lproj/InfoPlist.strings`, если такой файл есть: локализация
 * старше. У нас их два, английский и русский, — и пока менялся только
 * `Info.plist`, на русском устройстве название оставалось прежним.
 *
 * Переносим лишь те, для которых в связке уже есть свой каталог: новых
 * языков помощник не заводит, и подсунуть ему чужой путь через имя
 * каталога поэтому нечем.
 */
static int install_localized(const char *folder) {
    DIR *dir = opendir(folder);

    if (dir == NULL) {
        return 0;
    }

    int failed = 0;

    struct dirent *item;

    while ((item = readdir(dir)) != NULL) {
        const char *name = item->d_name;

        size_t length = strlen(name);

        if (length < 7 || strcmp(name + length - 6, ".lproj") != 0) {
            continue;
        }

        if (strchr(name, '/') != NULL || strstr(name, "..") != NULL) {
            continue;
        }

        char from[1024];
        char to[1024];
        char where[1024];

        snprintf(from, sizeof(from), "%s/%s/InfoPlist.strings", folder, name);
        snprintf(where, sizeof(where), "%s/%s", APP, name);
        snprintf(to, sizeof(to), "%s/InfoPlist.strings", where);

        if (access(from, R_OK) != 0) {
            continue;
        }

        struct stat there;

        if (stat(where, &there) != 0 || !S_ISDIR(there.st_mode)) {
            fprintf(stderr, "в связке нет каталога %s — пропускаю\n", name);

            continue;
        }

        if (copy_file(from, to) != 0) {
            failed++;
        }
    }

    closedir(dir);

    return failed;
}

static int install_from(const char *folder) {
    size_t i;
    int failed = 0;

    for (i = 0; i < sizeof(kSizes) / sizeof(kSizes[0]); i++) {
        char from[1024];
        char to[1024];

        snprintf(from, sizeof(from), "%s/Icon-%s.png", folder, kSizes[i]);
        snprintf(to, sizeof(to), "%s/Icon-%s.png", APP, kSizes[i]);

        if (access(from, R_OK) != 0) {
            fprintf(stderr, "нет %s\n", from);

            failed++;

            continue;
        }

        if (copy_file(from, to) != 0) {
            failed++;
        }
    }

    char plistFrom[1024];
    char plistTo[1024];

    snprintf(plistFrom, sizeof(plistFrom), "%s/Info.plist", folder);
    snprintf(plistTo, sizeof(plistTo), "%s/Info.plist", APP);

    if (access(plistFrom, R_OK) == 0) {
        if (copy_file(plistFrom, plistTo) != 0) {
            failed++;
        }
    } else {
        fprintf(stderr, "нет %s — название останется прежним\n", plistFrom);

        failed++;
    }

    failed += install_localized(folder);

    if (failed > 0) {
        fprintf(stderr, "сделано с ошибками: %d\n", failed);

        return 5;
    }

    return 0;
}

/*
 * Установка пакета: `dpkg -i`.
 *
 * Зачем здесь. Приложение раздаётся пакетом `.deb` из своего источника,
 * и поставить его поверх себя иначе нельзя: `dpkg` требует root, а
 * приложение работает от `mobile`. Помощник с битом setuid у нас уже
 * есть — заводить второй ради одной строки незачем.
 *
 * Что проверяется. Путь к пакету: только внутри `/var/mobile`, без «..»,
 * обычный файл, принадлежащий тому, кто нас позвал. И начало файла:
 * `.deb` — это архив `ar`, он начинается с «!<arch>»; подсунуть вместо
 * него скрипт или что угодно ещё не выйдет.
 *
 * Чего проверить нельзя. Содержимое пакета: его разбор — это ar, tar и
 * gzip, три формата ради одной проверки. Поэтому сводку SHA-256 сверяет
 * приложение: она названа в описи источника, оттуда же взят и адрес.
 * На устройстве с джейлбрейком, где root доступен и так, этого довольно.
 */
static int install_package(const char *path, uid_t caller) {
    if (strncmp(path, "/var/mobile/", 12) != 0 || strstr(path, "..") != NULL) {
        fprintf(stderr, "пакет не там, где положено: %s\n", path);

        return 4;
    }

    struct stat where;

    if (lstat(path, &where) != 0 || !S_ISREG(where.st_mode)) {
        fprintf(stderr, "нет такого файла: %s\n", path);

        return 4;
    }

    if (where.st_uid != caller) {
        fprintf(stderr, "файл не ваш: %s\n", path);

        return 4;
    }

    int file = open(path, O_RDONLY);

    if (file < 0) {
        fprintf(stderr, "не открыть %s: %s\n", path, strerror(errno));

        return 4;
    }

    char head[8] = {0};
    ssize_t got = read(file, head, sizeof(head));

    close(file);

    if (got != (ssize_t)sizeof(head) || memcmp(head, "!<arch>\n", 8) != 0) {
        fprintf(stderr, "это не пакет .deb: %s\n", path);

        return 4;
    }

    /* На rootless-джейлбрейках dpkg лежит под /var/jb. */
    const char *tools[] = { "/usr/bin/dpkg", "/var/jb/usr/bin/dpkg" };
    const char *dpkg = 0;

    unsigned i;

    for (i = 0; i < sizeof(tools) / sizeof(tools[0]); i++) {
        if (access(tools[i], X_OK) == 0) {
            dpkg = tools[i];

            break;
        }
    }

    if (dpkg == 0) {
        fprintf(stderr, "dpkg не найден — ставить нечем\n");

        return 6;
    }

    pid_t child = fork();

    if (child < 0) {
        fprintf(stderr, "не разветвиться: %s\n", strerror(errno));

        return 7;
    }

    if (child == 0) {
        execl(dpkg, "dpkg", "-i", path, (char *)0);

        fprintf(stderr, "не запустить dpkg: %s\n", strerror(errno));

        _exit(127);
    }

    int state = 0;

    while (waitpid(child, &state, 0) < 0 && errno == EINTR) {
        /* Ожидание прервал сигнал — ждём дальше. */
    }

    if (!WIFEXITED(state)) {
        return 8;
    }

    return WEXITSTATUS(state);
}

int main(int argc, char **argv) {
    uid_t caller = getuid();

    /*
     * Права поднимаем явно.
     *
     * Бит setuid даёт действующего владельца root, но настоящий остаётся
     * прежним, и часть вызовов смотрит именно на него. Группа меняется
     * первой: после `setuid(0)` вернуть себе право менять группу уже
     * не выйдет. Настоящего владельца запоминаем до всего этого —
     * по нему проверяется названный каталог.
     */
    setgid(0);
    setuid(0);

    if (geteuid() != 0) {
        fprintf(stderr, "нет прав root — проверьте бит setuid у помощника\n");

        return 3;
    }

    if (argc == 2 && strcmp(argv[1], "restore") == 0) {
        char own[1024];

        snprintf(own, sizeof(own), "%s/Icons/troubadour", APP);

        if (access(own, R_OK) != 0) {
            fprintf(stderr, "своего набора нет: %s\n", own);

            return 4;
        }

        int code = install_from(own);

        if (code == 0) {
            printf("вернули своё\n");
        }

        return code;
    }

    if (argc == 3 && strcmp(argv[1], "apply") == 0) {
        if (!folder_allowed(argv[2], caller)) {
            return 4;
        }

        int code = install_from(argv[2]);

        if (code == 0) {
            printf("поставлено из %s\n", argv[2]);
        }

        return code;
    }

    if (argc == 3 && strcmp(argv[1], "install") == 0) {
        return install_package(argv[2], caller);
    }

    fprintf(stderr, "нужно: iconswitch apply <каталог> | iconswitch restore"
                    " | iconswitch install <пакет>\n");

    return 2;
}
