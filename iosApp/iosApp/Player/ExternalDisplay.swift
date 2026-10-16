import AVFoundation
import UIKit
import ComposeApp

/// iOS hands the app its own scene for a connected display (USB-C/HDMI dock, AirPlay). While no window is shown
/// in it the display mirrors the iPad; while the player is open it shows the video full screen instead, at the
/// display's own resolution and aspect ratio. Owning a window there is also what puts the app in AVPlayer's
/// "external screen mode", in which usesExternalPlaybackWhileExternalScreenIsActive moves playback to the
/// display itself so it keeps going with the iPad locked.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        ExternalDisplay.shared.sceneConnected(windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        ExternalDisplay.shared.sceneDisconnected(scene)
    }
}

final class ExternalDisplay {
    static let shared = ExternalDisplay()

    // The player that owns the display. A new player attaches before the previous one is torn down, so only
    // the current owner may hand the display back.
    private weak var owner: AnyObject?
    private var onChange: (() -> Void)?
    private var scene: UIWindowScene?
    private var window: UIWindow?
    private let playerView = PlayerLayerView()

    var isConnected: Bool { scene != nil }

    fileprivate func sceneConnected(_ scene: UIWindowScene) {
        self.scene = scene
        InAppLogBridge.shared.info(tag: "Player/External", message: "display connected \(Int(scene.screen.bounds.width))x\(Int(scene.screen.bounds.height))")
        if playerView.playerLayer.player != nil { showWindow() }
        onChange?()
    }

    fileprivate func sceneDisconnected(_ scene: UIScene) {
        guard scene === self.scene else { return }
        hideWindow()
        self.scene = nil
        InAppLogBridge.shared.info(tag: "Player/External", message: "display disconnected")
        onChange?()
    }

    /// `onChange` runs on the main queue whenever a display connects or disconnects.
    func attach(_ owner: AnyObject, onChange: @escaping () -> Void) {
        self.owner = owner
        self.onChange = onChange
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
