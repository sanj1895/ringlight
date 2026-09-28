import SwiftUI
import UIKit
import AVKit
import PhotosUI

struct RingPreset: Identifiable {
    let name: String
    let color: Color
    var id: String { name }
}

private let presets: [RingPreset] = [
    RingPreset(name: "White", color: .white),
    // Snapchat's warm (#FFECBB) and cool (#D7F8FF).
    RingPreset(name: "Warm", color: Color(red: 1.00, green: 0.925, blue: 0.733)),
    RingPreset(name: "Cool", color: Color(red: 0.843, green: 0.973, blue: 1.00)),
    RingPreset(name: "Pink", color: Color(red: 1.00, green: 0.62, blue: 0.80)),
    RingPreset(name: "Peach", color: Color(red: 1.00, green: 0.72, blue: 0.58)),
    RingPreset(name: "Lavender", color: Color(red: 0.78, green: 0.68, blue: 1.00)),
    RingPreset(name: "Blue", color: Color(red: 0.35, green: 0.60, blue: 1.00)),
    RingPreset(name: "Red", color: Color(red: 1.00, green: 0.25, blue: 0.30)),
]

/// Where the camera preview sits inside the safe area: the exact shape of what gets saved,
/// as wide as the screen, just under the color bar. Nothing is cropped, so the preview
/// shows everything that gets saved.
enum PreviewLayout {
    static let topBar: CGFloat = 66

    static func rect(in safe: CGSize, aspect: CGFloat) -> CGRect {
        var width = safe.width
        var height = width / aspect
        if height > safe.height {
            height = safe.height
            width = height * aspect
        }
        let top = max(0, min(topBar, safe.height - height))
        return CGRect(x: (safe.width - width) / 2, y: top, width: width, height: height)
    }
}

/// Controls sit on top of the light, so they're dark-on-light and see-through.
private let ink = Color.black.opacity(0.8)
private let chip = Color.white.opacity(0.45)

struct ContentView: View {
    @StateObject private var camera = CameraModel()
    @ObservedObject private var library = CaptureLibrary.shared
    @ObservedObject private var tray = PrintTray.shared
    @StateObject private var developer = PrintDeveloper()
    @State private var showGallery = false
    @State private var showBackdropPicker = false
    @State private var backdropItem: PhotosPickerItem?
    @Environment(\.scenePhase) private var scenePhase

