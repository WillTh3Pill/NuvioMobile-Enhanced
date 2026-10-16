import ComposeApp
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Network

/// Repackages a stream AVPlayer can't open (MKV and friends) into fragmented-MP4 HLS served from
/// 127.0.0.1. Lossless: video and audio packets are copied bit-for-bit; only the container changes.
/// Segment boundaries come from the file's keyframe index, so the playlist is exact and any segment
/// can be produced on demand (seeking). Consecutive segments are read straight through without seeking.
final class HLSRemuxer {
    enum Outcome {
        case remux(URL)
        case playDirectly
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
    private var input: UnsafeMutablePointer<AVFormatContext>?
    private var videoIndex: Int32 = -1
    private var audioIndex: Int32 = -1
    private var boundaries: [Int64] = []
    private var playlist = Data()
    private var initSegment: Data?
    private var cache: [Int: Data] = [:]
    private var nextSequential = -1
    private var carry: [UnsafeMutablePointer<AVPacket>] = []

    private static let minimumSegmentSeconds: Int64 = 4
    private static let timestampOffsetSeconds: Int64 = 10 // keeps the first segment's B-frame dts positive
    private static let noPts = Int64.min
    private static let averrorEOF: Int32 = -541_478_725 // AVERROR_EOF; its FFERRTAG macro isn't visible to Swift
    private static let copyableAudio = [AV_CODEC_ID_AAC, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3]

    init(url: String, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }

    var lastError: String? {
        errorLock.lock()
        defer { errorLock.unlock() }
        return storedLastError
    }

    /// Opens the source; completes on the main queue with the local playlist URL, or `.playDirectly`
    /// when the source is already something AVPlayer handles natively (MP4, HLS).
    func start(completion: @escaping (Result<Outcome, Error>) -> Void) {
        let finish: (Result<Outcome, Error>) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }
        work.async {
            do {
                guard try self.openSource() else { return finish(.success(.playDirectly)) }
                self.startListener { result in
                    finish(result.map { Outcome.remux(URL(string: "http://127.0.0.1:\($0)/index.m3u8")!) })
                }
            } catch {
                self.record(error)
                finish(.failure(error))
            }
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
            cache.removeAll()
            if input != nil { avformat_close_input(&input) }
        }
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
        if formatName.contains("mp4") || formatName.contains("hls") { return false }

        let infoResult = avformat_find_stream_info(opened, nil)
        guard infoResult >= 0 else {
            throw RemuxError("couldn't read the stream: \(FFmpegSeekPreviewGenerator.describe(infoResult))")
        }

        videoIndex = av_find_best_stream(opened, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard videoIndex >= 0, let video = opened.pointee.streams[Int(videoIndex)],
              let videoParameters = video.pointee.codecpar else { throw RemuxError("the stream has no video") }
        let videoCodec = videoParameters.pointee.codec_id
        guard videoCodec == AV_CODEC_ID_H264 || videoCodec == AV_CODEC_ID_HEVC else {
            throw RemuxError("AVPlayer can't play \(Self.codecName(videoCodec)) video")
        }

        let preferredAudio = av_find_best_stream(opened, AVMEDIA_TYPE_AUDIO, -1, videoIndex, nil, 0)
        var audioCodecs: [AVCodecID] = []
        var copyable: [Int32] = []
        for index in 0..<Int32(opened.pointee.nb_streams) {
            guard let parameters = opened.pointee.streams[Int(index)]?.pointee.codecpar,
                  parameters.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            audioCodecs.append(parameters.pointee.codec_id)
            if Self.copyableAudio.contains(parameters.pointee.codec_id) { copyable.append(index) }
        }
        if !audioCodecs.isEmpty && copyable.isEmpty {
            // ponytail: DTS/TrueHD-only files stop here; next step is decoding them to ALAC (lossless) here.
            let names = audioCodecs.map(Self.codecName).joined(separator: ", ")
            throw RemuxError("this file's audio (\(names)) needs lossless conversion, which isn't built yet")
        }
        audioIndex = copyable.contains(preferredAudio) ? preferredAudio : (copyable.first ?? -1)
        for index in 0..<Int(opened.pointee.nb_streams) where Int32(index) != videoIndex && Int32(index) != audioIndex {
            opened.pointee.streams[index]?.pointee.discard = AVDISCARD_ALL
        }

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
            throw RemuxError("the file has no keyframe index to build a seekable playlist from")
        }

