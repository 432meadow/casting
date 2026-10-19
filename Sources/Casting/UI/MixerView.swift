import SwiftUI
import UniformTypeIdentifiers

/// The two-deck mixer, above the now-playing bar: three glass cards (deck A, the mixer, deck B)
/// floating over a wash of the loaded tracks' artwork, which leans toward whichever side the
/// crossfader favours.
struct MixerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let mixer = model.mixer
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                DeckView(deck: mixer.a, other: mixer.b, accent: Palette.warm)
                MixerSection(mixer: mixer)
                    .frame(width: 272)
                    .glassCard()
                DeckView(deck: mixer.b, other: mixer.a, accent: Palette.cool)
            }
        }
        .padding(10)
        .frame(height: 194)
        .background { AmbientBackdrop(mixer: mixer) }
        .clipped()
    }
}

extension UTType {
    /// One track ID per dragged row, as the track table writes it.
    static let castingTrackID = UTType(importedAs: "io.github.432meadow.casting.track-ids")
}

// MARK: - Backdrop

/// Each deck's artwork, blurred into a soft field of colour on its side, so the glass has
/// something to catch. Without artwork the deck's accent stands in. The colour leans toward
/// whichever deck the crossfader favours.
private struct AmbientBackdrop: View {
    let mixer: Mixer

    var body: some View {
        let toB = mixer.crossfader
        ZStack {
            LinearGradient(stops: [
                .init(color: Palette.warm.opacity(0.85 - toB * 0.45), location: 0),
                .init(color: Palette.warm.opacity(0.3), location: 0.3),
                .init(color: Palette.cool.opacity(0.3), location: 0.7),
                .init(color: Palette.cool.opacity(0.4 + toB * 0.45), location: 1),
            ], startPoint: .leading, endPoint: .trailing)
            HStack(spacing: 0) {
                Glow(request: mixer.a.track?.artworkRequest, strength: 1 - toB * 0.6, fadeToward: .trailing)
                Glow(request: mixer.b.track?.artworkRequest, strength: 0.4 + toB * 0.6, fadeToward: .leading)
            }
        }
        .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.3))
    }

    private struct Glow: View {
        let request: ArtworkRequest?
        let strength: Double
        let fadeToward: UnitPoint
        @State private var image: NSImage?

        var body: some View {
            Color.clear
                .overlay {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 40)
                            .saturation(1.4)
                            .transition(.opacity)
                    }
                }
                .clipped()
                // Fade out toward the middle so the two sides melt into each other.
                .mask(LinearGradient(colors: [.black, .black.opacity(0)],
                                     startPoint: fadeToward == .trailing ? .leading : .trailing, endPoint: fadeToward))
                .opacity(0.3 + 0.7 * strength)
                .task(id: request) {
                    guard let request else {
                        withAnimation(.easeInOut(duration: 0.6)) { image = nil }
                        return
                    }
                    // Tiny is plenty: it's blurred to nothing anyway.
                    var loaded = ArtworkStore.shared.cachedImage(for: request, pixelSize: 64)
                    if loaded == nil { loaded = await ArtworkStore.shared.image(for: request, pixelSize: 64) }
                    if !Task.isCancelled { withAnimation(.easeInOut(duration: 0.6)) { image = loaded } }
                }
        }
    }
}

// MARK: - Deck

private struct DeckView: View {
    @Environment(AppModel.self) private var model
    let deck: Deck
    let other: Deck
    let accent: Color
    @State private var isDropTarget = false

