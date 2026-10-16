import AVFoundation
import MediaPlayer
import UIKit
import ComposeApp

/// Stream player. AVPlayer's external playback hands video straight to a connected display (USB-C/HDMI dock,
/// AirPlay), so the TV gets full-screen video at its own aspect ratio and keeps playing with the iPad locked,
/// which mpv can't do because it renders with the app's GPU access that iOS revokes in the background.
/// Video is drawn by a plain AVPlayerLayer: AVKit's view controller turns external playback off while it is
/// shown inline. Containers AVPlayer can't open (MKV, …) are repackaged losslessly by HLSRemuxer.
final class AVPlayerBridgeImpl: NSObject, NuvioPlayerBridge {

    private let player = AVPlayer()
    private lazy var playerView: PlayerLayerView = {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        return view
    }()
    private lazy var playerVC: UIViewController = {
        let vc = UIViewController()
        vc.view = playerView
        return vc
    }()
    private lazy var nowPlaying: MPNowPlayingSession = {
        let session = MPNowPlayingSession(players: [player])
        session.automaticallyPublishesNowPlayingInfo = true
        return session
    }()
    private var remuxer: HLSRemuxer?
    private var lastLoad: (url: String, headersJson: String?, subtitlesJson: String?)?
    private var wantsPlayback = false
    private var unsupportedReason = ""
    private var isEnded = false
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var externalObservation: NSKeyValueObservation?
    private var metadata: [AVMetadataItem] = []
    private var artworkItem: AVMetadataItem?
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var textStyleRules: [AVTextStyleRule]?
    // Restored after a reload (adding an addon subtitle or changing the subtitle delay rebuilds the playlist).
    private var pendingSeek: CMTime?
    private var pendingAudioName: String?
    private var pendingSubtitleName: String?
    private var restoresSubtitleSelection = false
    private var addonSubtitleNames: [String: String] = [:] // subtitle URL → rendition name
    private var subtitleDelayReload: DispatchWorkItem?
    private var backgroundObserver: NSObjectProtocol?
    private var playingObservation: NSKeyValueObservation?

    // The next episode's player is created before the previous one is destroyed.
    private static var liveCount = 0
    // With the iPad locked, iOS suspends a background-audio app soon after its audio stops, so the app is kept
    // running from the end of an episode (or a player being replaced) until the next one plays.
    private static var gapTask = UIBackgroundTaskIdentifier.invalid

    private static func holdGap() {
        guard gapTask == .invalid else { return }
        gapTask = UIApplication.shared.beginBackgroundTask(withName: "Next episode") { releaseGap() }
    }

    private static func releaseGap() {
        guard gapTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(gapTask)
        gapTask = .invalid
    }

