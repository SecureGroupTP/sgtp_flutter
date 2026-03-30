# SGTP Flutter

End-to-end encrypted peer-to-peer chat built on the SGTP protocol.

---

## Table of Contents

1. [Requirements](#requirements)
2. [System Dependencies](#system-dependencies)
   - [Linux](#linux)
   - [Windows](#windows)
   - [macOS](#macos)
   - [Android](#android)
   - [iOS](#ios)
3. [Building](#building)
4. [Running in development](#running-in-development)
5. [Protocol overview](#protocol-overview)

---

## Requirements

- **Flutter SDK** ≥ 3.22 (stable channel)
- **Dart** ≥ 3.4

Install Flutter: https://docs.flutter.dev/get-started/install

---

## System Dependencies

### Linux

The following packages are required. Without them **video playback and voice messages will not work**.

**Ubuntu / Debian:**
```bash
sudo apt-get update
sudo apt-get install -y \
    libmpv-dev \
    mpv \
    libavcodec-dev libavformat-dev libavutil-dev libswscale-dev \
    libgstreamer1.0-dev \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    libgstreamer-plugins-base1.0-dev \
    libasound2-dev \
    libpulse-dev \
    libssl-dev \
    pkg-config \
    ninja-build \
    cmake
```

**Fedora / RHEL:**
```bash
sudo dnf install -y \
    mpv-libs-devel \
    gstreamer1-devel \
    gstreamer1-plugins-base-devel \
    gstreamer1-plugins-good \
    gstreamer1-plugins-bad-free \
    gstreamer1-plugins-ugly \
    gstreamer1-libav \
    alsa-lib-devel \
    pulseaudio-libs-devel \
    openssl-devel \
    pkg-config cmake ninja-build
```

**Arch / Manjaro:**
```bash
sudo pacman -S --needed \
    mpv \
    gstreamer gst-plugins-base gst-plugins-good \
    gst-plugins-bad gst-plugins-ugly gst-libav \
    alsa-lib pulseaudio \
    openssl pkg-config cmake ninja
```

> **Why?**  
> `media_kit` uses libmpv for video and `record`/`audioplayers` use GStreamer or ALSA for audio.  
> Without `libmpv-dev` video tracks are blank. Without GStreamer/ALSA voice messages won't record or play.

---

### Windows

No manual system-level installation is required for most dependencies.  
However, for **video and voice** support:

1. **Visual C++ Redistributable** (usually already installed):  
   https://aka.ms/vs/17/release/vc_redist.x64.exe

2. `media_kit` bundles its own `mpv` DLL — no separate mpv install needed.

3. For **voice recording** (`record` package) Windows uses WASAPI, which is built in.

4. Make sure your Windows SDK target is **10.0.17763.0** or newer.  
   Check in `windows/CMakeLists.txt`:
   ```cmake
   set(CMAKE_SYSTEM_VERSION "10.0.17763" ...)
   ```

> If you see a blank video track or no audio on Windows, update your **graphics drivers** and ensure Windows media codecs are installed (Settings → Apps → Optional features → search "Media Feature Pack").

---

### macOS

```bash
brew install mpv
```

Grant microphone permission when prompted, or add to `macos/Runner/Info.plist`:
```xml
<key>NSMicrophoneUsageDescription</key>
<string>SGTP needs microphone access to record voice messages.</string>
```

---

### Android

No extra system setup. Ensure the following permissions are in `AndroidManifest.xml` (already included):

- `INTERNET`
- `RECORD_AUDIO`
- `READ_EXTERNAL_STORAGE` / `READ_MEDIA_*`
- `CAMERA` (for video notes)

Minimum SDK: **21** (Android 5.0).

---

### iOS

Minimum deployment target: **iOS 14**.  
Permissions (already in `Info.plist`):
- `NSMicrophoneUsageDescription`
- `NSCameraUsageDescription`

---

## Building

```bash
# Get dependencies
flutter pub get

# ── Desktop ────────────────────────────────────────────────────────────────
# Linux
flutter build linux --release

# Windows
flutter build windows --release

# macOS
flutter build macos --release

# ── Mobile ──────────────────────────────────────────────────────────────────
# Android APK
flutter build apk --release

# Android App Bundle (Play Store)
flutter build appbundle --release

# iOS (requires Xcode + Apple Developer account)
flutter build ios --release
```

Build outputs:
| Platform | Location |
|---|---|
| Linux | `build/linux/x64/release/bundle/` |
| Windows | `build/windows/x64/runner/Release/` |
| macOS | `build/macos/Build/Products/Release/sgtp_flutter.app` |
| Android APK | `build/app/outputs/flutter-apk/app-release.apk` |

---

## Running in development

```bash
flutter run -d linux      # or windows / macos / chrome / <device-id>
```

Enable verbose Flutter logs:
```bash
flutter run --verbose -d linux
```

In-app packet logs are available in **Settings → Logs** (all inbound/outbound SGTP frames are logged at DEBUG level).

---

## Protocol overview

SGTP (Secure Group Transfer Protocol) is a custom encrypted messaging protocol:

- **Transport**: TCP with length-prefixed frames
- **Identity**: Ed25519 key pairs (OpenSSH format)
- **Session keys**: X25519 ECDH ephemeral exchange → ChaCha20-Poly1305 encryption
- **Chat keys**: rotated every 180 s by the room master
- **History sync**: HSI/HSR/HSRA handshake on peer join
- **Reactions**: embedded in MESSAGE payloads, relayed by master
- **Media**: chunked in 8 MiB segments, reassembled on receipt

Key packet types:

| Code | Name | Direction |
|------|------|-----------|
| 0x0000 | INTENT | broadcast |
| 0x0001 | PING | unicast |
| 0x0002 | PONG | unicast |
| 0x0004 | CHAT_REQUEST | → master |
| 0x0005 | CHAT_KEY | master → peer |
| 0x0007 | MESSAGE | broadcast |
| 0x000B–E | HSIR/HSI/HSR/HSRA | history sync |

All frames are signed with the sender's Ed25519 key and verified on receipt.
