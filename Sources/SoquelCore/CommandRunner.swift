import Foundation

/// Running a shell command in the folder you are looking at.
///
/// This is not a terminal emulator. There is no cursor addressing, no curses,
/// no `vim`. It runs a command, streams what it prints, and reports how it
/// exited — which covers `git status`, `npm run build`, `make`, and the other
/// nine tenths of what a file manager's terminal button gets used for. For
/// anything interactive, ⌃⌘T still opens the real thing.
final class CommandRunner {
    enum Event {
        case output(String)
        case finished(status: Int32)
    }

    private var process: Process?
    private let queue = DispatchQueue(label: "app.soquel.command")

    var isRunning: Bool { process?.isRunning == true }

    /// `TERM=dumb` so tools do not emit colour and cursor control that would
    /// arrive here as noise. Anything that slips through is stripped below.
    func run(_ command: String, in directory: URL, onEvent: @escaping (Event) -> Void) {
        cancel()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", command]
        task.currentDirectoryURL = directory

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        environment["CLICOLOR"] = "0"
        environment["NO_COLOR"] = "1"
        task.environment = environment

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        process = task

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = CommandRunner.strip(String(decoding: data, as: UTF8.self))
            DispatchQueue.main.async { onEvent(.output(text)) }
        }

        task.terminationHandler = { finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            // Whatever was buffered when the process exited.
            let rest = pipe.fileHandleForReading.availableData
            DispatchQueue.main.async {
                if !rest.isEmpty {
                    onEvent(.output(CommandRunner.strip(String(decoding: rest, as: UTF8.self))))
                }
                onEvent(.finished(status: finished.terminationStatus))
            }
        }

        queue.async {
            do {
                try task.run()
            } catch {
                DispatchQueue.main.async {
                    onEvent(.output("Could not run: \(error.localizedDescription)\n"))
                    onEvent(.finished(status: -1))
                }
            }
        }
    }

    /// SIGINT first, the same as ⌃C, so a well-behaved program can tidy up.
    func cancel() {
        guard let process, process.isRunning else { return }
        process.interrupt()
        self.process = nil
    }

    /// Removes ANSI escape sequences. TERM=dumb stops most of them; a tool that
    /// writes colour unconditionally would otherwise fill the output with
    /// `[0;32m`.
    static func strip(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var iterator = text.makeIterator()
        var pending: Character?

        while let character = pending ?? iterator.next() {
            pending = nil
            guard character == "\u{1B}" else {
                out.append(character)
                continue
            }
            // CSI: ESC [ … final byte in @ to ~
            guard let next = iterator.next() else { break }
            if next == "[" {
                while let byte = iterator.next() {
                    if ("@"..."~").contains(byte) { break }
                }
            } else if next == "]" {
                // OSC: runs to BEL or ST.
                while let byte = iterator.next() {
                    if byte == "\u{07}" { break }
                    if byte == "\u{1B}" {
                        pending = iterator.next()
                        break
                    }
                }
            }
        }
        return out
    }

    /// What the footer says once a command is done.
    static func exitSummary(status: Int32) -> String {
        switch status {
        case 0: return "Done"
        case -1: return "Did not start"
        // 128 + signal. 130 is ⌃C, which is not a failure worth shouting about.
        case 130: return "Interrupted"
        default: return "Exited \(status)"
        }
    }
}
