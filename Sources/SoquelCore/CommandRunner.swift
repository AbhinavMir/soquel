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
    /// Counts runs. A cancelled process can outlive its SIGINT, and its
    /// handlers still hold the caller's onEvent; every event checks the
    /// generation it was started under, so a superseded run cannot write its
    /// output or its exit status into the run that replaced it. Only read and
    /// written on the main thread.
    private var generation = 0

    var isRunning: Bool { process?.isRunning == true }

    /// `TERM=dumb` so tools do not emit colour and cursor control that would
    /// arrive here as noise. Anything that slips through is stripped below.
    func run(_ command: String, in directory: URL, onEvent: @escaping (Event) -> Void) {
        cancel()
        generation += 1
        let token = generation

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

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = CommandRunner.strip(String(decoding: data, as: UTF8.self))
            DispatchQueue.main.async {
                guard self?.generation == token else { return }
                onEvent(.output(text))
            }
        }

        task.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            // Whatever was buffered when the process exited.
            let rest = pipe.fileHandleForReading.availableData
            DispatchQueue.main.async {
                guard self?.generation == token else { return }
                if !rest.isEmpty {
                    onEvent(.output(CommandRunner.strip(String(decoding: rest, as: UTF8.self))))
                }
                onEvent(.finished(status: finished.terminationStatus))
            }
        }

        queue.async { [weak self] in
            do {
                try task.run()
            } catch {
                DispatchQueue.main.async {
                    guard self?.generation == token else { return }
                    onEvent(.output("Could not run: \(error.localizedDescription)\n"))
                    onEvent(.finished(status: -1))
                }
            }
        }
    }

    /// SIGINT first, the same as ⌃C, so a well-behaved program can tidy up.
    /// Some tools trap or outlive the interrupt; after a grace period the
    /// process gets SIGTERM, so it does not run on unstoppable once the
    /// reference here is dropped. The generation stays as it is: the exit
    /// still reports "Interrupted" through the current run's events unless a
    /// new run has started, in which case the token check drops them.
    func cancel() {
        guard let process, process.isRunning else { return }
        process.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if process.isRunning { process.terminate() }
        }
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
                        // ST is ESC \. The backslash is part of the
                        // terminator, so it is consumed here; anything else
                        // means a new sequence began inside this one, and the
                        // outer loop takes it from the top.
                        let after = iterator.next()
                        if after != "\\" { pending = after }
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
