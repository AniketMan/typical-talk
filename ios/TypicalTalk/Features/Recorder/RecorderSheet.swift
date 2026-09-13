import AVFoundation
import SwiftUI

/// The morphing recorder. One tap starts, one tap stops, the retake stack sits
/// underneath, and sending is a separate deliberate action.
struct RecorderSheet: View {
    let destination: Talk.ID
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var camera = CameraController()
    @State private var showGuides = true
    @State private var handsFree = false

    @State private var isSending = false
    @State private var countdown: Int?

    private var targetTalk: Talk? { store.talk(id: destination) }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.canvas.ignoresSafeArea()
                VStack(spacing: 14) {
                    viewfinder
                    controlBar
                    recordRow

                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            .navigationTitle("New take")
            .navigationSubtitle(targetTalk.map { "To \($0.title)" } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") {
                        camera.discardAll()
                        dismiss()
                    }
                }
            }
        }
        .task { await camera.prepare() }
        .onDisappear { camera.stop() }
        .alert("Recording problem", isPresented: .constant(camera.failure != nil)) {
            Button("OK") { }
        } message: {
            Text(camera.failure ?? "")
        }
    }

    // MARK: - Viewfinder

    private var viewfinder: some View {
        ZStack {
            switch camera.authorization {
            case .granted:
                if camera.cameraUnavailable {
                    Palette.raised.overlay {
                        VStack(spacing: 10) {
                            WaveformPlaceholder()
                            Text("No camera on this device. You can still record a voice-only Talk.")
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(Palette.secondaryText)
                                .padding(.horizontal, 28)
                        }
                    }
                } else if camera.voiceOnly {
                    Palette.raised.overlay { WaveformPlaceholder() }
                } else {
                    CameraPreview(camera: camera)
                }
            case .undetermined:
                Palette.raised.overlay { ProgressView() }
            case .denied:
                Palette.raised.overlay {
                    ContentUnavailableView {
                        Label("Camera is off", systemImage: "video.slash")
                    } description: {
                        Text("Turn on camera and microphone access to record a take.")
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.glass)
                    }
                }
            }

            if showGuides && !camera.voiceOnly && !camera.cameraUnavailable && camera.authorization == .granted {
                FramingGuides().transition(.opacity)
            }

            if isSending {
                Color.black.opacity(0.45)
                ProgressView("Sending")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .font(.caption)
            }

            if let countdown {
                Text("\(countdown)")
                    .font(.system(size: 84, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .aspectRatio(camera.supportsDynamicFraming && camera.framing == .landscape ? 16 / 9 : 9 / 13, contentMode: .fit)
        .animation(.snappy(duration: 0.3), value: camera.framing)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Scale.Radius.hero, style: .continuous))
        .overlay(alignment: .top) { hud }
        .overlay(
            RoundedRectangle(cornerRadius: Scale.Radius.hero, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 0.5)
        )
        // Hands-free: once you are rolling, a tap anywhere stops the take.
        .onTapGesture {
            if handsFree && camera.isRecording { camera.toggleRecording() }
        }
    }

    private var hud: some View {
        GlassEffectContainer(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(camera.isRecording ? Palette.record : .white.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text("\(timecode(camera.elapsed)) / \(timecode(camera.maximumDuration))")
                        .font(.caption2.monospacedDigit())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.clear, in: .capsule)

                Spacer()

                Button {
                    withAnimation(.snappy) { showGuides.toggle() }
                } label: {
                    Label(showGuides ? "Guides on" : "Guides off", systemImage: "grid")
                        .font(.caption2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .glassEffect(.clear.interactive(), in: .capsule)
                .disabled(camera.voiceOnly)
            }
            .padding(10)
        }
    }

    // MARK: - Controls

    private var controlBar: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 4) {
                toggle("3s lock", "timer", on: handsFree) {
                    handsFree.toggle()
                }
                toggle("Audio", "waveform", on: camera.voiceOnly) {
                    camera.voiceOnly.toggle()
                }
                .disabled(camera.cameraUnavailable)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
        }
    }

    private func toggle(_ title: String, _ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(on ? .white : .white.opacity(0.9))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background {
                    if on { Capsule().fill(Palette.record) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// The record button, with the camera switch beside it so both are under
    /// the same thumb.
    private var recordRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 56, height: 56)
            Spacer()
            recordButton
            Spacer()
            flipButton
        }
        .padding(.horizontal, 24)
    }

    private var flipButton: some View {
        Button {
            camera.flip()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(camera.voiceOnly || camera.cameraUnavailable)
        .opacity(camera.voiceOnly || camera.cameraUnavailable ? 0.35 : 1)
        .accessibilityLabel(camera.facing == .front ? "Switch to back camera" : "Switch to front camera")
    }

    /// The one tinted control in the whole app. One tap starts, one tap
    /// stops, and stopping sends.
    private var recordButton: some View {
        Button {
            Task { await tapRecord() }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.35), lineWidth: 3)
                    .frame(width: 78, height: 78)
                RoundedRectangle(cornerRadius: camera.isRecording ? 8 : 30, style: .continuous)
                    .fill(Palette.record)
                    .frame(
                        width: camera.isRecording ? 32 : 62,
                        height: camera.isRecording ? 32 : 62
                    )
            }
            .animation(.bouncy(duration: 0.3), value: camera.isRecording)
        }
        .buttonStyle(.plain)
        .disabled(camera.authorization != .granted || countdown != nil || isSending)
        .accessibilityLabel(camera.isRecording ? "Stop recording and send" : "Start recording")
    }

    private func tapRecord() async {
        if camera.isRecording {
            guard let take = await camera.finishAndWait() else { return }
            await send(take)
            return
        }
        if handsFree {
            for value in [3, 2, 1] {
                withAnimation(.snappy) { countdown = value }
                try? await Task.sleep(for: .seconds(1))
            }
            withAnimation(.snappy) { countdown = nil }
        }
        camera.toggleRecording()
    }

    // MARK: - Takes

    // MARK: - Sending

    private func send(_ take: CameraController.Take) async {
        isSending = true
        defer { isSending = false }
        // Transcribe before filing so the take is searchable the moment it
        // lands in the thread.
        let transcript = await Transcriber.segments(for: take.url)
        store.send(
            take: take.url,
            duration: take.duration,
            transcript: transcript,
            voiceOnly: take.voiceOnly,
            to: destination
        )
        dismiss()
    }
}

