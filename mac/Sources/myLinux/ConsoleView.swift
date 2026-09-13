import SwiftUI

/// The guest's serial console: a root shell inside the running machine. Handy when the desktop is stuck, and it is
/// how Stop asks the guest to power off.
struct ConsoleView: View {
    @ObservedObject var runner: Runner
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Console").font(.headline)
                Circle().fill(runner.consoleConnected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(runner.consoleConnected ? "root shell" : "not connected").foregroundStyle(.secondary).font(.caption)
                Spacer()
                Button("Ctrl-C") { runner.send("\u{03}") }.disabled(!runner.consoleConnected)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(runner.console.isEmpty ? "Waiting for the guest…" : runner.console)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("body")
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: runner.console) { _, _ in withAnimation(.none) { proxy.scrollTo("bottom") } }
            }
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            HStack {
                TextField("Command for the guest, for example: restartshell", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(sendCommand)
                Button("Send", action: sendCommand).disabled(!runner.consoleConnected || command.isEmpty)
            }
            .padding(10)
        }
    }

    private func sendCommand() {
        guard runner.consoleConnected, !command.isEmpty else { return }
        runner.send(command + "\n")
        command = ""
    }
}
