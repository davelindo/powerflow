import AppKit
import Combine
import SwiftUI

final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var cancellables = Set<AnyCancellable>()
    private let appState: AppState
    private var lastTitle: String?
    private var lastIconKey: StatusIconKey?

    private struct StatusIconKey: Equatable {
        let icon: PowerSettings.StatusBarIcon
        let batteryLevel: Double
        let overlay: BatteryIconRenderer.Overlay
        let symbolName: String?
    }

    init(appState: AppState) {
        self.appState = appState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.delegate = self

        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp])

        updateStatusItem(
            title: appState.statusBarTitle,
            snapshot: appState.statusSnapshot,
            settings: appState.settings
        )
        appState.$statusBarTitle
            .receive(on: RunLoop.main)
            .sink { [weak self] title in
                guard let self else { return }
                self.updateStatusItem(
                    title: title,
                    snapshot: self.appState.statusSnapshot,
                    settings: self.appState.settings
                )
            }
            .store(in: &cancellables)

        appState.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] settings in
                guard let self else { return }
                self.updateStatusItem(
                    title: self.appState.statusBarTitle,
                    snapshot: self.appState.statusSnapshot,
                    settings: settings
                )
            }
            .store(in: &cancellables)

        appState.$statusSnapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                self.updateStatusItem(
                    title: self.appState.statusBarTitle,
                    snapshot: snapshot,
                    settings: self.appState.settings
                )
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            ensurePopoverContent()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverWillShow(_ notification: Notification) {
        ensurePopoverContent()
        appState.isPopoverVisible = true
    }

    func popoverDidShow(_ notification: Notification) {
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverWillClose(_ notification: Notification) {
        appState.isPopoverVisible = false
        popover.contentViewController = nil
    }

    private func updateStatusItem(title: String, snapshot: PowerSnapshot, settings: PowerSettings) {
        guard let button = statusItem.button else { return }
        let iconKey = statusIconKey(for: settings, snapshot: snapshot)
        let titleChanged = title != lastTitle
        let iconChanged = iconKey != lastIconKey

        if titleChanged {
            button.title = title
            lastTitle = title
        }

        guard iconChanged else { return }
        lastIconKey = iconKey

        if settings.statusBarIcon == .dynamicBattery,
           let image = BatteryIconRenderer.dynamicBatteryImage(
               level: snapshot.batteryLevelPrecise,
               overlay: batteryOverlay(for: snapshot)
           ) {
            button.image = image
            button.imagePosition = .imageLeading
            return
        }

        if let symbolName = resolveSymbolName(settings: settings),
           let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: settings.statusBarIcon.label) {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
        } else {
            button.image = nil
            button.imagePosition = .noImage
        }
    }

    private func resolveSymbolName(settings: PowerSettings) -> String? {
        let candidates: [String]

        switch settings.statusBarIcon {
        case .none:
            return nil
        case .dynamicBattery:
            return nil
        default:
            if let name = settings.statusBarIcon.symbolName {
                candidates = [name]
            } else {
                return nil
            }
        }

        return candidates.first {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
        }
    }

    private func ensurePopoverContent() {
        guard popover.contentViewController == nil else { return }
        popover.contentViewController = NSHostingController(
            rootView: StatusPopoverView()
                .environmentObject(appState)
        )
    }

    private func statusIconKey(for settings: PowerSettings, snapshot: PowerSnapshot) -> StatusIconKey {
        switch settings.statusBarIcon {
        case .dynamicBattery:
            return StatusIconKey(
                icon: settings.statusBarIcon,
                batteryLevel: snapshot.batteryLevelPrecise,
                overlay: batteryOverlay(for: snapshot),
                symbolName: nil
            )
        case .none:
            return StatusIconKey(
                icon: settings.statusBarIcon,
                batteryLevel: 0,
                overlay: .none,
                symbolName: nil
            )
        default:
            return StatusIconKey(
                icon: settings.statusBarIcon,
                batteryLevel: 0,
                overlay: .none,
                symbolName: resolveSymbolName(settings: settings)
            )
        }
    }

    private func batteryOverlay(for snapshot: PowerSnapshot) -> BatteryIconRenderer.Overlay {
        if snapshot.isChargingActive {
            return .charging
        }
        if snapshot.isExternalPowerConnected {
            return .pluggedIn
        }
        return .none
    }
}