    var body: some View {
        @Bindable var deck = deck
        VStack(alignment: .leading, spacing: 10) {
            header
            WaveformView(deck: deck, accent: accent)
                .frame(height: 52)
            HStack(spacing: 8) {
                Button { deck.togglePlay() } label: {
                    Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(GlassPill(tint: accent, circle: true))
                .help(deck.isPlaying ? "Pause" : "Play")
                Button("Cue") { deck.cue() }
                    .buttonStyle(GlassPill())
                    .help("Playing: back to the cue point. Paused: set the cue point here.")

                Spacer(minLength: 4)

                NudgeButton(deck: deck, direction: -1, accent: accent)
                TempoSlider(tempo: $deck.tempo, accent: accent)
                    .frame(minWidth: 60, maxWidth: 130)
                NudgeButton(deck: deck, direction: 1, accent: accent)
                Button("Match") { deck.matchTempo(to: other) }
                    .buttonStyle(GlassPill())
                    .disabled(deck.tempoMatching(other) == nil)
                    .help(matchHelp)
            }
            .controlSize(.small)
            .disabled(!deck.isReady)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .glassCard(tint: isDropTarget ? accent.opacity(0.35) : deck.isPlaying ? accent.opacity(0.1) : nil)
        .animation(.easeInOut(duration: 0.25), value: deck.isPlaying)
        .animation(.easeInOut(duration: 0.15), value: isDropTarget)
        .onDrop(of: [.castingTrackID, .fileURL], isTargeted: $isDropTarget, perform: load)
        .contextMenu { deckMenu }
    }

    private var header: some View {
        HStack(spacing: 11) {
            ArtworkView(request: deck.track?.artworkRequest, pixelSize: 96, cornerRadius: 9)
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                .overlay(alignment: .topLeading) {
                    Text(deck.side.name)
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(accent, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                        .offset(x: -5, y: -5)
                }
            VStack(alignment: .leading, spacing: 2) {
                if let track = deck.track {
                    HStack(spacing: 6) {
                        Text(track.title.isEmpty ? track.fileName : track.title)
                            .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if deck.isLoading { ProgressView().controlSize(.mini) }
                    }
                    if let error = deck.errorMessage {
                        Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
                    } else {
                        Text(track.displayArtist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Text("Deck \(deck.side.name)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    Text("Empty").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                Text(deck.effectiveBPM.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 21, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(deck.effectiveBPM == nil ? .tertiary : .primary)
                    .contentTransition(.numericText())
                Text(deck.tempo == 0 ? "BPM" : String(format: "BPM  %+.1f%%", deck.tempo * 100))
                    .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                    .tracking(0.5)
                    .foregroundStyle(deck.tempo == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(accent))
            }
            .help(deck.track != nil && deck.effectiveBPM == nil ? "No BPM yet — Track ▸ Detect BPM" : "")
            Menu { deckMenu } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(.secondary)
            .fixedSize()
            .help("Load or eject")
        }
    }

    @ViewBuilder private var deckMenu: some View {
        Button("Load Now Playing") {
            if let track = model.player.currentTrack { model.load(track, on: deck.side) }
        }
        .disabled(model.player.currentTrack == nil)
        Button("Load Selected Track") {
            if let track = model.selectedTracks.first { model.load(track, on: deck.side) }
        }
        .disabled(model.selectedTrackIDs.isEmpty)
        Divider()
        Button("Eject") { deck.eject() }
            .disabled(deck.track == nil)
    }

    private var matchHelp: String {
        guard let target = other.effectiveBPM else { return "Match tempo to deck \(other.side.name) (needs both BPMs)" }
        return String(format: "Match tempo to deck %@ (%.1f BPM)", other.side.name, target)
    }

    /// Takes a track dragged from a track list (or a library file dragged from the Finder).
    private func load(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let model = model
        let side = deck.side
        if provider.hasItemConformingToTypeIdentifier(UTType.castingTrackID.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.castingTrackID.identifier) { data, _ in
                guard let data, let text = String(data: data, encoding: .utf8),
                      let id = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                Task { @MainActor in model.loadTrack(id: id, on: side) }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let path = url?.path else { return }
                Task { @MainActor in
                    if let track = model.track(atPath: path) { model.load(track, on: side) }
                }
            }
            return true
        }
        return false
    }
}

/// The whole track's loudness as mirrored rounded bars, the played part in the deck's colour.
/// Click or drag to seek.
private struct WaveformView: View {
    let deck: Deck
    let accent: Color
    /// Fraction of the track under the pointer while dragging.
    @State private var scrub: Double?

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !deck.isPlaying)) { _ in
                let duration = deck.duration
                let time = scrub.map { $0 * duration } ?? deck.currentTime
                let progress = duration > 0 ? time / duration : 0
                Canvas { context, size in
                    draw(in: &context, size: size, progress: progress, cue: duration > 0 ? deck.cuePoint / duration : 0)
                }
                .overlay(alignment: .bottomLeading) { timeLabel(Format.time(time)) }
                .overlay(alignment: .bottomTrailing) { timeLabel("-" + Format.time(max(0, duration - time))) }
                .opacity(deck.track == nil ? 0 : 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard deck.isReady, geometry.size.width > 0 else { return }
                        scrub = min(max(value.location.x / geometry.size.width, 0), 1)
                    }
                    .onEnded { _ in
                        if let scrub { deck.seek(to: scrub * deck.duration) }
                        scrub = nil
                    }
            )
        }
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if deck.track == nil {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.tertiary)
                    Label("Drop a track here", systemImage: "arrow.down.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func timeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, progress: Double, cue: Double) {
        let middle = size.height / 2
        let pitch: CGFloat = 3  // bar plus gap
        let count = max(1, Int(size.width / pitch))
        let levels = Self.resample(deck.waveform, to: count)
        var bars = Path()
        let maxHeight = size.height - 18
        for index in 0..<count {
            let level = levels.isEmpty ? 0 : CGFloat(levels[index])
            let height = max(2, level * maxHeight)
            bars.addRoundedRect(in: CGRect(x: CGFloat(index) * pitch, y: middle - height / 2, width: 2, height: height),
                                cornerSize: CGSize(width: 1, height: 1))
        }
        let playedX = size.width * progress
        var played = context
        played.clip(to: Path(CGRect(x: 0, y: 0, width: playedX, height: size.height)))
        played.fill(bars, with: .linearGradient(Gradient(colors: [accent, accent.opacity(0.65)]),
                                                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
        var unplayed = context
        unplayed.clip(to: Path(CGRect(x: playedX, y: 0, width: size.width - playedX, height: size.height)))
        unplayed.fill(bars, with: .color(.primary.opacity(0.2)))

        // Cue point: a small dot on the top edge.
        let cueX = min(max(size.width * cue, 3), size.width - 3)
        context.fill(Path(ellipseIn: CGRect(x: cueX - 2.5, y: 2, width: 5, height: 5)), with: .color(Palette.ochre))

        // Playhead, with a soft glow in the deck's colour.
        var glow = context
        glow.addFilter(.shadow(color: accent, radius: 4))
        glow.fill(Path(roundedRect: CGRect(x: playedX - 1, y: 3, width: 2, height: size.height - 6), cornerRadius: 1),
                  with: .color(.primary))
    }

    /// Averages (or repeats) the overview to one value per drawn bar.
    private static func resample(_ levels: [Float], to count: Int) -> [Float] {
        guard !levels.isEmpty else { return [] }
        return (0..<count).map { index in
            let start = index * levels.count / count
            let end = max(start + 1, (index + 1) * levels.count / count)
            let slice = levels[start..<min(end, levels.count)]
            return slice.reduce(0, +) / Float(slice.count)
        }
    }
}

/// Speeds the deck up or slows it down while held, for pulling the beats into line.
private struct NudgeButton: View {
    let deck: Deck
    let direction: Double
    let accent: Color
    @State private var isPressed = false

    var body: some View {
        Image(systemName: direction < 0 ? "minus" : "plus")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(isPressed ? accent : .secondary)
            .frame(width: 18, height: 18)
            .background(.primary.opacity(isPressed ? 0.12 : 0.06), in: Circle())
            .scaleEffect(isPressed ? 0.9 : 1)
            .animation(.spring(duration: 0.2), value: isPressed)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        deck.setNudge(direction * Deck.nudgeAmount)
                    }
                    .onEnded { _ in
                        isPressed = false
                        deck.setNudge(0)
                    }
            )
            .help(direction < 0 ? "Hold to slow down" : "Hold to speed up")
            .accessibilityLabel(direction < 0 ? "Nudge slower" : "Nudge faster")
    }
}

/// Tempo: a thin line with a centre mark; the fill grows out from the middle. Double-click resets.
private struct TempoSlider: View {
    @Binding var tempo: Double
    let accent: Color
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let middle = geometry.size.height / 2
            let fraction = (tempo / Deck.tempoRange + 1) / 2
            let x = width * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12)).frame(height: 3)
                Capsule()
                    .fill(accent)
                    .frame(width: abs(x - width / 2), height: 3)
                    .offset(x: min(x, width / 2))
                Rectangle().fill(.primary.opacity(0.3)).frame(width: 1, height: 9).offset(x: width / 2 - 0.5)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                    .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                    .frame(width: 13, height: 13)
                    .offset(x: x - 6.5)
            }
            .frame(height: geometry.size.height)
            .position(x: width / 2, y: middle)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard width > 0 else { return }
                        var target = (Double(drag.location.x / width) * 2 - 1) * Deck.tempoRange
                        if abs(target) < Deck.tempoRange * 0.03 { target = 0 }  // detent
                        tempo = (min(max(target, -Deck.tempoRange), Deck.tempoRange) * 1000).rounded() / 1000
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { tempo = 0 })
        }
        .frame(height: 20)
        .opacity(isEnabled ? 1 : 0.45)
        .help("Tempo ±8% — double-click to reset")
        .accessibilityElement()
        .accessibilityLabel("Tempo")
        .accessibilityValue(String(format: "%+.1f percent", tempo * 100))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: tempo = min(tempo + 0.001, Deck.tempoRange)
            case .decrement: tempo = max(tempo - 0.001, -Deck.tempoRange)
            @unknown default: break
            }
        }
    }
}