    @State private var ringOn = true
    @State private var ringColor: Color = .white
    @State private var selectedPreset: String? = "White"
    /// How far the glow reaches in from the edges (0...1), like Snapchat's slider.
    @State private var ringIntensity: Double = 0.4
    @State private var showControls = true
    @State private var shutterBlink = false
    @State private var pressing = false
    @State private var savedBrightness: CGFloat?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // The camera, in the exact shape of what gets saved...
            GeometryReader { geo in
                let rect = PreviewLayout.rect(in: geo.size, aspect: camera.previewAspect)
                Group {
                    if camera.mode == .shake {
                        // SHAKE: an old instant camera. You aim with its selfie mirror or viewfinder.
                        InstantCamera(isFront: camera.isFront, source: camera.frameSource(),
                                      shotCount: camera.shotCount, ejecting: tray.ejecting != nil,
                                      onEjected: { tray.ejecting = nil })
                            .overlay { countdownOverlay }
                            .contentShape(Rectangle())
                            .onTapGesture { showControls.toggle() }
                    } else {
                        preview(size: rect.size)
                    }
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            }

            // ...inside Snapchat-style ring light. It lights your face while you frame
            // the shot, so what you see is what you get.
            if ringOn {
                GlowView(color: ringColor, intensity: ringIntensity, aspect: camera.previewAspect)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // SHAKE: the print that just came out, developing as you shake.
            if camera.mode == .shake, let front = tray.front, tray.ejecting != front.id {
                DevelopingPrint(developer: developer) {
                    withAnimation(.spring) { tray.front = nil }
                }
                .id(front.id)
                .offset(y: 30)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }

            VStack(spacing: 10) {
                if showControls {
                    VStack(spacing: 8) {
                        if ringOn { colorBar }
                        quickToggles
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                statusBadge
                Spacer()
                if showControls {
                    VStack(spacing: 10) {
                        if ringOn { ringSlider }
                        modePicker
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                HStack {
                    if camera.mode == .shake, !tray.waiting.isEmpty, tray.front == nil {
                        printPile
                    } else {
                        galleryButton
                    }
                    Spacer()
                    shutterButton
                    Spacer()
                    flipButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .overlay(alignment: .top) { toast }
        .overlay(alignment: .trailing) {
            if camera.look == .fisheye, showControls {
                fisheyeSlider
                    .padding(.trailing, 10)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: camera.look)
        .photosPicker(isPresented: $showBackdropPicker, selection: $backdropItem, matching: .images)
        .onChange(of: backdropItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { camera.setCustomBackdrop(data) }
                backdropItem = nil
            }
        }
        .fullScreenCover(isPresented: $showGallery) {
            GalleryView(library: library) { showGallery = false }
        }
        .sheet(isPresented: Binding(get: { !camera.burstShots.isEmpty },
                                    set: { if !$0 { camera.burstShots = [] } })) {
            BurstPicker(shots: camera.burstShots,
                        onKeep: { camera.keepBurstShots($0) },
                        onDiscard: { camera.burstShots = [] })
        }
        // Volume buttons work as the shutter (hold for burst).
        .onCameraCaptureEvent(isEnabled: !showGallery && camera.burstShots.isEmpty) { event in
            switch event.phase {
            case .began: camera.shutterDown()
            case .ended: camera.shutterUp()
            default: break
            }
        }
        .animation(.easeOut(duration: 0.2), value: camera.mode)
        .animation(.easeInOut(duration: 0.25), value: showControls)
        .animation(.easeInOut(duration: 0.25), value: ringOn)
        .animation(.easeInOut(duration: 0.25), value: camera.toast)
        .animation(.spring(duration: 0.5), value: tray.front)
        .onChange(of: tray.front) { _, front in
            developer.show(camera.mode == .shake ? front : nil)
        }
        .onChange(of: camera.mode) { _, mode in
            developer.show(mode == .shake ? tray.front : nil)
        }
        .onChange(of: selectedPreset) { _, preset in
            camera.setColoredLight(ringOn && preset != "White")
        }
        .onChange(of: ringOn) { _, on in
            camera.setColoredLight(on && selectedPreset != "White")
            if on { lightOn() } else { lightOff() }
        }
        .onChange(of: camera.shotCount) { _, _ in blinkPreview() }
        .onAppear {
            camera.start()
            if ringOn { lightOn() }
            developer.onDeveloped = { print in
                // Let "Developed ✓" show for a moment, then save it and clear it away.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { camera.saveDevelopedPrint(print) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                camera.start()
                if ringOn { lightOn() }
            case .background:
                camera.stop()
                lightOff()
            default:
                break
            }
        }
    }

    // MARK: - Preview

    private func preview(size: CGSize) -> some View {
        CameraPreview(source: camera.frameSource(), look: camera.previewLook, dateStamp: camera.previewDateStamp)
            .opacity(shutterBlink ? 0.3 : 1)
            .overlay { countdownOverlay }
            .contentShape(Rectangle())
            .onTapGesture { showControls.toggle() }
            // In dual PiP, drag anywhere to move your selfie bubble.
            .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                guard camera.mode.isDual, camera.dualLayout == .pip else { return }
                camera.pipCenter = CGPoint(x: min(max(value.location.x / size.width, 0), 1),
                                           y: min(max(value.location.y / size.height, 0), 1))
            })
    }

    @ViewBuilder
    private var countdownOverlay: some View {
        Group {
            if let count = camera.countdown {
                Text("\(count)")
                    .font(.system(size: 120, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 10)
                    .contentTransition(.numericText(countsDown: true))
            } else if camera.cameraDenied {
                Text("Camera access is off.\nTurn it on in Settings → Ring Light.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding()
            }
        }
        .animation(.snappy, value: camera.countdown)
    }

    /// Recording time, booth/collage progress ("2/4") or burst count.
    @ViewBuilder
    private var statusBadge: some View {
        if let start = camera.recordingStart {
            TimelineView(.periodic(from: start, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(start)))
                badge(dot: true, String(format: "%d:%02d", seconds / 60, seconds % 60))
            }
        } else if let progress = camera.progress {
            badge(dot: progress == "●", progress == "●" ? "REC" : progress)
        }
    }

    private func badge(dot: Bool, _ text: String) -> some View {
        HStack(spacing: 6) {
            if dot { Circle().fill(.red).frame(width: 8, height: 8) }
            Text(text).font(.system(.subheadline, design: .monospaced).weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
    }

    // MARK: - Top controls

    private var colorBar: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(presets) { preset in
                        Button {
                            ringColor = preset.color
                            selectedPreset = preset.name
                        } label: {
                            Circle()
                                .fill(preset.color)
                                .frame(width: 34, height: 34)
                                .overlay(Circle().stroke(ink, lineWidth: selectedPreset == preset.name ? 3 : 0))
                                .overlay(Circle().stroke(.black.opacity(0.2), lineWidth: 1))
                                .padding(2)
                        }
                        .accessibilityLabel(preset.name)
                    }
                }
                .padding(.horizontal, 4)
            }

            ColorPicker("Custom color",
                        selection: Binding(get: { ringColor },
                                           set: { ringColor = $0; selectedPreset = nil }),
                        supportsOpacity: false)
                .labelsHidden()
        }
        .padding(8)
        .padding(.trailing, 4)
        .background(chip, in: Capsule())
    }

    /// Ring light on/off, timer, flash, date stamp, look, and the current mode's option.
    private var quickToggles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                toggleChip(ringOn ? "lightbulb.fill" : "lightbulb.slash", on: ringOn,
                           label: ringOn ? "Ring light on" : "Ring light off") { ringOn.toggle() }

                if camera.mode.usesTimer {
                    toggleChip("timer", text: camera.timer == 0 ? nil : "\(camera.timer)s", on: camera.timer > 0,
                               label: "Timer") {
                        camera.timer = camera.timer == 0 ? 3 : camera.timer == 3 ? 10 : 0
                    }
                }

                if camera.flashAvailable {
                    toggleChip(camera.flash == .off ? "bolt.slash" : camera.flash == .on ? "bolt.fill" : "bolt",
                               text: camera.flash == .auto ? "A" : nil, on: camera.flash != .off,
                               label: camera.flash == .off ? "Flash off" : camera.flash == .on ? "Flash on" : "Flash auto") {
                        camera.flash = camera.flash.next
                    }
                }

                toggleChip("calendar", on: camera.dateStamp, label: "Date stamp") { camera.dateStamp.toggle() }

                Menu {
                    Picker("Look", selection: $camera.look) {
                        ForEach(Look.allCases) { look in
                            Label(look.name, systemImage: look.icon).tag(look)
                        }
                    }
                } label: {
                    chipLabel(camera.look.icon, text: camera.look.name, on: camera.look != .normal)
                }

                modeOption
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .disabled(camera.isRecording || camera.busy)
    }

    /// Backdrop picker, collage 2/4, dual PiP/Split, or 0.5×/1× on the back camera.
    @ViewBuilder
    private var modeOption: some View {
        if camera.mode == .backdrop {
            Menu {
                ForEach(Backdrop.builtIn) { backdrop in
                    Button {
                        camera.backdrop = backdrop
                    } label: {
                        if camera.backdrop == backdrop { Label(backdrop.name, systemImage: "checkmark") } else { Text(backdrop.name) }
                    }
                }
                if camera.customBackdrop != nil {
                    Button {
                        camera.backdrop = .yourPhoto
                    } label: {
                        if camera.backdrop == .yourPhoto { Label("Your photo", systemImage: "checkmark") } else { Text("Your photo") }
                    }
                }
                Divider()
                Button {
                    showBackdropPicker = true
                } label: {
                    Label("Choose from Photos…", systemImage: "photo.on.rectangle")
                }
            } label: {
                chipLabel("photo.artframe", text: camera.backdrop.name, on: true)
            }
        }
        if camera.mode == .collage {
            toggleChip("square.grid.2x2", text: "\(camera.collageCount)", on: true, label: "Number of shots") {
                camera.collageCount = camera.collageCount == 4 ? 2 : 4
            }
        } else if camera.mode.isDual {
            toggleChip(camera.dualLayout == .pip ? "pip" : "rectangle.split.1x2", text: camera.dualLayout.rawValue,
                       on: true, label: "Dual layout") {
                camera.dualLayout = camera.dualLayout == .pip ? .split : .pip
            }
        } else if !camera.isFront {
            toggleChip(nil, text: camera.ultraWide ? "0.5×" : "1×", on: camera.ultraWide, label: "Lens") {
                camera.toggleUltraWide()
            }
        }
    }

    private func toggleChip(_ icon: String?, text: String? = nil, on: Bool, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(icon, text: text, on: on) }
            .accessibilityLabel(label)
    }

    private func chipLabel(_ icon: String?, text: String? = nil, on: Bool) -> some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            if let text { Text(text).font(.caption.weight(.bold)) }
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(on ? .white : ink)
        .padding(.horizontal, 11)
        .frame(minWidth: 38, minHeight: 38)
        .background(on ? ink : chip, in: Capsule())
    }

    // MARK: - Bottom controls

    /// Fisheye strength, on the side of the screen: up = bulgier.
    private var fisheyeSlider: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.circle.fill")
            Slider(value: $camera.fisheyeStrength, in: 0...1)
                .frame(width: 170)
                .rotationEffect(.degrees(-90))
                .frame(width: 30, height: 170)
            Image(systemName: "circle")
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(ink)
        .tint(ink)
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .background(chip, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fisheye strength")
    }

    /// More intensity = the glow reaches further in = more light on your face.
    private var ringSlider: some View {
        HStack(spacing: 12) {
            Image(systemName: "light.min")
            Slider(value: $ringIntensity, in: 0...1)
            Image(systemName: "light.max")
        }
        .foregroundStyle(ink)
        .tint(ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(chip, in: Capsule())
    }

    private var modePicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(CaptureMode.allCases) { mode in
                        Button {
                            camera.setMode(mode)
                        } label: {
                            Text(mode.rawValue)
                                .font(.footnote.weight(.bold))
                                .tracking(1)
                                .foregroundStyle(camera.mode == mode ? .white : ink)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(camera.mode == mode ? ink : Color.clear, in: Capsule())
                        }
                        .id(mode)
                    }
                }
                .padding(4)
            }
            .background(chip, in: Capsule())
            .onChange(of: camera.mode) { _, mode in
                withAnimation { proxy.scrollTo(mode, anchor: .center) }
            }
        }
        .disabled(camera.isRecording || camera.busy)
        .opacity(camera.isRecording || camera.busy ? 0.4 : 1)
    }

    /// Tap to shoot; hold in BURST mode. Red for modes you start and stop.
    private var shutterButton: some View {
        ZStack {
            Circle().stroke(ink, lineWidth: 5).frame(width: 76, height: 76)
            if camera.mode.records {
                RoundedRectangle(cornerRadius: camera.isRecording ? 8 : 31, style: .continuous)
                    .fill(.red)
                    .frame(width: camera.isRecording ? 30 : 62, height: camera.isRecording ? 30 : 62)
            } else {
                Circle().fill(.white).frame(width: pressing ? 56 : 62, height: pressing ? 56 : 62)
                    .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 1))
                    .overlay { shutterIcon }
            }
        }
        .frame(width: 90, height: 90)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !pressing else { return }
                pressing = true
                camera.shutterDown()
            }
            .onEnded { _ in
                pressing = false
                camera.shutterUp()
            })
        .animation(.spring(duration: 0.25), value: camera.isRecording)
        .animation(.spring(duration: 0.15), value: pressing)
        .accessibilityElement()
        .accessibilityLabel(camera.mode.records ? (camera.isRecording ? "Stop recording" : "Start recording")
                                                : "Shutter")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { camera.shutterDown(); camera.shutterUp() }
    }

    @ViewBuilder
    private var shutterIcon: some View {
        switch camera.mode {
        case .boomerang: Image(systemName: "infinity").font(.title3.weight(.bold)).foregroundStyle(ink)
        case .gif: Text("GIF").font(.caption.weight(.heavy)).foregroundStyle(ink)
        case .booth: Image(systemName: "person.crop.square.on.square.angled").foregroundStyle(ink)
        case .collage: Image(systemName: "square.grid.2x2").foregroundStyle(ink)
        case .burst: Text(pressing ? (camera.progress ?? "") : "HOLD").font(.caption2.weight(.heavy)).foregroundStyle(ink)
        default: EmptyView()
        }
    }

    /// SHAKE: undeveloped prints waiting on the pile. Tap to take one out and develop it.
    private var printPile: some View {
        Button {
            tray.pickUp()
        } label: {
            ZStack {
                ForEach(0..<min(tray.waiting.count, 3), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: 0.96, green: 0.95, blue: 0.92))
                        .overlay(Rectangle().fill(Color(red: 0.13, green: 0.14, blue: 0.12)).padding(5).padding(.bottom, 10))
                        .frame(width: 38, height: 50)
                        .rotationEffect(.degrees(Double(index) * 7 - 7))
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                }
                Text("\(tray.waiting.count)")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Circle().fill(.red))
                    .offset(x: 22, y: -26)
            }
            .frame(width: 54, height: 54)
        }
        .accessibilityLabel("\(tray.waiting.count) prints to develop")
    }

    /// Your latest shot; opens the in-app gallery.
    private var galleryButton: some View {
        Button {
            showGallery = true
        } label: {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(chip)
                .frame(width: 54, height: 54)
                .overlay {
                    if let thumbnail = library.latestThumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo.on.rectangle").foregroundStyle(ink)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ink, lineWidth: 2))
        }
        .accessibilityLabel("Gallery")
    }

    private var flipButton: some View {
        let disabled = camera.isRecording || camera.busy || camera.mode.isDual
        return Button {
            camera.flipCamera()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: 54, height: 54)
                .background(chip, in: Circle())
        }
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityLabel(camera.isFront ? "Switch to back camera" : "Switch to front camera")
    }

    @ViewBuilder
    private var toast: some View {
        if let message = camera.toast {
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.7), in: Capsule())
                .padding(.top, 70)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Helpers

    /// A quick dip of the preview so you know a shot was taken.
    private func blinkPreview() {
        withAnimation(.easeIn(duration: 0.05)) { shutterBlink = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeOut(duration: 0.2)) { shutterBlink = false }
        }
    }

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen
    }

    /// Max out the screen so the light actually lights your face.
    private func lightOn() {
        guard let screen else { return }
        if savedBrightness == nil { savedBrightness = screen.brightness }
        screen.brightness = 1.0
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func lightOff() {
        if let savedBrightness, let screen { screen.brightness = savedBrightness }
        savedBrightness = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
