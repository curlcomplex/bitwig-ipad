import Foundation

@_silgen_name("BWPluginMetadataProcessStarted") private func metadataStarted(_ pid: Int32)
@_silgen_name("BWPluginMetadataProcessExited") private func metadataExited(_ pid: Int32, _ code: Int32)

@MainActor
@objc(NativePluginMetadataCoordinator)
final class NativePluginMetadataCoordinator: NSObject {
    private final class Request {
        let arguments: [String]
        let completion: (Int32) -> Void

        init(arguments: [String], completion: @escaping (Int32) -> Void) {
            self.arguments = arguments
            self.completion = completion
        }
    }

    private static var pending: [Request] = []
    private static var active: Request?
    private static var activeExtension: AnyObject?

    @objc(startWithArguments:completion:)
    static func start(arguments: [String], completion: @escaping (Int32) -> Void) {
        pending.append(Request(arguments: arguments, completion: completion))
        startNext()
    }

    private static func startNext() {
        guard active == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        active = job
        var pid: Int32 = 0
        var reported = false

        // Extension objects can be reused. Only this request can finish its
        // launch and unlock the next original metadata request.
        func finish(_ code: Int32) {
            guard active === job else { return }
            active = nil
            activeExtension = nil
            if pid > 0 { metadataExited(pid, code) }
            if !reported {
                reported = true
                job.completion(0)
            }
            DispatchQueue.main.async { startNext() }
        }

        guard let extensionURL = Bundle.main.builtInPlugInsURL?.appendingPathComponent("BitwigPluginMetadata.appex"),
              let identifier = Bundle(url: extensionURL)?.bundleIdentifier else {
            finish(1)
            return
        }
        if NSClassFromString("NSExtension") == nil {
            dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW)
        }
        guard let cls = NSClassFromString("NSExtension") else {
            finish(1)
            return
        }
        do {
            let found = try unsafeBitCast(cls as AnyObject, to: EngineExtensionFactory.self)
                .extensionWithIdentifier(identifier)
            activeExtension = found
            let request = unsafeBitCast(found, to: EngineExtensionRequest.self)
            request.setCompletion { _, items in
                DispatchQueue.main.async {
                    let code = ((items?.first as? NSExtensionItem)?.userInfo?["exit_code"] as? Int32) ?? 1
                    finish(code)
                }
            }
            request.setCancellation { _, _ in DispatchQueue.main.async { finish(1) } }
            request.setInterruption { _ in DispatchQueue.main.async { finish(1) } }
            let item = NSExtensionItem()
            item.userInfo = ["arguments": job.arguments]
            request.begin([item]) { token in
                DispatchQueue.main.async {
                    guard active === job, !reported else { return }
                    guard let token else { finish(1); return }
                    pid = request.pid(token)
                    guard pid > 0 else { finish(1); return }
                    metadataStarted(pid)
                    reported = true
                    job.completion(pid)
                }
            }
        } catch {
            finish(1)
        }
    }
}
