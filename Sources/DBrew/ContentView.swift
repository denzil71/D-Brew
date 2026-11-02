import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: BrewModel
    @AppStorage(Prefs.refreshFirst) private var refreshFirst = true
    @AppStorage(Prefs.includeGreedy) private var includeGreedy = false
    @State private var sortOrder = [KeyPathComparator(\Package.name)]

    var body: some View {
        Group {
            if model.brewInstalled {
                VStack(spacing: 0) {
                    statusBar
                    if let error = model.error { errorBanner(error) }
                    Divider()
                    table
                    Divider()
                    actionBar
                }
            } else {
                NoHomebrewView()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.scan() } label: { Label("Scan", systemImage: "arrow.clockwise") }
                    .help("Check for outdated packages (⌘R)")
                    .disabled(model.isBusy || !model.brewInstalled)
                Menu {
                    Toggle("Run brew update before scanning", isOn: $refreshFirst)
                    Toggle("Include casks that update themselves", isOn: $includeGreedy)
                } label: {
                    Label("Options", systemImage: "slider.horizontal.3")
                }
                .help("Scan options")
                Button { model.showLog = true } label: { Label("Output", systemImage: "terminal") }
                    .help("Show Homebrew's output (⌘L)")
                    .disabled(model.log.isEmpty)
            }
        }
        .sheet(isPresented: $model.showLog) { LogSheet().environmentObject(model) }
        .onAppear { if model.lastScan == nil { model.scan() } }
    }

    // MARK: Status

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let activity = model.activity {
                ProgressView().controlSize(.small)
                Text(activity)
                Spacer()
                if !model.isUpgrading { Button("Stop") { model.stopScan() } }
            } else if let lastScan = model.lastScan {
                Image(systemName: model.packages.isEmpty ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(model.packages.isEmpty ? Color.green : Color.accentColor)
                Text(summary)
                Spacer()
                Text("Checked \(lastScan.formatted(.relative(presentation: .named)))")
                    .foregroundStyle(.secondary)
            } else {
                Text("Not scanned yet").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var summary: String {
        let count = model.packages.count
        if count == 0 { return "Everything is up to date." }
        let total = model.packages.compactMap(\.size).reduce(0, +)
        return "\(count) package\(count == 1 ? "" : "s") can be updated · \(BrewModel.format(total)) on disk"
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).textSelection(.enabled)
            Spacer()
            Button { model.error = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: Table

    private var table: some View {
        Table(model.packages.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("") { package in
                Toggle("", isOn: Binding(
                    get: { model.selection.contains(package.id) },
                    set: { _ in model.toggle(package) }))
                    .labelsHidden()
                    .disabled(package.pinned || model.isBusy)
                    .help(package.pinned ? "Pinned — run brew unpin \(package.name) to allow updates." : "")
            }
            .width(22)
            TableColumn("Package", value: \.name) { package in
                HStack(spacing: 5) {
                    Text(package.name).fontWeight(.medium)
                    if package.pinned {
                        Image(systemName: "pin.fill").foregroundStyle(.secondary).font(.caption)
                            .help("Pinned: brew upgrade skips it.")
                    }
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("Type", value: \.kindLabel) { package in
                Text(package.kindLabel).foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60)
            TableColumn("Installed", value: \.installedVersion) { package in
                HStack(spacing: 4) {
                    Text(package.installedVersion).monospacedDigit()
                    if package.installed.count > 1 {
                        Text("+\(package.installed.count - 1) older")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .help(package.installed.count > 1 ? "Installed: \(package.installed.joined(separator: ", "))" : "")
            }
            .width(min: 90, ideal: 140)
            TableColumn("Latest", value: \.latest) { package in
                Text(package.latest).monospacedDigit()
            }
            .width(min: 80, ideal: 110)
            TableColumn("On Disk", value: \.sortSize) { package in
                Text(BrewModel.format(package.size))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(package.appPath.map { "Includes \($0)" } ?? "")
            }
            .width(min: 70, ideal: 80)
        }
        .overlay {
            if model.packages.isEmpty, model.lastScan != nil, !model.isBusy {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal").font(.system(size: 36)).foregroundStyle(.green)
                    Text("Everything is up to date").font(.headline)
                }
            }
        }
    }

    // MARK: Actions

    private var actionBar: some View {
        HStack(spacing: 12) {
            Toggle("Select All", isOn: Binding(
                get: { !model.upgradable.isEmpty && model.selectedPackages.count == model.upgradable.count },
                set: { model.selectAll($0) }))
                .disabled(model.upgradable.isEmpty || model.isBusy)
            if !model.selectedPackages.isEmpty {
                Text("\(model.selectedPackages.count) selected · \(BrewModel.format(model.selectedSize))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Update Selected") { model.upgradeSelected() }
                .disabled(model.selectedPackages.isEmpty || model.isBusy)
            Button("Update All") { model.upgradeAll() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.upgradable.isEmpty || model.isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Homebrew's output while (and after) updating.
struct LogSheet: View {
    @EnvironmentObject var model: BrewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if model.isUpgrading {
                    ProgressView().controlSize(.small)
                    Text(model.activity ?? "Updating…").font(.headline)
                } else if let ok = model.upgradeSucceeded {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ok ? .green : .orange)
                    Text(ok ? "Update finished" : "Update finished with errors — see the output below").font(.headline)
                } else {
                    Text("Homebrew output").font(.headline)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.log.isEmpty ? " " : model.log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: model.log) { _ in proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            if model.isUpgrading {
                Text("If an update needs your administrator password, macOS will ask for it in a separate dialog.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Copy Output") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.log, forType: .string)
                }
                Spacer()
                Button("Done") { model.showLog = false }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isUpgrading)
            }
        }
        .padding(18)
        .frame(width: 640, height: 440)
        .interactiveDismissDisabled(model.isUpgrading)
    }
}

struct NoHomebrewView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text("Homebrew isn't installed").font(.title3.weight(.semibold))
            Text("D-Brew looks for brew in /opt/homebrew/bin and /usr/local/bin.")
                .foregroundStyle(.secondary)
            Link("Get Homebrew at brew.sh", destination: URL(string: "https://brew.sh")!)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
