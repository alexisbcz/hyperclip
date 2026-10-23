#if DEBUG
import AppKit

/// For checking the interface by eye: `HYPERCLIP_SNAPSHOT=/some/folder` saves a picture of the window for each of
/// `HYPERCLIP_PAGES` (start, project, exports, models; all by default), then quits. `HYPERCLIP_TIME` seeks the
/// first project there and selects the clip under it; `HYPERCLIP_CROPPED` previews the crop.
/// `HYPERCLIP_IMPORT` imports a file or link first and waits for its clips.
enum Snapshot {
    static func runIfRequested(_ studio: Studio) {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["HYPERCLIP_SNAPSHOT"] else { return }
        let pages = environment["HYPERCLIP_PAGES"]?.split(separator: ",").map(String.init) ?? ["start", "project", "exports", "models"]
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            NSApp.activate(ignoringOtherApps: true)
            if let source = environment["HYPERCLIP_IMPORT"] {
                let id = source.hasPrefix("http") ? Jobs.shared.importLink(source) : Jobs.shared.importFile(URL(fileURLWithPath: source))
                studio.open(id)
                while Jobs.shared.isBusy(id) { try? await Task.sleep(for: .milliseconds(500)) }
                if let error = Jobs.shared.errors[id] { try? error.write(toFile: folder + "/error.txt", atomically: true, encoding: .utf8) }
                if environment["HYPERCLIP_EXPORT"] != nil, let project = Library.shared.project(id), let clip = project.clips.max(by: { ($0.score ?? 0) < ($1.score ?? 0) }) {
                    Jobs.shared.export(id, clips: [clip.id])
                    while Jobs.shared.exporting[clip.id] != nil { try? await Task.sleep(for: .milliseconds(500)) }
                    if let file = Jobs.shared.exported[clip.id] { try? file.path.write(toFile: folder + "/exported.txt", atomically: true, encoding: .utf8) }
                    if let error = Jobs.shared.errors[id] { try? error.write(toFile: folder + "/error.txt", atomically: true, encoding: .utf8) }
                }
            }
            for page in pages {
                switch page {
                case "start": studio.destination = .start
                case "exports": studio.destination = .exports
                case "models": studio.destination = .models
                default:
                    guard let project = Library.shared.projects.first else { continue }
                    studio.destination = .project(project.id)
                    if let time = environment["HYPERCLIP_TIME"].flatMap(Double.init) {
                        try? await Task.sleep(for: .seconds(1))
                        studio.player.seek(to: time)
                        studio.select(project.clips.first { $0.range.contains(time) }, seek: false)
                    } else if let clip = project.clips.max(by: { ($0.score ?? 0) < ($1.score ?? 0) }) {
                        try? await Task.sleep(for: .seconds(1))
                        studio.select(clip)
                        studio.player.seek(to: clip.start + min(4, clip.duration / 3))
                    }
                    UserDefaults.standard.set(environment["HYPERCLIP_CROPPED"] != nil, forKey: "editor.cropped")
                    if let tab = environment["HYPERCLIP_INSPECTOR"] { UserDefaults.standard.set(tab, forKey: "editor.inspector") }
                }
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 700 }) {
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(nil)
                }
                try? await Task.sleep(for: .seconds(2))
                save(to: URL(fileURLWithPath: folder).appending(path: "\(page).png"))
            }
            if environment["HYPERCLIP_PUBLISH"] != nil, let project = Library.shared.projects.first(where: { !$0.exports.isEmpty }), let export = project.exports.first {
                studio.publishing = Studio.Publishing(projectID: project.id, export: export)
                try? await Task.sleep(for: .seconds(3))
                if let sheet = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent != nil }), let image = capture(CGWindowID(sheet.windowNumber)) {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: folder).appending(path: "publish.png"))
                }
                studio.publishing = nil
            }
            if environment["HYPERCLIP_OPEN_SETTINGS"] != nil {
                for tab in ["general", "downloads", "transcription", "finding", "captions", "appearance"] {
                    UserDefaults.standard.set(tab, forKey: "settings.tab")
                    try? await Task.sleep(for: .seconds(1.2))
                    if let settings = NSApp.windows.first(where: { $0.isVisible && $0.frame.width <= 700 && $0.contentView != nil }),
                       let image = capture(CGWindowID(settings.windowNumber)) {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: folder).appending(path: "settings-\(tab).png"))
                    }
                }
            }
            if environment["HYPERCLIP_STAY"] == nil {
                Library.shared.flush()
                NSApp.terminate(nil)
            }
        }
    }

    /// The window as the screen shows it, shadow included. An app may capture its own windows
    /// without the Screen Recording permission.
    static func save(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 700 }),
              let image = capture(CGWindowID(window.windowNumber))
        else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    typealias CreateImage = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?

    /// `CGWindowListCreateImage`, looked up at run time since Swift no longer exposes it.
    static func capture(_ window: CGWindowID) -> CGImage? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        return create(.null, 1 << 3, window, 0)?.takeRetainedValue()
    }
}
#endif
