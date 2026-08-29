# Waypo

A personal study project for Apple-platform networking: a SwiftUI multiplatform app (iOS, iPadOS, macOS) built around a `NEPacketTunnelProvider` extension, with the tunnel engine behind a small protocol boundary so different engine implementations can be swapped in without touching the app layer.

## Layout

```
Waypo.xcodeproj/     4 targets: Waypo (iOS/iPadOS), WaypoMac, WaypoTunnel (iOS), WaypoTunnelMac
Shared/              Code compiled into all targets: config model, store, controller, engine boundary
Waypo/               iOS/iPadOS app entry
WaypoMac/            macOS app entry
Tunnel/              Packet tunnel provider extension code (shared by both platforms)
```

## Before building

1. Open `Waypo.xcodeproj` in Xcode 26+ and set your Development Team on all four targets.
2. Bundle IDs (`org.waypo.ios`, `org.waypo.mac`, `org.waypo.ios.tunnel`, `org.waypo.mac.tunnel`) and the App Group (`group.org.waypo`) are placeholders — change them everywhere if you need different ones.
3. Signing note: the Network Extensions capability cannot be provisioned with a free personal team — a paid Apple Developer Program membership is required for the tunnel targets. Simulator builds never load tunnel extensions regardless; UI and store logic can still be developed in the simulator.

## Requirements

- Xcode 26+, Swift 6, iOS 26 / iPadOS 26 / macOS 26 deployment targets.
- tvOS is intentionally not a target: `NEPacketTunnelProvider` is unavailable there.
