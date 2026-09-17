import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var packager: Packager

    var body: some View {
        HStack(spacing: 0) {
            SettingsPane()
                .frame(width: 380)
            Divider()
            VStack(spacing: 0) {
                if packager.assets.isEmpty {
                    DropZone(targeted: packager.dropTargeted)
                } else {
                    AssetList()
                }
                Divider()
                FooterBar()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await packager.load(urls) }
            return true
        } isTargeted: { packager.dropTargeted = $0 }
        .onChange(of: settings.config.junkWords) { packager.reclean() }
        .onChange(of: settings.config.client) { packager.applyAutoVersion() }
        .onChange(of: settings.config.autoVersion) { packager.applyAutoVersion() }
    }
}

struct DropZone: View {
    @EnvironmentObject var packager: Packager
    let targeted: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
            Text("Drop a folder of final exports")
                .font(.title2.weight(.medium))
            Text("Images and video get renamed and resized. Anything else is copied into native formats.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Choose…") { packager.choose() }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .background(RoundedRectangle(cornerRadius: 14)
                    .fill(targeted ? Color.accentColor.opacity(0.08) : .clear))
                .padding(20)
        }
    }
}

struct AssetList: View {
    @EnvironmentObject var packager: Packager

    var body: some View {
        VStack(spacing: 0) {
            BatchNameBar()
            HStack(spacing: 12) {
                Text("Source").frame(width: 250, alignment: .leading).padding(.leading, 26)
                Text("Name → output").frame(alignment: .leading)
                Spacer()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            List {
                ForEach($packager.assets) { $asset in
                    AssetRow(asset: $asset)
                        .contextMenu {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([asset.url])
                            }
                            Button("Reset Name") {
                                asset.name = Naming.clean(asset.stem, junk: packager.settings.junk)
                                asset.edited = false
                            }
                            Divider()
                            Button("Remove") { packager.remove(asset.id) }
                        }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }
}

struct BatchNameBar: View {
    @EnvironmentObject var packager: Packager

    var body: some View {
        HStack(spacing: 8) {
            TextField("Name every file the same, e.g. \"Denver Rooftop Set\" → …-1, …-2, …-3",
                      text: $packager.batchName)
                .textFieldStyle(.roundedBorder)
                .disabled(packager.running)
                .onSubmit { packager.applyBatchName() }
            Button("Apply to All") { packager.applyBatchName() }
                .disabled(packager.running || packager.batchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

struct AssetRow: View {
    @EnvironmentObject var packager: Packager
    @EnvironmentObject var settings: Settings
    @Binding var asset: Asset

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon.frame(width: 14).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(asset.warnings, id: \.self) { w in
                    Text(w)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            .frame(width: 250, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                TextField("name", text: Binding(
                    get: { asset.name },
                    set: { asset.name = $0; asset.edited = true }))
                    .textFieldStyle(.roundedBorder)
                    .disabled(packager.running)
                Text(packager.previewName(asset))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        .help(helpText)
    }

    private var detail: String {
        var parts = [asset.kind.label]
        if let s = asset.size { parts.append("\(Int(s.width))×\(Int(s.height))") }
        if let codec = asset.videoCodec { parts.append(codec) }
        if let a = asset.audioInfo {
            let khz = a.sampleRate / 1000
            let rate = khz == khz.rounded() ? String(Int(khz)) : String(format: "%.1f", khz)
            parts.append("\(rate) kHz" + (a.bitDepth > 0 ? " \(a.bitDepth)-bit" : ""))
        }
        if asset.edited { parts.append("renamed") }
        return parts.joined(separator: " · ")
    }

    private var helpText: String {
        var lines: [String] = []
        if case .failed(let why) = asset.status { lines.append(why) }
        lines += asset.warnings
        lines.append(asset.url.path)
        return lines.joined(separator: "\n")
    }

    @ViewBuilder private var statusIcon: some View {
        switch asset.status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .working:
            ProgressView().controlSize(.mini)
        case .done where !asset.warnings.isEmpty:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.yellow)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

struct FooterBar: View {
    @EnvironmentObject var packager: Packager
    @EnvironmentObject var settings: Settings

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if !packager.assets.isEmpty {
                    Text("\(packager.assets.count) files → \(packager.jobCount) outputs")
                        .font(.callout.weight(.medium))
                }
                if !packager.message.isEmpty {
                    Text(packager.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if packager.running {
                ProgressView(value: packager.progress)
                    .frame(width: 160)
            }
            if let out = packager.output, !packager.running {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                }
            }
            Button("Clear") { packager.clear() }
                .disabled(packager.running || packager.assets.isEmpty)
            Group {
                Button {
                    Task { await packager.run(zip: true) }
                } label: {
                    Label("Zip", systemImage: "doc.zipper")
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .help("Package & Zip (⇧⌘↩)")
                Button {
                    Task { await packager.run(zip: false) }
                } label: {
                    Label("Package", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("p", modifiers: [.command, .option, .shift])
                .help("Package (⇧⌥⌘P)")
            }
            .disabled(packager.running || packager.assets.isEmpty || packager.formats.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct SettingsPane: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var packager: Packager

    var body: some View {
        Form {
            Section {
                TextField("Client", text: $settings.config.client, prompt: Text("Acme"))
                HStack {
                    TextField("Project", text: $settings.config.project, prompt: Text("spring-campaign"))
                    Toggle(isOn: $settings.config.includeProjectInName) { EmptyView() }
                        .toggleStyle(.checkbox)
                }
                HStack {
                    Stepper(value: $settings.config.version, in: 1...999) {
                        HStack {
                            Text("Version")
                            Spacer()
                            Text("v\(settings.config.version)" + (settings.config.autoVersion ? " · auto" : ""))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(settings.config.autoVersion || !settings.config.includeVersionInName)
                    Toggle(isOn: $settings.config.includeVersionInName) { EmptyView() }
                        .toggleStyle(.checkbox)
                }
                Toggle(isOn: $settings.config.autoVersion) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto version")
                        Text("Picks the next unused number next to the source folder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.config.includeVersionInName)
            } header: {
                Text("Job")
            } footer: {
                Text("Delivered as “\(packager.deliveryName(settings.config.version))”. Client, project and version only name the delivery folder/zip — never individual files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Pattern", text: $settings.config.template, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.system(.body, design: .monospaced))
                TextField("Strip words", text: $settings.config.junkWords, axis: .vertical)
                    .lineLimit(1...3)
            } header: {
                Text("Naming")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Naming.tokens.map { "{\($0)}" }.joined(separator: "  "))
                        .font(.system(.caption, design: .monospaced))
                    Text("Names are lowercased, spaces become hyphens, version tags and pixel sizes in the original name are dropped. Edit any name in the list to override it.")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $settings.config.resize) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Resize for platforms")
                        Text(settings.config.resize
                             ? "Each file is exported at every size below."
                             : "Off — files are renamed and copied untouched.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if settings.config.resize {
                    ForEach($settings.config.formats) { $format in
                        FormatRow(format: $format)
                            .contextMenu {
                                Button("Remove") {
                                    settings.config.formats.removeAll { $0.id == format.id }
                                }
                            }
                    }
                    HStack {
                        Button("Add Size") {
                            settings.config.formats.append(Format(label: "Custom", tag: "custom"))
                        }
                        Button("Add Native") {
                            settings.config.formats.append(Format(label: "Native copy", tag: "native", native: true))
                        }
                        Spacer()
                        Button("Reset") { settings.resetFormats() }
                    }
                    .buttonStyle(.borderless)
                    Picker("Mode", selection: $settings.config.fit) {
                        Text("Crop to fill").tag(FitMode.fill)
                        Text("Fit with bars").tag(FitMode.fit)
                    }
                    if settings.config.fit == .fit {
                        Picker("Bars", selection: $settings.config.padWhite) {
                            Text("Black").tag(false)
                            Text("White").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                }
            } header: {
                Text("Resize")
            } footer: {
                if settings.config.resize {
                    Text("Label · filename tag · size. Right-click a row to remove it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(isOn: $settings.config.stripMetadata) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Strip photo & video metadata")
                        Text("Removes location, camera and software info. Orientation, colour profile and picture quality are kept.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $settings.config.webFriendly) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Web-friendly formats")
                        Text("HEIC, TIFF, PSD → JPG (PNG if transparent). ProRes and other video → H.264 MP4; H.264 in .mov is rewrapped to .mp4 without re-encoding.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $settings.config.sizeCap) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("File size cap")
                        Text("Resized and converted files are squeezed under it. Untouched originals over it are flagged.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if settings.config.sizeCap {
                    HStack {
                        Text("Max size")
                        Spacer()
                        TextField("MB", value: $settings.config.sizeCapMB, format: .number.grouping(.never))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("MB").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Clean-up")
            }

            Section {
                Toggle(isOn: $settings.config.audio) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Audio deliverables")
                        Text("Masters are always copied untouched. These add extra versions of each audio file.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if settings.config.audio {
                    Toggle(isOn: $settings.config.audioMP3) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MP3 320")
                            if AudioTools.ffmpeg == nil {
                                Text("Needs ffmpeg: brew install ffmpeg")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    Toggle(isOn: $settings.config.audioCD) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("WAV 16-bit / 44.1 kHz")
                            Text("Mastering-quality resample, TPDF dither.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Audio")
            }

            Section {
                Toggle(isOn: $settings.config.finderImmediate) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Package straight away")
                        Text("Right-click a folder in Finder → Quick Actions or Services → Package with Crate. On: runs with these settings. Off: opens the files here first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Finder right-click")
            }

            Section("Output") {
                if settings.config.resize {
                    Toggle("Folder per format", isOn: $settings.config.subfolders)
                }
                Toggle("Write manifest.csv", isOn: $settings.config.manifest)
                Toggle("Keep folder when zipping", isOn: $settings.config.keepFolder)
                Toggle("Show in Finder when done", isOn: $settings.config.revealWhenDone)
            }
        }
        .formStyle(.grouped)
        .disabled(packager.running)
    }
}

struct FormatRow: View {
    @Binding var format: Format

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: $format.enabled)
                .labelsHidden()
            TextField("Label", text: $format.label)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            TextField("tag", text: $format.tag)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 58)
            if format.native {
                Text("native")
                    .foregroundStyle(.secondary)
                    .frame(width: 118)
            } else {
                TextField("W", value: $format.width, format: .number.grouping(.never))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52)
                Text("×").foregroundStyle(.secondary)
                TextField("H", value: $format.height, format: .number.grouping(.never))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52)
            }
        }
        .opacity(format.enabled ? 1 : 0.5)
    }
}
