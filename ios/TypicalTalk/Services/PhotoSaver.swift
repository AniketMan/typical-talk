import Photos

/// Saves a take to the photo library. Add-only access: the app can put videos
/// in, and never sees what else is there.
enum PhotoSaver {
    static func save(_ url: URL) async -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return "Typical Take is not allowed to add to Photos. You can change that in Settings."
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            return nil
        } catch {
            return "Could not save to Photos: \(error.localizedDescription)"
        }
    }
}
