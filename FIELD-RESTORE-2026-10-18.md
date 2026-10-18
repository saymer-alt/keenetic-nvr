# Полевое восстановление двух KN-1012 после Mesh-reset — 18.10.2026

> **ОБНОВЛЕНИЕ ПОСЛЕ ПОЛНОГО ВОССТАНОВЛЕНИЯ (22:44 МСК):** NVR на `.2` уже работает (3/3 HEALTHY), удалены 276 просроченных MKV, Telegram 4/4 PASS, Cron настроен. Ниже сохранена **хронология раннего этапа до запуска NVR**; актуальный финальный отчёт — [FIELD-ACCEPTANCE-2026-10-18.md](FIELD-ACCEPTANCE-2026-10-18.md). Не воспринимать ранние фразы «ещё не восстановлено» как текущее состояние.


> Проверенный на реальных устройствах **срез состояния**, не обещание полного релиза NVR v2.5.
> Из этой инструкции исключены RTSP-пароль, Telegram-токены, приватные конфиги и видео.
> Конфигурации с секретами хранятся **только локально** на роутерах (root/0600) или в защищённой личной резервной копии.
> Отдельные сервисы: [STREAM/v1](STREAM/v1/README.md) на `192.168.1.3` и [NVR/v2](NVR/v2/MESH-RECOVERY.md) на `192.168.1.2`.

## Фактически подтверждено на раннем этапе 18.10.2026 (до NVR restore)

| Проверка | KN-1012 `192.168.1.3` (STREAM) | KN-1012 `192.168.1.2` (NVR) |
| --- | --- | --- |
| Entware (BusyBox ash 1.37.0), `/opt` | внутренний UBIFS | внутренний UBIFS |
| `curl` | 8.15.0 | 8.15.0 |
| `/tmp` | tmpfs | tmpfs |
| KAS `S00ubifs` | **PASS**: `/opt/tmp`, `/opt/var/log`, `/opt/var/run` — tmpfs | **PASS**: те же три tmpfs |
| `ffmpeg` | 6.1.4, Entware | пока не установлен/не подтверждён в этом восстановлении |
| `/opt` по `df -h` | 98.2M total, 35.2M used, 58.3M available после FFmpeg | 98.2M total, 10.3M used, 83.2M available |
| STREAM | три worker UP, реальное видео **работает на Selenga и ЭЛТ Sony** | не устанавливать |
| NVR | не устанавливать | **сохранены каталоги архива**, восстановление записи ещё не выполнено |
| Перезагрузка после настройки | **отложена владельцем** | **отложена владельцем** |

Владелец **не хочет перезагружать** эти KN-1012 на текущем этапе: подключено много HDD, после reboot они долго запускаются. Не предлагать reboot в качестве обязательного ближайшего шага. Автозапуск STREAM после reboot ещё **не проверен**; то же относится к восстановлению NVR после reboot.

## STREAM: фактическая аппаратная конфигурация и совместимый плейлист

Путь сигнала: RTSP-источник `192.168.1.135:554` → отдельный KN-1012 `192.168.1.3` → FFmpeg `-c:v copy`, HTTP MPEG-TS → **Selenga 980** → аналоговый видеовыход → **Sony ЭЛТ 1992 года**.

Для старого телевизора используются **субпотоки**, а не 2K/H.265 main:
- камера «Входная Дверь»: RTSP channel **102**, HTTP **8999**;
- камера «Коридор Холл»: RTSP channel **202**, HTTP **9000**;
- камера «Лифт Мусоропровод»: RTSP channel **302**, HTTP **9001**.

Подтверждённая настройка `/opt/etc/keenetic-stream.conf` (локальный файл, права **600**) — **без секретов**:

```sh
STREAM_RTSP_HOST='192.168.1.135'
STREAM_RTSP_PORT=554
STREAM_RTSP_USER='YOUR_RTSP_USER'
STREAM_RTSP_PASSWORD='YOUR_RTSP_PASSWORD'
STREAM_BIND='192.168.1.3'
STREAM_PLAYLIST_HOST='192.168.1.3'
STREAM_CHANNELS='102:8999 202:9000 302:9001'
STREAM_RESTART_DELAY=2
```

В рабочем локальном конфиге пользователь подставил собственные RTSP-учётные данные, которые **не публикуются**. Не выводить этот файл целиком в GitHub issues или общий чат. Сервис использует RTSP credentials в аргументах запущенного FFmpeg; **не публиковать полные `ps`/`/proc/*/cmdline`**.

Воспроизведение подтвердилось именно **со старым плейлистом и суффиксами `/stream101.ts` и т. д.**, хотя стандартная команда `playlist` нового STREAM генерирует URL **без этих суффиксов**. Аппаратно проверенный старый M3U: [`STREAM/v1/playlist/selenga-sony-1992.m3u`](STREAM/v1/playlist/selenga-sony-1992.m3u). Не менять пользовательский плейлист без необходимости. Соответствие суффикса `stream101.ts` RTSP-каналу 102 — намеренная совместимость со старым названием, а не выбор main stream.

