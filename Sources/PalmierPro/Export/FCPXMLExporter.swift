import AVFoundation
import CryptoKit
import Foundation

/// Allowed `conform-rate` `srcFrameRate` enum strings (FCPXML v1.7 DTD), with their numeric fps.
private let conformRateEnum: [(string: String, fps: Double)] = [
    ("23.98", 24.0 * 1000.0 / 1001.0),
    ("24", 24.0),
    ("25", 25.0),
    ("29.97", 30.0 * 1000.0 / 1001.0),
    ("30", 30.0),
    ("47.95", 48.0 * 1000.0 / 1001.0),
    ("48", 48.0),
    ("50", 50.0),
    ("59.94", 60.0 * 1000.0 / 1001.0),
    ("60", 60.0),
]

/// Exports a Timeline as FCPXML 1.9 (Final Cut Pro).
///
/// FCPXML — unlike the XMEML path (`XMLExporter.swift`) — carries text overlays as `<title>`,
/// which is the reason this exporter exists. Version 1.9 keeps `media-rep` (for the embedded
/// bookmark) while still allowing a single `.fcpxml` file rather than a `.fcpxmld` bundle.
///
/// Phase 1 emits `<resources>` (formats + assets with bookmarks) and a `<spine>` covering the
/// full sequence with `<gap>` fillers, plus connected audio on negative lanes. PIP, titles, and
/// filters are filled in by later phases.
///
/// Times are integer rationals (`Rational`) so the float drift of accumulating `1/fps` never
/// shifts a cut. XML structure is built as an `XMLNode` tree (copied below from the XMEML
/// exporter's primitives); `render` owns all indentation and escaping.
enum FCPXMLExporter {

    nonisolated static func export(timeline: Timeline, resolver: MediaResolver, outputURL: URL) throws {
        let xml = try Builder(timeline: timeline, resolver: resolver).build()
        guard let data = xml.data(using: .utf8) else { throw ExportError.invalidFormat }
        try data.write(to: outputURL)
    }

    // MARK: - Builder

    private final class Builder {
        private let timeline: Timeline
        private let resolver: MediaResolver

        /// Sequence-grid frame duration (1 / timeline.fps), reduced.
        private let seqFrameDuration: Rational

        // id allocators — every id starts with a letter (XML-ID-safe).
        private var nextAssetId = 1
        private var nextFormatId = 1
        /// Per-title `<text-style-def>` id counter (ts1, ts2, …).
        private var nextTextStyleId = 1
        /// Fixed id for the single shared Text `<effect>`; emitted only when a telop exists.
        private let textEffectId = "rT"
        /// Set once the first `<title>` is emitted, so the `<effect>` is added to resources.
        private var usesTextEffect = false
        /// mediaRef → asset id (unique resolvable refs only).
        private var assetIds: [String: String] = [:]
        /// (width, height, fps-key) → format id.
        private var formatIds: [FormatKey: String] = [:]
        /// format id → emitted `<format>` node (in allocation order via `formatOrder`).
        private var formatNodes: [String: XMLNode] = [:]
        private var formatOrder: [String] = []
        /// Source start timecode (frames) per resolved url path; nil = no timecode track.
        private var tcFrameCache: [String: Int?] = [:]

        private struct FormatKey: Hashable { let w: Int; let h: Int; let fpsKey: String }

        private enum AssetKind { case video, image, audio }

        /// Cached per-asset facts, computed once when the asset is allocated.
        private struct AssetInfo {
            let id: String
            let entry: MediaManifestEntry
            let url: URL
            let kind: AssetKind
            /// Native frame duration (source fps based); image uses the timeline-fps grid.
            let frameDuration: Rational
            /// Embedded-TC offset as rational seconds (0 for image / no TC).
            let startTime: Rational
        }
        private var assetInfo: [String: AssetInfo] = [:]

        init(timeline: Timeline, resolver: MediaResolver) {
            self.timeline = timeline
            self.resolver = resolver
            // Unreduced `100/(fps·100)s` — the reference fcpxml's integer-fps frameDuration form
            // (e.g. 30→100/3000s, 24→100/2400s, 25→100/2500s). = 1/fps.
            self.seqFrameDuration = Rational(100, max(1, timeline.fps) * 100, reduce: false)
        }

        // MARK: - Document

        func build() throws -> String {
            // Sequence format: from Int timeline.fps + canvas dims.
            let seqFormatId = sequenceFormatId()

            // Allocate assets for every resolvable, unique media-backed mediaRef across all tracks.
            try allocateAssets()

            let spine = try buildSpine()

            let totalFrames = timeline.totalFrames
            let seqDuration = seqFrameDuration * totalFrames

            // Build asset nodes first so every asset `<format>` is allocated before the format list
            // is snapshotted (asset formats register into `formatOrder` lazily in `assetNode`).
            // `buildSpine` already ran, so `usesTextEffect` reflects whether any `<title>` exists.
            let assets = assetNodes()
            // Resources order matches the reference: formats, then the Text `<effect>` (only when a
            // telop exists), then assets.
            let effectNodes = usesTextEffect ? [textEffectNode()] : []
            let resources = el("resources", formatOrder.compactMap { formatNodes[$0] } + effectNodes + assets)
            let sequence = el("sequence", attrs: [
                ("format", seqFormatId),
                ("duration", seqDuration.attr),
                ("tcStart", "0s"),
                ("tcFormat", "NDF"),
                ("audioLayout", "stereo"),
                ("audioRate", "48k"),
            ], [spine])
            let project = el("project", attrs: [("name", "Timeline Export")], [sequence])
            let event = el("event", attrs: [("name", "Palmier Pro")], [project])
            let library = el("library", [event])
            let root = el("fcpxml", attrs: [("version", "1.9")], [resources, library])
            return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>\n" + render(root, indent: 0)
        }

        // MARK: - Formats

        /// Sequence `<format>` derived from the Int timeline fps and canvas dimensions.
        private func sequenceFormatId() -> String {
            let key = FormatKey(w: timeline.width, h: timeline.height, fpsKey: "seq\(timeline.fps)")
            if let id = formatIds[key] { return id }
            let id = "f\(nextFormatId)"; nextFormatId += 1
            formatIds[key] = id
            let node = el("format", attrs: [
                ("id", id),
                ("name", "FFVideoFormat\(timeline.height)p\(timeline.fps)"),
                ("frameDuration", seqFrameDuration.attr),
                ("width", String(timeline.width)),
                ("height", String(timeline.height)),
                ("colorSpace", "1-1-1 (Rec. 709)"),
            ])
            formatNodes[id] = node
            formatOrder.append(id)
            return id
        }

