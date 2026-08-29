# Roadmap

A personal study project for Apple-platform networking. This document lays out the development path from the current scaffold to a polished, distributable app.

## Phase 0 — Foundation (done)

- Xcode project with 5 targets: Waypo (iOS/iPadOS), WaypoMac, WaypoTunnel (iOS), WaypoTunnelMac, WaypoHarness.
- Shared code compiled into every target: configuration model, store, controller, and the engine boundary (`CoreEngine` + `PacketFlow`).
- Entitlements-free Debug builds so a free personal team can build and run; Release keeps entitlements.
- `WaypoHarness` CLI: drives the engine in-process against a real utun device — engine work needs no signing and no NetworkExtension involvement.

## Phase 1 — Real engine behind the boundary

The critical path. All project risk lives here, so it comes before UI work.

- Integrate the v1 core (a packaged static library behind a thin C-ABI shim) as the first `CoreEngine` implementation, replacing the placeholder.
- Map `TunnelConfiguration` to the engine's configuration format.
- Acceptance: the harness routes real traffic end to end; the extension stays under ~50 MB steady state.

## Phase 2 — Data-path correctness and tests

- Swift Testing suite driving the engine through the production path (the harness pattern — never a mock flow): packet framing, TCP/UDP forwarding, DNS resolution, stats and events.
- Deterministic metrics as CI gates: byte counters balance, no loss on a loopback test, clean shutdown drains.
- GitHub Actions macOS runner building all targets and running tests on every push.

## Phase 3 — App UI (OS 26 style)

Following current Apple sample-code practices:

- `NavigationSplitView` layout on macOS; tab/stack on iOS. Feature-organized view code.
- Server list management, configuration import (URL/file), per-server latency display.
- OS 26 design language: system-provided materials first, custom `glassEffect` only for signature controls (connect toggle, status ring), `backgroundExtensionEffect` for edge-to-edge content, Icon Composer app icon.
- Wire the controller to the real store; handle status-change edge cases (network loss, app termination).

## Phase 4 — Platform hardening

- Memory and battery profiling on device with Instruments (the extension process is the constraint, not the app).
- Sleep/wake, network-switch behavior, log capture and export.
- iPadOS multitasking checks; polish app icon and launch experience.

## Phase 5 — Distribution

- Requires a paid Apple Developer Program membership: Release entitlements, App Group provisioning, TestFlight for iOS.
- macOS packaging: app-extension embedding for the App Store first; a System Extension variant for direct distribution is a later, separate effort.
- Privacy manifest and complete UX for review.

## Phase 6 — Long-term

- In-house core implementation (Rust, C-ABI) replacing the packaged library behind the same `CoreEngine` boundary.
- tvOS/visionOS companion apps (control only — the packet tunnel APIs are unavailable on those platforms).
- Configuration sync and multi-profile management.
