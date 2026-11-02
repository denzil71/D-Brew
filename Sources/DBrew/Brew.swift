import Foundation
import os

/// An outdated formula or cask.
struct Package: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case formula, cask
    }

    let name: String
    let kind: Kind
    /// Installed versions, oldest first (a formula can keep several).
    let installed: [String]
    let latest: String
    /// Pinned formulae are skipped by `brew upgrade`.
    let pinned: Bool
    /// Space on disk: the formula's Cellar folder (every installed version), or the cask's
    /// Caskroom folder plus the app it installed. nil until measured.
    var size: Int64?
    /// The app a cask installed, when there is one.
    var appPath: String?

    var id: String { "\(kind.rawValue):\(name)" }
    var installedVersion: String { installed.last ?? "–" }
    /// For sorting; unmeasured sizes sort first.
    var sortSize: Int64 { size ?? -1 }
    var kindLabel: String { kind == .formula ? "Formula" : "Cask" }
}

/// A running `brew` process that can be stopped.
final class BrewProcess: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Process?>(initialState: nil)
    private let stoppedState = OSAllocatedUnfairLock(initialState: false)

    var stopped: Bool { stoppedState.withLock { $0 } }

    fileprivate func attach(_ process: Process) -> Bool {
        lock.withLock { $0 = process }
        return !stopped
    }

    func stop() {
        stoppedState.withLock { $0 = true }
        lock.withLock { $0?.terminate() }
    }
}

