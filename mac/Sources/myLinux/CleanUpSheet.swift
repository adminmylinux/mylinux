import SwiftUI
import AppKit

/// Clean Up Disk (the sidebar's button): the machines and the downloaded Linuxes with the space each takes, ticked for
/// removal. A machine goes to the Trash (its disk holds the user's work), as Remove does. A Linux is deleted with its
/// saved download (tools/download-cache.sh: the two share their blocks, so either alone frees nothing) and downloads
/// again when a new machine needs it. A machine that has started once has its own disk and boot files and keeps
/// working without its Linux, but for what it reads at every start: a myLinux machine the whole image, Debian's and
/// Alpine's the firmware, Windows's the firmware, the drivers (the tools disc), and the ISO until Windows is installed.
enum DiskCleanup {
    /// `bytes` is everything that goes with it: its disk, its boot files, and its share folder when that is inside its folder.
    struct Machine: Identifiable { let profile: Profile; let bytes: Double; let disk: Double; let share: Double; var id: UUID { profile.id } }
    struct Image: Identifiable {
        let kind: Profile.Kind
        let revision: String?
        /// Only the saved download is there (the installed one went, or was never installed in this launcher).
        let savedOnly: Bool
        /// The installed copy and the saved one, counted once where they are the same revision (clones).
        let bytes: Double
        /// What stays while machines of this kind are kept (stillNeeded).
        let keepBytes: Double
        var id: String { kind.rawValue }
    }
    struct Usage { var machines: [Machine]; var images: [Image]; var other: Double; var free: Double? }

    static let kinds: [Profile.Kind] = [.mylinux, .omarchy, .arch, .kali, .fedora, .rocky, .centos, .windows, .debian, .alpine, .tiny]
    /// The myLinux image is files in the out folder itself (tools/get-image.sh keeps the previous pair as *.prev).
    static let mylinuxFiles = ["Image", "rootfs.cpio.gz", "SHA256SUMS", "IMAGE-REVISION", "Image.prev", "rootfs.cpio.gz.prev"]

