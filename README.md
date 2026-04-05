<p align="center">
  <img src="logo.png" width="120" alt="LifeOS AnyWhere logo" />
</p>

<h1 align="center">LifeOS AnyWhere</h1>

<p align="center">
  Share files instantly between all your devices on the same local network.<br/>
  No internet required. No cloud. No limits.
</p>

<p align="center">
  <a href="https://github.com/07erkanoz/lifeos-anywhere/releases/latest"><img src="https://img.shields.io/github/v/release/07erkanoz/lifeos-anywhere?label=download&style=for-the-badge" alt="Latest Release" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/07erkanoz/lifeos-anywhere?style=for-the-badge" alt="MIT License" /></a>
  <a href="https://github.com/07erkanoz/lifeos-anywhere/actions"><img src="https://img.shields.io/github/actions/workflow/status/07erkanoz/lifeos-anywhere/build-linux.yml?label=build&style=for-the-badge" alt="Build Status" /></a>
</p>

---

## Features

- **Zero-config discovery** -- devices find each other automatically via UDP multicast/broadcast
- **Cross-platform** -- Windows, Linux, Android, and Android TV (iOS & macOS planned)
- **Drag & drop** -- drop files onto a device card to send instantly (desktop)
- **Folder sync** -- bidirectional, scheduled, or one-shot folder synchronization between devices
- **Server sync** -- sync with WebDAV (Nextcloud, Seafile), FTP/SFTP, Google Drive, and OneDrive
- **Relay transfer** -- send files between devices on different networks via WebRTC relay
- **Resume support** -- interrupted transfers pick up where they left off
- **File integrity** -- SHA-256 verification ensures nothing is corrupted in transit
- **Explorer / Share integration** -- right-click "Send with LifeOS" on Windows, share sheet on Android
- **System tray** -- runs quietly in the background, always ready
- **Android TV** -- full D-pad and remote control support with leanback UI
- **10 languages** -- English, Turkish, German, French, Spanish, Italian, Russian, Chinese, Japanese, Arabic
- **100% free & open source** -- no ads, no subscriptions, no tracking

## Supported Platforms

| Platform | Status | Download |
|----------|--------|----------|
| Windows 10/11 | Stable | [Installer (.exe)](https://github.com/07erkanoz/lifeos-anywhere/releases/latest) |
| Linux (x64) | Stable | [.deb package](https://github.com/07erkanoz/lifeos-anywhere/releases/latest) |
| Android 7+ | Stable | [APK](https://github.com/07erkanoz/lifeos-anywhere/releases/latest) |
| Android TV | Stable | Same APK as Android |
| iOS | Planned | -- |
| macOS | Planned | -- |

## Quick Start

1. **Download** the app for your platform from [Releases](https://github.com/07erkanoz/lifeos-anywhere/releases/latest)
2. **Install & open** on two or more devices connected to the same Wi-Fi / LAN
3. Devices appear automatically -- tap or drag files to send

No account, no sign-up, no configuration needed.

## Building from Source

### Prerequisites

- [Flutter](https://docs.flutter.dev/get-started/install) (stable channel, 3.11+)
- Platform-specific toolchains:
  - **Windows**: Visual Studio 2022 with C++ desktop workload
  - **Linux**: `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libnotify-dev libayatana-appindicator3-dev libsecret-1-dev`
  - **Android**: Android Studio with SDK 21+

### Build

```bash
# Clone
git clone https://github.com/07erkanoz/lifeos-anywhere.git
cd lifeos-anywhere

# Install dependencies
flutter pub get

# Build for your platform
flutter build windows --release
flutter build linux --release
flutter build apk --release
```

For cloud sync features (Google Drive, OneDrive), create a `.env` file with your API credentials and build with:

```bash
flutter build <platform> --release --dart-define-from-file=.env
```

## Architecture

```
lib/
  core/           # Constants, logging, theme, platform services
  features/
    discovery/    # UDP multicast device discovery
    transfer/     # File sending/receiving (HTTP + chunked)
    sync/         # Folder synchronization engine
    server_sync/  # WebDAV, FTP, Google Drive, OneDrive sync
    pairing/      # QR code & hotspot pairing
    relay/        # WebRTC relay for cross-network transfers
    settings/     # App configuration & preferences
    platform/     # Windows tray, Linux tray, Android services
  i18n/           # Localization (10 languages)
  widgets/        # Reusable UI components
```

**Key technologies:** Flutter + Dart, Riverpod (state management), shelf (HTTP server), UDP multicast (discovery), WebRTC (relay), platform channels (Android/Windows native).

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes
4. Push to your fork and open a Pull Request

## License

This project is licensed under the MIT License -- see the [LICENSE](LICENSE) file for details.

---

<p align="center">
  Made with Flutter by <a href="https://github.com/07erkanoz">Erkan Oz</a>
</p>