Встроенный `ffmpeg -listen 1` обслуживает **одного HTTP-клиента на канал**. Разъединение клиента приводит к перезапуску FFmpeg worker; тесты долгой непрерывной работы и восстановления после reboot ещё не проведены. Не заявлять, что проверено одновременное вещание нескольким клиентам или все сценарии восстановления.

## STREAM: восстановление на чистой Entware без редактора

На **`192.168.1.3`**, только после того как внутренний `/opt` определён и нет других работающих Entware-сервисов с важными файлами в `/opt/var/run`/`/opt/var/log`:

```sh
opkg update && opkg install curl
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-nvr/stable/tools/nand-audit.sh \
  -o /tmp/nand-audit.sh &&
sh -n /tmp/nand-audit.sh &&
sh /tmp/nand-audit.sh
```

На свежем `/opt` ожидаем PASS по UBIFS и `/tmp`, но WARN по трём runtime-каталогам — **до установки S00ubifs**. Для их переноса в RAM применяется **канонический скрипт KAS/stable**, а не полная установка Mihomo/KAS:

```sh
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-nvr/stable/tools/entware-flash-guard.sh \
  -o /tmp/entware-flash-guard.sh &&
sh -n /tmp/entware-flash-guard.sh &&
. /tmp/entware-flash-guard.sh &&
knvr_flash_ensure &&
/opt/etc/init.d/S00ubifs status &&
sh /tmp/nand-audit.sh
```

Ожидается три `mounted` и три `PASS`. Это изменение монтирований: существующее содержимое runtime-каталогов становится скрытым под tmpfs до размонтирования, поэтому включать **до** развёртывания других служб, не вслепую поверх уже работающей Entware. `S00ubifs` остаётся в `/opt/etc/init.d`, имеет права `755` и `ENABLED=yes`. Перезапуск Keenetic для активации **не нужен**.

Затем установить FFmpeg и автономный STREAM, закрепив загрузку на подготовленной ветке `stable` (для строго неизменяемого среза можно заменить `stable` на проверенный commit `60e37c13ec40441c34a0c0f7a132ef8c0e011112`):

```sh
opkg install ffmpeg
BASE=https://raw.githubusercontent.com/saymer-alt/keenetic-nvr/stable
curl -fSsL "$BASE/STREAM/v1/bootstrap.sh" -o /tmp/stream-bootstrap.sh &&
sh -n /tmp/stream-bootstrap.sh &&
STREAM_PROJECT_RAW_BASE="$BASE" sh /tmp/stream-bootstrap.sh preflight &&
STREAM_PROJECT_RAW_BASE="$BASE" sh /tmp/stream-bootstrap.sh install
```

Успешный `preflight` уже получен на реальном устройстве, а `install` завершился строкой `STREAM installed but NOT started`. Шаблон создан в `/opt/etc/keenetic-stream.conf` и **не содержит настоящего пароля**.

Для настройки **без vi/nano**, локально через скрытый ввод RTSP-пароля (при наличии обычной интерактивной Entware SSH-сессии):

```sh
(
  set -eu
  umask 077
  CONF=/opt/etc/keenetic-stream.conf
  TMP=$(mktemp /opt/etc/.keenetic-stream.XXXXXX)
  trap 'rm -f "$TMP"' EXIT
  printf 'RTSP password (hidden): '
  IFS= read -r -s PASS < /dev/tty
  printf '\n'
  case "$PASS" in ''|*[!a-zA-Z0-9._~%-]*) echo 'Password contains unsupported characters' >&2; exit 1;; esac
  if [ -e "$CONF" ]; then
    cp -p "$CONF" "$CONF.before-restore"  # локальный backup, не публиковать
    chmod 600 "$CONF.before-restore"
  fi
  cat > "$TMP" <<EOF
STREAM_RTSP_HOST='192.168.1.135'
STREAM_RTSP_PORT=554
STREAM_RTSP_USER='YOUR_RTSP_USER'
STREAM_RTSP_PASSWORD='$PASS'
STREAM_BIND='192.168.1.3'
STREAM_PLAYLIST_HOST='192.168.1.3'
STREAM_CHANNELS='102:8999 202:9000 302:9001'
STREAM_RESTART_DELAY=2
EOF
  sh -n "$TMP"
  chmod 600 "$TMP"
  mv -f "$TMP" "$CONF"
  unset PASS
  trap - EXIT
  sh /opt/etc/keenetic-stream.sh check
)
```

**Подставить свой локальный RTSP username вместо `YOUR_RTSP_USER` до запуска блока**; `YOUR_RTSP_PASSWORD` никогда не коммитить. Этот пример предназначен для **восстановления** конфигурации; работающий STREAM без необходимости не перенастраивать и не останавливать.

После проверки:

```sh
sh /opt/etc/keenetic-stream.sh start
sleep 5
sh /opt/etc/keenetic-stream.sh status
sh /opt/etc/keenetic-stream.sh playlist
```

