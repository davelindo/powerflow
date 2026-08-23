import Darwin
import Foundation

/// Runs a short-lived system utility without allowing its output or shutdown to
/// block Powerflow indefinitely.
enum BoundedProcessRunner {
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var storage = Data()
        private(set) var exceededLimit = false

        init(limit: Int) {
            self.limit = limit
            storage.reserveCapacity(min(limit, 64 * 1_024))
        }

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            guard !exceededLimit else { return }
            guard data.count <= limit - storage.count else {
                exceededLimit = true
                storage.removeAll(keepingCapacity: false)
                return
            }
            storage.append(data)
        }

        func result() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return exceededLimit ? nil : storage
        }
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = 4,
        terminationGrace: TimeInterval = 0.25,
        maximumOutputBytes: Int = 1_048_576
    ) -> Data? {
        guard timeout > 0, terminationGrace >= 0, maximumOutputBytes > 0 else { return nil }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let pipe = Pipe()
        let output = OutputBuffer(limit: maximumOutputBytes)
        let completion = DispatchSemaphore(value: 0)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in completion.signal() }

        let readHandle = pipe.fileHandleForReading
        readHandle.readabilityHandler = { handle in
            output.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            readHandle.readabilityHandler = nil
            return nil
        }

        let finishedNormally = completion.wait(timeout: .now() + timeout) == .success
        if !finishedNormally {
            process.terminate()
            if completion.wait(timeout: .now() + terminationGrace) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 1)
            }
            readHandle.readabilityHandler = nil
            try? readHandle.close()
            return nil
        }

        readHandle.readabilityHandler = nil
        output.append(readHandle.readDataToEndOfFile())
        guard process.terminationStatus == 0 else { return nil }
        return output.result()
    }
}
