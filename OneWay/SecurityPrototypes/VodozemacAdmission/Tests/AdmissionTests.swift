import XCTest
import CryptoKit
@testable import OneWayVodozemacAdmission

final class AdmissionTests:XCTestCase {
    func pair()throws->(OneWayE2EEEngine,OneWayE2EEEngine,PublicBootstrap,PublicBootstrap) {
        let a=try OneWayE2EEEngine(id:UUID().uuidString),b=try OneWayE2EEEngine(id:UUID().uuidString)
        let ap=try a.generateBootstrapKeys(),bp=try b.generateBootstrapKeys()
        try a.observe(bp.device,verified:true);try b.observe(ap.device,verified:true)
        return(a,b,ap,bp)
    }
    func testOfflineIndependentDevicesWrongDeviceTamperAndBindings()throws {
        let (a,b,ap,bp)=try pair();let c=try OneWayE2EEEngine(id:UUID().uuidString)
        let ci=try c.publicIdentity();XCTAssertNotEqual(ap.device.curve,bp.device.curve);XCTAssertNotEqual(ci.curve,ap.device.curve);XCTAssertNotEqual(ci.curve,bp.device.curve)
        let server=MockDeliveryServer();server.publicBundles=[ap,bp]
        let body=Data("ALT2-generated-private-fixture".utf8)
        let deliveries=try a.send(to:[bp],body:body);try a.deliver(deliveries,server:server)
        let d=deliveries[0];var tampered=d;tampered.ciphertext[tampered.ciphertext.count-1] ^= 1
        XCTAssertThrowsError(try b.receive(tampered))
        var downgraded=d;downgraded.suite="OW-UNSUPPORTED";XCTAssertThrowsError(try b.receive(downgraded))
        try c.observe(ap.device)
        let wrong=Delivery(id:d.id,sender:d.sender,recipient:c.id,suite:d.suite,conversation:d.conversation,kind:d.kind,ciphertext:d.ciphertext)
        XCTAssertThrowsError(try c.receive(wrong))
        let restarted=try OneWayE2EEEngine(id:b.id)
        XCTAssertEqual(try restarted.receive(d),body);XCTAssertNil(try restarted.receive(d))
        XCTAssertFalse(try JSONEncoder().encode(server.deliveries).range(of:body) != nil)
        XCTAssertEqual(try a.verificationFingerprint(bp.device),try restarted.verificationFingerprint(ap.device))
    }
    func testMultiDeviceRevocationIdentitySubstitution()throws {
        let (a,b,ap,bp)=try pair();let ai=try OneWayE2EEEngine(id:UUID().uuidString),bi=try OneWayE2EEEngine(id:UUID().uuidString)
        let aip=try ai.generateBootstrapKeys(),bip=try bi.generateBootstrapKeys();XCTAssertEqual(Set([ap.device.curve,bp.device.curve,aip.device.curve,bip.device.curve]).count,4)
        try a.observe(bip.device,verified:true);try bi.observe(ap.device)
        let ds=try a.send(to:[bp,bip],body:Data("fanout".utf8));XCTAssertEqual(ds.count,2);XCTAssertNotEqual(ds[0].ciphertext,ds[1].ciphertext)
        XCTAssertEqual(try b.receive(ds[0]),Data("fanout".utf8));XCTAssertEqual(try bi.receive(ds[1]),Data("fanout".utf8))
        try a.revoke(bi.id);XCTAssertEqual(try a.send(to:[bp,bip],body:Data("next".utf8)).map(\.recipient),[b.id])
        let malicious=PublicDevice(id:b.id,curve:bip.device.curve,signing:bip.device.signing)
        try a.observe(malicious);XCTAssertEqual(try a.trust(b.id),.changed)
        XCTAssertThrowsError(try a.send(to:[bp],body:Data("blocked".utf8)))
        let restored=try OneWayE2EEEngine(id:a.id);XCTAssertEqual(try restored.trust(b.id),.changed)
    }
    func testEveryFailureBoundaryAndRetry()throws {
        for point in ["beforeEncryption","afterEncryption","beforeStateCommit","afterStateCommit","beforeNetworkSend","afterNetworkSend","beforeAcknowledgement"] {
            let (a,b,_,bp)=try pair();let id=UUID().uuidString;let body=Data("fault fixture".utf8);let server=MockDeliveryServer()
            a.fault={if $0==point {throw AdmissionError.injected}}
            do {let ds=try a.send(to:[bp],body:body,id:id);try a.deliver(ds,server:server);try a.acknowledge(id);XCTFail("fault not reached")} catch {}
            let restored=try OneWayE2EEEngine(id:a.id);let retry=try restored.send(to:[bp],body:body,id:id)
            if let prior=server.deliveries.first {XCTAssertEqual(prior,retry[0])}
            try restored.deliver(retry,server:server);XCTAssertEqual(server.deliveries.count,1);XCTAssertEqual(try b.receive(retry[0]),body)
            try restored.acknowledge(id);XCTAssertNotNil(try restored.store.read("ack:"+id))
        }
        for point in ["duringDecrypt","afterDecrypt","beforeInboundCommit","afterInboundCommit"] {
            let (a,b,_,bp)=try pair();let ds=try a.send(to:[bp],body:Data("receive fault".utf8))
            b.fault={if $0==point {throw AdmissionError.injected}}
            XCTAssertThrowsError(try b.receive(ds[0]));let restored=try OneWayE2EEEngine(id:b.id)
            let result=try restored.receive(ds[0]);if point=="afterInboundCommit" {XCTAssertNil(result)} else {XCTAssertEqual(result,Data("receive fault".utf8))}
        }
    }
    func testProtectedFilesRollbackAndKeychain()throws {
        let (a,b,_,bp)=try pair();let fixture=Data("ALT2_SECRET_SENTINEL_86175".utf8)
        let initial=try a.serializeState();let d=try a.send(to:[bp],body:fixture)[0];_ = try b.receive(d)
        for engine in [a,b] {
            for f in try FileManager.default.contentsOfDirectory(at:engine.store.directory,includingPropertiesForKeys:nil) {
                let raw=try Data(contentsOf:f);XCTAssertNil(raw.range(of:fixture));XCTAssertNil(raw.range(of:initial))
            }
            XCTAssertNil(UserDefaults.standard.object(forKey:engine.id))
        }
        XCTAssertNotEqual(a.store.key,b.store.key)
        XCTAssertTrue(try a.store.directory.resourceValues(forKeys:[.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }
    func testHardwareDataProtection()throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iOS device required to verify Data Protection; simulator returns no protection attribute")
        #else
        let a=try OneWayE2EEEngine(id:UUID().uuidString)
        for f in try FileManager.default.contentsOfDirectory(at:a.store.directory,includingPropertiesForKeys:nil) {
            let attributes=try FileManager.default.attributesOfItem(atPath:f.path)
            XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType,.completeUntilFirstUserAuthentication)
        }
        #endif
    }
    func testOldDatabaseSnapshotRejected()throws {
        let a=try OneWayE2EEEngine(id:UUID().uuidString)
        let old=try a.store.snapshotForTest()
        _=try a.generateBootstrapKeys();try a.store.closeForTest()
        try old.write(to:a.store.directory.appendingPathComponent("state.sqlite"))
        XCTAssertThrowsError(try OneWayE2EEEngine(id:a.id))
    }
    func testAttachmentCallKeyAndRecoveryCompatibility()throws {
        let (a,b,_,bp)=try pair();let objectKey=SymmetricKey(size:.bits256),callKey=SymmetricKey(size:.bits256)
        let plaintext=Data(repeating:0x71,count:200_000)
        let envelope=try AttachmentCipher.encrypt(plaintext,key:objectKey)
        struct Grant:Codable {let type:String;let object:UUID;let attachmentKey:Data;let callKey:Data;let call:String;let epoch:Int;let suite:String}
        let g=Grant(type:"ALT2-KEY-GRANT",object:envelope.objectID,attachmentKey:objectKey.withUnsafeBytes{Data($0)},callKey:callKey.withUnsafeBytes{Data($0)},call:UUID().uuidString,epoch:1,suite:a.suite)
        let d=try a.send(to:[bp],body:JSONEncoder().encode(g))[0];let data=try XCTUnwrap(b.receive(d));let received=try JSONDecoder().decode(Grant.self,from:data)
        XCTAssertEqual(try AttachmentCipher.decrypt(envelope,key:SymmetricKey(data:received.attachmentKey)),plaintext)
        XCTAssertEqual(received.callKey,g.callKey);XCTAssertEqual(received.suite,a.suite)
        let fresh=try OneWayE2EEEngine(id:UUID().uuidString);XCTAssertNotEqual(try fresh.publicIdentity().curve,try b.publicIdentity().curve)
    }
    func testTenThousandMessages()throws {
        let start=Date();let (a,b,ap,bp)=try pair();var enc:[Double]=[],dec:[Double]=[];var count=0
        // Every message traverses Swift -> UniFFI -> Rust and durable protected DB writes.
        for batch in 0..<500 {
            var burst:[Delivery]=[]
            for i in 0..<20 {let t=Date();let id="\(batch)-\(i)";let d=try a.send(to:[bp],body:Data(id.utf8),id:id)[0];enc.append(Date().timeIntervalSince(t));burst.append(d)}
            for d in burst.reversed() {let t=Date();XCTAssertEqual(try b.receive(d),Data(d.id.utf8));dec.append(Date().timeIntervalSince(t));count+=1}
            XCTAssertNil(try b.receive(burst[0]));XCTAssertEqual(try a.send(to:[bp],body:Data(),id:burst[0].id)[0],burst[0])
            if batch % 100 == 0 {let reply=try b.send(to:[ap],body:Data("ratchet".utf8))[0];XCTAssertNotNil(try a.receive(reply))}
        }
        XCTAssertEqual(count,10000)
        let result:[String:Any] = ["suite":a.suite,"success":count,"failures":0,"total_seconds":Date().timeIntervalSince(start),"encrypt_with_persistence_mean_ms":enc.reduce(0,+)/Double(enc.count)*1000,"decrypt_with_persistence_mean_ms":dec.reduce(0,+)/Double(dec.count)*1000,"account_pickle_bytes":try a.serializeState().count]
        let bytes=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]);let attachment=XCTAttachment(data:bytes,uniformTypeIdentifier:"public.json");attachment.name="ALT2-10000-metrics";attachment.lifetime = .keepAlways;add(attachment)
        print("ALT2_METRICS "+String(data:bytes,encoding:.utf8)!)
    }
    func testWrapperBenchmark()throws {
        let key=SymmetricKey(size:.bits256).withUnsafeBytes{Data($0)}
        var identityTime=0.0
        for _ in 0..<100 {let t=Date();_ = try createAccount(rootKey:key);identityTime+=Date().timeIntervalSince(t)}
        let a=try createAccount(rootKey:key),b=try createAccount(rootKey:key)
        let aid=try publicIdentity(state:a,rootKey:key),bp=try bootstrap(state:b,rootKey:key)
        let payload=Data(repeating:0x65,count:64),start=Date()
        var ao=try outbound(state:a,rootKey:key,curve:bp.curve,signing:bp.signing,oneTime:bp.oneTime,signature:bp.signature,plaintext:payload)
        var bo=try inbound(state:bp.account,rootKey:key,senderCurve:aid.curve,ciphertext:ao.ciphertext)
        let setup=Date().timeIntervalSince(start)
        let reply=try encrypt(state:bo.session,rootKey:key,plaintext:payload);bo=reply
        ao=try decrypt(state:ao.session,rootKey:key,messageType:reply.messageType,ciphertext:reply.ciphertext)
        var enc=0.0,dec=0.0;let loop=Date()
        for _ in 0..<10000 {
            let t=Date();ao=try encrypt(state:ao.session,rootKey:key,plaintext:payload);enc+=Date().timeIntervalSince(t)
            let d=Date();bo=try decrypt(state:bo.session,rootKey:key,messageType:ao.messageType,ciphertext:ao.ciphertext);dec+=Date().timeIntervalSince(d);XCTAssertEqual(bo.plaintext,payload)
        }
        let runtime=Date().timeIntervalSince(loop)
        let store=try ProtectedStore(id:UUID().uuidString);let p=Date()
        for _ in 0..<100 {try store.transaction{store.put("state",Data(ao.session.utf8))}}
        var usage=rusage();getrusage(RUSAGE_SELF,&usage)
        let values:[String:Any] = ["suite":protocolSuite(),"identity_mean_ms":identityTime*10,"bootstrap_ms":setup*1000,"encrypt_mean_ms":enc/10,"decrypt_mean_ms":dec/10,"messages":10000,"loop_seconds":runtime,"persistence_sqlite_keychain_mean_ms":Date().timeIntervalSince(p)*10,"session_bytes":ao.session.utf8.count,"process_peak_rss_bytes":usage.ru_maxrss]
        print("ALT2_WRAPPER_METRICS "+String(data:try JSONSerialization.data(withJSONObject:values,options:[.sortedKeys]),encoding:.utf8)!)
    }
}
