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
