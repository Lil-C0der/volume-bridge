# VolumeBridge

A native macOS utility for managing external NTFS drives, powered by NTFS-3G and FUSE-T. Built with SwiftUI. Supports English, Japanese and Simplified Chinese.

[简体中文](README.zh-CN.md)

## Features

- Scan external physical disks and show format, mount mode and storage usage.
- Mount NTFS volumes for read/write, restore macOS read-only mounts, or safely eject.
- Open mounted volumes in Finder; inspect device and volume details.
- Switch language from the gear menu. Selection persists across launches.
- Verify read/write with an isolated 64 MB disk image.

NTFS volumes appear first, followed by other formats. Names use natural sorting within each group.

## Requirements and build

macOS 14 or later and the Swift compiler from Xcode Command Line Tools are required. Tested on Apple Silicon; other macOS versions and architectures need further validation.

For a full build, install the build tools and run:

```sh
brew install autoconf automake libtool pkgconf libgcrypt
python3 Source/build.py
open VolumeBridge.app
```

The build downloads the official FUSE-T 1.2.7 installer, checks its SHA-256 and package signature, extracts the framework, and builds NTFS-3G from the included source archive. The resulting app bundles both components. Internet access is required for the full build.

After a full build, rebuild the Swift application only:

```sh
python3 Source/build.py --ui-only
```

Fresh clones use an ad-hoc signature. To use a certificate from your login keychain, provide its SHA-1 fingerprint and a stable Bundle ID:

```sh
VOLUMEBRIDGE_SIGNING_IDENTITY=YOUR_CERTIFICATE_SHA1 \
VOLUMEBRIDGE_BUNDLE_ID=your.stable.bundle.identifier \
python3 Source/build.py --ui-only
```

Stable signing helps macOS recognize updated builds as the same application. The original developer's local certificate is excluded from Git. Local rebuilds with that certificate preserve the earlier application identity.

## Disk access

Enable VolumeBridge in **System Settings → Privacy & Security → Full Disk Access**. Use the gear menu's permission shortcut to open this panel. Changing the mount mode requests administrator authorization through macOS.

Read/write uses `norecover`: NTFS-3G rejects volumes requiring recovery. A failed read/write mount attempts to restore native read-only access. Normal unmounting checks file use; close files and copy operations before switching modes or ejecting. Mount operations verify the external NTFS volume's UUID before proceeding.

FUSE-T exposes mounted drives through a local NFS service, so Finder may display them as network volumes. Existing installations retain `/Volumes/NTFSDesk-diskXsY` mount locations for compatibility. Application name, disk contents and file names remain independent of this internal path.

System and driver diagnostics retain their original text. macOS authorization dialogs and standard menus follow macOS language settings.

## Tests

```sh
python3 Tests/test_regressions.py
python3 Source/test_localization.py
```

Mount regression tests simulate commands and devices; they perform no disk operations. Localization tests validate the translation resources and helper diagnostics. The app's **Verify read/write** action performs a separate real image test.

## Repository contents

- `Source/VolumeBridge.swift`: UI, scanning and privileged mount entry point.
- `Source/Localizations/`: translated strings and permission descriptions.
- `Source/build.py`: reproducible application build and signing configuration.
- `Source/ntfs-3g-f0e5cb0.tar.gz`: bundled NTFS-3G source archive.
- `Tests/`: simulated mount regression tests.
- `Licenses/`: upstream license texts.

Generated `.app` bundles and local signing material are excluded from Git. Publish built apps separately through GitHub Releases when ready.

## Third-party components

NTFS-3G and FUSE-T retain their upstream licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and `Licenses/` for attribution and redistribution terms.
