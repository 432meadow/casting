import AppKit
import SwiftUI

/// Art grid: album covers on top, the selected album's tracks underneath.
struct AlbumGridView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 18, alignment: .top)]

    var body: some View {
        @Bindable var model = model
        // A plain VStack: inside NavigationSplitView, VSplitView never gave the grid a width,
        // so the adaptive LazyVGrid laid out zero columns and showed nothing.
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(model.albums) { album in
                        AlbumCell(album: album, isSelected: album.id == model.selectedAlbumID)
                            .onTapGesture(count: 2) { model.play(album) }
                            .simultaneousGesture(TapGesture().onEnded { model.selectedAlbumID = album.id })
                            .contextMenu {
                                Button("Play") { model.play(album) }
                                if let artist = album.pageArtist {
                                    Button("Go to Artist") { model.showArtist(artist) }
                                }
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting(album.tracks.map { URL(fileURLWithPath: $0.path) })
                                }
                                Divider()
                                Button("Look Up Album on MusicBrainz…") { model.lookUpAlbum(for: album.tracks) }
                                Button("Find Missing Cover") { model.findMissingCovers(for: [album]) }
                                    .disabled(model.coverSearch != nil)
                            }
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let album = model.selectedAlbum {
                Divider()
                AlbumTracksView(album: album)
                    .frame(height: 220)
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("Sort Albums", selection: $model.albumSort) {
                    ForEach(Album.Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Sort albums")
            }
        }
    }
}

struct AlbumCell: View {
    let album: Album
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ArtworkView(request: album.artworkRequest, pixelSize: 420, cornerRadius: 6)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Palette.warm : .clear, lineWidth: 3)
                }
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            Text(album.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(album.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .help("\(album.title) — \(album.artist)")
    }
}

private struct AlbumTracksView: View {
    @Environment(AppModel.self) private var model
    let album: Album
    @State private var selectedIDs = Set<Track.ID>()

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ArtworkView(request: album.artworkRequest, pixelSize: 420, cornerRadius: 6)
                .frame(width: 160)
            VStack(alignment: .leading, spacing: 4) {
                Text(album.title).font(.title3.weight(.semibold)).lineLimit(2)
                Text(album.artist).foregroundStyle(.secondary).lineLimit(1)
                Text(details).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Play Album") { model.play(album) }
            }
            .frame(width: 180, alignment: .leading)

            Table(album.tracks, selection: $selectedIDs) {
                TableColumn("#") { track in
                    Text(track.trackNumber > 0 ? "\(track.trackNumber)" : "").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(28)
                TableColumn("Title") { track in
                    HStack(spacing: 4) {
                        if model.player.currentTrack?.id == track.id {
                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                        }
                        Text(track.title)
                    }
                }
                TableColumn("Artist") { Text($0.displayArtist) }
                TableColumn("Time") { Text(Format.time($0.length)).monospacedDigit() }
                    .width(52)
                TableColumn("Rating") { RatingView(rating: $0.rating) }
                    .width(72)
            }
            .id(album.id)
            .contextMenu(forSelectionType: Track.ID.self) { _ in
            } primaryAction: { ids in
                if let index = album.tracks.firstIndex(where: { ids.contains($0.id) }) {
                    model.play(album, startingAt: index)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(16)
    }

    private var details: String {
        var parts: [String] = []
        if album.year > 0 { parts.append(String(album.year)) }
        parts.append("\(album.tracks.count) tracks")
        parts.append(Format.time(album.duration))
        return parts.joined(separator: " · ")
    }
}