        /// Asset `<format>` deduped by (width, height, sourceFPS).
        private func assetFormatId(width: Int, height: Int, fps: Double) -> String {
            let fd = assetFrameDuration(fps: fps)
            let key = FormatKey(w: width, h: height, fpsKey: fd.attr)
            if let id = formatIds[key] { return id }
            let id = "f\(nextFormatId)"; nextFormatId += 1
            formatIds[key] = id
            let node = el("format", attrs: [
                ("id", id),
                ("frameDuration", fd.attr),
                ("width", String(width)),
                ("height", String(height)),
                ("colorSpace", "1-1-1 (Rec. 709)"),
            ])
            formatNodes[id] = node
            formatOrder.append(id)
            return id
        }

        /// Still-image `<format>`: native pixel size, rate-undefined (no frameDuration / colorSpace). Deduped by (width, height).
        private func imageFormatId(width: Int, height: Int) -> String {
            let key = FormatKey(w: width, h: height, fpsKey: "rateUndefined")
            if let id = formatIds[key] { return id }
            let id = "f\(nextFormatId)"; nextFormatId += 1
            formatIds[key] = id
            let node = el("format", attrs: [
                ("id", id),
                ("name", "FFVideoFormatRateUndefined"),
                ("width", String(width)),
                ("height", String(height)),
            ])
            formatNodes[id] = node
            formatOrder.append(id)
            return id
        }

        // MARK: - Assets

        /// Walk every track and allocate one asset per unique, resolvable media-backed mediaRef.
        private func allocateAssets() throws {
            for track in timeline.tracks {
                for clip in track.clips where clip.mediaType == .video || clip.mediaType == .image || clip.mediaType == .audio {
                    _ = try assetInfo(for: clip.mediaRef)
                }
            }
        }

        /// Resolve + cache the asset facts for a mediaRef. Returns nil only when unresolvable.
        private func assetInfo(for mediaRef: String) throws -> AssetInfo? {
            if let info = assetInfo[mediaRef] { return info }
            if assetIds[mediaRef] != nil { return nil }  // already tried, unresolvable
            guard let entry = resolver.entry(for: mediaRef),
                  let url = resolver.resolveURL(for: mediaRef) else { return nil }

            let id = "a\(nextAssetId)"; nextAssetId += 1
            assetIds[mediaRef] = id

            let kind: AssetKind = entry.type == .image ? .image : (entry.type == .audio ? .audio : .video)
            // Image times sit on the timeline-fps grid (it carries no native fps); audio/video use source fps.
            let fps = (kind == .image) ? Double(timeline.fps) : (entry.sourceFPS ?? Double(timeline.fps))
            let frameDuration = assetFrameDuration(fps: fps)
            let tcFrames = (kind == .image) ? 0 : (sourceTCFrame(url: url) ?? 0)
            let startTime = frameDuration * tcFrames

            let info = AssetInfo(id: id, entry: entry, url: url, kind: kind,
                                 frameDuration: frameDuration, startTime: startTime)
            assetInfo[mediaRef] = info
            return info
        }

        private func assetNodes() -> [XMLNode] {
            // Emit in allocation order (a1, a2, …).
            assetIds
                .sorted { lhs, rhs in assetIndex(lhs.value) < assetIndex(rhs.value) }
                .compactMap { assetNode(for: $0.key) }
        }

        private func assetIndex(_ id: String) -> Int { Int(id.dropFirst()) ?? 0 }

        private func assetNode(for mediaRef: String) -> XMLNode? {
            guard let info = assetInfo[mediaRef] else { return nil }
            let entry = info.entry
            let uid = Builder.contentHash(info.url.path)
            let mediaRepNode = mediaRep(url: info.url, sig: uid)

            switch info.kind {
            case .image:
                // FCP stills carry a native-size rate-undefined format and a zero-duration asset.
                return el("asset", attrs: [
                    ("id", info.id),
                    ("name", entry.name),
                    ("uid", uid),
                    ("start", "0s"),
                    ("duration", "0s"),
                    ("hasVideo", "1"),
                    ("format", imageFormatId(width: entry.sourceWidth ?? timeline.width,
                                             height: entry.sourceHeight ?? timeline.height)),
                    ("videoSources", "1"),
                ], [mediaRepNode])

            case .audio:
                let duration = assetDuration(entry: entry, frameDuration: info.frameDuration)
                return el("asset", attrs: [
                    ("id", info.id),
                    ("name", entry.name),
                    ("uid", uid),
                    ("start", info.startTime.attr),
                    ("duration", duration.attr),
                    ("hasAudio", "1"),
                    ("audioSources", "1"),
                    ("audioChannels", "2"),
                    ("audioRate", "48000"),
                ], [mediaRepNode])

            case .video:
                let formatId = assetFormatId(width: entry.sourceWidth ?? timeline.width,
                                             height: entry.sourceHeight ?? timeline.height,
                                             fps: entry.sourceFPS ?? Double(timeline.fps))
                let duration = assetDuration(entry: entry, frameDuration: info.frameDuration)
                var attrs: [(String, String)] = [
                    ("id", info.id),
                    ("name", entry.name),
                    ("uid", uid),
                    ("start", info.startTime.attr),
                    ("duration", duration.attr),
                    ("hasVideo", "1"),
                    ("format", formatId),
                    ("videoSources", "1"),
                ]
                if entry.hasAudio == true {
                    attrs += [
                        ("hasAudio", "1"),
                        ("audioSources", "1"),
                        ("audioChannels", "2"),
                        ("audioRate", "48000"),
                    ]
                }
                return el("asset", attrs: attrs, [mediaRepNode])
            }
        }

        /// `<media-rep>` with the file bookmark base64-encoded.
        private func mediaRep(url: URL, sig: String) -> XMLNode {
            var children: [XMLNode] = []
            do {
                let bookmark = try makeBookmark(url: url)
                children.append(leaf("bookmark", bookmark.base64EncodedString()))
            } catch {
                Log.export.warning("fcpxml bookmark failed for \(url.lastPathComponent): \(Log.detail(error))")
            }
            return el("media-rep", attrs: [
                ("kind", "original-media"),
                ("sig", sig),
                ("src", fileURLString(url)),
            ], children)
        }

        /// Plain (not security-scoped) bookmark: FCP — sandboxed — can't resolve a security-scoped one minted by this app, so it shows the asset's metadata but renders no pixels.
        private func makeBookmark(url: URL) throws -> Data {
            try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }

