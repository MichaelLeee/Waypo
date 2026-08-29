# Waypo

A personal study project for Apple-platform networking: a SwiftUI multiplatform app (iOS, iPadOS, macOS) built around a `NEPacketTunnelProvider` extension, with the tunnel engine behind a small protocol boundary so different engine implementations can be swapped in without touching the app layer.

## Layout

```
Waypo.xcodeproj/     5 targets: Waypo (iOS/iPadOS), WaypoMac, WaypoTunnel (iOS), WaypoTunnelMac, WaypoHarness
Shared/              Code compiled into all targets: config model, store, controller, engine boundary
Waypo/               iOS/iPadOS app entry
WaypoMac/            macOS app entry
Tunnel/              Packet tunnel provider extension code (shared by both platforms)
Harness/             macOS CLI that drives the engine in-process against a utun device
Core/                Engine library build script and packaged library output (not committed)
```

## Before building

1. Open `Waypo.xcodeproj` in Xcode 26+ and set your Development Team on the app and tunnel targets.
2. Bundle IDs (`org.waypo.ios`, `org.waypo.mac`, `org.waypo.ios.tunnel`, `org.waypo.mac.tunnel`) and the App Group (`group.org.waypo`) are placeholders — change them everywhere if you need different ones.
3. Debug builds carry no entitlements file, so they build and run with a free personal team — enough for all UI, store, and controller work in the simulator or on device. Release builds keep the entitlements (Network Extensions capability + App Group) and require a paid Apple Developer Program membership to sign. Simulator builds never load tunnel extensions regardless.

## Engine development without NetworkExtension

The `WaypoHarness` target is a macOS command-line tool for developing the engine/data path without any signing or NetworkExtension involvement. It creates a real `utun` device, configures it, and feeds packets through the same `CoreEngine` + `PacketFlow` boundary the tunnel extension uses.

```sh
xcodebuild -project Waypo.xcodeproj -target WaypoHarness -configuration Debug build
sudo $(xcodebuild -project Waypo.xcodeproj -target WaypoHarness -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/WaypoHarness
```

utun creation needs root, hence `sudo`. Options:

- `--unit N` — utun unit number (default 9 → `utun9`)
- `--address A.B.C.D` — local IPv4 address on the device (default `198.18.0.1`)
- `--default-route` — point the default route at the device. Off by default; with the placeholder engine not forwarding packets this blackholes your traffic until the process exits.

With the harness running, traffic sent to the utun address (e.g. `ping 198.18.0.2`) reaches the engine and is logged.

## Engine library

The tunnel extension ships with a placeholder engine. The packaged engine library is built from a separate source repository and is not committed here:

```sh
cd Core
CORE_REPO_URL=<engine source repository> ./build-library.sh
```

This clones the source, builds `Libbox.xcframework` for all Apple platforms, and installs it in `Core/`. Then drag the framework into both tunnel targets in Xcode to activate the real engine (`Tunnel/LibboxEngine.swift` is compiled in only when the framework is present, so the project always builds either way).

## Requirements

- Xcode 26+, Swift 6, iOS 26 / iPadOS 26 / macOS 26 deployment targets.
- tvOS is intentionally not a target: `NEPacketTunnelProvider` is unavailable there.
