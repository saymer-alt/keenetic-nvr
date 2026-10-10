# Keenetic NVR

[![NVR CI](https://github.com/saymer-alt/keenetic-nvr/actions/workflows/nvr-ci.yml/badge.svg)](https://github.com/saymer-alt/keenetic-nvr/actions/workflows/nvr-ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Автономный резервный видеорегистратор для Keenetic с Entware.** Забирает RTSP-потоки камер, сохраняет MKV на USB-диск, автоматически восстанавливает отказавшие процессы FFmpeg и сообщает о проблемах через Telegram. Команды Telegram позволяют проверять текущую запись без SSH.

> **Текущая версия: NVR v2.4 (основной код в `NVR/v2/`).**
> Работа на Keenetic KN-1012 подтверждена 10 октября 2026 года. Проверенные и ещё не проверенные сценарии перечислены ниже. Репозиторий выделен из [keenetic-knowledge-base](https://github.com/saymer-alt/keenetic-knowledge-base).

## Возможности

- **RTSP → MKV без перекодирования** (`ffmpeg -c copy`). Сегменты примерно по 15 минут, нарезка зависит от ключевых кадров.
- **Архив минимум 72 часа** от `mtime` завершённого сегмента. Почасовая очистка не сокращает срок хранения даже при нехватке места.
- **Watchdog** раз в 5 минут: проверяет процессы и свежесть файлов каждого канала, перезапускает проблемную камеру с задержкой повторов.
- **Статус и журнал**: `HEALTHY`, `DEGRADED`, `PAUSED`, `NO-DISK`; диск, последнее обновление видео, очистка и ошибки.
- **Telegram-оповещения** о сбоях камер, недоступности накопителя, ошибках очистки, заполнении и восстановлении. Дополнительно — HTTPS webhook.
- **Telegram по запросу** (`/status`, `/cameras`, `/disk`, `/help`): отдельный модуль только для чтения, принимает команды лишь из настроенного приватного чата.
- **Установка, обновление и откат** с резервными копиями. Секреты остаются локально на роутере.

## Проверено на реальном Keenetic

| Испытание 10.10.2026, KN-1012 | Результат |
| --- | --- |
| Обновление с v2.3 на v2.4, восстановление двух заданий Cron | **PASS** |
| Запись всех трёх каналов 101/201/301, свежие MKV | **PASS — 3/3 HEALTHY** |
| Watchdog по Cron, диск RW | **PASS** |
| Автоматический запуск очистки по Cron в 15:03 | **PASS**, OK, удалено 0 файлов |
| Telegram: тестовое аварийное уведомление | **PASS — HTTP 200, доставлено** |
| Telegram: /status, /cameras, /disk, /help | **PASS — ответы доставлены в 15:37–15:39** |
| Реальное удаление архивных MKV старше 72 часов | **Ещё не проверено на роутере** |
| Принудительный отказ камеры и автоматическое восстановление | **Ещё не проверено** |
| Перезагрузка Keenetic и автоматическое восстановление записи | **Ещё не проверено** |
| Чистая установка на втором устройстве и фактический rollback | **Ещё не проверено** |

Успешная очистка с `REMOVED FILES: 0` подтверждает, что задание выполнилось, **но не подтверждает удаление истёкших сегментов**. Офлайн-тесты этой логики входят в CI. Полный журнал: [CHANGELOG](NVR/v2/CHANGELOG.md); ограничения: [KNOWN-LIMITATIONS](NVR/v2/KNOWN-LIMITATIONS.md).

## Быстрый старт (новый Keenetic)

Нужны Keenetic с Entware, отдельный USB-диск **EXT4** под видеоархив (не системный диск Entware), доступ к RTSP и пакеты `ffmpeg`, `cron`, `curl`, `coreutils-stat`. Интерактивный установщик поможет поставить недостающие пакеты.

На **новом** роутере с уже установленным Entware, подключённым отдельным
USB-диском EXT4 и открытым интерактивным SSH-терминалом запустите **одну команду**:

```sh
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-nvr/main/setup.sh | sh
```

Это запускает **полную установку**, а не только preflight:
загрузчик проверит Entware, предложит установить недостающие
`ffmpeg`, `cron` и `coreutils-stat`, затем мастер спросит диск,
RTSP IP/логин/пароль (ввод скрыт), каналы, необязательные уведомления
и убедится, что появился свежий MKV каждой камеры. После проверки
добавятся задания Cron. Архивный диск не должен совпадать с диском Entware.

**Вариант с проверкой успешности скачивания `curl` и без передачи сети напрямую в shell**
(предпочтителен при нестабильном подключении):

```sh
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-nvr/main/setup.sh \
  -o /tmp/keenetic-nvr-setup.sh && \
sh -n /tmp/keenetic-nvr-setup.sh && sh /tmp/keenetic-nvr-setup.sh
```

Только предварительная проверка (может предложить доустановить пакеты):

```sh
sh /tmp/keenetic-nvr-setup.sh preflight
```

Последняя команда предполагает, что вы скачали файл вторым способом.

Установщик запросит параметры через `/dev/tty`, поэтому работает и
при `curl | sh`. Для **уже установленной** v2.4 повторная установка
блокируется: используйте команды статуса или отдельный сценарий обновления.
Конфигурация: `/opt/etc/nvr-v2.conf`, права `600`.

**Чистая установка ещё не подтверждена на втором физическом Keenetic**:
офлайн-тесты в CI не заменяют эту проверку.

### Обновление действующей v2.3

Для устройства **со старой v2.3**, не для чистой установки:

```sh
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-nvr/main/NVR/v2/bootstrap.sh -o /tmp/nvr-upgrade.sh
sh /tmp/nvr-upgrade.sh preflight-upgrade
```

После `Upgrade preflight PASS`:

```sh
sh /tmp/nvr-upgrade.sh upgrade
```

Установщик временно останавливает резервную запись, проверяет её возобновление и восстанавливает Cron. Резервная копия и инструмент отката находятся в `/opt/etc/nvr-v24-upgrade-backup/`. **Уже работающую v2.4 повторно обновлять этим сценарием не нужно.**

## Telegram: оповещения и статус из чата

Для нового бота создать API-токен через [@BotFather](https://t.me/BotFather), открыть чат с созданным ботом, отправить `/start` и сообщение.

Подключение оповещений к **уже установленной v2.4**:

```sh
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-nvr/main/NVR/v2/telegram-setup.sh -o /tmp/nvr-telegram-setup.sh
sh -n /tmp/nvr-telegram-setup.sh && sh /tmp/nvr-telegram-setup.sh
```

Для интерактивных запросов статуса: `opkg install jq` и опциональный cron-поллер.

```sh
opkg update && opkg install jq
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-nvr/main/NVR/v2/telegram-bot-install.sh -o /tmp/nvr-telegram-bot-install.sh
sh /tmp/nvr-telegram-bot-install.sh preflight
sh /tmp/nvr-telegram-bot-install.sh install
```

После этого отправляйте боту `/status`, `/cameras`, `/disk` или `/help`. Ответ приходит обычно в течение минуты (опрос Bot API по Cron). **Бот не может останавливать запись или удалять архив.** Токен хранится только в приватном конфиге роутера, вводить повторно для модуля команд его не нужно.

## Для администрирования и разработки

```sh
sh /opt/etc/nvr-v2.sh status
sh /opt/etc/nvr-v2.sh logs 50
sh /opt/etc/nvr-v2.sh notify test
```

Проверки разработчика в CI: синтаксис POSIX sh и BusyBox ash, ShellCheck, сценарии записи и хранения, Telegram/auth/replay, сканер секретов. Запуск на Linux с нужными инструментами:

```sh
sh tests/smoke.sh
sh tests/retention-cases.sh
sh tests/notify-logic.sh
sh tests/fresh-config-smoke.sh
sh tests/telegram-bot-commands.sh
sh tests/secrets-scan.sh
sh tests/source-links.sh
```

### Структура

| Путь | Назначение |
| --- | --- |
| [NVR/v2/README.md](NVR/v2/README.md) | Полная инструкция установки, обновления и диагностики |
| [NVR/v2/nvr.sh](NVR/v2/nvr.sh) | Запись RTSP, watchdog, очистка и диагностика |
| [NVR/v2/telegram-bot.sh](NVR/v2/telegram-bot.sh) | Ответы на команды Telegram (только чтение) |
| [NVR/v2/ARCHITECTURE.md](NVR/v2/ARCHITECTURE.md) | Архитектура, безопасность, хранение состояния |
| [NVR/v2/CHANGELOG.md](NVR/v2/CHANGELOG.md) | Изменения и фактические испытания |
| [NVR/v2/KNOWN-LIMITATIONS.md](NVR/v2/KNOWN-LIMITATIONS.md) | Известные ограничения и дальнейшие задачи |
| [tests/](tests/) | Офлайн-тесты, выполняемые GitHub Actions |
| [legacy/v1/](legacy/v1/) | Исторические скрипты NVR v1 и HTTP-вещания, **не используйте для установки v2.4** |

## Совместимость и безопасность

Старые файлы в `keenetic-knowledge-base/NVR/v2/` сохранены для совместимости уже опубликованных команд. **Новый основной адрес проекта — `saymer-alt/keenetic-nvr`.** Существующие роутеры не требуется перенастраивать только ради переноса кода в GitHub.

Никогда не публикуйте содержимое `/opt/etc/nvr-v2.conf`, токены Telegram, RTSP-пароли, полные выводы `ps` или видеоархивы. RTSP URL может быть виден локально в параметрах процесса FFmpeg; выделенная RTSP-учётная запись рекомендуется.

Лицензия: [MIT](LICENSE). Обратная связь — через GitHub Issues этого репозитория.
