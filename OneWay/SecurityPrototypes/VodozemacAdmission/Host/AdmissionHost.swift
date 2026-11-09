import SwiftUI
@testable import OneWayVodozemacAdmission

@main struct AdmissionHost:App {
    init() {
        let args=ProcessInfo.processInfo.arguments
        if let i=args.firstIndex(of:"--alt2-phase"),args.count>i+1 {
            let phase=args[i+1]
            DispatchQueue.global().async { Self.scenario(phase) }
        }
    }
    var body:some Scene {WindowGroup{Text("OneWay isolated crypto admission")}}
    static func scenario(_ phase:String) {
        do {
            let args=ProcessInfo.processInfo.arguments
            let run=args.firstIndex(of:"--alt2-run").flatMap{args.count>$0+1 ? args[$0+1]:nil} ?? "first"
            let a=try OneWayE2EEEngine(id:"process-alice-"+run),b=try OneWayE2EEEngine(id:"process-bob-"+run)
            let root=a.store.directory.deletingLastPathComponent()
            let ap=try a.generateBootstrapKeys(),bp=try b.generateBootstrapKeys()
            try a.observe(bp.device,verified:true);try b.observe(ap.device,verified:true)
            if phase.hasPrefix("kill-") {
                let point=String(phase.dropFirst(5))
                let pause: (String)throws->Void = {p in if p==point {
                    let digest=try a.store.read("out:"+phase).map{ProtectedStore.hash($0)} ?? "NONE"
                    let marker=["point":p,"outbox_digest":digest]
                    try JSONEncoder().encode(marker).write(to:root.appendingPathComponent("ready"))
                    DispatchSemaphore(value:0).wait()
                }}
                a.fault=pause;b.fault=pause
                let ds=try a.send(to:[bp],body:Data("process fixture".utf8),id:phase)
                try a.deliver(ds,server:MockDeliveryServer())
                _=try b.receive(ds[0]);try a.acknowledge(phase)
            } else {
                let id=phase.hasPrefix("resume-") ? "kill-"+phase.dropFirst(7) : "setup"
                let d=try a.send(to:[bp],body:Data("process fixture".utf8),id:String(id))[0]
                let result=try b.receive(d)
                let prior=try b.store.read("in:"+a.id+":"+String(id))
                guard result==Data("process fixture".utf8) || (result==nil && prior==Data("process fixture".utf8)) else {throw AdmissionError.authentication}
                if phase=="setup" {let reply=try b.send(to:[ap],body:Data("reply".utf8))[0];_ = try a.receive(reply)}
                let digest=try a.store.read("out:"+String(id)).map{ProtectedStore.hash($0)} ?? "NONE"
                try JSONEncoder().encode(["status":"PASS","outbox_digest":digest]).write(to:root.appendingPathComponent("result"))
            }
        } catch {
            let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("ALT2")
            try? Data("FAIL".utf8).write(to:root.appendingPathComponent("result"))
        }
    }
}
