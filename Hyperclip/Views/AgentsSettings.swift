import SwiftUI

/// Settings › Agents: adds Hyperclip's MCP server to the AI agents on this Mac in one click each, and puts the
/// `hyperclip` command on your PATH.
struct AgentsSettings: View {
    @State private var states: [String: AgentIntegrations.State] = [:]
    @State private var command = CommandLineTool.status
    @State private var working: String?
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                ForEach(AgentIntegrations.agents) { agent in
                    row(agent)
                }
            } header: {
                Text("MCP Server")
            } footer: {
                Text("Agents can then import videos, read transcripts, find, trim and export clips, and publish them, while you watch it happen here. Restart an agent after adding Hyperclip.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    switch command {
                    case .installed:
                        Button("Remove") { change { try CommandLineTool.uninstall() } }
                    case .notInstalled, .elsewhere:
                        Button("Install") { change { try CommandLineTool.install() } }
                    }
                } label: {
                    Text("‘hyperclip’ command")
                    switch command {
                    case .installed(let link): Label("Installed at \(link.path)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .elsewhere(let link): Text("Points at another copy of Hyperclip: \(link.path)")
                    case .notInstalled: Text("Not installed")
                    }
                }
                Text(verbatim: """
                hyperclip import https://youtu.be/… --wait
                hyperclip clips latest
                hyperclip export latest --best 3 --aspect vertical --wait
                hyperclip publish latest --to youtube,tiktok --tiktok-consent
                """)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            } header: {
                Text("Command Line")
            } footer: {
                Text("Run hyperclip --help for every command. Add --json to any of them for output scripts can read.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Text(AgentIntegrations.snippet)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AgentIntegrations.snippet, forType: .string)
                    copied = true
                }
            } header: {
                Text("Other Agents")
            } footer: {
                Text("Most agents read this shape of config. Links like hyperclip://import?url=… and the Shortcuts actions drive Hyperclip too.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 660)
        .onAppear(perform: refresh)
        .alert("Couldn't change that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    @ViewBuilder
    private func row(_ agent: AgentIntegrations.Agent) -> some View {
        let state = states[agent.id] ?? .notFound
        LabeledContent {
            if working == agent.id {
                ProgressView().controlSize(.small)
            } else {
                switch state {
                case .notFound, .notAdded:
                    Button("Add") { change(agent, add: true) }
                case .added:
                    Button("Remove") { change(agent, add: false) }
                case .elsewhere:
                    HStack {
                        Button("Update") { change(agent, add: true) }
                        Button("Remove") { change(agent, add: false) }
                    }
                }
            }
        } label: {
            Text(agent.name)
            switch state {
            case .notFound: Text("Not found on this Mac")
            case .notAdded: Text("Not added")
            case .added: Label("Added", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .elsewhere(let path): Text("Uses another copy of Hyperclip: \(path)")
            }
        }
        .help(agent.file.path)
    }

    private func change(_ agent: AgentIntegrations.Agent, add: Bool) {
        working = agent.id
        Task {
            do {
                if add { try await AgentIntegrations.add(agent) } else { try await AgentIntegrations.remove(agent) }
            } catch {
                self.error = error.localizedDescription
            }
            working = nil
            refresh()
        }
    }

    private func change(_ body: () throws -> Void) {
        do { try body() } catch is CancellationError {} catch { self.error = error.localizedDescription }
        refresh()
    }

    private func refresh() {
        states = Dictionary(uniqueKeysWithValues: AgentIntegrations.agents.map { ($0.id, AgentIntegrations.state(of: $0)) })
        command = CommandLineTool.status
    }
}
