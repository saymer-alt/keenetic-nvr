# NVR technical audit — 2026-09-19

**Status:** Reviewed / candidate  
**Scope:** `README.md`, `record_cctv.sh`, `cleanup_cctv.sh`, `S99cctv`, `S99stream`  
**Environment assumed by the project:** Keenetic + Entware + USB storage + FFmpeg  
**Live-router test in this audit:** not performed

## Result

The NVR/streaming mini-project is structurally reusable, but it should still be treated as
**candidate documentation**, not canonical operational guidance, until it is exercised again
on a current Keenetic/Entware installation.

One current compatibility problem was confirmed and fixed:

- `record_cctv.sh` used the old FFmpeg RTSP option `-stimeout`;
- FFmpeg renamed the socket I/O option to `timeout` after the old RTSP options were removed;
- the script and README now use `-timeout 15000000` (15,000,000 microseconds = 15 seconds).

Current Entware still distributes FFmpeg 6.x, so keeping the old `-stimeout` spelling would
make the saved recipe unreliable on a fresh installation.

## What was checked

### Recording path

The recorder:

1. waits up to 60 seconds for the configured USB directory;
2. uses a marker file to represent requested running state;
3. starts one watchdog shell per camera stream;
4. starts FFmpeg in stream-copy mode;
5. writes segmented MKV files with timestamped names;
6. waits for FFmpeg exit and restarts it after 5 seconds while the marker exists.

The architecture is simple and suitable for low-CPU recording because video is not
transcoded.

### Streaming path

`S99stream`:

- starts three independent HTTP listeners;
- copies video;
- optionally maps audio and encodes it to AAC;
- restarts a listener after its FFmpeg process exits;
- uses per-stream PID files for stop handling.

The typo in the README launch path (`/opt/etc.init.d/...`) was corrected to
`/opt/etc/init.d/...`.

### Retention

`cleanup_cctv.sh` deletes matching MKV files using `find -mtime +3 -delete`.

The README already documents an `-exec rm -f {} +` fallback for implementations of
`find` without `-delete`.

The exact retention boundary is based on `find -mtime` semantics rather than an exact
72-hour timer; this audit does not change that behavior.

### Cron

The existing instructions use the standalone Entware `cron` package:

- `opkg install cron`;
- system crontab at `/opt/etc/crontab`;
- a user field such as `root`;
- service `/opt/etc/init.d/S10cron`.

This matches the Entware cron package model. The package is still present in current Entware
feeds. The Entware wiki page describing this layout is old, so cron remains something worth
confirming on the target router during the next live test, but there was not enough evidence
to rewrite the instructions to BusyBox crond.

## Safety / reliability findings

### 1. RTSP credentials are plaintext

Both `record_cctv.sh` and `S99stream` contain RTSP username/password fields.

The README now recommends mode `700` for files containing those credentials instead of only
adding an executable bit.

This does not encrypt the credentials; it only limits local filesystem readability.

### 2. PID files are not process-identity validation

The stop routines read a numeric PID and signal it.

This is much safer than broad `killall ffmpeg`, but a stale PID can theoretically be reused
by an unrelated process. The current scripts do not validate `/proc/$PID/cmdline` before
sending a signal.

No code change was made because adding identity validation should be tested on actual
Keenetic/Entware `/proc` behavior rather than guessed.

### 3. The recording marker is a requested-state flag, not a health lock

`/tmp/cctv_is_running` tells watchdog shells that recording is requested.

It does not prove that all three FFmpeg processes or wrapper shells are alive. An abnormal
termination in the same boot can therefore leave a stale marker that makes a later `start`
say "already running".

A normal `stop` removes the marker. `/tmp` also normally clears on reboot.

### 4. Forced stop can truncate the current segment

`S99cctv stop` removes the marker, waits, then sends SIGKILL to any remaining FFmpeg PID.

This favors predictable shutdown over graceful container finalization. A segment being
written at that moment can be incomplete.

`S99stream` is better here: it first sends SIGTERM, waits, then uses SIGKILL only for
survivors.

Changing recorder shutdown behavior is deferred until a live test confirms what delay and
signal handling the Entware FFmpeg build needs.

### 5. Streaming is intentionally one-client-per-listener

FFmpeg `-listen 1` runs a listening HTTP output for a client session. When that FFmpeg exits,
the wrapper restarts it.

This is a lightweight direct stream, not a multi-client streaming server. If multiple
simultaneous viewers are needed, the architecture should change rather than multiplying
ad-hoc process logic.

### 6. Resource claims need a fresh measurement before canonical status

The README records a real historical observation that three H.265 2K streams in `-c copy`
mode gave almost no CPU load on a KN-1012-class device.

That is useful provenance, but this audit did not reproduce CPU, I/O, USB throughput,
temperature, or segment-integrity measurements.

## Changes made by this audit

- `record_cctv.sh`: `-stimeout 15000000` → `-timeout 15000000`.
- `README.md`: same FFmpeg option correction.
- `README.md`: fixed `/opt/etc.init.d/S99stream` typo.
- `README.md`: credential-containing scripts now use recommended mode `700`.
- `README.md`: PID/marker limitations are stated explicitly.
- No live router configuration was changed.
- No camera, network, firewall or Keenetic setting was changed.

## What remains before canonical status

A real-device validation should record:

1. `ffmpeg -version`;
2. successful RTSP connection with `-timeout`;
3. 15+ minutes of recording per configured stream;
4. restart after camera/network interruption;
5. `S99cctv stop/start/restart`;
6. cleanup cron execution;
7. stream connect/disconnect/reconnect;
8. CPU/RAM and USB write load;
9. whether current segments remain playable after forced shutdown;
10. whether stale PID/marker hardening is worth adding.

Until then, keep this mini-project at **candidate / reviewed** status.

## Related material

- [README.md](README.md)
- [record_cctv.sh](record_cctv.sh)
- [S99cctv](S99cctv)
- [S99stream](S99stream)
- [../INVENTORY.md](../INVENTORY.md)
