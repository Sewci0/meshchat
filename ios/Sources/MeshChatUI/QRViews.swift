import CoreImage
import CoreImage.CIFilterBuiltins
import MeshChatCore
import MeshCoreKit
import PhotosUI
import SwiftUI
#if os(iOS)
import UIKit
#if !targetEnvironment(macCatalyst)
import VisionKit
#endif
#elseif os(macOS)
import AppKit
#endif

/// Contacts by QR code, as the MeshCore apps exchange them: your own code to show, and adding someone
/// (or a channel) from theirs, by camera, from a photo or screenshot, or from a pasted link. All offline.
struct ContactCodesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// a link opened from outside, to show straight away
    var link: String?
    var open: (ConversationID) -> Void = { _ in }
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Show", selection: $tab) { Text("My code").tag(0); Text("Add from a code").tag(1) }
                    .pickerStyle(.segmented)
                    .padding()
                if tab == 0 { MyCodeView() } else { AddFromCodeView(initial: link) { c in dismiss(); open(c) } }
            }
            .onAppear { if link != nil { tab = 1 } }
            .navigationTitle("Contacts by QR code")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Your contact link as a QR code, to scan with any MeshCore app.
struct MyCodeView: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        Form {
            if let me = model.me {
                let link = MeshLink.contactLink(name: me.name, key: me.key)
                Section {
                    if let qr = QRCode.image(link) {
                        Image(decorative: qr, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                            .background(.white, in: .rect(cornerRadius: 12))
                            .frame(maxWidth: 280)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("QR code of your contact link")
                    }
                    LabeledContent("Name", value: me.name)
                } footer: {
                    Text("Someone scans this to add you. Your messages reach them once their radio has heard your advert, or straight away if they add you from this code.")
                }
                Section {
                    ShareLink(item: link, subject: Text("My MeshCore contact")) { Label("Share link", systemImage: "square.and.arrow.up") }
                    Button { copyToClipboard(link); copied = true } label: {
                        Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                } footer: {
                    Text(link).font(.caption.monospaced()).textSelection(.enabled)
                }
            } else {
                ContentUnavailableView("Not connected", systemImage: "antenna.radiowaves.left.and.right.slash",
                                       description: Text("Your code shows once the radio is connected."))
            }
        }
        .formStyle(.grouped)
    }
}

/// Adds a contact or joins a channel from a meshcore:// link: scanned, from a picture, or pasted.
struct AddFromCodeView: View {
    @Environment(AppModel.self) private var model
    var initial: String?
    let open: (ConversationID) -> Void
    @State private var found: MeshLink?
    @State private var text = ""
    @State private var photo: PhotosPickerItem?
    @State private var problem: String?
    @State private var busy = false
    @State private var addedNetwork = false
    @State private var scanning = false

