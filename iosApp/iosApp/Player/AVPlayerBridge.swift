import AVFoundation
import AVKit
import MediaPlayer
import UIKit
import ComposeApp

/// Stream player. AVPlayer's external playback hands video straight to a connected display (USB-C/HDMI
/// dock, AirPlay), so the TV gets full-screen video at its own aspect ratio and keeps playing with the
/// iPad locked, which mpv can't do because it renders with the app's GPU access that iOS revokes in the
/// background. Containers AVPlayer can't open (MKV, …) are repackaged losslessly by HLSRemuxer.
final class AVPlayerBridgeImpl: NSObject, NuvioPlayerBridge {

    private let player = AVPlayer()
    private lazy var playerVC: AVPlayerViewController = {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = false // Nuvio's Compose controls draw on top.
        vc.allowsPictureInPicturePlayback = false
        vc.view.backgroundColor = .black
        return vc
    }()
    private var remuxer: HLSRemuxer?
    private var lastLoad: (url: String, headersJson: String?)?
    private var wantsPlayback = false
    private var unsupportedReason = ""
    private var isEnded = false
    private var endObserver: NSObjectProtocol?
    private var metadata: [AVMetadataItem] = []
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []

    private static let nativeExtensions: Set<String> = ["mp4", "m4v", "mov", "m3u8"]

    override init() {
        super.init()
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        // Lock-screen controls for when the iPad is off. play/pause are idempotent, so this is safe
        // even if AVKit registers its own handlers too.
        let center = MPRemoteCommandCenter.shared()
        remoteCommandTargets = [
            (center.playCommand, center.playCommand.addTarget { [weak self] _ in self?.play(); return .success }),
            (center.pauseCommand, center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }),
        ]
    }

    func createPlayerViewController() -> UIViewController { playerVC }

    func loadFile(url: String) {
        loadFileWithAudio(videoUrl: url, audioUrl: nil, headersJson: nil, subtitlesJson: nil)
    }

    // External subtitle files aren't wired into AVPlayer yet; embedded/HLS tracks show.
    func loadFileWithAudio(videoUrl: String, audioUrl: String?, headersJson: String?, subtitlesJson: String?) {
        remuxer?.stop()
        remuxer = nil
        player.replaceCurrentItem(with: nil)
        isEnded = false
        audioGroup = nil
        subtitleGroup = nil
        lastLoad = (videoUrl, headersJson)
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

        if Self.nativeExtensions.contains(url.pathExtension.lowercased()) {
            playItem(url, headers: headers)
            return
        }
        let remuxer = HLSRemuxer(url: videoUrl, headers: headers)
        self.remuxer = remuxer
        remuxer.start { [weak self] result in
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
        item.externalMetadata = metadata

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in self?.isEnded = true }
        player.replaceCurrentItem(with: item)
        if wantsPlayback { player.play() }

        Task { @MainActor [weak self] in
            let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
            let subtitles = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self, self.player.currentItem === item else { return }
            self.audioGroup = audio
            self.subtitleGroup = subtitles
        }
    }

    func play() {
        wantsPlayback = true
        // Same serial queue as mpv, so a teardown deactivation can't land after this activation.
        MPVPlayerViewController.audioSessionQueue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
        }
        player.play() // starts at player.defaultRate
    }

    func pause() {
        wantsPlayback = false
        player.pause()
    }

    func seekTo(positionMs: Int64) {
        isEnded = false
        player.seek(to: CMTime(value: positionMs, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seekBy(offsetMs: Int64) { seekTo(positionMs: max(0, getPositionMs() + offsetMs)) }

    func retry() {
        guard let lastLoad else { return }
        loadFileWithAudio(videoUrl: lastLoad.url, audioUrl: nil, headersJson: lastLoad.headersJson, subtitlesJson: nil)
    }

    func setPlaybackSpeed(speed: Float) {
        player.defaultRate = speed
        if player.rate != 0 { player.rate = speed }
    }

    func getPlaybackSpeed() -> Float { player.defaultRate }

    // ponytail: AVPlayer volume caps at 1.0, so mpv's 200% boost is unavailable.
    func getVolume() -> Float { player.volume }
    func setVolume(volume: Float) { player.volume = min(max(volume, 0), 1) }
    func setMuted(muted: Bool) { player.isMuted = muted }

    // Only affects the iPad-side layer; the external display always gets the full frame.
    func setResizeMode(mode: Int32) { playerVC.videoGravity = mode == 0 ? .resizeAspect : .resizeAspectFill }

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
        player.currentItem?.externalMetadata = metadata
    }

    func clearNowPlayingInfo() {
        metadata = []
        player.currentItem?.externalMetadata = []
    }

    // MARK: State (polled from Kotlin every 250ms)

    func getIsLoading() -> Bool {
        // Like mpv, a source that failed to open still counts as loading, so nothing seeks into it.
        guard let item = player.currentItem, item.status != .failed else { return true }
        return item.status == .unknown || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    func getIsPlaying() -> Bool { player.timeControlStatus == .playing }
    func getIsEnded() -> Bool { isEnded }
    func getDurationMs() -> Int64 { Self.ms(player.currentItem?.duration) }
    func getPositionMs() -> Int64 { Self.ms(player.currentTime()) }

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
        remuxer == nil ? #"{"engine":"avplayer"}"# : #"{"engine":"avplayer (lossless MKV repackaging)"}"#
    }

    private static func ms(_ time: CMTime?) -> Int64 {
        guard let seconds = time?.seconds, seconds.isFinite, seconds > 0 else { return 0 }
        return Int64(seconds * 1000)
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
    func setSubtitleUrl(url: String) {}
    func setSubtitleDelayMs(delayMs: Int32) {}
    func applySubtitleStyle(
        textColor: String,
        backgroundColor: String,
        outlineColor: String,
        outlineSize: Float,
        bold: Bool,
        fontSize: Float,
        subPos: Int32,
        stripSdh: Bool
    ) {}
    func setEmbeddedPreviewMode(enabled: Bool) {}
    func syncVideoSurfaceLayout(width: Double, height: Double) {}
    func isPictureInPictureSupported() -> Bool { false }
    func startPictureInPicture() {}
    func setExperimentalSinglePrimaryPictureInPictureEnabled(enabled: Bool) {}
    func setKeyboardShortcutsEnabled(enabled: Bool) {}
    func setKeyboardShortcutHandler(handler: ((String) -> Void)?) {}
    func getProperty(name: String) -> String { "" }

    func destroy() {
        remuxer?.stop()
        remuxer = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        remoteCommandTargets.forEach { command, target in command.removeTarget(target) }
        remoteCommandTargets = []
        MPVPlayerViewController.audioSessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
