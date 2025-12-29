# Powerflow (Native Swift)

Powerflow is a native macOS menu bar app for monitoring power input, system load,
and battery health in real time. This repository is the Swift-first fork.

Fork reference: https://github.com/lzt1008/powerflow

## Features

- Menu bar power readout with customizable format and icon.
- Live power flow diagram (adapter, system, battery).
- System load breakdown based on SMC total and known channels.
- Battery health, remaining Wh, cycle count, and adapter details.
- History charts for system load and primary temperature.
- Diagnostics view for SMC/IORegistry/telemetry data and fan readings.

## Requirements

- macOS 26+
- Xcode 26 (recommended) or any Xcode that can target macOS 26

## Build and Run

Open the Xcode project:

```
open Powerflow.xcodeproj
```

Or build from the command line:

```
xcodebuild -project Powerflow.xcodeproj -scheme Powerflow -configuration Release -destination "platform=macOS" build
```

There is also a helper script:

```
scripts/build_release.sh
```

## Repository Layout

- `Sources/` - Swift app source.
- `Resources/` - App resources and Info.plist.
- `scripts/` - Release build helper.
- `LICENSE` - Original MIT license.

## License

MIT. See `LICENSE`.
