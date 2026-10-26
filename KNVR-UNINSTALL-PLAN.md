# Simple KNVR removal and emulator validation — 2026-10-26

Owner request: implement simple removal now and run useful deferred KNVR tests
in router-emulator. No physical device required for these virtual checks.

## Contract

`sh uninstall.sh` asks for REMOVE; `--yes` supports an intentional unattended run.
Remove NVR v2 recorder, Telegram poller and the dedicated storage guard only.
Stop scheduled invocations first, wait for active controllers, call native stop,
verify no recorder writing this archive remains, then remove program files.
Preserve config, archive, bot offset, backups, packages, STREAM, shared S00ubifs,
Entware and unrelated cron entries. On failure report PARTIAL and retain remaining
program files for retry. No rollback cache, package removal, purge or formatting.
Legacy v1 removal is outside this command.

## Implementation plan

1. Add failing lifecycle tests using real NVR controller/process fixture and
   isolated crontab. Cover cancellation, removal/repeat/reinstall, foreign jobs,
   busy controller, partial stop and symlinks. Implement the minimal POSIX script,
   expose it through setup.sh remove and document preserved files.
2. Add an independent KNVR stage to router-emulator. Reuse authenticated Ported,
   native Entware and pinned packages; attach a separate real EXT4 archive image.
   Use real FFmpeg and a local synthetic RTSP source when available, label any
   process fixture explicitly. Test TIME, CIRCULAR, HYBRID on disposable segments,
   dry-run, open-file protection, RO/unmount/recovery, watchdog, removal, repeat,
   reboot and reinstall. Never interpret this as hardware acceptance.
3. Run repository suites, emulator integration and review. Publish source and
   sanitized exact results in PRs; report any unexecuted checks explicitly.

## Limits

Do not change real routers, firmware releases or upstream. Do not add v2.4→v2.5
upgrade behavior. NAND lifetime, physical USB, real cameras, Telegram delivery
and long running reliability require separate evidence.
