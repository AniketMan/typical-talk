import SwiftUI
import UIKit

/// Profile photos, fetched once per version and kept on disk.
///
/// A photo's version changes when its owner picks a new one, so the cache key
/// carries it and an old photo is never shown for a new version.
@MainActor
enum AvatarCache {
    private static let memory = NSCache<NSString, UIImage>()

    private static let directory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func image(for userID: UUID, version: Int, token: String) async -> UIImage? {
        let id = userID.uuidString.lowercased()
        let key = "\(id)-\(version)"
        if let hit = memory.object(forKey: key as NSString) { return hit }

        let file = directory.appendingPathComponent("\(key).jpg")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }

        guard let data = await TalkAPI.avatarData(for: id, version: version, token: token),
              let image = UIImage(data: data) else { return nil }
        // Older photos of the same person are no use any more.
        for old in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where old.hasPrefix(id) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(old))
        }
        try? data.write(to: file, options: .atomic)
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    static func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Crops a picked photo to a centred square and shrinks it to 512 points,
    /// which is plenty for an avatar and keeps the upload small.
    static func squareJPEG(from data: Data, side: CGFloat = 512) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let crop = min(image.size.width, image.size.height)
        let scale = side / crop
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(
                x: (side - drawn.width) / 2,
                y: (side - drawn.height) / 2,
                width: drawn.width,
                height: drawn.height
            ))
        }
        return rendered.jpegData(compressionQuality: 0.8)
    }
}

/// A person's photo, or their initials until there is one.
struct AvatarView: View {
    let person: Person
    var size: CGFloat = Scale.Avatar.medium
    @Environment(AccountStore.self) private var account
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.circle)
                    .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 0.5))
            } else {
                Monogram(text: person.initials, size: size)
            }
        }
        .frame(width: size, height: size)
        .task(id: "\(person.id.uuidString)-\(person.avatarVersion ?? 0)") {
            guard let version = person.avatarVersion, let token = account.account?.sessionToken else {
                image = nil
                return
            }
            image = await AvatarCache.image(for: person.id, version: version, token: token)
        }
    }
}
