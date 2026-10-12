import Foundation
import UIKit
import Darwin
import WindowsVRCore

/// Requests Madeira's debugger protocol in the currently running host process.
/// A debugger attachment is only a prerequisite; native FEX initialization must
/// still prepare its executable pool and report its own errors.
@MainActor
final class JITCoordinator {
    enum Failure: LocalizedError {
        case helperUnavailable, scriptMissing, invalidRequest, attachmentTimedOut

        var errorDescription: String? {
            switch self {
            case .helperUnavailable: return L("Install and configure StikDebug for visionOS before starting a Windows game.", "Installiere und konfiguriere StikDebug für visionOS, bevor du ein Windows-Spiel startest.")
            case .scriptMissing: return L("The Madeira JIT protocol script is missing from this app.", "Das Madeira-JIT-Protokollskript fehlt in dieser App.")
            case .invalidRequest: return L("The app could not create its debugger request.", "Die App konnte die Debugger-Anfrage nicht erstellen.")
            case .attachmentTimedOut: return L("The debugger did not attach. Check StikDebug's remote pairing and local VPN configuration.", "Der Debugger wurde nicht angehängt. Prüfe die Kopplung mit StikDebug und die lokale VPN-Konfiguration.")
            }
        }
    }

    func prepareDebugger() async throws {
        // An arbitrary Xcode debugger cannot service Madeira's custom BRK
        // protocol. Always request the script-capable helper, even if traced.
        let scheme = ["stikdebug", "stikjit"].first { candidate in
            guard let url = URL(string: "\(candidate)://enable-jit") else { return false }
            return UIApplication.shared.canOpenURL(url)
        }
        guard let scheme else { throw Failure.helperUnavailable }
        guard let bundleID = Bundle.main.bundleIdentifier else { throw Failure.invalidRequest }
        guard let scriptURL = Bundle.main.url(forResource: "madeira-jit", withExtension: "js") else {
            throw Failure.scriptMissing
        }
        let script = try Data(contentsOf: scriptURL)
        var components = URLComponents()
        components.scheme = scheme
        components.host = "enable-jit"
        components.queryItems = [
            URLQueryItem(name: "bundle-id", value: bundleID),
            URLQueryItem(name: "pid", value: String(getpid())),
            URLQueryItem(name: "script-data", value: script.base64EncodedString())
        ]
        guard let url = components.url else { throw Failure.invalidRequest }
        let opened = await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { accepted in
                continuation.resume(returning: accepted)
            }
        }
        guard opened else { throw Failure.helperUnavailable }
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if Self.isDebuggerAttached() { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw Failure.attachmentTimedOut
    }

    private static func isDebuggerAttached() -> Bool {
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = query.withUnsafeMutableBufferPointer { query in
            sysctl(query.baseAddress, UInt32(query.count), &process, &size, nil, 0)
        }
        return result == 0 && (process.kp_proc.p_flag & P_TRACED) != 0
    }
}
