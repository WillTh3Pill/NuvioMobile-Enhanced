import ComposeApp
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswresample
import Network

/// Repackages a stream AVPlayer can't open (MKV, …) into fragmented-MP4 HLS served from 127.0.0.1, with no
/// quality loss:
/// - H.264/HEVC video is copied bit-for-bit.
/// - Every audio track becomes an HLS audio rendition. AAC, AC-3, E-AC-3, FLAC and ALAC are copied; anything
///   AVPlayer can't decode (DTS, TrueHD, Opus, PCM, …) is decoded and stored as FLAC, which is lossless, keeping
///   the original channel count and up to 24-bit depth.
/// - Embedded text subtitles and addon subtitle files become WebVTT renditions.
/// Segment boundaries follow the file's keyframe index, so the playlists are exact and any segment can be
/// produced on demand; each byte range of the source is read once for all tracks.
final class HLSRemuxer {
    enum Outcome {
        case remux(URL)
        case playDirectly
    }

    struct SubtitleSource {
        let url: String
        let name: String?
        let language: String?
        let headers: [String: String]
    }

    struct Cue {
        let start: Double
        let end: Double
        let text: String
    }

    private struct AudioTrack {
        let streamIndex: Int32
        let name: String
        let language: String?
        let channels: String
        let codecString: String
        let isDefault: Bool
        let transcoder: FlacTranscoder? // nil: packets are copied unchanged
    }

    private struct SubtitleTrack {
        let streamIndex: Int32
        let codec: AVCodecID
        let name: String
        let language: String
        let isForced: Bool
    }

    private struct ExternalSubtitle {
        let url: String
        let name: String
        let language: String
        let cues: [Cue]
    }

    /// Everything read from one segment's byte range of the source.
    private final class RangeData {
        var video = Data()
        var audio: [Int32: [UnsafeMutablePointer<AVPacket>]] = [:]
        var cues: [Int32: [Cue]] = [:]

        deinit { audio.values.joined().forEach(HLSRemuxer.release) }
    }

    private let url: String
    private let headers: [String: String]
    private let abortFlag = SeekPreviewAbortFlag()
    private let work = DispatchQueue(label: "nuvio.hls-remux.work", qos: .userInitiated)
    private let network = DispatchQueue(label: "nuvio.hls-remux.network", qos: .userInitiated)
    private let errorLock = NSLock()
    private var storedLastError: String?

    // Everything below is touched only on `work`.
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var input: UnsafeMutablePointer<AVFormatContext>?
    private var videoIndex: Int32 = -1
    private var videoStartSeconds = 0.0
    private var audioTracks: [AudioTrack] = []
    private var subtitleTracks: [SubtitleTrack] = []
    private var externalSubtitles: [ExternalSubtitle] = []
    private var boundaries: [Int64] = []
    private var segmentSeconds: [(start: Double, duration: Double)] = []
    private var variantAttributes = "" // everything but CODECS
    private var mediaCodecs: [String]? // video + audio formats; nil when the video codec string can't be read
    private var masterVersion = 0
    private var loggedMasterPlaylist = false
    private var subtitleDelay = 0.0
    private var videoInit: Data?
    private var audioInits: [Int: Data] = [:]
    private var ranges: [Int: RangeData] = [:]
    private var audioSegments: [String: Data] = [:]
    private var nextSequential = -1
    private var carry: [UnsafeMutablePointer<AVPacket>] = []

    private static let minimumSegmentSeconds: Int64 = 4
    private static let timestampOffsetSeconds: Int64 = 10 // keeps the first segment's B-frame dts positive
    private static let noPts = Int64.min
    private static let averrorEOF: Int32 = -541_478_725 // AVERROR_EOF; its FFERRTAG macro isn't visible to Swift
    private static let copyableAudio = [AV_CODEC_ID_AAC, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3, AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC]
    private static let textSubtitles = [AV_CODEC_ID_SUBRIP, AV_CODEC_ID_ASS, AV_CODEC_ID_SSA, AV_CODEC_ID_WEBVTT, AV_CODEC_ID_TEXT, AV_CODEC_ID_MOV_TEXT]
    private static let dispositionDefault: Int32 = 0x1 // AV_DISPOSITION_DEFAULT
    private static let dispositionForced: Int32 = 0x40 // AV_DISPOSITION_FORCED
    private static let dispositionHearingImpaired: Int32 = 0x80 // AV_DISPOSITION_HEARING_IMPAIRED

    init(url: String, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }

    var lastError: String? {
        errorLock.lock()
        defer { errorLock.unlock() }
        return storedLastError
    }