    /// What a kept machine of this kind still reads from its Linux at every start (run-server.sh, run-windows.sh).
    static func stillNeeded(_ kind: Profile.Kind) -> Set<String> {
        switch kind {
        case .debian, .alpine: return ["edk2-aarch64-code.fd", "edk2-licenses.txt"]
        case .windows: return ["edk2-aarch64-code.fd", "edk2-licenses.txt", "drivers", "WINDOWS-REVISION"]
        default: return []
        }
    }
    static func revisionFile(_ kind: Profile.Kind) -> String { kind == .mylinux ? "IMAGE-REVISION" : "\(kind.rawValue.uppercased())-REVISION" }
    static func folder(_ kind: Profile.Kind, out: URL) -> URL { kind == .mylinux ? out : out.appendingPathComponent(kind.rawValue, isDirectory: true) }
    /// The saved download (none for Windows: the ISO is the user's own file).
    static func saved(_ kind: Profile.Kind, cache: URL = Paths.downloadCache) -> URL? {
        kind == .windows ? nil : cache.appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    /// The machine has its own disk (and what its first start put beside it), so it starts without its Linux.
    static func hasOwnDisk(_ p: Profile) -> Bool {
        if p.kind.runsDesktop { return p.desktopCreated }
        return p.isServer && FileManager.default.fileExists(atPath: p.appsDisk)
            && FileManager.default.fileExists(atPath: p.machineFolder.appendingPathComponent(p.kind.firstStartFile).path)
    }

    /// Why this Linux cannot be removed while these machines stay, or nil.
    static func blocker(_ image: Image, kept: [Profile], running: (Profile) -> Bool, downloading: Bool) -> String? {
        if downloading { return "Downloading now" }
        let mine = kept.filter { $0.kind == image.kind }
        if image.kind == .mylinux, !mine.isEmpty { return "\(names(mine)) start\(mine.count == 1 ? "s" : "") from it every time" }
        if let p = mine.first(where: { $0.kind == .windows && !$0.windowsInstalled }) { return "“\(p.name)” is still installing Windows from it" }
        if let p = mine.first(where: { running($0) && !hasOwnDisk($0) }) { return "“\(p.name)” is making its disk from it" }
        if !mine.isEmpty, image.bytes - image.keepBytes < 1_000_000 { return "Only the firmware \(names(mine)) start\(mine.count == 1 ? "s" : "") with is left" }
        return nil
    }

    /// What removing it means for the machines that stay.
    static func note(_ image: Image, kept: [Profile]) -> String {
        let mine = kept.filter { $0.kind == image.kind }
        let new = mine.filter { !hasOwnDisk($0) }
        if !new.isEmpty { return "\(names(new)) \(new.count == 1 ? "has" : "have") not started yet: it downloads \(image.kind.title) again" }
        if mine.isEmpty { return image.savedOnly ? "Saved for new machines; no machine uses it" : "No machine uses it" }
        let firmware = stillNeeded(image.kind).isEmpty ? "" : " (the firmware they start with stays)"
        return "\(names(mine)) \(mine.count == 1 ? "has its" : "have their") own disk and keep\(mine.count == 1 ? "s" : "") working\(firmware)"
    }

    private static func names(_ ps: [Profile]) -> String {
        ps.count <= 2 ? ps.map { "“\($0.name)”" }.joined(separator: " and ") : "“\(ps[0].name)” and \(ps.count - 1) more"
    }

    /// Deletes a Linux and its saved download, but for what kept machines of its kind still read (stillNeeded).
    /// Returns what could not be deleted, in words, or nil.
    static func removeImage(_ kind: Profile.Kind, out: URL, cache: URL = Paths.downloadCache, keepForMachines: Bool) -> String? {
        let fm = FileManager.default
        let dir = folder(kind, out: out)
        let keep = keepForMachines ? stillNeeded(kind) : []
        var urls: [URL]
        if kind == .mylinux { urls = mylinuxFiles.map { out.appendingPathComponent($0) } }
        else if keep.isEmpty { urls = [dir, out.appendingPathComponent("\(kind.rawValue).prev", isDirectory: true)] }
        else { urls = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { !keep.contains($0.lastPathComponent) } }
        if let s = saved(kind, cache: cache) { urls.append(s) }
        var failed: [String] = []
        for u in urls where fm.fileExists(atPath: u.path) {
            do { try fm.removeItem(at: u) } catch { failed.append("\(u.path): \(error.localizedDescription)") }
        }
        return failed.isEmpty ? nil : failed.joined(separator: "\n")
    }

    /// The download (or update) of this Linux, which is busy while one runs and refreshes the pages that show it.
    static func loader(_ kind: Profile.Kind) -> ScriptDownloader {
        kind == .mylinux ? ImageManager.shared : kind.isServer ? ServerImageManager.shared(kind) : DesktopImageManager.shared(kind)
    }
    static func refresh(_ kind: Profile.Kind, _ settings: AppSettings) {
        if kind == .mylinux { ImageManager.shared.refresh(settings) }
        else if kind.isServer { ServerImageManager.shared(kind).refresh(settings) }
        else { DesktopImageManager.shared(kind).refresh(settings) }
    }

    /// Measured off the main thread (allocated blocks: a sparse disk counts what it holds).
    static func measure(_ profiles: [Profile], settings: AppSettings) async -> Usage {
        let out = settings.outDir, dev = settings.developerMode, support = Paths.support, cache = Paths.downloadCache
        return await Task.detached(priority: .utility) {
            let machines = profiles.map { p in
                let folder = p.machineFolder
                let inside = folder.path.hasPrefix(support.path + "/")
                let disk = StorageUsage.allocated(URL(fileURLWithPath: p.appsDisk))
                let own = inside ? StorageUsage.allocated(folder) : disk
                let share = inside && !p.shareDir.isEmpty && p.shareDir.hasPrefix(folder.path + "/") ? StorageUsage.allocated(URL(fileURLWithPath: p.shareDir)) : 0
                return Machine(profile: p, bytes: own + StorageUsage.allocated(out.appendingPathComponent("machines/\(p.id.uuidString.lowercased())")),
                               disk: disk, share: share)
            }
            // a checkout's out/ is the developer's: not measured, never removed here
            let images = dev ? [] : kinds.compactMap { image($0, out: out, cache: cache) }
            let other = (dev ? 0 : StorageUsage.allocated(out.appendingPathComponent("qemu-runtime"))) + StorageUsage.allocated(Paths.logs)
            let free = (try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage.map(Double.init)
            return Usage(machines: machines.sorted { $0.bytes > $1.bytes }, images: images.sorted { $0.bytes > $1.bytes }, other: other, free: free)
        }.value
    }

    static func image(_ kind: Profile.Kind, out: URL, cache: URL) -> Image? {
        let dir = folder(kind, out: out)
        let installed = kind == .mylinux ? mylinuxFiles.reduce(0) { $0 + StorageUsage.allocated(out.appendingPathComponent($1)) } : StorageUsage.allocated(dir)
        let savedDir = saved(kind, cache: cache)
        let savedBytes = savedDir.map(StorageUsage.allocated) ?? 0
        guard installed + savedBytes > 0 else { return nil }
        func read(_ u: URL) -> String? {
            (try? String(contentsOf: u, encoding: .utf8)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let rev = read(dir.appendingPathComponent(revisionFile(kind)))
        let savedRev = savedDir.flatMap { read($0.appendingPathComponent(revisionFile(kind))) }
        // a saved download of the installed revision is a clone of it (tools/download-cache.sh): the blocks are counted once
        let shared = rev != nil && rev == savedRev ? min(installed, savedBytes) : 0
        let keep = stillNeeded(kind).reduce(0) { $0 + StorageUsage.allocated(dir.appendingPathComponent($1)) }
        return Image(kind: kind, revision: kind == .windows ? read(dir.appendingPathComponent("WINDOWS-ISO")) : rev ?? savedRev,
                     savedOnly: installed == 0, bytes: installed + savedBytes - shared, keepBytes: keep)
    }
}

struct CleanUpSheet: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var usage: DiskCleanup.Usage?
    @State private var machines: Set<UUID> = []
    @State private var images: Set<Profile.Kind> = []
    @State private var done: String?
    @State private var problem: String?
    /// The question before anything goes (a SwiftUI alert, as Settings › Storage asks).
    @State private var confirming = false

    private func running(_ p: Profile) -> Bool {
        let r = RunManager.shared.runner(for: p.id)
        return r.isActive || r.state == .inUseElsewhere
    }
    private var kept: [Profile] { store.profiles.filter { !machines.contains($0.id) } }
    private func blocker(_ i: DiskCleanup.Image) -> String? {
        DiskCleanup.blocker(i, kept: kept, running: running, downloading: DiskCleanup.loader(i.kind).busy)
    }
    /// What removing it frees now: all of it, or all but what kept machines of its kind still read.
    private func freed(_ i: DiskCleanup.Image) -> Double { kept.contains { $0.kind == i.kind } ? i.bytes - i.keepBytes : i.bytes }
    private var chosenMachines: [DiskCleanup.Machine] { usage?.machines.filter { machines.contains($0.id) && !running($0.profile) } ?? [] }
    private var chosenImages: [DiskCleanup.Image] { usage?.images.filter { images.contains($0.kind) && blocker($0) == nil } ?? [] }
    private var chosenBytes: Double { chosenMachines.reduce(0) { $0 + $1.bytes } + chosenImages.reduce(0) { $0 + freed($1) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clean Up Disk").font(.title2.bold())
                Text(summary).foregroundStyle(.secondary)
            }
            if let usage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        section("Machines") {
                            if usage.machines.isEmpty { empty("No machines") }
                            ForEach(usage.machines) { m in
                                let on = running(m.profile)
                                row(tick($machines, m.id), kind: m.profile.kind, title: m.profile.name,
                                    caption: caption(m, running: on),
                                    bytes: m.bytes, disabled: on)
                            }
                        }
                        section("Downloaded Linuxes") {
                            if settings.developerMode { empty("They come from the checkout's out/ folder, which is not changed here.") }
                            else if usage.images.isEmpty { empty("Nothing downloaded") }
                            ForEach(usage.images) { i in
                                let why = blocker(i)
                                row(tick($images, i.kind), kind: i.kind, title: i.kind.title,
                                    caption: [i.revision, why ?? DiskCleanup.note(i, kept: kept)].compactMap { $0 }.joined(separator: " · "),
                                    bytes: freed(i), disabled: why != nil)
                            }
                        }
                    }
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Measuring…").foregroundStyle(.secondary) }
                Spacer()
            }
            Text("Tick what to remove; the rest stays. A machine goes to the Trash with its disk: the space comes back when you empty the Trash. A downloaded Linux is deleted now, with its saved copy, and downloads again when a new machine needs it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let done { Banner(text: done, kind: .info) }
            if let problem { Banner(text: problem, kind: .error) }
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.support]) }
                Spacer()
                if chosenBytes > 0 { Text("\(size(chosenBytes)) chosen").monospacedDigit().foregroundStyle(.secondary) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Remove…", role: .destructive) { confirming = true }
                    .disabled(chosenMachines.isEmpty && chosenImages.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600, height: 640)
        .task { usage = await DiskCleanup.measure(store.profiles, settings: settings) }
        .alert(question, isPresented: $confirming) {
            Button("Remove", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(consequences)
        }
    }

    private var question: String {
        "Remove " + (chosenMachines.map { "“\($0.profile.name)”" } + chosenImages.map { $0.kind.title }).joined(separator: ", ") + "?"
    }
    private var consequences: String {
        let ms = chosenMachines, ims = chosenImages
        return [
            ms.isEmpty ? nil : "\(ms.count == 1 ? "The machine goes" : "The machines go") to the Trash with everything inside (\(size(ms.reduce(0) { $0 + $1.bytes }))); the space comes back when you empty the Trash.",
            ims.isEmpty ? nil : "\(ims.count == 1 ? "The Linux is" : "The Linuxes are") deleted now (\(size(ims.reduce(0) { $0 + freed($1) }))) and downloaded again when a new machine needs \(ims.count == 1 ? "it" : "one").",
        ].compactMap { $0 }.joined(separator: "\n\n")
    }

    private var summary: String {
        guard let u = usage else { return "Measuring what myLinux keeps on this Mac…" }
        let total = u.machines.reduce(0) { $0 + $1.bytes } + u.images.reduce(0) { $0 + $1.bytes } + u.other
        return "myLinux takes \(size(total)) on this Mac" + (u.free.map { " · \(Fmt.gb($0)) GB free" } ?? "")
            + (settings.developerMode ? " (not counting the checkout's out/ folder)" : "")
    }

    /// Its kind, then what its size is made of (the disk, and the share folder, which goes with it), or why it stays.
    private func caption(_ m: DiskCleanup.Machine, running on: Bool) -> String {
        guard FileManager.default.fileExists(atPath: m.profile.appsDisk) else { return m.profile.kind.title + " · not started yet" }
        return [m.profile.kind.title, "disk \(size(m.disk))", m.share >= 1_000_000 ? "share folder \(size(m.share))" : nil,
                on ? "running: shut it down to remove it" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// "1.4 GB", "472 MB": with the decimal a choice between them needs, in the Overview's binary units.
    private func size(_ bytes: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory) }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.09)))
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }

    private func row(_ on: Binding<Bool>, kind: Profile.Kind, title: String, caption: String, bytes: Double, disabled: Bool) -> some View {
        HStack(spacing: 10) {
            Toggle(title, isOn: on).toggleStyle(.checkbox).labelsHidden().disabled(disabled)
            MachineIconView(kind: kind, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text(bytes > 0 ? size(bytes) : "—").monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .opacity(disabled ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !disabled { on.wrappedValue.toggle() } }
    }

    private func tick<T: Hashable>(_ set: Binding<Set<T>>, _ item: T) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(item) }, set: { if $0 { set.wrappedValue.insert(item) } else { set.wrappedValue.remove(item) } })
    }

    private func remove() {
        let ms = chosenMachines, ims = chosenImages
        guard !ms.isEmpty || !ims.isEmpty else { return }
        let mb = ms.reduce(0) { $0 + $1.bytes }, ib = ims.reduce(0) { $0 + freed($1) }
        var problems: [String] = []
        let keptAfter = kept
        for m in ms { if let e = store.remove(m.id, trashFiles: true) { problems.append(e) } }
        for i in ims {
            if let e = DiskCleanup.removeImage(i.kind, out: settings.outDir, keepForMachines: keptAfter.contains { $0.kind == i.kind }) { problems.append(e) }
            DiskCleanup.refresh(i.kind, settings)
        }
        done = [
            ms.isEmpty ? nil : "Moved \(ms.count) machine\(ms.count == 1 ? "" : "s") to the Trash (\(size(mb)), back when you empty it).",
            ims.isEmpty ? nil : "Deleted \(ims.map(\.kind.title).joined(separator: ", ")) (\(size(ib)) freed).",
        ].compactMap { $0 }.joined(separator: " ")
        problem = problems.isEmpty ? nil : "Some files are still there:\n" + problems.joined(separator: "\n")
        machines = []; images = []; usage = nil
        Task { usage = await DiskCleanup.measure(store.profiles, settings: settings) }
    }
}