        let timeBase = video.pointee.time_base
        var end = Self.noPts
        if opened.pointee.duration > 0 {
            let start = opened.pointee.start_time == Self.noPts ? 0 : opened.pointee.start_time
            end = av_rescale_q(start + opened.pointee.duration, AVRational(num: 1, den: AV_TIME_BASE), timeBase)
        } else if video.pointee.duration > 0 {
            end = (video.pointee.start_time == Self.noPts ? 0 : video.pointee.start_time) + video.pointee.duration
        }
        guard end != Self.noPts, end > sortedKeyframes[0] else { throw RemuxError("the stream has no known length") }

        let minimum = av_rescale_q(Self.minimumSegmentSeconds, AVRational(num: 1, den: 1), timeBase)
        var bounds = [sortedKeyframes[0]]
        for keyframe in sortedKeyframes.dropFirst() where keyframe < end && keyframe - bounds[bounds.count - 1] >= minimum {
            bounds.append(keyframe)
        }
        bounds.append(end)
        boundaries = bounds

        let secondsPerTick = Double(timeBase.num) / Double(timeBase.den)
        let durations = zip(bounds, bounds.dropFirst()).map { Double($1 - $0) * secondsPerTick }
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        text += "#EXT-X-TARGETDURATION:\(Int((durations.max() ?? 1).rounded(.up)))\n"
        text += "#EXT-X-MAP:URI=\"init.mp4\"\n"
        for (index, duration) in durations.enumerated() {
            text += "#EXTINF:\(String(format: "%.6f", duration)),\nseg\(index).m4s\n"
        }
        text += "#EXT-X-ENDLIST\n"
        playlist = Data(text.utf8)

        let audioName = audioIndex >= 0
            ? Self.codecName(opened.pointee.streams[Int(audioIndex)]!.pointee.codecpar.pointee.codec_id)
            : "none"
        InAppLogBridge.shared.info(
            tag: "Player/Remux",
            message: "repackaging \(formatName) video=\(Self.codecName(videoCodec)) audio=\(audioName) " +
                "keyframes=\(sortedKeyframes.count) segments=\(durations.count)"
        )
        return true
    }

    // MARK: Segments

    private func initData() throws -> Data {
        if let initSegment { return initSegment }
        _ = try segment(0)
        guard let initSegment else { throw RemuxError("no init segment") }
        return initSegment
    }

    private func segment(_ index: Int) throws -> Data {
        if let cached = cache[index] { return cached }
        let media = try produce(index)
        cache[index] = media
        // ponytail: keeps only neighbouring segments for AVPlayer's repeat requests (4K segments are large).
        if cache.count > 2 { cache = cache.filter { abs($0.key - index) <= 1 } }
        return media
    }

