import Foundation

@_silgen_name("BWPluginMetadataProcessStarted") private func metadataStarted(_ pid: Int32)
@_silgen_name("BWPluginMetadataProcessExited") private func metadataExited(_ pid: Int32, _ code: Int32)

@MainActor
@objc(NativePluginMetadataCoordinator)
final class NativePluginMetadataCoordinator: NSObject {
    private static var active: AnyObject?

    @objc(startWithArguments:completion:)
    static func start(arguments: [String], completion: @escaping (Int32) -> Void) {
        guard active == nil,
              let extensionURL = Bundle.main.builtInPlugInsURL?.appendingPathComponent("BitwigPluginMetadata.appex"),
              let identifier = Bundle(url: extensionURL)?.bundleIdentifier else {
            completion(0)
            return
        }
        if NSClassFromString("NSExtension") == nil {
            dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW)
        }
        guard let cls = NSClassFromString("NSExtension") else { completion(0); return }
        do {
            let found = try unsafeBitCast(cls as AnyObject, to: EngineExtensionFactory.self)
                .extensionWithIdentifier(identifier)
            active = found
            let request = unsafeBitCast(found, to: EngineExtensionRequest.self)
            var pid: Int32 = 0
            var reported = false
            func finish(_ code: Int32) {
                guard active === found else { return }
                active = nil
                if pid > 0 { metadataExited(pid, code) }
                if !reported { reported = true; completion(0) }
            }
            request.setCompletion { _, items in
                DispatchQueue.main.async {
                    let code = ((items?.first as? NSExtensionItem)?.userInfo?["exit_code"] as? Int32) ?? 1
                    finish(code)
                }
            }
            request.setCancellation { _, _ in DispatchQueue.main.async { finish(1) } }
            request.setInterruption { _ in DispatchQueue.main.async { finish(1) } }
            let item = NSExtensionItem()
            item.userInfo = ["arguments": arguments]
            request.begin([item]) { token in
                DispatchQueue.main.async {
                    guard active === found, !reported else { return }
                    guard let token else { finish(1); return }
                    pid = request.pid(token)
                    guard pid > 0 else { finish(1); return }
                    metadataStarted(pid)
                    reported = true
                    completion(pid)
                }
            }
        } catch {
            active = nil
            completion(0)
        }
    }
}
