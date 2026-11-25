import Foundation
@_silgen_name("BWEngineProcessStarted") private func processStarted(_ pid:Int32)
@_silgen_name("BWEngineProcessExited") private func processExited(_ pid:Int32,_ code:Int32)
@_silgen_name("BWPrepareAudioOutput") private func prepareAudioOutput()->Bool
@_silgen_name("BWStopAudioOutput") private func stopAudioOutput()

@objc private protocol EngineExtensionFactory {
    @objc(extensionWithIdentifier:error:) func extensionWithIdentifier(_ identifier:String) throws -> AnyObject
}
@objc private protocol EngineExtensionRequest {
    @objc(beginExtensionRequestWithInputItems:completion:) func begin(_ items:[Any],completion:@escaping(NSUUID?)->Void)
    @objc(pidForRequestIdentifier:) func pid(_ identifier:NSUUID)->Int32
    @objc(setRequestCompletionBlock:) func setCompletion(_ block:@escaping(NSUUID?,[Any]?)->Void)
    @objc(setRequestCancellationBlock:) func setCancellation(_ block:@escaping(NSUUID?,NSError?)->Void)
    @objc(setRequestInterruptionBlock:) func setInterruption(_ block:@escaping(NSUUID?)->Void)
}

// Uses the same own-extension lifecycle already verified by our JIT helper.
// The engine runs in its own process, preserving its native global state.
@objc(NativeEngineCoordinator)
@MainActor final class NativeEngineCoordinator:NSObject {
    private static var active:AnyObject?
    private static var currentPID:Int32=0
    private static func record(_ value:[String:Any]) {
        let file=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("native-engine-extension.json")
        try? JSONSerialization.data(withJSONObject:value,options:.prettyPrinted).write(to:file,options:.atomic)
    }
    @objc(startWithArguments:environment:completion:)
    static func start(arguments:[String],environment:[String:String],completion:@escaping(Int32)->Void) {
        guard active==nil else {completion(0);return}
        guard prepareAudioOutput() else {record(["phase":"failed","error":"Foreground audio output initialization failed"]);completion(0);return}
        let url=Bundle.main.builtInPlugInsURL?.appendingPathComponent("BitwigEngine.appex")
        guard let url,let identifier=Bundle(url:url)?.bundleIdentifier else {
            record(["phase":"failed","error":"Embedded engine extension is missing"]);completion(0);return
        }
        if NSClassFromString("NSExtension")==nil {dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation",RTLD_NOW)}
        guard let cls=NSClassFromString("NSExtension") else {completion(0);return}
        do {
            let found=try unsafeBitCast(cls as AnyObject,to:EngineExtensionFactory.self).extensionWithIdentifier(identifier)
            active=found
            var delivered=false
            func started(_ pid:Int32) {if !delivered {delivered=true;completion(pid)}}
            let request=unsafeBitCast(found,to:EngineExtensionRequest.self)
            request.setCompletion {_,items in DispatchQueue.main.async {
                guard active === found else{return}
                stopAudioOutput()
                var result=((items?.first as? NSExtensionItem)?.userInfo?["bitwig.engine.result"] as? [String:Any]) ?? ["error":"Engine returned no result"]
                if currentPID==0,let pid=result["pid"] as? Int32 {currentPID=pid;processStarted(pid)}
                result["phase"]="exited";result["pid"]=currentPID
                processExited(currentPID,(result["exit_code"] as? Int32) ?? -1);started(currentPID)
                record(result);active=nil;currentPID=0
            }}
            request.setCancellation {_,error in DispatchQueue.main.async {
                guard active === found else{return}
                stopAudioOutput()
                processExited(currentPID,-1);started(0)
                record(["phase":"failed","error":error?.localizedDescription ?? "Engine cancelled","pid":currentPID]);active=nil;currentPID=0
            }}
            request.setInterruption {_ in DispatchQueue.main.async {
                guard active === found else{return}
                stopAudioOutput()
                processExited(currentPID,-1);started(0)
                record(["phase":"interrupted","pid":currentPID]);active=nil;currentPID=0
            }}
            let item=NSExtensionItem();item.userInfo=["bitwig.engine.arguments":arguments,"bitwig.engine.environment":environment,
                "bitwig.engine.profile":ProcessInfo.processInfo.arguments.contains("--native-dsp-profile")]
            record(["phase":"starting","arguments":arguments])
            request.begin([item]) {identifier in DispatchQueue.main.async {
                guard active === found else{started(0);return}
                guard let identifier else {active=nil;started(0);return}
                let pid=request.pid(identifier);currentPID=pid
                processStarted(pid)
                record(["phase":"preparingJIT","pid":pid,"arguments":arguments])
                // Return the real process now; its helper serves future compilations.
                started(pid)
                NativeJITCoordinator.prepareEngine(pid:pid) { success in
                    guard active === found else {started(0);return}
                    if success {record(["phase":"JIT service finished","pid":pid,"arguments":arguments])}
                    else {record(["phase":"failed","pid":pid,"error":"Engine JIT preparation failed"]);kill(pid,SIGTERM);started(0)}
                }
            }}
        } catch {active=nil;record(["phase":"failed","error":error.localizedDescription]);completion(0)}
    }
}
