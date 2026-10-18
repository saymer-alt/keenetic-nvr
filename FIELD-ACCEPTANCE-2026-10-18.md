# Полевое завершение восстановления двух KN-1012 — 18.10.2026

Итог после Mesh-reset, по **реальным наблюдениям владельца** 18 октября 2026 года (МСК). Продолжение [первичной полевой инвентаризации](FIELD-RESTORE-2026-10-18.md) и [сценария восстановления](NVR/v2/MESH-RECOVERY.md).

**Функциональное восстановление обоих роутеров подтверждено.** Это **не полная аппаратная приёмка v2.5** и **не подтверждение автозапуска после reboot**. Секреты, личный Chat ID, RTSP-пароль, видеозаписи не публикуются. Перезагрузку пользователь сознательно отложил из-за большого количества USB HDD.

## 1. Раздельная архитектура

| Узел | KN-1012, Mesh member, KeeneticOS 5.1.8 | Назначение | Итог |
| --- | --- | --- | --- |
| STREAM | `192.168.1.3` | RTSP SUBSTREAM 102/202/302 → FFmpeg HTTP MPEG-TS → Selenga 980 → Sony ЭЛТ (1992) | **3/3 WORKER UP, изображение подтверждено** |
| NVR | `192.168.1.2` | RTSP MAIN 101/201/301 → FFmpeg MKV → отдельный USB EXT4, TIME 72h | **3/3 HEALTHY, новые MKV подтверждены, Telegram PASS** |

Оба используют Entware в **внутреннем UBIFS `/opt`**, а не на USB. На обоих `/tmp` — tmpfs, три runtime-каталога `/opt/tmp`, `/opt/var/log`, `/opt/var/run` находятся в tmpfs через **штатный KAS `S00ubifs`**; `nand-audit.sh` PASS. Полную установку KAS/Mihomo выполнять не потребовалось.

Плейлист на STREAM аппаратно подтверждён в [`STREAM/v1/playlist/selenga-sony-1992.m3u`](STREAM/v1/playlist/selenga-sony-1992.m3u). HTTP 8999/9000/9001 отдают substreams RTSP 102/202/302, а пользовательские URL `/stream101.ts`, `/stream201.ts`, `/stream301.ts` совместимы. Это **не** основные 2K/H.265 каналы. Ограничение: FFmpeg с `-listen 1` поддерживает по одному клиенту на канал. Ни reboot, ни долгий непрерывный soak-test STREAM пока не проверены.

## 2. Безопасное восстановление NVR на `192.168.1.2`

**Архив НЕ форматировали и НЕ удаляли при переустановке Entware.**

- Архивный USB: EXT4 RW, UUID `f9bf834b-5650-d901-f0aa-834b5650d901`; директория `/tmp/mnt/f9bf834b-5650-d901-f0aa-834b5650d901/cctv` с существующими `.nvr-v2`, `cam101`, `cam201`, `cam301` и MKV. На момент старта диск 654.9 GiB, 168.6 GiB занято, 451.3 GiB доступно; `/proc/mounts` подтвердил EXT4 RW. Не трогали второй USB UUID `f75f02e6-eb51-d901-e05f-02e6eb51d901`. Имена `/dev/sdX` могут измениться.
- Entware `opkg install ffmpeg cron coreutils-stat` → FFmpeg 6.1.4-1, cron 4.1-7, coreutils-stat 9.9-2, позже `jq 1.8.1-2`. Проверка FFmpeg RTSP `-timeout` успешна.
- Базовый код строго закреплён за commit `60e37c13ec40441c34a0c0f7a132ef8c0e011112`: `NVR/v2/nvr.sh` → `/opt/etc/nvr-v2.sh`, `NVR/v2/storage-guard.sh` → `/opt/etc/nvr-storage-guard.sh` (mode 700, `sh -n` PASS); вызов `nvr_archive_safe "$D" "$D/cctv"` → PASS. `setup.sh install`/`fresh-install.sh` **не запускали**, т.к. они закономерно отказываются поверх архива с прежними MKV.
- Пароль RTSP введён **локально и скрыто** через `read -r -s`; `/opt/etc/nvr-v2.conf` имеет mode 600. Несекретные параметры: `NVR_MOUNT=/tmp/mnt/f9bf834b-5650-d901-f0aa-834b5650d901`, `NVR_BASE_DIR=<этот mount>/cctv`, `RTSP_IP=192.168.1.135`, `NVR_CAMERAS='101 201 301'`, `NVR_STORAGE_MODE='time'`, `NVR_RETENTION_SECONDS=259200`, резерв 10%/128 MB, пороги 75/90%. **Не публиковать полный конфиг и `ps` с RTSP URL.**
- Изначальный `sh /opt/etc/nvr-v2.sh status` → ожидаемо `DEGRADED` (записи не запущены). `sh /opt/etc/nvr-v2.sh start` → через 30 секунд `NVR v2.5 - HEALTHY` и 3/3 камеры HEALTHY. Фактически появились новые `cam101_2026-10-18_21-57-31.mkv`, `cam201_2026-10-18_21-57-31.mkv`, `cam301_2026-10-18_21-57-31.mkv`. Старые MKV от 17 октября сохранились.

