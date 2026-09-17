import Foundation
import AppKit
import UniformTypeIdentifiers
import AVFoundation

enum Variant {
    case main, mp3, cd
}

struct Job {
    let index: Int
    let format: Format
    let variant: Variant
}

enum Action {
    case copy
    case stripImage
    case convertImage(String)
    case remux(AVFileType)
    case encodeVideo
    case resizeImage(String)
    case resizeVideo
    case mp3
    case cd
}

@MainActor
final class Packager: ObservableObject {
    @Published var assets: [Asset] = []
    @Published var source: URL?
    @Published var running = false
    @Published var progress = 0.0
    @Published var message = ""
    @Published var output: URL?
    @Published var dropTargeted = false
    @Published var batchName = ""

    var interactive = true
    private var outputParent: URL?
    let settings: Settings

    init(settings: Settings) {
        self.settings = settings
    }

    var formats: [Format] {
        settings.config.resize
            ? settings.config.formats.filter(\.enabled)
            : [Format(label: "Original", tag: "", native: true)]
    }

    static let mp3Format = Format(label: "MP3 320", tag: "mp3", native: true)
    static let cdFormat = Format(label: "WAV 16/44.1", tag: "16bit", native: true)

    func jobs(for index: Int) -> [Job] {
        let asset = assets[index]
        let cfg = settings.config
        var out: [Job] = []
        for f in formats where f.native || asset.kind == .image || asset.kind == .video {
            out.append(Job(index: index, format: f, variant: .main))
        }
        if cfg.audio && asset.kind == .audio {
            if cfg.audioMP3 { out.append(Job(index: index, format: Self.mp3Format, variant: .mp3)) }
            if cfg.audioCD { out.append(Job(index: index, format: Self.cdFormat, variant: .cd)) }
        }
        return out
    }

    var jobCount: Int {
        assets.indices.reduce(0) { $0 + jobs(for: $1).count }
    }

    private func sourceExt(_ asset: Asset) -> String {
        let e = asset.url.pathExtension.lowercased()
        return e == "jpeg" ? "jpg" : e
    }

    func plan(_ job: Job) -> (action: Action, ext: String) {
        let asset = assets[job.index]
        let cfg = settings.config
        switch job.variant {
        case .mp3: return (.mp3, "mp3")
        case .cd: return (.cd, "wav")
        case .main: break
        }
        let web = cfg.webFriendly
        if !job.format.native {
            if asset.kind == .video { return (.resizeVideo, "mp4") }
            let type = ImageResizer.outputType(sourceType: asset.imageType, hasAlpha: asset.hasAlpha, web: web)
            return (.resizeImage(type), ImageResizer.ext(for: type, source: asset.url))
        }
        switch asset.kind {
        case .image:
            let type = asset.imageType
            if web, let type, type != UTType.jpeg.identifier, type != UTType.png.identifier {
                let out = ImageResizer.outputType(sourceType: type, hasAlpha: asset.hasAlpha, web: true)
                return (.convertImage(out), ImageResizer.ext(for: out, source: asset.url))
            }
            return cfg.stripMetadata ? (.stripImage, sourceExt(asset)) : (.copy, sourceExt(asset))
        case .video:
            if web {
                if let codec = asset.videoCodec, !VideoResizer.webCodecs.contains(codec) {
                    return (.encodeVideo, "mp4")
                }
                if sourceExt(asset) != "mp4" { return (.remux(.mp4), "mp4") }
            }
            if cfg.stripMetadata {
                let type = VideoResizer.fileType(forExtension: sourceExt(asset))
                return (.remux(type), type == .mov ? "mov" : sourceExt(asset))
            }
            return (.copy, sourceExt(asset))
        case .audio, .other:
            return (.copy, sourceExt(asset))
        }
    }

