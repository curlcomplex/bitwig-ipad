import Foundation

@_silgen_name("csops") private func csops(_ pid: Int32, _ operation: Int32,
                                         _ status: UnsafeMutableRawPointer?, _ size: Int) -> Int32

// Logging adapter for the embedded StikJIT extension launcher. No VM is linked.
enum BitwigLog {
    static func log(_ category: String, _ message: String) { NSLog("[%@] %@", category, message) }
}

@objc(NativeJITCoordinator)
@MainActor final class NativeJITCoordinator: NSObject {
    private static var timer: Timer?
    static func prepareEngine(pid:Int32,completion:@escaping(Bool)->Void) {
        let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        guard let pairing=try? Data(contentsOf:documents.appendingPathComponent("pairing.plist")),
              let url=Bundle.main.url(forResource:"native-engine-jit",withExtension:"js"),
              let script=try? Data(contentsOf:url) else {completion(false);return}
        let request=BitwigJITRequest.enable(targetPID:pid,pairingData:pairing,scriptBase64:script.base64EncodedString())
        try? JSONSerialization.data(withJSONObject:["pid":pid,"phase":"starting engine JIT service"],options:.prettyPrinted).write(to:documents.appendingPathComponent("native-engine-jit.json"),options:.atomic)
        BitwigBuiltInJIT.send(request,completion:{ result in
            let success:Bool;let message:String
            switch result {
            case .success(let response):success=response.success;message=response.message
            case .failure(let error):success=false;message=error.localizedDescription
            }
            let report:[String:Any]=["pid":pid,"phase":success ? "finished" : "failed","message":message]
            try? JSONSerialization.data(withJSONObject:report,options:.prettyPrinted).write(to:documents.appendingPathComponent("native-engine-jit.json"),options:.atomic)
            completion(success)
        })
    }

    @objc static func start(completion: @escaping (Bool) -> Void) {
#if EMBEDDED_TUNNEL
        NativeTunnelCoordinator.ensureReady(allowConfiguration: false) { result in
            switch result {
            case .success: prepareHelper(completion: completion)
            case .failure(let error):
                let nsError = error as NSError
                status(nsError.domain == "BitwigLocalTunnel" && nsError.code == NativeTunnelCoordinator.consentCode ? "needsTunnelConsent" : "failed", error.localizedDescription)
                completion(false)
            }
        }
#else
        prepareHelper(completion: completion)
#endif
    }

    @objc static func authorizeTunnel(completion: @escaping (Bool) -> Void) {
#if EMBEDDED_TUNNEL
        status("preparing", "Waiting for permission to configure Bitwig’s on-device developer tunnel.")
        NativeTunnelCoordinator.ensureReady(allowConfiguration: true) { result in
            switch result {
            case .success: completion(true)
            case .failure(let error): status("needsTunnelConsent", error.localizedDescription); completion(false)
            }
        }
#else
        completion(false)
#endif
    }

    private static func status(_ phase: String, _ message: String) {
        let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let json:[String:Any]=["phase":phase,"message":message,"pid":getpid()]
        try? JSONSerialization.data(withJSONObject:json,options:.prettyPrinted)
            .write(to:documents.appendingPathComponent("native-jit.json"),options:.atomic)
        NotificationCenter.default.post(name:NSNotification.Name("NativeHostStatus"),object:message,userInfo:["phase":phase])
    }

    private static func prepareHelper(recoverTransport: Bool = true, completion: @escaping (Bool) -> Void) {
        let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        guard let pairing=try? Data(contentsOf:documents.appendingPathComponent("pairing.plist")) else {
            status("blocked","A device pairing record is required in this app's Documents/pairing.plist.")
            completion(false);return
        }
        guard let scriptURL=Bundle.main.url(forResource:"native-java-jit",withExtension:"js"),
              let script=try? Data(contentsOf:scriptURL) else {
            status("failed","The embedded Java JIT script is missing.");completion(false);return
        }
        var delivered=false
        func finish(_ success: Bool) {
            guard !delivered else{return};delivered=true;timer?.invalidate();timer=nil;completion(success)
        }
#if EMBEDDED_TUNNEL
        status("preparing","Preparing Java execution through Bitwig’s embedded helper and local developer tunnel.")
#else
        status("preparing","Preparing Java execution through the app's embedded JIT helper. LocalDevVPN must be active.")
#endif
        let request=BitwigJITRequest.enable(targetPID:getpid(),pairingData:pairing,scriptBase64:script.base64EncodedString())
        BitwigBuiltInJIT.send(request,started:{
            let deadline=Date().addingTimeInterval(300)
            timer=Timer.scheduledTimer(withTimeInterval:0.2,repeats:true){_ in
                MainActor.assumeIsolated {
                    var flags:UInt32=0
                    if csops(getpid(),0,&flags,MemoryLayout<UInt32>.size)==0 && flags & 0x10000000 != 0 {
                        status("attached","Embedded helper attached; creating Java's executable code cache.");finish(true)
                    } else if Date()>deadline {
                        status("failed","Embedded JIT preparation timed out. Check the local developer tunnel and the pairing record.");finish(false)
                    }
                }
            }
        },completion:{result in
            switch result {
            case .success(let response):
#if EMBEDDED_TUNNEL
                if !response.success && !delivered && recoverTransport && response.message.contains("Timed out connecting to 10.7.0.1") {
                    delivered=true;timer?.invalidate();timer=nil
                    status("preparing","Reconnecting the local developer tunnel after a connection timeout.")
                    NativeTunnelCoordinator.reconnect { result in
                        switch result {
                        case .success: prepareHelper(recoverTransport:false,completion:completion)
                        case .failure(let error):status("failed",error.localizedDescription);completion(false)
                        }
                    }
                    return
                }
#endif
                status(response.success ? "detached" : "failed",response.message)
                if !response.success{finish(false)}
            case .failure(let error):status("failed",error.localizedDescription);finish(false)
            }
        })
    }
}
