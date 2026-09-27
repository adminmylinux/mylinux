import Foundation

/// The Mac's cloud-storage folders a server can reach inside (Install Script… › Cloud). Each ticked one is one more
/// virtio-9p share of that Mac folder (run-server.sh's EXTRA_SHARES, attached when the machine starts), which the
/// launcher mounts inside at /mnt/<tag> and links as ~/<name>, beside ~/Mac. The Mac's own cloud app keeps syncing it.
enum CloudFolder: String, CaseIterable, Codable, Identifiable {
    case dropbox, onedrive, icloud, googledrive
    var id: String { rawValue }

    var title: String {
        switch self { case .dropbox: return "Dropbox"; case .onedrive: return "OneDrive"; case .icloud: return "iCloud Drive"; case .googledrive: return "Google Drive" }
    }
    /// The link in the home folder inside: ~/Dropbox, ~/OneDrive, ~/iCloud, ~/GoogleDrive.
    var guestName: String {
        switch self { case .dropbox: return "Dropbox"; case .onedrive: return "OneDrive"; case .icloud: return "iCloud"; case .googledrive: return "GoogleDrive" }
    }
    /// The mount point inside, and the 9p mount tag.
    var guestMount: String { "/mnt/\(rawValue)" }

    /// Where it is on this Mac, or nil: File Provider folders in ~/Library/CloudStorage (Dropbox, OneDrive-<org>,
    /// GoogleDrive-<account>), iCloud Drive in ~/Library/Mobile Documents; an older Dropbox's real ~/Dropbox too.
    func macPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let fm = FileManager.default
        let storage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        func isDir(_ url: URL) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue }
        func first(_ prefix: String) -> String? {
            let names = ((try? fm.contentsOfDirectory(atPath: storage.path)) ?? []).sorted()
            return names.first { $0 == prefix || $0.hasPrefix(prefix + "-") }.map { storage.appendingPathComponent($0).path }
        }
        switch self {
        case .dropbox:
            if let p = first("Dropbox") { return p }
            let old = home.appendingPathComponent("Dropbox")
            let isLink = (try? fm.destinationOfSymbolicLink(atPath: old.path)) != nil
            return !isLink && isDir(old) ? old.path : nil
        case .onedrive: return first("OneDrive")
        case .googledrive: return first("GoogleDrive")
        case .icloud:
            let docs = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            return isDir(docs) ? docs.path : first("iCloudDrive")
        }
    }

    /// EXTRA_SHARES for run-server.sh: one "tag=path" line per ticked folder that is on this Mac.
    static func extraShares(_ picked: [String]) -> String {
        CloudFolder.allCases.filter { picked.contains($0.rawValue) }.compactMap { f in f.macPath().map { "\(f.rawValue)=\($0)" } }
            .joined(separator: "\n")
    }

    /// "dropbox:Dropbox onedrive:OneDrive" for the ticked folders, or all of them.
    private static func pairs(_ picked: [String]? = nil) -> String {
        CloudFolder.allCases.filter { picked?.contains($0.rawValue) ?? true }.map { "\($0.rawValue):\($0.guestName)" }.joined(separator: " ")
    }

    /// What the launcher runs in the machine after each start (over its SSH connection, as its user): mount each
    /// ticked folder at /mnt/<tag> through /etc/fstab (so a reboot inside mounts it too) and link it as ~/<name>;
    /// take out the ones no longer ticked. Root through doas (Alpine) or sudo (Debian); a real ~/<name> is left alone.
    /// `root`: the command for root instead (Omarchy's pasted commands: a sudo that may ask for the password).
    static func mountScript(_ picked: [String], root: String? = nil) -> String {
        let want = pairs(picked), all = pairs()
        let r = root.map { "R=; [ \"$(id -u)\" = 0 ] || R=\"\($0)\"" } ?? #"R=; [ "$(id -u)" = 0 ] || { command -v doas >/dev/null && R="doas" || R="sudo -n"; }"#
        return """
        \(r)
        want="\(want)"; changed=
        for pair in \(all); do
          tag=${pair%%:*}; name=${pair#*:}; mp=/mnt/$tag
          case " $want " in
            *" $pair "*)
              $R mkdir -p "$mp"
              grep -q "^$tag $mp " /etc/fstab || { echo "$tag $mp 9p trans=virtio,version=9p2000.L,msize=512000,nofail,_netdev 0 0" | $R tee -a /etc/fstab >/dev/null; changed=1; }
              mountpoint -q "$mp" || $R mount "$mp" 2>/dev/null || echo "myLinux: could not mount $tag (restart the machine to attach it)"
              if [ ! -e "$HOME/$name" ] || [ -L "$HOME/$name" ]; then ln -sfn "$mp" "$HOME/$name"; fi
              ! mountpoint -q "$mp" || echo "myLinux: ~/$name is ready" ;;
            *)
              if grep -q "^$tag $mp " /etc/fstab; then
                ! mountpoint -q "$mp" || $R umount "$mp"
                $R sed -i "\\#^$tag $mp #d" /etc/fstab; changed=1
              fi
              [ "$(readlink "$HOME/$name" 2>/dev/null)" != "$mp" ] || rm -f "$HOME/$name" ;;
          esac
        done
        # systemd reads fstab into mount units: tell it about the change (no "fstab has been modified" hint)
        [ -z "${changed:-}" ] || ! command -v systemctl >/dev/null || $R systemctl daemon-reload 2>/dev/null || true
        """
    }

    /// Omarchy: the commands to paste once into a terminal inside (the launcher has no way in as root). The fstab
    /// lines they write mount the folders at every start from then on.
    static func pasteScript(_ picked: [String]) -> String {
        "# myLinux: the Mac's cloud folders in your home folder (sudo asks for your password)\n" + mountScript(picked, root: "sudo")
    }

    /// myLinux: what the launcher types into the machine's root console at every start (its root filesystem lives in
    /// RAM, so nothing like fstab lasts): once the apps disk's home is bound over /root, mount each ticked folder at
    /// /mnt/<tag>, bind it into the apps chroot, link it as ~/<name>; take out links to folders no longer ticked.
    /// One line, in the background, so the console is free again at once.
    static func consoleScript(_ picked: [String]) -> String {
        let want = pairs(picked), all = pairs()
        return #" ( i=0; while ! mountpoint -q /root && [ $i -lt 90 ]; do sleep 1; i=$((i+1)); done; want=""# + want + #""; for pair in "# + all + #"; do tag=${pair%%:*}; name=${pair#*:}; mp=/mnt/$tag; case " $want " in *" $pair "*) mkdir -p $mp; mountpoint -q $mp || mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000 $tag $mp || continue; if mountpoint -q /mnt/apps; then mkdir -p /mnt/apps$mp; mountpoint -q /mnt/apps$mp || mount --bind $mp /mnt/apps$mp; fi; if [ ! -e /root/$name ] || [ -L /root/$name ]; then ln -sfn $mp /root/$name; fi ;; *) [ "$(readlink /root/$name 2>/dev/null)" != "$mp" ] || rm -f /root/$name ;; esac; done ) >/dev/null 2>&1 &"#
    }
}