### Безопасная очистка TIME / 72 часа

Сначала оператор выполнил **только предварительный просмотр**:

```sh
sh /opt/etc/nvr-v2.sh cleanup --dry-run
# DRY-RUN STORAGE MODE: time; candidates=276 skipped=0 failed=0
```

После этого сам разрешил и выполнил реальную команду `sh /opt/etc/nvr-v2.sh cleanup`. Результат в `status`: **`LAST CLEANUP: 2026-10-18 22:00:46 OK`, `REMOVED FILES: 276 (skipped 0)`**. Освободилось около **14.9 GB** (451.3 → 466.2 GB free), занятость 27% → 25%. Новый dry-run сразу после удаления обнаружил **3 дополнительных кандидата**: во время испытаний новые MKV пересекли возрастной порог. Очистка отсчитывает 72 часа от `mtime` MKV; открытые файлы FFmpeg защищены. Режим CIRCULAR/HYBRID **не включали**.

**Важно:** команда `cleanup` **без** `--dry-run` физически удаляет просроченные MKV. Не применять её в неподтверждённом режиме и не запускать старые `cleanup_cctv.sh`.

### Планировщик / watchdog

Через ~882 секунды без watchdog общий статус стал `DEGRADED`, при этом все три камеры оставались `HEALTHY` и продолжали запись. Ручная `check` в 22:21:05 вернула общий статус `HEALTHY`. Далее без перезагрузки добавлены **только две строки** root crontab:

```cron
*/5 * * * * /bin/sh /opt/etc/nvr-v2.sh check
3 * * * * /bin/sh /opt/etc/nvr-v2.sh cleanup
```

Предыдущий root crontab сохранён в `/opt/etc/nvr-crontab-backup.GvvOlD` (mode 600). `S10cron restart` → `Starting cron... done.`; `crontab -l` подтвердил обе строки. Telegram `/status` в **22:40:01** отобразил `LAST CHECK: 22:40:01 (0s ago)` — в момент расписания `*/5`, что **хорошо согласуется** с автосрабатыванием, хотя отдельный журнал запуска Cron не проверялся. **Очистка HH:03 после восстановления на момент финального отчёта ещё не наблюдалась.**

### Telegram — уведомления и четыре команды

При первом запуске `telegram-setup.sh` была временная ошибка DNS `Could not resolve host: api.telegram.org`. Диагностика позднее показала успешный DNS у `127.0.0.1` и `1.1.1.1`, а обычный и IPv4 `curl -I https://api.telegram.org` дали `HTTP/2 302` (API доступен). Существующий бот подтверждён методом `getMe`. Первоначальный `getUpdates` не обнаружил Chat ID, поэтому пользователь ввёл **собственный личный Chat ID** вручную и подтвердил `y`. **22:35 — тестовая Telegram-доставка подтверждена реальным сообщением** `NVR TEST [notify-test] test notification from NVR v2.5`.

В **22:40** бот ответил на `/status` (общий `HEALTHY`, `ALERTS: enabled`). В **22:44** пришли настоящие ответы на `/cameras` (CAM 101/201/301 HEALTHY), `/disk` (25% used, **465.9 GB free**, TIME 72h, cleanup 276 OK) и `/help`. **Read-only ответы Telegram: PASS 4/4.** Команды не управляют камерами и не удаляют записи. Точную SSH-команду установки poller пользователь в журнале не прислал; работоспособность канала получения команд подтверждена ответами.

## 3. Эксплуатация и что остаётся проверить

Безопасная read-only диагностика **на `192.168.1.2`**:

```sh
sh /opt/etc/nvr-v2.sh status
sh /opt/etc/nvr-v2.sh cleanup --dry-run | tail -n 1
crontab -l
df -h /tmp/mnt/f9bf834b-5650-d901-f0aa-834b5650d901
```

Последний реальный статус (22:44): **NVR v2.5 HEALTHY, камеры 3/3 HEALTHY, свободно 465.9 GB, TIME 72h, ALERTS enabled**. Запись NVR восстановлена, STREAM на соседнем роутере работает, перезагрузка **не выполнялась**.

**#15 можно закрыть как выполненное функциональное восстановление после Mesh-reset.** Не путать с полным релизным gate: отдельные аппаратные проверки **ещё открыты** в [#7](https://github.com/saymer-alt/keenetic-nvr/issues/7) (TIME/CIRCULAR/HYBRID на тестовом накопителе, disk-loss, reboot, принудительный сбой камеры), [#14](https://github.com/saymer-alt/keenetic-nvr/issues/14) (NAND safety), [#13](https://github.com/saymer-alt/keenetic-nvr/issues/13) (автоматический upgrade). Также ещё не проверены reboot-автозапуск STREAM и длительное вещание. `v2.5.0` **не выпускать** до выполнения [#7](https://github.com/saymer-alt/keenetic-nvr/issues/7) и [#10](https://github.com/saymer-alt/keenetic-nvr/issues/10).