        // MARK: - Spine

        /// Base track index for the most recent `buildSpine`; nil = all-gap spine.
        private var baseTrackIndex: Int?

        private func buildSpine() throws -> XMLNode {
            let baseTrackIndex = selectBaseTrackIndex()
            self.baseTrackIndex = baseTrackIndex
            let baseClips = baseTrackIndex.map { sortedEmittableVisualClips(timeline.tracks[$0]) } ?? []

            // Spine elements with their sequence-grid offset (for sorting + gap math) + source FD.
            var elements: [(offset: Int, end: Int, node: XMLNode, srcFD: Rational)] = []
            for clip in baseClips {
                guard let info = assetInfo[clip.mediaRef] else { continue }
                let node = try baseVideoNode(clip: clip, info: info)
                elements.append((clip.startFrame, clip.endFrame, node, info.frameDuration))
            }
            elements.sort { $0.offset < $1.offset }

            // Fill gaps so spine children cover 0…totalFrames contiguously.
            let total = timeline.totalFrames
            var children: [XMLNode] = []
            var spans: [(offset: Int, end: Int, srcFD: Rational)] = []
            var cursor = 0
            for e in elements {
                if e.offset > cursor {
                    children.append(gapNode(offsetFrames: cursor, durationFrames: e.offset - cursor))
                    spans.append((cursor, e.offset, seqFrameDuration))
                }
                children.append(e.node)
                spans.append((e.offset, e.end, e.srcFD))
                cursor = max(cursor, e.end)
            }
            if cursor < total {
                children.append(gapNode(offsetFrames: cursor, durationFrames: total - cursor))
                spans.append((cursor, total, seqFrameDuration))
            }
            // All-gap spine when no base clips and a non-zero timeline.
            if children.isEmpty && total > 0 {
                children.append(gapNode(offsetFrames: 0, durationFrames: total))
                spans.append((0, total, seqFrameDuration))
            }
            spineSpans = spans

            // Attach connected audio (and disabled visual/audio retreats) to their parent element.
            try attachConnectedItems(into: &children)

            return el("spine", children)
        }

        /// Bottom-most (last in model order) visible visual track that has emittable video/image clips.
        private func selectBaseTrackIndex() -> Int? {
            for index in timeline.tracks.indices.reversed() {
                let track = timeline.tracks[index]
                guard track.type.isVisual, !track.hidden else { continue }
                if !sortedEmittableVisualClips(track).isEmpty { return index }
            }
            return nil
        }

        /// Resolvable video/image clips on a track, sorted by start frame.
        private func sortedEmittableVisualClips(_ track: Track) -> [Clip] {
            track.clips
                .filter { ($0.mediaType == .video || $0.mediaType == .image) && assetIds[$0.mediaRef] != nil }
                .sorted { $0.startFrame < $1.startFrame }
        }

        /// A base spine `<video>` (video-only — never `<asset-clip>`, so the linked audio clip
        /// doesn't double the embedded track). Adjust-* children (conform-rate → timeMap →
        /// adjust-crop → adjust-transform → adjust-blend) precede any connected lane items (which
        /// `attachConnectedItems` appends later), satisfying the strict `<video>` DTD child order.
        private func baseVideoNode(clip: Clip, info: AssetInfo) throws -> XMLNode {
            let offset = seqFrameDuration * clip.startFrame
            let duration = seqFrameDuration * clip.durationFrames
            let start = sourceInPoint(clip: clip, info: info)
            return el("video", attrs: [
                ("ref", info.id),
                ("offset", offset.attr),
                ("name", resolver.displayName(for: clip.mediaRef)),
                ("start", start.attr),
                ("duration", duration.attr),
            ], mediaAdjustChildren(clip: clip, info: info, isAudio: false, isBase: true))
        }

        private func gapNode(offsetFrames: Int, durationFrames: Int) -> XMLNode {
            el("gap", attrs: [
                ("name", "Gap"),
                ("offset", (seqFrameDuration * offsetFrames).attr),
                ("duration", (seqFrameDuration * durationFrames).attr),
            ])
        }

        // MARK: - Connected items (audio in Phase 1; PIP/titles reuse this in later phases)

        /// One lane allocator per spine parent; visual children take positive lanes, audio negative.
        private final class LaneAllocator {
            private var nextVisualLane = 1
            private var nextAudioLane = -1
            func nextVisual() -> Int { defer { nextVisualLane += 1 }; return nextVisualLane }
            func nextAudio() -> Int { defer { nextAudioLane -= 1 }; return nextAudioLane }
        }

        /// Index of the spine child (clip or gap) whose sequence span contains `frame`.
        /// Each child carries its `[offset, end)` in frames plus its source frame duration (a gap runs
        /// at the sequence rate).
        private var spineSpans: [(offset: Int, end: Int, srcFD: Rational)] = []