    override init() {
        super.init()
        Self.liveCount += 1
        playingObservation = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            guard player.timeControlStatus == .playing else { return }
            DispatchQueue.main.async { Self.releaseGap() }
        }
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        externalObservation = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { player, _ in
            InAppLogBridge.shared.info(tag: "Player/External", message: Self.externalPlaybackState(player))
        }
        ExternalDisplay.shared.attach(self) { [weak self] in self?.routeVideo() }
        routeVideo()
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            InAppLogBridge.shared.info(tag: "Player/External", message: "iPad locked/backgrounded: \(self.playbackState())")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                InAppLogBridge.shared.info(tag: "Player/External", message: "3s after locking: \(self.playbackState())")
            }
        }
        let center = nowPlaying.remoteCommandCenter
        center.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.player.timeControlStatus == .paused ? self.play() : self.pause()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seekTo(positionMs: Int64(event.positionTime * 1000))
            return .success
        }
    }

    func createPlayerViewController() -> UIViewController { playerVC }

    /// A player draws on one layer at a time: the connected display's while there is one, otherwise the iPad's.
    private func routeVideo() {
        let display = ExternalDisplay.shared
        if display.isConnected {
            playerView.playerLayer.player = nil
            display.present(player)
        } else {
            display.present(nil)
            playerView.playerLayer.player = player
        }
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        InAppLogBridge.shared.info(
            tag: "Player/External",
            message: "video on \(display.isConnected ? "connected display" : "iPad"): \(Self.externalPlaybackState(player))"
        )
    }

    private func playbackState() -> String {
        "status=\(player.timeControlStatus.rawValue) rate=\(player.rate) \(Self.externalPlaybackState(player))"
    }

    func loadFile(url: String) {
        loadFileWithAudio(videoUrl: url, audioUrl: nil, headersJson: nil, subtitlesJson: nil)
    }

    func loadFileWithAudio(videoUrl: String, audioUrl: String?, headersJson: String?, subtitlesJson: String?) {
        remuxer?.stop()
        remuxer = nil
        player.replaceCurrentItem(with: nil)
        isEnded = false
        audioGroup = nil
        subtitleGroup = nil
        pendingSeek = nil
        pendingAudioName = nil
        restoresSubtitleSelection = false
        addonSubtitleNames = [:]
        lastLoad = (videoUrl, headersJson, subtitlesJson)
        if let audioUrl, !audioUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            unsupportedReason = "Unplayable format: AVPlayer can't merge a separate audio stream"
            return
        }
        guard let url = URL(string: videoUrl) else {
            unsupportedReason = "Invalid stream URL"
            return
        }
        unsupportedReason = ""

        // AVPlayer issues its own Range requests, so a forwarded Range header would break them.
        let headers = headersJson?.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }?
            .filter { $0.key.caseInsensitiveCompare("Range") != .orderedSame } ?? [:]

        // HLS sources play as they are; everything else goes through the repackager so every audio track,
        // embedded subtitles and addon subtitles are available.
        if url.pathExtension.lowercased() == "m3u8" {
            playItem(url, headers: headers)
            return
        }
        let subtitles = MPVPlayerBridgeImpl.parseSubtitles(subtitlesJson).map {
            HLSRemuxer.SubtitleSource(url: $0.url, name: $0.name, language: $0.language, headers: $0.headers ?? [:])
        }
        let remuxer = HLSRemuxer(url: videoUrl, headers: headers)
        self.remuxer = remuxer
        remuxer.start(subtitles: subtitles) { [weak self] result in
            guard let self, self.remuxer === remuxer else { return }
            switch result {
            case .success(.remux(let localUrl)):
                self.playItem(localUrl, headers: [:])
            case .success(.playDirectly):
                remuxer.stop()
                self.remuxer = nil
                self.playItem(url, headers: headers)
            case .failure(let error):
                self.unsupportedReason = error.localizedDescription
            }
        }
    }

    private func playItem(_ url: URL, headers: [String: String]) {
        let asset = AVURLAsset(url: url, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        item.externalMetadata = metadata + (artworkItem.map { [$0] } ?? [])
        item.textStyleRules = textStyleRules

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.isEnded = true
            Self.holdGap()
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                if item.status == .failed { Self.logFailure(item) }
                guard let self, item === self.player.currentItem, item.status == .readyToPlay, let seek = self.pendingSeek else { return }
                self.pendingSeek = nil
                self.player.seek(to: seek, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        player.replaceCurrentItem(with: item)
        // Attaching the layer and item must leave external playback on.
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        if wantsPlayback { player.play() }

        Task { @MainActor [weak self] in
            let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
            let subtitles = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self, self.player.currentItem === item else { return }
            self.audioGroup = audio
            self.subtitleGroup = subtitles
            if let name = self.pendingAudioName, let audio { self.select(audio, named: name) }
            if self.restoresSubtitleSelection, let subtitles { self.select(subtitles, named: self.pendingSubtitleName) }
            self.pendingAudioName = nil
            self.pendingSubtitleName = nil
            self.restoresSubtitleSelection = false
        }
    }

    /// Reloads the item from a rebuilt playlist, keeping position, audio track and subtitle choice.
    private func reload(_ url: URL, selectingSubtitle subtitleName: String?) {
        guard player.currentItem != nil else { return }
        pendingSeek = player.currentTime()
        pendingAudioName = selectedName(audioGroup)
        pendingSubtitleName = subtitleName ?? selectedName(subtitleGroup)
        restoresSubtitleSelection = true
        playItem(url, headers: [:])
    }

    func play() {
        wantsPlayback = true
        // Same serial queue as mpv, so a teardown deactivation can't land after this activation.
        MPVPlayerViewController.audioSessionQueue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
        }
        nowPlaying.becomeActiveIfPossible { _ in }
        player.play() // starts at player.defaultRate
        InAppLogBridge.shared.info(tag: "Player/External", message: "play: \(Self.externalPlaybackState(player))")
    }

    func pause() {
        wantsPlayback = false
        player.pause()
    }

    func seekTo(positionMs: Int64) {
        isEnded = false
        pendingSeek = nil
        player.seek(to: CMTime(value: positionMs, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seekBy(offsetMs: Int64) { seekTo(positionMs: max(0, getPositionMs() + offsetMs)) }

    func retry() {
        guard let lastLoad else { return }
        loadFileWithAudio(videoUrl: lastLoad.url, audioUrl: nil, headersJson: lastLoad.headersJson, subtitlesJson: lastLoad.subtitlesJson)
    }

    func setPlaybackSpeed(speed: Float) {
        player.defaultRate = speed
        if player.rate != 0 { player.rate = speed }
    }

    func getPlaybackSpeed() -> Float { player.defaultRate }

    // ponytail: AVPlayer volume caps at 1.0, so mpv's 200% boost is unavailable; an audio tap could add it.
    func getVolume() -> Float { player.volume }
    func setVolume(volume: Float) { player.volume = min(max(volume, 0), 1) }
    func setMuted(muted: Bool) { player.isMuted = muted }

    // Only affects the iPad-side layer; the external display always gets the full frame.
    func setResizeMode(mode: Int32) { playerView.playerLayer.videoGravity = mode == 0 ? .resizeAspect : .resizeAspectFill }

    func updateNowPlayingMetadata(title: String, subtitle: String?, artworkUrl: String?) {
        let fields: [(AVMetadataIdentifier, String?)] = [
            (.commonIdentifierTitle, title),
            (.iTunesMetadataTrackSubTitle, subtitle),
        ]
        metadata = fields.compactMap { identifier, value -> AVMetadataItem? in
            guard let value else { return nil }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item
        }
        applyMetadata()
        guard let artworkUrl, let url = URL(string: artworkUrl) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else { return }
            DispatchQueue.main.async {
                let item = AVMutableMetadataItem()
                item.identifier = .commonIdentifierArtwork
                item.value = jpeg as NSData
                item.dataType = kCMMetadataBaseDataType_JPEG as String
                item.extendedLanguageTag = "und"
                self?.artworkItem = item
                self?.applyMetadata()
            }
        }.resume()
    }

    private func applyMetadata() {
        player.currentItem?.externalMetadata = metadata + (artworkItem.map { [$0] } ?? [])
    }

    func clearNowPlayingInfo() {
        metadata = []
        artworkItem = nil
        applyMetadata()
    }

    // MARK: State (polled from Kotlin every 250ms)

    func getIsLoading() -> Bool {
        // Like mpv, a source that failed to open still counts as loading, so nothing seeks into it.
        guard let item = player.currentItem, item.status != .failed else { return true }
        return item.status == .unknown || pendingSeek != nil || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    func getIsPlaying() -> Bool { player.timeControlStatus == .playing }
    func getIsEnded() -> Bool { isEnded }
    func getDurationMs() -> Int64 { Self.ms(player.currentItem?.duration) }
    // During a reload the position being restored is reported, so watch progress never drops to zero.
    func getPositionMs() -> Int64 { Self.ms(pendingSeek ?? player.currentTime()) }

    func getBufferedMs() -> Int64 {
        let now = player.currentTime()
        let range = player.currentItem?.loadedTimeRanges.map(\.timeRangeValue).first { $0.containsTime(now) }
        return Self.ms(range?.end ?? now)
    }

    func getVideoWidth() -> Int32 { Int32(player.currentItem?.presentationSize.width ?? 0) }
    func getVideoHeight() -> Int32 { Int32(player.currentItem?.presentationSize.height ?? 0) }

    func getErrorMessage() -> String {
        if !unsupportedReason.isEmpty { return unsupportedReason }
        guard let error = player.currentItem?.error else { return "" }
        let detail = remuxer?.lastError.map { " (\($0))" } ?? ""
        return "AVPlayer: \(error.localizedDescription)\(detail)"
    }

    func getMediaInfoJson() -> String {
        remuxer == nil ? #"{"engine":"avplayer"}"# : #"{"engine":"avplayer (lossless repackaging)"}"#
    }

    private static func ms(_ time: CMTime?) -> Int64 {
        guard let seconds = time?.seconds, seconds.isFinite, seconds > 0 else { return 0 }
        return Int64(seconds * 1000)
    }

    /// AVPlayer's "Cannot Open" hides the reason; the underlying error and the access/error logs carry it.
    private static func logFailure(_ item: AVPlayerItem) {
        var lines: [String] = []
        if let error = item.error as NSError? {
            lines.append("error \(error.domain) \(error.code): \(error.localizedDescription)")
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                lines.append("underlying \(underlying.domain) \(underlying.code): \(underlying.localizedDescription)")
            }
            if let reason = error.localizedFailureReason { lines.append("reason: \(reason)") }
        }
        for event in item.errorLog()?.events ?? [] {
            lines.append("errorLog \(event.errorDomain) \(event.errorStatusCode) \(event.errorComment ?? "") uri=\(event.uri ?? "")")
        }
        InAppLogBridge.shared.error(tag: "Player/AVPlayer", message: lines.joined(separator: " | "))
    }

    private static func externalPlaybackState(_ player: AVPlayer) -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue)
        return "externalPlaybackActive=\(player.isExternalPlaybackActive) allows=\(player.allowsExternalPlayback) " +
            "whileExternalScreen=\(player.usesExternalPlaybackWhileExternalScreenIsActive) " +
            "screens=\(UIScreen.screens.count) audioOutputs=\(outputs)"
    }

    // MARK: Tracks (id == index into the AVMediaSelectionGroup)

    func getAudioTrackCount() -> Int32 { Int32(audioGroup?.options.count ?? 0) }
    func getAudioTrackIndex(at: Int32) -> Int32 { at }
    func getAudioTrackId(at: Int32) -> String { "\(at)" }
    func getAudioTrackLabel(at: Int32) -> String { option(audioGroup, at)?.displayName ?? "" }
    func getAudioTrackLang(at: Int32) -> String { Self.language(option(audioGroup, at)) }
    func isAudioTrackSelected(at: Int32) -> Bool { isSelected(audioGroup, at) }

    func getSubtitleTrackCount() -> Int32 { Int32(subtitleGroup?.options.count ?? 0) }
    func getSubtitleTrackIndex(at: Int32) -> Int32 { at }
    func getSubtitleTrackId(at: Int32) -> String { "\(at)" }
    func getSubtitleTrackLabel(at: Int32) -> String { option(subtitleGroup, at)?.displayName ?? "" }
    func getSubtitleTrackLang(at: Int32) -> String { Self.language(option(subtitleGroup, at)) }
    func isSubtitleTrackSelected(at: Int32) -> Bool { isSelected(subtitleGroup, at) }

    func selectAudioTrack(trackId: Int32) { select(audioGroup, trackId) }
    func selectSubtitleTrack(trackId: Int32) { select(subtitleGroup, trackId) }
    func clearExternalSubtitle() { select(subtitleGroup, -1) }
    func clearExternalSubtitleAndSelect(trackId: Int32) { select(subtitleGroup, trackId) }

    /// An addon subtitle becomes another subtitle rendition; the playlist is rebuilt and the item reloaded.
    func setSubtitleUrl(url: String) {
        if let name = addonSubtitleNames[url] {
            if let subtitleGroup { select(subtitleGroup, named: name) }
            return
        }
        guard let remuxer else {
            InAppLogBridge.shared.warn(tag: "Player/Remux", message: "addon subtitles can't be added to an HLS source")
            return
        }
        let source = HLSRemuxer.SubtitleSource(url: url, name: nil, language: nil, headers: [:])
        remuxer.addSubtitle(source) { [weak self] added in
            guard let self, self.remuxer === remuxer, let added else { return }
            self.addonSubtitleNames[url] = added.name
            self.reload(added.url, selectingSubtitle: added.name)
        }
    }

    func setSubtitleDelayMs(delayMs: Int32) {
        guard let remuxer else { return }
        remuxer.setSubtitleDelay(Double(delayMs) / 1000) { [weak self] url in
            // Already fetched subtitle segments keep the old timing, so reload once the user stops adjusting.
            guard let self, self.remuxer === remuxer, self.selectedName(self.subtitleGroup) != nil else { return }
            self.subtitleDelayReload?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reload(url, selectingSubtitle: nil) }
            self.subtitleDelayReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }
    }

    func applySubtitleStyle(
        textColor: String,
        backgroundColor: String,
        outlineColor: String,
        outlineSize: Float,
        bold: Bool,
        fontSize: Float,
        subPos: Int32,
        stripSdh: Bool
    ) {
        // Nuvio's default size (18sp) arrives as 54; AVPlayer sizes relative to its own default.
        var attributes: [String: Any] = [
            kCMTextMarkupAttribute_RelativeFontSize as String: max(50, min(200, Double(fontSize) / 54 * 100)),
        ]
        if let color = Self.argb(textColor) { attributes[kCMTextMarkupAttribute_ForegroundColorARGB as String] = color }
        if let color = Self.argb(backgroundColor), color[0] > 0 {
            attributes[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] = color
        }
        if bold { attributes[kCMTextMarkupAttribute_BoldStyle as String] = true }
        if outlineSize > 0 {
            attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] = kCMTextMarkupCharacterEdgeStyle_Uniform as String
        }
        textStyleRules = AVTextStyleRule(textMarkupAttributes: attributes).map { [$0] }
        player.currentItem?.textStyleRules = textStyleRules
    }

    /// "#AARRGGBB" → [a, r, g, b] in 0…1.
    private static func argb(_ hex: String) -> [Double]? {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }
        return [24, 16, 8, 0].map { Double((value >> UInt32($0)) & 0xFF) / 255 }
    }

    func applyAudioLanguagePreferences(languages: [String]) {
        player.setMediaSelectionCriteria(
            AVPlayerMediaSelectionCriteria(preferredLanguages: languages, preferredMediaCharacteristics: nil),
            forMediaCharacteristic: .audible
        )
    }

    private func option(_ group: AVMediaSelectionGroup?, _ at: Int32) -> AVMediaSelectionOption? {
        guard let options = group?.options, options.indices.contains(Int(at)) else { return nil }
        return options[Int(at)]
    }

    private func isSelected(_ group: AVMediaSelectionGroup?, _ at: Int32) -> Bool {
        guard let group, let option = option(group, at) else { return false }
        return player.currentItem?.currentMediaSelection.selectedMediaOption(in: group) == option
    }

    // An out-of-range id (Kotlin sends -1 for "off") selects nil, which turns subtitles off.
    private func select(_ group: AVMediaSelectionGroup?, _ trackId: Int32) {
        guard let group else { return }
        player.currentItem?.select(option(group, trackId), in: group)
    }

    /// Selects the option with this display name; nil turns the group off (subtitles).
    private func select(_ group: AVMediaSelectionGroup, named name: String?) {
        player.currentItem?.select(name.flatMap { name in group.options.first { $0.displayName == name } }, in: group)
    }

    private func selectedName(_ group: AVMediaSelectionGroup?) -> String? {
        guard let group else { return nil }
        return player.currentItem?.currentMediaSelection.selectedMediaOption(in: group)?.displayName
    }

    private static func language(_ option: AVMediaSelectionOption?) -> String {
        option?.extendedLanguageTag ?? option?.locale?.identifier ?? ""
    }

    // MARK: mpv-only knobs with no AVPlayer equivalent

    func configureVideoOutput(
        hardwareDecoder: String,
        targetColorspaceHint: Bool,
        toneMapping: String,
        hdrComputePeak: Bool,
        targetPrimaries: String,
        targetTransfer: String,
        extendedDynamicRange: Bool,
        deband: Bool,
        interpolation: Bool,
        brightness: Int32,
        contrast: Int32,
        saturation: Int32,
        gamma: Int32
    ) {}
    func configureAudioOutput(audioOutput: String) {}
    func setEmbeddedPreviewMode(enabled: Bool) {}
    func syncVideoSurfaceLayout(width: Double, height: Double) {}
    func isPictureInPictureSupported() -> Bool { false }
    func startPictureInPicture() {}
    func setExperimentalSinglePrimaryPictureInPictureEnabled(enabled: Bool) {}
    func setKeyboardShortcutsEnabled(enabled: Bool) {}
    func setKeyboardShortcutHandler(handler: ((String) -> Void)?) {}
    func getProperty(name: String) -> String { "" }

    func destroy() {
        ExternalDisplay.shared.detach(self)
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
        remuxer?.stop()
        remuxer = nil
        subtitleDelayReload?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation = nil
        externalObservation = nil
        playingObservation = nil
        let center = nowPlaying.remoteCommandCenter
        [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.changePlaybackPositionCommand]
            .forEach { $0.removeTarget(nil) }
        Self.liveCount -= 1
        guard Self.liveCount == 0 else {
            // Replaced by the next episode's player: keep the audio session, and the app, until it plays.
            Self.holdGap()
            return
        }
        MPVPlayerViewController.audioSessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// A view whose backing layer is the AVPlayerLayer, so it always fills the view.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer } // swiftlint:disable:this force_cast
}
