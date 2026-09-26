import SwiftUI
import AppKit

// The launcher's look since 0.7.0: an Overview of the Mac and its machines, sidebar rows with each machine's icon
// and numbers, and machine pages that lead with state, actions and live activity (settings fold away below).

/// Each kind's icon: the same pictures as the machines' own apps in the Dock (tools/icons).
enum MachineIcon {
    private static var cache: [Profile.Kind: NSImage] = [:]
    static func image(_ kind: Profile.Kind) -> NSImage? {
        if let i = cache[kind] { return i }
        let i = WelcomeSheet.icon(kind == .mylinux ? "myLinux" : "machine-\(kind.rawValue)")
        cache[kind] = i
        return i
    }
}

struct MachineIconView: View {
    let kind: Profile.Kind
    var size: CGFloat = 28
    var body: some View {
        if let i = MachineIcon.image(kind) {
            // the icon files carry Apple's margin around the body; drawn a little larger so the body fills the size
            Image(nsImage: i).resizable().interpolation(.high).frame(width: size * 1.22, height: size * 1.22).frame(width: size, height: size)
        } else {
            Image(systemName: "desktopcomputer").frame(width: size, height: size)
        }
    }
}

/// A machine's state in words, the same in the sidebar, the Overview and the machine page ("Running · ready in 12 s").
enum MachineStatus {
    static func text(_ p: Profile, _ r: Runner, now: Date = Date()) -> String {
        switch r.state {
        case .running where p.isServer && r.readyAt == nil:
            return "Starting… " + Runner.seconds(now.timeIntervalSince(r.startedAt ?? now))
        case .running: return r.readyIn.map { "Running · ready in " + Runner.seconds($0) } ?? "Running"
        case .starting: return "Starting… " + Runner.seconds(now.timeIntervalSince(r.startedAt ?? now))
        case .stopping: return "Shutting down…"
        case .inUseElsewhere: return p.isServer ? "Running · started earlier" : "Running outside the app"
        case .failed: return "Did not start"
        case .stopped:
            return "Stopped · \(p.memoryGB) GB" + (p.isServer ? " · port \(String(p.sshPort))" : "")
        }
    }
    static func color(_ r: Runner) -> Color {
        switch r.state {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .inUseElsewhere: return .yellow
        case .failed: return .red
        case .stopped: return .secondary.opacity(0.5)
        }
    }
    /// Counting seconds: redrawn every second.
    static func counting(_ p: Profile, _ r: Runner) -> Bool { r.isActive && r.readyAt == nil && (r.state == .starting || p.isServer) }
    static func running(_ r: Runner) -> Bool { r.state == .running || r.state == .inUseElsewhere }
}

enum Fmt {
    static func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }
    static func gb(_ bytes: Double) -> String {
        let g = bytes / 1_073_741_824
        return g >= 100 ? String(Int(g.rounded())) : g >= 10 ? String(Int(g.rounded())) : String(format: "%.1f", g)
    }
    /// "1 TB", "512 GB": a disk's size.
    static func size(_ bytes: Double) -> String {
        let g = bytes / 1_000_000_000
        if g < 1 { return bytes < 1_000_000 ? (bytes > 0 ? "<1 MB" : "0 MB") : "\(Int((bytes / 1_000_000).rounded())) MB" }
        return g >= 1000 ? String(format: g >= 10_000 ? "%.0f TB" : "%.1f TB", g / 1000).replacingOccurrences(of: ".0 TB", with: " TB") : "\(Int(g.rounded())) GB"
    }
    static func level(_ f: Double) -> Color { f >= 0.9 ? .red : f >= 0.75 ? .orange : .green }
}

/// A thin bar, as wide as it is given.
struct Meter: View {
    let fraction: Double
    var color: Color
    var height: CGFloat = 5
    var body: some View {
        Capsule().fill(Color.secondary.opacity(0.2))
            .overlay(alignment: .leading) {
                GeometryReader { g in Capsule().fill(color).frame(width: max(height, g.size.width * min(1, max(0, fraction)))) }
            }
            .frame(height: height)
    }
}