        /// Attach connected children — overlay PIP (`<video>`, positive lanes) and audio-track clips
        /// (`<audio>`, negative lanes) — to the spine element that contains each clip's start frame.
        /// Mutates `children` in place. `spineSpans` (set by `buildSpine`) carries each child's
        /// `[offset, end)` in frames. Visual + audio share one allocator per parent so lanes stay
        /// consistent: overlays positive (front-ward by source-track stacking), audio negative.
        private func attachConnectedItems(into children: inout [XMLNode]) throws {
            guard !children.isEmpty else { return }

            // Shared lane allocator per parent index.
            var laneAllocators: [Int: LaneAllocator] = [:]
            func allocator(_ parentIndex: Int) -> LaneAllocator {
                if let a = laneAllocators[parentIndex] { return a }
                let a = LaneAllocator(); laneAllocators[parentIndex] = a; return a
            }

            // Overlay visual tracks → connected children on positive lanes. Walk non-base visual
            // tracks back→front (model order is top→bottom = front→back, so reversed index is
            // back→front): the track just behind the front gets lane 1, front-most the highest.
            // Dispatch each clip by media type: video/image → PIP `<video>`, text → `<title>`,
            // lottie → skip + warn, anything else → skip. text/lottie clips carry `mediaRef=""`, so
            // they never resolve to an asset — they take this independent path, not the asset one.
            // Hidden tracks emit too, as `enabled="0"`. Same-track clips are time-disjoint, so no
            // lane collision within a parent.
            for index in timeline.tracks.indices.reversed() {
                let track = timeline.tracks[index]
                guard track.type.isVisual, index != baseTrackIndex else { continue }
                let hidden = track.hidden
                for clip in track.clips.sorted(by: { $0.startFrame < $1.startFrame }) {
                    let parentIndex = spineElementIndex(containing: clip.startFrame)
                    let parentOffsetFrame = spineSpans[parentIndex].offset
                    let parentSrcFD = spineSpans[parentIndex].srcFD
                    let parentStart = Rational(attr: children[parentIndex].attribute("start") ?? "0s") ?? .zero
                    switch clip.mediaType {
                    case .video, .image:
                        guard let info = assetInfo[clip.mediaRef] else { continue }
                        let lane = allocator(parentIndex).nextVisual()
                        let node = connectedVideoNode(clip: clip, info: info, lane: lane,
                                                      parentStart: parentStart, parentSrcFrameDuration: parentSrcFD,
                                                      parentOffsetFrame: parentOffsetFrame,
                                                      enabled: !hidden)
                        children[parentIndex] = appendChild(node, to: children[parentIndex])
                    case .text:
                        let lane = allocator(parentIndex).nextVisual()
                        let node = titleNode(clip: clip, lane: lane,
                                             parentStart: parentStart, parentSrcFrameDuration: parentSrcFD,
                                             parentOffsetFrame: parentOffsetFrame,
                                             enabled: !hidden)
                        children[parentIndex] = appendChild(node, to: children[parentIndex])
                    case .lottie:
                        Log.export.warning(
                            "fcpxml: skipping Lottie clip \(resolver.displayName(for: clip.mediaRef)) (unsupported)")
                    case .audio:
                        continue
                    }
                }
            }

            // Audio-track clips → connected audio on negative lanes.
            for track in timeline.tracks where track.type == .audio {
                let muted = track.muted
                for clip in track.clips.sorted(by: { $0.startFrame < $1.startFrame }) {
                    guard let info = try (assetInfo[clip.mediaRef] ?? assetInfo(for: clip.mediaRef)) else { continue }
                    let parentIndex = spineElementIndex(containing: clip.startFrame)
                    let parentStart = Rational(attr: children[parentIndex].attribute("start") ?? "0s") ?? .zero
                    let lane = allocator(parentIndex).nextAudio()
                    let node = connectedAudioNode(clip: clip, info: info, lane: lane,
                                                  parentStart: parentStart,
                                                  parentSrcFrameDuration: spineSpans[parentIndex].srcFD,
                                                  parentOffsetFrame: spineSpans[parentIndex].offset,
                                                  enabled: !muted)
                    children[parentIndex] = appendChild(node, to: children[parentIndex])
                }
            }
        }

        /// Spine child index whose span contains `frame`; clamps to the last element otherwise.
        private func spineElementIndex(containing frame: Int) -> Int {
            for (i, span) in spineSpans.enumerated() where frame >= span.offset && frame < span.end {
                return i
            }
            return max(0, spineSpans.count - 1)
        }

        /// Connected child `offset` in the parent's local timeline: `parentStart + parentSrcFrameDuration · (childStart − parentOffset)`. The frame delta maps 1:1 (rate-conform), so the result lands on the parent's source-frame grid — which FCP requires for connected items ("edit frame boundary"). A gap parent has start 0 and runs at the sequence rate.
        private func connectedOffset(parentStart: Rational, parentSrcFrameDuration: Rational,
                                     parentOffsetFrame: Int, childStartFrame: Int) -> Rational {
            parentStart + parentSrcFrameDuration * (childStartFrame - parentOffsetFrame)
        }

        /// Connected `<audio>` — offset anchors to the parent on its source-frame grid (see
        /// `connectedOffset`). A gap parent has start `0s` and runs at the sequence rate.
        private func connectedAudioNode(clip: Clip, info: AssetInfo, lane: Int,
                                        parentStart: Rational, parentSrcFrameDuration: Rational,
                                        parentOffsetFrame: Int, enabled: Bool) -> XMLNode {
            let offset = connectedOffset(parentStart: parentStart, parentSrcFrameDuration: parentSrcFrameDuration,
                                         parentOffsetFrame: parentOffsetFrame, childStartFrame: clip.startFrame)
            let duration = seqFrameDuration * clip.durationFrames
            let start = sourceInPoint(clip: clip, info: info)
            var attrs: [(String, String)] = [
                ("ref", info.id),
                ("lane", String(lane)),
                ("offset", offset.attr),
                ("name", resolver.displayName(for: clip.mediaRef)),
                ("start", start.attr),
                ("duration", duration.attr),
            ]
            if !enabled { attrs.append(("enabled", "0")) }
            return el("audio", attrs: attrs, mediaAdjustChildren(clip: clip, info: info, isAudio: true, isBase: false))
        }

        /// Connected `<video>` (PIP) — video-only, positive lane. Offset anchors to the parent on its
        /// source-frame grid (see `connectedOffset`). Adjust-* children precede any nested lane items (DTD order).
        private func connectedVideoNode(clip: Clip, info: AssetInfo, lane: Int,
                                        parentStart: Rational, parentSrcFrameDuration: Rational,
                                        parentOffsetFrame: Int, enabled: Bool) -> XMLNode {
            let offset = connectedOffset(parentStart: parentStart, parentSrcFrameDuration: parentSrcFrameDuration,
                                         parentOffsetFrame: parentOffsetFrame, childStartFrame: clip.startFrame)
            let duration = seqFrameDuration * clip.durationFrames
            let start = sourceInPoint(clip: clip, info: info)
            var attrs: [(String, String)] = [
                ("ref", info.id),
                ("lane", String(lane)),
                ("offset", offset.attr),
                ("name", resolver.displayName(for: clip.mediaRef)),
                ("start", start.attr),
                ("duration", duration.attr),
            ]
            if !enabled { attrs.append(("enabled", "0")) }
            return el("video", attrs: attrs,
                      mediaAdjustChildren(clip: clip, info: info, isAudio: false, isBase: false))
        }

        // MARK: - Phase 4: per-clip adjustments (transform, opacity, crop, volume, speed, fade, conform-rate)

        /// Ordered adjust-* children for a media-backed node, satisfying the strict DTD child order.
        /// `<video>`: conform-rate? → timeMap? → adjust-crop? → adjust-transform? → adjust-blend?.
        /// `<audio>`: conform-rate? → timeMap? → adjust-volume?.
        /// Connected lane items are appended afterward by `attachConnectedItems`, so they stay last.
        private func mediaAdjustChildren(clip: Clip, info: AssetInfo, isAudio: Bool, isBase: Bool) -> [XMLNode] {
            var children: [XMLNode] = []
            if let cr = conformRateNode(clip: clip, info: info) { children.append(cr) }
            if let tm = timeMapNode(clip: clip, info: info) { children.append(tm) }
            if isAudio {
                if let vol = adjustVolumeNode(clip: clip) { children.append(vol) }
            } else {
                if let crop = adjustCropNode(clip: clip) { children.append(crop) }
                if let xf = adjustTransformNode(clip: clip, info: info, isBase: isBase) { children.append(xf) }
                if let blend = adjustBlendNode(clip: clip) { children.append(blend) }
            }
            return children
        }

