import Carbon.HIToolbox
import SwiftUI

struct MenuView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ShotKeys").font(.headline)
                Spacer()
                Toggle("Enabled", isOn: $state.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if !state.hasPermission {
                permissionWarning
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Volume")
                    Spacer()
                    Text("\(Int((state.volume * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $state.volume, in: 0...1)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Pitch variation")
                    Spacer()
                    Text("±\(Int((state.pitchVariation * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $state.pitchVariation, in: 0...AppState.maxPitchVariation)
            }

            Toggle("Play on key repeat", isOn: $state.playOnRepeat)

            Divider()

            HStack(spacing: 6) {
                Text("Test").font(.caption).foregroundStyle(.secondary)
                Spacer()
                ForEach([SoundGroup.shot, .space, .reload, .backspace], id: \.self) { group in
                    Button(group.rawValue.capitalized) {
                        state.engine.trigger(group, isRepeat: false, eventTimestamp: 0)
                    }
                    .controlSize(.small)
                }
            }

            DiagnosticsView(state: state)

            Divider()

            Button("Quit ShotKeys") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { state.refreshPermission() }
    }

    private var permissionWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Input Monitoring permission needed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline.weight(.semibold))
            Text("macOS requires Input Monitoring access for ShotKeys to hear key presses. It only sees which key was pressed, never what you type. Sound starts as soon as you allow it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Input Monitoring Settings…") { state.openInputMonitoringSettings() }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}

/// Live debug info. Only refreshes while the menu is open.
private struct DiagnosticsView: View {
    let state: AppState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let stats = state.engine.stats.snapshot()
            VStack(alignment: .leading, spacing: 3) {
                row("Permission", state.hasPermission ? "Granted" : "Missing")
                row("Key presses this session", "\(state.tap.keyDownCount)")
                row("Shots played", "\(stats.shots)")
                row("Keys muted by reload", "\(stats.suppressedByReload)")
                row("Latency (event → scheduled)", latencyText(stats))
                row("Audio output latency", String(format: "%.1f ms", stats.outputLatencyMs))
                row("Audio engine", stats.engineRunning ? "Running" : "Sleeping (wakes on next key)")
                if IsSecureEventInputEnabled() {
                    Text("Secure Input is on (e.g. a password field), so macOS hides key presses. ShotKeys stays silent.")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
        }
    }

    private func latencyText(_ stats: LatencyStats.Snapshot) -> String {
        guard let p50 = stats.softwareP50Ms, let p95 = stats.softwareP95Ms else { return "—" }
        return String(format: "%.1f / %.1f ms (p50/p95)", p50, p95)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}