    private func produce(_ index: Int) throws -> Data {
        guard let input, index >= 0, index + 1 < boundaries.count,
              let video = input.pointee.streams[Int(videoIndex)] else {
            throw RemuxError("segment \(index) doesn't exist")
        }
        let start = boundaries[index]
        let end = boundaries[index + 1]
        let isLast = index + 2 == boundaries.count
        let videoTimeBase = video.pointee.time_base
        let audio = audioIndex >= 0 ? input.pointee.streams[Int(audioIndex)] : nil
        // Safety stop if the index promised a keyframe that never arrives, or the audio track ends early.
        let horizon = end + av_rescale_q(10, AVRational(num: 1, den: 1), videoTimeBase)

        if index != nextSequential {
            dropCarry()
            let seekResult = av_seek_frame(input, videoIndex, start, AVSEEK_FLAG_BACKWARD)
            guard seekResult >= 0 else {
                throw RemuxError("seek to segment \(index) failed: \(FFmpegSeekPreviewGenerator.describe(seekResult))")
            }
        }
        nextSequential = -1

        var videoPackets: [UnsafeMutablePointer<AVPacket>] = []
        var audioPackets: [UnsafeMutablePointer<AVPacket>] = []
        var pending = carry
        carry = []
        defer { (videoPackets + audioPackets + pending).forEach(Self.release) }
        var videoStarted = false
        var videoDone = false
        var audioDone = audio == nil

        while !(videoDone && audioDone) {
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
            if ts == Self.noPts || (streamIndex != videoIndex && streamIndex != audioIndex) {
                Self.release(packet)
                continue
            }

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
            } else if let audio {
                let videoTime = av_rescale_q(ts, audio.pointee.time_base, videoTimeBase)
                if audioDone || (videoTime >= end && !isLast) {
                    audioDone = true
                    carry.append(packet)
                } else if videoTime < start {
                    Self.release(packet)
                } else {
                    audioPackets.append(packet)
                }
            }
        }
        carry.append(contentsOf: pending)
        pending.removeAll()

