import Foundation
import CryptoKit

private func ffiEncrypt(_ s:String,_ k:Data,_ p:Data)throws->Operation {try encrypt(state:s,rootKey:k,plaintext:p)}
private func ffiDecrypt(_ s:String,_ k:Data,_ t:UInt32,_ c:Data)throws->Operation {try decrypt(state:s,rootKey:k,messageType:t,ciphertext:c)}
private func ffiIdentity(_ s:String,_ k:Data)throws->Identity {try publicIdentity(state:s,rootKey:k)}

struct PublicDevice: Codable, Equatable {let id:String; let curve:String; let signing:String}
struct PublicBootstrap: Codable {let device:PublicDevice;let oneTime:String;let signature:String;let suite:String}
struct Delivery: Codable, Equatable {let id:String;let sender:PublicDevice;let recipient:String;var suite:String;let conversation:String;let kind:UInt32;var ciphertext:Data}
private struct Payload: Codable {let domain:String;let id:String;let sender:PublicDevice;let recipient:String;let suite:String;let conversation:String;let body:Data}
enum TrustState:String,Codable {case unverified="UNVERIFIED",verified="VERIFIED",changed="SECURITY_CHANGED",revoked="REVOKED"}
private struct Contact:Codable {let device:PublicDevice;var trust:TrustState}

