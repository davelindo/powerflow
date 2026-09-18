import Darwin
import Foundation

/// Runs a short-lived system utility without allowing its output or shutdown to
/// block Powerflow indefinitely.
enum BoundedProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = 4,
        terminationGrace: TimeInterval = 0.25,
        maximumOutputBytes: Int = 1_048_576
    ) -> Data? {
        guard timeout.isFinite, timeout > 0,
              terminationGrace.isFinite, terminationGrace >= 0,
              maximumOutputBytes > 0 else { return nil }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let pipe = Pipe()
        let completion = DispatchSemaphore(value: 0)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in completion.signal() }

        let readHandle = pipe.fileHandleForReading
        defer {
            try? readHandle.close()
            try? pipe.fileHandleForWriting.close()
        }
        let deadline = DispatchTime.now() + timeout

        do {
            try process.run()
        } catch {
            return nil
        }
        // Only the subprocess owns the write end now. A single synchronous,
        // nonblocking reader avoids racing a readability callback at shutdown.
        try? pipe.fileHandleForWriting.close()
        let output = drain(readHandle.fileDescriptor, until: deadline, limit: maximumOutputBytes)

        let terminationDeadline: DispatchTime = output == nil ? .now() : deadline
        let finishedNormally = completion.wait(timeout: terminationDeadline) == .success
        if !finishedNormally {
            if process.isRunning { process.terminate() }
            if completion.wait(timeout: .now() + terminationGrace) == .timedOut {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                _ = completion.wait(timeout: .now() + 1)
            }
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        return output
    }

    private static func drain(_ descriptor: Int32, until deadline: DispatchTime, limit: Int) -> Data? {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while DispatchTime.now() < deadline {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard count <= limit - output.count else { return nil }
                output.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return output
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline.uptimeNanoseconds else { return nil }
                let remaining = Double(deadline.uptimeNanoseconds - now) / 1_000_000
                var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let result = poll(&descriptorState, 1, Int32(min(remaining.rounded(.up), Double(Int32.max))))
                if result < 0 && errno != EINTR { return nil }
            } else {
                return nil
            }
        }
        return nil
    }
}
