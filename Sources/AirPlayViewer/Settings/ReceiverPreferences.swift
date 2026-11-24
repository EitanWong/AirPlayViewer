import AppKit
import ImageIO
import MirrorCore
import SwiftUI
import UniformTypeIdentifiers

struct ReceiverPreferences: Equatable {
    static let iconKey = "ReceiverCustomIconPNG"
    static let presentationKey = "PresentationEnabled"
    static let zoomKey = "PresentationZoomPercent"
    var name: String
    var icon: Data?
    var presentationEnabled: Bool
    var zoomPercent: Double

    init(defaults: UserDefaults) {
        name = ReceiverSettings.normalizedName(defaults.string(forKey: ReceiverSettings.Key.name) ?? "")
        icon = defaults.data(forKey: Self.iconKey)
        presentationEnabled = defaults.bool(forKey: Self.presentationKey)
        let stored = defaults.double(forKey: Self.zoomKey)
        zoomPercent = (5...30).contains(stored) ? stored : 18
    }

    func save(to defaults: UserDefaults) {
        defaults.set(name, forKey: ReceiverSettings.Key.name)
        defaults.set(icon, forKey: Self.iconKey)
        defaults.set(presentationEnabled, forKey: Self.presentationKey)
        defaults.set(zoomPercent, forKey: Self.zoomKey)
    }

    var iconImage: NSImage? {
        if let icon, let image = NSImage(data: icon) {
            let edge = max(image.size.width, image.size.height)
            guard edge > 0 else { return nil }
            image.size = NSSize(width: 18 * image.size.width / edge, height: 18 * image.size.height / edge)
            return image
        }
        let image = NSImage(systemSymbolName: "airplay.video", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        image?.isTemplate = true
        return image
    }

    /// Downsample before decoding the whole image; store only a bounded raster, not a file reference.
    static func importIcon(_ url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let type = CGImageSourceGetType(source), let uti = UTType(type as String), uti.conforms(to: .image),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(output, image, nil)
        return CGImageDestinationFinalize(output) ? data as Data : nil
    }
}

struct ReceiverPreferencesView: View {
    @State var draft: ReceiverPreferences
    let save: (ReceiverPreferences) -> Void
    let cancel: () -> Void
    @State private var picking = false
    @State private var importing = false
    @State private var importFailed = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(L10n.receiverSection) {
                    TextField(L10n.receiverName, text: $draft.name, prompt: Text(ReceiverSettings.defaultName))
                    LabeledContent(L10n.receiverIcon) {
                        HStack {
                            if let image = draft.iconImage {
                                Image(nsImage: image).frame(width: 18, height: 18).accessibilityHidden(true)
                            }
                            Button(L10n.chooseIcon) { picking = true }.disabled(importing)
                            if draft.icon != nil {
                                Button(L10n.resetIcon) { draft.icon = nil }.disabled(importing)
                            }
                            if importing { ProgressView().controlSize(.small) }
                        }
                    }
                }
                Section(L10n.presentationSection) {
                    Toggle(L10n.presentationEnabled, isOn: $draft.presentationEnabled)
                    LabeledContent(L10n.presentationZoom) {
                        HStack {
                            Slider(value: $draft.zoomPercent, in: 5...30, step: 1)
                                .accessibilityLabel(L10n.presentationZoom)
                            Text((draft.zoomPercent / 100).formatted(.percent.precision(.fractionLength(0))))
                                .monospacedDigit()
                                .frame(minWidth: 42, alignment: .trailing)
                                .accessibilityHidden(true)
                        }
                        .disabled(!draft.presentationEnabled)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(L10n.cancel, action: cancel)
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.save) {
                    var settings = draft
                    settings.name = ReceiverSettings.normalizedName(settings.name)
                    save(settings)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(importing)
            }
            .padding()
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            importing = true
            Task { @MainActor in
                let icon = await Task.detached(priority: .userInitiated) { ReceiverPreferences.importIcon(url) }.value
                importing = false
                if let icon { draft.icon = icon } else { importFailed = true }
            }
        }
        .alert(L10n.iconImportFailed, isPresented: $importFailed) {
            Button(L10n.ok, role: .cancel) {}
        }
    }
}
