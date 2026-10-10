# NVR v1 + HTTP Streaming — исторический архив

**Не применять как текущий установщик.** Эта схема сохранена для истории и анализа миграции. Рабочий проект v2.4: [README](../../README.md) и [NVR/v2](../../NVR/v2/README.md).

Приведённые ниже скрипты описывают первоначальный подход и имеют иные гарантии, чем v2.4. Аудит v1: [AUDIT.md](AUDIT.md).

Набор скриптов для превращения роутеров Keenetic (Entware) в автономный NVR и/или HTTP-вещатель для IP-камер. Тестировалось на Keenetic 1012 (MediaTek Filogic) — запись трёх потоков H.265 (2K) даёт почти нулевую нагрузку на CPU благодаря `-c copy`.

## Возможности

**NVR (запись архива)**
- Захват RTSP без транскодирования.
- Нарезка на файлы по 15 минут.
- Автозапуск после перезагрузки с ожиданием USB-диска (до 60 сек).
- Watchdog через встроенный RTSP socket timeout ffmpeg (`-timeout`, микросекунды).
- `stop` использует сохранённые PID ffmpeg; ограничения stale PID/PID reuse описаны в [AUDIT.md](AUDIT.md).
- Кольцевой буфер: автоудаление файлов старше 3 суток.

**Streaming (вещание на ТВ)**
- HTTP MPEG-TS для IPTV-приставок (Selenga, VLC, Kodi).
- Видео — copy, звук — AAC.
- Лечение потока: `+genpts` и `+resend_headers` для капризных железных плееров.
- Авто-перезапуск порта при отключении клиента.

## Архитектура

| Роутер | Роль | Инструмент |
|---|---|---|
| **Первый** | Ядро сети, VPN | KeeneticOS |
| **Второй** | Архив, кольцевой буфер | `ffmpeg` + `segment` |
| **Третий** | Живой эфир на ТВ | `ffmpeg` + `-listen 1` |

Разделение труда. Никаких Docker, никаких `go2rtc`.

## Требования

- Keenetic с Entware и USB-диском (для NVR желателен EXT4/exFAT).
- Пакеты:
  ```sh
  opkg update
  opkg install ffmpeg cron
  ```

---

## Часть 1. NVR — запись архива

### 1. Папки

```sh
mkdir -p /tmp/mnt/YOUR_USB_DRIVE/cctv/cam101
mkdir -p /tmp/mnt/YOUR_USB_DRIVE/cctv/cam201
mkdir -p /tmp/mnt/YOUR_USB_DRIVE/cctv/cam301
```

### 2. `record_cctv.sh`

Сохраните в `/tmp/mnt/YOUR_USB_DRIVE/cctv/record_cctv.sh`. Замените `YOUR_*`.

```bash
#!/bin/sh

BASE_DIR="/tmp/mnt/YOUR_USB_DRIVE/cctv"
RTSP_USER="YOUR_USERNAME"
RTSP_PASS="YOUR_PASSWORD"
RTSP_IP="192.168.1.XXX"

# Ждем USB-диск после перезагрузки (до 60 сек)
WAIT=0
while [ ! -d "$BASE_DIR" ] && [ $WAIT -lt 60 ]; do
    sleep 5
    WAIT=$((WAIT + 5))
done

if [ ! -d "$BASE_DIR" ]; then
    echo "ERROR: Disk not mounted!" >&2
    exit 1
fi

if [ -f /tmp/cctv_is_running ]; then
    echo "CCTV already running."
    exit 0
fi

touch /tmp/cctv_is_running

start_recording() {
    CAM_ID=$1
    DIR="$BASE_DIR/cam$CAM_ID"
    mkdir -p "$DIR"
    URL="rtsp://$RTSP_USER:$RTSP_PASS@$RTSP_IP:554/Streaming/Channels/$CAM_ID"
    
    (
        while [ -f /tmp/cctv_is_running ]; do
            rm -f /tmp/cctv_cam${CAM_ID}.pid
            
            /opt/bin/ffmpeg -hide_banner -loglevel error \
                -timeout 15000000 \
                -rtsp_transport tcp -i "$URL" \
                -c copy -f segment -segment_time 900 \
                -strftime 1 -reset_timestamps 1 \
                "$DIR/cam${CAM_ID}_%Y-%m-%d_%H-%M-%S.mkv" > /dev/null 2>&1 &
            
            PID=$!
            echo $PID > /tmp/cctv_cam${CAM_ID}.pid
            wait $PID 2>/dev/null
            rm -f /tmp/cctv_cam${CAM_ID}.pid
            
            sleep 5
        done
    ) > /dev/null 2>&1 &
}

start_recording "101"
start_recording "201"
start_recording "301"

echo "CCTV recording started in watchdog mode."
```

