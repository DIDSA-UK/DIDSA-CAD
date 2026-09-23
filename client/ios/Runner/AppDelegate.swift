import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  // Held strongly for the app's lifetime - IosStoragePlugin.register only
  // captures `self` weakly inside its MethodChannel handler, so nothing
  // else keeps the plugin instance alive otherwise (see that class's own
  // doc comment).
  private var storagePlugin: IosStoragePlugin?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let plugin = IosStoragePlugin(viewController: controller)
      plugin.register(with: controller.binaryMessenger)
      storagePlugin = plugin
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
