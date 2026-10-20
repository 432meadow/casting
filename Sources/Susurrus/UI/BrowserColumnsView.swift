import SwiftUI

/// iTunes-style column browser: Genre → Artist → Album, each narrowing the next,
/// with the matching tracks listed underneath.
struct BrowserColumnsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            BrowserColumn(title: "Genres", values: model.browserGenres, selection: model.browserGenre) {
                model.browse(genre: $0)
            }
            Divider()
            BrowserColumn(title: "Artists", values: model.browserArtists, selection: model.browserArtist) {
                model.browse(artist: $0)
            }
            Divider()
            BrowserColumn(title: "Albums", values: model.browserAlbums, selection: model.browserAlbum) {
                model.browse(album: $0)
            }
        }
    }
}

private struct BrowserColumn: View {
    let title: String
    let values: [String]
    let selection: String?
    let select: (String?) -> Void

    /// "All" is represented by the empty string so List selection can hold it.
    var body: some View {
        List(selection: Binding(
            get: { selection ?? "" },
            set: { select(($0?.isEmpty ?? true) ? nil : $0) }
        )) {
            Text("All (\(values.count.formatted()) \(title))")
                .fontWeight(.medium)
                .tag("")
                .paletteSelection(selection == nil)
            ForEach(values, id: \.self) { value in
                Text(value).lineLimit(1).tag(value)
                    .paletteSelection(selection == value)
            }
        }
        .listStyle(.inset)
        .frame(maxWidth: .infinity)
    }
}
