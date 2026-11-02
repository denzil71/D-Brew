import Foundation
import SwiftUI

enum Prefs {
    /// Run `brew update` before listing, so the list reflects the newest versions.
    static let refreshFirst = "refreshFirst"
    /// Also list casks that update themselves (`--greedy`).
    static let includeGreedy = "includeGreedy"
}

@MainActor
final class BrewModel: ObservableObject {
    @Published private(set) var packages: [Package] = []
    @Published var selection: Set<Package.ID> = []
    /// What's happening right now, e.g. "Updating Homebrew…"; nil when idle.
    @Published private(set) var activity: String?
    @Published private(set) var isUpgrading = false
    @Published private(set) var lastScan: Date?
    @Published var error: String?
    /// Output of the current or last brew command run.
    @Published private(set) var log = ""
    /// Set when an upgrade finishes: true if every command succeeded.
    @Published private(set) var upgradeSucceeded: Bool?
    @Published var showLog = false

    private var handle: BrewProcess?

    var isBusy: Bool { activity != nil }
    var brewInstalled: Bool { Brew.executable != nil }

    init() {
        UserDefaults.standard.register(defaults: [Prefs.refreshFirst: true, Prefs.includeGreedy: false])
    }

    // MARK: Scan

    func scan() {
        guard !isBusy, brewInstalled else { return }
        Task { await runScan(afterUpgrade: false) }
    }

    /// After an upgrade the list is refreshed without `brew update`, keeping the upgrade's output.
    private func runScan(afterUpgrade: Bool) async {
        let handle = BrewProcess()
        self.handle = handle
        defer { if self.handle === handle { self.handle = nil } }
        if !afterUpgrade {
            error = nil
            log = ""
        }

        if !afterUpgrade, UserDefaults.standard.bool(forKey: Prefs.refreshFirst) {
            activity = "Updating Homebrew…"
            let update = await Brew.run(["update"], handle: handle, onOutput: { self.appendLog($0) })
            if handle.stopped { return finishStopped() }
            if !update.succeeded {
                // Still list what the local database knows; just say the refresh failed.
                error = "brew update failed, so the list may be out of date.\n\(Self.lastLines(update.stderr))"
            }
        }

        activity = "Checking for outdated packages…"
        var arguments = ["outdated", "--json=v2"]
        if UserDefaults.standard.bool(forKey: Prefs.includeGreedy) { arguments.append("--greedy") }
        let outdated = await Brew.run(arguments, environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"], handle: handle)
        if handle.stopped { return finishStopped() }
        guard var found = Brew.parseOutdated(outdated.stdout) else {
            activity = nil
            error = "Couldn't read Homebrew's list of outdated packages.\n\(Self.lastLines(outdated.stderr))"
            return
        }
        found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        // Keep ticks for packages still listed.
        let ids = Set(found.map(\.id))
        packages = found
        selection = selection.intersection(ids)
        lastScan = Date()

        activity = "Measuring disk space…"
        let casks = found.filter { $0.kind == .cask }.map(\.name)
        var apps: [String: [String]] = [:]
        if !casks.isEmpty {
            let info = await Brew.run(["info", "--cask", "--json=v2"] + casks,
                                      environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"], handle: handle)
            apps = Brew.parseCaskApps(info.stdout)
        }
        let measured = await Task.detached(priority: .userInitiated) {
            found.map { package -> Package in
                var package = package
                package.appPath = (apps[package.name] ?? []).lazy.compactMap(Brew.appLocation).first
                package.size = Brew.size(of: package, appPath: package.appPath)
                return package
            }
        }.value
        if handle.stopped { return finishStopped() }
        packages = measured
        activity = nil
    }

    private func finishStopped() {
        activity = nil
    }

    /// Stops a scan. Upgrades aren't stopped part-way.
    func stopScan() {
        guard !isUpgrading else { return }
        handle?.stop()
        activity = nil
    }

    // MARK: Upgrade

    var selectedPackages: [Package] { packages.filter { selection.contains($0.id) && !$0.pinned } }
    var upgradable: [Package] { packages.filter { !$0.pinned } }

    func upgradeSelected() { upgrade(selectedPackages) }
    func upgradeAll() { upgrade(upgradable) }

    private func upgrade(_ chosen: [Package]) {
        guard !isBusy, !chosen.isEmpty else { return }
        Task { await runUpgrade(chosen) }
    }

    private func runUpgrade(_ chosen: [Package]) async {
        let handle = BrewProcess()
        self.handle = handle
        isUpgrading = true
        upgradeSucceeded = nil
        showLog = true
        log = ""
        error = nil
        var environment = ["HOMEBREW_NO_AUTO_UPDATE": "1"]
        if let askpass = Brew.askpassHelper() { environment["SUDO_ASKPASS"] = askpass }

        var ok = true
        let formulae = chosen.filter { $0.kind == .formula }.map(\.name)
        let casks = chosen.filter { $0.kind == .cask }.map(\.name)
        for (names, extra, label) in [(formulae, [String](), "formulae"), (casks, ["--cask"], "casks")] where !names.isEmpty {
            activity = "Updating \(label)…"
            let arguments = ["upgrade"] + extra + names
            appendLog("==> brew \(arguments.joined(separator: " "))\n")
            let result = await Brew.run(arguments, environment: environment, handle: handle, onOutput: { self.appendLog($0) })
            if !result.succeeded { ok = false }
            appendLog("\n")
        }
        upgradeSucceeded = ok
        isUpgrading = false
        activity = nil
        self.handle = nil
        selection.subtract(chosen.map(\.id))
        await runScan(afterUpgrade: true)
    }

    // MARK: Helpers

    private nonisolated func appendLog(_ text: String) {
        Task { @MainActor in self.log += text }
    }

    var selectedSize: Int64 { selectedPackages.reduce(0) { $0 + ($1.size ?? 0) } }

    func toggle(_ package: Package) {
        if selection.contains(package.id) { selection.remove(package.id) } else { selection.insert(package.id) }
    }

    func selectAll(_ on: Bool) {
        selection = on ? Set(upgradable.map(\.id)) : []
    }

    static func lastLines(_ text: String, count: Int = 4) -> String {
        text.split(separator: "\n").suffix(count).joined(separator: "\n")
    }

    static func format(_ bytes: Int64?) -> String {
        guard let bytes else { return "…" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
