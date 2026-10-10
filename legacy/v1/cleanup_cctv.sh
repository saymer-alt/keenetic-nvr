#!/bin/sh
find /tmp/mnt/YOUR_USB_DRIVE/cctv/ -name "*.mkv" -type f -mtime +3 -delete
