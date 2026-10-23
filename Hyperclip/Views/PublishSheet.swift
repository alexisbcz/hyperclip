import AVFoundation
import SwiftUI

/// Posts an exported clip to the accounts connected in Zernio, now or at a set time.
struct PublishSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    let projectID: UUID
    let export: Export

    @AppStorage("publish.accounts") private var remembered = ""
    @State private var accounts: [Zernio.Account]?
    @State private var loadError: String?
    @State private var selected: Set<String> = []
    @State private var caption = ""
    @State private var title = ""
    @State private var visibility = Zernio.Visibility.public
    @State private var privacy = Zernio.TikTokPrivacy.everyone
    @State private var tiktokConsent = false
    @State private var schedules = false
    @State private var date = Date().addingTimeInterval(3600)
    @State private var progress: (Double, String)?
    @State private var outcomes: [Zernio.Outcome]?
    @State private var error: String?
    @State private var image: NSImage?

    private var chosen: [Zernio.Account] { (accounts ?? []).filter { selected.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                preview
                VStack(alignment: .leading, spacing: 16) {
                    Text("Publish").font(.title2.weight(.semibold))
                    if let outcomes {
                        results(outcomes)
                    } else {
                        form
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(22)
            Divider()
            footer
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
        }
        .frame(width: 680)
        .task { await load() }
        .task(id: export.file) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: export.file))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)
            if let (cgImage, _) = try? await generator.image(at: CMTime(seconds: min(1.5, export.duration / 3), preferredTimescale: 600)) {
                image = NSImage(cgImage: cgImage, size: .zero)
            }
        }
        .onAppear {
            caption = export.title
            title = export.title
            selected = Set(remembered.split(separator: ",").map(String.init))
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.black)
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
        }
        .frame(width: 160, height: 284)
        .clipShape(.rect(cornerRadius: 12))
        .overlay(alignment: .bottomTrailing) {
            Text(export.duration.clock)
                .font(.caption2.weight(.semibold)).monospacedDigit()
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
                .foregroundStyle(.white)
                .padding(8)
        }
    }

    @ViewBuilder
    private var form: some View {
        if !Zernio.hasKey {
            VStack(alignment: .leading, spacing: 10) {
                Text("Hyperclip posts through Zernio, which connects to X, YouTube, TikTok, Instagram, LinkedIn, Facebook, Threads, Bluesky and more. Connect your accounts on zernio.com, then add your API key.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Link("Open Zernio", destination: URL(string: "https://zernio.com")!)
                    Button("Add API Key…") {
                        UserDefaults.standard.set("publishing", forKey: "settings.tab")
                        openSettings()
                    }
                }
            }
        } else if let loadError {
            Label(loadError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Button("Try Again") { Task { await load() } }
        } else if let accounts {
            VStack(alignment: .leading, spacing: 8) {
                Text("Post to").font(.headline)
                if accounts.isEmpty {
                    Text("No accounts connected yet. Connect some in Zernio's dashboard.").foregroundStyle(.secondary)
                    Link("Open Zernio", destination: URL(string: "https://zernio.com/dashboard")!)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(accounts) { account in
                            AccountChip(account: account, isOn: selected.contains(account.id)) {
                                if selected.contains(account.id) { selected.remove(account.id) } else { selected.insert(account.id) }
                            }
                            .disabled(!account.isUsable || progress != nil)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Caption").font(.headline)
                TextEditor(text: $caption)
                    .font(.body)
                    .frame(height: 72)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                Text("\(caption.count) characters" + (chosen.contains { $0.platform == "twitter" } && caption.count > 280 ? " · X allows 280" : ""))
                    .font(.caption)
                    .foregroundStyle(chosen.contains { $0.platform == "twitter" } && caption.count > 280 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }

            if chosen.contains(where: { $0.platform == "youtube" }) {
                Grid(alignment: .leading, verticalSpacing: 8) {
                    GridRow {
                        Text("YouTube title").foregroundStyle(.secondary)
                        TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Visibility").foregroundStyle(.secondary)
                        Picker("", selection: $visibility) {
                            ForEach(Zernio.Visibility.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }
            }

            if chosen.contains(where: { $0.platform == "tiktok" }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("TikTok audience").foregroundStyle(.secondary)
                        Picker("", selection: $privacy) {
                            ForEach(Zernio.TikTokPrivacy.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Toggle(isOn: $tiktokConsent) {
                        Text("I agree to TikTok's Music Usage Confirmation and have previewed this video.")
                            .font(.callout)
                    }
                    .toggleStyle(.checkbox)
                }
            }

            HStack {
                Toggle("Schedule", isOn: $schedules.animation(.snappy))
                    .toggleStyle(.checkbox)
                if schedules {
                    DatePicker("", selection: $date, in: Date()...)
                        .labelsHidden()
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ProgressView("Loading your accounts…").controlSize(.small)
        }
    }

    private func results(_ outcomes: [Zernio.Outcome]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(outcomes) { outcome in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(outcome.succeeded ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Zernio.name(of: outcome.platform)) · \(outcome.status.capitalized)").font(.callout.weight(.medium))
                        if let error = outcome.error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        if let link = outcome.url, let url = URL(string: link) {
                            Link(link, destination: url).font(.caption).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let progress {
                ProgressView(value: progress.0).frame(width: 160)
                Text(progress.1).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if outcomes != nil {
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(schedules ? "Schedule" : "Publish") { publish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty || progress != nil || caption.isEmpty
                              || (chosen.contains { $0.platform == "tiktok" } && !tiktokConsent))
            }
        }
    }

    private func load() async {
        guard Zernio.hasKey else { return }
        loadError = nil
        do {
            accounts = try await Zernio.accounts()
            selected.formIntersection(Set(accounts?.map(\.id) ?? []))
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func publish() {
        remembered = selected.joined(separator: ",")
        error = nil
        let post = Zernio.Post(caption: caption, title: title.isEmpty ? export.title : title, accounts: chosen,
                               youtubeVisibility: visibility, tiktokPrivacy: privacy, schedule: schedules ? date : nil)
        progress = (0, "Starting")
        let file = export.file, exportID = export.id, projectID = projectID
        Task {
            do {
                let results = try await Zernio.publish(file, post: post) { fraction, detail in
                    Task { @MainActor in progress = (fraction, detail) }
                }
                outcomes = results
                let names = Dictionary(post.accounts.map { ($0.platform, $0.handle ?? $0.name) }, uniquingKeysWith: { a, _ in a })
                Library.shared.update(projectID) { project in
                    guard let index = project.exports.firstIndex(where: { $0.id == exportID }) else { return }
                    project.exports[index].posts = (project.exports[index].posts ?? []) + results.map {
                        Publication(platform: $0.platform, account: names[$0.platform] ?? "", status: $0.status, url: $0.url)
                    }
                }
            } catch {
                self.error = error.localizedDescription
            }
            progress = nil
        }
    }
}

/// A connected account as a toggle: its platform, name and handle.
private struct AccountChip: View {
    let account: Zernio.Account
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                Text(Zernio.name(of: account.platform)).fontWeight(.semibold)
                Text(account.handle ?? account.name).foregroundStyle(.secondary).lineLimit(1)
                if !account.isUsable {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help("Reconnect this account in Zernio")
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isOn ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: .capsule)
            .overlay(Capsule().strokeBorder(isOn ? AnyShapeStyle(.tint.opacity(0.6)) : AnyShapeStyle(.clear)))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

/// Lays children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
