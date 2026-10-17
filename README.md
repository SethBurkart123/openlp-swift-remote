# OpenLP Swift Remote

![OpenLP Swift Remote showing Service and Slides on iPhone](docs/banner.webp)

A small, native iPhone remote for [OpenLP](https://openlp.org), built with SwiftUI. Browse the service, select slides, and control the display without installing OpenLP’s web remote files.

This is an independent project, not an official OpenLP release.

## Screenshots

All screenshots use fictional demo service content and original sample lyrics.

<p>
  <img src="docs/screenshots/service.png" width="250" alt="Service list with the current item highlighted">
  <img src="docs/screenshots/slides.png" width="250" alt="Slides with the current verse highlighted">
  <img src="docs/screenshots/settings.png" width="250" alt="Connection and live-control settings">
</p>

## Features

- Native Service and Slides tabs, plus connection settings.
- Pale blue for a requested selection; stronger blue for the server-confirmed live selection.
- Single-slide service items stay on Service. Multi-slide items open Slides after confirmation.
- Previous/next controls and Blank, Theme, Desktop, and Show modes.
- Image previews and video stills when supported by the OpenLP server.
- Play/pause, stop, ten-second skips, and a native timeline for live media on the patched server.
- HTTP or HTTPS connections and optional Basic authentication.
- Live controls default to enabled. Your manual setting is remembered across launches, backgrounding, and reconnects. Commands remain unavailable while disconnected.
- Pull to refresh and automatic foreground refresh every two seconds.

## Build and connect

Requires macOS, Xcode with an iOS SDK, and iOS 17 or later. There are no third-party app dependencies.

1. Open `OpenLPRemote.xcodeproj` in Xcode and select the **OpenLPRemote** scheme.
2. Choose an iPhone simulator, or choose your development team and a unique bundle identifier to run on your iPhone.
3. Build and run. For a physical phone, enable Developer Mode and allow Local Network access when prompted.
4. In the app’s Settings, enter the OpenLP computer’s IP address or hostname and remote port (usually `4316`). Both devices must be able to reach the same network.
5. Live controls are enabled by default. Turn them off in Settings when you only want to browse.

The checked-in Xcode project is ready to open. To regenerate it after changing `project.yml`, run `xcodegen generate` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Demo screenshots

Run the included local API on your Mac:

```sh
python3 scripts/demo_server.py
```

In the iPhone simulator, connect to `127.0.0.1`, port `9431`, with HTTPS and authentication off. This demo never contacts a real OpenLP server. Its content is fictional and can be used for screenshots.

## Compatibility and limitations

The app uses OpenLP’s legacy `/api` endpoints. The API contract was checked against OpenLP 3.1.7 source and read against a running OpenLP server. It has not been tested against every OpenLP release.

The OpenLP API must be reachable even when its web interface is unavailable. Image previews depend on the server’s thumbnail endpoints; unavailable thumbnails show a placeholder. The companion OpenLP fork change on `codex/remote-media-previews` adds authenticated previews for the current live item at `/api/controller/live/thumbnail/<item-id>/<slide-index>`. Run that patched OpenLP source and enable thumbnails in its remote/API settings. Local video files require FFmpeg on the OpenLP computer; previews are still frames from the configured start time, not streaming playback. Streaming URLs and optical media are excluded from thumbnails and seeking. Playback controls require the companion media-control API patch; older servers simply omit the controls. Commands target a specific service item and execute on the OpenLP GUI thread. The app does not include search, alerts, or service editing.

Commands are serialized: additional taps are ignored while a command is awaiting confirmation, without dimming the controls. Confirmation times out after eight seconds and prompts you to check the projection before retrying. Passwords are kept only for the current app session. Basic authentication over HTTP is not encrypted; use HTTPS on networks where credentials need protection.

## Verification

Simulator and signed-device builds were completed. Manual simulator checks against a separate local server covered delayed service/slide confirmation, distinct pending/live highlights, and navigation for single- versus multi-slide items. Read-only checks covered a real server’s service list and live slide data. Live-control checks were performed against the local demo, not a running service. Image and video previews were visually verified in the simulator against the patched Python API with isolated demo media. Server regression checks cover real image/video decoding, authentication, stale item URLs, disabled thumbnails, and missing files.

## License and attribution

GPL-3.0-or-later. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).

The app icon uses OpenLP’s official logo artwork. The OpenLP name and logo identify the compatible software; they do not imply endorsement.