enum Brew {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        var succeeded: Bool { status == 0 }
    }

    /// Homebrew's own install locations (Apple silicon, then Intel).
    static let executable: URL? = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        .map { URL(fileURLWithPath: $0) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }

    /// The Homebrew prefix, e.g. /opt/homebrew.
    static var prefix: URL? { executable?.deletingLastPathComponent().deletingLastPathComponent() }

    /// Apps launched from Finder get a minimal PATH, so Homebrew's own bin folders are added.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let base = prefix.map { "\($0.path)/bin:\($0.path)/sbin:" } ?? ""
        env["PATH"] = base + "/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        env["HOMEBREW_NO_EMOJI"] = "1"
        env["NO_COLOR"] = "1"
        return env
    }

    /// Runs brew with `arguments`. `onOutput` receives stdout and stderr text as it arrives.
    static func run(
        _ arguments: [String], environment extra: [String: String] = [:], handle: BrewProcess? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async -> Output {
        guard let executable else { return Output(status: -1, stdout: "", stderr: "Homebrew isn't installed.") }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment.merging(extra) { $1 }
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.standardInput = FileHandle.nullDevice
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let collected = OSAllocatedUnfairLock(initialState: (out: Data(), err: Data()))

            @Sendable func drain(_ handle: FileHandle, isError: Bool) {
                let data = handle.availableData
                guard !data.isEmpty else { return }
                collected.withLock { isError ? $0.err.append(data) : $0.out.append(data) }
                onOutput?(String(decoding: data, as: UTF8.self))
            }
            out.fileHandleForReading.readabilityHandler = { drain($0, isError: false) }
            err.fileHandleForReading.readabilityHandler = { drain($0, isError: true) }

            process.terminationHandler = { process in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                // Whatever arrived after the last callback.
                for (pipe, isError) in [(out, false), (err, true)] {
                    let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                    guard !rest.isEmpty else { continue }
                    collected.withLock { isError ? $0.err.append(rest) : $0.out.append(rest) }
                    onOutput?(String(decoding: rest, as: UTF8.self))
                }
                let (stdout, stderr) = collected.withLock { $0 }
                continuation.resume(returning: Output(
                    status: process.terminationStatus,
                    stdout: String(decoding: stdout, as: UTF8.self),
                    stderr: String(decoding: stderr, as: UTF8.self)))
            }
            if let handle, !handle.attach(process) {
                continuation.resume(returning: Output(status: -1, stdout: "", stderr: "Stopped."))
                return
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: Output(status: -1, stdout: "", stderr: error.localizedDescription))
            }
        }
    }

    // MARK: Outdated packages

    private struct OutdatedJSON: Decodable {
        struct Item: Decodable {
            let name: String
            let installed_versions: [String]
            let current_version: String
            let pinned: Bool?
        }
        let formulae: [Item]
        let casks: [Item]
    }

    static func parseOutdated(_ json: String) -> [Package]? {
        guard let decoded = try? JSONDecoder().decode(OutdatedJSON.self, from: Data(json.utf8)) else { return nil }
        let formulae = decoded.formulae.map {
            Package(name: $0.name, kind: .formula, installed: $0.installed_versions, latest: $0.current_version,
                    pinned: $0.pinned ?? false)
        }
        let casks = decoded.casks.map {
            Package(name: $0.name, kind: .cask, installed: $0.installed_versions, latest: $0.current_version,
                    pinned: false)
        }
        return formulae + casks
    }

    /// App bundle names each cask installs, from `brew info --cask --json=v2`.
    static func parseCaskApps(_ json: String) -> [String: [String]] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else { return [:] }
        var result: [String: [String]] = [:]
        for cask in casks {
            guard let token = cask["token"] as? String else { continue }
            let artifacts = cask["artifacts"] as? [[String: Any]] ?? []
            // Entries are "Name.app", or ["Name.app", {"target": "Other.app"}] when renamed on install.
            let apps = artifacts.compactMap { $0["app"] as? [Any] }.flatMap { entries -> [String] in
                var names: [String] = []
                for entry in entries {
                    if let target = (entry as? [String: Any])?["target"] as? String {
                        if !names.isEmpty { names.removeLast() }
                        names.append(target)
                    } else if let name = entry as? String {
                        names.append(name)
                    }
                }
                return names
            }
            result[token] = apps
        }
        return result
    }

    // MARK: Disk space

    /// Where a cask's app is installed, if it's there.
    static func appLocation(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.fileExists(atPath: name) ? name : nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications/\(name)", "\(home)/Applications/\(name)"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Space on disk of `package`'s files.
    static func size(of package: Package, appPath: String?) -> Int64 {
        guard let prefix else { return 0 }
        // Formulae from other taps are listed as "user/tap/name"; folders use the short name.
        let short = package.name.split(separator: "/").last.map(String.init) ?? package.name
        switch package.kind {
        case .formula:
            return allocatedSize(prefix.appendingPathComponent("Cellar/\(short)"))
        case .cask:
            let caskroom = allocatedSize(prefix.appendingPathComponent("Caskroom/\(short)"))
            return caskroom + (appPath.map { allocatedSize(URL(fileURLWithPath: $0)) } ?? 0)
        }
    }

    /// Allocated size of everything under `url`, without following symlinks.
    static func allocatedSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: Administrator password

    /// A helper `sudo -A` runs to ask for the password with a macOS dialog, since a cask
    /// installer that needs sudo has no terminal to ask in. Homebrew passes `-A` when SUDO_ASKPASS is set.
    static func askpassHelper() -> String? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("D-Brew", isDirectory: true)
        let url = support.appendingPathComponent("askpass.sh")
        let script = """
            #!/bin/sh
            # Asked by sudo (via Homebrew) when an update needs an administrator password.
            exec /usr/bin/osascript \\
              -e 'display dialog "Homebrew needs your administrator password to finish an update." with title "D-Brew" default answer "" with hidden answer with icon caution buttons {"Cancel", "OK"} default button "OK"' \\
              -e 'text returned of result'

            """
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            if (try? String(contentsOf: url, encoding: .utf8)) != script {
                try script.write(to: url, atomically: true, encoding: .utf8)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url.path
        } catch {
            NSLog("D-Brew: couldn't write askpass helper: \(error)")
            return nil
        }
    }
}
