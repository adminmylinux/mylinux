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

    /// What the launcher runs in the machine after each start (over its SSH connection, as its user): mount each
    /// ticked folder at /mnt/<tag> through /etc/fstab (so a reboot inside mounts it too) and link it as ~/<name>;
    /// take out the ones no longer ticked. Root through doas (Alpine) or sudo (Debian); a real ~/<name> is left alone.
    static func mountScript(_ picked: [String]) -> String {
        let want = CloudFolder.allCases.filter { picked.contains($0.rawValue) }.map { "\($0.rawValue):\($0.guestName)" }.joined(separator: " ")
        let all = CloudFolder.allCases.map { "\($0.rawValue):\($0.guestName)" }.joined(separator: " ")
        return """
        R=; [ "$(id -u)" = 0 ] || { command -v doas >/dev/null && R="doas" || R="sudo -n"; }
        want="\(want)"
        for pair in \(all); do
          tag=${pair%%:*}; name=${pair#*:}; mp=/mnt/$tag
          case " $want " in
            *" $pair "*)
              $R mkdir -p "$mp"
              grep -q "^$tag $mp " /etc/fstab || echo "$tag $mp 9p trans=virtio,version=9p2000.L,msize=512000,nofail,_netdev 0 0" | $R tee -a /etc/fstab >/dev/null
              mountpoint -q "$mp" || $R mount "$mp" || echo "myLinux: could not mount $tag (restart the machine to attach it)"
              if [ ! -e "$HOME/$name" ] || [ -L "$HOME/$name" ]; then ln -sfn "$mp" "$HOME/$name"; fi ;;
            *)
              if grep -q "^$tag $mp " /etc/fstab; then
                ! mountpoint -q "$mp" || $R umount "$mp"
                $R sed -i "\\#^$tag $mp #d" /etc/fstab
              fi
              [ "$(readlink "$HOME/$name" 2>/dev/null)" != "$mp" ] || rm -f "$HOME/$name" ;;
          esac
        done
        """
    }
}
