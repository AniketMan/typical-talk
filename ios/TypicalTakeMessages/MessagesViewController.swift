@preconcurrency import AVFoundation
import Messages
import Security
import SwiftUI
import UIKit

/// Typical Take inside Messages.
///
/// Record a take here and it goes into the conversation as a bubble. Whoever
/// taps it with the app installed is taken into the app, where the take lands
/// in their one to one conversation with you. Without the app, the bubble's
/// link opens a page that plays it.
final class MessagesViewController: MSMessagesAppViewController {
    private let model = MessagesModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.requestExpanded = { [weak self] in self?.requestPresentationStyle(.expanded) }
        model.insert = { [weak self] message in
            guard let conversation = self?.activeConversation else { return }
            conversation.insert(message) { _ in }
            self?.requestPresentationStyle(.compact)
        }
        let host = UIHostingController(rootView: MessagesRoot(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }

    override func willBecomeActive(with conversation: MSConversation) {
        model.style = presentationStyle
        openIfTapped(conversation.selectedMessage)
    }

    override func didSelect(_ message: MSMessage, conversation: MSConversation) {
        openIfTapped(message)
    }

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        model.style = presentationStyle
        if presentationStyle == .compact { model.camera.stop() }
    }

    override func didResignActive(with conversation: MSConversation) {
        model.camera.stop()
    }

    /// Someone tapped a take bubble: hand them to the app, which files the
    /// take into their conversation with the sender.
    private func openIfTapped(_ message: MSMessage?) {
        guard let url = message?.url,
              let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value
                ?? url.pathComponents.last,
              let app = URL(string: "typicaltalk://share/\(code)") else { return }
        model.opening = true
        extensionContext?.open(app) { [weak self] opened in
            Task { @MainActor in
                self?.model.opening = false
                if !opened { self?.model.problem = "Install Typical Take to watch this take." }
            }
        }
    }
}

// MARK: - Model

@MainActor
@Observable
final class MessagesModel {
    var style: MSMessagesAppPresentationStyle = .compact
    var recorded: URL?
    var recordedDuration: Double = 0
    var isSending = false
    var opening = false
    var problem: String?
    let camera = SimpleCamera()

    var requestExpanded: () -> Void = {}
    var insert: (MSMessage) -> Void = { _ in }

    /// Uploads the take, then puts a bubble in the conversation for the
    /// person to send. Apple does not let an app send on someone's behalf.
    func send() async {
        guard let file = recorded else { return }
        guard let session = SharedSession.read() else {
            problem = "Open Typical Take and sign in first."
            return
        }
        isSending = true
        defer { isSending = false }

        var request = URLRequest(url: URL(string: session.apiBase)!.appending(path: "/v1/shares"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        request.setValue("video/quicktime", forHTTPHeaderField: "Content-Type")
        request.setValue(String(format: "%.2f", recordedDuration), forHTTPHeaderField: "x-take-duration")

        struct Created: Decodable { let code: String; let url: String }
        guard let (data, response) = try? await URLSession.shared.upload(for: request, fromFile: file),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let created = try? JSONDecoder().decode(Created.self, from: data),
              var link = URLComponents(string: created.url) else {
            problem = "That take could not be sent. Try again."
            return
        }
        link.queryItems = [URLQueryItem(name: "code", value: created.code)]

        let layout = MSMessageTemplateLayout()
        layout.image = await Self.poster(of: file)
        layout.caption = "A take"
        layout.subcaption = "\(Int(recordedDuration.rounded()))s · Typical Take"
        let message = MSMessage(session: MSSession())
        message.layout = layout
        message.url = link.url
        message.summaryText = "Sent a take"

        try? FileManager.default.removeItem(at: file)
        recorded = nil
        insert(message)
    }

    func discard() {
        if let recorded { try? FileManager.default.removeItem(at: recorded) }
        recorded = nil
    }

    private static func poster(of url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        guard let image = try? await generator.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)).image else { return nil }
        return UIImage(cgImage: image)
    }
}

/// The session the app shares through the Keychain group.
enum SharedSession {
    struct Value: Decodable { var token: String; var userID: String; var apiBase: String }

    static func read() -> Value? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.typicaltalk.widget",
            kSecAttrAccessGroup as String: "5BF427L96N.com.typicaltalk.TypicalTalk.shared",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }
}

// MARK: - Camera