        // MARK: Keyframe time + animation builders

        /// `<keyframeAnimation>` with one EMPTY `<keyframe time="…s" value="…"/>` per sample.
        /// `relFrame` is clip-relative; its time is `seqFrameDuration · relFrame`. No interp/curve
        /// attributes (matches the sample's `<keyframe time=".." value=".."/>`).
        private func keyframeAnimationNode(_ keyframes: [(relFrame: Int, value: String)]) -> XMLNode {
            el("keyframeAnimation", keyframes.map { kf in
                el("keyframe", attrs: [
                    ("time", (seqFrameDuration * kf.relFrame).attr),
                    ("value", kf.value),
                ])
            })
        }

        /// `<param name="…"><keyframeAnimation>…</keyframeAnimation></param>`.
        private func paramKF(name: String, keyframes: [(relFrame: Int, value: String)]) -> XMLNode {
            el("param", attrs: [("name", name)], [keyframeAnimationNode(keyframes)])
        }

        // MARK: dB + conform-rate helpers

        /// Export-only linear-gain → dB. Unlike `VolumeScale.dbFromLinear` (clamps at −60), this
        /// floors only at gain==0 → −96 dB, so quiet-but-nonzero gains keep their true dB.
        private func exportDb(_ gain: Double) -> Double { gain <= 0 ? -96 : 20 * log10(gain) }

        /// Nearest allowed `conform-rate` enum string for a source fps, or nil when no enum value is
        /// within ~0.3 fps (don't emit conform-rate for an unknown cadence).
        private func conformSrcRate(_ fps: Double) -> String? {
            var best: (string: String, diff: Double)?
            for entry in conformRateEnum {
                let diff = abs(entry.fps - fps)
                if best == nil || diff < best!.diff { best = (entry.string, diff) }
            }
            guard let best, best.diff <= 0.3 else { return nil }
            return best.string
        }

        // MARK: conform-rate

        /// `<conform-rate>` when a media-backed clip's source fps maps to an allowed enum value that
        /// differs from the timeline fps. `scaleEnabled="0"` only on speed-retimed clips (mirrors the
        /// sample's retimed clip). Images / text / unknown cadences emit nothing.
        private func conformRateNode(clip: Clip, info: AssetInfo) -> XMLNode? {
            guard info.kind != .image, let sourceFPS = info.entry.sourceFPS,
                  let srcStr = conformSrcRate(sourceFPS) else { return nil }
            let timelineStr = conformSrcRate(Double(timeline.fps))
            if srcStr == timelineStr { return nil }
            var attrs: [(String, String)] = []
            if clip.speed != 1.0 { attrs.append(("scaleEnabled", "0")) }
            attrs.append(("srcFrameRate", srcStr))
            return el("conform-rate", attrs: attrs)
        }

        // MARK: timeMap (speed)

        /// Constant-rate 2-point `<timeMap>` for a retimed clip (speed != 1). Time axis on the
        /// sequence grid, value on the source in-point; slope == speed. interp="smooth2" like the
        /// sample. [要検証] exact axis vs real FCP retime.
        private func timeMapNode(clip: Clip, info: AssetInfo) -> XMLNode? {
            guard clip.speed != 1.0 else { return nil }
            let inPoint = sourceInPoint(clip: clip, info: info)
            let localEnd = seqFrameDuration * clip.durationFrames
            let sourceConsumed = seqFrameDuration * Int((Double(clip.durationFrames) * clip.speed).rounded())
            let value1 = inPoint + sourceConsumed
            return el("timeMap", [
                el("timept", attrs: [("time", "0s"), ("value", inPoint.attr), ("interp", "smooth2")]),
                el("timept", attrs: [("time", localEnd.attr), ("value", value1.attr), ("interp", "smooth2")]),
            ])
        }

        // MARK: adjust-transform (base + PIP, static / keyframed, flip)

        /// `<adjust-transform>` or nil. Static path: fit-scale + center-origin position + negated
        /// rotation, with flip negating the matching scale axis. Base clips omit the node when fully
        /// identity (no keyframes, no flip); PIP overlays always emit one. Keyframed path: per-`<param>`
        /// keyframeAnimation over the union of position/scale/rotation kf frames; the params carry the
        /// animation, so the static attributes are dropped. [要検証] adjust-transform keyframe param
        /// names ("position"/"scale"/"rotation") not present in the sample.
        private func adjustTransformNode(clip: Clip, info: AssetInfo, isBase: Bool) -> XMLNode? {
            let t = clip.transform
            let seqW = Double(timeline.width)
            let seqH = Double(timeline.height)
            // adjust-transform position is in percent of canvas height (100 = full height), not pixels.
            let posUnit = 100.0 / seqH
            let srcW = Double(info.entry.sourceWidth ?? timeline.width)
            let srcH = Double(info.entry.sourceHeight ?? timeline.height)
            let fit = min(seqW / srcW, seqH / srcH)
            let flipX = t.flipHorizontal ? -1.0 : 1.0
            let flipY = t.flipVertical ? -1.0 : 1.0

            let posFrames = clip.keyframeFrames(for: .position)
            let scaleFrames = clip.keyframeFrames(for: .scale)
            let rotFrames = clip.keyframeFrames(for: .rotation)
            let keyframed = !posFrames.isEmpty || !scaleFrames.isEmpty || !rotFrames.isEmpty

            if keyframed {
                let frames = Set(posFrames + scaleFrames + rotFrames).sorted()
                let posKFs: [(Int, String)] = frames.map { f in
                    let xf = clip.transformAt(frame: f)
                    let px = (xf.centerX - 0.5) * seqW * posUnit
                    let py = (0.5 - xf.centerY) * seqH * posUnit
                    return (f - clip.startFrame, "\(fmt(px, 2)) \(fmt(py, 2))")
                }
                let scaleKFs: [(Int, String)] = frames.map { f in
                    let sz = clip.sizeAt(frame: f)
                    let sx = (sz.width * seqW) / (srcW * fit) * flipX
                    let sy = (sz.height * seqH) / (srcH * fit) * flipY
                    return (f - clip.startFrame, "\(fmt(sx, 4)) \(fmt(sy, 4))")
                }
                let rotKFs: [(Int, String)] = frames.map { f in
                    (f - clip.startFrame, fmt(-clip.rotationAt(frame: f), 2))
                }
                return el("adjust-transform", [
                    paramKF(name: "position", keyframes: posKFs),
                    paramKF(name: "scale", keyframes: scaleKFs),
                    paramKF(name: "rotation", keyframes: rotKFs),
                ])
            }

            let sx = (t.width * seqW) / (srcW * fit) * flipX
            let sy = (t.height * seqH) / (srcH * fit) * flipY
            let px = (t.centerX - 0.5) * seqW * posUnit
            let py = (0.5 - t.centerY) * seqH * posUnit
            let rot = -t.rotation
            // Base clips: omit a fully identity transform; PIP overlays always emit one.
            if isBase, px == 0, py == 0, sx == 1, sy == 1, rot == 0,
               !t.flipHorizontal, !t.flipVertical {
                return nil
            }
            return el("adjust-transform", attrs: [
                ("position", "\(fmt(px, 2)) \(fmt(py, 2))"),
                ("scale", "\(fmt(sx, 4)) \(fmt(sy, 4))"),
                ("rotation", fmt(rot, 2)),
            ])
        }