        guard !videoPackets.isEmpty else { throw RemuxError("segment \(index) has no video") }
        let media = try mux(videoPackets, audioPackets, video: video, audio: audio)
        nextSequential = index + 1
        return media
    }

    // MARK: fMP4

    private func mux(
        _ videoPackets: [UnsafeMutablePointer<AVPacket>],
        _ audioPackets: [UnsafeMutablePointer<AVPacket>],
        video: UnsafeMutablePointer<AVStream>,
        audio: UnsafeMutablePointer<AVStream>?
    ) throws -> Data {
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

        guard let videoOut = avformat_new_stream(output, nil),
              avcodec_parameters_copy(videoOut.pointee.codecpar, video.pointee.codecpar) >= 0 else {
            throw RemuxError("couldn't set up the video track")
        }
        videoOut.pointee.time_base = video.pointee.time_base
        // AVPlayer only accepts HEVC tagged hvc1 (or dvh1 for single-layer Dolby Vision profile 5).
        videoOut.pointee.codecpar.pointee.codec_tag = video.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_HEVC
            ? Self.fourCC(Self.isDolbyVisionProfile5(video.pointee.codecpar) ? "dvh1" : "hvc1")
            : 0

        var audioOut: UnsafeMutablePointer<AVStream>?
        if let audio {
            guard let stream = avformat_new_stream(output, nil),
                  avcodec_parameters_copy(stream.pointee.codecpar, audio.pointee.codecpar) >= 0 else {
                throw RemuxError("couldn't set up the audio track")
            }
            stream.pointee.codecpar.pointee.codec_tag = 0
            stream.pointee.time_base = audio.pointee.time_base
            audioOut = stream
        }

        // Keep the source's absolute timestamps in every fragment (tfdt), so AVPlayer can join
        // segments produced independently: no edit list, no shifting, discontinuous fragments.
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

        // Video: Matroska only stores presentation times, so derive decode times from them.
        let videoOutTimeBase = videoOut.pointee.time_base
        let videoOffset = av_rescale_q(Self.timestampOffsetSeconds, AVRational(num: 1, den: 1), videoOutTimeBase)
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
            av_packet_rescale_ts(packet, video.pointee.time_base, videoOutTimeBase)
            packet.pointee.pts += videoOffset
            packet.pointee.dts += videoOffset
            packet.pointee.stream_index = videoOut.pointee.index
            let result = av_write_frame(output, packet)
            guard result >= 0 else { throw RemuxError("writing video failed: \(FFmpegSeekPreviewGenerator.describe(result))") }
        }

        // Audio: lay frames on the exact sample grid (Matroska rounds times to milliseconds) so
        // independently produced segments join without gaps.
        if let audio, let audioOut, !audioPackets.isEmpty {
            let parameters = audio.pointee.codecpar.pointee
            let outTimeBase = audioOut.pointee.time_base
            let offset = av_rescale_q(Self.timestampOffsetSeconds, AVRational(num: 1, den: 1), outTimeBase)
            let frame = parameters.frame_size > 0 && parameters.sample_rate > 0
                ? av_rescale_q(Int64(parameters.frame_size), AVRational(num: 1, den: parameters.sample_rate), outTimeBase)
                : 0
            let streamStart = audio.pointee.start_time == Self.noPts
                ? 0
                : av_rescale_q(audio.pointee.start_time, audio.pointee.time_base, outTimeBase)
            var first = av_rescale_q(audioPackets[0].pointee.pts, audio.pointee.time_base, outTimeBase)
            if frame > 0 { first = streamStart + (first - streamStart + frame / 2) / frame * frame }
            for (position, packet) in audioPackets.enumerated() {
                if frame > 0 {
                    packet.pointee.pts = first + Int64(position) * frame
                    packet.pointee.duration = frame
                } else {
                    packet.pointee.pts = av_rescale_q(packet.pointee.pts, audio.pointee.time_base, outTimeBase)
                    packet.pointee.duration = av_rescale_q(packet.pointee.duration, audio.pointee.time_base, outTimeBase)
                }
                packet.pointee.pts += offset
                packet.pointee.dts = packet.pointee.pts
                packet.pointee.stream_index = audioOut.pointee.index
                let result = av_write_frame(output, packet)
                guard result >= 0 else { throw RemuxError("writing audio failed: \(FFmpegSeekPreviewGenerator.describe(result))") }
            }
        }

        // delay_moov: the first flush writes ftyp+moov (AC-3/E-AC-3 configs need packets first),
        // the second writes this segment's moof+mdat.
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
        if initSegment == nil { initSegment = Data(bytes[..<fragmentStart]) }
        return Data(bytes[fragmentStart...])
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
        let name = parts.count > 1 ? String(parts[1].split(separator: "/").last ?? "") : ""
        let range = lines.first { $0.lowercased().hasPrefix("range:") }
        work.async { [weak self] in
            guard let self else { return connection.cancel() }
            let response = self.response(for: name)
            self.network.async { self.send(response, range: range, headOnly: isHead, on: connection) }
        }
    }

    private func response(for name: String) -> (status: String, type: String, body: Data) {
        do {
            if name == "index.m3u8" { return ("200 OK", "application/vnd.apple.mpegurl", playlist) }
            if name == "init.mp4" { return ("200 OK", "video/mp4", try initData()) }
            if name.hasPrefix("seg"), name.hasSuffix(".m4s"), let index = Int(name.dropFirst(3).dropLast(4)) {
                return ("200 OK", "video/mp4", try segment(index))
            }
            return ("404 Not Found", "text/plain", Data())
        } catch {
            record(error)
            return ("500 Internal Server Error", "text/plain", Data(error.localizedDescription.utf8))
        }
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

    private static func release(_ packet: UnsafeMutablePointer<AVPacket>) {
        var pointer: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&pointer)
    }

    private static func codecName(_ codec: AVCodecID) -> String {
        String(cString: avcodec_get_name(codec))
    }

    /// MKTAG order: first character in the lowest byte.
    private static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func isDolbyVisionProfile5(_ parameters: UnsafeMutablePointer<AVCodecParameters>) -> Bool {
        guard let sideData = av_packet_side_data_get(
            parameters.pointee.coded_side_data,
            parameters.pointee.nb_coded_side_data,
            AV_PKT_DATA_DOVI_CONF
        ), sideData.pointee.size > 2 else { return false }
        return sideData.pointee.data[2] == 5 // AVDOVIDecoderConfigurationRecord.dv_profile
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

    /// "Range: bytes=start-end" or "bytes=start-"; anything else is served whole.
    private static func byteRange(_ header: String, length: Int) -> Range<Int>? {
        guard let spec = header.split(separator: "=", maxSplits: 1).last else { return nil }
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard bounds.count == 2, let start = Int(bounds[0]), start < length else { return nil }
        let end = Int(bounds[1]).map { min($0 + 1, length) } ?? length
        return start < end ? start..<end : nil
    }
}

private struct RemuxError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
