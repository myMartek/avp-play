import Foundation
import Darwin

/// Lässt ein fremdes Kommandozeilenwerkzeug an einem eigenen Pseudo-Terminal laufen und reicht durch, was der
/// Nutzer tippt und was das Werkzeug schreibt. So kann ein Werkzeug nach Passwort und Bestätigungscode fragen,
/// ohne dass dieses Programm die Antworten je zu sehen bekommt: Sie gehen unverändert an das Werkzeug und werden
/// nirgends gespeichert.
enum Pty {
    /// Startet das Werkzeug und kehrt zurück, wenn es endet.
    /// - Parameters:
    ///   - input, output: das Terminal des Nutzers (oder die Leitungen eines Fensters, das eines darstellt).
    ///   - transform: bekommt jede Ausgabe des Werkzeugs, bevor sie erscheint – um Geheimes zurückzuhalten.
    ///   - finish: was `transform` am Ende noch zurückgehalten hat.
    /// - Returns: der Endestatus; negativ, wenn ein Signal das Werkzeug beendet hat.
    static func run(tool: URL, arguments: [String], environment: [String: String], directory: URL? = nil,
                    input: Int32, output: Int32,
                    transform: (ArraySlice<UInt8>) -> [UInt8], finish: () -> [UInt8] = { [] }) throws -> Int32 {
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize()
        let haveSize = ioctl(input, TIOCGWINSZ, &size) == 0
        guard (haveSize ? openpty(&master, &slave, nil, nil, &size) : openpty(&master, &slave, nil, nil, nil)) == 0 else {
            throw LoginError.couldNotStart(String(cString: strerror(errno)))
        }
        defer { close(master) }
        guard let slaveName = ttyname(slave).map({ String(cString: $0) }) else {
            close(slave); throw LoginError.couldNotStart(L("no name for the pseudo-terminal", "kein Name für das Pseudo-Terminal"))
        }

        // Das Kind bekommt eine eigene Sitzung und öffnet das Terminal selbst: so wird es dessen steuerndes
        // Terminal, und Strg-C des Nutzers erreicht das Werkzeug. Alle übrigen Deskriptoren bleiben zu.
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, slaveName, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory.path) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = ([tool.path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv + envp { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, tool.path, &actions, &attr, argv, envp)
        close(slave)
        guard rc == 0 else { throw LoginError.couldNotStart(String(cString: strerror(rc))) }

        // Das Terminal des Nutzers roh schalten: Echo und Zeilenbearbeitung macht das Pseudo-Terminal.
        var saved = termios()
        let isTerminal = isatty(input) == 1 && tcgetattr(input, &saved) == 0
        if isTerminal {
            var raw = saved
            cfmakeraw(&raw)
            tcsetattr(input, TCSANOW, &raw)
        }
        defer { if isTerminal { tcsetattr(input, TCSANOW, &saved) } }

        var inputOpen = true
        var buffer = [UInt8](repeating: 0, count: 4096)
        func emit(_ bytes: [UInt8]) {
            var rest = bytes[...]
            while !rest.isEmpty {
                let n = rest.withUnsafeBytes { write(output, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                rest = rest.dropFirst(n)
            }
        }
        relay: while true {
            var fds = [pollfd(fd: master, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: inputOpen ? input : -1, events: Int16(POLLIN), revents: 0)]
            if poll(&fds, 2, -1) < 0 { if errno == EINTR { continue }; break }
            if fds[1].revents & Int16(POLLIN | POLLHUP) != 0 {
                let n = read(input, &buffer, buffer.count)
                if n > 0 { _ = buffer.withUnsafeBytes { write(master, $0.baseAddress, n) } } else { inputOpen = false }
            }
            if fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let n = read(master, &buffer, buffer.count)
                if n <= 0 { break relay }       // das Werkzeug hat sein Terminal geschlossen
                emit(transform(buffer[..<n]))
            }
        }
        emit(finish())

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let exited = (status & 0x7f) == 0
        return exited ? (status >> 8) & 0xff : -(status & 0x7f)
    }
}