/// Only admission targets compile this API. UniFFI never reaches production call sites.
final class OneWayE2EEEngine {
    let id:String
    let store:ProtectedStore
    private let lock=NSRecursiveLock()
    private let encoder=JSONEncoder()
    var fault: ((String)throws->Void)?
    var suite:String {protocolSuite()}
    init(id:String)throws {
        self.id=id;store=try ProtectedStore(id:id);encoder.outputFormatting=[.sortedKeys]
        if try store.read("account")==nil {try store.transaction{store.put("account",Data(try createAccount(rootKey:store.key).utf8))}}
    }
    private func string(_ k:String)throws->String {guard let d=try store.read(k),let s=String(data:d,encoding:.utf8) else {throw AdmissionError.invalid};return s}
    func publicIdentity()throws->PublicDevice {lock.lock();defer{lock.unlock()};let i=try ffiIdentity(string("account"),store.key);return PublicDevice(id:id,curve:i.curve,signing:i.signing)}
    func generateBootstrapKeys()throws->PublicBootstrap {
        lock.lock();defer{lock.unlock()}
        return try store.transaction{let b=try bootstrap(state:string("account"),rootKey:store.key);store.put("account",Data(b.account.utf8));return PublicBootstrap(device:PublicDevice(id:id,curve:b.curve,signing:b.signing),oneTime:b.oneTime,signature:b.signature,suite:b.suite)}
    }
    /// Explicit local trust input for tests; no server auto-enrollment.
    func observe(_ device:PublicDevice,verified:Bool=false)throws {
        lock.lock();defer{lock.unlock()}
        try store.transaction {
            if let old=try store.read("contact:"+device.id) {
                var c=try JSONDecoder().decode(Contact.self,from:old)
                if c.device != device {c.trust = .changed;store.put("contact:"+device.id,try encoder.encode(c));return}
                if c.trust == .revoked || c.trust == .changed {return}
            }
            store.put("contact:"+device.id,try encoder.encode(Contact(device:device,trust:verified ? .verified:.unverified)))
        }
    }
    func trust(_ device:String)throws->TrustState {guard let d=try store.read("contact:"+device) else {throw AdmissionError.invalid};return try JSONDecoder().decode(Contact.self,from:d).trust}
    func revoke(_ device:String)throws {
        lock.lock();defer{lock.unlock()};try store.transaction{guard let d=try store.read("contact:"+device) else {throw AdmissionError.invalid};var c=try JSONDecoder().decode(Contact.self,from:d);c.trust = .revoked;store.put("contact:"+device,try encoder.encode(c))}
    }
    private func check(_ device:PublicDevice)throws {
        guard let d=try store.read("contact:"+device.id) else {throw AdmissionError.changedIdentity}
        let c=try JSONDecoder().decode(Contact.self,from:d)
        guard c.trust != .revoked else {throw AdmissionError.revoked}
        guard c.trust != .changed,c.device==device else {throw AdmissionError.changedIdentity}
    }
    func verificationFingerprint(_ peer:PublicDevice)throws->String {
        let identities=try [publicIdentity(),peer].sorted{$0.id<$1.id}
        let data=try encoder.encode(identities)
        return Data(SHA256.hash(data:Data(("OneWay.ALT2.Verification.1|"+suite).utf8)+data)).map{String(format:"%02x",$0)}.joined()
    }
    func send(to peers:[PublicBootstrap],body:Data,id messageID:String=UUID().uuidString,conversation:String="ALT2-DM")throws->[Delivery] {
        lock.lock();defer{lock.unlock()}
        if let stored=try store.read("out:"+messageID) {return try JSONDecoder().decode([Delivery].self,from:stored)}
        try fault?("beforeEncryption")
        return try store.transaction({
            var deliveries:[Delivery]=[];let me=try publicIdentity()
            for peer in peers {
                if try trust(peer.device.id) == .revoked {continue}
                try check(peer.device);guard peer.suite==suite else {throw AdmissionError.suite}
                let payload=try encoder.encode(Payload(domain:"OW.ALT2.Payload.1",id:messageID,sender:me,recipient:peer.device.id,suite:suite,conversation:conversation,body:body))
                let op:Operation
                if let existing=try store.read("session:"+peer.device.id),let s=String(data:existing,encoding:.utf8) {op=try ffiEncrypt(s,store.key,payload)}
                else {op=try outbound(state:string("account"),rootKey:store.key,curve:peer.device.curve,signing:peer.device.signing,oneTime:peer.oneTime,signature:peer.signature,plaintext:payload)}
                store.put("session:"+peer.device.id,Data(op.session.utf8))
                deliveries.append(Delivery(id:messageID,sender:me,recipient:peer.device.id,suite:suite,conversation:conversation,kind:op.messageType,ciphertext:op.ciphertext))
            }
            try fault?("afterEncryption");store.put("out:"+messageID,try encoder.encode(deliveries));return deliveries
        },beforeCommit:{try self.fault?("beforeStateCommit")},afterCommit:{try self.fault?("afterStateCommit")})
    }
    func deliver(_ deliveries:[Delivery],server:MockDeliveryServer)throws {
        try fault?("beforeNetworkSend");server.accept(deliveries);try fault?("afterNetworkSend")
    }
    func receive(_ d:Delivery)throws->Data? {
        lock.lock();defer{lock.unlock()}
        guard d.recipient==id,d.suite==suite else {throw AdmissionError.suite};try check(d.sender)
        let replay="in:"+d.sender.id+":"+d.id
        if try store.read(replay) != nil {return nil}
        return try store.transaction({
            try fault?("duringDecrypt");let op:Operation
            if let data=try store.read("session:"+d.sender.id),let s=String(data:data,encoding:.utf8) {op=try ffiDecrypt(s,store.key,d.kind,d.ciphertext)}
            else {guard d.kind==0 else {throw AdmissionError.invalid};op=try inbound(state:string("account"),rootKey:store.key,senderCurve:d.sender.curve,ciphertext:d.ciphertext);store.put("account",Data(op.account.utf8))}
            try fault?("afterDecrypt")
            let p=try JSONDecoder().decode(Payload.self,from:op.plaintext)
            guard try encoder.encode(p)==op.plaintext,p.domain=="OW.ALT2.Payload.1",p.id==d.id,p.sender==d.sender,p.recipient==id,p.suite==suite,p.conversation==d.conversation else {throw AdmissionError.authentication}
            store.put("session:"+d.sender.id,Data(op.session.utf8));store.put(replay,p.body);return p.body
        },beforeCommit:{try self.fault?("beforeInboundCommit")},afterCommit:{try self.fault?("afterInboundCommit")})
    }
    func acknowledge(_ messageID:String)throws {
        lock.lock();defer{lock.unlock()};try fault?("beforeAcknowledgement")
        try store.transaction {guard try store.read("out:"+messageID) != nil else {throw AdmissionError.invalid};store.put("ack:"+messageID,Data("ACKNOWLEDGED".utf8))}
    }
    func serializeState()throws->Data {try string("account").data(using:.utf8)!}
}

/// DTOs deliberately have no field for secret states/root keys or plaintext.
final class MockDeliveryServer {
    var publicBundles:[PublicBootstrap]=[]
    private(set) var deliveries:[Delivery]=[]
    func accept(_ messages:[Delivery]) {for m in messages where !deliveries.contains(where:{$0.id==m.id && $0.recipient==m.recipient}) {deliveries.append(m)}}
}