        // MARK: adjust-blend (opacity, with video fade)

        /// `<adjust-blend>` for opacity, or nil. Fade-in/out folds into the opacity envelope by
        /// forcing a keyframed animation over the union of opacity kf frames + fade boundary frames,
        /// each value = `rawOpacityAt · fadeMultiplier`. Static (no kf, no fade) at opacity 1 omits.
        /// [要検証] opacity→adjust-blend amount mapping (not in the sample).
        private func adjustBlendNode(clip: Clip) -> XMLNode? {
            let opacityFrames = clip.keyframeFrames(for: .opacity)
            let hasFade = clip.fadeInFrames > 0 || clip.fadeOutFrames > 0

            if !opacityFrames.isEmpty || hasFade {
                let frames = fadeSampleFrames(clip: clip, propertyFrames: opacityFrames)
                let kfs: [(Int, String)] = frames.map { f in
                    (f - clip.startFrame, fmt(clip.rawOpacityAt(frame: f) * clip.fadeMultiplier(at: f), 4))
                }
                return el("adjust-blend", [paramKF(name: "amount", keyframes: kfs)])
            }
            if clip.opacity == 1.0 { return nil }
            return el("adjust-blend", attrs: [("amount", fmt(clip.opacity, 4))])
        }

        // MARK: adjust-crop

        /// `<adjust-crop mode="trim">` or nil. trim-rect edges as a 0..100 percentage (mirrors the
        /// xmeml cropFilter unit). Keyframed crop nests per-edge `<param>` keyframeAnimations inside
        /// trim-rect. Identity crop with no kf omits. [要検証] FCP trim-rect unit/range.
        private func adjustCropNode(clip: Clip) -> XMLNode? {
            let cropFrames = clip.keyframeFrames(for: .crop)
            if cropFrames.isEmpty {
                if clip.crop.isIdentity { return nil }
                let c = clip.crop
                return el("adjust-crop", attrs: [("mode", "trim")], [
                    el("trim-rect", attrs: [
                        ("left", fmt(c.left * 100, 4)),
                        ("top", fmt(c.top * 100, 4)),
                        ("right", fmt(c.right * 100, 4)),
                        ("bottom", fmt(c.bottom * 100, 4)),
                    ]),
                ])
            }
            let frames = cropFrames.sorted()
            func edgeKFs(_ pick: (Crop) -> Double) -> [(Int, String)] {
                frames.map { f in (f - clip.startFrame, fmt(pick(clip.cropAt(frame: f)) * 100, 4)) }
            }
            return el("adjust-crop", attrs: [("mode", "trim")], [
                el("trim-rect", [
                    paramKF(name: "left", keyframes: edgeKFs { $0.left }),
                    paramKF(name: "top", keyframes: edgeKFs { $0.top }),
                    paramKF(name: "right", keyframes: edgeKFs { $0.right }),
                    paramKF(name: "bottom", keyframes: edgeKFs { $0.bottom }),
                ]),
            ])
        }

        // MARK: adjust-volume (with audio fade)

        /// `<adjust-volume>` for an audio clip, or nil. Fade-in/out folds into the gain envelope by
        /// forcing a keyframed animation over the union of volume kf frames + fade boundary frames,
        /// each value = `exportDb(rawVolumeAt · fadeMultiplier) + "dB"`. Static gain 1 (0 dB) with no
        /// kf / fade omits. [要検証] volume→adjust-volume dB mapping (not in the sample).
        private func adjustVolumeNode(clip: Clip) -> XMLNode? {
            let volumeFrames = clip.keyframeFrames(for: .volume)
            let hasFade = clip.fadeInFrames > 0 || clip.fadeOutFrames > 0

            if !volumeFrames.isEmpty || hasFade {
                let frames = fadeSampleFrames(clip: clip, propertyFrames: volumeFrames)
                let kfs: [(Int, String)] = frames.map { f in
                    let gain = clip.rawVolumeAt(frame: f) * clip.fadeMultiplier(at: f)
                    return (f - clip.startFrame, "\(fmt(exportDb(gain), 2))dB")
                }
                return el("adjust-volume", [paramKF(name: "amount", keyframes: kfs)])
            }
            if clip.volume == 1.0 { return nil }
            return el("adjust-volume", attrs: [("amount", "\(fmt(exportDb(clip.volume), 2))dB")])
        }

        /// Sample frames for a property animation. Without a fade, just the property's own kf frames
        /// (clamped, deduped, sorted). With a fade, those unioned with the fade boundary frames (clip
        /// start, end of fade-in, start of fade-out, last frame) so the fade envelope composes in.
        private func fadeSampleFrames(clip: Clip, propertyFrames: [Int]) -> [Int] {
            let lastFrame = max(clip.startFrame, clip.endFrame - 1)
            func clamp(_ f: Int) -> Int { min(max(f, clip.startFrame), lastFrame) }
            var s = Set(propertyFrames.map(clamp))
            if clip.fadeInFrames > 0 || clip.fadeOutFrames > 0 {
                s.insert(clip.startFrame)
                if clip.fadeInFrames > 0 { s.insert(clamp(clip.startFrame + clip.fadeInFrames)) }
                if clip.fadeOutFrames > 0 { s.insert(clamp(clip.endFrame - clip.fadeOutFrames)) }
                s.insert(lastFrame)
            }
            return s.sorted()
        }