    var body: some View {
        Form {
            if let found {
                result(found)
            } else {
                Section {
                    #if os(iOS) && !targetEnvironment(macCatalyst)
                    if CodeScanner.isAvailable {
                        Button { scanning = true } label: { Label("Scan a code", systemImage: "qrcode.viewfinder") }
                    }
                    #endif
                    PhotosPicker(selection: $photo, matching: .images) { Label("Choose a picture of a code", systemImage: "photo") }
                } footer: {
                    Text("A screenshot of a code works too, for example one someone sent you.")
                }
                Section {
                    TextField("meshcore://…", text: $text, axis: .vertical)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit { read(text) }
                    HStack {
                        Button("Read link") { read(text) }.disabled(text.isEmpty)
                        Spacer()
                        PasteButton(payloadType: String.self) { s in if let first = s.first { text = first; read(first) } }
                            .labelStyle(.iconOnly)
                    }
                } header: { Text("Or paste a link") }
            }
            if let problem { Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
        }
        .formStyle(.grouped)
        .onAppear { if let initial, found == nil { read(initial) } }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                defer { photo = nil }
                guard let data = try? await item.loadTransferable(type: Data.self) else { problem = String(localized: "That picture couldn't be opened."); return }
                guard let s = QRCode.read(data) else { problem = String(localized: "No QR code found in that picture."); return }
                read(s)
            }
        }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        .fullScreenCover(isPresented: $scanning) {
            NavigationStack {
                CodeScanner { s in scanning = false; read(s) }
                    .ignoresSafeArea()
                    .navigationTitle("Scan a code")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
            }
        }
        #endif
    }

    private func read(_ s: String) {
        if let l = MeshLink(s) { found = l; problem = nil } else { problem = String(localized: "That isn't a MeshCore contact, channel or network link.") }
    }

    @ViewBuilder private func result(_ link: MeshLink) -> some View {
        switch link {
        case .contact(let name, let key, let type):
            Section {
                LabeledContent("Name", value: name)
                LabeledContent("Type", value: "\(type)")
                LabeledContent("Key", value: String(key.hex.prefix(16)) + "…").font(.body.monospaced())
            } header: { Text("Contact") }
            Section {
                if model.contacts[key] != nil {
                    Label("In your contacts", systemImage: "checkmark.circle").foregroundStyle(.green)
                    if type == .companion || type == .room { Button("Message \(name)") { open(.direct(key)) } }
                } else {
                    Button { Task { await add(key: key, name: name, type: type) } } label: {
                        if busy { ProgressView() } else { Text("Add to contacts") }
                    }
                    .disabled(busy || !model.isConnected)
                }
                Button("Read another code") { found = nil; text = "" }
            } footer: {
                if model.contacts[key] == nil { Text("Saved on the radio. You can message them straight away.") }
            }
        case .channel(let name, let secret):
            Section {
                LabeledContent("Channel", value: name)
                LabeledContent("Secret", value: String(secret.hex.prefix(8)) + "…").font(.body.monospaced())
            } header: { Text("Channel") }
            Section {
                if let ch = model.channels.first(where: { $0.secret == secret }) {
                    Label("Joined", systemImage: "checkmark.circle").foregroundStyle(.green)
                    Button("Open \(ch.name)") { open(.channel(ch.index)) }
                } else {
                    Button { Task { await join(name: name, secret: secret) } } label: {
                        if busy { ProgressView() } else { Text("Join \(name)") }
                    }
                    .disabled(busy || !model.isConnected)
                }
                Button("Read another code") { found = nil; text = "" }
            }
        case .network(let p):
            Section {
                LabeledContent("Network", value: p.name)
                LabeledContent("Settings", value: p.radio.summary).font(.caption.monospacedDigit())
                if let tx = p.txPower { LabeledContent("Transmit power", value: "\(tx) dBm") }
                if let h = p.pathHashMode { LabeledContent("Path hashes", value: String(localized: "\(h + 1)-byte")) }
            } header: { Text("Network") }
            Section {
                if let have = model.radioProfiles.profiles.first(where: { RadioProfile.sameNetwork($0.radio, p.radio) && $0.txPower == p.txPower && $0.pathHashMode == p.pathHashMode }) {
                    Label("Saved as “\(have.name)”", systemImage: "checkmark.circle").foregroundStyle(.green)
                } else {
                    Button("Add to your networks") { model.radioProfiles.add(p); problem = nil; addedNetwork = true }
                        .disabled(addedNetwork)
                }
                Button("Read another code") { found = nil; text = ""; addedNetwork = false }
            } footer: {
                Text("Adding it doesn't change the radio: switch to it in Settings › Network.")
            }
        }
    }

    private func add(key: PublicKey, name: String, type: NodeType) async {
        busy = true; defer { busy = false }
        do { _ = try await model.engine.addContact(key: key, name: name, type: type); problem = nil }
        catch { problem = String(localized: "Not added: \(String(describing: error))") }
    }

    private func join(name: String, secret: Data) async {
        busy = true; defer { busy = false }
        do { let ch = try await model.engine.joinChannel(name: name, secret: secret); open(.channel(ch.index)) }
        catch { problem = String(localized: "Not joined: \(String(describing: error))") }
    }
}

/// QR codes in and out, with Core Image (no network).
enum QRCode {
    static func image(_ text: String) -> CGImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }

    static func read(_ imageData: Data) -> String? {
        guard let image = CIImage(data: imageData),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        else { return nil }
        return detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
}

func copyToClipboard(_ s: String) {
    #if os(iOS)
    UIPasteboard.general.string = s
    #elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
    #endif
}

#if os(iOS) && !targetEnvironment(macCatalyst)
/// The camera, reading QR codes with VisionKit: the first code found is returned.
struct CodeScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                           recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) { vc.stopScanning() }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        var done = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in added {
                if case .barcode(let b) = item, let s = b.payloadStringValue, !done {
                    done = true
                    found(s)
                }
            }
        }
    }
}
#endif
