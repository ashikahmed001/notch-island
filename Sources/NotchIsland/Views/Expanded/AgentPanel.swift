import SwiftUI

/// Agents tab: what Claude Code / Copilot is doing right now, step by step.
struct AgentPanel: View {
    @ObservedObject var vm: IslandViewModel
    @ObservedObject var api: IslandAPIService

    var body: some View {
        if let session = api.agentSessions.first {
            let tint = IslandAPIService.swiftUIColor(session.tint)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        AgentIcon(session: session, size: 18)
                        Text(session.displayName)
                            .font(.system(size: 14, weight: .bold))
                        Circle().fill(tint).frame(width: 5, height: 5)
                        Text(session.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        // No summary card (with its own Open) yet: offer Open up here.
                        if session.hostBundleID != nil, (session.summary ?? session.message) == nil {
                            Button { vm.openAgent(session) } label: {
                                Label("Open", systemImage: "arrow.up.forward.app")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.white)
                                    .padding(.horizontal, 9)
                                    .frame(height: 22)
                                    .glassBackground(Capsule(), fallback: Color.white.opacity(0.12))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        if api.agentSessions.count > 1 {
                            Text("+\(api.agentSessions.count - 1)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .help("Other recent agent sessions")
                        }
                    }

                    if session.steps.isEmpty && session.state == .working {
                        Text("Starting…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.steps.suffix(session.current == nil ? 4 : 3)) { step in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(tint)
                                .frame(width: 12)
                            Text(step.text)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if let current = session.current, let started = session.currentStarted {
                        HStack(spacing: 8) {
                            Spinner(tint: tint).frame(width: 11, height: 11).frame(width: 12)
                            Text(current)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.75))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            TimelineView(LiveSchedule(start: started, live: vm.mode == .expanded)) { context in
                                Text(AgentSession.elapsed(since: started, now: context.date))
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        status(session, tint: tint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Click anywhere on the task to go to its window.
                .contentShape(Rectangle())
                .onTapGesture { if session.hostBundleID != nil { vm.openAgent(session) } }
                .help(session.hostBundleID != nil ? "Click to open \(session.displayName)" : "")

                if let text = session.summary ?? session.message {
                    summaryCard(session, text: text)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            Placeholder(symbol: "sparkles", text: "Connect Claude Code or Copilot in Settings ▸ Terminal")
        }
    }

    @ViewBuilder
    private func status(_ session: AgentSession, tint: Color) -> some View {
        HStack(spacing: 8) {
            switch session.state {
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                Text(session.files.isEmpty ? "Done" : "Done · \(session.files.count) file\(session.files.count == 1 ? "" : "s") changed")
            case .needsInput:
                Image(systemName: "hand.raised.fill").foregroundStyle(Color.yellow)
                Text("Waiting for you")
            case .working:
                Spinner(tint: tint).frame(width: 11, height: 11)
                Text("Working…")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
    }

    /// Its last reply, and a way back to the terminal.
    private func summaryCard(_ session: AgentSession, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
            if session.hostBundleID != nil {
                Button { vm.openAgent(session) } label: {
                    Label("Open", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .glassBackground(Capsule(), fallback: Color.white.opacity(0.12))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Bring the window running \(session.displayName) to the front")
            }
        }
        .padding(10)
        .frame(width: 210)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}
