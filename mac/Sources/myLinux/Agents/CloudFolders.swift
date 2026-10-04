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

    /// EXTRA_SHARES for run-server.sh: one "tag=path" line per ticked folder that is on this Mac, and per Mac folder.
    static func extraShares(_ picked: [String], mac: [MacFolder] = []) -> String {
        (CloudFolder.allCases.filter { picked.contains($0.rawValue) }.compactMap { f in f.macPath().map { "\(f.rawValue)=\($0)" } }
         + mac.map { "\($0.tag)=\($0.path)" })
            .joined(separator: "\n")
    }

    /// "dropbox:Dropbox onedrive:OneDrive mac-projects:Projects" for the ticked folders and the Mac folders, or all
    /// the cloud ones and the Mac folders.
    private static func pairs(_ picked: [String]? = nil, mac: [MacFolder]) -> String {
        (CloudFolder.allCases.filter { picked?.contains($0.rawValue) ?? true }.map { "\($0.rawValue):\($0.guestName)" }
         + mac.map { "\($0.tag):\($0.name)" }).joined(separator: " ")
    }

    /// What the launcher runs in the machine after each start (over its SSH connection, as its user): mount each
    /// ticked folder at /mnt/<tag> through /etc/fstab (so a reboot inside mounts it too) and link it as ~/<name>;
    /// take out the ones no longer ticked. Root through doas (Alpine) or sudo (Debian); a real ~/<name> is left alone.
    /// `root`: the command for root instead (Omarchy's pasted commands: a sudo that may ask for the password).
    static func mountScript(_ picked: [String], mac: [MacFolder] = [], root: String? = nil) -> String {
        let want = pairs(picked, mac: mac), all = pairs(mac: mac)
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
        # Mac folders taken away (their tags are mac-<name>): the fstab line, the mount and the link go
        for tag in $(awk '$1 ~ /^mac-/ { print $1 }' /etc/fstab 2>/dev/null); do
          case " $want " in *" $tag:"*) continue ;; esac
          mp=/mnt/$tag
          ! mountpoint -q "$mp" || $R umount "$mp"
          $R sed -i "\\#^$tag $mp #d" /etc/fstab; changed=1
          for l in "$HOME"/*; do [ -L "$l" ] && [ "$(readlink "$l")" = "$mp" ] && rm -f "$l"; done
        done
        # systemd reads fstab into mount units: tell it about the change (no "fstab has been modified" hint)
        [ -z "${changed:-}" ] || ! command -v systemctl >/dev/null || $R systemctl daemon-reload 2>/dev/null || true
        """
    }

    /// Omarchy: the commands to paste once into a terminal inside (the launcher has no way in as root). The fstab
    /// lines they write mount the folders at every start from then on.
    static func pasteScript(_ picked: [String], mac: [MacFolder] = []) -> String {
        "# myLinux: the Mac's cloud folders and Mac folders in your home folder (sudo asks for your password)\n" + mountScript(picked, mac: mac, root: "sudo")
    }

    /// myLinux: what the launcher types into the machine's root console at every start (its root filesystem lives in
    /// RAM, so nothing like fstab lasts): once the apps disk's home is bound over /root, mount each ticked folder at
    /// /mnt/<tag>, bind it into the apps chroot, link it as ~/<name>; take out links to folders no longer ticked.
    /// One line, in the background, so the console is free again at once.
    static func consoleScript(_ picked: [String], mac: [MacFolder] = []) -> String {
        let want = pairs(picked, mac: mac), all = pairs(mac: mac)
        return #" ( i=0; while ! mountpoint -q /root && [ $i -lt 90 ]; do sleep 1; i=$((i+1)); done; want=""# + want + #""; for pair in "# + all + #"; do tag=${pair%%:*}; name=${pair#*:}; mp=/mnt/$tag; case " $want " in *" $pair "*) mkdir -p $mp; mountpoint -q $mp || mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000 $tag $mp || continue; if mountpoint -q /mnt/apps; then mkdir -p /mnt/apps$mp; mountpoint -q /mnt/apps$mp || mount --bind $mp /mnt/apps$mp; fi; if [ ! -e /root/$name ] || [ -L /root/$name ]; then ln -sfn $mp /root/$name; fi ;; *) [ "$(readlink /root/$name 2>/dev/null)" != "$mp" ] || rm -f /root/$name ;; esac; done; for l in /root/*; do t=$(readlink $l 2>/dev/null); case $t in /mnt/mac-*) case " $want " in *" ${t#/mnt/}:"*) ;; *) rm -f $l ;; esac ;; esac; done ) >/dev/null 2>&1 &"#
    }
}

/// A Mac folder of the user's own choosing (Cloud Folders › Mac folders › Add Folder…), shared into the machine like a
/// cloud folder: 9p tag mac-<name>, mounted at /mnt/mac-<name> and linked as ~/<name> inside.
struct MacFolder: Codable, Hashable, Identifiable {
    var name: String            // ~/<name> inside
    var path: String            // the folder on this Mac
    var id: String { tag }
    var tag: String { "mac-" + Paths.slug(name) }

    /// What is wrong with sharing `path` as ~/`name` beside `others`, in words; nil when it is fine. The same folders
    /// tools/extra-shares.sh refuses: the whole disk or home, system folders, the Library.
    static func problem(name: String, path: String, others: [MacFolder], home: String = NSHomeDirectory()) -> String? {
        if name.isEmpty || name.hasPrefix(".") || name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) == nil {
            return "The name inside is one word: letters, digits, . _ -"
        }
        if MacFolder(name: name, path: path).tag.count > 31 { return "The name inside is at most 27 characters (QEMU's share tags are short)." }
        let taken = CloudFolder.allCases.map(\.guestName) + ["Mac"]
        if taken.contains(where: { $0.lowercased() == name.lowercased() }) { return "~/\(name) is taken (a cloud folder or the Mac share)." }
        if others.contains(where: { $0.tag == MacFolder(name: name, path: path).tag }) { return "There is a Mac folder called \(name) already." }
        if others.contains(where: { $0.path == path }) { return "That folder is shared already." }
        if path.contains(",") { return "The folder's path must not contain a comma." }
        let refused = ["/", "/Users", "/private", "/tmp", "/private/tmp", "/System", "/Library", "/Applications", "/Volumes", home, home + "/Library"]
        if refused.contains(path) || path.hasPrefix(home + "/Library/") && !path.hasPrefix(home + "/Library/CloudStorage/") && !path.hasPrefix(home + "/Library/Mobile Documents/") {
            return "Not that one: the whole disk, your home folder, system folders and the Library stay on the Mac. Pick a folder inside them."
        }
        return nil
    }

    /// A name for inside from the folder's own: "My Projects" → MyProjects.
    static func suggestedName(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        let words = last.split(whereSeparator: { !$0.isLetter && !$0.isNumber && !"._-".contains($0) })
        let ascii = words.map { String($0.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }) }.filter { !$0.isEmpty }
        let joined = ascii.count > 1 ? ascii.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined() : (ascii.first ?? "")
        return String(joined.prefix(30)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