/// A line through the last minute's readings (0…1), with "60 s ago" and "Now" under it.
struct Sparkline: View {
    let values: [Double]
    var color: Color
    /// The graph and its captions.
    static let height: CGFloat = 48
    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { g in
                let n = MachineStats.historyLength
                let step = g.size.width / CGFloat(max(1, n - 1))
                let start = CGFloat(n - values.count) * step
                let points = values.enumerated().map { i, v in
                    CGPoint(x: start + CGFloat(i) * step, y: g.size.height - 2 - CGFloat(min(1, max(0, v))) * (g.size.height - 4))
                }
                ZStack {
                    Path { p in p.move(to: CGPoint(x: 0, y: g.size.height - 1)); p.addLine(to: CGPoint(x: g.size.width, y: g.size.height - 1)) }
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    if points.count > 1 {
                        Path { p in p.addLines(points) }.stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    } else if let p0 = points.first {
                        Circle().fill(color).frame(width: 4, height: 4).position(p0)
                    }
                }
            }
            .frame(height: 30)
            HStack { Text("60 s ago"); Spacer(); Text("Now") }.font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(height: Sparkline.height)
    }
}

/// A rounded panel in the window's own colours.
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.09)))
    }
}

/// One number with its title, a caption and something under it (a bar or a graph).
struct StatCard<Below: View>: View {
    let symbol: String
    let title: String
    let value: String
    var unit = ""
    let caption: String
    @ViewBuilder var below: Below
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol).font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                    if !unit.isEmpty { Text(unit).font(.callout).foregroundStyle(.secondary) }
                }
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                below.padding(.top, 4)
            }
        }
    }
}

// ---- the sidebar ----------------------------------------------------------------------------------------------------

/// The Overview's row at the top of the sidebar: the Mac in two numbers.
struct OverviewRow: View {
    @ObservedObject var stats = MachineStats.shared
    /// the machines with readings: the running ones, counted afresh every 3 s
    private var running: Int { stats.stats.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer").frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Overview").fontWeight(.semibold)
                    Text("This Mac · \(running) running").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("CPU \(Fmt.percent(stats.host.cpu))")
                Spacer()
                Text("RAM \(Fmt.gb(stats.host.memUsed)) / \(Fmt.gb(stats.host.memTotal)) GB")
            }
            .font(.caption2.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// A machine in the sidebar: its icon, name and state, and while it runs its CPU, memory and disk.
struct MachineRow: View {
    let profile: Profile
    @ObservedObject var runner: Runner
    @ObservedObject private var stats = MachineStats.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                MachineIconView(kind: profile.kind, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name).fontWeight(.semibold).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(MachineStatus.color(runner)).frame(width: 6, height: 6)
                        if MachineStatus.counting(profile, runner) {
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in status(ctx.date) }
                        } else {
                            status(Date())
                        }
                    }
                }
            }
            if MachineStatus.running(runner), let s = stats.stats[profile.id] {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("CPU \(Fmt.percent(s.cpu))")
                        Spacer()
                        Text("MEM \(Fmt.percent(s.memFraction))")
                    }
                    .font(.caption2.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                    gauge("memorychip", s.memFraction, "\(Fmt.gb(s.memUsed)) / \(Fmt.gb(s.memTotal)) GB")
                        .help(s.memFromGuest ? "Memory in use inside the machine, of what it was given" : "Memory the machine holds on the Mac, of what it was given")
                    gauge("internaldrive", s.diskFraction, "\(Fmt.gb(s.diskFree)) GB free")
                        .help(s.diskFromGuest ? "Free space on the machine's disk, of \(Fmt.gb(s.diskTotal)) GB"
                                              : "The disk is \(Fmt.gb(s.diskTotal)) GB; the Mac holds \(Fmt.gb(s.diskUsed)) GB of it (space freed inside is not counted back)")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func status(_ now: Date) -> some View {
        Text(MachineStatus.text(profile, runner, now: now)).font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
    }

    private func gauge(_ symbol: String, _ f: Double, _ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 12)
            Meter(fraction: f, color: Fmt.level(f), height: 4)
            Text(label).font(.caption2).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).frame(minWidth: 74, alignment: .leading)
        }
    }
}

// ---- the Overview ---------------------------------------------------------------------------------------------------

