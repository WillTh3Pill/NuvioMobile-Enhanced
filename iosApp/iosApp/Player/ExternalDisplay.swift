import AVFoundation
import UIKit
import ComposeApp

/// iOS connects a scene for a connected display (USB-C/HDMI dock, AirPlay) on its own; while the app shows no
/// window in it the display mirrors the iPad. While the player is open it shows the video full screen there
/// instead, at the display's own resolution and aspect ratio. Owning a window there is also what puts the app in
/// AVPlayer's "external screen mode", in which usesExternalPlaybackWhileExternalScreenIsActive moves playback
/// to the display itself so it keeps going with the iPad locked.
/// The scene is picked up from the connected scenes rather than configured in the app delegate, which would
/// interfere with SwiftUI's own scene setup.
final class ExternalDisplay {
    static let shared = ExternalDisplay()

    // The player that owns the display. A new player attaches before the previous one is torn down, so only
    // the current owner may hand the display back.
    private weak var owner: AnyObject?
    private var onChange: (() -> Void)?
    private var scene: UIWindowScene?
    private var window: UIWindow?
    private let playerView = PlayerLayerView()
    private var observers: [NSObjectProtocol] = []

    var isConnected: Bool { scene != nil }

    private init() {
        let center = NotificationCenter.default
        for name in [UIScene.willConnectNotification, UIScene.didDisconnectNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // After the scene's own setup has run.
                DispatchQueue.main.async { self?.refresh() }
            })
        }
        refresh()
    }

    /// `onChange` runs on the main queue whenever a display connects or disconnects.
    func attach(_ owner: AnyObject, onChange: @escaping () -> Void) {
        self.owner = owner
        self.onChange = onChange
        refresh()
    }

    func detach(_ owner: AnyObject) {
        guard owner === self.owner else { return }
        self.owner = nil
        onChange = nil
        present(nil)
    }

    /// Shows `player` full screen on the connected display; nil hands the display back to mirroring.
    func present(_ player: AVPlayer?) {
        playerView.playerLayer.player = player
        if player != nil { showWindow() } else { hideWindow() }
    }

    private func refresh() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let external = scenes.first { $0.session.role == .windowExternalDisplayNonInteractive }
        let description = external.map { "display scene \(Int($0.screen.bounds.width))x\(Int($0.screen.bounds.height))" }
            ?? "no display scene"
        InAppLogBridge.shared.info(
            tag: "Player/External",
            message: "\(description); scenes=\(scenes.map { "\($0.session.role.rawValue):\($0.activationState.rawValue)" }) screens=\(UIScreen.screens.count)"
        )
        guard external !== scene else { return }
        hideWindow()
        scene = external
        if playerView.playerLayer.player != nil { showWindow() }
        onChange?()
    }

    private func showWindow() {
        guard let scene, window == nil else { return }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        playerView.backgroundColor = .black
        controller.view = playerView
        window.rootViewController = controller
        window.isHidden = false
        self.window = window
    }

    private func hideWindow() {
        window?.isHidden = true
        window = nil
    }
}