        /// Fixed-decimal string matching the reference fcpxml's digit counts (position 2, scale 4).
        /// Normalizes `-0.0` to `0.0` so a zero never prints with a leading minus (matches reference).
        private func fmt(_ value: Double, _ places: Int) -> String {
            let v = value == 0 ? 0 : value
            return String(format: "%.\(places)f", v)
        }

        // MARK: - Titles (text overlays — the reason this exporter exists)

        /// The single shared Text `<effect>`; referenced by every `<title>`. Emitted into resources
        /// only when at least one telop exists (`usesTextEffect`).
        private func textEffectNode() -> XMLNode {
            el("effect", attrs: [
                ("id", textEffectId),
                ("name", "Text"),
                ("uid", ".../Titles.localized/Basic Text.localized/Text.localized/Text.moti"),
            ])
        }

        /// A connected `<title>` for a text clip. Offset anchors to the parent on its source-frame grid
        /// (see `connectedOffset`); `start` is the fixed template `3600s`. Children follow the strict
        /// DTD order param → text → text-style-def. text clips carry `mediaRef=""`, so this path reads
        /// `textContent`/`textStyle` directly and never touches the asset table.
        private func titleNode(clip: Clip, lane: Int,
                               parentStart: Rational, parentSrcFrameDuration: Rational,
                               parentOffsetFrame: Int, enabled: Bool) -> XMLNode {
            usesTextEffect = true
            let style = clip.textStyle ?? TextStyle()
            let content = clip.textContent ?? ""

            let offset = connectedOffset(parentStart: parentStart, parentSrcFrameDuration: parentSrcFrameDuration,
                                         parentOffsetFrame: parentOffsetFrame, childStartFrame: clip.startFrame)
            let duration = seqFrameDuration * clip.durationFrames

            let tsId = "ts\(nextTextStyleId)"; nextTextStyleId += 1

            // DTD order: param* , text , text-style-def.
            var children: [XMLNode] = []
            if let pos = positionParamNode(transform: clip.transform) { children.append(pos) }
            children.append(el("text", [
                XMLNode(name: "text-style", attributes: [("ref", tsId)], text: content),
            ]))
            children.append(textStyleDefNode(id: tsId, style: style))

            var attrs: [(String, String)] = [
                ("ref", textEffectId),
                ("lane", String(lane)),
                ("offset", offset.attr),
                ("name", titleName(content)),
                ("start", "3600s"),
                ("duration", duration.attr),
            ]
            if !enabled { attrs.append(("enabled", "0")) }
            return el("title", attrs: attrs, children)
        }

        /// `<param name="位置" …>` for the title position. Value is `((cx−0.5)·W·2, (0.5−cy)·H·2)`
        /// — the Text template's internal 2× canvas. Returns nil at center (param omitted = default).
        private func positionParamNode(transform: Transform) -> XMLNode? {
            let px = (transform.centerX - 0.5) * Double(timeline.width) * 2
            let py = (0.5 - transform.centerY) * Double(timeline.height) * 2
            if abs(px) < 1 && abs(py) < 1 { return nil }
            return el("param", attrs: [
                ("name", "位置"),
                ("key", "9999/10003/13260/3296672360/1/100/101"),
                ("value", "\(fmt(px, 2)) \(fmt(py, 2))"),
            ])
        }

        /// `<text-style-def>` carrying the title's font/size/color/alignment.
        /// fontSize = `fontSize · fontScale · (height/1080) · 2` (canvas normalization × template 2×);
        /// at 1080p / scale 1 this is the verified ×2. shadow/background/border are out of scope here.
        private func textStyleDefNode(id: String, style: TextStyle) -> XMLNode {
            let (family, face) = fcpFont(style.fontName)
            let size = style.fontSize * style.fontScale * (Double(timeline.height) / 1080.0) * 2
            let c = style.color
            var styleAttrs: [(String, String)] = [("font", family)]
            if let face { styleAttrs.append(("fontFace", face)) }
            styleAttrs.append(("fontSize", fontSizeString(size)))
            styleAttrs.append(("fontColor", "\(num(c.r)) \(num(c.g)) \(num(c.b)) \(num(c.a))"))
            styleAttrs.append(("alignment", style.alignment.rawValue))
            return el("text-style-def", attrs: [("id", id)], [
                XMLNode(name: "text-style", attributes: styleAttrs),
            ])
        }

        /// Map a Palmier PostScript-style font name to FCP family + optional fontFace.
        /// `HiraginoSans-W{n}` → ("Hiragino Sans", "W{n}"); otherwise (fontName, nil) — the bare
        /// PostScript name as family (matches the Python converter; no broader mapping table).
        private func fcpFont(_ name: String) -> (family: String, face: String?) {
            let prefix = "HiraginoSans-W"
            if name.hasPrefix(prefix) {
                let suffix = String(name.dropFirst(prefix.count))
                if !suffix.isEmpty && suffix.allSatisfy(\.isNumber) {
                    return ("Hiragino Sans", "W" + suffix)
                }
            }
            return (name, nil)
        }

        /// fontSize as an integer when whole (the reference's form, e.g. `116`), else minimal decimal.
        private func fontSizeString(_ size: Double) -> String {
            if size == size.rounded() { return String(Int(size.rounded())) }
            return String(format: "%g", size)
        }

        /// A color component as `0`/`1` when whole, else minimal decimal (matches `fontColor="1 1 1 1"`).
        private func num(_ value: Double) -> String {
            if value == value.rounded() { return String(Int(value.rounded())) }
            return String(format: "%g", value)
        }

        /// Title display name = first non-empty line of the content, capped at 40 chars; else "Title".
        private func titleName(_ content: String) -> String {
            let firstLine = content.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let trimmed = firstLine.isEmpty ? "Title" : firstLine
            return String(trimmed.prefix(40))
        }

        // MARK: - Source in-point

        /// FCP's fixed still-image in-point.
        private var stillStartTime: Rational { Rational(3600, 1) }

        /// `start = assetStartTime + trimStartFrame · sourceFrameDuration`; the trim is added on the
        /// SOURCE grid (rate-conform maps frames 1:1). Image → fixed `3600s`; TC-less assets start at 0.
        private func sourceInPoint(clip: Clip, info: AssetInfo) -> Rational {
            if info.kind == .image { return stillStartTime }
            // Rate-conform maps source frames 1:1 onto sequence frames, so a timeline-frame trim consumes the same count of source frames; add it on the source grid to keep start on it.
            let trim = info.frameDuration * max(0, clip.trimStartFrame)
            return info.startTime + trim
        }

