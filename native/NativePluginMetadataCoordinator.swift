import Foundation
import Darwin

@_silgen_name("BWPluginMetadataProcessStarted") private func metadataStarted(_ pid: Int32)
@_silgen_name("BWPluginMetadataProcessExited") private func metadataExited(_ pid: Int32, _ code: Int32)

private func watchMetadataExit(_ pid: Int32, completed: @escaping (Int32) -> Void) -> DispatchSourceRead? {
    let descriptor = kqueue()
    guard descriptor >= 0 else { return nil }

    var change = kevent()
    change.ident = UInt(pid)
    change.filter = Int16(EVFILT_PROC)
    change.flags = UInt16(EV_ADD | EV_ONESHOT)
    change.fflags = NOTE_EXIT | UInt32(NOTE_EXITSTATUS)
    var registered = kevent(descriptor, &change, 1, nil, 0, nil)
    if registered < 0 && (errno == EPERM || errno == EACCES) {
        change.fflags = NOTE_EXIT
        registered = kevent(descriptor, &change, 1, nil, 0, nil)
    }
    // The PID is the one just supplied by the extension's actual begin callback.
    if registered < 0 {
        let failure = errno
        close(descriptor)
        if failure == ESRCH { DispatchQueue.main.async { completed(1) } }
        return nil
    }

    let observer = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
    observer.setCancelHandler { close(descriptor) }
    observer.setEventHandler {
        var event = kevent()
        var nonblocking = timespec()
        guard kevent(descriptor, nil, 0, &event, 1, &nonblocking) == 1,
              event.ident == UInt(pid), event.fflags & NOTE_EXIT != 0 else { return }

        let code: Int32
        if event.fflags & UInt32(NOTE_EXITSTATUS) != 0 {
            let status = UInt32(truncatingIfNeeded: event.data)
            let signal = status & 0x7f
            code = Int32(signal == 0 ? (status >> 8) & 0xff : 128 + signal)
        } else {
            code = 1
        }
        // Give any native reply already queued on the main actor first use.
        DispatchQueue.main.async { completed(code) }
    }
    observer.activate()
    return observer
}

@MainActor
@objc(NativePluginMetadataCoordinator)
final class NativePluginMetadataCoordinator: NSObject {
    private final class Request {
        var exitObserver: DispatchSourceRead?
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
            job.exitObserver?.cancel()
            job.exitObserver = nil
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
                    job.exitObserver = watchMetadataExit(pid) { code in
                        finish(code)
                    }
                    job.completion(pid)
                }
            }
        } catch {
            finish(1)
        }
    }
}
