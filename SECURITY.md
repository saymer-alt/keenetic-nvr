# Security Policy

`SECURITY.md` documents coordinated disclosure; it **does not enable** GitHub Private Vulnerability Reporting. The availability of that feature must be verified separately.

## Supported scope

The v2.4 baseline was tested on KN-1012 on 2026-10-10. As of 2026-10-18, v2.5 **TIME/72h** has also passed partial real-device acceptance on KN-1012: 3/3 healthy MKV streams, preview and actual cleanup of 276 expired MKV files, active Cron watchdog, and Telegram alerts/read-only commands. The KAS `S00ubifs` runtime tmpfs guard was verified on both KN-1012 routers, and STREAM/v1 delivered actual MPEG-TS video to a Selenga 980 and Sony CRT. This **does not** establish full hardware acceptance of CIRCULAR/HYBRID, reboot recovery, USB-loss, forced camera failures, or a fresh install on a separate test disk; see issue #7 and [field report](FIELD-ACCEPTANCE-2026-10-18.md). Older revisions are not promised security support.

RTSP URL handling, passwords, install/bootstrap scripts, command arguments, temporary files, telemetry/Telegram bot tokens, webhook payloads, scheduled FFmpeg execution, video file access and cleanup. Never submit real camera access details.

## Report a vulnerability privately

1. Visit the repository's [Security Advisories](https://github.com/saymer-alt/keenetic-nvr/security/advisories).
2. If the **Report a vulnerability** button is present, use it to provide a private report.
3. If that button is absent, **do not submit technical details of the vulnerability in a public issue or pull request**. You may open an Issue titled **Request private security contact**, with only a general non-sensitive subject and a request for a private communication channel. This is not itself a private reporting channel.

There is no verified security contact email published by this project. Do not send secrets to contacts you have not confirmed.

## What to include in a private report

- Affected software/package version and environment.
- Potential impact and minimum reproduction with synthetic, non-secret fixtures.
- Relevant redacted evidence and uncertainty/limits of testing.
- Suggested mitigation, where available.

Do **not** attach genuine camera/VPS credentials, WARP accounts, private keys, token-bearing subscription URLs, Telegram tokens, personal information or confidential infrastructure inventory.

## Disclosure process

Please coordinate public disclosure with maintainers before releasing exploit details. Responses and patches are best-effort; no fixed security SLA is promised. Vulnerabilities in third-party upstream components may require separate upstream disclosure.

Non-sensitive bugs and feature ideas belong in [Issues](https://github.com/saymer-alt/keenetic-nvr/issues/new/choose).
