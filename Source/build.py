#!/usr/bin/env python3
"""Rebuild the local app; external disk operations are never part of the build."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--ui-only', action='store_true')
args = parser.parse_args()
source = Path(__file__).resolve().parent
root = source.parent
app = root / 'VolumeBridge.app'
contents = app / 'Contents'

# Local rebuilds reuse the existing pinned identity and Bundle ID.
# The public repository omits the machine-specific certificate. Fresh clones
# use an ad-hoc signature unless a SHA-1 signing identity is supplied.
certificate = source / 'NTFSDesk-Local-Signing.cer'
signing_identity = os.environ.get('VOLUMEBRIDGE_SIGNING_IDENTITY')
if not signing_identity:
    signing_identity = hashlib.sha1(certificate.read_bytes()).hexdigest().upper() if certificate.is_file() else '-'
bundle_id = os.environ.get('VOLUMEBRIDGE_BUNDLE_ID',
    'local.hndrx.NTFSDesk' if certificate.is_file() else 'io.github.volumebridge.VolumeBridge')
designated_requirement = None
if signing_identity != '-':
    identities = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                               check=True, capture_output=True, text=True).stdout
    if signing_identity not in identities:
        raise SystemExit('The selected VolumeBridge signing identity is unavailable in the keychain.')
    if len(signing_identity) != 40 or any(c not in '0123456789ABCDEFabcdef' for c in signing_identity):
        raise SystemExit('VOLUMEBRIDGE_SIGNING_IDENTITY must be a certificate SHA-1 fingerprint.')
    designated_requirement = 'designated => identifier "' + bundle_id + '" and anchor = H"' + signing_identity + '"'

def run(argv, cwd=None, env=None):
    subprocess.run([str(x) for x in argv], cwd=cwd, env=env, check=True)

for directory in ['MacOS', 'Resources/driver/sbin', 'Frameworks', 'Resources/Licenses']:
    (contents / directory).mkdir(parents=True, exist_ok=True)

if not args.ui_only:
    for tool in ['autoreconf', 'automake', 'glibtoolize', 'pkg-config']:
        if not shutil.which(tool):
            raise SystemExit('Build prerequisites: brew install autoconf automake libtool pkgconf libgcrypt')
    with tempfile.TemporaryDirectory(prefix='NTFSDesk-build-') as temp:
        work = Path(temp)
        pkg = work / 'fuse-t.pkg'
        url = 'https://github.com/macos-fuse-t/fuse-t/releases/download/1.2.7/fuse-t-macos-installer-1.2.7.pkg'
        urllib.request.urlretrieve(url, pkg)
        expected = '6a29c747e61a86a405a189efc3de42812d73147135f93a1bb0624c1e7b90e654'
        assert hashlib.sha256(pkg.read_bytes()).hexdigest() == expected, 'FUSE-T package checksum mismatch'
        run(['pkgutil', '--check-signature', pkg])
        run(['pkgutil', '--expand-full', pkg, work / 'package'])
        framework = work / 'package/fuse-t-core.pkg/Payload/Library/Frameworks/fuse_t.framework'
        bundled = contents / 'Frameworks/fuse_t.framework'
        if bundled.exists(): shutil.rmtree(bundled)
        run(['ditto', framework, bundled])
        src = work / 'ntfs-3g'
        src.mkdir()
        with tarfile.open(source / 'ntfs-3g-f0e5cb0.tar.gz') as archive:
            archive.extractall(src, filter='data')
        makefile = src / 'src/Makefile.am'
        text = makefile.read_text()
        text = text.replace('-I/usr/local/include/fuse', '-I' + str(framework / 'Headers'))
        text = text.replace('FUSE_LIBS   = -lfuse-t', 'FUSE_LIBS   = ' + str(framework / 'fuse_t'))
        makefile.write_text(text)
        run(['./autogen.sh'], cwd=src)
        run(['./configure', '--prefix=' + str(work / 'driver'), '--disable-shared', '--enable-static',
             '--disable-crypto', '--disable-plugins', '--disable-ldconfig',
             'LDFLAGS=-Wl,-rpath,@executable_path/../../../Frameworks'], cwd=src)
        run(['make', '-j4'], cwd=src)
        shutil.copy2(src / 'src/ntfs-3g', contents / 'Resources/driver/sbin/ntfs-3g')
        shutil.copy2(src / 'ntfsprogs/mkntfs', contents / 'Resources/driver/sbin/mkntfs')

run(['swiftc', '-parse-as-library', '-O', source / 'VolumeBridge.swift', '-o', contents / 'MacOS/VolumeBridge'])
metadata = {'CFBundleExecutable': 'VolumeBridge', 'CFBundleIdentifier': bundle_id,
            'CFBundleName': 'VolumeBridge', 'CFBundleDisplayName': 'VolumeBridge', 'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': '0.2.1', 'CFBundleVersion': '11', 'LSMinimumSystemVersion': '14.0',
            'CFBundleDevelopmentRegion': 'en', 'CFBundleLocalizations': ['zh-Hans', 'en', 'ja'],
            'NSRemovableVolumesUsageDescription': '读取和挂载你选择的外接 NTFS 磁盘。',
            'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication'}
(contents / 'Info.plist').write_bytes(plistlib.dumps(metadata))
for license_file in (root / 'Licenses').iterdir():
    shutil.copy2(license_file, contents / 'Resources/Licenses' / license_file.name)
for localization in (source / 'Localizations').glob('*.lproj'):
    shutil.copytree(localization, contents / 'Resources' / localization.name, dirs_exist_ok=True)
sign_command = ['codesign', '--force', '--sign', signing_identity, '--timestamp=none']
if designated_requirement:
    sign_command += ['--requirements', '=' + designated_requirement]
run(sign_command + [app])
run(['codesign', '--verify', '--deep', '--strict', app])
if designated_requirement:
    run(['codesign', '--verify', '-R', '=' + designated_requirement.removeprefix('designated => '), app])
print('Built:', app)
