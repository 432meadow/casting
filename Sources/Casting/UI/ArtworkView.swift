import SwiftUI

/// Square album cover that loads asynchronously, with a placeholder while loading or when there's no art.
struct ArtworkView: View {
    let request: ArtworkRequest?
    /// Pixel size to decode at (points × screen scale).
    let pixelSize: Int
    var cornerRadius: CGFloat = 4

    @State private var image: NSImage?

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
            .task(id: request) {
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
