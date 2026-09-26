#!/usr/bin/env python3
"""Build/install a non-debuggable service probe and verify a cached-process relaunch."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import zipfile

p = argparse.ArgumentParser()
p.add_argument('--serial', required=True)
p.add_argument('--zig', default='zig')
a = p.parse_args()
root = Path(__file__).resolve().parent
sdk = Path(os.environ['ANDROID_HOME'])
build_tools = sorted((sdk / 'build-tools').iterdir(), key=lambda x: tuple(map(int, x.name.split('.'))))[-1]
platform = sorted((sdk / 'platforms').glob('android-*'), key=lambda x: int(x.name.split('-')[1]))[-1]
adb = [str(sdk / 'platform-tools/adb'), '-s', a.serial]
package = 'com.labelle.services_probe'
def run(*args, **kwargs):
    return subprocess.check_output(list(map(str, args)), text=True, stderr=subprocess.STDOUT, **kwargs)
def logs():
    return run(*adb, 'logcat', '-d', '-s', 'SERVICE_ACCEPTANCE:I', '*:S')
def await_log(launch):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        found = re.search(r'pid=(\d+) launch=' + str(launch) + r' scene=(\S+) screenshot=(\S+) after=(\S+) debuggable=(\S+)', logs())
        if found:
            return found.groups()
        time.sleep(.2)
    raise AssertionError(logs())
run(a.zig, 'build', cwd=root)
with tempfile.TemporaryDirectory(prefix='labelle-services-') as temp:
    temp = Path(temp)
    raw = temp / 'probe.apk'
    run(build_tools / 'aapt', 'package', '-f', '-M', root / 'AndroidManifest.xml', '-I', platform / 'android.jar', '-F', raw)
    with zipfile.ZipFile(raw, 'a') as apk:
        apk.write(root / 'zig-out/lib/libprobe.so', 'lib/arm64-v8a/libprobe.so', compress_type=zipfile.ZIP_STORED)
    aligned = temp / 'aligned.apk'
    run(build_tools / 'zipalign', '-f', '4', raw, aligned)
    key = temp / 'test.keystore'
    run('keytool', '-genkeypair', '-keystore', key, '-storepass', 'android', '-keypass', 'android', '-alias', 'test', '-keyalg', 'RSA', '-validity', '1', '-dname', 'CN=Acceptance')
    run(build_tools / 'apksigner', 'sign', '--ks', key, '--ks-key-alias', 'test', '--ks-pass', 'pass:android', aligned)
    subprocess.run(adb + ['uninstall', package], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(run(*adb, 'install', '--no-incremental', aligned).strip())
    run(*adb, 'logcat', '-c')
    run(*adb, 'shell', 'am', 'start', '-W', '-n', package + '/android.app.NativeActivity', '--es', 'LABELLE_SCENE', 'probe', '--es', 'LABELLE_SCREENSHOT_PATH', '/sdcard/probe.png', '--es', 'LABELLE_SCREENSHOT_AFTER_SEC', '1')
    first = await_log(1)
    assert first[1:] == ('probe', '<unset>', '<unset>', 'false'), first
    # The native entry finishes its Activity, deliberately leaving its process alive.
    time.sleep(1)
    run(*adb, 'shell', 'am', 'start', '-W', '-n', package + '/android.app.NativeActivity')
    second = await_log(2)
    assert second[0] == first[0], (first, second)
    assert second[1:] == ('<unset>', '<unset>', '<unset>', 'false'), second
    print(logs().strip())
    print('PASS: real JNI extras, release screenshot gate, and same-PID plain relaunch cleanup')
    run(*adb, 'shell', 'am', 'force-stop', package)
