import Foundation
import CryptoKit
import Security
import SQLite3

enum AdmissionError: Error { case storage, authentication, changedIdentity, revoked, suite, injected, invalid, rollback }

/// Local admission store only. All callers are serialized by OneWayE2EEEngine.
final class ProtectedStore {
    let directory: URL
    let key: Data
    private var db: OpaquePointer?
    private let service: String
    private var hashes: [String: String] = [:]
    private var generation: Int64 = 0
    private let encoder = JSONEncoder()
    private struct Anchor: Codable { var generation: Int64; var digest: String }
    private struct Manifest: Codable { var generation: Int64; var hashes: [String: String] }
    private var pending: [String: Data] = [:]

    static func keychain(_ service: String, _ account: String, value: Data? = nil) throws -> Data? {
        let q: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service, kSecAttrAccount as String:account]
        if let value {
            let update = [kSecValueData as String:value]
            let status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var add=q; add[kSecValueData as String]=value
                add[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                guard SecItemAdd(add as CFDictionary,nil)==errSecSuccess else {throw AdmissionError.storage}
            } else if status != errSecSuccess {throw AdmissionError.storage}
            return value
        }
        var query=q; query[kSecReturnData as String]=true; query[kSecMatchLimit as String]=kSecMatchLimitOne
        var result: CFTypeRef?
        let status=SecItemCopyMatching(query as CFDictionary,&result)
        if status == errSecItemNotFound {return nil}
        guard status == errSecSuccess, let bytes=result as? Data else {throw AdmissionError.storage}
        return bytes
    }
    init(id: String) throws {
        service="is.oneway.alt2.\(id)"
        directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("ALT2/\(id)")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication])
        var url=directory; var values=URLResourceValues(); values.isExcludedFromBackup=true; try url.setResourceValues(values)
        if let existing=try Self.keychain(service,"root") {key=existing}
        else {
            guard !FileManager.default.fileExists(atPath:directory.appendingPathComponent("state.sqlite").path) else {throw AdmissionError.rollback}
            var bytes=Data(count:32); let result=bytes.withUnsafeMutableBytes {SecRandomCopyBytes(kSecRandomDefault,32,$0.baseAddress!)}
            guard result==errSecSuccess else {throw AdmissionError.storage}
            key=bytes; _=try Self.keychain(service,"root",value:bytes)
        }
        guard sqlite3_open(directory.appendingPathComponent("state.sqlite").path,&db)==SQLITE_OK else {throw AdmissionError.storage}
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY; CREATE TABLE IF NOT EXISTS records(k TEXT PRIMARY KEY,v BLOB NOT NULL);")
        encoder.outputFormatting=[.sortedKeys]
        if let manifest=try raw("manifest") {
            let m=try JSONDecoder().decode(Manifest.self,from:open(manifest,context:"manifest"))
            let actual=Anchor(generation:m.generation,digest:Self.hash(manifest))
            let anchor=try Self.keychain(service,"anchor").map{try JSONDecoder().decode(Anchor.self,from:$0)}
            let pending=try Self.keychain(service,"pending").map{try JSONDecoder().decode(Anchor.self,from:$0)}
            guard [anchor,pending].compactMap({$0}).contains(where:{$0.generation==actual.generation && $0.digest==actual.digest}) else {throw AdmissionError.rollback}
            hashes=m.hashes; generation=m.generation
            _=try Self.keychain(service,"anchor",value:encoder.encode(actual))
            _=try Self.keychain(service,"pending",value:encoder.encode(actual))
        } else if try Self.keychain(service,"anchor") != nil {throw AdmissionError.rollback}
        try protectFiles()
    }
    deinit {sqlite3_close(db)}
    func snapshotForTest()throws->Data {try exec("PRAGMA wal_checkpoint(TRUNCATE)");return try Data(contentsOf:directory.appendingPathComponent("state.sqlite"))}
    func closeForTest()throws {try exec("PRAGMA wal_checkpoint(TRUNCATE)");guard sqlite3_close(db)==SQLITE_OK else {throw AdmissionError.storage};db=nil}
    static func hash(_ data:Data)->String {Data(SHA256.hash(data:data)).base64EncodedString()}
    private func seal(_ value:Data,context:String)throws->Data {
        guard let data=try AES.GCM.seal(value,using:SymmetricKey(data:key),authenticating:Data(("OW.ALT2.Row.1|"+context).utf8)).combined else {throw AdmissionError.storage}; return data
    }
    private func open(_ value:Data,context:String)throws->Data {try AES.GCM.open(AES.GCM.SealedBox(combined:value),using:SymmetricKey(data:key),authenticating:Data(("OW.ALT2.Row.1|"+context).utf8))}
    func read(_ k:String)throws->Data? {
        if let p=pending[k] {return p}
        guard let expected=hashes[k] else {return nil}
        guard let sealed=try raw(k),Self.hash(sealed)==expected else {throw AdmissionError.rollback}
        return try open(sealed,context:k)
    }
    func put(_ k:String,_ v:Data) {pending[k]=v}
    func transaction<T>(_ block:()throws->T,beforeCommit:()throws->Void = {},afterCommit:()throws->Void = {})throws->T {
        guard pending.isEmpty else {throw AdmissionError.storage}
        try exec("BEGIN IMMEDIATE")
        var committed=false
        do {
            let result=try block(); var next=hashes
            for (k,v) in pending {let sealed=try seal(v,context:k); try write(k,sealed); next[k]=Self.hash(sealed)}
            let manifest=try seal(encoder.encode(Manifest(generation:generation+1,hashes:next)),context:"manifest")
            let anchor=try encoder.encode(Anchor(generation:generation+1,digest:Self.hash(manifest)))
            _=try Self.keychain(service,"pending",value:anchor)
            try write("manifest",manifest); try beforeCommit(); try exec("COMMIT"); committed=true
            hashes=next;generation+=1;pending=[:]
            _=try Self.keychain(service,"anchor",value:anchor)
            _=try Self.keychain(service,"pending",value:anchor)
            try protectFiles();try afterCommit();return result
        } catch {if !committed {try? exec("ROLLBACK")};pending=[:];throw error}
    }
    func protectFiles()throws {
        for file in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) {
            try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:file.path)
        }
    }
    private func exec(_ sql:String)throws {guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else {throw AdmissionError.storage}}
    private func raw(_ k:String)throws->Data? {
        var s:OpaquePointer?;guard sqlite3_prepare_v2(db,"SELECT v FROM records WHERE k=?",-1,&s,nil)==SQLITE_OK else {throw AdmissionError.storage};defer{sqlite3_finalize(s)}
        let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self);sqlite3_bind_text(s,1,k,-1,transient)
        let result=sqlite3_step(s);if result==SQLITE_DONE{return nil};guard result==SQLITE_ROW else {throw AdmissionError.storage}
        return Data(bytes:sqlite3_column_blob(s,0),count:Int(sqlite3_column_bytes(s,0)))
    }
    private func write(_ k:String,_ v:Data)throws {
        var s:OpaquePointer?;guard sqlite3_prepare_v2(db,"INSERT OR REPLACE INTO records(k,v) VALUES(?,?)",-1,&s,nil)==SQLITE_OK else {throw AdmissionError.storage};defer{sqlite3_finalize(s)}
        let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self);sqlite3_bind_text(s,1,k,-1,transient)
        _=v.withUnsafeBytes{sqlite3_bind_blob(s,2,$0.baseAddress,Int32(v.count),transient)}
        guard sqlite3_step(s)==SQLITE_DONE else {throw AdmissionError.storage}
    }
}