// MARK: - Mixer section

private struct MixerSection: View {
    @Bindable var mixer: Mixer

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 0) {
                ChannelStrip(deck: mixer.a, accent: Palette.warm, knobsLeading: true)
                Spacer(minLength: 0)
                VStack(spacing: 5) {
                    Knob(value: $mixer.masterVolume, range: 0...1, defaultValue: 0.8, accent: .primary, size: 30)
                    StripLabel("MASTER")
                    if let error = mixer.errorMessage {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(error)
                    }
                }
                .frame(maxHeight: .infinity)
                Spacer(minLength: 0)
                ChannelStrip(deck: mixer.b, accent: Palette.cool, knobsLeading: false)
            }
            HStack(spacing: 8) {
                Text("A").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(Palette.warm)
                Crossfader(position: mixer.crossfader) { mixer.moveCrossfader(to: $0) }
                Text("B").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(Palette.cool)
                Menu {
                    Picker("Crossfade Length", selection: $mixer.autoFadeSeconds) {
                        ForEach(Mixer.autoFadeChoices, id: \.self) { seconds in
                            Text("\(Int(seconds)) seconds").tag(seconds)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: mixer.isAutoFading ? "stop.fill" : "arrow.left.arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(mixer.isAutoFading ? Palette.warm : .secondary)
                        .frame(width: 24, height: 24)
                        .background(.primary.opacity(mixer.isAutoFading ? 0.12 : 0.06), in: Circle())
                        .contentShape(Circle())
                } primaryAction: {
                    mixer.isAutoFading ? mixer.cancelAutoFade() : mixer.autoFade()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(mixer.isAutoFading ? "Stop crossfade" : "Crossfade to the other side over \(Int(mixer.autoFadeSeconds)) s (hold for length)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// EQ knobs beside a channel fader; deck B's mirrors deck A's so the faders sit together.
private struct ChannelStrip: View {
    @Bindable var deck: Deck
    let accent: Color
    let knobsLeading: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if knobsLeading { knobs; fader } else { fader; knobs }
        }
    }

    private var knobs: some View {
        VStack(spacing: 2) {
            Knob(value: $deck.high, range: -1...1, defaultValue: 0, accent: accent)
            StripLabel("HI")
            Knob(value: $deck.mid, range: -1...1, defaultValue: 0, accent: accent)
            StripLabel("MID")
            Knob(value: $deck.low, range: -1...1, defaultValue: 0, accent: accent)
            StripLabel("LOW")
        }
    }

    private var fader: some View {
        ChannelFader(level: $deck.level, accent: accent)
            .frame(width: 22, height: 112)
            .help("Deck \(deck.side.name) level — double-click to reset")
    }
}

/// A vertical channel fader: a slim groove that fills from the bottom, with a pill-shaped cap.
private struct ChannelFader: View {
    @Binding var level: Float
    let accent: Color

    var body: some View {
        GeometryReader { geometry in
            let capHeight: CGFloat = 12
            let travel = geometry.size.height - capHeight
            let y = travel * CGFloat(1 - level)
            ZStack(alignment: .top) {
                Capsule().fill(.primary.opacity(0.12)).frame(width: 4)
                Capsule()
                    .fill(LinearGradient(colors: [accent, accent.opacity(0.5)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 4, height: max(0, geometry.size.height - y - capHeight / 2))
                    .offset(y: y + capHeight / 2)
                Capsule()
                    .fill(.white)
                    .overlay(Capsule().fill(accent).frame(width: 12, height: 1.5))
                    .overlay(Capsule().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: 22, height: capHeight)
                    .offset(y: y)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard travel > 0 else { return }
                        level = Float(min(max(1 - (drag.location.y - capHeight / 2) / travel, 0), 1))
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { level = 1 })
        }
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue(String(format: "%.0f%%", level * 100))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: level = min(level + 0.05, 1)
            case .decrement: level = max(level - 0.05, 0)
            @unknown default: break
            }
        }
    }
}

private struct StripLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 7.5, weight: .bold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

/// A rotary control: drag up or down to turn, double-click to reset. A soft dome with a dot for
/// the pointer, and an arc in the accent colour from the resting position to the value.
private struct Knob: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let defaultValue: Float
    let accent: Color
    var size: CGFloat = 22
    @State private var dragStart: Float?
    @Environment(\.colorScheme) private var colorScheme

    private static let sweep = 0.75  // of a full turn

    var body: some View {
        let span = range.upperBound - range.lowerBound
        let fraction = Double((value - range.lowerBound) / span)
        let origin = Double((defaultValue - range.lowerBound) / span)
        let angle = Angle.degrees(-135 + fraction * 270)
        ZStack {
            Circle()
                .trim(from: 0, to: Self.sweep)
                .stroke(.primary.opacity(0.12), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: min(fraction, origin) * Self.sweep, to: max(fraction, origin) * Self.sweep)
                .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(135))
                .shadow(color: accent.opacity(0.5), radius: 2)
            Circle()
                .fill(LinearGradient(colors: colorScheme == .dark ? [Color(white: 0.86), Color(white: 0.68)] : [.white, Color(white: 0.86)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.22), radius: 2, y: 1.5)
                .padding(4.5)
            Circle()
                .fill(Color(white: 0.25))
                .frame(width: 3, height: 3)
                .offset(y: -(size / 2 - 8))
                .rotationEffect(angle)
        }
        .frame(width: size, height: size)
        .padding(2)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let start = dragStart ?? value
                    dragStart = start
                    let turned = Float(-drag.translation.height / 140) * span
                    value = min(max(start + turned, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in dragStart = nil }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { value = defaultValue })
        .accessibilityElement()
        .accessibilityValue(String(format: "%.0f%%", fraction * 100))
        .accessibilityAdjustableAction { direction in
            let step = span / 20
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
        }
    }
}

/// The crossfader: a groove tinted from deck A's colour to deck B's, a pill cap, and a soft
/// detent in the middle.
private struct Crossfader: View {
    let position: Double
    let set: (Double) -> Void

    private static let capWidth: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            let travel = geometry.size.width - Self.capWidth
            let middle = geometry.size.height / 2
            ZStack {
                Capsule()
                    .fill(LinearGradient(colors: [Palette.warm.opacity(0.7), .primary.opacity(0.12), Palette.cool.opacity(0.7)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 4)
                    .position(x: geometry.size.width / 2, y: middle)
                Rectangle()
                    .fill(.primary.opacity(0.3))
                    .frame(width: 1, height: 12)
                    .position(x: geometry.size.width / 2, y: middle)
                Capsule()
                    .fill(.white)
                    .overlay(Capsule().fill(Color(white: 0.3)).frame(width: 1.5, height: 9))
                    .overlay(Capsule().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 2.5, y: 1)
                    .frame(width: Self.capWidth, height: 16)
                    .position(x: Self.capWidth / 2 + travel * position, y: middle)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard travel > 0 else { return }
                        var target = (drag.location.x - Self.capWidth / 2) / travel
                        if abs(target - 0.5) < 0.025 { target = 0.5 }  // detent
                        set(min(max(target, 0), 1))
                    }
            )
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel("Crossfader")
        .accessibilityValue(String(format: "%.0f%% deck B", position * 100))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(min(position + 0.05, 1))
            case .decrement: set(max(position - 0.05, 0))
            @unknown default: break
            }
        }
    }
}

