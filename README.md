# Powerflow

Powerflow is a native macOS menu bar app for monitoring adapter input, system load,
battery state, and thermal behavior in real time. The app is intentionally OS-first:
Powerflow observes and explains battery health, while macOS remains the source of truth
for charge optimization and battery longevity controls.

Fork reference: https://github.com/lzt1008/powerflow

## Screenshots

<img src="assets/dashboard.png" alt="Powerflow dashboard" width="520">

<img src="assets/graphs.png" alt="History and charts" width="260"> <img src="assets/settings.png" alt="Settings" width="260">

## Features

- Menu bar power readout with customizable format and icon.
- Live power flow diagram (adapter, system, battery).
- System load breakdown based on SMC total and known channels.
- Battery health, remaining Wh, cycle count, and temperature visibility.
- History charts for system load and primary temperature.
- Battery guidance links to Apple's built-in battery management documentation.
- Diagnostics view for SMC/IORegistry/telemetry data and fan readings.

## Requirements

- macOS 15+
- Xcode 16.4 or newer

## Build and Run

Open the Xcode project:

```
open Powerflow.xcodeproj
```

Run the tests:

```
xcodebuild -project Powerflow.xcodeproj -scheme Powerflow -destination "platform=macOS" test
```

Build a release app:

```
xcodebuild -project Powerflow.xcodeproj -scheme Powerflow -configuration Release -destination "platform=macOS" build
```

There is also a release packaging script:

```
scripts/build_release.sh
```

## Repository Layout

- `Sources/Powerflow` - App source, including services, state, and SwiftUI UI.
- `Tests/PowerflowTests` - Unit tests for settings and formatting behavior.
- `Resources` - App resources and Info.plist.
- `project.yml` - XcodeGen project definition.
- `scripts/build_release.sh` - Release packaging script.
- `LICENSE` - Original MIT license.

## License

MIT. See `LICENSE`.