/// The Mac and every machine at a glance: what the whole Mac is doing, how much memory the machines were given,
/// and a table of the machines. A row opens its machine.
struct OverviewView: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var runs: RunManager
    @ObservedObject private var stats = MachineStats.shared
    let open: (UUID) -> Void

    private var running: [Profile] { store.profiles.filter { MachineStatus.running(runs.runner(for: $0.id)) || runs.runner(for: $0.id).isActive } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "desktopcomputer").font(.title2).foregroundStyle(.blue)
                        .frame(width: 44, height: 44).background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This Mac").font(.title.bold())
                        Text("\(Profile.macMemoryGB) GB memory · \(stats.host.cores) CPU cores").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("Mac activity").font(.headline)
                    Spacer()
                    Text("The whole Mac, machines included").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    let h = stats.host
                    StatCard(symbol: "cpu", title: "CPU", value: "\(Int((h.cpu * 100).rounded()))", unit: "%", caption: "All \(h.cores) cores") {
                        Meter(fraction: h.cpu, color: .blue)
                    }
                    StatCard(symbol: "memorychip", title: "Memory", value: Fmt.gb(h.memUsed), unit: "/ \(Fmt.gb(h.memTotal)) GB", caption: "In use") {
                        Meter(fraction: h.memTotal > 0 ? h.memUsed / h.memTotal : 0, color: .purple)
                    }
                    StatCard(symbol: "internaldrive", title: "Storage", value: Fmt.gb(h.diskFree), unit: "GB free",
                             caption: "\(Fmt.size(h.diskTotal)) disk, where the machines live") {
                        Meter(fraction: h.diskTotal > 0 ? 1 - h.diskFree / h.diskTotal : 0, color: .blue)
                    }
                }
                Card(padding: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
                        if running.isEmpty {
                            Text("No machine is running.").foregroundStyle(.secondary)
                        } else {
                            let given = running.reduce(0) { $0 + $1.memoryGB }
                            Text("**\(given) GB** of memory given to \(running.count) running machine\(running.count == 1 ? "" : "s")")
                                + Text(given > Profile.macMemoryGB - 4 ? " — that leaves little for the Mac itself" : "").foregroundColor(.orange)
                        }
                    }
                    .font(.callout)
                }
                HStack {
                    Text("All machines").font(.headline)
                    Spacer()
                    Text("\(running.count) running · \(store.profiles.count - running.count) stopped").font(.caption).foregroundStyle(.secondary)
                }
                table
                HStack {
                    let inside = store.profiles.compactMap { stats.stats[$0.id] }.reduce(0) { $0 + $1.memUsed }
                    Text(inside > 0 ? "Memory in use inside the machines ≈ \(Fmt.gb(inside)) GB" : " ")
                    Spacer()
                    Text("CPU: each machine's share of the whole Mac")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { VersionAndSettings() } }
    }

    private var table: some View {
        VStack(spacing: 0) {
            row(header: true) {
                Text("Machine")
            } cpu: { Text("CPU") } mem: { Text("Memory used") } disk: { Text("Disk free") }
            Divider()
            ForEach(store.profiles) { p in
                OverviewMachineRow(profile: p, runner: runs.runner(for: p.id), stat: stats.stats[p.id], open: open)
                Divider()
            }
        }
    }

    private func row<A: View, B: View, C: View, D: View>(header: Bool, @ViewBuilder name: () -> A, @ViewBuilder cpu: () -> B,
                                                         @ViewBuilder mem: () -> C, @ViewBuilder disk: () -> D) -> some View {
        HStack {
            name().frame(maxWidth: .infinity, alignment: .leading)
            cpu().frame(width: 80, alignment: .trailing)
            mem().frame(width: 150, alignment: .trailing)
            disk().frame(width: 110, alignment: .trailing)
        }
        .font(header ? .caption : .body).foregroundStyle(header ? .secondary : .primary)
        .padding(.horizontal, 8).padding(.vertical, header ? 6 : 8)
    }
}

private struct OverviewMachineRow: View {
    let profile: Profile
    @ObservedObject var runner: Runner
    let stat: MachineStats.Stat?
    let open: (UUID) -> Void
    @State private var hover = false

    var body: some View {
        Button { open(profile.id) } label: {
            HStack {
                HStack(spacing: 10) {
                    MachineIconView(kind: profile.kind, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.name).lineLimit(1)
                        HStack(spacing: 5) {
                            Circle().fill(MachineStatus.color(runner)).frame(width: 6, height: 6)
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                Text(MachineStatus.text(profile, runner, now: ctx.date)).font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(stat.map { Fmt.percent($0.macCPU) } ?? "—").monospacedDigit().frame(width: 80, alignment: .trailing)
                    .help(stat.map { "\(Fmt.percent($0.cpu)) of its own \($0.vcpus) cores" } ?? "")
                VStack(alignment: .trailing, spacing: 1) {
                    if let s = stat {
                        Text("\(Fmt.gb(s.memUsed)) GB").monospacedDigit()
                        Text("of \(Fmt.gb(s.memTotal)) GB").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Text("—").foregroundStyle(.secondary)
                        Text("\(profile.memoryGB) GB given").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 150, alignment: .trailing)
                Text(stat.map { "\(Fmt.gb($0.diskFree)) GB" } ?? "—").monospacedDigit().frame(width: 110, alignment: .trailing)
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.05) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