    /// Opens the source and loads `subtitles`; completes on the main queue with the playlist URL, or
    /// `.playDirectly` when the source is already HLS.
    func start(subtitles: [SubtitleSource], completion: @escaping (Result<Outcome, Error>) -> Void) {
        let finish: (Result<Outcome, Error>) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }
        work.async {
            do {
                guard try self.openSource() else { return finish(.success(.playDirectly)) }
                subtitles.forEach { _ = self.loadExternalSubtitle($0) }
                self.startListener { result in
                    self.work.async {
                        if case .success(let port) = result { self.port = port }
                        finish(result.map { _ in Outcome.remux(self.masterURL) })
                    }
                }
            } catch {
                if !self.abortFlag.isSet { self.record(error) } // a superseded load isn't an error worth logging
                finish(.failure(error))
            }
        }
    }

    /// Adds an addon subtitle file; completes on the main queue with the new playlist URL (the item has to be
    /// reloaded to see it) and the subtitle's name, or nil if it couldn't be loaded.
    func addSubtitle(_ source: SubtitleSource, completion: @escaping ((url: URL, name: String)?) -> Void) {
        work.async {
            let name = self.loadExternalSubtitle(source)
            if name != nil { self.masterVersion += 1 }
            let result = name.map { (url: self.masterURL, name: $0) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Shifts every subtitle by `seconds`; completes on the main queue with the new playlist URL.
    func setSubtitleDelay(_ seconds: Double, completion: @escaping (URL) -> Void) {
        work.async {
            self.subtitleDelay = seconds
            self.masterVersion += 1
            let url = self.masterURL
            DispatchQueue.main.async { completion(url) }
        }
    }

    func stop() {
        abortFlag.set()
        work.async { [self] in
            listener?.newConnectionHandler = nil
            listener?.stateUpdateHandler = nil
            listener?.cancel()
            listener = nil
            dropCarry()
            ranges.removeAll()
            audioSegments.removeAll()
            audioTracks.removeAll() // releases the FLAC transcoders
            if input != nil { avformat_close_input(&input) }
        }
    }

    private var masterURL: URL {
        // A new name per version so AVPlayer can't serve a cached copy after subtitles change.
        URL(string: "http://127.0.0.1:\(port)/master\(masterVersion).m3u8")!
    }

    // MARK: Source

    private func openSource() throws -> Bool {
        guard let context = avformat_alloc_context() else { throw RemuxError("out of memory") }
        context.pointee.interrupt_callback.callback = { opaque in
            guard let opaque else { return 0 }
            return Unmanaged<SeekPreviewAbortFlag>.fromOpaque(opaque).takeUnretainedValue().isSet ? 1 : 0
        }
        context.pointee.interrupt_callback.opaque = Unmanaged.passUnretained(abortFlag).toOpaque()

        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        _ = av_dict_set(&options, "rw_timeout", "15000000", 0)
        _ = av_dict_set(&options, "reconnect", "1", 0)
        _ = av_dict_set(&options, "reconnect_on_network_error", "1", 0)
        _ = av_dict_set(&options, "reconnect_delay_max", "4", 0)
        var headerLines = ""
        for (name, value) in headers where name.caseInsensitiveCompare("Range") != .orderedSame {
            if name.caseInsensitiveCompare("User-Agent") == .orderedSame {
                _ = av_dict_set(&options, "user_agent", value, 0)
            } else {
                headerLines += "\(name): \(value)\r\n"
            }
        }
        if !headerLines.isEmpty { _ = av_dict_set(&options, "headers", headerLines, 0) }

        var contextPointer: UnsafeMutablePointer<AVFormatContext>? = context
        let openResult = avformat_open_input(&contextPointer, url, nil, &options)
        guard openResult >= 0, let opened = contextPointer else {
            throw RemuxError("couldn't open the stream: \(FFmpegSeekPreviewGenerator.describe(openResult))")
        }
        input = opened

        let formatName = String(cString: opened.pointee.iformat.pointee.name)
        if formatName.contains("hls") { return false }

        let infoResult = avformat_find_stream_info(opened, nil)
        guard infoResult >= 0 else {
            throw RemuxError("couldn't read the stream: \(FFmpegSeekPreviewGenerator.describe(infoResult))")
        }

        videoIndex = av_find_best_stream(opened, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard videoIndex >= 0, let video = opened.pointee.streams[Int(videoIndex)],
              let videoParameters = video.pointee.codecpar else { throw RemuxError.unplayable("the stream has no video") }
        let videoCodec = videoParameters.pointee.codec_id
        guard videoCodec == AV_CODEC_ID_H264 || videoCodec == AV_CODEC_ID_HEVC else {
            throw RemuxError.unplayable("AVPlayer can't play \(Self.codecName(videoCodec)) video")
        }
        if video.pointee.start_time != Self.noPts {
            videoStartSeconds = Double(video.pointee.start_time) * Self.seconds(video.pointee.time_base)
        }

        try loadTracks(opened)
        try buildSegments(opened, video: video)
        variantAttributes = Self.variantAttributes(opened, video: video)
        mediaCodecs = Self.videoCodecString(video.pointee.codecpar!).map { videoCodec in
            audioTracks.reduce(into: [videoCodec]) { codecs, track in
                if !codecs.contains(track.codecString) { codecs.append(track.codecString) }
            }
        }

        InAppLogBridge.shared.info(
            tag: "Player/Remux",
            message: "repackaging \(formatName) video=\(Self.codecName(videoCodec)) " +
                "audio=[\(audioTracks.map { "\($0.name)\($0.transcoder == nil ? "" : " →FLAC")" }.joined(separator: "; "))] " +
                "subtitles=\(subtitleTracks.count) segments=\(segmentSeconds.count)"
        )
        return true
    }

    private func loadTracks(_ opened: UnsafeMutablePointer<AVFormatContext>) throws {
        let preferredAudio = av_find_best_stream(opened, AVMEDIA_TYPE_AUDIO, -1, videoIndex, nil, 0)
        var audioNames = Set<String>()
        var subtitleNames = Set<String>()
        var undecodableAudio: [String] = []
        for index in 0..<Int32(opened.pointee.nb_streams) {
            guard let stream = opened.pointee.streams[Int(index)], let parameters = stream.pointee.codecpar else { continue }
            let codec = parameters.pointee.codec_id
            let language = Self.languageTag(Self.metadata(stream, "language"))
            let title = Self.metadata(stream, "title")
            let disposition = stream.pointee.disposition

            if parameters.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                let copy = Self.copyableAudio.contains(codec)
                var transcoder: FlacTranscoder?
                if !copy {
                    do {
                        transcoder = try FlacTranscoder(stream: stream)
                    } catch {
                        undecodableAudio.append(Self.codecName(codec))
                        InAppLogBridge.shared.warn(tag: "Player/Remux", message: "skipping audio track \(index): \(error.localizedDescription)")
                        continue
                    }
                }
                let channelCount = parameters.pointee.ch_layout.nb_channels
                let base = title ?? language.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? "Audio \(audioTracks.count + 1)"
                let detail = "\(Self.codecLabel(parameters)) \(Self.channelLabel(channelCount))"
                audioTracks.append(AudioTrack(
                    streamIndex: index,
                    name: Self.unique("\(base) (\(detail))", in: &audioNames),
                    language: language,
                    // Plain channel count: playlists declaring Atmos ("16/JOC", "ec+3") were rejected outright on
                    // iPadOS 16 (suspected cause). Atmos is still signalled by the bitstream itself.
                    channels: "\(channelCount)",
                    codecString: copy ? Self.audioCodecString(parameters) : "fLaC",
                    isDefault: false,
                    transcoder: transcoder
                ))
            } else if parameters.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE, Self.textSubtitles.contains(codec) {
                var name = title ?? language.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? "Subtitles \(subtitleTracks.count + 1)"
                if disposition & Self.dispositionForced != 0 { name += " (Forced)" }
                if disposition & Self.dispositionHearingImpaired != 0 { name += " (SDH)" }
                subtitleTracks.append(SubtitleTrack(
                    streamIndex: index,
                    codec: codec,
                    name: Self.unique(name, in: &subtitleNames),
                    language: language ?? "und",
                    isForced: disposition & Self.dispositionForced != 0
                ))
            }
        }
        if audioTracks.isEmpty && !undecodableAudio.isEmpty {
            throw RemuxError.unplayable("the audio (\(undecodableAudio.joined(separator: ", "))) can't be decoded")
        }

        // Mark one default audio track: FFmpeg's pick, else the file's default, else the first.
        let defaultIndex = audioTracks.firstIndex(where: { $0.streamIndex == preferredAudio })
            ?? audioTracks.firstIndex(where: { opened.pointee.streams[Int($0.streamIndex)]!.pointee.disposition & Self.dispositionDefault != 0 })
            ?? (audioTracks.isEmpty ? nil : 0)
        if let defaultIndex {
            let track = audioTracks[defaultIndex]
            audioTracks[defaultIndex] = AudioTrack(
                streamIndex: track.streamIndex, name: track.name, language: track.language, channels: track.channels,
                codecString: track.codecString, isDefault: true, transcoder: track.transcoder
            )
        }

        let kept = Set([videoIndex] + audioTracks.map(\.streamIndex) + subtitleTracks.map(\.streamIndex))
        for index in 0..<Int32(opened.pointee.nb_streams) where !kept.contains(index) {
            opened.pointee.streams[Int(index)]?.pointee.discard = AVDISCARD_ALL
        }
    }

    private func buildSegments(_ opened: UnsafeMutablePointer<AVFormatContext>, video: UnsafeMutablePointer<AVStream>) throws {
        // Matroska only reads its Cues (the keyframe index) on the first seek.
        _ = av_seek_frame(opened, videoIndex, 0, AVSEEK_FLAG_BACKWARD)
        var keyframes = Set<Int64>()
        for index in 0..<avformat_index_get_entries_count(video) {
            if let entry = avformat_index_get_entry(video, index), entry.pointee.flags & AVINDEX_KEYFRAME != 0 {
                keyframes.insert(entry.pointee.timestamp)
            }
        }
        let sortedKeyframes = keyframes.sorted()
        guard sortedKeyframes.count >= 2 else {
            throw RemuxError.unplayable("the file has no keyframe index to build a seekable playlist from")
        }

        let timeBase = video.pointee.time_base
        var end = Self.noPts
        if opened.pointee.duration > 0 {
            let start = opened.pointee.start_time == Self.noPts ? 0 : opened.pointee.start_time
            end = av_rescale_q(start + opened.pointee.duration, AVRational(num: 1, den: AV_TIME_BASE), timeBase)
        } else if video.pointee.duration > 0 {
            end = (video.pointee.start_time == Self.noPts ? 0 : video.pointee.start_time) + video.pointee.duration
        }
        guard end != Self.noPts, end > sortedKeyframes[0] else { throw RemuxError.unplayable("the stream has no known length") }

        let minimum = av_rescale_q(Self.minimumSegmentSeconds, AVRational(num: 1, den: 1), timeBase)
        var bounds = [sortedKeyframes[0]]
        for keyframe in sortedKeyframes.dropFirst() where keyframe < end && keyframe - bounds[bounds.count - 1] >= minimum {
            bounds.append(keyframe)
        }
        bounds.append(end)
        boundaries = bounds
        let tick = Self.seconds(timeBase)
        segmentSeconds = zip(bounds, bounds.dropFirst()).map { (start: Double($0) * tick, duration: Double($1 - $0) * tick) }
    }

    // MARK: Playlists

    private func masterPlaylist() -> Data {
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        for (index, track) in audioTracks.enumerated() {
            text += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"\(Self.quoted(track.name))\""
            if let language = track.language { text += ",LANGUAGE=\"\(language)\"" }
            text += ",DEFAULT=\(track.isDefault ? "YES" : "NO"),AUTOSELECT=YES,CHANNELS=\"\(track.channels)\",URI=\"audio\(index).m3u8\"\n"
        }
        for (index, track) in subtitleTracks.enumerated() {
            text += "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(Self.quoted(track.name))\",LANGUAGE=\"\(track.language)\"" +
                ",DEFAULT=NO,AUTOSELECT=YES,FORCED=\(track.isForced ? "YES" : "NO"),URI=\"sub\(index).m3u8\"\n"
        }
        for (index, subtitle) in externalSubtitles.enumerated() {
            text += "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(Self.quoted(subtitle.name))\",LANGUAGE=\"\(subtitle.language)\"" +
                ",DEFAULT=NO,AUTOSELECT=YES,FORCED=NO,URI=\"xsub\(index).m3u8\"\n"
        }
        let hasSubtitles = !subtitleTracks.isEmpty || !externalSubtitles.isEmpty
        text += "#EXT-X-STREAM-INF:\(variantAttributes),CLOSED-CAPTIONS=NONE"
        // Video and audio formats; left out entirely rather than guessed. WebVTT's "wvtt" is optional and left out.
        if let mediaCodecs { text += ",CODECS=\"\(mediaCodecs.joined(separator: ","))\"" }
        if !audioTracks.isEmpty { text += ",AUDIO=\"audio\"" }
        if hasSubtitles { text += ",SUBTITLES=\"subs\"" }
        text += "\nvideo.m3u8\n"
        if !loggedMasterPlaylist {
            loggedMasterPlaylist = true
            InAppLogBridge.shared.info(tag: "Player/Remux", message: "playlist:\n\(text.prefix(4000))")
        }
        return Data(text.utf8)
    }

    private func mediaPlaylist(map: String?, segment: (Int) -> String) -> Data {
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        text += "#EXT-X-TARGETDURATION:\(Int((segmentSeconds.map { $0.duration }.max() ?? 1).rounded(.up)))\n"
        if let map { text += "#EXT-X-MAP:URI=\"\(map)\"\n" }
        for (index, entry) in segmentSeconds.enumerated() {
            text += "#EXTINF:\(String(format: "%.6f", entry.duration)),\n\(segment(index))\n"
        }
        text += "#EXT-X-ENDLIST\n"
        return Data(text.utf8)
    }

    // MARK: Segments

    private func range(_ index: Int) throws -> RangeData {
        if let cached = ranges[index] { return cached }
        let data = try readRange(index)
        ranges[index] = data
        // ponytail: keeps three ranges (4K remux segments are large); raise if seeking back re-reads too often.
        if ranges.count > 3 { ranges = ranges.filter { abs($0.key - index) <= 1 } }
        return data
    }

    private func videoInitData() throws -> Data {
        if videoInit == nil { _ = try range(0) }
        guard let videoInit else { throw RemuxError("no video init segment") }
        return videoInit
    }

    private func audioInitData(_ track: Int) throws -> Data {
        if audioInits[track] == nil { _ = try audioSegment(track, 0) }
        guard let data = audioInits[track] else { throw RemuxError("no audio init segment for track \(track)") }
        return data
    }

    private func audioSegment(_ trackIndex: Int, _ index: Int) throws -> Data {
        let key = "\(trackIndex)_\(index)"
        if let cached = audioSegments[key] { return cached }
        guard audioTracks.indices.contains(trackIndex), let input,
              let stream = input.pointee.streams[Int(audioTracks[trackIndex].streamIndex)] else {
            throw RemuxError("audio track \(trackIndex) doesn't exist")
        }
        let track = audioTracks[trackIndex]
        let raw = try range(index).audio[track.streamIndex] ?? []
        let sampleRate = stream.pointee.codecpar.pointee.sample_rate
        let sampleTimeBase = AVRational(num: 1, den: sampleRate)

        var packets: [UnsafeMutablePointer<AVPacket>] = []
        defer { packets.forEach(Self.release) }
        let parameters: UnsafePointer<AVCodecParameters>
        if let transcoder = track.transcoder {
            packets = try transcoder.encode(raw, segment: index, isLast: index + 1 == segmentSeconds.count)
            guard let encoded = transcoder.parameters else { throw RemuxError("audio track \(trackIndex) produced no audio") }
            parameters = UnsafePointer(encoded)
        } else {
            // Lay frames on the exact sample grid (Matroska rounds times to milliseconds) so independently
            // produced segments join without gaps.
            let frame = Int64(stream.pointee.codecpar.pointee.frame_size)
            let streamStart = stream.pointee.start_time == Self.noPts
                ? 0
                : av_rescale_q(stream.pointee.start_time, stream.pointee.time_base, sampleTimeBase)
            var first = raw.first.map { av_rescale_q($0.pointee.pts, stream.pointee.time_base, sampleTimeBase) } ?? 0
            if frame > 0 { first = streamStart + (first - streamStart + frame / 2) / frame * frame }
            for (position, source) in raw.enumerated() {
                guard let packet = av_packet_clone(source) else { throw RemuxError("out of memory") }
                if frame > 0 {
                    packet.pointee.pts = first + Int64(position) * frame
                    packet.pointee.duration = frame
                } else {
                    packet.pointee.pts = av_rescale_q(source.pointee.pts, stream.pointee.time_base, sampleTimeBase)
                    packet.pointee.duration = av_rescale_q(source.pointee.duration, stream.pointee.time_base, sampleTimeBase)
                }
                packet.pointee.dts = packet.pointee.pts
                packets.append(packet)
            }
            parameters = UnsafePointer(stream.pointee.codecpar!)
        }
        guard !packets.isEmpty else { throw RemuxError("audio track \(trackIndex) has no audio in segment \(index)") }

        let (initData, media) = try mux(parameters, codecTag: 0, timeBase: sampleTimeBase, packets: packets)
        if audioInits[trackIndex] == nil { audioInits[trackIndex] = initData }
        audioSegments[key] = media
        // ponytail: small cache for AVPlayer's repeat requests; audio segments are small.
        if audioSegments.count > 8 { audioSegments.removeAll(); audioSegments[key] = media }
        return media
    }

    private func subtitleSegment(_ trackIndex: Int, _ index: Int) throws -> Data {
        guard subtitleTracks.indices.contains(trackIndex) else { throw RemuxError("subtitle track \(trackIndex) doesn't exist") }
        let cues = try range(index).cues[subtitleTracks[trackIndex].streamIndex] ?? []
        return webVTT(cues)
    }

    private func externalSubtitleSegment(_ subtitleIndex: Int, _ index: Int) throws -> Data {
        guard externalSubtitles.indices.contains(subtitleIndex), segmentSeconds.indices.contains(index) else {
            throw RemuxError("subtitle segment doesn't exist")
        }
        let start = segmentSeconds[index].start
        let end = index + 1 < segmentSeconds.count ? segmentSeconds[index + 1].start : .infinity
        return webVTT(externalSubtitles[subtitleIndex].cues.filter { $0.start >= start && $0.start < end })
    }

    private func webVTT(_ cues: [Cue]) -> Data {
        // Cue times are on the source timeline; media timestamps carry the same offset as the video.
        var text = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:\(Self.timestampOffsetSeconds * 90_000),LOCAL:00:00:00.000\n"
        for cue in cues {
            let start = max(0, cue.start + subtitleDelay)
            let end = max(start + 0.001, cue.end + subtitleDelay)
            text += "\n\(Self.vttTime(start)) --> \(Self.vttTime(end))\n\(cue.text)\n"
        }
        return Data(text.utf8)
    }

    /// Reads one segment's byte range once: muxes its video and keeps its audio packets and subtitle cues.
    private func readRange(_ index: Int) throws -> RangeData {
        guard let input, index >= 0, index + 1 < boundaries.count,
              let video = input.pointee.streams[Int(videoIndex)] else {
            throw RemuxError("segment \(index) doesn't exist")
        }
        let start = boundaries[index]
        let end = boundaries[index + 1]
        let isLast = index + 2 == boundaries.count
        let videoTimeBase = video.pointee.time_base
        // Safety stop if the index promised a keyframe that never arrives, or an audio track ends early.
        let horizon = end + av_rescale_q(10, AVRational(num: 1, den: 1), videoTimeBase)
        let audioStreams = Set(audioTracks.map(\.streamIndex))
        let subtitleCodecs = Dictionary(uniqueKeysWithValues: subtitleTracks.map { ($0.streamIndex, $0.codec) })

        if index != nextSequential {
            dropCarry()
            let seekResult = av_seek_frame(input, videoIndex, start, AVSEEK_FLAG_BACKWARD)
            guard seekResult >= 0 else {
                throw RemuxError("seek to segment \(index) failed: \(FFmpegSeekPreviewGenerator.describe(seekResult))")
            }
        }
        nextSequential = -1

        let result = RangeData()
        var videoPackets: [UnsafeMutablePointer<AVPacket>] = []
        var pending = carry
        carry = []
        defer { (videoPackets + pending).forEach(Self.release) }
        var videoStarted = false
        var videoDone = false
        var audioWaiting = isLast ? Set<Int32>() : audioStreams

        while !(videoDone && audioWaiting.isEmpty) {
            let packet: UnsafeMutablePointer<AVPacket>
            if pending.isEmpty {
                guard let fresh = av_packet_alloc() else { throw RemuxError("out of memory") }
                let readResult = av_read_frame(input, fresh)
                if readResult < 0 {
                    Self.release(fresh)
                    if readResult == Self.averrorEOF { break }
                    throw RemuxError("reading segment \(index) failed: \(FFmpegSeekPreviewGenerator.describe(readResult))")
                }
                packet = fresh
            } else {
                packet = pending.removeFirst()
            }

            let streamIndex = packet.pointee.stream_index
            let ts = packet.pointee.pts != Self.noPts ? packet.pointee.pts : packet.pointee.dts
            guard ts != Self.noPts, let stream = input.pointee.streams[Int(streamIndex)] else {
                Self.release(packet)
                continue
            }
            let time = av_rescale_q(ts, stream.pointee.time_base, videoTimeBase)

            if streamIndex == videoIndex {
                if !isLast && ts > horizon {
                    carry.append(packet)
                    break
                }
                let isKeyframe = packet.pointee.flags & AV_PKT_FLAG_KEY != 0
                if videoDone {
                    carry.append(packet)
                } else if !videoStarted {
                    if isKeyframe && ts >= start {
                        videoStarted = true
                        videoPackets.append(packet)
                    } else {
                        Self.release(packet)
                    }
                } else if isKeyframe && ts >= end && !isLast {
                    videoDone = true
                    carry.append(packet)
                } else {
                    videoPackets.append(packet)
                }
            } else if audioStreams.contains(streamIndex) {
                if time >= end && !isLast {
                    audioWaiting.remove(streamIndex)
                    carry.append(packet)
                } else if time < start {
                    Self.release(packet)
                } else {
                    result.audio[streamIndex, default: []].append(packet)
                }
            } else if let codec = subtitleCodecs[streamIndex] {
                if time >= end && !isLast {
                    carry.append(packet)
                } else {
                    if time >= start, let data = packet.pointee.data, packet.pointee.size > 0,
                       let text = Self.cueText(String(decoding: UnsafeBufferPointer(start: data, count: Int(packet.pointee.size)), as: UTF8.self), codec: codec) {
                        let tick = Self.seconds(stream.pointee.time_base)
                        let cueStart = Double(ts) * tick
                        let length = packet.pointee.duration > 0 ? Double(packet.pointee.duration) * tick : 3
                        result.cues[streamIndex, default: []].append(Cue(start: cueStart, end: cueStart + length, text: text))
                    }
                    Self.release(packet)
                }
            } else {
                Self.release(packet)
            }
        }
        carry.append(contentsOf: pending)
        pending.removeAll()
        guard !videoPackets.isEmpty else { throw RemuxError("segment \(index) has no video") }

        // Matroska only stores presentation times, so derive decode times from them.
        let pts = videoPackets.map { $0.pointee.pts }
        let sorted = pts.sorted()
        let steps = zip(sorted, sorted.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
        let frameDuration = steps.isEmpty ? Self.nominalFrameDuration(video) : steps[steps.count / 2]
        let reorderDelay = max(
            zip(sorted, pts).map { $0 - $1 }.max() ?? 0,
            Int64(video.pointee.codecpar.pointee.video_delay) * frameDuration,
            0
        )
        for (position, packet) in videoPackets.enumerated() {
            packet.pointee.dts = sorted[position] - reorderDelay
            packet.pointee.duration = position + 1 < sorted.count ? sorted[position + 1] - sorted[position] : frameDuration
        }
        // AVPlayer only accepts HEVC tagged hvc1 (or dvh1 for single-layer Dolby Vision profile 5).
        let tag: UInt32 = video.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_HEVC
            ? Self.fourCC(Self.dolbyVisionProfile(video.pointee.codecpar) == 5 ? "dvh1" : "hvc1")
            : 0
        let (initData, media) = try mux(UnsafePointer(video.pointee.codecpar!), codecTag: tag, timeBase: videoTimeBase, packets: videoPackets)
        if videoInit == nil { videoInit = initData }
        result.video = media
        nextSequential = index + 1
        return result
    }

    // MARK: fMP4

    /// Writes one track's packets (timestamps in `timeBase`) as an fMP4 fragment; returns ftyp+moov and moof+mdat.
    private func mux(
        _ parameters: UnsafePointer<AVCodecParameters>,
        codecTag: UInt32,
        timeBase: AVRational,
        packets: [UnsafeMutablePointer<AVPacket>]
    ) throws -> (initData: Data, media: Data) {
        var outputPointer: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&outputPointer, nil, "mp4", nil) >= 0,
              let output = outputPointer else { throw RemuxError("mp4 muxer unavailable") }
        defer { avformat_free_context(output) }
        var dynamicBuffer: UnsafeMutablePointer<AVIOContext>?
        guard avio_open_dyn_buf(&dynamicBuffer) >= 0 else { throw RemuxError("out of memory") }
        output.pointee.pb = dynamicBuffer
        defer {
            if output.pointee.pb != nil {
                var discarded: UnsafeMutablePointer<UInt8>?
                _ = avio_close_dyn_buf(output.pointee.pb, &discarded)
                av_free(discarded)
                output.pointee.pb = nil
            }
        }

        guard let stream = avformat_new_stream(output, nil),
              avcodec_parameters_copy(stream.pointee.codecpar, parameters) >= 0 else {
            throw RemuxError("couldn't set up the mp4 track")
        }
        stream.pointee.codecpar.pointee.codec_tag = codecTag
        stream.pointee.time_base = timeBase

        // Keep the source's absolute timestamps in every fragment (tfdt), so AVPlayer can join segments
        // produced independently: no edit list, no shifting, discontinuous fragments.
        output.pointee.avoid_negative_ts = 0 // AVFMT_AVOID_NEG_TS_DISABLED
        output.pointee.strict_std_compliance = -1 // FF_COMPLIANCE_UNOFFICIAL: write Dolby Vision config boxes
        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        _ = av_dict_set(&options, "movflags", "+frag_custom+delay_moov+default_base_moof+frag_discont", 0)
        _ = av_dict_set(&options, "use_editlist", "0", 0)
        _ = av_dict_set(&options, "video_track_timescale", "90000", 0)
        let headerResult = avformat_write_header(output, &options)
        guard headerResult >= 0 else {
            throw RemuxError("mp4 header failed: \(FFmpegSeekPreviewGenerator.describe(headerResult))")
        }

        let outTimeBase = stream.pointee.time_base
        let offset = av_rescale_q(Self.timestampOffsetSeconds, AVRational(num: 1, den: 1), outTimeBase)
        for packet in packets {
            av_packet_rescale_ts(packet, timeBase, outTimeBase)
            packet.pointee.pts += offset
            packet.pointee.dts += offset
            packet.pointee.stream_index = stream.pointee.index
            let result = av_write_frame(output, packet)
            guard result >= 0 else { throw RemuxError("writing a packet failed: \(FFmpegSeekPreviewGenerator.describe(result))") }
        }

        // delay_moov: the first flush writes ftyp+moov (AC-3/E-AC-3 configs need packets first),
        // the second writes the fragment.
        for _ in 0..<2 {
            let result = av_write_frame(output, nil)
            guard result >= 0 else { throw RemuxError("flushing failed: \(FFmpegSeekPreviewGenerator.describe(result))") }
        }

        var bufferPointer: UnsafeMutablePointer<UInt8>?
        let size = avio_close_dyn_buf(output.pointee.pb, &bufferPointer)
        output.pointee.pb = nil
        defer { av_free(bufferPointer) }
        guard let buffer = bufferPointer, size > 0 else { throw RemuxError("the muxer produced no data") }
        let bytes = Data(bytes: buffer, count: Int(size))
        guard let fragmentStart = Self.firstBox("moof", in: bytes) else { throw RemuxError("the muxer produced no fragment") }
        return (Data(bytes[..<fragmentStart]), Data(bytes[fragmentStart...]))
    }

    // MARK: Addon subtitles

    /// Downloads and parses a subtitle file; returns its rendition name, or nil if it couldn't be used.
    private func loadExternalSubtitle(_ source: SubtitleSource) -> String? {
        if let existing = externalSubtitles.first(where: { $0.url == source.url }) { return existing.name }
        do {
            let cues = try Self.parseSubtitleFile(Self.download(source.url, headers: source.headers))
                .map { Cue(start: $0.start + videoStartSeconds, end: $0.end + videoStartSeconds, text: $0.text) }
            guard !cues.isEmpty else { throw RemuxError("no subtitles found in the file") }
            let language = Self.languageTag(source.language) ?? "und"
            let base = source.name ?? Locale.current.localizedString(forLanguageCode: language) ?? "Subtitles"
            var names = Set(subtitleTracks.map(\.name) + externalSubtitles.map(\.name))
            let name = Self.unique("\(base) (addon)", in: &names)
            externalSubtitles.append(ExternalSubtitle(url: source.url, name: name, language: language, cues: cues))
            return name
        } catch {
            InAppLogBridge.shared.warn(tag: "Player/Remux", message: "addon subtitle failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func download(_ url: String, headers: [String: String]) throws -> Data {
        guard let address = URL(string: url) else { throw RemuxError("invalid subtitle URL") }
        var request = URLRequest(url: address, timeoutInterval: 20)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        final class Box { var result: Result<Data, Error> = .failure(RemuxError("subtitle download timed out")) }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data, (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true {
                box.result = .success(data)
            } else {
                box.result = .failure(error ?? RemuxError("subtitle download failed"))
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 25)
        return try box.result.get()
    }

    /// SubRip, WebVTT or ASS/SSA, in UTF-8 or Windows-1252.
    static func parseSubtitleFile(_ data: Data) -> [Cue] {
        let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        let text = decoded.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        if text.contains("[Events]") {
            return text.components(separatedBy: "\n").compactMap { line -> Cue? in
                guard line.hasPrefix("Dialogue:") else { return nil }
                // Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
                let fields = line.dropFirst("Dialogue:".count).split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
                guard fields.count == 10, let start = parseTime(String(fields[1])), let end = parseTime(String(fields[2])),
                      let body = cueText("0,0,,,0,0,0,,\(fields[9])", codec: AV_CODEC_ID_ASS) else { return nil }
                return Cue(start: start, end: end, text: body)
            }
        }

        return text.components(separatedBy: "\n\n").compactMap { block -> Cue? in
            let lines = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let parts = lines[timing].components(separatedBy: "-->")
            let endField = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "" : ""
            guard let start = parseTime(parts[0]), let end = parseTime(endField),
                  let body = cueText(lines[(timing + 1)...].joined(separator: "\n"), codec: AV_CODEC_ID_SUBRIP) else { return nil }
            return Cue(start: start, end: end, text: body)
        }
    }

    /// "hh:mm:ss,mmm", "hh:mm:ss.mmm", "mm:ss.mmm" or ASS "h:mm:ss.cc".
    private static func parseTime(_ field: String) -> Double? {
        let parts = field.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    /// Converts one subtitle event to WebVTT cue text (keeps <i>, <b>, <u>); nil if nothing displayable is left.
    static func cueText(_ raw: String, codec: AVCodecID) -> String? {
        var text = raw
        if codec == AV_CODEC_ID_ASS || codec == AV_CODEC_ID_SSA {
            // FFmpeg's ASS events: ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
            let fields = text.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9 else { return nil }
            text = String(fields[8])
            if text.range(of: #"\\p[1-9]"#, options: .regularExpression) != nil { return nil } // vector drawing, not text
            text = text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
        }
        text = text.replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression) // ASS tags inside SRT
            .replacingOccurrences(of: #"<(?!/?[ibu]>)[^>]*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: #"<(?!/?[ibu]>)"#, with: "&lt;", options: .regularExpression)
            .replacingOccurrences(of: "-->", with: "->")
            .replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func vttTime(_ seconds: Double) -> String {
        let milliseconds = Int((seconds * 1000).rounded())
        return String(format: "%02ld:%02ld:%02ld.%03ld",milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }

    // MARK: HTTP (127.0.0.1 only)

    private func startListener(ready: @escaping (Result<UInt16, Error>) -> Void) {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            let listener = try NWListener(using: parameters, on: .any)
            // Report once: the handler removes itself.
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    guard let port = listener?.port?.rawValue else { return }
                    listener?.stateUpdateHandler = nil
                    ready(.success(port))
                case .failed(let error):
                    listener?.stateUpdateHandler = nil
                    ready(.failure(error))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            self.listener = listener
            listener.start(queue: network)
        } catch {
            ready(.failure(error))
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: network)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self), on: connection)
            } else if isComplete || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(_ request: String, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        let isHead = parts.first == "HEAD"
        let name = parts.count > 1 ? String(parts[1].split(separator: "?").first?.split(separator: "/").last ?? "") : ""
        let range = lines.first { $0.lowercased().hasPrefix("range:") }
        work.async { [weak self] in
            guard let self else { return connection.cancel() }
            let response = self.response(for: name)
            self.network.async { self.send(response, range: range, headOnly: isHead, on: connection) }
        }
    }

    private func response(for name: String) -> (status: String, type: String, body: Data) {
        let playlist = "application/vnd.apple.mpegurl"
        do {
            if name.hasPrefix("master"), name.hasSuffix(".m3u8") { return ("200 OK", playlist, masterPlaylist()) }
            if name == "video.m3u8" { return ("200 OK", playlist, mediaPlaylist(map: "vinit.mp4") { "v\($0).m4s" }) }
            if name == "vinit.mp4" { return ("200 OK", "video/mp4", try videoInitData()) }
            if let numbers = Self.numbers(name, prefix: "audio", suffix: ".m3u8"), numbers.count == 1 {
                let track = numbers[0]
                return ("200 OK", playlist, mediaPlaylist(map: "ainit\(track).mp4") { "a\(track)_\($0).m4s" })
            }
            if let numbers = Self.numbers(name, prefix: "ainit", suffix: ".mp4"), numbers.count == 1 {
                return ("200 OK", "audio/mp4", try audioInitData(numbers[0]))
            }
            if let numbers = Self.numbers(name, prefix: "xsub", suffix: ".m3u8"), numbers.count == 1 {
                return ("200 OK", playlist, mediaPlaylist(map: nil) { "x\(numbers[0])_\($0).vtt" })
            }
            if let numbers = Self.numbers(name, prefix: "sub", suffix: ".m3u8"), numbers.count == 1 {
                return ("200 OK", playlist, mediaPlaylist(map: nil) { "s\(numbers[0])_\($0).vtt" })
            }
            if let numbers = Self.numbers(name, prefix: "v", suffix: ".m4s"), numbers.count == 1 {
                return ("200 OK", "video/mp4", try range(numbers[0]).video)
            }
            if let numbers = Self.numbers(name, prefix: "a", suffix: ".m4s"), numbers.count == 2 {
                return ("200 OK", "audio/mp4", try audioSegment(numbers[0], numbers[1]))
            }
            if let numbers = Self.numbers(name, prefix: "s", suffix: ".vtt"), numbers.count == 2 {
                return ("200 OK", "text/vtt", try subtitleSegment(numbers[0], numbers[1]))
            }
            if let numbers = Self.numbers(name, prefix: "x", suffix: ".vtt"), numbers.count == 2 {
                return ("200 OK", "text/vtt", try externalSubtitleSegment(numbers[0], numbers[1]))
            }
            return ("404 Not Found", "text/plain", Data())
        } catch {
            record(error)
            return ("500 Internal Server Error", "text/plain", Data(error.localizedDescription.utf8))
        }
    }

    /// "a2_17.m4s" with prefix "a" and suffix ".m4s" gives [2, 17]; nil if the name doesn't match.
    private static func numbers(_ name: String, prefix: String, suffix: String) -> [Int]? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let middle = name.dropFirst(prefix.count).dropLast(suffix.count)
        let values = middle.split(separator: "_", omittingEmptySubsequences: false).map { Int($0) }
        guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { return nil }
        return values.compactMap { $0 }
    }

    private func send(
        _ response: (status: String, type: String, body: Data),
        range: String?,
        headOnly: Bool,
        on connection: NWConnection
    ) {
        var status = response.status
        var body = response.body
        var contentRange = ""
        if status.hasPrefix("200"), let range, let bytes = Self.byteRange(range, length: body.count) {
            contentRange = "Content-Range: bytes \(bytes.lowerBound)-\(bytes.upperBound - 1)/\(body.count)\r\n"
            body = body.subdata(in: bytes)
            status = "206 Partial Content"
        }
        var payload = Data((
            "HTTP/1.1 \(status)\r\nContent-Type: \(response.type)\r\nContent-Length: \(body.count)\r\n" +
                "Accept-Ranges: bytes\r\n\(contentRange)Connection: close\r\n\r\n"
        ).utf8)
        if !headOnly { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// "Range: bytes=start-end" or "bytes=start-"; anything else is served whole.
    private static func byteRange(_ header: String, length: Int) -> Range<Int>? {
        guard let spec = header.split(separator: "=", maxSplits: 1).last else { return nil }
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard bounds.count == 2, let start = Int(bounds[0]), start < length else { return nil }
        let end = Int(bounds[1]).map { min($0 + 1, length) } ?? length
        return start < end ? start..<end : nil
    }

    // MARK: Playlist attributes (Apple's HLS authoring spec: CODECS, RESOLUTION, FRAME-RATE, VIDEO-RANGE, bandwidths)

    private static func variantAttributes(_ input: UnsafeMutablePointer<AVFormatContext>, video: UnsafeMutablePointer<AVStream>) -> String {
        let parameters = video.pointee.codecpar!
        let bitRate = input.pointee.bit_rate > 0 ? input.pointee.bit_rate : 20_000_000
        var attributes = "BANDWIDTH=\(bitRate * 2),AVERAGE-BANDWIDTH=\(bitRate)"
        if parameters.pointee.width > 0, parameters.pointee.height > 0 {
            attributes += ",RESOLUTION=\(parameters.pointee.width)x\(parameters.pointee.height)"
        }
        let rate = video.pointee.avg_frame_rate
        if rate.num > 0, rate.den > 0 { attributes += ",FRAME-RATE=\(String(format: "%.3f", Double(rate.num) / Double(rate.den)))" }
        switch parameters.pointee.color_trc {
        case AVCOL_TRC_SMPTE2084: attributes += ",VIDEO-RANGE=PQ"
        case AVCOL_TRC_ARIB_STD_B67: attributes += ",VIDEO-RANGE=HLG"
        default: attributes += dolbyVisionProfile(parameters) != nil ? ",VIDEO-RANGE=PQ" : ",VIDEO-RANGE=SDR"
        }
        return attributes
    }

    /// RFC 6381 codec string from the avcC/hvcC record (ISO/IEC 14496-15), or nil if it can't be read.
    private static func videoCodecString(_ parameters: UnsafeMutablePointer<AVCodecParameters>) -> String? {
        guard let extradata = parameters.pointee.extradata else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: extradata, count: Int(parameters.pointee.extradata_size)))
        if parameters.pointee.codec_id == AV_CODEC_ID_H264 {
            guard bytes.count >= 4, bytes[0] == 1 else { return nil }
            return String(format: "avc1.%02x%02x%02x", bytes[1], bytes[2], bytes[3])
        }
        guard parameters.pointee.codec_id == AV_CODEC_ID_HEVC, bytes.count >= 13, bytes[0] == 1 else { return nil }
        if let profile = dolbyVisionProfile(parameters), profile == 5, let level = dolbyVisionLevel(parameters) {
            return String(format: "dvh1.%02ld.%02ld", profile, level)
        }
        let profileSpace = ["", "A", "B", "C"][Int(bytes[1] >> 6)]
        let tier = bytes[1] & 0x20 != 0 ? "H" : "L"
        let profile = bytes[1] & 0x1F
        let compatibility = bytes[2...5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var reversed: UInt32 = 0
        for bit in 0..<32 where compatibility & (1 << UInt32(bit)) != 0 { reversed |= 1 << UInt32(31 - bit) }
        var constraints = Array(bytes[6...11])
        while constraints.last == 0 { constraints.removeLast() }
        let constraintText = constraints.isEmpty ? "" : "." + constraints.map { String(format: "%02X", $0) }.joined(separator: ".")
        return "hvc1.\(profileSpace)\(profile).\(String(reversed, radix: 16, uppercase: true)).\(tier)\(bytes[12])\(constraintText)"
    }

    private static func audioCodecString(_ parameters: UnsafeMutablePointer<AVCodecParameters>) -> String {
        switch parameters.pointee.codec_id {
        case AV_CODEC_ID_AC3: return "ac-3"
        case AV_CODEC_ID_EAC3: return "ec-3"
        case AV_CODEC_ID_FLAC: return "fLaC"
        case AV_CODEC_ID_ALAC: return "alac"
        default:
            // AAC: the audio object type is the first 5 bits of the AudioSpecificConfig.
            guard let extradata = parameters.pointee.extradata, parameters.pointee.extradata_size > 0 else { return "mp4a.40.2" }
            let objectType = extradata[0] >> 3
            return "mp4a.40.\(objectType == 0 || objectType == 31 ? 2 : objectType)"
        }
    }

    private static func dolbyVisionRecord(_ parameters: UnsafeMutablePointer<AVCodecParameters>) -> UnsafeMutablePointer<UInt8>? {
        guard let sideData = av_packet_side_data_get(
            parameters.pointee.coded_side_data,
            parameters.pointee.nb_coded_side_data,
            AV_PKT_DATA_DOVI_CONF
        ), sideData.pointee.size > 3 else { return nil }
        return sideData.pointee.data
    }

    /// AVDOVIDecoderConfigurationRecord: version major, minor, dv_profile, dv_level, …
    private static func dolbyVisionProfile(_ parameters: UnsafeMutablePointer<AVCodecParameters>) -> Int? {
        dolbyVisionRecord(parameters).map { Int($0[2]) }
    }

    private static func dolbyVisionLevel(_ parameters: UnsafeMutablePointer<AVCodecParameters>) -> Int? {
        dolbyVisionRecord(parameters).map { Int($0[3]) }
    }

    // MARK: Helpers

    private func record(_ error: Error) {
        let message = error.localizedDescription
        errorLock.lock()
        storedLastError = message
        errorLock.unlock()
        InAppLogBridge.shared.error(tag: "Player/Remux", message: message)
    }

    private func dropCarry() {
        carry.forEach(Self.release)
        carry.removeAll()
    }

    static func release(_ packet: UnsafeMutablePointer<AVPacket>) {
        var pointer: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&pointer)
    }

    private static func seconds(_ timeBase: AVRational) -> Double {
        Double(timeBase.num) / Double(timeBase.den)
    }

    private static func codecName(_ codec: AVCodecID) -> String {
        String(cString: avcodec_get_name(codec))
    }

    private static func codecLabel(_ parameters: UnsafeMutablePointer<AVCodecParameters>) -> String {
        if let profile = avcodec_profile_name(parameters.pointee.codec_id, parameters.pointee.profile) {
            return String(cString: profile)
        }
        return codecName(parameters.pointee.codec_id).uppercased()
    }

    private static func channelLabel(_ channels: Int32) -> String {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    private static func metadata(_ stream: UnsafeMutablePointer<AVStream>, _ key: String) -> String? {
        guard let entry = av_dict_get(stream.pointee.metadata, key, nil, 0), let value = entry.pointee.value else { return nil }
        let text = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// ISO 639-2 ("eng") to the RFC 5646 tag HLS expects ("en"); nil when unknown.
    private static func languageTag(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.lowercased() != "und" else { return nil }
        // Only letters, digits and hyphens are valid in an RFC 5646 tag (and inside the quoted attribute).
        let tag = Locale.canonicalLanguageIdentifier(from: raw).replacingOccurrences(of: "_", with: "-")
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        return tag.isEmpty ? nil : tag
    }

    private static func unique(_ name: String, in names: inout Set<String>) -> String {
        var candidate = name
        var counter = 2
        while names.contains(candidate) {
            candidate = "\(name) \(counter)"
            counter += 1
        }
        names.insert(candidate)
        return candidate
    }

    private static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ")
    }

    /// MKTAG order: first character in the lowest byte.
    private static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func nominalFrameDuration(_ stream: UnsafeMutablePointer<AVStream>) -> Int64 {
        let rate = stream.pointee.avg_frame_rate
        guard rate.num > 0, rate.den > 0 else { return 1 }
        return max(1, av_rescale_q(1, AVRational(num: rate.den, den: rate.num), stream.pointee.time_base))
    }

    private static func firstBox(_ type: String, in data: Data) -> Int? {
        var offset = 0
        while offset + 8 <= data.count {
            let size = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            if String(decoding: data[offset + 4..<offset + 8], as: UTF8.self) == type { return offset }
            guard size >= 8 else { return nil }
            offset += size
        }
        return nil
    }
}

/// Decodes one audio track AVPlayer can't play and re-encodes it as FLAC, losslessly: the decoded samples are
/// stored exactly (up to 24-bit) with the original channel count. Decoder and encoder state carry across
/// consecutive segments so there are no gaps; a seek resets them.
private final class FlacTranscoder {
    private let stream: UnsafeMutablePointer<AVStream>
    private var decoder: UnsafeMutablePointer<AVCodecContext>?
    private var encoder: UnsafeMutablePointer<AVCodecContext>?
    private var resampler: OpaquePointer?
    private var fifo: OpaquePointer?
    private(set) var parameters: UnsafeMutablePointer<AVCodecParameters>?
    private var nextSegment = -1
    private var cursor: Int64?

    /// FFmpeg's FLAC channel layouts (FLAC channel assignments), as AV_CH_* masks by channel count.
    private static let layoutMasks: [Int32: UInt64] = [
        1: 0x4, // FC
        2: 0x3, // FL FR
        3: 0x7, // FL FR FC
        4: 0x33, // FL FR BL BR
        5: 0x607, // FL FR FC SL SR
        6: 0x60F, // FL FR FC LFE SL SR
        7: 0x70F, // FL FR FC LFE BC SL SR
        8: 0x63F, // FL FR FC LFE BL BR SL SR
    ]

    init(stream: UnsafeMutablePointer<AVStream>) throws {
        self.stream = stream
        guard let parameters = stream.pointee.codecpar,
              let codec = avcodec_find_decoder(parameters.pointee.codec_id),
              let context = avcodec_alloc_context3(codec) else {
            throw RemuxError("no decoder for \(String(cString: avcodec_get_name(stream.pointee.codecpar.pointee.codec_id)))")
        }
        decoder = context
        guard avcodec_parameters_to_context(context, parameters) >= 0 else { throw RemuxError("decoder parameters rejected") }
        context.pointee.pkt_timebase = stream.pointee.time_base
        let result = avcodec_open2(context, codec, nil)
        guard result >= 0 else { throw RemuxError("decoder failed to open: \(FFmpegSeekPreviewGenerator.describe(result))") }
        guard Self.layoutMasks[parameters.pointee.ch_layout.nb_channels] != nil || parameters.pointee.ch_layout.nb_channels == 0 else {
            throw RemuxError("\(parameters.pointee.ch_layout.nb_channels)-channel audio has no FLAC layout")
        }
    }

    deinit {
        resetEncoder()
        if decoder != nil { avcodec_free_context(&decoder) }
        if parameters != nil { avcodec_parameters_free(&parameters) }
    }

    /// Returns FLAC packets with timestamps in 1/sample_rate.
    func encode(_ packets: [UnsafeMutablePointer<AVPacket>], segment: Int, isLast: Bool) throws -> [UnsafeMutablePointer<AVPacket>] {
        guard let decoder else { return [] }
        if segment != nextSegment {
            avcodec_flush_buffers(decoder)
            resetEncoder()
        }
        nextSegment = segment + 1
        var output: [UnsafeMutablePointer<AVPacket>] = []
        do {
            for packet in packets {
                guard avcodec_send_packet(decoder, packet) >= 0 else { continue } // a damaged packet; skip it
                while true {
                    guard let frame = av_frame_alloc() else { throw RemuxError("out of memory") }
                    var framePointer: UnsafeMutablePointer<AVFrame>? = frame
                    defer { av_frame_free(&framePointer) }
                    guard avcodec_receive_frame(decoder, frame) >= 0 else { break }
                    try push(frame, into: &output)
                }
            }
            if isLast { try drain(final: true, into: &output) }
        } catch {
            output.forEach(HLSRemuxer.release)
            throw error
        }
        return output
    }

    private func push(_ frame: UnsafeMutablePointer<AVFrame>, into output: inout [UnsafeMutablePointer<AVPacket>]) throws {
        if encoder == nil { try openEncoder(matching: frame) }
        guard let encoder, let resampler, let fifo else { return }
        if cursor == nil {
            let pts = frame.pointee.best_effort_timestamp
            cursor = pts == Int64.min ? 0 : av_rescale_q(pts, stream.pointee.time_base, AVRational(num: 1, den: encoder.pointee.sample_rate))
        }
        guard let converted = av_frame_alloc() else { throw RemuxError("out of memory") }
        var convertedPointer: UnsafeMutablePointer<AVFrame>? = converted
        defer { av_frame_free(&convertedPointer) }
        converted.pointee.format = encoder.pointee.sample_fmt.rawValue
        converted.pointee.sample_rate = frame.pointee.sample_rate
        _ = av_channel_layout_copy(&converted.pointee.ch_layout, &frame.pointee.ch_layout)
        let result = swr_convert_frame(resampler, converted, frame)
        guard result >= 0 else { throw RemuxError("sample conversion failed: \(FFmpegSeekPreviewGenerator.describe(result))") }
        _ = av_audio_fifo_write(fifo, Self.planes(converted), converted.pointee.nb_samples)
        try drain(final: false, into: &output)
    }

    private func drain(final: Bool, into output: inout [UnsafeMutablePointer<AVPacket>]) throws {
        guard let encoder, let fifo else { return }
        let frameSize = encoder.pointee.frame_size
        while av_audio_fifo_size(fifo) >= frameSize || (final && av_audio_fifo_size(fifo) > 0) {
            let count = min(frameSize, av_audio_fifo_size(fifo))
            guard let frame = av_frame_alloc() else { throw RemuxError("out of memory") }
            var framePointer: UnsafeMutablePointer<AVFrame>? = frame
            defer { av_frame_free(&framePointer) }
            frame.pointee.nb_samples = count
            frame.pointee.format = encoder.pointee.sample_fmt.rawValue
            frame.pointee.sample_rate = encoder.pointee.sample_rate
            _ = av_channel_layout_copy(&frame.pointee.ch_layout, &encoder.pointee.ch_layout)
            guard av_frame_get_buffer(frame, 0) >= 0 else { throw RemuxError("out of memory") }
            _ = av_audio_fifo_read(fifo, Self.planes(frame), count)
            frame.pointee.pts = cursor ?? 0
            cursor = (cursor ?? 0) + Int64(count)
            let result = avcodec_send_frame(encoder, frame)
            guard result >= 0 else { throw RemuxError("FLAC encoding failed: \(FFmpegSeekPreviewGenerator.describe(result))") }
            collect(into: &output)
        }
        if final {
            _ = avcodec_send_frame(encoder, nil)
            collect(into: &output)
        }
    }

    private func collect(into output: inout [UnsafeMutablePointer<AVPacket>]) {
        guard let encoder else { return }
        while let packet = av_packet_alloc() {
            guard avcodec_receive_packet(encoder, packet) >= 0 else {
                HLSRemuxer.release(packet)
                return
            }
            packet.pointee.dts = packet.pointee.pts
            output.append(packet)
        }
    }

    private func openEncoder(matching frame: UnsafeMutablePointer<AVFrame>) throws {
        let channels = frame.pointee.ch_layout.nb_channels
        guard let mask = Self.layoutMasks[channels] else { throw RemuxError("\(channels)-channel audio has no FLAC layout") }
        guard let codec = avcodec_find_encoder(AV_CODEC_ID_FLAC), let context = avcodec_alloc_context3(codec) else {
            throw RemuxError("FLAC encoder unavailable")
        }
        encoder = context
        let format = AVSampleFormat(rawValue: frame.pointee.format)
        let sixteenBit = format == AV_SAMPLE_FMT_S16 || format == AV_SAMPLE_FMT_S16P
        context.pointee.sample_fmt = sixteenBit ? AV_SAMPLE_FMT_S16 : AV_SAMPLE_FMT_S32
        context.pointee.bits_per_raw_sample = sixteenBit ? 16 : 24
        context.pointee.sample_rate = frame.pointee.sample_rate
        context.pointee.time_base = AVRational(num: 1, den: frame.pointee.sample_rate)
        // Same channels in the same order; only the label follows FLAC's assignment (e.g. back → side surrounds).
        _ = av_channel_layout_from_mask(&context.pointee.ch_layout, mask)
        let result = avcodec_open2(context, codec, nil)
        guard result >= 0 else { throw RemuxError("FLAC encoder failed to open: \(FFmpegSeekPreviewGenerator.describe(result))") }

        if parameters == nil { parameters = avcodec_parameters_alloc() }
        guard let parameters, avcodec_parameters_from_context(parameters, context) >= 0 else { throw RemuxError("out of memory") }

        guard swr_alloc_set_opts2(
            &resampler,
            &frame.pointee.ch_layout, context.pointee.sample_fmt, frame.pointee.sample_rate,
            &frame.pointee.ch_layout, format, frame.pointee.sample_rate,
            0, nil
        ) >= 0, swr_init(resampler) >= 0 else { throw RemuxError("sample converter failed to open") }
        fifo = av_audio_fifo_alloc(context.pointee.sample_fmt, channels, max(1, context.pointee.frame_size))
        guard fifo != nil else { throw RemuxError("out of memory") }
    }

    private func resetEncoder() {
        if encoder != nil { avcodec_free_context(&encoder) }
        if resampler != nil { swr_free(&resampler) }
        if let fifo { av_audio_fifo_free(fifo) }
        fifo = nil
        cursor = nil
    }

    private static func planes(_ frame: UnsafeMutablePointer<AVFrame>) -> UnsafePointer<UnsafeMutableRawPointer?> {
        UnsafeRawPointer(frame.pointee.extended_data!).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    }
}

private struct RemuxError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }

    /// The app skips to the next source on this prefix (PlayerScreenRuntimeEffects.kt).
    static func unplayable(_ message: String) -> RemuxError {
        RemuxError("Unplayable format: \(message)")
    }
}
