import SwiftUI
import VisionOneKit

/// Settings › Agents: let Claude Code, Codex and other agents use Vision
/// One over MCP. One switch, one click to add it to an agent, and a rule
/// per agent. Sharing always asks, whatever the rule.
struct AgentsSettingsView: View {
    @ObservedObject var service: MCPService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Toggle(isOn: $service.enabled) {
                        Text("Let coding agents use Vision One").font(.system(size: 15, weight: .semibold))
                    }
                    .toggleStyle(.switch)
                    .tint(Theme.text)
                    Text("Claude Code, Codex and other agents can list and read your takes, draft cuts, clips and posts, and export. Recording, keeping changes and sharing ask you first.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let problem = service.problem {
                        Text(problem).font(.system(size: 12)).foregroundStyle(Theme.error)
                    }
                }

                if service.enabled {
                    section("Connect an agent") {
                        HStack(spacing: Theme.Space.sm) {
                            Button("Add to Claude Code") {
                                service.addTo("Claude Code", command: MCPService.claudeCodeCommand)
                            }
                            .buttonStyle(PillButtonStyle(kind: .primary))
                            Button("Add to Codex") {
                                service.addTo("Codex", command: MCPService.codexCommand)
                            }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                            Button("Copy setup for other apps") {
                                service.copy(MCPService.jsonConfig,
                                             note: "Copied. Paste it into your app's MCP settings (Cursor, Claude Desktop, Zed).")
                            }
                            .buttonStyle(PillButtonStyle(kind: .quiet))
                        }
                        if let note = service.setupNote {
                            Text(note).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                        }
                        Text(MCPService.command.map(MCPService.shellQuoted).joined(separator: " "))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textMuted)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                    }

                    section("Agents that have connected") {
                        if service.agents.isEmpty {
                            Text("None yet. Once you add Vision One to an agent and it connects, it shows here.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textMuted)
                        }
                        ForEach(service.agents) { agent in
                            AgentRow(agent: agent, service: service)
                        }
                        Text("Sharing always asks, whatever you pick here.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.textMuted)
            content()
        }
    }
}

private struct AgentRow: View {
    let agent: MCPService.Agent
    @ObservedObject var service: MCPService

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).font(.system(size: 13, weight: .semibold))
                Text("Last connected " + agent.lastUsed.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { service.trusted.contains(agent.id) },
                set: { service.setTrusted(agent, $0) }
            )) {
                Text("Ask first").tag(false)
                Text("Allow until quit").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            Button("Forget") { service.forget(agent) }
                .buttonStyle(PillButtonStyle(kind: .quiet))
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.line))
    }
}
