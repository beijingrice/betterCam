//
//  betterCamApp.swift
//  betterCam
//
//  Created by Rice on 2026/1/22.
//

import SwiftUI
import UIKit

@main
final class BetterCamAppDelegate: UIResponder, UIApplicationDelegate {
    let storeManager = StoreManager()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        ShutterManager.cleanupOldData()
        ShutterManager.resetSession()
        NotificationCenter.default.addObserver(self, selector: #selector(restoreCameraScene(_:)),
                                               name: UIScene.willEnterForegroundNotification, object: nil)
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Camera", sessionRole: session.role)
        configuration.delegateClass = CameraSceneDelegate.self
        return configuration
    }

    // UIKit can reconnect a saved WindowGroup session using its previous delegate.
    @objc private func restoreCameraScene(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene,
              scene.session.role == .windowApplication,
              !(scene.delegate is CameraSceneDelegate) else { return }
        let delegate = CameraSceneDelegate()
        scene.delegate = delegate
        delegate.installWindow(in: scene, storeManager: storeManager)
    }
}

final class CameraSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var camera: Camera?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene,
              let app = UIApplication.shared.delegate as? BetterCamAppDelegate else { return }
        installWindow(in: scene, storeManager: app.storeManager)
    }

    fileprivate func installWindow(in scene: UIWindowScene, storeManager: StoreManager) {
        guard window == nil else { return }
        let camera = Camera()
        self.camera = camera
        let window = UIWindow(windowScene: scene)
        window.rootViewController = CameraHostingController(
            rootView: ContentView(camera: camera).environmentObject(storeManager)
        )
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        if #available(iOS 26.0, *) {
            window?.rootViewController?.setNeedsUpdateOfPrefersInterfaceOrientationLocked()
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        camera?.parameterManager.saveExposureParameters()
    }
}

private final class CameraHostingController<Content: View>: UIHostingController<Content> {
    @available(iOS 26.0, *)
    override var childForInterfaceOrientationLock: UIViewController? { nil }

    @available(iOS 26.0, *)
    override var prefersInterfaceOrientationLocked: Bool { true }
}