### 3. `S99cctv` (автозагрузка)

Сохраните в `/opt/etc/init.d/S99cctv`.

```bash
#!/bin/sh

SCRIPT_PATH="/tmp/mnt/YOUR_USB_DRIVE/cctv/record_cctv.sh"

case "$1" in
    start)
        if [ -f /tmp/cctv_is_running ]; then
            echo "CCTV already running."
            exit 0
        fi
        echo "Starting CCTV recording..."
        sh "$SCRIPT_PATH"
        ;;
    stop)
        echo "Stopping CCTV recording..."
        rm -f /tmp/cctv_is_running
        sleep 12
        
        for pidfile in /tmp/cctv_cam*.pid; do
            [ -f "$pidfile" ] || continue
            PID=$(cat "$pidfile")
            kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null
            rm -f "$pidfile"
        done
        ;;
    restart)
        $0 stop
        sleep 2
        $0 start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac
```

### 4. `cleanup_cctv.sh`

```bash
#!/bin/sh
find /tmp/mnt/YOUR_USB_DRIVE/cctv/ -name "*.mkv" -type f -mtime +3 -delete
```

Если `find` не поддерживает `-delete`, замените на:
```bash
-exec rm -f {} +
```

### 5. Cron

```sh
nano /opt/etc/crontab
```

Добавьте:
```text
0 * * * * root sh /tmp/mnt/YOUR_USB_DRIVE/cctv/cleanup_cctv.sh
```

Перезапустить:
```sh
/opt/etc/init.d/S10cron restart
```

### 6. Права и старт

```sh
chmod 700 /tmp/mnt/YOUR_USB_DRIVE/cctv/record_cctv.sh   # содержит RTSP credentials
chmod 755 /tmp/mnt/YOUR_USB_DRIVE/cctv/cleanup_cctv.sh
chmod 755 /opt/etc/init.d/S99cctv

/opt/etc/init.d/S99cctv start
```

---

## Часть 2. Streaming — вещание на ТВ

### `S99stream`

Сохраните в `/opt/etc/init.d/S99stream`.