/// Rule of thirds plus a face-centering ellipse. Subtle, and dismissible.
struct FramingGuides: View {
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h / 3)); path.addLine(to: CGPoint(x: w, y: h / 3))
                    path.move(to: CGPoint(x: 0, y: 2 * h / 3)); path.addLine(to: CGPoint(x: w, y: 2 * h / 3))
                    path.move(to: CGPoint(x: w / 3, y: 0)); path.addLine(to: CGPoint(x: w / 3, y: h))
                    path.move(to: CGPoint(x: 2 * w / 3, y: 0)); path.addLine(to: CGPoint(x: 2 * w / 3, y: h))
                }
                .stroke(.white.opacity(0.16), style: StrokeStyle(lineWidth: 0.7, dash: [5, 5]))

                Ellipse()
                    .strokeBorder(.white.opacity(0.22), style: StrokeStyle(lineWidth: 0.8, dash: [5, 5]))
                    .frame(width: w * 0.54, height: h * 0.42)
                    .position(x: w / 2, y: h * 0.37)
            }
        }
        .allowsHitTesting(false)
    }
}

struct TakeChip: View {
    let take: CameraController.Take
    let isSelected: Bool
    var select: () -> Void
    var delete: () -> Void
    @State private var poster: UIImage?

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    if let poster {
                        Image(uiImage: poster).resizable().scaledToFill()
                    } else {
                        Palette.raised.overlay {
                            Image(systemName: take.voiceOnly ? "waveform" : "video")
                                .foregroundStyle(Palette.secondaryText)
                        }
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: Scale.Radius.thumbnail, style: .continuous))

                HStack {
                    Text(timecode(take.duration))
                        .font(.caption2.monospacedDigit())
                    Spacer()
                    Button(role: .destructive, action: delete) {
                        Image(systemName: "trash").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.secondaryText)
                }
            }
            .padding(8)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: Scale.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Scale.Radius.control, style: .continuous)
                    .strokeBorder(isSelected ? .white.opacity(0.7) : Palette.hairline, lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .task(id: take.id) { poster = await VideoPoster.firstFrame(of: take.url) }
    }
}
