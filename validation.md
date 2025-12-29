Below is a concrete "validation + compatibility update" brief you can hand to a research agent and use to harden the app now. This focuses on what can be validated from public sources, what is likely to break on older Intel / older SMCs, and implementation changes that reduce wrong UI output when keys/units differ.

## What's strongly supported by public sources

### Core power keys: units + meaning

- PSTR is treated as total system power (watts). This matches both Apple Silicon reverse-engineering docs ("entire system's power consumption in W") and upstream Linux device-tree labels ("Total System Power"). ([asahilinux.org][1])
- PDTR is treated as AC/DC input power (watts). Again consistent across Apple Silicon docs ("input power in W") and Linux labels ("AC Input Power"). ([asahilinux.org][1])
- PHPC is explicitly labeled "Heatpipe Power" in recent Apple Silicon hwmon DTS work, which supports the "SoC/package proxy" framing (with the important caveat: it's heatpipe-domain, not necessarily "SoC only"). ([LKML][2])
- PPBR is described as battery power (Watts) in VirtualSMC's sensor key docs, and it's shown with a signed fixed-point type (strong hint that the value can be negative/positive). ([GitHub][3])

### Battery SMC keys: units

Asahi's Apple Silicon SMC notes align with current battery unit assumptions:

- B0AV battery voltage in mV (notably documented there as si16 on at least some systems).
- B0DC/B0FC capacities in mAh.
- B0TE/B0TF time-to-empty / time-to-full in minutes.
- SBAR/SBAV "float" variants exist for remaining capacity/voltage on some systems. ([asahilinux.org][1])

### Fans: key shapes that exist in the wild

Recent Apple Silicon hwmon DTS patches use:

- F0Ac / F1Ac as actual speed,
- F0Mx / F1Mx as max,
- plus min/target/mode keys (F0Mn, F0Tg, F0Md, etc.). ([LKML][2])
  That supports the "FnAc/FnMx per index" model and suggests also considering min/target keys as optional enhancements.

### PowerTelemetryData: units and relationships

Ask Different has a relevant thread with concrete unit inference:

- Treat SystemInputVoltage as mV, SystemInputCurrent as mA, and SystemPowerIn/SystemLoad/AdapterEfficiencyLoss as mW (and voltage x current ~= power with /1000 conversion). ([Ask Different][4])
- It also notes availability constraints: the OP found it "only available on Ventura" (macOS 13). ([Ask Different][4])
  So the "telemetry in mW unless noted" assumption is well supported.

### PDBR naming (but weaker "meaning")

In the ecosystem, PDBR is commonly surfaced as something like "Power Delivery Brightness", and it behaves like an internal display power channel in those tools. ([RSK Group][5])
This supports the UI label directionally, but it is not as strong as PDTR/PSTR/PHPC.

---

## The biggest compatibility risks (and what to change)

### 1) SMC type decoding: signed integers are a must

The decoder list omits si8/si16/si32. That is a compatibility risk because at least one widely referenced Apple Silicon SMC map describes B0AV as si16. If unknown types become nil -> 0, it silently converts voltage to 0 V, which then makes remaining Wh = 0 and cascades into wrong flow math. ([asahilinux.org][1])

Compatibility update

- Add support for: si8, si16, si32, si64, ui64, flag.
- Change the "unknown type => nil => default 0" behavior into:
  - unknown type => nil (propagate missingness),
  - only use 0 where 0 is a valid reading (e.g., fan rpm can be 0 when stopped, but "system power = 0" is almost never a real state on a running laptop).

This prevents "looks plausible but wrong" UI states on older/odd models.

### 2) AppleSmartBattery CurrentCapacity is not stable across OS / query path

This is real:

- Some examples show CurrentCapacity and MaxCapacity as large numbers (mAh) (e.g., 6417 / 6834). ([Stack Overflow][6])
- Other examples show CurrentCapacity and MaxCapacity as 97 / 100 (percent-like). ([OS X Daily][7])
- Some libraries (e.g., OSHI) interpret AppleSmartBattery registry capacities as mAh and explicitly set capacity units to mAh. ([Oshi][8])

Compatibility update

Implement a scale-detection heuristic and stop treating CurrentCapacity as percent unconditionally:

```swift
struct BatteryCapacity {
    var current: Double
    var max: Double?
    var units: Units // .percent or .mAh
}

func inferCapacityUnits(current: Double, max: Double?) -> Units {
    // Common cases:
    // - percent-like: current <= 100 and (max == nil || max <= 100)
    // - mAh-like: max is typically thousands
    if current <= 100, (max == nil || max! <= 100) { return .percent }
    if let max, max > 200 { return .mAh }
    // fallback: if current is >100, it is almost certainly mAh
    if current > 100 { return .mAh }
    return .percent
}

func percentFromCapacity(current: Double, max: Double?, units: Units) -> Double? {
    switch units {
    case .percent:
        return min(100, max(0, current))
    case .mAh:
        guard let max, max > 0 else { return nil }
        return min(100, max(0, 100.0 * current / max))
    }
}
```

Then:

- If you need remaining Wh, prefer SMC (SBAR/B0AV) when present (those are explicitly mAh/mV in the Apple Silicon mapping). ([asahilinux.org][1])
- If SMC battery keys are not available (or unreliable), compute battery power from IORegistry:
  - Voltage (mV) x InstantAmperage (mA) / 1e6 = W (after sign handling).

### 3) PPBR sign + direction: treat as signed, but do not hard-code meaning

Current assumption:
- PPBR > 0 charging, < 0 discharging.

What we can back confidently:
- PPBR is battery power and has a signed type in a major SMC key documentation set. ([GitHub][3])

What is still device/firmware-dependent:
- Whether positive means "into battery" or "out of battery."

Compatibility update

Instead of hard-coding sign semantics globally:

1. Keep PPBR as signed.
2. Determine sign convention at runtime using a short calibration window:
   - If ExternalConnected == false and IsCharging == false, battery should be discharging.
   - If PPBR is positive during that window, flip the "PPBR positive means discharge" flag for that machine/session.
3. Persist a per-model "PPBR sign convention" keyed by hw.model or model identifier.

This makes the app robust even if older Intel / some T2 firmware uses opposite polarity.

### 4) PSTR may be averaged/delayed; do not treat it as instantaneous truth

VirtualSMC sensor docs mention PSTR being "delayed 1 second" (at least in that reference). ([GitHub][3])
That matters because the UI is flow-based and thresholded.

Compatibility update

- Apply smoothing consistently (e.g., EMA with 0.3-0.5 alpha) to all power channels rendered as live flows.
- When validating conservation (PSTR ~= PDBR + PHPC + other), allow a tolerance band (e.g., +/- (0.5W + 5%)).

### 5) PowerTelemetryData is a powerful fallback - but version-gated

Ask Different suggests:

- Units are "milli-" for most live values (mV/mA/mW). ([Ask Different][4])
- It may only exist on Ventura+ (macOS 13). ([Ask Different][4])

Compatibility update

Add a telemetry-first fallback chain:

Preferred chain (when present and consistent):

1. SMC: PSTR, PDTR, PPBR, PDBR, PHPC
2. PowerTelemetryData:
   - SystemLoad (mW -> W)
   - SystemPowerIn (mW -> W)
   - AdapterEfficiencyLoss (mW -> W)
   - Use WallEnergyEstimate / SystemEnergyConsumed only if you need energy totals, and treat them as counters/estimates, not instantaneous power.
3. AppleSmartBattery instantaneous current/voltage power:
   - compute battery W, compute adapter W when adapter current/voltage are available.

Then in UI calculations, only mix sources if you can show they are coherent for that device.

### 6) PHPC is "heatpipe power", not guaranteed "SoC power"

Linux DTS literally labels it "Heatpipe Power." ([LKML][2])
So the current "SoC/package proxy" is reasonable, but labeling it as "SoC" can be misleading, especially on Intel or on models where the heatpipe domain covers more than the die.

Compatibility update

- Rename the label logic to something like:
  - Apple Silicon: "SoC (Heatpipe)" or "Package (Heatpipe)"
  - Intel: "CPU Package" when using Intel package keys, otherwise "Heatpipe".

Only call it "SoC" if you are sure it corresponds to SoC/package on that platform.

### 7) Screen power: PDBR is not universal; build a fallback strategy

PDBR may not exist and external display scenarios are tricky.

Compatibility update

Treat "Screen power" as a feature that can be on/off:

- If PDBR exists and is non-zero: show "Screen".
- Else if internal display present but no PDBR:
  - show "Screen" as "unavailable" (not 0 W), or
  - estimate screen power from brightness + panel type (if comfortable with an estimate).
- If no internal display (desktop, lid closed clamshell with external only, etc.): hide the screen row entirely.

### 8) Intel "package power" alternates: use PCPC / PCPT / etc when PHPC is missing

The SMC ecosystem commonly surfaces Intel CPU package power keys like PCPC / PCPT etc. ([GitHub][9])

Compatibility update

- If PHPC is missing, try Intel package keys in descending preference:
  - PCPC (CPU Package)
  - PCPT (CPU Package total)
  - PC0R / PCPR style "CPU rail" power keys (model dependent)

Then label accordingly ("CPU Package"), not "SoC".

---

## Recommended changes to derived formulas

### A safer way to compute battery/system/adapter flows

Right now, batteryPower = max(PPBR, PDTR - PSTR) can mask inconsistencies by construction.

A more robust approach is:

1. Treat all powers as signed "into the node" or "out of the node" consistently.

Example convention (pick one and stick to it):

- PSTR = system consumption (always >= 0)
- PDTR = adapter input power available to the platform (>= 0)
- PPBR = battery power into battery positive (charging), out of battery negative (discharging) - but determine sign convention per machine as described above.

2. Then compute "balance implied battery" only as a fallback or as a cross-check:

- impliedBattery = PDTR - PSTR

  - positive => surplus available for charging battery (or losses)
  - negative => deficit must be supplied by battery (discharge)

3. Choose batteryPower like:

- If PPBR is present and coherent with charging/discharging status => use PPBR.
- Else use impliedBattery.
- If both exist but differ a lot => keep both internally and mark battery flow confidence low (do not overdraw strong UI arrows).

### Telemetry-based formula alignment

From PowerTelemetryData:

- SystemPowerIn ~= SystemInputVoltage x SystemInputCurrent / 1000 (mW), and AdapterEfficiencyLoss is also mW. ([Ask Different][4])
  So telemetry conversions are conceptually right; the main fix is:
- Treat telemetry values as a separate power source (not just "read but not used"), and use them as fallback on older machines where SMC power keys are missing/unreliable.

---

## SoC naming: a compatibility-friendly rule

Current logic uses machdep.cpu.brand_string and then labels as "SoC" regardless.

Compatibility update

- Determine CPU architecture first (arm64 vs x86_64) using sysctl (hw.optional.arm64) or similar.
- If arm64: label as SoC (and use brand_string normalization if it is present and stable in tests).
- If Intel: label as CPU, not SoC.

This avoids "SoC: Intel(R) Core(TM) i7..." which reads wrong to users.

---

## HID temperature fallback: keep it, but treat it as best-effort

Multiple open-source implementations match HID thermal sensors using:

- PrimaryUsagePage = 0xff00
- PrimaryUsage = 0x5

This aligns with the current approach. ([GitHub][10])

Compatibility update

- Make HID temperature a supplemental channel used only when SMC CPU die temps are missing/0, and clearly mark it as "HID thermal sensor" in debug logs (not in UI).

---

## Validation plan for your research agent

### 1) Build a device/OS test matrix

Minimum recommended buckets:

- Intel pre-T2 (2012-2017 era)
- Intel T2 (2018-2020 era)
- Apple Silicon M1
- Apple Silicon M2/M3/M4 (if you can)

For each bucket, test on at least:

- AC power + idle
- AC power + CPU load
- Battery + idle
- Battery + CPU load
- Brightness sweep 0->100% (internal panel)
- Clamshell/external monitor (if relevant)

### 2) For each run, capture raw data snapshots

Collect:

- SMC: availability + type + value for PPBR/PDTR/PSTR/PHPC/PDBR/B0AV/B0FC/B0DC/SBAR/B0TE/B0TF, fan keys, and the temp key family max.
- IORegistry AppleSmartBattery: CurrentCapacity, MaxCapacity, Voltage, InstantAmperage/Amperage, ExternalConnected, IsCharging, TimeRemaining.
- PowerTelemetryData if present.

### 3) Run three consistency checks (per sample window)

- Power balance: PDTR - PSTR should track battery charging/discharging direction; compare to PPBR sign after runtime sign calibration.
- Screen correlation: candidate screen key should correlate strongly with brightness changes (PDBR if present; otherwise discover alternates by scanning P* keys and correlating).
- Thermal sanity: CPU temp max should increase under load; reject sensors that spike unrealistically or stay pinned at 0.

### 4) Produce per-model feature flags

Output a small JSON mapping (model -> booleans / preferred keys), e.g.:

- supportsPDBR
- supportsPHPC
- ppbrSignConvention (+1 or -1)
- batteryCapacityUnitsFromIOReg (percent vs mAh)
- preferredPackagePowerKey (PHPC vs PCPC vs PCPT)

---

## Summary of "do this now" compatibility updates

1. Add SMC signed integer + flag decoding and stop treating unknown types as "0". ([asahilinux.org][1])
2. Make AppleSmartBattery CurrentCapacity unit-aware (percent vs mAh) and derive percent accordingly. ([Stack Overflow][6])
3. Runtime-calibrate PPBR polarity using charging state + external power. ([GitHub][3])
4. Use PowerTelemetryData as a first-class fallback (mW/mV/mA), gated by availability (Ventura+). ([Ask Different][4])
5. Treat PHPC as "Heatpipe Power" and label more carefully; fall back to Intel package keys like PCPC/PCPT when PHPC is absent. ([LKML][2])
6. Make screen power a capability (PDBR optional; hide/estimate when missing). ([RSK Group][5])

If you want, I can also draft a small "capability scoring" struct (Swift) that takes a snapshot of SMC/IORegistry/Telemetry and returns a PowerflowSnapshot plus a confidence map per edge (Adapter->System, Battery<->System, etc.), so the UI can degrade gracefully instead of showing wrong arrows.

[1]: https://asahilinux.org/docs/hw/soc/smc/ "System Management Controller (SMC) - Asahi Linux Documentation"
[2]: https://lkml.org/lkml/2025/8/19/977 "LKML: James Calligeros: [PATCH 7/8] arm64: dts: apple: add common hwmon sensors and fans"
[3]: https://github.com/acidanthera/VirtualSMC/blob/master/Docs/SMCSensorKeys.txt "VirtualSMC/Docs/SMCSensorKeys.txt at master"
[4]: https://apple.stackexchange.com/questions/455157/looking-for-a-way-to-read-out-battery-and-poweradapter-information-via-ioreg "macos - Looking for a way to read out Battery and PowerAdapter Information via ioreg - Ask Different"
[5]: https://rskgroup.org/mac-temperature-exporter-to-prometheus/ "Mac smc_exporter with temperatures for Prometheus - RSK Group"
[6]: https://stackoverflow.com/questions/53552864/i-want-to-retrieve-battery-related-informationmodel-information-health-informat "macos - I want to retrieve battery related information (model ...)"
[7]: https://osxdaily.com/2024/01/03/how-to-check-battery-capacity-cycle-count-from-command-line-on-mac/ "How to Check Battery Capacity & Cycle Count from Command Line on Mac"
[8]: https://www.oshi.ooo/xref/oshi/hardware/platform/mac/MacPowerSource.html "MacPowerSource xref"
[9]: https://github.com/exelban/stats/issues/170 "Deleting wrong element while enumerating sensors #170"
[10]: https://github.com/fermion-star/apple_sensors/blob/master/temp_sensor.m "apple_sensors/temp_sensor.m at master"
