import SwiftUI

private struct PowerflowSnapshotRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var powerflowSnapshotRendering: Bool {
        get { self[PowerflowSnapshotRenderingKey.self] }
        set { self[PowerflowSnapshotRenderingKey.self] = newValue }
    }
}
