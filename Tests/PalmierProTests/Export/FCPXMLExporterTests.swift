import Foundation
import Testing
@testable import PalmierPro

@Suite("FCPXMLExporter")
struct FCPXMLExporterTests {

    private func makeDir(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FCPXMLExporterTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Build a tmpdir + manifest + resolver. Creates each entry's external file on disk (empty by
    /// default — the exporter only needs file existence, except bookmark generation which any real
    /// file satisfies).
    private func makeResolver(entries: [MediaManifestEntry]) throws -> (MediaResolver, URL) {
        let tmpDir = try makeDir("res")
        for entry in entries {
            if case let .external(absolutePath) = entry.source {
                if !FileManager.default.fileExists(atPath: absolutePath) {
                    FileManager.default.createFile(atPath: absolutePath, contents: Data())
                }
            }
        }
        var manifest = MediaManifest()
        manifest.entries = entries
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })
        return (resolver, tmpDir)
    }

    /// Video manifest entry whose source is an empty temp file. `hasAudio`/`sourceFPS` configurable.
    private func videoEntry(id: String, in dir: URL, width: Int = 1920, height: Int = 1080,
                            fps: Double? = nil, hasAudio: Bool = false, duration: Double = 5) -> MediaManifestEntry {
        let path = dir.appendingPathComponent("\(id).mp4").path
        var e = MediaManifestEntry(id: id, name: id, type: .video,
                                   source: .external(absolutePath: path), duration: duration,
                                   sourceWidth: width, sourceHeight: height)
        e.sourceFPS = fps
        e.hasAudio = hasAudio
        return e
    }

    private func imageEntry(id: String, in dir: URL, width: Int = 1080, height: Int = 1080) -> MediaManifestEntry {
        let path = dir.appendingPathComponent("\(id).jpg").path
        return MediaManifestEntry(id: id, name: id, type: .image,
                                  source: .external(absolutePath: path), duration: 0,
                                  sourceWidth: width, sourceHeight: height)
    }

    private func audioEntry(id: String, in dir: URL, fps: Double? = nil, duration: Double = 5) -> MediaManifestEntry {
        let path = dir.appendingPathComponent("\(id).m4a").path
        var e = MediaManifestEntry(id: id, name: id, type: .audio,
                                   source: .external(absolutePath: path), duration: duration)
        e.sourceFPS = fps
        return e
    }

    private func exportXML(timeline: Timeline, resolver: MediaResolver, dir: URL) throws -> (String, XMLDocument) {
        let out = dir.appendingPathComponent("out-\(UUID().uuidString).fcpxml")
        try FCPXMLExporter.export(timeline: timeline, resolver: resolver, outputURL: out)
        let data = try Data(contentsOf: out)
        return (String(decoding: data, as: UTF8.self), try XMLDocument(data: data))
    }

    // MARK: - Well-formed skeleton (Phase 0 — must keep passing)

    @Test func outputIsWellFormedFCPXMLWithVersion() throws {
        let timeline = Fixtures.timeline()
        let (resolver, tmpDir) = try makeResolver(entries: [])
        let outURL = tmpDir.appendingPathComponent("out.fcpxml")

        try FCPXMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let data = try Data(contentsOf: outURL)
        let doc = try XMLDocument(data: data)
        let root = try #require(doc.rootElement())
        #expect(root.name == "fcpxml")
        #expect(root.attribute(forName: "version")?.stringValue == "1.9")
    }

    @Test func outputContainsLibraryEventProjectSequence() throws {
        let timeline = Fixtures.timeline()
        let (resolver, tmpDir) = try makeResolver(entries: [])
        let outURL = tmpDir.appendingPathComponent("out.fcpxml")

        try FCPXMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let doc = try XMLDocument(data: try Data(contentsOf: outURL))
        #expect(try !doc.nodes(forXPath: "/fcpxml/resources").isEmpty)
        #expect(try !doc.nodes(forXPath: "/fcpxml/library/event/project/sequence").isEmpty)
    }

    @Test func exportWritesFileToDisk() throws {
        let timeline = Fixtures.timeline()
        let (resolver, tmpDir) = try makeResolver(entries: [])
        let outURL = tmpDir.appendingPathComponent("written.fcpxml")

        #expect(!FileManager.default.fileExists(atPath: outURL.path))
        try FCPXMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)
        #expect(FileManager.default.fileExists(atPath: outURL.path))
    }

    @Test func fcpxmlExportThroughExportServiceWritesFileWithoutError() async throws {
        let (resolver, tmpDir) = try makeResolver(entries: [])
        let timeline = Fixtures.timeline()
        let outURL = tmpDir.appendingPathComponent("svc.fcpxml")

        let svc = await ExportService()
        await svc.export(
            timeline: timeline, resolver: resolver,
            format: .fcpxml, resolution: .r1080p, outputURL: outURL
        )
        await #expect(svc.error == nil)
        await #expect(svc.progress == 1.0)
        #expect(FileManager.default.fileExists(atPath: outURL.path))

        let doc = try XMLDocument(data: try Data(contentsOf: outURL))
        #expect(doc.rootElement()?.name == "fcpxml")
    }

    // MARK: - Sequence format from Int timeline fps

    @Test func sequenceFormatUsesTimelineFpsFrameDuration() throws {
        // 30 fps → 1/30 = 100/3000s; canvas dims flow into the sequence format.
        var timeline = Fixtures.timeline(fps: 30)
        timeline.width = 1920; timeline.height = 1080
        let (resolver, tmpDir) = try makeResolver(entries: [])
        let (_, doc) = try exportXML(timeline: timeline, resolver: resolver, dir: tmpDir)

        let seq = try #require(doc.nodes(forXPath: "/fcpxml/library/event/project/sequence").first as? XMLElement)
        let seqFormatId = try #require(seq.attribute(forName: "format")?.stringValue)
        let fmt = try #require(doc.nodes(forXPath: "/fcpxml/resources/format[@id='\(seqFormatId)']").first as? XMLElement)
        #expect(fmt.attribute(forName: "frameDuration")?.stringValue == "100/3000s")
        #expect(fmt.attribute(forName: "width")?.stringValue == "1920")
        #expect(fmt.attribute(forName: "height")?.stringValue == "1080")
        #expect(fmt.attribute(forName: "colorSpace")?.stringValue == "1-1-1 (Rec. 709)")
    }

    @Test func sequenceFormat24fpsFrameDuration() throws {
        let timeline = Fixtures.timeline(fps: 24)
        let (resolver, tmpDir) = try makeResolver(entries: [])
        let (_, doc) = try exportXML(timeline: timeline, resolver: resolver, dir: tmpDir)
        let seq = try #require(doc.nodes(forXPath: "//sequence").first as? XMLElement)
        let id = try #require(seq.attribute(forName: "format")?.stringValue)
        let fmt = try #require(doc.nodes(forXPath: "//format[@id='\(id)']").first as? XMLElement)
        #expect(fmt.attribute(forName: "frameDuration")?.stringValue == "100/2400s")
    }

    // MARK: - Asset & format structure

    @Test func videoAssetHasExpectedAttributesAndMediaRep() throws {
        let dir = try makeDir("vasset")
        let entry = videoEntry(id: "v1", in: dir, width: 3840, height: 2160, fps: 23.976, hasAudio: true)
        let (res, _) = try makeResolver(entries: [entry])

        let clip = Fixtures.clip(id: "c1", mediaRef: "v1", start: 0, duration: 24)
        let timeline = Fixtures.timeline(fps: 24, tracks: [Fixtures.videoTrack(clips: [clip])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let asset = try #require(doc.nodes(forXPath: "//asset[@name='v1']").first as? XMLElement)
        // Temp file carries no tmcd track → embedded-TC offset is 0, normalized to "0s".
        #expect(asset.attribute(forName: "start")?.stringValue == "0s")
        #expect(asset.attribute(forName: "hasVideo")?.stringValue == "1")
        #expect(asset.attribute(forName: "videoSources")?.stringValue == "1")
        #expect(asset.attribute(forName: "hasAudio")?.stringValue == "1")
        #expect(asset.attribute(forName: "audioSources")?.stringValue == "1")
        #expect(asset.attribute(forName: "audioChannels")?.stringValue == "2")
        #expect(asset.attribute(forName: "audioRate")?.stringValue == "48000")
        // uid == sig and both are 64 hex chars (SHA-256).
        let uid = try #require(asset.attribute(forName: "uid")?.stringValue)
        #expect(uid.count == 64)
        let mediaRep = try #require(asset.nodes(forXPath: "media-rep").first as? XMLElement)
        #expect(mediaRep.attribute(forName: "kind")?.stringValue == "original-media")
        #expect(mediaRep.attribute(forName: "sig")?.stringValue == uid)
        #expect(mediaRep.attribute(forName: "src")?.stringValue?.hasPrefix("file://") == true)

        // Asset duration as a native-grid rational: 5s @ 23.976 = round(5·24000/1001)=120 frames →
        // 120·1001 = 120120 over 24000.
        #expect(asset.attribute(forName: "duration")?.stringValue == "120120/24000s")

        // Asset format deduped by (W,H,fps); 23.976 → NTSC rational 1001/24000s.
        let formatId = try #require(asset.attribute(forName: "format")?.stringValue)
        let fmt = try #require(doc.nodes(forXPath: "//format[@id='\(formatId)']").first as? XMLElement)
        #expect(fmt.attribute(forName: "frameDuration")?.stringValue == "1001/24000s")
        #expect(fmt.attribute(forName: "width")?.stringValue == "3840")
        #expect(fmt.attribute(forName: "height")?.stringValue == "2160")
    }

    @Test func imageAssetHasNoAudioAndZeroDuration() throws {
        let dir = try makeDir("img")
        let entry = imageEntry(id: "img1", in: dir)
        let (res, _) = try makeResolver(entries: [entry])

        let clip = Fixtures.clip(id: "c1", mediaRef: "img1", mediaType: .image, start: 0, duration: 90)
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [clip])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let asset = try #require(doc.nodes(forXPath: "//asset[@name='img1']").first as? XMLElement)
        #expect(asset.attribute(forName: "start")?.stringValue == "0s")
        #expect(asset.attribute(forName: "duration")?.stringValue == "0s")
        #expect(asset.attribute(forName: "hasVideo")?.stringValue == "1")
        #expect(asset.attribute(forName: "hasAudio") == nil)
    }

    /// FIX 1: a still image references a native-pixel `FFVideoFormatRateUndefined` format (no
    /// frameDuration / colorSpace), matching real FCP output — NOT the sequence (canvas) format.
    @Test func imageAssetReferencesNativePixelRateUndefinedFormat() throws {
        let dir = try makeDir("imgfmt")
        // Native pixels 823×1000 (the reference case) differ from the 1920×1080 canvas.
        let entry = imageEntry(id: "img1", in: dir, width: 823, height: 1000)
        let (res, _) = try makeResolver(entries: [entry])

        let clip = Fixtures.clip(id: "c1", mediaRef: "img1", mediaType: .image, start: 0, duration: 60)
        var timeline = Fixtures.timeline(fps: 24, tracks: [Fixtures.videoTrack(clips: [clip])])
        timeline.width = 1920; timeline.height = 1080
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let asset = try #require(doc.nodes(forXPath: "//asset[@name='img1']").first as? XMLElement)
        let formatId = try #require(asset.attribute(forName: "format")?.stringValue)
        let fmt = try #require(doc.nodes(forXPath: "//format[@id='\(formatId)']").first as? XMLElement)
        // Native pixel size, rate-undefined name, no frameDuration / colorSpace.
        #expect(fmt.attribute(forName: "name")?.stringValue == "FFVideoFormatRateUndefined")
        #expect(fmt.attribute(forName: "width")?.stringValue == "823")
        #expect(fmt.attribute(forName: "height")?.stringValue == "1000")
        #expect(fmt.attribute(forName: "frameDuration") == nil)
        #expect(fmt.attribute(forName: "colorSpace") == nil)
        // It is NOT the sequence (canvas) format.
        let seq = try #require(doc.nodes(forXPath: "//sequence").first as? XMLElement)
        #expect(seq.attribute(forName: "format")?.stringValue != formatId)
    }

    /// FIX 1 guard: video assets are unchanged — they still reference a native-dimension format
    /// (which FCP handles correctly for moving footage).
    @Test func videoAssetStillReferencesNativeDimensionFormat() throws {
        let dir = try makeDir("vidfmt")
        let entry = videoEntry(id: "v1", in: dir, width: 3840, height: 2160, fps: 23.976)
        let (res, _) = try makeResolver(entries: [entry])

        let clip = Fixtures.clip(id: "c1", mediaRef: "v1", start: 0, duration: 24)
        var timeline = Fixtures.timeline(fps: 24, tracks: [Fixtures.videoTrack(clips: [clip])])
        timeline.width = 1920; timeline.height = 1080
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let asset = try #require(doc.nodes(forXPath: "//asset[@name='v1']").first as? XMLElement)
        let formatId = try #require(asset.attribute(forName: "format")?.stringValue)
        let fmt = try #require(doc.nodes(forXPath: "//format[@id='\(formatId)']").first as? XMLElement)
        // Native source dimensions, nameless asset format (the existing video convention).
        #expect(fmt.attribute(forName: "width")?.stringValue == "3840")
        #expect(fmt.attribute(forName: "height")?.stringValue == "2160")
        #expect(fmt.attribute(forName: "name") == nil)
        // Video's format is distinct from the sequence (canvas) format.
        let seq = try #require(doc.nodes(forXPath: "//sequence").first as? XMLElement)
        #expect(seq.attribute(forName: "format")?.stringValue != formatId)
    }

    @Test func assetFormatsDedupedByDimensionsAndFps() throws {
        // Two videos with identical (W,H,fps) share ONE asset format; a third with a different fps
        // gets its own. Sequence format is separate. Reference dedups asset formats this way.
        let dir = try makeDir("fmtdedup")
        let a = videoEntry(id: "a", in: dir, width: 1920, height: 1080, fps: 23.976)
        let b = videoEntry(id: "b", in: dir, width: 1920, height: 1080, fps: 23.976)
        let c = videoEntry(id: "c", in: dir, width: 1920, height: 1080, fps: 29.97)
        let (res, _) = try makeResolver(entries: [a, b, c])

        let timeline = Fixtures.timeline(fps: 24, tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "ca", mediaRef: "a", start: 0, duration: 10),
            Fixtures.clip(id: "cb", mediaRef: "b", start: 10, duration: 10),
            Fixtures.clip(id: "cc", mediaRef: "c", start: 20, duration: 10),
        ])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        // Distinct asset-format frameDurations: one 1001/24000 (shared by a+b) and one 1001/30000.
        let durations = try doc.nodes(forXPath: "//format/@frameDuration").compactMap { $0.stringValue }
        #expect(durations.contains("1001/24000s"))
        #expect(durations.contains("1001/30000s"))
        // a and b reference the same format id.
        let fa = try #require((doc.nodes(forXPath: "//asset[@name='a']").first as? XMLElement)?.attribute(forName: "format")?.stringValue)
        let fb = try #require((doc.nodes(forXPath: "//asset[@name='b']").first as? XMLElement)?.attribute(forName: "format")?.stringValue)
        let fc = try #require((doc.nodes(forXPath: "//asset[@name='c']").first as? XMLElement)?.attribute(forName: "format")?.stringValue)
        #expect(fa == fb)
        #expect(fa != fc)
    }

    @Test func sequenceCarriesReferenceAttributes() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [])
        let (_, doc) = try exportXML(timeline: Fixtures.timeline(fps: 24), resolver: resolver, dir: tmpDir)
        let seq = try #require(doc.nodes(forXPath: "//sequence").first as? XMLElement)
        #expect(seq.attribute(forName: "tcStart")?.stringValue == "0s")
        #expect(seq.attribute(forName: "tcFormat")?.stringValue == "NDF")
        #expect(seq.attribute(forName: "audioLayout")?.stringValue == "stereo")
        #expect(seq.attribute(forName: "audioRate")?.stringValue == "48k")
        #expect(seq.attribute(forName: "format") != nil)
        #expect(seq.attribute(forName: "duration") != nil)
    }

    // MARK: - ID integrity

    @Test func allIdsUniqueRefsResolveAndStartWithLetter() throws {
        let dir = try makeDir("ids")
        let v = videoEntry(id: "vid", in: dir, fps: 29.97, hasAudio: true)
        let img = imageEntry(id: "pic", in: dir)
        let aud = audioEntry(id: "snd", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [v, img, aud])

        let vClip = Fixtures.clip(id: "vc", mediaRef: "vid", start: 0, duration: 60)
        let imgClip = Fixtures.clip(id: "ic", mediaRef: "pic", mediaType: .image, start: 60, duration: 30)
        let aClip = Fixtures.clip(id: "ac", mediaRef: "snd", mediaType: .audio, start: 0, duration: 90)
        let timeline = Fixtures.timeline(fps: 30, tracks: [
            Fixtures.videoTrack(clips: [vClip, imgClip]),
            Fixtures.audioTrack(clips: [aClip]),
        ])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        // Collect all id attributes and all ref attributes.
        let idNodes = try doc.nodes(forXPath: "//*[@id]")
        var ids = Set<String>()
        for n in idNodes {
            let id = try #require((n as? XMLElement)?.attribute(forName: "id")?.stringValue)
            #expect(!ids.contains(id), "duplicate id \(id)")
            ids.insert(id)
            #expect(id.first?.isLetter == true, "id \(id) must start with a letter")
        }
        let refNodes = try doc.nodes(forXPath: "//*[@ref]")
        #expect(!refNodes.isEmpty)
        for n in refNodes {
            let ref = try #require((n as? XMLElement)?.attribute(forName: "ref")?.stringValue)
            #expect(ids.contains(ref), "ref \(ref) has no matching id")
        }
    }

    // MARK: - Spine gap coverage

    @Test func spineGapsCoverTimelineContiguously() throws {
        let dir = try makeDir("gap")
        let v = videoEntry(id: "vid", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [v])

        // Two clips with a hole between them and a head gap: [10,40), [100,160). total=160.
        let c1 = Fixtures.clip(id: "c1", mediaRef: "vid", start: 10, duration: 30)
        let c2 = Fixtures.clip(id: "c2", mediaRef: "vid", start: 100, duration: 60)
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [c1, c2])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let spine = try #require(doc.nodes(forXPath: "//spine").first as? XMLElement)
        let fps = 30
        // Each direct child of <spine> with an offset+duration; verify contiguity 0…total.
        var cursor = 0
        for child in spine.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            let off = try framesOf(child.attribute(forName: "offset")?.stringValue, fps: fps)
            let dur = try framesOf(child.attribute(forName: "duration")?.stringValue, fps: fps)
            #expect(off == cursor, "gap/clip at \(off) expected to start at \(cursor)")
            cursor = off + dur
        }
        #expect(cursor == 160, "spine must cover the full 160-frame timeline, got \(cursor)")
        // At least one gap exists (head + hole).
        #expect(!(try spine.nodes(forXPath: "gap")).isEmpty)
    }

    @Test func emptyVisualTimelineProducesAllGapSpine() throws {
        // Only an audio track → no base visual clips → spine is one full-length gap.
        let dir = try makeDir("allgap")
        let aud = audioEntry(id: "snd", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [aud])

        let a = Fixtures.clip(id: "ac", mediaRef: "snd", mediaType: .audio, start: 0, duration: 90)
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.audioTrack(clips: [a])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let spine = try #require(doc.nodes(forXPath: "//spine").first as? XMLElement)
        let gaps = try spine.nodes(forXPath: "gap")
        #expect(gaps.count == 1)
        let gap = try #require(gaps.first as? XMLElement)
        #expect(try framesOf(gap.attribute(forName: "offset")?.stringValue, fps: 30) == 0)
        #expect(try framesOf(gap.attribute(forName: "duration")?.stringValue, fps: 30) == 90)
    }

    // MARK: - No audio doubling

    @Test func linkedVideoAndAudioYieldExactlyOneAudioElement() throws {
        // Palmier splits a video import into a video clip + a separate audio clip. The visual clip
        // must emit <video> only (no embedded audio); audio comes solely from the audio track.
        let dir = try makeDir("dbl")
        let v = videoEntry(id: "vid", in: dir, fps: 30, hasAudio: true)
        let aud = audioEntry(id: "snd", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [v, aud])

        let vClip = Fixtures.clip(id: "vc", mediaRef: "vid", start: 0, duration: 60)
        let aClip = Fixtures.clip(id: "ac", mediaRef: "snd", mediaType: .audio, start: 0, duration: 60)
        let timeline = Fixtures.timeline(fps: 30, tracks: [
            Fixtures.videoTrack(clips: [vClip]),
            Fixtures.audioTrack(clips: [aClip]),
        ])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        // Exactly one <audio> element anywhere, and zero <asset-clip> (which would replay the
        // video's embedded audio under the already-separate audio clip).
        let audios = try doc.nodes(forXPath: "//audio")
        #expect(audios.count == 1)
        #expect(try doc.nodes(forXPath: "//asset-clip").isEmpty)
        // The single <audio> is the connected audio-track clip (carries a lane), nested under the
        // containing base <video>. The base element is a <video>, not an audio-bearing asset-clip.
        let audio = try #require(audios.first as? XMLElement)
        #expect(audio.attribute(forName: "lane") != nil)
        let video = try #require(doc.nodes(forXPath: "//spine/video").first as? XMLElement)
        #expect(video.attribute(forName: "ref")?.stringValue == "a1") // points at the video asset
        // The connected audio references the SEPARATE audio asset, not the video asset.
        #expect(audio.attribute(forName: "ref")?.stringValue != video.attribute(forName: "ref")?.stringValue)
    }

    // MARK: - Trimmed audio source in-point at timeline.fps != sourceFPS

    @Test func trimmedAudioStartUsesSourceGridAndZeroTC() throws {
        // 24-fps timeline + 29.97 source. TC=0 (temp file has none). trimStart=12 timeline frames.
        // Rate-conform maps frames 1:1, so the trim is added on the source grid:
        // source in-point = 0 + 12 · (1001/30000) = 12012/30000s, reduced to 1001/2500s.
        let dir = try makeDir("trim")
        let aud = audioEntry(id: "snd", in: dir, fps: 29.97)
        let (res, _) = try makeResolver(entries: [aud])

        let aClip = Fixtures.clip(id: "ac", mediaRef: "snd", mediaType: .audio, start: 0, duration: 48, trimStart: 12)
        let timeline = Fixtures.timeline(fps: 24, tracks: [Fixtures.audioTrack(clips: [aClip])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let audio = try #require(doc.nodes(forXPath: "//audio").first as? XMLElement)
        #expect(audio.attribute(forName: "start")?.stringValue == "1001/2500s")
        // lane is negative.
        let lane = try #require(audio.attribute(forName: "lane")?.stringValue)
        #expect((Int(lane) ?? 0) < 0)
    }

    // MARK: - Hidden / muted → enabled="0"

    @Test func mutedAudioClipCarriesEnabledZero() throws {
        let dir = try makeDir("mute")
        let aud = audioEntry(id: "snd", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [aud])

        let aClip = Fixtures.clip(id: "ac", mediaRef: "snd", mediaType: .audio, start: 0, duration: 60)
        var track = Fixtures.audioTrack(clips: [aClip]); track.muted = true
        let timeline = Fixtures.timeline(fps: 30, tracks: [track])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let audio = try #require(doc.nodes(forXPath: "//audio").first as? XMLElement)
        #expect(audio.attribute(forName: "enabled")?.stringValue == "0")
    }

    @Test func hiddenVisualTrackClipBecomesDisabledNotBase() throws {
        // A hidden visual track must not become the spine base. (In Phase 1, connected VISUAL
        // emission — PIP / higher tracks / hidden-visual retreats — is deferred to Phase 2, so the
        // hidden clip is simply not in the spine yet; only muted-AUDIO disabled retreats exist.)
        let dir = try makeDir("hide")
        let v = videoEntry(id: "vid", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [v])

        let vClip = Fixtures.clip(id: "vc", mediaRef: "vid", start: 0, duration: 60)
        var track = Fixtures.videoTrack(clips: [vClip]); track.hidden = true
        let timeline = Fixtures.timeline(fps: 30, tracks: [track])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        // No base <video> in the spine (hidden track can't be base); spine is a gap.
        #expect(try doc.nodes(forXPath: "//spine/video").isEmpty)
        #expect(try !doc.nodes(forXPath: "//spine/gap").isEmpty)
    }

    // MARK: - Bookmark actually generates

    @Test func bookmarkBase64IsNonEmptyForRealFile() throws {
        let dir = try makeDir("bm")
        let v = videoEntry(id: "vid", in: dir, fps: 30)
        // Real (non-empty) file so bookmarkData succeeds.
        try Data("payload".utf8).write(to: dir.appendingPathComponent("vid.mp4"))
        var manifest = MediaManifest(); manifest.entries = [v]
        let res = MediaResolver(manifest: { manifest }, projectURL: { nil })

        let clip = Fixtures.clip(id: "vc", mediaRef: "vid", start: 0, duration: 30)
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [clip])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let bookmark = try #require(doc.nodes(forXPath: "//asset/media-rep/bookmark").first as? XMLElement)
        let b64 = try #require(bookmark.stringValue)
        #expect(!b64.isEmpty)
        #expect(Data(base64Encoded: b64) != nil, "bookmark must be valid base64")
    }

    // MARK: - Phase 2: connected PIP (overlay video)

    /// Overlay clip nested in a GAP parent: offset = parentStart(=0s) + childStart·seqFD.
    @Test func gapAnchoredOverlayOffsetIsChildStartFromZero() throws {
        // Base track is empty (audio only beneath, so spine is one gap). The overlay sits on a
        // second visual track at frame 30 → connected <video> under the gap, offset = 30·(1/30)=1s.
        let dir = try makeDir("gapov")
        let ov = videoEntry(id: "ov", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [ov])

        let ovClip = Fixtures.clip(id: "oc", mediaRef: "ov", start: 30, duration: 30)
        // Two visual tracks: an empty base candidate and the overlay-bearing one. Neither has a
        // base because only the overlay track has clips → it becomes the (single) visible base.
        // To force a GAP anchor, make the overlay track HIDDEN so it can't be base; base becomes
        // nil → all-gap spine, overlay attaches to the gap as a disabled connected video.
        var ovTrack = Fixtures.videoTrack(clips: [ovClip]); ovTrack.hidden = true
        let timeline = Fixtures.timeline(fps: 30, tracks: [ovTrack])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        // Connected video lives under the gap, not as a direct spine child.
        #expect(try doc.nodes(forXPath: "//spine/video").isEmpty)
        let video = try #require(doc.nodes(forXPath: "//spine/gap/video").first as? XMLElement)
        // offset = 0 (gap parent start) + 30 source frames on the gap's grid (= seq grid) = 1s.
        #expect(try framesOf(video.attribute(forName: "offset")?.stringValue, fps: 30) == 30)
        #expect(video.attribute(forName: "offset")?.stringValue == "1s")
        // Hidden track → enabled="0".
        #expect(video.attribute(forName: "enabled")?.stringValue == "0")
    }

    /// Overlay nested in a base CLIP parent: offset = parentStart + (childStart − parentOffset).
    @Test func overlayOnBaseClipOffsetUsesParentStart() throws {
        let dir = try makeDir("ovbase")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let ov = videoEntry(id: "ov", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [base, ov])

        // Base clip [0,120) with trimStart=15 (source in-point 15/30=1/2s). Overlay [30,60) on a
        // front track → connected under the base <video>; offset = parentStart(1/2s) + (30−0)/30 = 1/2 + 1 = 3/2s.
        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 120, trimStart: 15)
        let ovClip = Fixtures.clip(id: "oc", mediaRef: "ov", start: 30, duration: 30)
        let timeline = Fixtures.timeline(fps: 30, tracks: [
            Fixtures.videoTrack(clips: [ovClip]),   // front (overlay)
            Fixtures.videoTrack(clips: [baseClip]), // back (base)
        ])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let video = try #require(doc.nodes(forXPath: "//spine/video").first as? XMLElement)
        // Base spine <video> references the "base" asset.
        let baseRef = try #require(video.attribute(forName: "ref")?.stringValue)
        let baseAsset = try #require(doc.nodes(forXPath: "//asset[@id='\(baseRef)']").first as? XMLElement)
        #expect(baseAsset.attribute(forName: "name")?.stringValue == "base")
        let pip = try #require(doc.nodes(forXPath: "//spine/video/video").first as? XMLElement)
        // parentStart 1/2s + 1s (30 source frames on the parent's grid) = 3/2s.
        #expect(pip.attribute(forName: "offset")?.stringValue == "3/2s")
        #expect(pip.attribute(forName: "lane")?.stringValue == "1")
    }

    /// Trimmed overlay source in-point on the source grid when timeline.fps != sourceFPS, TC=0.
    @Test func trimmedOverlayStartUsesSourceGrid() throws {
        // 24-fps timeline + 29.97 overlay source. trimStart=12 timeline frames → 12·(1001/30000) =
        // 12012/30000s, reduced to 1001/2500s.
        let dir = try makeDir("ovtrim")
        let base = videoEntry(id: "base", in: dir, fps: 24)
        let ov = videoEntry(id: "ov", in: dir, fps: 29.97)
        let (res, _) = try makeResolver(entries: [base, ov])

        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 96)
        let ovClip = Fixtures.clip(id: "oc", mediaRef: "ov", start: 0, duration: 48, trimStart: 12)
        let timeline = Fixtures.timeline(fps: 24, tracks: [
            Fixtures.videoTrack(clips: [ovClip]),
            Fixtures.videoTrack(clips: [baseClip]),
        ])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let pip = try #require(doc.nodes(forXPath: "//spine/video/video").first as? XMLElement)
        #expect(pip.attribute(forName: "start")?.stringValue == "1001/2500s")
    }

    /// Fit-scale ≈0.74 for a 16:9 source PIP'd into a 16:9 sequence at width/height ≈0.74.
    @Test func adjustTransformFitScaleForSixteenNine() throws {
        let dir = try makeDir("scale")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let ov = videoEntry(id: "ov", in: dir, width: 1920, height: 1080, fps: 30)
        let (res, _) = try makeResolver(entries: [base, ov])

        var ovClip = Fixtures.clip(id: "oc", mediaRef: "ov", start: 0, duration: 30)
        ovClip.transform = Transform(centerX: 0.5, centerY: 0.5, width: 0.74, height: 0.74)
        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 60)
        var timeline = Fixtures.timeline(fps: 30, tracks: [
            Fixtures.videoTrack(clips: [ovClip]),
            Fixtures.videoTrack(clips: [baseClip]),
        ])
        timeline.width = 1920; timeline.height = 1080
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let at = try #require(doc.nodes(forXPath: "//spine/video/video/adjust-transform").first as? XMLElement)
        // 16:9 into 16:9 → fit=1, so scale == (width, height) == 0.7400 0.7400.
        #expect(at.attribute(forName: "scale")?.stringValue == "0.7400 0.7400")
        // Centered → position 0,0.
        #expect(at.attribute(forName: "position")?.stringValue == "0.00 0.00")
        #expect(at.attribute(forName: "rotation")?.stringValue == "0.00")
    }

    /// Full-screen overlay (width=height=1, full-frame source) → identity scale ≈1.
    @Test func adjustTransformIdentityScaleForFullScreen() throws {
        let dir = try makeDir("ident")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let ov = videoEntry(id: "ov", in: dir, width: 1920, height: 1080, fps: 30)
        let (res, _) = try makeResolver(entries: [base, ov])

        let ovClip = Fixtures.clip(id: "oc", mediaRef: "ov", start: 0, duration: 30) // default transform: 1×1 centered
        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 60)
        var timeline = Fixtures.timeline(fps: 30, tracks: [
            Fixtures.videoTrack(clips: [ovClip]),
            Fixtures.videoTrack(clips: [baseClip]),
        ])
        timeline.width = 1920; timeline.height = 1080
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let at = try #require(doc.nodes(forXPath: "//spine/video/video/adjust-transform").first as? XMLElement)
        #expect(at.attribute(forName: "scale")?.stringValue == "1.0000 1.0000")
        #expect(at.attribute(forName: "position")?.stringValue == "0.00 0.00")
    }

    /// Position px maps off-center transform; rotation sign is negated (Palmier CW-positive).
    @Test func adjustTransformPositionAndNegatedRotation() throws {
        let dir = try makeDir("pos")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let ov = videoEntry(id: "ov", in: dir, width: 1920, height: 1080, fps: 30)
        let (res, _) = try makeResolver(entries: [base, ov])

        var ovClip = Fixtures.clip(id: "oc", mediaRef: "ov", start: 0, duration: 30)
        // Position is in % of canvas height: centerY 0.4 → py = (0.5−0.4)·100 = 10. centerX 0.5 → px 0. rotation 30 → −30.
        ovClip.transform = Transform(centerX: 0.5, centerY: 0.4, width: 0.74, height: 0.74, rotation: 30)
        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 60)
        var timeline = Fixtures.timeline(fps: 30, tracks: [
            Fixtures.videoTrack(clips: [ovClip]),
            Fixtures.videoTrack(clips: [baseClip]),
        ])
        timeline.width = 1920; timeline.height = 1080
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let at = try #require(doc.nodes(forXPath: "//spine/video/video/adjust-transform").first as? XMLElement)
        #expect(at.attribute(forName: "position")?.stringValue == "0.00 10.00")
        #expect(at.attribute(forName: "rotation")?.stringValue == "-30.00")
    }

    /// Two stacked PIP overlays + audio on one base clip → distinct lanes: visual positive
    /// front-ward, audio negative, all distinct.
    @Test func stackedOverlaysAndAudioGetDistinctLanes() throws {
        let dir = try makeDir("lanes")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let ovFront = videoEntry(id: "ovF", in: dir, fps: 30)
        let ovBack = videoEntry(id: "ovB", in: dir, fps: 30)
        let aud = audioEntry(id: "snd", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [base, ovFront, ovBack, aud])

        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 60)
        let frontClip = Fixtures.clip(id: "fc", mediaRef: "ovF", start: 0, duration: 30)
        let backClip = Fixtures.clip(id: "kc", mediaRef: "ovB", start: 0, duration: 30)
        let aClip = Fixtures.clip(id: "ac", mediaRef: "snd", mediaType: .audio, start: 0, duration: 30)
        // Model order top→bottom = front→back: [front, back, base, audio].
        let timeline = Fixtures.timeline(fps: 30, tracks: [
            Fixtures.videoTrack(clips: [frontClip]),
            Fixtures.videoTrack(clips: [backClip]),
            Fixtures.videoTrack(clips: [baseClip]),
            Fixtures.audioTrack(clips: [aClip]),
        ])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        // Two connected videos + one connected audio, all under the base <video>.
        let pipLanes = try doc.nodes(forXPath: "//spine/video/video/@lane").compactMap { Int($0.stringValue ?? "") }
        let audioLanes = try doc.nodes(forXPath: "//spine/video/audio/@lane").compactMap { Int($0.stringValue ?? "") }
        #expect(pipLanes.count == 2)
        #expect(audioLanes.count == 1)
        // Visual lanes positive; back-most overlay = lane 1, front-most = lane 2.
        #expect(Set(pipLanes) == Set([1, 2]))
        // Audio negative.
        #expect(audioLanes.allSatisfy { $0 < 0 })
        // All distinct.
        let all = pipLanes + audioLanes
        #expect(Set(all).count == all.count)
        // The front-most source track (ovF) gets the higher (front-ward) lane.
        let frontPip = try #require(doc.nodes(forXPath: "//spine/video/video[@name='ovF']").first as? XMLElement)
        let backPip = try #require(doc.nodes(forXPath: "//spine/video/video[@name='ovB']").first as? XMLElement)
        let frontLane = Int(frontPip.attribute(forName: "lane")?.stringValue ?? "0") ?? 0
        let backLane = Int(backPip.attribute(forName: "lane")?.stringValue ?? "0") ?? 0
        #expect(frontLane > backLane)
    }

    /// Hidden visual overlay track → connected <video> carries enabled="0".
    @Test func hiddenVisualOverlayCarriesEnabledZero() throws {
        let dir = try makeDir("hidov")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let ov = videoEntry(id: "ov", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [base, ov])

        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 60)
        let ovClip = Fixtures.clip(id: "oc", mediaRef: "ov", start: 0, duration: 30)
        var hiddenTrack = Fixtures.videoTrack(clips: [ovClip]); hiddenTrack.hidden = true
        let timeline = Fixtures.timeline(fps: 30, tracks: [
            hiddenTrack,                            // hidden overlay (front)
            Fixtures.videoTrack(clips: [baseClip]), // visible base (back)
        ])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        // Base is the visible track; the hidden overlay is a connected disabled <video>.
        let pip = try #require(doc.nodes(forXPath: "//spine/video/video[@name='ov']").first as? XMLElement)
        #expect(pip.attribute(forName: "enabled")?.stringValue == "0")
        // Base <video> itself is enabled (no enabled attr).
        let baseVideo = try #require(doc.nodes(forXPath: "//spine/video").first as? XMLElement)
        #expect(baseVideo.attribute(forName: "enabled") == nil)
    }

    // MARK: - Phase 3: titles (text overlays — the core feature)

    /// Build a text clip with the given content / style / transform (mediaRef="" — telops carry no media).
    private func textClip(id: String, content: String, style: TextStyle = TextStyle(),
                          transform: Transform = Transform(), start: Int, duration: Int,
                          enabledHidden: Bool = false) -> Clip {
        var c = Fixtures.clip(id: id, mediaRef: "", mediaType: .text, start: start, duration: duration)
        c.textContent = content
        c.textStyle = style
        c.transform = transform
        return c
    }

    private func textTrack(clips: [Clip], hidden: Bool = false) -> Track {
        var t = Track(type: .text, clips: clips)
        t.hidden = hidden
        return t
    }

    /// Trap guard: a text clip (mediaRef="", textContent set) is emitted as <title ref="rT">, NOT
    /// dropped by the asset-resolve filter.
    @Test func textClipIsEmittedAsTitle() throws {
        let dir = try makeDir("title")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [base])

        var style = TextStyle(); style.fontName = "HiraginoSans-W6"; style.fontSize = 58
        let title = textClip(id: "tc", content: "道の駅 川口", style: style, start: 0, duration: 60)
        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 120)
        let timeline = Fixtures.timeline(fps: 30, tracks: [
            textTrack(clips: [title]),               // front (telop)
            Fixtures.videoTrack(clips: [baseClip]),  // back (base)
        ])
        let (xml, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let titles = try doc.nodes(forXPath: "//title")
        #expect(titles.count == 1)
        let titleEl = try #require(titles.first as? XMLElement)
        #expect(titleEl.attribute(forName: "ref")?.stringValue == "rT")
        #expect(titleEl.attribute(forName: "start")?.stringValue == "3600s")
        // Body text survives.
        #expect(xml.contains("道の駅 川口"))
        // The effect is in resources exactly once.
        let effects = try doc.nodes(forXPath: "/fcpxml/resources/effect[@id='rT']")
        #expect(effects.count == 1)
        let effect = try #require(effects.first as? XMLElement)
        #expect(effect.attribute(forName: "name")?.stringValue == "Text")
        #expect(effect.attribute(forName: "uid")?.stringValue == ".../Titles.localized/Basic Text.localized/Text.localized/Text.moti")
    }

    /// Strict DTD child order: param → text → text-style-def (verified on an off-center title so the
    /// position param is present).
    @Test func titleChildOrderIsParamTextStyleDef() throws {
        let dir = try makeDir("order")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [base])

        // Off-center so the position param is emitted.
        let tf = Transform(centerX: 0.5, centerY: 0.8)
        let title = textClip(id: "tc", content: "下寄せ", transform: tf, start: 0, duration: 60)
        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 120)
        let timeline = Fixtures.timeline(fps: 30, tracks: [
            textTrack(clips: [title]),
            Fixtures.videoTrack(clips: [baseClip]),
        ])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let titleEl = try #require(doc.nodes(forXPath: "//title").first as? XMLElement)
        let childNames = (titleEl.children ?? []).compactMap { ($0 as? XMLElement)?.name }
        #expect(childNames == ["param", "text", "text-style-def"])
    }

    /// HiraginoSans-W6 maps to font="Hiragino Sans" fontFace="W6".
    @Test func titleFontFamilyAndFaceMapping() throws {
        let dir = try makeDir("font")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [base])

        var style = TextStyle(); style.fontName = "HiraginoSans-W6"
        let title = textClip(id: "tc", content: "テスト", style: style, start: 0, duration: 60)
        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 120)
        let timeline = Fixtures.timeline(fps: 30, tracks: [
            textTrack(clips: [title]),
            Fixtures.videoTrack(clips: [baseClip]),
        ])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let ts = try #require(doc.nodes(forXPath: "//text-style-def/text-style").first as? XMLElement)
        #expect(ts.attribute(forName: "font")?.stringValue == "Hiragino Sans")
        #expect(ts.attribute(forName: "fontFace")?.stringValue == "W6")
    }

    /// Non-Hiragino PostScript name → bare family, no fontFace.
    @Test func titleNonHiraginoFontHasNoFace() throws {
        let dir = try makeDir("font2")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [base])

        var style = TextStyle(); style.fontName = "Helvetica-Bold"
        let title = textClip(id: "tc", content: "x", style: style, start: 0, duration: 60)
        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 120)
        let timeline = Fixtures.timeline(fps: 30, tracks: [
            textTrack(clips: [title]),
            Fixtures.videoTrack(clips: [baseClip]),
        ])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let ts = try #require(doc.nodes(forXPath: "//text-style-def/text-style").first as? XMLElement)
        #expect(ts.attribute(forName: "font")?.stringValue == "Helvetica-Bold")
        #expect(ts.attribute(forName: "fontFace") == nil)
    }

    /// fontSize = fontSize · fontScale · (height/1080) · 2; 58 @ scale 1 @ 1080p → 116 (integer form).
    @Test func titleFontSizeFormula() throws {
        let dir = try makeDir("fsize")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [base])

        var style = TextStyle(); style.fontName = "HiraginoSans-W6"; style.fontSize = 58; style.fontScale = 1
        let title = textClip(id: "tc", content: "x", style: style, start: 0, duration: 60)
        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 120)
        var timeline = Fixtures.timeline(fps: 30, tracks: [
            textTrack(clips: [title]),
            Fixtures.videoTrack(clips: [baseClip]),
        ])
        timeline.width = 1920; timeline.height = 1080
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let ts = try #require(doc.nodes(forXPath: "//text-style-def/text-style").first as? XMLElement)
        #expect(ts.attribute(forName: "fontSize")?.stringValue == "116")
        #expect(ts.attribute(forName: "fontColor")?.stringValue == "1 1 1 1")
        #expect(ts.attribute(forName: "alignment")?.stringValue == "center")
    }

    /// fontScale folds into fontSize: 58 · 1.5 · 1 · 2 = 174.
    @Test func titleFontSizeIncludesFontScale() throws {
        let dir = try makeDir("fscale")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [base])

        var style = TextStyle(); style.fontSize = 58; style.fontScale = 1.5
        let title = textClip(id: "tc", content: "x", style: style, start: 0, duration: 60)
        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 120)
        var timeline = Fixtures.timeline(fps: 30, tracks: [
            textTrack(clips: [title]),
            Fixtures.videoTrack(clips: [baseClip]),
        ])
        timeline.width = 1920; timeline.height = 1080
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let ts = try #require(doc.nodes(forXPath: "//text-style-def/text-style").first as? XMLElement)
        #expect(ts.attribute(forName: "fontSize")?.stringValue == "174")
    }

    /// Position is 2× sequence pixels; centered titles omit the param.
    @Test func titlePositionDoublesAndOmitsWhenCentered() throws {
        let dir = try makeDir("tpos")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [base])

        // Lower title centerY 0.8 → py = (0.5−0.8)·1080·2 = −648. centerX 0.5 → px 0.
        let lower = textClip(id: "lc", content: "下", transform: Transform(centerX: 0.5, centerY: 0.8),
                             start: 0, duration: 30)
        // Centered title (default transform 0.5,0.5) → param omitted.
        let centered = textClip(id: "cc", content: "中", start: 30, duration: 30)
        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 120)
        var timeline = Fixtures.timeline(fps: 30, tracks: [
            textTrack(clips: [lower, centered]),
            Fixtures.videoTrack(clips: [baseClip]),
        ])
        timeline.width = 1920; timeline.height = 1080
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let lowerTitle = try #require(doc.nodes(forXPath: "//title[@name='下']").first as? XMLElement)
        let posParam = try #require(lowerTitle.nodes(forXPath: "param[@name='位置']").first as? XMLElement)
        #expect(posParam.attribute(forName: "key")?.stringValue == "9999/10003/13260/3296672360/1/100/101")
        #expect(posParam.attribute(forName: "value")?.stringValue == "0.00 -648.00")

        let centeredTitle = try #require(doc.nodes(forXPath: "//title[@name='中']").first as? XMLElement)
        #expect(try centeredTitle.nodes(forXPath: "param[@name='位置']").isEmpty)
    }

    /// Multi-line content is preserved literally inside the <text-style> (newlines kept).
    @Test func titleMultilineContentPreservesNewlines() throws {
        let dir = try makeDir("multiline")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [base])

        let title = textClip(id: "tc", content: "道の駅 川口\n✓ スポット登録", start: 0, duration: 60)
        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 120)
        let timeline = Fixtures.timeline(fps: 30, tracks: [
            textTrack(clips: [title]),
            Fixtures.videoTrack(clips: [baseClip]),
        ])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let inner = try #require(doc.nodes(forXPath: "//text/text-style").first as? XMLElement)
        #expect(inner.stringValue == "道の駅 川口\n✓ スポット登録")
        // Name is the first line only, capped.
        let titleEl = try #require(doc.nodes(forXPath: "//title").first as? XMLElement)
        #expect(titleEl.attribute(forName: "name")?.stringValue == "道の駅 川口")
    }

    /// Shared lane allocator: a parent with PIP + title + audio → visual lanes positive & distinct,
    /// audio negative.
    @Test func sharedLanesAcrossPipTitleAndAudio() throws {
        let dir = try makeDir("sharelane")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let pip = videoEntry(id: "pip", in: dir, fps: 30)
        let aud = audioEntry(id: "snd", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [base, pip, aud])

        let titleClip = textClip(id: "tc", content: "T", start: 0, duration: 30)
        let pipClip = Fixtures.clip(id: "pc", mediaRef: "pip", start: 0, duration: 30)
        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 60)
        let aClip = Fixtures.clip(id: "ac", mediaRef: "snd", mediaType: .audio, start: 0, duration: 30)
        // Model order top→bottom = front→back: [title, pip, base, audio].
        let timeline = Fixtures.timeline(fps: 30, tracks: [
            textTrack(clips: [titleClip]),
            Fixtures.videoTrack(clips: [pipClip]),
            Fixtures.videoTrack(clips: [baseClip]),
            Fixtures.audioTrack(clips: [aClip]),
        ])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        // Under the base <video>: one connected <video> (PIP), one <title>, one <audio>.
        let pipLane = try #require((doc.nodes(forXPath: "//spine/video/video").first as? XMLElement)?
            .attribute(forName: "lane")?.stringValue).flatMap { Int($0) }
        let titleLane = try #require((doc.nodes(forXPath: "//spine/video/title").first as? XMLElement)?
            .attribute(forName: "lane")?.stringValue).flatMap { Int($0) }
        let audioLane = try #require((doc.nodes(forXPath: "//spine/video/audio").first as? XMLElement)?
            .attribute(forName: "lane")?.stringValue).flatMap { Int($0) }
        let p = try #require(pipLane); let t = try #require(titleLane); let a = try #require(audioLane)
        // Visual lanes positive, distinct, front-ward: PIP (back) lane 1, title (front) lane 2.
        #expect(p == 1)
        #expect(t == 2)
        #expect(t > p)
        // Audio negative.
        #expect(a < 0)
        // All distinct.
        #expect(Set([p, t, a]).count == 3)
    }

    /// Two overlapping telops on stacked tracks get distinct lanes.
    @Test func overlappingTitlesGetDistinctLanes() throws {
        let dir = try makeDir("twotitle")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [base])

        let t1 = textClip(id: "t1", content: "A", start: 0, duration: 60)
        let t2 = textClip(id: "t2", content: "B", start: 0, duration: 60)
        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 120)
        let timeline = Fixtures.timeline(fps: 30, tracks: [
            textTrack(clips: [t1]),
            textTrack(clips: [t2]),
            Fixtures.videoTrack(clips: [baseClip]),
        ])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let lanes = try doc.nodes(forXPath: "//spine/video/title/@lane").compactMap { Int($0.stringValue ?? "") }
        #expect(lanes.count == 2)
        #expect(Set(lanes).count == 2)
        #expect(lanes.allSatisfy { $0 > 0 })
    }

    /// Hidden text track → <title> carries enabled="0".
    @Test func hiddenTitleTrackCarriesEnabledZero() throws {
        let dir = try makeDir("hidtitle")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [base])

        let title = textClip(id: "tc", content: "T", start: 0, duration: 30)
        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 60)
        let timeline = Fixtures.timeline(fps: 30, tracks: [
            textTrack(clips: [title], hidden: true),
            Fixtures.videoTrack(clips: [baseClip]),
        ])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let titleEl = try #require(doc.nodes(forXPath: "//title").first as? XMLElement)
        #expect(titleEl.attribute(forName: "enabled")?.stringValue == "0")
    }

    /// No telop anywhere → no <effect> in resources.
    @Test func noTitleMeansNoTextEffect() throws {
        let dir = try makeDir("noeffect")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [base])

        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 60)
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [baseClip])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        #expect(try doc.nodes(forXPath: "//effect").isEmpty)
        #expect(try doc.nodes(forXPath: "//title").isEmpty)
    }

    /// Title offset uses the connected formula (parentStart + (childStart − parentOffset)).
    @Test func titleOffsetUsesConnectedFormula() throws {
        let dir = try makeDir("toffset")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [base])

        // Base clip [0,120) trimStart=15 → source in-point 1/2s. Title [30,60) → offset = 1/2 + (30−0)/30 = 3/2s.
        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 120, trimStart: 15)
        let title = textClip(id: "tc", content: "T", start: 30, duration: 30)
        let timeline = Fixtures.timeline(fps: 30, tracks: [
            textTrack(clips: [title]),
            Fixtures.videoTrack(clips: [baseClip]),
        ])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let titleEl = try #require(doc.nodes(forXPath: "//spine/video/title").first as? XMLElement)
        // parentStart 1/2s + 1s (30 source frames on the parent's grid) = 3/2s.
        #expect(titleEl.attribute(forName: "offset")?.stringValue == "3/2s")
        // Duration on the sequence grid: 30 frames @ 30fps.
        #expect(try framesOf(titleEl.attribute(forName: "duration")?.stringValue, fps: 30) == 30)
    }

    /// Lottie clip is skipped entirely (no node in the output).
    @Test func lottieClipIsSkipped() throws {
        let dir = try makeDir("lottie")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [base])

        // A lottie clip (mediaRef set but type lottie) on an overlay track → skipped.
        var lottie = Fixtures.clip(id: "lc", mediaRef: "anim", mediaType: .lottie, start: 0, duration: 30)
        lottie.sourceClipType = .lottie
        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 60)
        let timeline = Fixtures.timeline(fps: 30, tracks: [
            Track(type: .lottie, clips: [lottie]),
            Fixtures.videoTrack(clips: [baseClip]),
        ])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        // The base <video> is present; nothing references the lottie, no title/asset for it.
        #expect(try !doc.nodes(forXPath: "//spine/video").isEmpty)
        // Only the base <video>, no connected child video/title for the lottie.
        #expect(try doc.nodes(forXPath: "//spine/video/video").isEmpty)
        #expect(try doc.nodes(forXPath: "//title").isEmpty)
    }

    // MARK: - Phase 4: opacity (adjust-blend)

    @Test func opacityStaticEmitsAdjustBlend() throws {
        let dir = try makeDir("op-static")
        let v = videoEntry(id: "vid", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [v])

        var clip = Fixtures.clip(id: "c1", mediaRef: "vid", start: 0, duration: 30)
        clip.opacity = 0.5
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [clip])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let blend = try #require(doc.nodes(forXPath: "//spine/video/adjust-blend").first as? XMLElement)
        #expect(blend.attribute(forName: "amount")?.stringValue == "0.5000")
    }

    @Test func opacityOneOmitsAdjustBlend() throws {
        let dir = try makeDir("op-one")
        let v = videoEntry(id: "vid", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [v])

        let clip = Fixtures.clip(id: "c1", mediaRef: "vid", start: 0, duration: 30) // opacity defaults to 1.0
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [clip])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        #expect(try doc.nodes(forXPath: "//adjust-blend").isEmpty)
    }

    @Test func opacityKeyframedEmitsKeyframeAnimation() throws {
        let dir = try makeDir("op-kf")
        let v = videoEntry(id: "vid", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [v])

        var clip = Fixtures.clip(id: "c1", mediaRef: "vid", start: 0, duration: 60)
        // Frames are CLIP-RELATIVE in track storage (Keyframe.upsert stores via toOffset).
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0.0),
            Keyframe(frame: 30, value: 1.0),
        ])
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [clip])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let kfs = try doc.nodes(forXPath: "//adjust-blend/param[@name='amount']/keyframeAnimation/keyframe")
        #expect(kfs.count == 2)
        let first = try #require(kfs.first as? XMLElement)
        #expect(first.attribute(forName: "value")?.stringValue == "0.0000")
        #expect(first.attribute(forName: "time")?.stringValue == "0s")
    }

    // MARK: - Phase 4: crop (adjust-crop)

    @Test func cropStaticEmitsTrimRectPercent() throws {
        let dir = try makeDir("crop-static")
        let v = videoEntry(id: "vid", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [v])

        var clip = Fixtures.clip(id: "c1", mediaRef: "vid", start: 0, duration: 30)
        clip.crop = Crop(left: 0.1, top: 0, right: 0.1, bottom: 0)
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [clip])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let crop = try #require(doc.nodes(forXPath: "//spine/video/adjust-crop[@mode='trim']").first as? XMLElement)
        let rect = try #require(crop.nodes(forXPath: "trim-rect").first as? XMLElement)
        #expect(rect.attribute(forName: "left")?.stringValue == "10.0000")
        #expect(rect.attribute(forName: "right")?.stringValue == "10.0000")
        #expect(rect.attribute(forName: "top")?.stringValue == "0.0000")
    }

    @Test func cropIdentityOmitsAdjustCrop() throws {
        let dir = try makeDir("crop-id")
        let v = videoEntry(id: "vid", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [v])

        let clip = Fixtures.clip(id: "c1", mediaRef: "vid", start: 0, duration: 30) // identity crop
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [clip])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        #expect(try doc.nodes(forXPath: "//adjust-crop").isEmpty)
    }

    @Test func cropKeyframedEmitsPerEdgeKeyframeAnimation() throws {
        let dir = try makeDir("crop-kf")
        let v = videoEntry(id: "vid", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [v])

        var clip = Fixtures.clip(id: "c1", mediaRef: "vid", start: 0, duration: 60)
        clip.cropTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: Crop(left: 0, top: 0, right: 0, bottom: 0)),
            Keyframe(frame: 30, value: Crop(left: 0.2, top: 0, right: 0, bottom: 0)),
        ])
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [clip])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let leftKFs = try doc.nodes(forXPath: "//adjust-crop/trim-rect/param[@name='left']/keyframeAnimation/keyframe")
        #expect(leftKFs.count == 2)
    }

    // MARK: - Phase 4: transform (keyframed + flip)

    @Test func transformKeyframedEmitsPositionScaleRotationParams() throws {
        let dir = try makeDir("xf-kf")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let ov = videoEntry(id: "ov", in: dir, width: 1920, height: 1080, fps: 30)
        let (res, _) = try makeResolver(entries: [base, ov])

        var ovClip = Fixtures.clip(id: "oc", mediaRef: "ov", start: 0, duration: 60)
        ovClip.positionTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: AnimPair(a: 0.4, b: 0.4)),
            Keyframe(frame: 30, value: AnimPair(a: 0.6, b: 0.6)),
        ])
        ovClip.scaleTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: AnimPair(a: 0.5, b: 0.5)),
            Keyframe(frame: 30, value: AnimPair(a: 0.7, b: 0.7)),
        ])
        ovClip.rotationTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0.0),
            Keyframe(frame: 30, value: 45.0),
        ])
        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 120)
        var timeline = Fixtures.timeline(fps: 30, tracks: [
            Fixtures.videoTrack(clips: [ovClip]),
            Fixtures.videoTrack(clips: [baseClip]),
        ])
        timeline.width = 1920; timeline.height = 1080
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let posKFs = try doc.nodes(forXPath: "//spine/video/video/adjust-transform/param[@name='position']/keyframeAnimation/keyframe")
        let scaleKFs = try doc.nodes(forXPath: "//spine/video/video/adjust-transform/param[@name='scale']/keyframeAnimation/keyframe")
        let rotKFs = try doc.nodes(forXPath: "//spine/video/video/adjust-transform/param[@name='rotation']/keyframeAnimation/keyframe")
        #expect(posKFs.count == 2)
        #expect(scaleKFs.count == 2)
        #expect(rotKFs.count == 2)
    }

    @Test func transformFlipNegatesScaleAxis() throws {
        let dir = try makeDir("xf-flip")
        let base = videoEntry(id: "base", in: dir, fps: 30)
        let ovH = videoEntry(id: "ovH", in: dir, width: 1920, height: 1080, fps: 30)
        let ovV = videoEntry(id: "ovV", in: dir, width: 1920, height: 1080, fps: 30)
        let (res, _) = try makeResolver(entries: [base, ovH, ovV])

        var hClip = Fixtures.clip(id: "hc", mediaRef: "ovH", start: 0, duration: 30)
        hClip.transform = Transform(centerX: 0.5, centerY: 0.5, width: 1, height: 1, flipHorizontal: true)
        var vClip = Fixtures.clip(id: "vc", mediaRef: "ovV", start: 0, duration: 30)
        vClip.transform = Transform(centerX: 0.5, centerY: 0.5, width: 1, height: 1, flipVertical: true)
        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 60)
        var timeline = Fixtures.timeline(fps: 30, tracks: [
            Fixtures.videoTrack(clips: [hClip]),
            Fixtures.videoTrack(clips: [vClip]),
            Fixtures.videoTrack(clips: [baseClip]),
        ])
        timeline.width = 1920; timeline.height = 1080
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let hAt = try #require(doc.nodes(forXPath: "//spine/video/video[@name='ovH']/adjust-transform").first as? XMLElement)
        #expect(hAt.attribute(forName: "scale")?.stringValue == "-1.0000 1.0000")
        let vAt = try #require(doc.nodes(forXPath: "//spine/video/video[@name='ovV']/adjust-transform").first as? XMLElement)
        #expect(vAt.attribute(forName: "scale")?.stringValue == "1.0000 -1.0000")
    }

    // MARK: - Phase 4: volume (adjust-volume)

    @Test func volumeStaticConvertsLinearToDb() throws {
        let dir = try makeDir("vol-static")
        let aud = audioEntry(id: "snd", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [aud])

        let aClip = Fixtures.clip(id: "ac", mediaRef: "snd", mediaType: .audio, start: 0, duration: 60, volume: 0.5)
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.audioTrack(clips: [aClip])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let vol = try #require(doc.nodes(forXPath: "//audio/adjust-volume").first as? XMLElement)
        let expected = String(format: "%.2f", 20 * log10(0.5)) + "dB"
        #expect(vol.attribute(forName: "amount")?.stringValue == expected)
        #expect(expected == "-6.02dB")
    }

    @Test func volumeOneOmitsAdjustVolume() throws {
        let dir = try makeDir("vol-one")
        let aud = audioEntry(id: "snd", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [aud])

        let aClip = Fixtures.clip(id: "ac", mediaRef: "snd", mediaType: .audio, start: 0, duration: 60) // volume 1.0
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.audioTrack(clips: [aClip])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        #expect(try doc.nodes(forXPath: "//adjust-volume").isEmpty)
    }

    @Test func volumeUnclampedQuietAndGainZero() throws {
        // Static volume field (not the dB-clamped track): exercises the unclamped export-dB path.
        let dir = try makeDir("vol-quiet")
        let quiet = audioEntry(id: "q", in: dir, fps: 30)
        let silent = audioEntry(id: "z", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [quiet, silent])

        // volume 0.0001 → exportDb = 20·log10(1e-4) = -80 (NOT clamped to -60).
        let qClip = Fixtures.clip(id: "qc", mediaRef: "q", mediaType: .audio, start: 0, duration: 30, volume: 0.0001)
        // volume 0 → exportDb floors at -96.
        let zClip = Fixtures.clip(id: "zc", mediaRef: "z", mediaType: .audio, start: 0, duration: 30, volume: 0.0)
        let timeline = Fixtures.timeline(fps: 30, tracks: [
            Fixtures.audioTrack(clips: [qClip]),
            Fixtures.audioTrack(clips: [zClip]),
        ])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let qVol = try #require(doc.nodes(forXPath: "//audio[@name='q']/adjust-volume").first as? XMLElement)
        #expect(qVol.attribute(forName: "amount")?.stringValue == "-80.00dB")
        let zVol = try #require(doc.nodes(forXPath: "//audio[@name='z']/adjust-volume").first as? XMLElement)
        #expect(zVol.attribute(forName: "amount")?.stringValue == "-96.00dB")
    }

    @Test func fadeComposesWithVolumeAsKeyframes() throws {
        let dir = try makeDir("vol-fade")
        let aud = audioEntry(id: "snd", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [aud])

        var aClip = Fixtures.clip(id: "ac", mediaRef: "snd", mediaType: .audio, start: 0, duration: 60, volume: 0.5)
        aClip.fadeInFrames = 10
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.audioTrack(clips: [aClip])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let kfs = try doc.nodes(forXPath: "//audio/adjust-volume/param[@name='amount']/keyframeAnimation/keyframe")
        #expect(kfs.count >= 2)
        // First keyframe at clip start = silence (fadeMultiplier 0 → exportDb(0) = -96).
        let first = try #require(kfs.first as? XMLElement)
        #expect(first.attribute(forName: "value")?.stringValue == "-96.00dB")
        // A later keyframe reaches the authored gain (exportDb(0.5) = -6.02).
        let values = kfs.compactMap { ($0 as? XMLElement)?.attribute(forName: "value")?.stringValue }
        #expect(values.contains("-6.02dB"))
    }

    @Test func videoFadeComposesWithOpacityAsKeyframes() throws {
        let dir = try makeDir("op-fade")
        let v = videoEntry(id: "vid", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [v])

        var clip = Fixtures.clip(id: "c1", mediaRef: "vid", start: 0, duration: 60) // opacity 1.0
        clip.fadeInFrames = 10
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [clip])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let kfs = try doc.nodes(forXPath: "//spine/video/adjust-blend/param[@name='amount']/keyframeAnimation/keyframe")
        #expect(kfs.count >= 2)
        let first = try #require(kfs.first as? XMLElement)
        #expect(first.attribute(forName: "value")?.stringValue == "0.0000")
    }

    // MARK: - Phase 4: speed (timeMap)

    @Test func speedEmitsTwoPointTimeMapWithCorrectSlope() throws {
        let dir = try makeDir("speed")
        let v = videoEntry(id: "vid", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [v])

        let clip = Fixtures.clip(id: "c1", mediaRef: "vid", start: 0, duration: 60, speed: 2.0)
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [clip])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let timepts = try doc.nodes(forXPath: "//spine/video/timeMap/timept")
        #expect(timepts.count == 2)
        let p0 = try #require(timepts.first as? XMLElement)
        let p1 = try #require(timepts.last as? XMLElement)
        #expect(p0.attribute(forName: "time")?.stringValue == "0s")
        // Slope = (value1 - value0) / (time1 - time0) == speed.
        let t0 = try rationalSeconds(p0.attribute(forName: "time")?.stringValue)
        let v0 = try rationalSeconds(p0.attribute(forName: "value")?.stringValue)
        let t1 = try rationalSeconds(p1.attribute(forName: "time")?.stringValue)
        let v1 = try rationalSeconds(p1.attribute(forName: "value")?.stringValue)
        let slope = (v1 - v0) / (t1 - t0)
        #expect(abs(slope - 2.0) < 0.001)
    }

    @Test func speedTimeMapValueStartsAtSourceInPoint() throws {
        let dir = try makeDir("speed-trim")
        let v = videoEntry(id: "vid", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [v])

        // trimStart=15 @ 30fps timeline grid → source in-point 15/30 = 1/2s.
        let clip = Fixtures.clip(id: "c1", mediaRef: "vid", start: 0, duration: 60, trimStart: 15, speed: 2.0)
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [clip])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let p0 = try #require(doc.nodes(forXPath: "//spine/video/timeMap/timept").first as? XMLElement)
        #expect(p0.attribute(forName: "value")?.stringValue == "1/2s")
    }

    // MARK: - Phase 4: composite DTD child order

    @Test func videoChildOrderFollowsDTD() throws {
        // One base video carrying speed (timeMap) + crop + transform + opacity + conform-rate, plus
        // a connected audio child. The <video>'s direct children must lead with the strict order.
        let dir = try makeDir("vorder")
        let base = videoEntry(id: "base", in: dir, width: 1920, height: 1080, fps: 23.976)
        let aud = audioEntry(id: "snd", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [base, aud])

        var baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 60, speed: 2.0)
        baseClip.crop = Crop(left: 0.1, top: 0, right: 0, bottom: 0)
        baseClip.transform = Transform(centerX: 0.4, centerY: 0.5, width: 0.5, height: 0.5)
        baseClip.opacity = 0.5
        let aClip = Fixtures.clip(id: "ac", mediaRef: "snd", mediaType: .audio, start: 0, duration: 60)
        var timeline = Fixtures.timeline(fps: 24, tracks: [
            Fixtures.videoTrack(clips: [baseClip]),
            Fixtures.audioTrack(clips: [aClip]),
        ])
        timeline.width = 1920; timeline.height = 1080
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let videoEl = try #require(doc.nodes(forXPath: "//spine/video").first as? XMLElement)
        let names = (videoEl.children ?? []).compactMap { ($0 as? XMLElement)?.name }
        let prefix = Array(names.prefix(5))
        #expect(prefix == ["conform-rate", "timeMap", "adjust-crop", "adjust-transform", "adjust-blend"])
        // Lane children (the connected audio) come after the adjust-* block.
        #expect(names.dropFirst(5).contains("audio"))
    }

    @Test func audioChildOrderFollowsDTD() throws {
        let dir = try makeDir("aorder")
        let base = videoEntry(id: "base", in: dir, fps: 24)
        let aud = audioEntry(id: "snd", in: dir, fps: 23.976)
        let (res, _) = try makeResolver(entries: [base, aud])

        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 60)
        let aClip = Fixtures.clip(id: "ac", mediaRef: "snd", mediaType: .audio, start: 0, duration: 60,
                                  speed: 2.0, volume: 0.5)
        let timeline = Fixtures.timeline(fps: 24, tracks: [
            Fixtures.videoTrack(clips: [baseClip]),
            Fixtures.audioTrack(clips: [aClip]),
        ])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let audioEl = try #require(doc.nodes(forXPath: "//audio").first as? XMLElement)
        let names = (audioEl.children ?? []).compactMap { ($0 as? XMLElement)?.name }
        #expect(names == ["conform-rate", "timeMap", "adjust-volume"])
    }

    // MARK: - Phase 4: conform-rate

    @Test func conformRateEmittedForFpsMismatch() throws {
        let dir = try makeDir("conform")
        let v = videoEntry(id: "vid", in: dir, fps: 23.976)
        let (res, _) = try makeResolver(entries: [v])

        let clip = Fixtures.clip(id: "c1", mediaRef: "vid", start: 0, duration: 24)
        let timeline = Fixtures.timeline(fps: 24, tracks: [Fixtures.videoTrack(clips: [clip])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let cr = try #require(doc.nodes(forXPath: "//spine/video/conform-rate[@srcFrameRate='23.98']").first as? XMLElement)
        #expect(cr.attribute(forName: "scaleEnabled") == nil)
    }

    @Test func conformRateRetimedHasScaleEnabledZero() throws {
        let dir = try makeDir("conform-retime")
        let v = videoEntry(id: "vid", in: dir, fps: 23.976)
        let (res, _) = try makeResolver(entries: [v])

        let clip = Fixtures.clip(id: "c1", mediaRef: "vid", start: 0, duration: 24, speed: 0.5)
        let timeline = Fixtures.timeline(fps: 24, tracks: [Fixtures.videoTrack(clips: [clip])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        let cr = try #require(doc.nodes(forXPath: "//spine/video/conform-rate").first as? XMLElement)
        #expect(cr.attribute(forName: "srcFrameRate")?.stringValue == "23.98")
        #expect(cr.attribute(forName: "scaleEnabled")?.stringValue == "0")
    }

    @Test func conformRateOmittedWhenSourceMatchesTimeline() throws {
        let dir = try makeDir("conform-match")
        let v = videoEntry(id: "vid", in: dir, fps: 30)
        let (res, _) = try makeResolver(entries: [v])

        let clip = Fixtures.clip(id: "c1", mediaRef: "vid", start: 0, duration: 30)
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [clip])])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        #expect(try doc.nodes(forXPath: "//conform-rate").isEmpty)
    }

    // MARK: - Phase 5 (FIX 2): offsets anchor to the parent's source-frame grid

    /// Parse a `"num/dens"` / `"ns"` rational and return (num, den); both must be present.
    private func rationalParts(_ attr: String) throws -> (num: Int, den: Int) {
        #expect(attr.hasSuffix("s"))
        let body = String(attr.dropLast())
        if let slash = body.firstIndex(of: "/") {
            let n = try #require(Int(body[body.startIndex..<slash]))
            let d = try #require(Int(body[body.index(after: slash)...]))
            return (n, d)
        }
        return (try #require(Int(body)), 1)
    }

    /// `a − b` for rationals expressed as `(num, den)`.
    private func ratSub(_ a: (num: Int, den: Int), _ b: (num: Int, den: Int)) -> (num: Int, den: Int) {
        (a.num * b.den - b.num * a.den, a.den * b.den)
    }

    /// A spine direct child's offset lands on the sequence frame grid (`num·fps` divisible by `den`).
    private func expectOnSequenceGrid(_ raw: String, fps: Int) throws {
        let (num, den) = try rationalParts(raw)
        #expect((num * fps) % den == 0, "offset \(raw) is off the \(fps)fps sequence grid")
    }

    /// `delta = childOffset − parentStart` is an integer multiple of the parent's source frame
    /// duration `fd` — i.e. `delta.num·fd.den` is divisible by `delta.den·fd.num`. This is the
    /// "edit frame boundary" FCP requires for connected items: the value sits on the PARENT's
    /// source-frame grid, regardless of how the fraction is reduced.
    private func expectOnSourceGrid(childOffset: String, parentStart: String, fd: (num: Int, den: Int)) throws {
        let off = try rationalParts(childOffset)
        let ps = try rationalParts(parentStart)
        let delta = ratSub(off, ps)
        let n = delta.num * fd.den
        let d = delta.den * fd.num
        #expect(d != 0)
        #expect(n % d == 0, "offset \(childOffset) is off the parent source grid (delta \(delta.num)/\(delta.den) not a multiple of \(fd.num)/\(fd.den))")
    }

    /// The source frame duration of a base spine `<video>`: its asset's referenced format's
    /// `frameDuration`. Falls back to the sequence grid `1/fps` if absent.
    private func parentSourceFD(of videoEl: XMLElement, doc: XMLDocument, fps: Int) throws -> (num: Int, den: Int) {
        guard let ref = videoEl.attribute(forName: "ref")?.stringValue,
              let asset = try doc.nodes(forXPath: "//asset[@id='\(ref)']").first as? XMLElement,
              let fmtId = asset.attribute(forName: "format")?.stringValue,
              let fmt = try doc.nodes(forXPath: "//format[@id='\(fmtId)']").first as? XMLElement,
              let fd = fmt.attribute(forName: "frameDuration")?.stringValue else {
            return (100, fps * 100)
        }
        return try rationalParts(fd)
    }

    /// Walk every spine direct child (base `<video>` / `<gap>`): its own offset is on the sequence
    /// grid, and every nested connected child (video/audio/title) sits on the parent's source grid
    /// (gap parent → sequence grid, start 0s).
    private func expectConnectedOffsetsOnParentSourceGrid(_ doc: XMLDocument, fps: Int) throws {
        let parents = try doc.nodes(forXPath: "//spine/*").compactMap { $0 as? XMLElement }
        #expect(!parents.isEmpty)
        var checkedConnected = false
        for parent in parents {
            if let off = parent.attribute(forName: "offset")?.stringValue {
                try expectOnSequenceGrid(off, fps: fps)
            }
            let parentStart = parent.attribute(forName: "start")?.stringValue ?? "0s"
            let fd: (num: Int, den: Int) = parent.name == "video"
                ? try parentSourceFD(of: parent, doc: doc, fps: fps)
                : (100, fps * 100)
            for child in (parent.children ?? []).compactMap({ $0 as? XMLElement })
            where ["video", "audio", "title"].contains(child.name) && child.attribute(forName: "lane") != nil {
                let childOffset = try #require(child.attribute(forName: "offset")?.stringValue)
                try expectOnSourceGrid(childOffset: childOffset, parentStart: parentStart, fd: fd)
                checkedConnected = true
            }
        }
        #expect(checkedConnected, "expected at least one connected child to check")
    }

    /// FIX 2: across a mixed-fps timeline (24fps sequence + 23.976 source) with a base clip, a PIP
    /// overlay, a title, an audio clip, and head/tail gaps, every connected `offset` lands on its
    /// parent's source-frame grid (and spine children on the sequence grid).
    @Test func connectedOffsetsOnParentSourceGridForMixedFpsTimeline() throws {
        let dir = try makeDir("ongrid")
        let base = videoEntry(id: "base", in: dir, fps: 23.976)
        let pip = videoEntry(id: "pip", in: dir, fps: 23.976)
        let aud = audioEntry(id: "snd", in: dir, fps: 23.976)
        let (res, _) = try makeResolver(entries: [base, pip, aud])

        // Base clip starts at frame 7 (head gap), trimmed, on a 24fps timeline with 23.976 media.
        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 7, duration: 50, trimStart: 13)
        let pipClip = Fixtures.clip(id: "pc", mediaRef: "pip", start: 20, duration: 17)
        let title = textClip(id: "tc", content: "T", start: 11, duration: 19)
        // Audio starts inside the base clip span [7,57) so it nests under the base <video>.
        let aClip = Fixtures.clip(id: "ac", mediaRef: "snd", mediaType: .audio, start: 8, duration: 40)
        var timeline = Fixtures.timeline(fps: 24, tracks: [
            textTrack(clips: [title]),
            Fixtures.videoTrack(clips: [pipClip]),
            Fixtures.videoTrack(clips: [baseClip]),
            Fixtures.audioTrack(clips: [aClip]),
        ])
        timeline.width = 1920; timeline.height = 1080
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        try expectConnectedOffsetsOnParentSourceGrid(doc, fps: 24)
        // Sanity: the connected children actually emitted under the base video.
        #expect(try !doc.nodes(forXPath: "//spine/video/video").isEmpty)
        #expect(try !doc.nodes(forXPath: "//spine/video/title").isEmpty)
        #expect(try !doc.nodes(forXPath: "//spine/video/audio").isEmpty)
        // The base clip's own start is an integer number of source frames (the FIX 1 core property):
        // base start 13013/24000 = 13 · (1001/24000).
        let baseVideo = try #require(doc.nodes(forXPath: "//spine/video").first as? XMLElement)
        #expect(baseVideo.attribute(forName: "start")?.stringValue == "13013/24000s")
    }

    /// FIX 2: gap-anchored connected children (no base clip) sit on the gap's grid (= sequence grid).
    @Test func gapAnchoredConnectedOffsetsOnGrid() throws {
        let dir = try makeDir("ongridgap")
        let ov = videoEntry(id: "ov", in: dir, fps: 23.976)
        let aud = audioEntry(id: "snd", in: dir, fps: 23.976)
        let (res, _) = try makeResolver(entries: [ov, aud])

        let ovClip = Fixtures.clip(id: "oc", mediaRef: "ov", start: 9, duration: 23)
        let aClip = Fixtures.clip(id: "ac", mediaRef: "snd", mediaType: .audio, start: 3, duration: 60)
        var ovTrack = Fixtures.videoTrack(clips: [ovClip]); ovTrack.hidden = true  // forces all-gap spine
        let timeline = Fixtures.timeline(fps: 24, tracks: [
            ovTrack,
            Fixtures.audioTrack(clips: [aClip]),
        ])
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        try expectConnectedOffsetsOnParentSourceGrid(doc, fps: 24)
        #expect(try !doc.nodes(forXPath: "//spine/gap/video").isEmpty)
        #expect(try !doc.nodes(forXPath: "//spine/gap/audio").isEmpty)
    }

    /// FIX 2 (exact value): a 23.976 base at frame 0 (untrimmed → start 0) on a 24fps timeline with a
    /// connected title at frame 10. offset = parentStart(0) + sourceFD·(10−0) = 10·(1001/24000) =
    /// 1001/2400s — an integer count of source frames, off the sequence grid but on the source grid.
    @Test func connectedTitleOffsetEqualsParentSourceFormula() throws {
        let dir = try makeDir("ntsctitle")
        let base = videoEntry(id: "base", in: dir, fps: 23.976)
        let (res, _) = try makeResolver(entries: [base])

        let baseClip = Fixtures.clip(id: "bc", mediaRef: "base", start: 0, duration: 120)
        let title = textClip(id: "tc", content: "T", start: 10, duration: 30)
        var timeline = Fixtures.timeline(fps: 24, tracks: [
            textTrack(clips: [title]),
            Fixtures.videoTrack(clips: [baseClip]),
        ])
        timeline.width = 1920; timeline.height = 1080
        let (_, doc) = try exportXML(timeline: timeline, resolver: res, dir: dir)

        // Base (untrimmed, TC=0) starts at 0s — already an integer (0) source frames.
        let baseVideo = try #require(doc.nodes(forXPath: "//spine/video").first as? XMLElement)
        #expect(baseVideo.attribute(forName: "start")?.stringValue == "0s")
        let titleEl = try #require(doc.nodes(forXPath: "//spine/video/title").first as? XMLElement)
        #expect(titleEl.attribute(forName: "offset")?.stringValue == "1001/2400s")
        // (offset − parentStart) / sourceFD = 10 (integral).
        try expectOnSourceGrid(childOffset: "1001/2400s", parentStart: "0s", fd: (1001, 24000))
    }

    // MARK: - Helpers

    /// Parse a `"num/dens"` / `"ns"` rational-seconds attribute to a Double (seconds).
    private func rationalSeconds(_ attr: String?) throws -> Double {
        let s = try #require(attr)
        #expect(s.hasSuffix("s"))
        let body = String(s.dropLast())
        if let slash = body.firstIndex(of: "/") {
            let num = Double(body[body.startIndex..<slash]) ?? 0
            let den = Double(body[body.index(after: slash)...]) ?? 1
            return num / den
        }
        return Double(body) ?? 0
    }

    /// Convert a `"num/dens"` / `"ns"` rational-seconds attribute to integer frames at `fps`.
    private func framesOf(_ attr: String?, fps: Int) throws -> Int {
        let s = try #require(attr)
        #expect(s.hasSuffix("s"))
        let body = String(s.dropLast())
        let num: Double, den: Double
        if let slash = body.firstIndex(of: "/") {
            num = Double(body[body.startIndex..<slash]) ?? 0
            den = Double(body[body.index(after: slash)...]) ?? 1
        } else {
            num = Double(body) ?? 0; den = 1
        }
        return Int((num / den * Double(fps)).rounded())
    }
}