        // MARK: - Rational frame durations

        /// Native asset frame duration from a source fps.
        /// NTSC (23.976, 29.97, …) → `1001/(round(fps)·1000)`; integer → `100/(fps·100)`.
        private func assetFrameDuration(fps: Double) -> Rational {
            let nominal = (fps.rounded())
            let ntscRate = nominal * 1000.0 / 1001.0
            if abs(fps - ntscRate) < 0.01 {
                return Rational(1001, Int(nominal) * 1000, reduce: false)
            }
            let f = max(1, Int(nominal))
            return Rational(100, f * 100, reduce: false)
        }

        /// Asset duration as a native-grid rational from the entry's seconds.
        private func assetDuration(entry: MediaManifestEntry, frameDuration: Rational) -> Rational {
            let seconds = max(0, entry.duration)
            // native frames = round(seconds / frameDuration) = round(seconds · den / num)
            let frames = Int((seconds * Double(frameDuration.den) / Double(frameDuration.num)).rounded())
            return frameDuration * frames
        }

        // MARK: - Timecode

        private func sourceTCFrame(url: URL) -> Int? {
            if let cached = tcFrameCache[url.path] { return cached }
            let frame = Builder.readStartTimecodeFrame(url: url)
            tcFrameCache[url.path] = frame
            return frame
        }

        /// Start frame from the QuickTime `tmcd` track (duplicated from `XMLExporter`).
        private static func readStartTimecodeFrame(url: URL) -> Int? {
            let asset = AVURLAsset(url: url)
            guard let track = asset.tracks(withMediaType: .timecode).first,
                  let reader = try? AVAssetReader(asset: asset) else { return nil }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }
            while let sample = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                var be: UInt32 = 0
                guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &be) == kCMBlockBufferNoErr
                else { return nil }
                return Int(UInt32(bigEndian: be))
            }
            return nil
        }

        // MARK: - Helpers

        /// Deterministic SHA-256 (hex, uppercase) of a path string — stable across runs.
        private static func contentHash(_ s: String) -> String {
            let digest = SHA256.hash(data: Data(s.utf8))
            return digest.map { String(format: "%02X", $0) }.joined()
        }

        /// `file://` URL string; `URL.absoluteString` already percent-encodes the path.
        private func fileURLString(_ url: URL) -> String {
            url.absoluteString
        }

        /// Append `child` to `node`'s children, preserving attributes/text.
        private func appendChild(_ child: XMLNode, to node: XMLNode) -> XMLNode {
            var copy = node
            copy.children.append(child)
            return copy
        }
    }
}

// MARK: - Rational seconds

/// Integer-arithmetic rational for FCPXML times (`num/den` seconds), avoiding float drift.
private struct Rational {
    var num: Int
    var den: Int

    static let zero = Rational(0, 1)

    init(_ num: Int, _ den: Int, reduce: Bool = true) {
        precondition(den != 0, "Rational denominator cannot be zero")
        var n = num, d = den
        if d < 0 { n = -n; d = -d }
        if reduce {
            let g = Rational.gcd(abs(n), d)
            if g > 1 { n /= g; d /= g }
        }
        self.num = n
        self.den = d
    }

    /// Parse `"num/dens"` or `"ns"` (the trailing `s` is the seconds unit).
    init?(attr: String) {
        guard attr.hasSuffix("s") else { return nil }
        let body = String(attr.dropLast())
        if let slash = body.firstIndex(of: "/") {
            guard let n = Int(body[body.startIndex..<slash]),
                  let d = Int(body[body.index(after: slash)...]) else { return nil }
            self.init(n, d, reduce: false)
        } else {
            guard let n = Int(body) else { return nil }
            self.init(n, 1, reduce: false)
        }
    }

    /// FCPXML attribute form: `"0s"` for zero, `"ns"` when the denominator is 1, else `"num/dens"`.
    var attr: String {
        if num == 0 { return "0s" }
        return den == 1 ? "\(num)s" : "\(num)/\(den)s"
    }

    static func + (lhs: Rational, rhs: Rational) -> Rational {
        Rational(lhs.num * rhs.den + rhs.num * lhs.den, lhs.den * rhs.den)
    }

    static func * (lhs: Rational, scalar: Int) -> Rational {
        Rational(lhs.num * scalar, lhs.den, reduce: false)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a == 0 ? 1 : a
    }
}

// MARK: - XML rendering

/// A minimal XML tree (duplicated from `XMLExporter.swift` to keep the xmeml exporter untouched).
/// The emitters above describe document *structure*; `render` owns every bit of whitespace and
/// escaping so no fragment ever hardcodes its own indentation.
private struct XMLNode {
    let name: String
    var attributes: [(String, String)] = []
    var text: String? = nil        // leaf value → `<name>text</name>`
    var children: [XMLNode] = []   // empty + no text → self-closing `<name/>`

    func attribute(_ name: String) -> String? {
        attributes.first(where: { $0.0 == name })?.1
    }
}

private func el(_ name: String, _ children: [XMLNode] = []) -> XMLNode {
    XMLNode(name: name, children: children)
}
private func el(_ name: String, attrs: [(String, String)], _ children: [XMLNode] = []) -> XMLNode {
    XMLNode(name: name, attributes: attrs, children: children)
}
private func leaf(_ name: String, _ value: String) -> XMLNode { XMLNode(name: name, text: value) }
private func leaf(_ name: String, _ value: Int) -> XMLNode { XMLNode(name: name, text: String(value)) }
private func bool(_ name: String, _ value: Bool) -> XMLNode { XMLNode(name: name, text: value ? "1" : "0") }

private func render(_ node: XMLNode, indent: Int) -> String {
    let pad = String(repeating: " ", count: indent)
    let attrs = node.attributes.map { " \($0.0)=\"\(escapeXML($0.1))\"" }.joined()
    if let text = node.text {
        return "\(pad)<\(node.name)\(attrs)>\(escapeXML(text))</\(node.name)>"
    }
    guard !node.children.isEmpty else { return "\(pad)<\(node.name)\(attrs)/>" }
    let inner = node.children.map { render($0, indent: indent + 2) }.joined(separator: "\n")
    return "\(pad)<\(node.name)\(attrs)>\n\(inner)\n\(pad)</\(node.name)>"
}

private func escapeXML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
     .replacingOccurrences(of: "'", with: "&apos;")
}