    func nextFreeVersion() -> Int? {
        guard settings.config.includeVersionInName, let parent = outputParent,
              let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path)
        else { return nil }
        let prefix = deliveryName(0).dropLast(1)
        let used = names.compactMap { name -> Int? in
            let base = name.hasSuffix(".zip") ? String(name.dropLast(4)) : name
            guard base.hasPrefix(prefix) else { return nil }
            return Int(base.dropFirst(prefix.count))
        }
        return (used.max() ?? 0) + 1
    }

    func applyAutoVersion() {
        guard settings.config.autoVersion, let next = nextFreeVersion(),
              next != settings.config.version else { return }
        settings.config.version = next
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Load"
        if panel.runModal() == .OK {
            Task { await load(panel.urls) }
        }
    }

    func clear() {
        guard !running else { return }
        assets = []
        source = nil
        outputParent = nil
        output = nil
        message = ""
        progress = 0
    }

    func remove(_ id: Asset.ID) {
        guard !running else { return }
        assets.removeAll { $0.id == id }
    }

    func load(_ urls: [URL]) async {
        guard !running, !urls.isEmpty else { return }
        let fm = FileManager.default
        var files: [URL] = []
        for url in urls {
            if isDirectory(url) {
                let items = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let item = items?.nextObject() as? URL {
                    if (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                        files.append(item)
                    }
                }
            } else {
                files.append(url)
            }
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        if urls.count == 1 && isDirectory(urls[0]) {
            source = urls[0]
            outputParent = urls[0].deletingLastPathComponent()
        } else {
            source = urls[0].deletingLastPathComponent()
            outputParent = source
        }
        output = nil
        progress = 0
        let junk = settings.junk
        assets = files.map { url in
            Asset(url: url, kind: kind(of: url), name: Naming.clean(url.deletingPathExtension().lastPathComponent, junk: junk))
        }
        message = ""
        applyAutoVersion()

        for asset in assets {
            var probed = asset
            let url = asset.url
            switch asset.kind {
            case .image:
                if let p = await Task.detached(operation: { ImageResizer.probe(url) }).value {
                    probed.size = p.size
                    probed.imageType = p.type
                    probed.hasAlpha = p.hasAlpha
                } else {
                    probed.kind = .other
                }
            case .video:
                if let p = await VideoResizer.probe(url) {
                    probed.size = p.size
                    probed.videoCodec = p.codec
                    probed.duration = p.duration
                } else {
                    probed.kind = .other
                }
            case .audio:
                if let info = await Task.detached(operation: { AudioTools.probe(url) }).value {
                    probed.audioInfo = info
                } else {
                    probed.kind = .other
                }
            case .other:
                break
            }
            if let i = assets.firstIndex(where: { $0.id == asset.id }) {
                assets[i].kind = probed.kind
                assets[i].size = probed.size
                assets[i].imageType = probed.imageType
                assets[i].hasAlpha = probed.hasAlpha
                assets[i].videoCodec = probed.videoCodec
                assets[i].duration = probed.duration
                assets[i].audioInfo = probed.audioInfo
            }
        }
    }

    func applyBatchName() {
        let base = batchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !assets.isEmpty else { return }
        let width = max(2, String(assets.count).count)
        for i in assets.indices {
            assets[i].name = "\(base) \(String(format: "%0\(width)d", i + 1))"
            assets[i].edited = true
        }
    }

    func reclean() {
        let junk = settings.junk
        for i in assets.indices where !assets[i].edited {
            assets[i].name = Naming.clean(assets[i].stem, junk: junk)
        }
    }

    func previewName(_ asset: Asset) -> String {
        guard let index = assets.firstIndex(where: { $0.id == asset.id }) else { return "" }
        let jobs = jobs(for: index)
        guard let job = jobs.first(where: { !$0.format.native }) ?? jobs.first
        else { return "skipped — only images and video go into resized sizes" }
        var name = join(fileStem(asset, job.format, index + 1, Naming.dateStamp()), plan(job).ext)
        if jobs.count > 1 { name += "  +\(jobs.count - 1)" }
        return name
    }

    private func fileStem(_ asset: Asset, _ format: Format, _ n: Int, _ date: String) -> String {
        let c = settings.config
        let stem = Naming.render(c.template, [
            "name": Naming.slug(asset.name),
            "format": Naming.slug(format.tag),
            "size": format.native ? asset.size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "" : format.sizeText,
            "version": c.includeVersionInName ? "v\(c.version)" : "",
            "date": date,
            "n": String(format: "%02d", n),
        ])
        return Naming.applyCase(stem, c.caseStyle)
    }

    private func join(_ stem: String, _ ext: String) -> String {
        ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    private func sanitizeForFolder(_ s: String) -> String {
        s.replacingOccurrences(of: #"[/:\\]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }

    func deliveryName(_ version: Int) -> String {
        let cfg = settings.config
        let client = sanitizeForFolder(cfg.client)
        var parts = [client.isEmpty ? "Delivery" : client]
        if cfg.includeProjectInName {
            let project = sanitizeForFolder(cfg.project)
            if !project.isEmpty { parts.append(project) }
        }
        if cfg.includeVersionInName {
            parts.append("v\(version)")
        }
        return parts.joined(separator: " ")
    }

    private enum Conflict { case bump, replace }

    private func resolveConflict(_ root: URL, next: Int?, canReplace: Bool) -> Conflict? {
        guard interactive else { return nil }
        let alert = NSAlert()
        alert.messageText = "“\(root.lastPathComponent)” already exists"
        if let next {
            alert.informativeText = canReplace
                ? "Export as v\(next) instead, or move the existing delivery to the Trash and replace it?"
                : "That's the folder you're packaging from. Export as v\(next) instead?"
            alert.addButton(withTitle: "Export as v\(next)")
        } else {
            alert.informativeText = canReplace
                ? "Turn on Version to export a new copy, or move the existing delivery to the Trash and replace it?"
                : "That's the folder you're packaging from. Turn on Version to export under a new name."
        }
        if canReplace { alert.addButton(withTitle: "Replace") }
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return next != nil ? .bump : (canReplace ? .replace : nil)
        case .alertSecondButtonReturn: return canReplace ? .replace : nil
        default: return nil
        }
    }

    func run(zip: Bool) async {
        guard !running, !assets.isEmpty, let base = source, let parent = outputParent else { return }
        guard !formats.isEmpty else {
            message = "Turn on at least one size."
            return
        }

        applyAutoVersion()
        let fm = FileManager.default
        let isSource = { (url: URL) in url.standardizedFileURL == base.standardizedFileURL }
        let exists = { (url: URL) in
            fm.fileExists(atPath: url.path) || fm.fileExists(atPath: url.appendingPathExtension("zip").path) || isSource(url)
        }
        var root = parent.appendingPathComponent(deliveryName(settings.config.version))
        if exists(root) {
            var next: Int?
            if settings.config.includeVersionInName {
                var candidate = settings.config.version + 1
                while exists(parent.appendingPathComponent(deliveryName(candidate))) { candidate += 1 }
                next = candidate
            }
            switch resolveConflict(root, next: next, canReplace: !isSource(root)) {
            case .bump:
                settings.config.version = next!
                root = parent.appendingPathComponent(deliveryName(next!))
            case .replace:
                do {
                    for url in [root, root.appendingPathExtension("zip")] where fm.fileExists(atPath: url.path) {
                        try fm.trashItem(at: url, resultingItemURL: nil)
                    }
                } catch {
                    message = "Couldn't move the old delivery to the Trash: \(error.localizedDescription)"
                    return
                }
            case nil:
                message = interactive
                    ? "Cancelled."
                    : settings.config.includeVersionInName
                        ? "\(root.lastPathComponent) already exists — bump the version."
                        : "\(root.lastPathComponent) already exists — turn on Version, or delete/rename it first."
                return
            }
        }

        let cfg = settings.config
        let formats = formats
        let subfolders = cfg.resize && cfg.subfolders
        running = true
        defer { running = false }
        progress = 0
        output = nil
        for i in assets.indices { assets[i].status = .pending }

        let date = Naming.dateStamp()

        let jobs = assets.indices.flatMap { self.jobs(for: $0) }
        let skipped = assets.indices.filter { self.jobs(for: $0).isEmpty }.count
        var used: [String: Set<String>] = [:]
        var rows = ["source,format,file,width,height,size_mb,note"]
        var failures = 0
        var warned = 0
        for i in assets.indices { assets[i].warnings = [] }

        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            message = "Couldn't create output folder: \(error.localizedDescription)"
            return
        }

        for (done, job) in jobs.enumerated() {
            let (i, format) = (job.index, job.format)
            let asset = assets[i]
            if case .failed = asset.status {} else { assets[i].status = .working }
            message = "\(asset.url.lastPathComponent) → \(format.label)"

            let dir = subfolders ? root.appendingPathComponent(format.folderName) : root
            let stem = fileStem(asset, format, i + 1, date)
            let (action, ext) = plan(job)
            var taken = used[dir.path, default: []]
            var file = join(stem, ext)
            var k = 2
            while taken.contains(file.lowercased()) {
                file = join("\(stem)-\(k)", ext)
                k += 1
            }
            taken.insert(file.lowercased())
            used[dir.path] = taken
            let dst = dir.appendingPathComponent(file)

            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let (size, warning) = try await produce(asset, format, action, dst, cfg)
                let rel = subfolders ? "\(format.folderName)/\(file)" : file
                var notes = warning.map { [$0] } ?? []
                let bytes = ImageResizer.fileSize(dst)
                if warning == nil, cfg.sizeCap, bytes > capBytes(cfg) {
                    notes.append("Over size cap (\(ImageResizer.mb(bytes)))")
                }
                if !notes.isEmpty {
                    assets[i].warnings.append(contentsOf: notes.map { "\(format.label): \($0)" })
                    warned += 1
                }
                rows.append([asset.url.lastPathComponent, format.label, rel,
                             size.map { String(Int($0.width)) } ?? "",
                             size.map { String(Int($0.height)) } ?? "",
                             String(format: "%.2f", Double(bytes) / 1_000_000),
                             notes.joined(separator: "; ")].map(csv).joined(separator: ","))
            } catch {
                failures += 1
                assets[i].status = .failed(error.localizedDescription)
                try? fm.removeItem(at: dst)
            }
            progress = Double(done + 1) / Double(jobs.count)
        }
        for i in assets.indices where assets[i].status == .working {
            assets[i].status = .done
        }

        if cfg.manifest {
            try? (rows.joined(separator: "\n") + "\n")
                .write(to: root.appendingPathComponent("manifest.csv"), atomically: true, encoding: .utf8)
        }

        var result = root
        if zip {
            message = "Zipping…"
            do {
                result = try await Self.zip(root)
                if !cfg.keepFolder { try? fm.trashItem(at: root, resultingItemURL: nil) }
            } catch {
                message = "Zip failed: \(error.localizedDescription)"
                output = root
                return
            }
        }

        output = result
        var summary = "Packaged \(jobs.count - failures) files → \(result.lastPathComponent)"
        if failures > 0 { summary += " · \(failures) failed" }
        if warned > 0 { summary += " · \(warned) with warnings" }
        if skipped > 0 { summary += " · \(skipped) skipped" }
        message = summary
        if interactive && cfg.revealWhenDone { NSWorkspace.shared.activateFileViewerSelecting([result]) }
    }

    private func capBytes(_ cfg: Config) -> Int {
        Int(max(cfg.sizeCapMB, 0.1) * 1_000_000)
    }

    private func produce(_ asset: Asset, _ format: Format, _ action: Action, _ dst: URL,
                         _ cfg: Config) async throws -> (CGSize?, String?) {
        let src = asset.url
        let (fit, pad, strip) = (cfg.fit, cfg.padWhite, cfg.stripMetadata)
        let cap = cfg.sizeCap ? capBytes(cfg) : nil

        switch action {
        case .copy:
            try FileManager.default.copyItem(at: src, to: dst)
            return (asset.size, nil)
        case .stripImage:
            let ok = await Task.detached { ImageResizer.stripMetadata(src, to: dst) }.value
            if ok { return (asset.size, nil) }
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
            return (asset.size, "Couldn't strip metadata from this format; copied as is")
        case .convertImage(let type):
            let warning = try await Task.detached {
                try ImageResizer.render(src, to: dst, type: type, width: nil, height: nil,
                                        fit: fit, padWhite: pad, capBytes: cap)
            }.value
            return (asset.size, warning)
        case .resizeImage(let type):
            let (w, h) = (format.width, format.height)
            guard (16...16384).contains(w), (16...16384).contains(h) else { throw CrateError("Bad size \(w)x\(h)") }
            let warning = try await Task.detached {
                try ImageResizer.render(src, to: dst, type: type, width: w, height: h,
                                        fit: fit, padWhite: pad, capBytes: cap)
            }.value
            return (CGSize(width: w, height: h), warning)
        case .remux(let type):
            try await VideoResizer.remux(src, to: dst, as: type, strip: strip)
            return (asset.size, nil)
        case .encodeVideo:
            guard let size = asset.size else { throw CrateError("Unknown video size") }
            let warning = try await VideoResizer.render(src, to: dst, width: Int(size.width),
                                                        height: Int(size.height), fit: .fit, padWhite: pad,
                                                        strip: strip, capBytes: cap)
            return (size, warning)
        case .resizeVideo:
            let (w, h) = (format.width, format.height)
            guard (16...16384).contains(w), (16...16384).contains(h) else { throw CrateError("Bad size \(w)x\(h)") }
            let warning = try await VideoResizer.render(src, to: dst, width: w, height: h, fit: fit,
                                                        padWhite: pad, strip: strip, capBytes: cap)
            return (CGSize(width: w + w % 2, height: h + h % 2), warning)
        case .mp3:
            let rate = asset.audioInfo?.sampleRate ?? 44_100
            try await Task.detached { try AudioTools.makeMP3(src, to: dst, sampleRate: rate) }.value
            return (nil, nil)
        case .cd:
            try await Task.detached { try AudioTools.makeCD(src, to: dst) }.value
            return (nil, nil)
        }
    }

    nonisolated private static func zip(_ folder: URL) async throws -> URL {
        let zipURL = folder.appendingPathExtension("zip")
        try? FileManager.default.removeItem(at: zipURL)
        return try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", folder.path, zipURL.path]
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw CrateError("ditto exited \(p.terminationStatus)") }
            return zipURL
        }.value
    }

    private func csv(_ s: String) -> String {
        s.contains(where: { ",\"\n".contains($0) }) ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private func kind(of url: URL) -> Kind {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .other }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) && !type.conforms(to: .svg) && !type.conforms(to: .pdf) { return .image }
        return .other
    }
}