На реальном устройстве `status` показал `WORKER UP` 3/3, а Selenga фактически показала изображение. При изменении с default `101:8081 201:8082 301:8083` **сначала остановить старые workers**, затем поменять `STREAM_CHANNELS`, проверить и запустить: нельзя менять конфиг до `stop`, потому что `stop` сопоставляет PID с текущими ID/портами.

## NVR `192.168.1.2`: ранняя инвентаризация дисков ДО восстановления/очистки

Read-only `df -h` 18.10.2026:

| Источник на момент проверки | UUID / mount | Размер | Использовано | Доступно |
| --- | --- | ---: | ---: | ---: |
| `/dev/sdb1` | `/tmp/mnt/f9bf834b-5650-d901-f0aa-834b5650d901` | 654.9G | 168.6G | **451.3G** |
| `/dev/sda1` | `/tmp/mnt/f75f02e6-eb51-d901-e05f-02e6eb51d901` | 873.2G | 695.8G | 130.8G |

**Важен UUID, а не `sda/sdb`:** Linux-имена дисков могут меняться между загрузками. Не перепутать заполненный дополнительный USB-диск и архивный диск. В этом сеансе `df` показывает mount и объём, но **не подтверждает тип файловой системы**; перед включением записи надо отдельно убедиться, что архивный диск действительно EXT4 и RW.

Архивный путь:

```text
/tmp/mnt/f9bf834b-5650-d901-f0aa-834b5650d901/cctv/
  .nvr-v2/        # присутствует, содержимое не вскрывали
  cam101/         # присутствует
  cam201/         # присутствует
  cam301/         # присутствует
  cleanup.log
  cleanup_cctv.sh # legacy, НЕ запускать вслепую
  record_cctv.sh  # legacy, НЕ запускать вслепую
```

`cctv` существовала и была прочитана через `ls -lah`; содержимое отдельных `cam*/` и MKV **ещё не инвентаризировали в этом сеансе**, поэтому не объявлять новые/старые сегменты проверенными. На `.2` `nand-audit.sh` уже дал 5×PASS: внутренний `/opt`, `/tmp` RAM и три runtime tmpfs.

**Цель по запросу владельца:** запись основных RTSP каналов **101/201/301** с архивом около **72 часов** и управлением заполнением. В терминах кандидатной v2.5 это может быть `HYBRID` + 72h, **но HYBRID имеет право удалять старые сегменты РАНЬШЕ 72 часов** при нехватке места. Если нужен жёсткий минимум 72h, выбирается `TIME` + 72h и заранее обеспечивается место. Окончательный режим владелец выберет после безопасной аппаратной проверки.

**Безопасный следующий шаг (только чтение):**

```sh
D=/tmp/mnt/f9bf834b-5650-d901-f0aa-834b5650d901
df -h "$D"
grep -F " $D " /proc/mounts
ls -ld "$D/cctv" "$D/cctv"/cam101 "$D/cctv"/cam201 "$D/cctv"/cam301 "$D/cctv"/.nvr-v2
for c in 101 201 301; do
  echo "=== cam$c: latest entries ==="
  ls -lt "$D/cctv/cam$c" | head -n 6
done
```

НЕ запускать `setup.sh install` / `fresh-install.sh` поверх единственного существующего архива; не запускать `cleanup_cctv.sh`, старые `record_cctv.sh`, cron/watchdog/retention, `CIRCULAR` или `HYBRID`, пока не проверены архив, старые конфиги, backup/preview. По [MESH-RECOVERY](NVR/v2/MESH-RECOVERY.md) сценарий C — **восстановление**, а не чистая установка. Переход v2.4→v2.5 пока **не реализован** ([#13](https://github.com/saymer-alt/keenetic-nvr/issues/13)).

## Первоначальные границы проверки (устарели после следующего этапа)

**Аппаратно PASS:** Entware/UBIFS обоих KN-1012, KAS S00ubifs и NAND audit на обоих, FFmpeg 6.1.4 на `.3`, STREAM preflight/install/start/status и реальное видео на Sony через Selenga со старым плейлистом и указанными путями. Нет требования тестировать VLC: целевой приёмник — Selenga/ЭЛТ.

**НЕ ПРОВЕРЕНО:** reboot и автозапуск (осознанно отложены), длинный STREAM soak-test, поведение после обрыва HTTP/RTSP, ресурсные показатели во время длительной трансляции; на `.2` ещё не восстановлены NVR и Telegram, запись нового MKV, retention/удаление старше 72h, пропадание USB, политика v2.5 на отдельном тестовом диске.

Текущее окончание восстановления подробно описано в [финальном протоколе](FIELD-ACCEPTANCE-2026-10-18.md). Релиз `v2.5.0` **не выпускать** до закрытия аппаратной приёмки [#7](https://github.com/saymer-alt/keenetic-nvr/issues/7) и выполнения условий [#10](https://github.com/saymer-alt/keenetic-nvr/issues/10). Дополнительные задачи: [#14](https://github.com/saymer-alt/keenetic-nvr/issues/14) NAND, [#15](https://github.com/saymer-alt/keenetic-nvr/issues/15) Mesh recovery.