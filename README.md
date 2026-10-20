# casting

A native macOS music library and player (SwiftUI + AVAudioEngine).

It plays music from anywhere the Mac can see it: the internal disk, an external drive, or a
network share (SMB/NAS). Local files are played in place; for slow network shares there are a few
extras, described under [Playback from a network share](#playback-from-a-network-share).

## Build, run, test

Needs macOS 14+ and the Swift toolchain (Xcode Command Line Tools are enough).

```bash
scripts/bundle.sh
```

```bash
open "build/casting.app"
```

```bash
scripts/test.sh
```

`scripts/test.sh` builds and runs the swift-testing suites. With only the Command Line Tools,
`swift test` builds them but SwiftPM's helper never runs them, so the script loads the test bundle
with a tiny runner (`scripts/testrunner/main.swift`). Pass swift-testing flags through, e.g.
`scripts/test.sh --filter Player`. The player tests play generated tones through the real audio
engine at zero volume. The tag-writing tests write only to generated files in a temp folder.

To try a build without touching your real library, set `CASTING_SUPPORT_DIR` to a scratch folder
(it stands in for `~/Library/Application Support`).

## Releases and updates

Installed copies update themselves with [Sparkle](https://sparkle-project.org): they read
`appcast.xml` from the latest GitHub release (daily, or **casting ▸ Check for Updates…**) and only
install a zip whose EdDSA signature matches the public key in `scripts/bundle.sh`.

To release, tag and push; [`.github/workflows/release.yml`](.github/workflows/release.yml) builds,
signs and publishes the release:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

The version shown in the app is the tag; the build number is the commit count.

The private signing key lives in the login Keychain (Sparkle's `generate_keys --account casting`)
and, for the workflow, in the `SPARKLE_PRIVATE_KEY` repository secret. Builds are ad-hoc signed,
not notarized, so the first copy downloaded by hand needs its quarantine flag cleared before it
opens (updates installed by Sparkle don't):

```bash
xattr -dr com.apple.quarantine /Applications/casting.app
```

## Features

**Library**
- **Add to Library** (⌘O, or drag files/folders onto the window) and **watched folders**
  (Settings ▸ Library), rescanned at launch, when a volume mounts, and every 30 minutes. Tags are
  read with AVFoundation; untagged files fall back to `Artist/Album/NN Title` folder layout.
- Views: All Tracks, **Albums** (cover grid), **Artists** (see below), **Browse** (Genre → Artist →
  Album columns).
- Built-in lists: **Recently Added** and **Recently Played** (last 30 days), **History** (every
  play, newest first, seeded with each track's last play on upgrade; right-click ▸ Clear
  History), **Duplicates** (same artist and title ignoring case/accents/punctuation, lengths
  within 2 s, grouped together) and **Missing Files** (only shown when there are some).
- Search across title/artist/album/genre/composer (every word must match; `-word` excludes,
  `"quoted phrases"` stay together) with field scopes: `artist:`, `title:`, `album:`,
  `albumartist:`, `genre:`, `composer:`, `comment:`, `grouping:`, `kind:flac`, `file:`;
  numbers `bpm:120-128`, `rating:>=4`, `year:<1990`, `plays:0`, `track:`, `disc:`, `bitrate:`,
  `time:>5:00`; dates `added:30d` (in the last 30 days), `played:>1y` (not in the last year;
  units d/w/mo/y); keys `key:8A` or `key:Am`, and `key:~8A` for every key that mixes with 8A.
  Any scope can be negated (`-genre:techno`).
- **Stats** (sidebar): listening time, plays, different tracks and skips for the last 7 days,
  30 days, 12 months or all time; top 10 artists, albums and tracks by time listened (click an
  artist to open their page, double-click anything to play it); listening by hour of day and
  average per weekday; a GitHub-style calendar of the last 12 months; and the most skipped
  tracks. Every listen is logged with the time actually spent playing (pauses and waiting for
  a network share left out) and how it ended: finished, **skipped** (moved on before the last 10 s, or
  last 10% of a short track) or stopped. Listens under a second aren't kept. Plays from before
  the log existed count their track's length, and the view says so. Skip counts are searchable
  (`skips:>2`) and there's an optional Skips column. Clear History also clears the log.
- **Artists** (sidebar, right-click a track or album ▸ Go to Artist, or click the artist in the
  now-playing bar): every artist and album artist in the library (spellings that differ only in
  case, accents or a leading "The" are merged), filtered by the search field. An artist's page
  shows their albums in the library (and ones they appear on), their most played tracks, and,
  looked up without an account or key:
  - **MusicBrainz**: the matching artist (by name; when several share it, the one whose
    discography overlaps the library most; **Not them?** picks another and is remembered), type,
    country, years, genres and links, plus the **discography** (albums and EPs, or everything)
    with each release marked **In library** (title match ignoring case, punctuation and edition
    notes like "(Deluxe Edition)") or offered as **Search Soulseek** / add to the Soulseek
    **Wishlist**. "Missing only" narrows it to the gaps.
  - **Wikipedia**: the summary and photo (through the artist's Wikidata link).
  - **ListenBrainz**: similar artists; the ones in your library are highlighted and open their
    page, the others offer a Soulseek search or wishlist entry.

  Responses are cached for two weeks in `~/Library/Caches/casting/ArtistInfo` (a stale copy is
  used when offline), and MusicBrainz requests are spaced a second apart as it asks
  (`Metadata/ArtistInfoService.swift`).
- **Go to Current Track** (⌘L, or click the title in the now-playing bar) selects and centers the
  playing track, switching to All Tracks if the current list doesn't have it.
- Track list: right-click the header to show/hide columns (extra ones: Album Artist, Composer,
  Grouping, Comment, #, Disc, Last Played, Kind, Bit Rate, Sample Rate, Size); type to jump to a
  row in the sorted column (title otherwise).
- **Missing files**: every file is checked in the background a minute after launch and whenever
  a volume mounts or unmounts (File ▸ Check for Missing Files to run it now). Missing tracks are
  dimmed with a ⚠; tracks on an unmounted volume are dimmed with a drive icon instead (one check
  per volume, not per file). Files that moved but still resolve through their bookmark get their
  path fixed silently. **Locate File…** (Track menu or right-click) relinks a missing track and
  also finds its missing neighbours in the chosen file's folder.
- **Remove from Library…** (⌥⌘⌫, right-click, or File ▸ Remove Missing Tracks from Library…)
  deletes tracks from casting's database after a confirmation. The files are never touched.

**Editing** (saved to the casting database; optionally also written into the files, see below)
- **Get Info** (⌘I) for one or many tracks; mixed values stay untouched unless changed.
- Ratings: click stars in the table, Track ▸ Rating, or ⌘0–⌘5.
- Playlists: new (⌘N), from selection (⇧⌘N), folders, rename, delete, drag tracks onto a
  playlist, drag playlists into folders, reorder by dragging rows (in playlist order),
  remove (⌘⌫).
- **Smart playlists** (⌥⌘N): native rule editor with a live match count.
- **Undo/Redo** (⌘Z/⇧⌘Z) for Get Info edits, ratings, and every playlist change: add, remove,
  reorder, rename, move, create, edit smart rules, and delete (a deleted folder comes back with
  all its playlists). Removing tracks from the library and background BPM detection aren't
  undoable.
- **Detect BPM** (Track menu or right-click): fills in the BPM of selected tracks that have none
  (or re-detects them, when every selected track already has one), a few files at a time in the
  background with progress in the window subtitle. Results are saved like Get Info edits, so
  they're written into the files too when that's on. There's a BPM column in the track list.

  Lightweight on purpose (`Library/BPMDetector.swift`): it reads ~30 s from the middle of the
  file's audio — for MP3 and FLAC just that byte range (≈1.2 MB / ≈3 MB, cut at a frame
  boundary, past any embedded cover art), since AudioToolbox would otherwise read the whole file
  to seek, which is slow over a network share — mixes it to mono at ~11 kHz, and takes the
  strongest periodicity of a spectral-flux onset envelope (~10 ms of CPU per track; reads took
  ~1 s each from a slow network share). Tempos are folded into 70–140 BPM, the convention nearly
  all existing BPM tags in the test library followed. On 319 randomly picked tagged tracks it
  agreed with the tag (within 2%) on 80%, and on 84% if half/double/3:2 time counts; 6% had no
  clear beat and are left empty.
- **Detect Key** works the same way and fills a Key column (Camelot and standard notation,
  sorted round the Camelot wheel; editable in Get Info). It reads a minute from the middle of the
  file, builds a chromagram (55 Hz–1.8 kHz) and picks the major or minor key whose
  Krumhansl–Kessler profile fits best (`Library/KeyDetector.swift`). Keys are read from and
  written to ID3 `TKEY` and FLAC `INITIALKEY`; MP4 files have no standard key item, so keys are
  read from them but not written. It's checked against generated chord progressions, not yet
  against a tagged library, so treat it as a first guess.

**Import and export** (File menu; nothing here reads audio, it all comes from the database)
- **M3U playlists**: **Export Playlist…** (File menu, or right-click a playlist) saves a playlist,
  a smart playlist's current tracks, or everything in a folder as M3U8 (`#EXTM3U` with
  `#EXTINF` length and "Artist - Title" lines), with paths **relative to the playlist file** or
  **absolute** (relative paths fall back to absolute for files on another volume). **Import
  Playlist…** (or drag `.m3u` / `.m3u8` files onto the window) makes a new playlist named after
  the file: entries are matched to library tracks by path (also when the case or accent
  encoding differs, `file://` URLs, relative and Windows-style paths), files that exist but
  aren't in the library are added, and a summary lists how many matched, were added and
  weren't found. Imported from a folder's right-click menu, it lands in that folder.
- **Import from Apple Music…** reads a library exported from Music or iTunes (File ▸ Library ▸
  Export Library…, a `Library.xml`; dropping one on the window works too). Tracks are matched by
  path, and a preview shows what would change before anything does, with the option to add the
  files that are on disk but not in the library. It only fills gaps or brings values forward:
  ratings only where casting has none (ratings inherited from the album are ignored), the
  higher play count (adding them would count plays from before the switch twice), the later
  last played and the earlier date added. Playlists and folders are recreated inside a new
  **Apple Music** folder; the whole-library and media-kind lists (Library, Music, Downloaded,
  Podcasts…) are skipped. Skip counts stay casting's own (they come from its listen log).
  Everything goes into casting's database only, never into the files, and one **Undo** puts it
  all back (tracks it added stay in the library, as with Add to Library).
- **Export Rekordbox XML…** (or right-click a playlist ▸ Export for Rekordbox…) writes the
  whole library or the chosen playlists and their tracks in Rekordbox's `DJ_PLAYLISTS` format:
  tags, size, length, BPM, key (as Rekordbox writes it: Am, F#, Ebm), rating (51 per star),
  play count, date added and a `file://localhost/` location, with the playlist folders as
  they are in the sidebar (smart playlists as their current tracks). Tracks that have been on a
  mixer deck also get their beat grid (a `TEMPO` with the fitted tempo and first beat); the
  grids are remembered in `BeatGrids.json` next to the library, so the library isn't analysed
  on export. Load it in Rekordbox under Preferences ▸ Advanced ▸ rekordbox xml.
- Exports are written to a temp file next to the target and renamed over it, so a failed export
  never leaves half a file.

**Playback**
- Gapless playback; shuffle (⌥⌘S), repeat off/all/one (⌘R).
- **Up Next** panel (⌥⌘U): Play Next (⌥↩), Add to Queue (⌥⇧↩), reorder, remove, jump.
- Play counts and last-played are recorded after half a track (or 4 minutes).
- 10-band **equalizer** with presets (⌥⌘E).
- Two-deck **mixer** (⇧⌘M) for blending tracks by hand: load a deck from the track menu (⌥⌘1 / ⌥⌘2)
  or by dragging a track onto it. Equal-power crossfader, auto crossfade over 4–32 s (⇧⌘X),
  3-band EQ with kills, channel faders, tempo ±8% with hold-to-nudge and BPM match, cue point,
  and a loudness overview to click-seek in. Knobs, faders, tempo and the crossfader also follow
  the scroll wheel. **Continue in Mixer** moves the playing track onto a deck at the same spot.
  The mixer and the queue player take turns: starting one pauses the other. There's one output,
  so no headphone pre-listen.
  - **Beats** (⌃⌘B): both decks close up, one above the other, scrolling past a shared playhead
    with each track's beat grid drawn on, and how far apart the beats are while both play. The
    grid is fitted to the track's onsets when the deck loads it (tempo to 0.01 BPM, starting from
    the tag). Paused, drag a strip to put a beat under the playhead before setting the cue.
  - Each deck shows its key as it sounds at the current tempo (±8% can move it a semitone), with
    a warning when it clashes with the other deck's. Tracks without a BPM or key get the ones the
    deck worked out.
  - The **Mixer** menu plays and cues each deck from the keyboard (⌃⌘1 / ⌃⌘2, add ⌥ to cue) and
    moves the crossfader (⌃⌘← / ⌃⌘→).
  - Deck plays count and show up in History and Stats. Auditioning a track or mixing it out
    early isn't counted as a skip.
- Output device picker and AirPlay button in the now-playing bar.
- Media keys, Control Center / Now Playing widget, headphone buttons.
- Menu bar mini-player; the app keeps running when the window is closed.
- **Help ▸ Report a Bug…** opens a new GitHub issue in the browser, filled in with what you wrote
  and, if you want, diagnostics: versions, Mac model, library size and formats, whether the music
  is on a local disk or a share, a few settings, the last 40 errors, and the latest crash
  report's summary. Paths and the Mac's user and computer names are taken out, the diagnostics
  can be edited before sending, and casting itself sends nothing. The errors come from a small
  log in `~/Library/Logs/casting/events.log` that survives a crash.
- Queue and position are restored (paused) on the next launch.

**Soulseek** (phases 1–4: search + downloads + sharing + messages)
- Native Soulseek client (sidebar ▸ Network ▸ Soulseek): connect with a username/password set in
  Settings ▸ Soulseek (password lives in the keychain; a brand-new username is auto-registered by
  the network on first login) and search the network. Results stream in from peers with format,
  bitrate/bit depth, length, size, free-slot and speed columns.
- **Downloads**: double-click a result (or right-click — multi-select works, and "Download
  Folder" grabs a whole album) to queue it with the peer. The **Downloads tab** (next to Search,
  with a live count of active transfers) shows each file's state: connecting, waiting on the
  uploader, place in their queue, transferring with progress, done, or failed (with the peer's
  reason, e.g. "File not shared.") — plus an Uploads section for files others fetch from you.
  Files land in Settings ▸ Soulseek's download folder (default `~/Music/Soulseek`), inside their
  remote folder name so albums stay together; transfers write to a `.part` file, resume from
  where they stopped (Retry in the row's context menu), and finished folders are **imported into
  the library automatically** through the watched-folder scanner.
- The protocol (message layouts, zlib-wrapped search results, the direct + server-relayed peer
  connection dance, and the QueueUpload → TransferRequest → raw-byte `F` connection transfer
  flow) follows Nicotine+ 3.3.10's `doc/SLSKPROTOCOL.md`, implemented from scratch in
  `Sources/Casting/Soulseek/` on Network.framework + BSD sockets — no dependencies. The peer
  listener uses BSD sockets because `NWListener` fails (EINVAL) on Macs with certain network
  filters; without a reachable port everything still works through server-relayed connections.
- **Sharing**: pick a shared folder in Settings ▸ Soulseek. It's scanned off the main thread
  (library tracks contribute bitrate/duration/bit-depth attributes), casting joins the
  distributed network as a leaf (adopts a parent, takes no children), answers matching searches
  directly to the searcher, serves browse requests, and uploads queued files over `F`
  connections — two slots, a queue with position replies, resume offsets honored. Search
  matching is all-words-must-match with `-word` exclusions, like other clients.
- **Filters** above Search/Wishlist/Browse results: filter words (`-word` excludes), a format
  menu (Lossless, 320/256/192 kbps or better — lossless always passes), free-slot only, and
  **Group by folder**, which folds results into one row per user + remote folder (total size and
  length, "Mixed" when formats differ) that downloads the whole folder.
- **Block users** (right-click a result or an upload): their results are hidden, and they get no
  search results, an empty share list, no user info, and "Banned" for upload requests; their
  messages are dropped. Settings ▸ Soulseek
  lists them with Unblock.
- **Browse** tab (or right-click a result/transfer ▸ Browse *user*'s Files): fetches the user's
  whole share (peer code 4 → 5, zlib file list; bare file names are joined to their folder).
  Folders on the left with a filter, files on the right; right-click a folder to download it, or
  it and its subfolders.
- **Wishlist** tab: saved searches (add there, or with the ☆ next to the search field). While
  connected, one is re-run per interval, round robin, with the server's `WishlistSearch` (code
  103) at the interval it sends (code 104, default 12 minutes). New results are counted per
  search (and on the tab) until you look; results are kept for the session.
- **Messages** tab: private conversations, latest first, with unread counts on each one, on the
  tab and on the sidebar's Soulseek row, and a dot for whether the user is online, away or
  offline (the server's `WatchUser` / `GetUserStatus`, codes 5 and 7). Start one from the
  username field there, or right-click a result, a transfer or a browsed user ▸ **Message
  *user***. Messages go through the server (`MessageUser`, code 22), which holds them for
  offline users; every message received is acknowledged (`MessageAcked`, code 23) so it isn't
  sent again, and ones that waited for you arrive at login marked as sent while you were
  offline. Blocked users' messages are dropped. History is kept in
  `~/Library/Application Support/casting/Soulseek/Messages.json`.
- **User info** (right-click ▸ Show Info, or Info in a conversation): a sheet with the user's
  status, the server's stats (`GetUserStats`, code 36: average speed, uploads, files and
  folders), and what the user reports about themselves (peer `UserInfoRequest` → `UserInfoResponse`,
  codes 15 → 16: description, picture, upload slots, queue, free slot), with Browse Files,
  Message and Block. casting answers the same request with the description from Settings ▸
  Soulseek, its two upload slots, its queue and whether a slot is free (blocked users get no
  answer).
- **Notifications** (Settings ▸ Soulseek, on by default) when a download folder finishes and is
  imported, and when a saved search turns up new results; a separate switch covers private
  messages (one per sender, so a burst at login doesn't flood). They need the app bundle (not
  `swift run`).
- **Upload speed limit** (Settings ▸ Soulseek): one cap for all uploads together, paced in small
  chunks so the rate stays even. **Connect when casting starts** keeps the share and wishlist
  going without a search first.

## Writing tags to files

Off by default: **Settings ▸ Library ▸ Write tags to files** (asks for confirmation the first
time). With it on, Get Info edits and ratings are queued and written into the files in the
background, one file at a time, with progress in Settings and the window subtitle. Play counts
stay in casting's database (rewriting a file after every play isn't worth it).

| Format | Tags | Rating |
| --- | --- | --- |
| MP3 | ID3v2.2 / v2.3 / v2.4 (keeps the file's version; untagged files get v2.3) | `POPM`, MusicBee values (½★ = 13 … 4½★ = 242, 5★ = 255); existing POPM frames keep their email and play counter |
| FLAC | Vorbis comments | `RATING` 0–100 (20 per star) |
| M4A | iTunes `ilst` items | not written: no rating field that other players agree on |

WAV/AIFF, unsynchronised or compressed ID3 tags, and fragmented MP4 are reported and skipped.

Every write is checked before the original is touched (`Library/TagWriting/TagFileWriter.swift`):
the new file is written to a hidden temp copy next to the original, read back from disk, and must
parse with the new values, keep every frame/comment/item that wasn't edited byte for byte, and
keep the audio data identical (MP4: every chunk offset still points at the same bytes; MP3/M4A:
AVFoundation reads the same duration).

When the new MP3/FLAC tags fit in the space the old tag takes up (its padding absorbs the
change, which is the usual case), only the tag is read and only the bytes that changed are
written back in place, then read back and compared (the old bytes are put back if they differ).
The audio is never written to. Over a slow network share (~1.3 MB/s) that took writes from about a
minute per file to a few seconds. If the original's size or modification date changed
meanwhile it's skipped. Otherwise permissions, creation date and extended attributes (Finder
tags) are copied over and the copy is renamed over the original (atomic). The track that's
playing is written once it stops playing.

**Why hand-written writers instead of a library.** Options considered, all buildable with only the
Command Line Tools:
- *Vendored TagLib* (C++ target + C wrapper): covers every format, but it means tens of thousands of lines of C++ to
  vendor and keep updated, LGPL/MPL licensed, and its C API can't reach POPM.
- *Pure-Swift ID3 packages* (e.g. ID3TagEditor): MP3 only, and they rebuild the tag from the
  frames they understand, dropping anything else (TXXX ReplayGain, iTunSMPB gapless info, PRIV…).
- *AVFoundation*: reads tags but can only write them via passthrough export of MP4, which rebuilds
  the whole file.

The formats casting writes need only a few hundred lines each when the code edits the frames it
owns and copies everything else verbatim, which is also what makes the byte-for-byte verification
above possible. So: small writers in `Sources/Casting/Library/TagWriting/` (`ID3Tag`, `FLACTag`,
`MP4Tag`), no dependencies.

## Playback from a network share

Files on the Mac's own disks and external drives are played in place. Files on a network
volume (SMB, AFP, NFS) can arrive slowly (the share casting was developed against measured
0.2–3 MB/s), so for those:
- A track you start plays **straight from the share** if it's MP3/AAC/WAV/AIFF (needs ~40 KB/s),
  so it starts as soon as the share responds. If it takes over 8 s the bar says
  "Waiting for the network share…".
- **Scrubbing shows a spinner while the share catches up**: after a seek in a streamed track,
  a short probe segment is scheduled first; the loading wheel next to the title spins until that
  probe's audio has actually played (and the "Waiting for the network share…" note appears if it
  takes over 8 s).
- **FLAC is copied locally first**: AudioToolbox scans FLAC files end to end for packets, which
  over the network stalled playback.
- The **next track is copied** to `~/Library/Caches/casting/Playback` (last 8, cleared on
  launch) in the background — after the current stream has had 20 s to settle — and chained
  onto the audio node in the last ~12 s, so transitions are gapless and queue edits are free.

## Layout

| Path | What |
| --- | --- |
| `Sources/Casting/Library/` | SQLite wrapper, store (+ editing, history, listen log, removal, saved tag writes), listening stats, artist index and discography matching, smart playlist predicates, tag reader, albums, artwork, BPM and key detection, search scopes, duplicate and missing-file checks |
| `Sources/Casting/Library/TagWriting/` | ID3 / FLAC / MP4 tag writers, safe file replacement, background write queue |
| `Sources/Casting/Playback/` | Player (queue, gapless, shuffle/repeat), two-deck mixer and track analysis (waveforms, beat grid), file cache, EQ, output devices, Now Playing |
| `Sources/Casting/Exchange/` | M3U playlists, Apple Music / iTunes `Library.xml` reader and import plan, Rekordbox XML writer, path matching, atomic export writes, remembered beat grids |
| `Sources/Casting/Metadata/` | MusicBrainz / Wikipedia / ListenBrainz client for artist pages (rate limit, disk cache) |
| `Sources/Casting/Soulseek/` | Soulseek client: wire codec, messages, client actor (server + peer connections), UI model, private conversations (saved to disk) |
| `Sources/Casting/AppModel*.swift` | App state, selection, actions and undo, scanning, library housekeeping, import and export |
| `Sources/Casting/Updater.swift` | Sparkle in-app updates (Check for Updates…, automatic checks) |
| `Sources/Casting/Reporting/` | Bug reports: event log, diagnostics, redaction, crash report summaries, the GitHub issue link |
| `Sources/Casting/UI/` | Track table (NSTableView), sidebar, albums, browser, Up Next, Get Info, smart editor, EQ, mixer, Rekordbox export sheet, Soulseek (+ messages and user info), settings, menu bar |
| `Sources/ObjCSupport/` | Catches NSExceptions (predicate evaluation, audio graph connections) |
| `Tests/CastingTests/` | 171 tests: listening stats, the listen log (store, v2→v3 upgrade, player skip/pause/stop tracking), discography matching, artist index, smart playlist predicates, albums/artwork, library editing, history/removal/saved tag writes and the v1→v2 upgrade, search scopes, duplicates, missing-file checks, tag reading and writing (on generated files), BPM detection (generated drum patterns, WAV and FLAC excerpts), beat grids (click tracks) and keys (chord progressions), player, mixer, import and export (M3U round trips and other apps' playlists, a generated `Library.xml` and the import plan, the Rekordbox XML shape), bug reports (redaction, issue links, crash summaries, event log), Soulseek codec + loopback client tests (search, wishlist, browse, download, resume, denial, blocking, serving searches + uploads, upload speed limit, private messages and acks, offline messages, user info and stats) against a mock server, and saved conversations |

## Known issues

- ID3v1 tags at the end of MP3s aren't updated. (Tag writes still queued at quit are saved in
  the database and picked up at the next launch, unless Write tags to files was turned off.)
- The smart playlist match count can take a few seconds on the full library.
- Ogg/Opus aren't playable (AVFoundation can't decode them; none are in the current library).
- Output-device switching mid-track (headphones unplugged, AirPlay) is handled but not yet tested
  on real hardware changes.
