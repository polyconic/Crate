import Foundation
import CoreGraphics

struct Format: Identifiable, Codable, Hashable {
    var id = UUID()
    var label: String
    var tag: String
    var native = false
    var width = 1080
    var height = 1080
    var enabled = true

    var folderName: String {
        let t = Naming.slug(tag).isEmpty ? Naming.slug(label) : Naming.slug(tag)
        return native ? t : "\(t)_\(width)x\(height)"
    }

    var sizeText: String { native ? "native" : "\(width)x\(height)" }

    static let defaults: [Format] = [
        Format(label: "Original", tag: "master", native: true),
        Format(label: "IG Square", tag: "1x1", width: 1080, height: 1080),
        Format(label: "IG Portrait", tag: "4x5", width: 1080, height: 1350),
        Format(label: "Story / Reel", tag: "9x16", width: 1080, height: 1920),
        Format(label: "Landscape", tag: "16x9", width: 1920, height: 1080, enabled: false),
    ]
}

enum FitMode: String, Codable, CaseIterable {
    case fill, fit
}

struct Config: Codable {
    var client = ""
    var project = ""
    var version = 1
    var template = "{name}_{format}_v{version}"
    var junkWords = "final, finalfinal, fnl, export, exported, copy, untitled, edit, render, approved"
    var formats = Format.defaults
    var fit = FitMode.fill
    var padWhite = false
    var resize = false
    var subfolders = true
    var manifest = true
    var keepFolder = true
    var autoVersion = false
    var stripMetadata = false
    var webFriendly = false
    var sizeCap = false
    var sizeCapMB = 100.0
    var audio = false
    var audioMP3 = true
    var audioCD = true
    var finderImmediate = false
    var revealWhenDone = false
    var includeProjectInName = true
    var includeVersionInName = true
}

extension Config {
    private enum CodingKeys: String, CodingKey {
        case client, project, version, template, junkWords, formats, fit, padWhite,
             resize, subfolders, manifest, keepFolder, autoVersion, stripMetadata, webFriendly,
             sizeCap, sizeCapMB, audio, audioMP3, audioCD, finderImmediate, revealWhenDone,
             includeProjectInName, includeVersionInName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        func load<T: Decodable>(_ key: CodingKeys, into value: inout T) {
            if let v = try? c.decodeIfPresent(T.self, forKey: key) { value = v }
        }
        load(.client, into: &client)
        load(.project, into: &project)
        load(.version, into: &version)
        load(.template, into: &template)
        template = template.replacingOccurrences(of: "{client}", with: "")
            .replacingOccurrences(of: "{project}", with: "")
            .replacingOccurrences(of: #"([_\-.])[_\-.]+"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_-. "))
        load(.junkWords, into: &junkWords)
        load(.formats, into: &formats)
        load(.fit, into: &fit)
        load(.padWhite, into: &padWhite)
        load(.resize, into: &resize)
        load(.subfolders, into: &subfolders)
        load(.manifest, into: &manifest)
        load(.keepFolder, into: &keepFolder)
        load(.autoVersion, into: &autoVersion)
        load(.stripMetadata, into: &stripMetadata)
        load(.webFriendly, into: &webFriendly)
        load(.sizeCap, into: &sizeCap)
        load(.sizeCapMB, into: &sizeCapMB)
        load(.audio, into: &audio)
        load(.audioMP3, into: &audioMP3)
        load(.audioCD, into: &audioCD)
        load(.finderImmediate, into: &finderImmediate)
        load(.revealWhenDone, into: &revealWhenDone)
        load(.includeProjectInName, into: &includeProjectInName)
        load(.includeVersionInName, into: &includeVersionInName)
    }
}

final class Settings: ObservableObject {
    @Published var config: Config {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "config"),
           let saved = try? JSONDecoder().decode(Config.self, from: data) {
            config = saved
        } else {
            config = Config()
        }
    }

    var junk: Set<String> {
        Set(config.junkWords.lowercased()
            .split(whereSeparator: { ", \n;".contains($0) })
            .map(String.init))
    }

    func resetFormats() {
        config.formats = Format.defaults
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "config")
        }
    }
}

enum Kind {
    case image, video, audio, other

    var label: String {
        switch self {
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .other: "File"
        }
    }
}

enum Status: Equatable {
    case pending, working, done, failed(String)
}

struct Asset: Identifiable {
    let id = UUID()
    let url: URL
    var kind: Kind
    var size: CGSize?
    var name: String
    var edited = false
    var status = Status.pending
    var warnings: [String] = []
    var imageType: String?
    var hasAlpha = false
    var videoCodec: String?
    var duration: Double?
    var audioInfo: AudioInfo?

    var stem: String { url.deletingPathExtension().lastPathComponent }
}

struct AudioInfo {
    var sampleRate: Double
    var bitDepth: Int
    var channels: Int
    var isFloat: Bool
}

struct CrateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
