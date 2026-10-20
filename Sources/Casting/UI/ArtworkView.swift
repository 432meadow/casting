import SwiftUI

/// Square album cover that loads asynchronously, with a placeholder while loading or when there's no art.
struct ArtworkView: View {
    let request: ArtworkRequest?
    /// Pixel size to decode at (points × screen scale).
    let pixelSize: Int
    var cornerRadius: CGFloat = 4

    @State private var image: NSImage?
    /// Bumped when the album's cover changes, to load it again.
    @State private var revision = 0

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onReceive(NotificationCenter.default.publisher(for: ArtworkStore.didChange)) { note in
                if let request, note.object as? String == request.id { revision += 1 }
            }
            .task(id: ArtworkTaskID(request: request, revision: revision)) {
                guard let request else {
                    image = nil
                    return
                }
                image = ArtworkStore.shared.cachedImage(for: request, pixelSize: pixelSize)
                guard image == nil else { return }
                let loaded = await ArtworkStore.shared.image(for: request, pixelSize: pixelSize)
                if !Task.isCancelled { image = loaded }
            }
    }

    private struct ArtworkTaskID: Equatable {
        var request: ArtworkRequest?
        var revision: Int
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
            }
    }
}
