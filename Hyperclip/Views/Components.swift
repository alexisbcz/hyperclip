import AVFoundation
import SwiftUI

/// What a pane shows before there's anything in it.
struct EmptyState<Actions: View>: View {
    let title: String
    let icon: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            actions
        }
    }
}

/// A project's thumbnail, or a placeholder until there is one.
struct Thumbnail: View {
    let project: Project
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film").foregroundStyle(.tertiary)
            }
        }
        .clipped()
        .task(id: project.duration) {
            image = NSImage(contentsOf: Library.thumbnail(of: project.id))
        }
    }
}

/// How likely a clip is to work, as a ring that fills and shifts from orange to green.
struct ScoreBadge: View {
    let score: Double
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: 3)
            Circle()
                .trim(from: 0, to: score / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(score))")
                .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: size, height: size)
        .help("Score: \(Int(score)) out of 100")
    }

    var color: Color { Self.color(for: score) }

    static func color(for score: Double) -> Color {
        score >= 80 ? .green : score >= 60 ? .mint : score >= 45 ? .orange : .secondary
    }
}

struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.3), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// A small rounded tag.
struct Chip: View {
    let text: String
    var icon: String?

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.7), in: .capsule)
    }
}

/// A rounded panel on the page, the way the app groups things outside of forms.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
    }
}

/// The current step of a project's work, with its progress and a way to stop it.
struct JobBanner: View {
    @Environment(Jobs.self) private var jobs
    let projectID: UUID

    var body: some View {
        if let job = jobs.running[projectID] {
            HStack(spacing: 12) {
                if let progress = job.progress {
                    ProgressView(value: progress).frame(width: 140)
                } else {
                    ProgressView().controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.kind.title + (job.progress.map { " · \(Int($0 * 100))%" } ?? "")).font(.callout.weight(.medium))
                    if !job.detail.isEmpty {
                        Text(job.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button("Stop") { jobs.cancel(projectID) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 12))
        } else if let error = jobs.errors[projectID] {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    jobs.errors[projectID] = nil
                } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 12))
        }
    }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