```bash
#!/bin/sh

RTSP_USER="YOUR_USERNAME"
RTSP_PASS="YOUR_PASSWORD"
RTSP_IP="192.168.1.XXX"
SCRIPT_NAME="stream"

start_stream() {
    CAM_ID=$1
    PORT=$2
    URL="rtsp://$RTSP_USER:$RTSP_PASS@$RTSP_IP:554/Streaming/Channels/$CAM_ID"
    
    (
        while [ -f /tmp/${SCRIPT_NAME}_is_running ]; do
            if [ -f /tmp/${SCRIPT_NAME}_cam${CAM_ID}.pid ]; then
                OLD_PID=$(cat /tmp/${SCRIPT_NAME}_cam${CAM_ID}.pid)
                kill -0 $OLD_PID 2>/dev/null || rm -f /tmp/${SCRIPT_NAME}_cam${CAM_ID}.pid
            fi
            
            /opt/bin/ffmpeg -hide_banner -loglevel error \
                -fflags +genpts \
                -rtsp_transport tcp -i "$URL" \
                -map 0:v:0 -map 0:a? \
                -c:v copy -c:a aac -b:a 64k \
                -f mpegts -mpegts_flags +resend_headers -listen 1 \
                "http://0.0.0.0:$PORT/stream$CAM_ID.ts" > /dev/null 2>&1 &
            
            PID=$!
            echo $PID > /tmp/${SCRIPT_NAME}_cam${CAM_ID}.pid
            
            wait $PID 2>/dev/null
            rm -f /tmp/${SCRIPT_NAME}_cam${CAM_ID}.pid
            
            sleep 3
        done
    ) > /dev/null 2>&1 &
}

case "$1" in
    start)
        if [ -f /tmp/${SCRIPT_NAME}_is_running ]; then
            echo "Stream already running."
            exit 0
        fi
        echo "Starting CCTV HTTP streams..."
        touch /tmp/${SCRIPT_NAME}_is_running
        
        # Для аппаратных IPTV-приставок рекомендуется субпоток H.264 (102/202/302).
        # Если приставка тянет H.265 — используйте основной поток (101/201/301).
        start_stream "102" "8999"
        start_stream "202" "9000"
        start_stream "302" "9001"
        
        echo "Done."
        ;;
    stop)
        echo "Stopping CCTV HTTP streams..."
        rm -f /tmp/${SCRIPT_NAME}_is_running
        
        for pidfile in /tmp/${SCRIPT_NAME}_cam*.pid; do
            [ -f "$pidfile" ] || continue
            PID=$(cat "$pidfile")
            kill -TERM "$PID" 2>/dev/null
        done
        
        sleep 3
        
        for pidfile in /tmp/${SCRIPT_NAME}_cam*.pid; do
            [ -f "$pidfile" ] || continue
            PID=$(cat "$pidfile")
            kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null
            rm -f "$pidfile"
        done
        ;;
    restart)
        $0 stop
        sleep 2
        $0 start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac
```

### Запуск

```sh
chmod 700 /opt/etc/init.d/S99stream   # содержит RTSP credentials
/opt/etc/init.d/S99stream start
```

### URL для плеера

```
http://IP_РОУТЕРА:8999/stream102.ts
http://IP_РОУТЕРА:9000/stream202.ts
http://IP_РОУТЕРА:9001/stream302.ts
```

---

## Важные ограничения

- RTSP-логин и пароль хранятся в открытом виде в `record_cctv.sh` и `S99stream`; поэтому файлы с credentials рекомендуется держать с правами `700`.
- PID-файлы уменьшают риск остановки чужих процессов, но не исключают редкий сценарий stale PID/PID reuse. Текущие скрипты не сверяют `/proc/$PID/cmdline` перед `kill`.
- Маркер `/tmp/cctv_is_running` — простой lock-файл, а не проверка живости всех ffmpeg-процессов. После аварийного завершения управляющего shell в той же загрузке может потребоваться `stop`/удаление stale marker перед повторным `start`.
- Технический аудит без запуска на роутере — в [AUDIT.md](AUDIT.md). До повторного реального теста раздел остаётся `candidate`, а не canonical.

## Лайфхаки и траблшутинг

**Приставка виснет/чёрный экран**
- Убедитесь, что в камере для субпотока включён звук: **Video & Audio** (не просто Video).
- Если картинка есть, но нет звука — проверьте настройки аудио на субпотоке в веб-интерфейсе камеры.

**Файлы в архиве разной длины (не ровно 15 мин)**
- Нормально для H.265+/Smart Codec. Камера редко шлёт ключевые кадры при статической картинке, а ffmpeg режет только по ним. Размер файла при этом пропорционален времени.

**Задержка на ТВ 10–15 секунд**
- Буферизация MPEG-TS + Wi-Fi. На проводе будет меньше. Это не баг.

**`ffmpeg: not found`**
- Проверьте `which ffmpeg`. Если пусто — `opkg install ffmpeg`.

## Лицензия

MIT. Главное — не пишите архив во внутреннюю память роутера. 😄
