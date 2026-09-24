import SwiftUI

/// The first thing a new install shows: what the launcher runs and that myLinux itself is a download away. The
/// download runs right here; the other kinds of machine fetch what they need from their own pages.
struct WelcomeSheet: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var images: ImageManager
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to myLinux").font(.title2.bold())
                    Text("Linux machines on this Mac, each with its own disk.").foregroundStyle(.secondary)
                }
            }
            Text("The launcher brought its own QEMU. What it does not carry is the operating system: **myLinux** is a 110 MB download, once, and every myLinux machine boots from it. Omarchy (1.4 GB) and Debian Server (300 MB) download from their own machine pages when you add one.")
                .fixedSize(horizontal: false, vertical: true)
            if images.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(images.progress.isEmpty ? "Downloading…" : images.progress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Cancel") { images.cancel() }
                }
            } else if images.present {
                Banner(text: "myLinux is downloaded. Select the machine and press Start.", kind: .info)
            }
            if let e = images.lastError { Banner(text: e, kind: .error) }
            HStack {
                Spacer()
                if images.present {
                    Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
                } else {
                    Button("Later", action: dismiss).keyboardShortcut(.cancelAction).disabled(images.busy)
                    Button("Download myLinux") { images.download(settings) }.keyboardShortcut(.defaultAction).disabled(images.busy)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
