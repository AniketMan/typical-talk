import AVFoundation
import SwiftUI

/// The morphing recorder. One tap starts, one tap stops, the retake stack sits
/// underneath, and sending is a separate deliberate action.
struct RecorderSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft = DraftRecorder.shared
    @State private var confirmDiscard = false
    @State private var sendError: String?

    private var camera: CameraController { draft.camera }
    @State private var showGuides = true
    @State private var handsFree = false

    @State private var isSending = false
    @State private var countdown: Int?

    private var targetTalk: Talk? { draft.talkID.flatMap { store.talk(id: $0) } }
    private var hasFootage: Bool { !draft.segments.isEmpty || camera.isRecording }

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
            .navigationTitle(draft.segments.isEmpty ? "New take" : "Draft")
            .navigationSubtitle(targetTalk.map { "To \($0.title)" } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Closing keeps what you recorded as a paused draft.
                    // Throwing it away is the trash button, on purpose.
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .task { await camera.prepare() }
        // However the recorder goes away, by the X or a swipe down, what was
        // recorded is kept and waits above the tab bar.
        .onDisappear { Task { await draft.recorderClosed() } }
        .confirmationDialog("Throw away this draft?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Throw away", role: .destructive) {
                draft.discard()
                dismiss()
            }
        } message: {
            Text("The \(timecode(draft.duration)) you recorded is deleted.")
        }
        .alert("Couldn't send", isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
            Button("OK") { sendError = nil }
        } message: {
            Text(sendError ?? "")
        }
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
                            Text("No camera on this device. You can still record a voice-only take.")
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
                    .tint(Palette.record)
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
                    Text("\(timecode(draft.duration + camera.elapsed)) / \(timecode(DraftRecorder.limit))")
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
            HStack(spacing: 10) {
                optionsPill
                flipButton
            }
        }
    }

    private var optionsPill: some View {
        HStack(spacing: 4) {
                toggle("3s lock", "timer", on: handsFree) {
                    handsFree.toggle()
                }
                toggle("Audio", "waveform", on: camera.voiceOnly) {
                    camera.voiceOnly.toggle()
                }
                // A take cannot switch between video and voice halfway.
                .disabled(camera.cameraUnavailable || hasFootage)
                effectsMenu
            }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .capsule)
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

    /// Apple's camera effects. Reactions are drawn into the video; the rest
    /// (Portrait, Studio Light, Center Stage, backgrounds) are switched on in
    /// the system's own Video Effects panel.
    private var effectsMenu: some View {
        Menu {
            let reactions = camera.availableReactions
            if !reactions.isEmpty {
                Section("Reactions") {
                    ForEach(reactions, id: \.rawValue) { reaction in
                        Button(Self.name(of: reaction), systemImage: reaction.systemImageName) {
                            camera.perform(reaction)
                        }
                    }
                }
            }
            Button("Video Effects", systemImage: "camera.filters") { camera.showVideoEffects() }
        } label: {
            Image(systemName: "sparkles")
                .font(.body)
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(camera.voiceOnly || camera.cameraUnavailable)
        .accessibilityLabel("Effects")
    }

    private static func name(of reaction: AVCaptureReactionType) -> String {
        switch reaction {
        case .heart: "Heart"
        case .thumbsUp: "Thumbs up"
        case .thumbsDown: "Thumbs down"
        case .balloons: "Balloons"
        case .confetti: "Confetti"
        case .fireworks: "Fireworks"
        case .rain: "Rain"
        case .lasers: "Lasers"
        default: "Reaction"
        }
    }

    /// Throw away on the left, record or pause in the middle, send on the
    /// right. Send and throw away only appear once there is something.
    private var recordRow: some View {
        HStack {
            Button {
                confirmDiscard = true
            } label: {
                Image(systemName: "trash")
                    .font(.body.weight(.semibold))
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .opacity(hasFootage && !camera.isRecording ? 1 : 0)
            .disabled(!hasFootage || camera.isRecording || isSending)
            .accessibilityLabel("Throw away draft")

            Spacer()
            recordButton
            Spacer()

            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Palette.record, in: .circle)
            }
            .buttonStyle(.plain)
            .opacity(hasFootage ? 1 : 0)
            .disabled(!hasFootage || isSending)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12)
    }

    /// The record button, with the camera switch beside it so both are under
    /// the same thumb.
    private var flipButton: some View {
        Button {
            camera.flip()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
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
        .disabled(camera.authorization != .granted || countdown != nil || isSending || (!camera.isRecording && draft.remaining < 0.5))
        .accessibilityLabel(camera.isRecording ? "Pause recording" : (draft.segments.isEmpty ? "Start recording" : "Resume recording"))
    }

    /// One tap records, the next pauses. Pausing keeps everything so far;
    /// recording again carries on from there.
    private func tapRecord() async {
        if camera.isRecording {
            await draft.pause()
            return
        }
        if handsFree {
            for value in [3, 2, 1] {
                withAnimation(.snappy) { countdown = value }
                try? await Task.sleep(for: .seconds(1))
            }
            withAnimation(.snappy) { countdown = nil }
        }
        draft.startSegment()
    }

    // MARK: - Sending

    private func send() async {
        guard let destination = draft.talkID else { return }
        isSending = true
        defer { isSending = false }
        await draft.pause()
        guard let joined = await draft.assemble() else {
            sendError = "The recording could not be put together. Your draft is still here."
            return
        }
        // Transcribe before filing so the take is searchable the moment it
        // lands in the thread.
        let transcript = await Transcriber.segments(for: joined.url)
        store.send(
            take: joined.url,
            duration: joined.duration,
            transcript: transcript,
            voiceOnly: draft.isVoiceOnly,
            to: destination
        )
        draft.finishSent()
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
