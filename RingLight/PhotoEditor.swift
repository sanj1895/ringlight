import SwiftUI
import Photos
import CoreImage
import CoreImage.CIFilterBuiltins

/// The edits the editor can make. Saved with the photo, so reopening the editor
/// picks up where you left off, and Photos' "Revert" can undo them.
struct PhotoEdits: Codable, Equatable {
    var exposure: Double = 0     // -1...1 stops
    var contrast: Double = 1     // 0.6...1.4
    var saturation: Double = 1   // 0...2
    var warmth: Double = 0       // -1 (cool)...1 (warm)
    var look: Look = .normal
    var quarterTurns = 0         // rotations 90° to the left

    static let format = "com.sanjanaa.ringlight.edits"
    static let version = "2"

    func apply(to image: CIImage, forSaving: Bool) -> CIImage {
        var img = image
        switch quarterTurns % 4 {
        case 1: img = img.oriented(.left)
        case 2: img = img.oriented(.down)
        case 3: img = img.oriented(.right)
        default: break
        }

        let exposureFilter = CIFilter.exposureAdjust()
        exposureFilter.inputImage = img
        exposureFilter.ev = Float(exposure)
        img = exposureFilter.outputImage ?? img

        let color = CIFilter.colorControls()
        color.inputImage = img
        color.contrast = Float(contrast)
        color.saturation = Float(saturation)
        img = color.outputImage ?? img

        let temperature = CIFilter.temperatureAndTint()
        temperature.inputImage = img
        temperature.neutral = CIVector(x: 6500, y: 0)
        temperature.targetNeutral = CIVector(x: 6500 - warmth * 1500, y: 0)  // lower = warmer
        img = temperature.outputImage ?? img

        if look != .normal {
            img = look.apply(to: img, outputLongSide: forSaving ? look.photoLongSide : nil)
            if look == .polaroid { img = Look.polaroidFrame(img) }
        }
        return img
    }
}

struct PhotoEditor: View {
    let asset: PHAsset
    var onDone: () -> Void

    @State private var input: PHContentEditingInput?
    @State private var source: CIImage?   // screen-sized copy for the live preview
    @State private var edits = PhotoEdits()
    @State private var preview: UIImage?
    @State private var renderCount = 0
    @State private var saving = false
    @State private var failed = false

    private static let renderQueue = DispatchQueue(label: "ringlight.editor")

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFit()
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                controls
            }
            .background(Color.black)
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDone)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save", action: save).bold().disabled(input == nil)
                    }
                }
            }
            .alert("Couldn't save the edit", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
        .task { load() }
        .onChange(of: edits) { _, _ in render() }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            slider("Brightness", "sun.max", value: $edits.exposure, range: -1...1)
            slider("Contrast", "circle.lefthalf.filled", value: $edits.contrast, range: 0.6...1.4)
            slider("Color", "drop", value: $edits.saturation, range: 0...2)
            slider("Warmth", "thermometer.medium", value: $edits.warmth, range: -1...1)
            HStack(spacing: 12) {
                Picker(selection: $edits.look) {
                    ForEach(Look.allCases) { look in
                        Label(look.name, systemImage: look.icon).tag(look)
                    }
                } label: {
                    Label("Look", systemImage: "camera.filters")
                }
                .pickerStyle(.menu)
                Button {
                    edits.quarterTurns = (edits.quarterTurns + 1) % 4
                } label: {
                    Label("Rotate", systemImage: "rotate.left")
                }
                Spacer()
                Button("Reset") { edits = PhotoEdits() }
                    .disabled(edits == PhotoEdits())
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color(white: 0.1))
    }

    private func slider(_ title: String, _ icon: String, value: Binding<Double>,
                        range: ClosedRange<Double>) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .frame(width: 130, alignment: .leading)
            Slider(value: value, in: range)
        }
        .font(.subheadline)
        .foregroundStyle(.white)
    }

    // MARK: - Loading, previewing, saving

    private func load() {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        // If we edited this photo before, start from the original and restore the sliders.
        options.canHandleAdjustmentData = { data in
            data.formatIdentifier == PhotoEdits.format && data.formatVersion == PhotoEdits.version
        }
        asset.requestContentEditingInput(with: options) { input, _ in
            guard let input, let url = input.fullSizeImageURL,
                  let full = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                failed = true
                return
            }
            if let data = input.adjustmentData, data.formatIdentifier == PhotoEdits.format,
               let saved = try? JSONDecoder().decode(PhotoEdits.self, from: data.data) {
                edits = saved
            }
            let scale = min(1, 1600 / max(full.extent.width, full.extent.height))
            source = full.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            self.input = input
            render()
        }
    }

    private func render() {
        guard let source else { return }
        renderCount += 1
        let ticket = renderCount
        let edits = edits
        Self.renderQueue.async {
            let output = edits.apply(to: source, forSaving: false)
            guard let cg = Look.context.createCGImage(output, from: output.extent) else { return }
            DispatchQueue.main.async {
                if ticket == renderCount { preview = UIImage(cgImage: cg) }  // skip stale renders
            }
        }
    }

    private func save() {
        guard let input, let url = input.fullSizeImageURL else { return }
        saving = true
        let edits = edits
        Self.renderQueue.async {
            let output = PHContentEditingOutput(contentEditingInput: input)
            guard let full = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
                  let data = try? JSONEncoder().encode(edits) else { return finish(false) }
            output.adjustmentData = PHAdjustmentData(formatIdentifier: PhotoEdits.format,
                                                     formatVersion: PhotoEdits.version, data: data)
            // Rotation is baked into the pixels, so drop the old orientation tag.
            let edited = edits.apply(to: full, forSaving: true).settingProperties([:])
            let space = full.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            do {
                try Look.context.writeJPEGRepresentation(of: edited, to: output.renderedContentURL,
                                                            colorSpace: space, options: [:])
            } catch {
                return finish(false)
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest(for: asset).contentEditingOutput = output
            }) { saved, _ in
                finish(saved)
            }
        }
    }

    private func finish(_ saved: Bool) {
        DispatchQueue.main.async {
            saving = false
            if saved {
                CaptureLibrary.shared.reload()
                onDone()
            } else {
                failed = true
            }
        }
    }
}
