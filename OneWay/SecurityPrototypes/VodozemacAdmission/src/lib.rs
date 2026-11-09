#![forbid(unsafe_code)]
//! Test-only, stateless FFI. Caller owns encrypted-state transactions and trust.
use vodozemac::{Curve25519PublicKey, Ed25519PublicKey, Ed25519Signature};
use vodozemac::olm::{Account, AccountPickle, Session, SessionPickle, SessionConfig, OlmMessage};
uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CryptoError {
    #[error("invalid bounded input")] InvalidInput,
    #[error("authentication failed")] Authentication,
    #[error("unsupported suite")] Suite,
    #[error("invalid protected state")] State,
}
type Result<T> = std::result::Result<T, CryptoError>;
#[derive(uniffi::Record)]
pub struct Identity { pub curve: String, pub signing: String }
#[derive(uniffi::Record)]
pub struct Bootstrap { pub account: String, pub curve: String, pub signing: String, pub one_time: String, pub signature: String, pub suite: String }
#[derive(uniffi::Record)]
pub struct Operation { pub account: String, pub session: String, pub message_type: u32, pub ciphertext: Vec<u8>, pub plaintext: Vec<u8> }
fn key(k: &[u8]) -> Result<&[u8;32]> { k.try_into().map_err(|_| CryptoError::InvalidInput) }
fn account(s: &str,k: &[u8]) -> Result<Account> { if s.len()>4_000_000 {return Err(CryptoError::InvalidInput)}; AccountPickle::from_encrypted(s,key(k)?).map(Account::from_pickle).map_err(|_|CryptoError::State) }
fn session(s: &str,k: &[u8]) -> Result<Session> {
    if s.len()>4_000_000 {return Err(CryptoError::InvalidInput)};
    let s = SessionPickle::from_encrypted(s,key(k)?).map(Session::from_pickle).map_err(|_|CryptoError::State)?;
    if s.session_config()!=config() {return Err(CryptoError::Suite)}; Ok(s)
}
fn config()->SessionConfig {
    #[cfg(feature="full-tag")] { SessionConfig::version_2() }
    #[cfg(not(feature="full-tag"))] { SessionConfig::version_1() }
}
fn bound(b:&[u8])->Result<()> { if b.len()>1_048_576 {Err(CryptoError::InvalidInput)} else {Ok(())} }
fn bundle_bytes(c:&str,s:&str,o:&str)->Result<Vec<u8>> {
    if [c,s,o].iter().any(|s|s.len()>128) {return Err(CryptoError::InvalidInput)};
    serde_json::to_vec(&("OneWay.ALT2.PublicBootstrap.1",protocol_suite(),c,s,o)).map_err(|_|CryptoError::InvalidInput)
}
#[uniffi::export]
pub fn protocol_suite()->String {
    #[cfg(feature="full-tag")] { "OW-ALT2-OLM-FULLTAG-EXPERIMENTAL-1".into() }
    #[cfg(not(feature="full-tag"))] { "OW-ALT2-OLM-STABLE-1".into() }
}
#[uniffi::export]
pub fn create_account(root_key:Vec<u8>)->Result<String> {Ok(Account::new().pickle().encrypt(key(&root_key)?))}
#[uniffi::export]
pub fn public_identity(state:String,root_key:Vec<u8>)->Result<Identity> {
    let a=account(&state,&root_key)?; Ok(Identity{curve:a.curve25519_key().to_base64(),signing:a.ed25519_key().to_base64()})
}
#[uniffi::export]
pub fn bootstrap(state:String,root_key:Vec<u8>)->Result<Bootstrap> {
    let mut a=account(&state,&root_key)?; a.generate_one_time_keys(1);
    let one_time=a.one_time_keys().values().next().ok_or(CryptoError::State)?.to_base64();
    let curve=a.curve25519_key().to_base64(); let signing=a.ed25519_key().to_base64();
    let signature=a.sign(&bundle_bytes(&curve,&signing,&one_time)?).to_base64();
    a.mark_keys_as_published();
    Ok(Bootstrap{account:a.pickle().encrypt(key(&root_key)?),curve,signing,one_time,signature,suite:protocol_suite()})
}
#[uniffi::export]
pub fn outbound(state:String,root_key:Vec<u8>,curve:String,signing:String,one_time:String,signature:String,plaintext:Vec<u8>)->Result<Operation> {
    bound(&plaintext)?;
    let signed=bundle_bytes(&curve,&signing,&one_time)?;
    Ed25519PublicKey::from_base64(&signing).map_err(|_|CryptoError::InvalidInput)?.verify(&signed,&Ed25519Signature::from_base64(&signature).map_err(|_|CryptoError::InvalidInput)?).map_err(|_|CryptoError::Authentication)?;
    let a=account(&state,&root_key)?;
    let mut s=a.create_outbound_session(config(),Curve25519PublicKey::from_base64(&curve).map_err(|_|CryptoError::InvalidInput)?,Curve25519PublicKey::from_base64(&one_time).map_err(|_|CryptoError::InvalidInput)?).map_err(|_|CryptoError::Authentication)?;
    let (kind,ciphertext)=s.encrypt(&plaintext).map_err(|_|CryptoError::Authentication)?.to_parts();
    Ok(Operation{account:state,session:s.pickle().encrypt(key(&root_key)?),message_type:kind as u32,ciphertext,plaintext:vec![]})
}
#[uniffi::export]
pub fn inbound(state:String,root_key:Vec<u8>,sender_curve:String,ciphertext:Vec<u8>)->Result<Operation> {
    bound(&ciphertext)?; let mut a=account(&state,&root_key)?;
    let OlmMessage::PreKey(p)=OlmMessage::from_parts(0,&ciphertext).map_err(|_|CryptoError::InvalidInput)? else {return Err(CryptoError::InvalidInput)};
    let r=a.create_inbound_session(config(),Curve25519PublicKey::from_base64(&sender_curve).map_err(|_|CryptoError::InvalidInput)?,&p).map_err(|_|CryptoError::Authentication)?;
    Ok(Operation{account:a.pickle().encrypt(key(&root_key)?),session:r.session.pickle().encrypt(key(&root_key)?),message_type:0,ciphertext:vec![],plaintext:r.plaintext})
}
#[uniffi::export]
pub fn encrypt(state:String,root_key:Vec<u8>,plaintext:Vec<u8>)->Result<Operation> {
    bound(&plaintext)?; let mut s=session(&state,&root_key)?;
    let (kind,ciphertext)=s.encrypt(&plaintext).map_err(|_|CryptoError::Authentication)?.to_parts();
    Ok(Operation{account:String::new(),session:s.pickle().encrypt(key(&root_key)?),message_type:kind as u32,ciphertext,plaintext:vec![]})
}
#[uniffi::export]
pub fn decrypt(state:String,root_key:Vec<u8>,message_type:u32,ciphertext:Vec<u8>)->Result<Operation> {
    bound(&ciphertext)?; let mut s=session(&state,&root_key)?;
    let m=OlmMessage::from_parts(message_type as usize,&ciphertext).map_err(|_|CryptoError::InvalidInput)?;
    let plaintext=s.decrypt(&m).map_err(|_|CryptoError::Authentication)?;
    Ok(Operation{account:String::new(),session:s.pickle().encrypt(key(&root_key)?),message_type,ciphertext:vec![],plaintext})
}

#[cfg(all(test, feature="full-tag"))]
mod tests {
    use super::*;
    #[test]
    fn full_tag_never_accepts_stable_bootstrap_and_reverse() {
        for (sending,receiving) in [(SessionConfig::version_1(),SessionConfig::version_2()),(SessionConfig::version_2(),SessionConfig::version_1())] {
            let a=Account::new();let mut b=Account::new();b.generate_one_time_keys(1);
            let otk=*b.one_time_keys().values().next().unwrap();
            let mut s=a.create_outbound_session(sending,b.curve25519_key(),otk).unwrap();
            let OlmMessage::PreKey(p)=s.encrypt(b"test-only suite mismatch").unwrap() else {panic!("prekey expected")};
            assert!(b.create_inbound_session(receiving,a.curve25519_key(),&p).is_err());
            assert!(b.create_inbound_session(sending,a.curve25519_key(),&p).is_ok());
        }
    }
}
