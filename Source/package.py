#!/usr/bin/env python3
"""Build a relocatable Apple Silicon preview DMG from committed sources.

The existing local application supplies the bundled driver/framework only.
The release app is rebuilt in isolation with its public Bundle ID and an ad-hoc
signature. The locally installed application and its signing identity stay intact.
"""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, default=root / 'dist')
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)

def run(command, **kwargs):
    return subprocess.run([str(v) for v in command], check=True, **kwargs)

local_app = root / 'VolumeBridge.app'
if not local_app.is_dir():
    raise SystemExit('Run Source/build.py first to build the bundled driver and framework.')
version = plistlib.loads((local_app / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
stem = f'VolumeBridge-{version}-arm64'
dmg = output / (stem + '.dmg')
source_zip = output / f'VolumeBridge-{version}-source.zip'
if dmg.exists() or source_zip.exists():
    raise SystemExit('Release files already exist; choose a new output directory.')

with tempfile.TemporaryDirectory(prefix='VolumeBridge-package-') as directory:
    temp = Path(directory)
    archive = temp / 'source.tar'
    run(['git', '-C', root, 'archive', '--format=tar', '-o', archive, 'HEAD'])
    checkout = temp / 'source'
    checkout.mkdir()
    with tarfile.open(archive) as content:
        content.extractall(checkout, filter='data')
    run(['ditto', local_app, checkout / 'VolumeBridge.app'])
    env = {**os.environ, 'VOLUMEBRIDGE_SIGNING_IDENTITY': '-',
           'VOLUMEBRIDGE_BUNDLE_ID': 'io.github.volumebridge.VolumeBridge'}
    run(['python3', checkout / 'Source/build.py', '--ui-only'], env=env)
    app = checkout / 'VolumeBridge.app'
    for binary in [app / 'Contents/MacOS/VolumeBridge',
                   app / 'Contents/Resources/driver/sbin/ntfs-3g',
                   app / 'Contents/Resources/driver/sbin/mkntfs']:
        arch = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip()
        if arch != 'arm64':
            raise SystemExit(f'Expected arm64 binary, got {arch}: {binary}')
    run(['python3', checkout / 'Tests/test_regressions.py'])
    run(['python3', checkout / 'Source/test_localization.py'])
    # This creates and mounts only a temporary 64 MB disk image.
    run([app / 'Contents/MacOS/VolumeBridge', '--language', 'en', '--self-test'])
    stage = temp / 'dmg'
    stage.mkdir()
    run(['ditto', app, stage / 'VolumeBridge.app'])
    (stage / 'Applications').symlink_to('/Applications')
    shutil.copytree(checkout / 'Licenses', stage / 'Licenses')
    shutil.copy2(checkout / 'THIRD_PARTY_NOTICES.md', stage / 'THIRD_PARTY_NOTICES.md')
    (stage / 'Sources').mkdir()
    shutil.copy2(checkout / 'Source/ntfs-3g-f0e5cb0.tar.gz', stage / 'Sources')
    shutil.copy2(checkout / 'Source/build.py', stage / 'Sources')
    (stage / 'INSTALL.txt').write_text('''VolumeBridge - Apple Silicon preview

Requires Apple Silicon and macOS 14 or later.
Drag VolumeBridge.app to Applications, then open it there.
The NTFS-3G driver and FUSE-T framework are bundled with the app.

This preview is ad-hoc signed and has not been notarized by Apple.
macOS may block the first launch. After reviewing the source and release,
use System Settings > Privacy & Security > Open Anyway if macOS offers it.
Keep macOS security protections enabled.

Enable VolumeBridge in Privacy & Security > Full Disk Access for NTFS access.
Mount-mode changes request administrator authorization.
Languages: English, Japanese, Simplified Chinese (gear menu > Language).

FUSE-T's binary license permits non-commercial use; commercial use or
bundling with commercial software requires a license from its authors.
See Licenses and THIRD_PARTY_NOTICES.md. NTFS-3G source and build recipe
are included in Sources; the complete project source is attached to the release.
''', encoding='utf-8')
    run(['hdiutil', 'create', '-volname', 'VolumeBridge', '-srcfolder', stage,
         '-format', 'UDZO', '-ov', dmg])
    run(['hdiutil', 'verify', dmg])
    run(['git', '-C', root, 'archive', '--format=zip', '--prefix=volume-bridge/', '-o', source_zip, 'HEAD'])

checksum = output / f'VolumeBridge-{version}-SHA256SUMS.txt'
checksum.write_text(''.join(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n'
                            for path in [dmg, source_zip]))
print('Packaged:', dmg)
print('Source:', source_zip)
print('Checksums:', checksum)
