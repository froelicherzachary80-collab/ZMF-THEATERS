import UIKit
import SwiftUI

/// Authenticated poster/backdrop loader with an in-memory cache.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    func image(for item: MediaItem, library: MediaLibrary, type: String = "Primary", maxWidth: Int = 500) async -> UIImage? {
        guard let client = library.client(for: item) else { return nil }
        let itemId = (item.kind == .episode && type == "Backdrop") ? (item.seriesId ?? item.itemId) : item.itemId
        let url = client.imageURL(itemId: itemId, type: type, maxWidth: maxWidth)
        let key = url.absoluteString
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let t = inflight[key] { return await t.value }
        var req = URLRequest(url: url)
        req.setValue(client.authorizationHeader, forHTTPHeaderField: "Authorization")
        let session = client.session
        let request = req
        let task = Task<UIImage?, Never> {
            guard let result = try? await session.data(for: request),
                  (result.1 as? HTTPURLResponse)?.statusCode == 200,
                  let img = UIImage(data: result.0) else { return nil }
            return img
        }
        inflight[key] = task
        let img = await task.value
        inflight[key] = nil
        if let img { cache.setObject(img, forKey: key as NSString) }
        return img
    }
}

struct PosterView: View {
    let item: MediaItem
    @EnvironmentObject var library: MediaLibrary
    var width: CGFloat = 110
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: [.purple.opacity(0.6), .black], startPoint: .top, endPoint: .bottom))
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Text(item.title).font(.caption.bold()).multilineTextAlignment(.center).padding(6).foregroundStyle(.white)
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: item.id) {
            if item.hasPrimaryImage || item.kind == .episode {
                image = await ImageLoader.shared.image(for: item, library: library)
            }
        }
    }
}