// MARK: - Glass

/// Liquid Glass on macOS 26; frosted material before it.
private struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

private extension View {
    @ViewBuilder
    func glassCard(tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.fill(tint ?? .clear).allowsHitTesting(false))
                .overlay(shape.strokeBorder(.white.opacity(0.15), lineWidth: 0.5).allowsHitTesting(false))
        }
    }
}

/// A capsule (or circle) of glass with a label on it; tinted, it's the deck's main button.
private struct GlassPill: ButtonStyle {
    var tint: Color?
    var circle = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(tint == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .frame(width: circle ? 30 : nil, height: circle ? 30 : 24)
            .padding(.horizontal, circle ? 0 : 12)
            .modifier(PillBackground(tint: tint, circle: circle))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .contentShape(circle ? AnyShape(Circle()) : AnyShape(Capsule()))
    }
}

private struct PillBackground: ViewModifier {
    let tint: Color?
    let circle: Bool

    func body(content: Content) -> some View {
        let shape = circle ? AnyShape(Circle()) : AnyShape(Capsule())
        if let tint {
            // Solid colour rather than tinted glass: glass nested in the card washes the tint out.
            content
                .background(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom), in: shape)
                .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
                .shadow(color: tint.opacity(0.45), radius: 5, y: 2)
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content
                .background(.thinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.15), lineWidth: 0.5))
        }
    }
}
