import AppKit
import Foundation

final class AppIconCache {
    static let shared = AppIconCache()

    private var images: [String: NSImage] = [:]

    func prefetch(paths: [String]) {
        for path in Set(paths) {
            guard images[path] == nil else { continue }
            images[path] = loadImage(for: path)
        }
    }

    func cachedImage(for path: String?) -> NSImage? {
        guard let path else { return nil }
        return images[path]
    }

    private func loadImage(for path: String) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 32, height: 32)
        return image
    }
}
