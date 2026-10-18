# Keenetic NVR v2.5.0-rc.1 — кандидат выпуска (18.10.2026)

> **Release candidate, не финальный production release.** На настоящих KN-1012 аппаратно проверены NVR TIME/72h и STREAM. Режимы CIRCULAR/HYBRID пока только CI; выпуск `v2.5.0` без суффикса остаётся заблокированным до [#7](https://github.com/saymer-alt/keenetic-nvr/issues/7) и [#10](https://github.com/saymer-alt/keenetic-nvr/issues/10).
>
> Этот документ — подготовленные release notes. Сам по себе он не создаёт GitHub Release или git-тег.

## Функции

- **NVR/v2:** RTSP → MKV без перекодирования, сегменты около 900 секунд, watchdog и почасовая очистка TIME/72h.
- **Storage modes v2.5:** TIME (только после заданного возраста `mtime`), CIRCULAR (по заполнению), HYBRID (по возрасту и заполнению). **CIRCULAR/HYBRID могут удалить раньше заданного срока**.
- **NAND safety:** Entware во внутренней UBIFS, runtime в RAM/tmpfs через KAS `S00ubifs`, архив только на отдельном USB EXT4, storage-guard отказывает при ненадёжном mount.
- **Telegram:** предупреждения и read-only команды `/status`, `/cameras`, `/disk`, `/help`.
- **STREAM/v1:** отдельный RTSP → HTTP MPEG-TS сервис для Selenga и аналогового ТВ без MKV и без cron очистки NVR.

## Реально проверено на KN-1012 18.10.2026

| Проверка | Результат |
| --- | --- |
| Два KN-1012, KeeneticOS 5.1.8, внутренний /opt UBIFS, KAS S00ubifs | NAND audit PASS, три runtime tmpfs |
| NVR на сохранённом USB EXT4 | Свежие MKV, CAM 101/201/301 все HEALTHY |
| TIME 72h — предварительная очистка | 276 кандидатов, 0 skipped, 0 failed |
| TIME 72h — реальное удаление | 276 MKV удалено, LAST CLEANUP OK, +14.9 GB свободного места |
| Cron watchdog | */5 check и HH:03 cleanup установлены, LAST CHECK обновлялся |
| Telegram notifications | Тестовое сообщение доставлено |
| Telegram read-only | /status, /cameras, /disk, /help — 4/4 PASS |
| STREAM/v1 | 3 WORKER UP, видео на Selenga 980 → Sony ЭЛТ (1992), субпотоки 102/202/302, HTTP 8999/9000/9001 |

Полный протокол: [FIELD-ACCEPTANCE-2026-10-18.md](FIELD-ACCEPTANCE-2026-10-18.md).

## Ещё НЕ проверено

- CIRCULAR и HYBRID на отдельном тестовом диске, а также сценарии низкого свободного места.
- Autostart STREAM/NVR после reboot, USB-loss/read-only, намеренный отказ камеры, длительный soak-test.
- Clean install v2.5 через мастер на отдельном роутере и автоматический upgrade v2.4→v2.5 (последний не реализован).
- Самостоятельное срабатывание нового Cron cleanup в HH:03 после сегодняшнего восстановления (ручное удаление прошло успешно).
- STREAM: несколько клиентов одного канала не поддерживаются `ffmpeg -listen 1`.

## Как пользоваться

Новая NVR — по [README](README.md), только со специально подготовленным отдельным EXT4 и проверкой `sh -n`; **не запускать fresh-install на уже существующих MKV**. Для такого диска использовать [MESH-RECOVERY](NVR/v2/MESH-RECOVERY.md), без форматирования. Конфиги с паролями и Telegram-токены держать только локально (0600), не публиковать `ps` с RTSP credentials.

STREAM устанавливать **отдельно** по [STREAM/v1/README](STREAM/v1/README.md), использовать [фактически проверенный M3U для Selenga](STREAM/v1/playlist/selenga-sony-1992.m3u).

Формальный GitHub Release должен ссылаться на неизменяемый тег или SHA после соответствующей проверки; релиз по этой документации **не означает автоматическую установку на работающие роутеры**.

## Путь к финальному v2.5.0

Закрыть аппаратные сценарии из [#7](https://github.com/saymer-alt/keenetic-nvr/issues/7), релизный gate [#10](https://github.com/saymer-alt/keenetic-nvr/issues/10); затем защищённый тег `v2.5.0` и публикация GitHub Release. До этого кандидат — **частично проверенная сборка**, а не полностью принятая v2.5.0.