/// A small recorder for the extension: front camera, one take, a minute at
/// most. The full recorder with drafts lives in the app.
@MainActor
@Observable
final class SimpleCamera: NSObject, AVCaptureFileOutputRecordingDelegate {
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "com.typicaltalk.messages.capture")
    private var configured = false
    private(set) var isRecording = false
    private(set) var elapsed: Double = 0
    private(set) var authorized = false
    private var timer: Timer?
    private var startedAt: Date?
    var finished: ((URL, Double) -> Void)?

    static let limit: Double = 60

    func start() async {
        let video = await AVCaptureDevice.requestAccess(for: .video)
        let audio = await AVCaptureDevice.requestAccess(for: .audio)
        authorized = video && audio
        guard authorized else { return }
        if !configured {
            configured = true
            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            let mic = AVCaptureDevice.default(for: .audio)
            let inputs = [camera, mic].compactMap { $0 }.compactMap { try? AVCaptureDeviceInput(device: $0) }
            queue.async { [session, output] in
                session.beginConfiguration()
                session.sessionPreset = .high
                for input in inputs where session.canAddInput(input) { session.addInput(input) }
                if session.canAddOutput(output) { session.addOutput(output) }
                if let connection = output.connection(with: .video) {
                    if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                    if connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = false
                    }
                }
                session.commitConfiguration()
                session.startRunning()
            }
        } else {
            queue.async { [session] in if !session.isRunning { session.startRunning() } }
        }
    }

    func stop() {
        if isRecording { output.stopRecording() }
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    func toggle() {
        if isRecording {
            output.stopRecording()
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("message-\(UUID().uuidString).mov")
        output.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        startedAt = .now
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date.now.timeIntervalSince(startedAt)
                if self.elapsed >= Self.limit, self.isRecording { self.output.stopRecording() }
            }
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: (any Error)?) {
        Task { @MainActor in
            self.timer?.invalidate()
            self.isRecording = false
            let length = self.elapsed
            if length > 0.5 { self.finished?(url, length) } else { try? FileManager.default.removeItem(at: url) }
        }
    }
}

struct CameraLayer: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - Views

private let record = Color(red: 1.0, green: 0.325, blue: 0.435)

struct MessagesRoot: View {
    @Bindable var model: MessagesModel

    var body: some View {
        Group {
            if model.opening {
                ProgressView("Opening Typical Take")
            } else if model.style == .compact {
                compact
            } else {
                RecorderView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Typical Take", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK") { model.problem = nil }
        } message: {
            Text(model.problem ?? "")
        }
    }

    private var compact: some View {
        Button {
            model.requestExpanded()
        } label: {
            Label("Record a take", systemImage: "video.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(record, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

struct RecorderView: View {
    @Bindable var model: MessagesModel

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                if let file = model.recorded {
                    RecordedPreview(url: file)
                } else {
                    CameraLayer(session: model.camera.session)
                }
            }
            .aspectRatio(3 / 4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(alignment: .top) {
                if model.camera.isRecording {
                    Text("\(Int(model.camera.elapsed))s / \(Int(SimpleCamera.limit))s")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.5), in: .capsule)
                        .padding(10)
                }
            }

            HStack(spacing: 40) {
                if model.recorded != nil {
                    Button("Retake", systemImage: "arrow.counterclockwise") { model.discard() }
                        .labelStyle(.iconOnly).font(.title2)
                    Button {
                        Task { await model.send() }
                    } label: {
                        Group {
                            if model.isSending { ProgressView().tint(.white) } else { Image(systemName: "arrow.up").font(.title2.weight(.bold)) }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(record, in: .circle)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isSending)
                    .accessibilityLabel("Send")
                } else {
                    Button { model.camera.toggle() } label: {
                        ZStack {
                            Circle().strokeBorder(.white.opacity(0.4), lineWidth: 3).frame(width: 74, height: 74)
                            RoundedRectangle(cornerRadius: model.camera.isRecording ? 8 : 28, style: .continuous)
                                .fill(record)
                                .frame(width: model.camera.isRecording ? 30 : 58, height: model.camera.isRecording ? 30 : 58)
                        }
                        .animation(.bouncy(duration: 0.3), value: model.camera.isRecording)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.camera.authorized)
                    .accessibilityLabel(model.camera.isRecording ? "Stop" : "Record")
                }
            }
        }
        .padding(16)
        .task {
            model.camera.finished = { [weak model] url, length in
                model?.recorded = url
                model?.recordedDuration = length
            }
            await model.camera.start()
        }
    }
}

/// Plays back what was just recorded, on a loop, before sending.
struct RecordedPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        let player = AVQueuePlayer()
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        player.play()
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var looper: AVPlayerLooper? }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
