import SwiftUI
import AppKit

/// The first thing a new install shows, and what File › Download Linux… brings back: the Linux machines the launcher
/// can run, each with what it is, its download size and a checkbox. Download fetches the ticked ones side by side,
/// with progress on each row, and adds a machine of each kind that has none yet.
struct WelcomeSheet: View {
    static let showNotification = Notification.Name("mylinux.showWelcome")
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var images: ImageManager
    @ObservedObject var omarchy: OmarchyManager
    @ObservedObject var debian: DebianManager
    @ObservedObject var runtime: RuntimeManager
    /// Called when the sheet closes, with the kinds that were downloaded and are ready (to add machines for).
    let done: ([Profile.Kind]) -> Void
    @State private var chosen: Set<Profile.Kind> = [.mylinux]
    @State private var started = false
    @State private var startedAt: Date? = WelcomeSheet.renderStartedAt
    /// For --render-welcome: a sheet that started downloading this long ago.
    static var renderStartedAt: Date?
    @State private var finishedAt: Date?

    struct Offer {
        let kind: Profile.Kind
        let name: String
        let size: String
        let bytes: Double
        let text: String
    }
    static let offers = [
        Offer(kind: .mylinux, name: "myLinux", size: "110 MB", bytes: 110e6,
              text: "A small Linux desktop with a Mac feel that starts in seconds and runs from memory, so every start is clean. Your home folder, browsers and coding agents live on their own disk."),
        Offer(kind: .omarchy, name: "Omarchy", size: "1.4 GB", bytes: 1.4e9,
              text: "Arch Linux with the Hyprland tiling desktop, run from the keyboard. Your Command key works as its Super key, the clipboard is shared with the Mac, and your windows come back after a restart."),
        Offer(kind: .debian, name: "Debian Server", size: "300 MB", bytes: 300e6,
              text: "The latest stable Debian as a terminal, no desktop. Install Claude Code and Codex from its menu and look at what they build in a browser that lives inside the machine."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(spacing: 10) {
                ForEach(Self.offers, id: \.kind) { row($0) }
            }
            .padding(.horizontal, 24)
            footer
        }
        .frame(width: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // ---- parts ----------------------------------------------------------------------------------------------------
    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: WelcomeSheet.icon("launcher") ?? NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to myLinux").font(.system(size: 24, weight: .bold))
                Text("Pick the Linux machines you want on this Mac. Each one downloads once and runs in its own window with its own disk. You can add the others later with the + button.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 20)
        .overlay(alignment: .topTrailing) { clock.padding(.top, 14).padding(.trailing, 18) }
        .onChange(of: anyBusy) { _, busy in if started && !busy && finishedAt == nil { finishedAt = Date() } }
    }

    /// The download time, top right: elapsed and an estimate of what is left while it runs, the total when done.
    @ViewBuilder private var clock: some View {
        if let startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { ctx in
                let end = finishedAt ?? ctx.date
                let elapsed = end.timeIntervalSince(startedAt)
                VStack(alignment: .trailing, spacing: 1) {
                    Label(finishedAt == nil ? WelcomeSheet.clockText(elapsed) : "Took \(WelcomeSheet.clockText(elapsed))", systemImage: "clock")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    if finishedAt == nil, let left = WelcomeSheet.remaining(elapsed: elapsed, fraction: fraction) {
                        Text(left).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func row(_ o: Offer) -> some View {
        let isOn = present(o.kind) || chosen.contains(o.kind)
        return HStack(alignment: .top, spacing: 14) {
            Toggle("", isOn: Binding(get: { isOn }, set: { on in if on { chosen.insert(o.kind) } else { chosen.remove(o.kind) } }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(started || present(o.kind))
                .padding(.top, 16)
                .accessibilityLabel("Download \(o.name), \(o.size)")
            logo(o.kind)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(o.name).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(present(o.kind) ? "Downloaded" : o.size).font(.callout.monospacedDigit()).foregroundStyle(present(o.kind) ? Color.green : Color.secondary)
                }
                Text(o.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                status(o.kind)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isOn ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isOn ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !started, !present(o.kind) else { return }
            if chosen.contains(o.kind) { chosen.remove(o.kind) } else { chosen.insert(o.kind) }
        }
    }

    /// The machine's own mark on a tile of the same size for all three.
    private func logo(_ kind: Profile.Kind) -> some View {
        ZStack {
            switch kind {
            case .mylinux:
                if let i = WelcomeSheet.icon("myLinux") { Image(nsImage: i).resizable().frame(width: 52, height: 52) }
                else { tile(.blue, "desktopcomputer") }
            case .omarchy:
                // the mark comes on its own dark tile with a margin
                if let i = WelcomeSheet.icon("omarchy") { Image(nsImage: i).resizable().frame(width: 60, height: 60) }
                else { tile(.purple, "keyboard") }
            case .debian:
                if let i = WelcomeSheet.icon("debian") {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white).frame(width: 46, height: 46)
                        .overlay(Image(nsImage: i).resizable().aspectRatio(contentMode: .fit).padding(8))
                } else { tile(.red, "terminal") }
            }
        }
        .frame(width: 52, height: 52)
        .padding(.top, 2)
    }
    private func tile(_ color: Color, _ symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous).fill(color.gradient).frame(width: 46, height: 46)
            .overlay(Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white))
    }

    @ViewBuilder private func status(_ kind: Profile.Kind) -> some View {
        let m = manager(kind)
        if m.busy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(m.progress.isEmpty ? "Starting…" : m.progress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.top, 4)
        } else if let e = m.lastError, started, chosen.contains(kind) {
            Text(e).font(.caption).foregroundStyle(.red).lineLimit(3).padding(.top, 4)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(summary).font(.callout).foregroundStyle(.secondary)
            Spacer()
            if !started {
                Button("Later") { done([]) }.keyboardShortcut(.cancelAction)
                Button("Download") { start() }
                    .keyboardShortcut(.defaultAction).controlSize(.large).disabled(pending.isEmpty)
            } else if anyBusy {
                Button("Continue in Background") { done(readyKinds) }
            } else {
                Button("Done") { done(readyKinds) }.keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
        .padding(24)
    }

    // ---- state ----------------------------------------------------------------------------------------------------
    private func manager(_ kind: Profile.Kind) -> ScriptDownloader {
        switch kind { case .mylinux: return images; case .omarchy: return omarchy; case .debian: return debian }
    }
    private func present(_ kind: Profile.Kind) -> Bool {
        switch kind { case .mylinux: return images.present; case .omarchy: return omarchy.present; case .debian: return debian.present }
    }
    /// Ticked and not downloaded yet.
    private var pending: [Profile.Kind] { Self.offers.map(\.kind).filter { chosen.contains($0) && !present($0) } }
    private var anyBusy: Bool { images.busy || omarchy.busy || debian.busy || runtime.busy }
    private var readyKinds: [Profile.Kind] { Self.offers.map(\.kind).filter { chosen.contains($0) && present($0) } }
    private var summary: String {
        if started && anyBusy { return "Downloading…" }
        if started { return readyKinds.isEmpty ? "Nothing was downloaded." : "Ready. Select a machine and press Start." }
        let bytes = Self.offers.filter { pending.contains($0.kind) }.map(\.bytes).reduce(0, +)
        if bytes == 0 { return "Nothing selected." }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .decimal) + " to download"
    }

    private func start() {
        started = true; startedAt = Date(); finishedAt = nil
        for kind in pending {
            switch kind {
            case .mylinux: images.download(settings)
            case .omarchy:
                // Omarchy runs only on the accelerated runtime; a release carries it, a local build fetches it
                if !runtime.present && !runtime.busy && RuntimeManager.bundledTarball == nil { runtime.download(settings) }
                omarchy.download(settings)
            case .debian: debian.download(settings)
            }
        }
    }

    /// How far the started downloads are, weighted by size: a finished one counts in full, a running one by the
    /// percentage its download prints, a failed one not at all.
    private var fraction: Double {
        var total = 0.0, got = 0.0
        for o in Self.offers where chosen.contains(o.kind) {
            let m = manager(o.kind)
            if present(o.kind) { total += o.bytes; got += o.bytes }
            else if m.busy { total += o.bytes; got += o.bytes * WelcomeSheet.percent(in: m.progress) }
        }
        return total > 0 ? got / total : 0
    }
    /// The last "65.7%" in a line of curl's progress output, as 0...1.
    static func percent(in line: String) -> Double {
        guard let re = try? NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)%") else { return 0 }
        let ms = re.matches(in: line, range: NSRange(line.startIndex..., in: line))
        guard let m = ms.last, let r = Range(m.range(at: 1), in: line), let v = Double(line[r]) else { return 0 }
        return min(max(v / 100, 0), 1)
    }
    /// "4:05", or "1:02:03" past an hour.
    static func clockText(_ t: TimeInterval) -> String {
        let s = Int(t.rounded()); let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    /// "about 3 min left", once there is enough progress to judge (3 % and 5 s).
    static func remaining(elapsed: TimeInterval, fraction f: Double) -> String? {
        guard f >= 0.03, f < 1, elapsed >= 5 else { return nil }
        let left = elapsed * (1 - f) / f
        if left < 60 { return "under a minute left" }
        return "about \(Int((left / 60).rounded())) min left"
    }

    /// An icon from the app bundle (Contents/Resources/icons), or from the developer checkout's tools/icons.
    static func icon(_ name: String) -> NSImage? {
        let file = name == "launcher" ? "myLinux Launcher.png" : "\(name).png"
        if let url = Bundle.main.resourceURL?.appendingPathComponent("icons/\(file)"), let i = NSImage(contentsOf: url) { return i }
        let repo = AppSettings.shared.repoPath
        if !repo.isEmpty, let i = NSImage(contentsOfFile: (repo as NSString).appendingPathComponent("tools/icons/\(file)")) { return i }
        if let repo = Paths.buildRepo, let i = NSImage(contentsOfFile: (repo as NSString).appendingPathComponent("tools/icons/\(file)")) { return i }
        return nil
    }
}
