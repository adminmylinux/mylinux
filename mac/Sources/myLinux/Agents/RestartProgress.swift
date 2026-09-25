import SwiftUI

/// What a restart for new cloud folders shows over the terminal window, step by step, each timed in seconds as it
/// happens: shutting down, starting, connecting the folders, then "Ready in 17 s". It closes on its own a few seconds
/// after the machine is ready (the terminal reconnects behind it).
struct RestartProgressView: View {
    @ObservedObject var runner: Runner
    let machine: String
    /// "Dropbox", "Dropbox and OneDrive", or nil when the change only took folders away.
    let folders: String?
    let close: () -> Void
    @State private var closing = false

    private enum Phase { case waiting, running(since: Date), done(took: TimeInterval) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(folders.map { "Connecting \($0)" } ?? "Updating cloud folders").font(.title2.bold())
                    Text("A shared folder is attached when \(machine) starts, so it restarts now. Your terminals reconnect on their own.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 12) {
                    step("Shutting down \(machine)", phase(from: runner.restartBeganAt, to: runner.stoppedAt), now: ctx.date)
                    step("Starting \(machine)", phase(from: runner.stoppedAt, to: runner.sshAnsweredAt), now: ctx.date)
                    step(folders.map { "Connecting \($0)" } ?? "Removing the folders", phase(from: runner.sshAnsweredAt, to: runner.readyAt), now: ctx.date)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
                HStack {
                    if case .failed(let why) = runner.state {
                        Banner(text: why, kind: .error)
                    } else if let began = runner.restartBeganAt, let ready = runner.readyAt, ready > began {
                        Label("Ready in \(Runner.seconds(ready.timeIntervalSince(began)))", systemImage: "bolt.fill")
                            .font(.title3.weight(.semibold)).monospacedDigit()
                    } else if let began = runner.restartBeganAt {
                        Text(Runner.seconds(ctx.date.timeIntervalSince(began))).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(isReady ? "Done" : "Hide", action: close).keyboardShortcut(isReady ? .defaultAction : .cancelAction)
                }
            }
            .padding(20)
            .frame(width: 460)
        }
        .onChange(of: runner.readyAt) { _, ready in
            // leave "Ready in …" up long enough to read, then out of the way
            guard ready != nil, !closing else { return }
            closing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { close() }
        }
    }

    private var isReady: Bool {
        guard let began = runner.restartBeganAt, let ready = runner.readyAt else { return false }
        return ready > began
    }

    /// A step runs from its start mark to its end mark; before the start it waits.
    private func phase(from start: Date?, to end: Date?) -> Phase {
        guard let start, let began = runner.restartBeganAt, start >= began else { return .waiting }
        if let end, end >= start { return .done(took: end.timeIntervalSince(start)) }
        return .running(since: start)
    }

    private func step(_ title: String, _ phase: Phase, now: Date) -> some View {
        HStack(spacing: 10) {
            Group {
                switch phase {
                case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
                case .running: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .frame(width: 18)
            Text(title).foregroundStyle({ if case .waiting = phase { return Color.secondary } else { return Color.primary } }())
            Spacer()
            switch phase {
            case .waiting: EmptyView()
            case .running(let since): Text(Runner.seconds(now.timeIntervalSince(since))).monospacedDigit().foregroundStyle(.secondary)
            case .done(let took): Text(Runner.seconds(took)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}
