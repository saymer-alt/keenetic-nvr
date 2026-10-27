#!/usr/bin/env python3
"""Recorder launched by the real start_cam must survive an SSH PTY hangup.
The FFmpeg fixture writes bytes only; this tests process lifetime, not video.
"""
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='knvr-hangup-', dir='/tmp') as td:
    t = Path(td)
    (t/'mount/cctv').mkdir(parents=True)
    (t/'state').mkdir()
    subprocess.run(['gcc','-O2','-o',str(t/'ffmpeg'),str(ROOT/'tests/ffmpeg-stub.c')],check=True)
    (t/'mounts').write_text('/dev/test %s ext4 rw 0 0\n' % (t/'mount'))
    (t/'config').write_text("NVR_MOUNT='%s'\nNVR_BASE_DIR='%s'\nRTSP_USER='dummy'\nRTSP_PASS='fixture-only'\nRTSP_IP='192.0.2.1'\nNVR_MOUNTS_FILE='%s'\nNVR_STATE_DIR='%s'\nNVR_FFMPEG='%s'\n" % (t/'mount',t/'mount/cctv',t/'mounts',t/'state',t/'ffmpeg'))
    master, slave = pty.openpty()
    def terminal():
        os.setsid()
        fcntl.ioctl(0,termios.TIOCSCTTY,0)
    env = dict(os.environ,NVR_CONFIG=str(t/'config'),NVR_LIB_ONLY='1')
    proc = subprocess.Popen(['sh','-c','. "$1"; start_cam 101; echo READY; sleep 30','sh',str(ROOT/'NVR/v2/nvr.sh')],
        stdin=slave,stdout=slave,stderr=slave,env=env,preexec_fn=terminal)
    os.close(slave)
    child_pid = None
    try:
        output=b''
        until=time.monotonic()+10
        while b'READY' not in output:
            if time.monotonic()>until: raise AssertionError('controller did not launch recorder')
            if select.select([master],[],[],.2)[0]: output+=os.read(master,65536)
        child_pid=int((t/'state/cam101.pid').read_text())
        time.sleep(1)
        file=next((t/'mount/cctv/cam101').glob('*.mkv'))
        before=file.stat().st_size
        os.close(master);master=None
        time.sleep(2)
        assert file.stat().st_size>before, 'FFmpeg stopped writing after SSH PTY hangup'
        print('SSH disconnect recorder lifetime PASS')
    finally:
        if master is not None: os.close(master)
        for pid in (child_pid,proc.pid):
            if pid:
                try: os.kill(pid,signal.SIGTERM)
                except ProcessLookupError: pass
        try:proc.wait(timeout=5)
        except subprocess.TimeoutExpired:proc.kill();proc.wait()
