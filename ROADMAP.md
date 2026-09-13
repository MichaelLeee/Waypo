# Roadmap

A personal study project for Apple-platform networking. This document lays out the
development path from the current scaffold to a polished, distributable app.

## Phase 0 — Foundation (done)

- Xcode project with 5 targets: Waypo (iOS/iPadOS), WaypoMac, WaypoTunnel (iOS), WaypoTunnelMac, WaypoHarness.
- Shared code compiled into every target: configuration model, store, controller, and the engine boundary (`CoreEngine` + `PacketFlow`).
- Entitlements-free Debug builds so a free personal team can build and run; Release keeps entitlements.
- `WaypoHarness` CLI: drives the engine in-process against a real utun device — engine work needs no signing and no NetworkExtension involvement.

## Phase 1 — Real engine behind the boundary (done)

- The packaged engine is integrated as the first `CoreEngine` implementation, linked into the extension targets and the harness.
- `TunnelConfiguration` maps to the engine's configuration format (per-server outbounds + a selector group + route rules).

## Phase 2 — Data-path correctness and tests (done)

- GitHub Actions macOS runner: `macos` job (build all targets + Swift Testing suite) and `engine` job (builds the engine framework from a pinned upstream ref, compiles the extensions against it, runs the harness self-test as root, uploads the framework as an artifact).
- Harness self-test gates: UDP round-trip, byte-exact TCP forwarding, DNS handling, clean shutdown with route cleanup.
- Share-link and base64 subscription import; server editor UI; per-server latency checks; log viewer; traffic stats over provider messages.

## Phase 3 — Transport breadth (done)

- Six transports wired end to end (model fields, share-link parsers, outbound mapping, editor UI, tests): shadowsocks, trojan, vless, hysteria2, tuic, vmess.
- Zero-downtime server switching via the engine's selector outbound.

## Phase 4 — Usable by real users (current)

The migration milestone: existing subscriptions must import and run cleanly.

- Import the community-standard YAML configuration format (proxies, groups, rules, DNS) from files or remote URLs, with auto-update and provider quota display.
- Export a profile back out to the same format, round-tripping servers, groups, rules, and DNS without dropping the entries the import could not represent.
- Policy groups beyond the selector: url-test, fallback, load-balance — mapped to the engine's native group types; a groups view with inline latency and tap-to-switch.
- macOS system-wide mode: the engine runs in-process in the Mac app with a local mixed inbound, and a small privileged helper (SMAppService daemon) applies and reverts the system-level network configuration. This also provides a full end-to-end path that requires no paid developer membership.
- Transport completion: WireGuard (configuration-file import plus key handling UI), AnyTLS, Shadow-TLS v3.

## Phase 5 — Visibility and platform integration

- Connection inspector driven by the engine's status API: live connections with matched rule, transfer counters, per-connection close, running traffic graphs.
- DNS configuration UI: encrypted resolvers (DoH/DoT/DoQ), hosts mapping, fake-IP toggle with exclusion list.
- Rule management: remote rule sets with auto-update, an ordered rule editor, GeoIP/GeoSite database handling.
- Widgets, App Intents (connect/disconnect/mode switching), Control Center toggle, Live Activities.
- Continuous design-system polish: coherent type and color system, motion, empty states, per-server icons, iPad multitasking.

## Phase 6 — Power-user platform (bets, sequenced after Phase 4–5)

- JavaScript scripting (JavaScriptCore): request/response hooks, cron tasks, event hooks, persistent storage, notifications.
- Rewrite toolkit: URL/header rewrite, reject handling, map-local.
- HTTPS decryption with certificate generation.
- Local HTTP API + web dashboard for external control.
- Apple Watch companion; tvOS companion (control only — packet tunnel APIs are unavailable there).
- Configuration sync via iCloud/WebDAV.

## Phase 7 — Distribution

- Requires a paid Apple Developer Program membership: Release entitlements, App Group provisioning, TestFlight for iOS.
- macOS packaging: app-extension embedding for the App Store first; a System Extension variant for direct distribution is a later, separate effort.
- Privacy manifest and complete UX for review.

## Phase 8 — Long-term

- In-house core implementation (Rust, C-ABI) replacing the packaged library behind the same `CoreEngine` boundary — the decision gate is whether the packaged engine's memory ceiling blocks the Phase 6 scripting work. Measured, the bare engine plus traffic sits at ~25% of the 50 MB budget, so the ceiling does not block it today; HTTPS decryption in the extension is the sharper test.
- visionOS companion apps (control only).

## Cross-cutting tracks (never drop)

- Memory budget for the extension: 50 MB `phys_footprint`, the figure the system terminates a process for. Measured on every commit by the `engine` job's `--footprint` step, which samples before the engine starts, with traffic in flight, and after shutdown, and fails the run past the budget. Baseline for a direct configuration carrying UDP traffic: 12.5 MiB peak, ~25% of budget — but on a macOS Release build, which has neither the extension loader nor the device's own limit, so read it as a floor rather than the device figure. Past 60% of budget the step annotates a warning: anything holding per-connection buffers in the extension, starting with the Phase 6 HTTPS decryption work, has to stream with strictly bounded buffers, and past 100% it cannot run in the extension at all. Re-checked per transport added.
- Vocabulary discipline in this public repo: neutral terms only, in commits, docs, and comments.
