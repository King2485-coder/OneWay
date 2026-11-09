//! Isolated ALT-1 protocol feasibility tests. No production adapter or networking.
//! Pickle snapshots below model disposable transaction candidates, not durable storage.

#[cfg(test)]
mod tests {
    use vodozemac::olm::{Account, AccountPickle, OlmMessage, Session, SessionConfig, SessionPickle};

    fn pair(alice: &Account, bob: &mut Account) -> (Session, Session) {
        bob.generate_one_time_keys(1);
        let key = *bob.one_time_keys().values().next().unwrap();
        let mut a = alice.create_outbound_session(SessionConfig::version_1(), bob.curve25519_key(), key).unwrap();
        bob.mark_keys_as_published();
        let OlmMessage::PreKey(first) = a.encrypt(b"fixture: initial").unwrap() else { panic!("expected prekey") };
        let result = bob.create_inbound_session(SessionConfig::version_1(), alice.curve25519_key(), &first).unwrap();
        assert_eq!(result.plaintext, b"fixture: initial");
        let mut b = result.session;
        assert_eq!(a.session_id(), b.session_id());
        assert_eq!(a.decrypt(&b.encrypt(b"fixture: reply").unwrap()).unwrap(), b"fixture: reply");
        (a, b)
    }

    #[test]
    fn asynchronous_handshake_bidirectional_ratchets_reorder_replay() {
        let (mut a, mut b) = pair(&Account::new(), &mut Account::new());
        let first = a.encrypt(b"one").unwrap();
        let second = a.encrypt(b"two").unwrap();
        assert_eq!(b.decrypt(&second).unwrap(), b"two");
        assert_eq!(b.decrypt(&first).unwrap(), b"one");
        assert!(b.decrypt(&first).is_err());
        for _ in 0..32 {
            assert_eq!(a.decrypt(&b.encrypt(b"reply").unwrap()).unwrap(), b"reply");
            assert_eq!(b.decrypt(&a.encrypt(b"next").unwrap()).unwrap(), b"next");
        }
    }

    #[test]
    fn tamper_rejected_without_losing_valid_message() {
        let (mut a, mut b) = pair(&Account::new(), &mut Account::new());
        let valid = a.encrypt(b"tamper fixture").unwrap();
        let (kind, mut bytes) = valid.to_parts();
        *bytes.last_mut().unwrap() ^= 1;
        if let Ok(bad) = OlmMessage::from_parts(kind, &bytes) { assert!(b.decrypt(&bad).is_err()); }
        assert_eq!(b.decrypt(&valid).unwrap(), b"tamper fixture");
        assert!(OlmMessage::from_parts(999, &bytes).is_err());
    }

    #[test]
    fn independent_devices_cannot_decrypt_each_others_delivery() {
        let alice = Account::new();
        let mut bob = Account::new();
        let mut carol = Account::new();
        assert_ne!(bob.identity_keys(), carol.identity_keys());
        let (mut ab, mut ba) = pair(&alice, &mut bob);
        let (mut ac, mut ca) = pair(&alice, &mut carol);
        let for_b = ab.encrypt(b"per-device fixture").unwrap();
        assert!(ca.decrypt(&for_b).is_err());
        assert_eq!(ba.decrypt(&for_b).unwrap(), b"per-device fixture");
        let for_c = ac.encrypt(b"per-device fixture").unwrap();
        assert_eq!(ca.decrypt(&for_c).unwrap(), b"per-device fixture");
    }

    #[test]
    fn encrypted_pickle_restart_and_wrong_key() {
        // Test-only key generated from the library's OS-backed key generator.
        let key = vodozemac::Curve25519SecretKey::new().to_bytes();
        let alice = Account::new();
        let account_pickle = alice.pickle().encrypt(&key);
        let restored = Account::from_pickle(AccountPickle::from_encrypted(&account_pickle, &key).unwrap());
        assert_eq!(alice.identity_keys(), restored.identity_keys());
        let (mut a, b) = pair(&restored, &mut Account::new());
        let encrypted = b.pickle().encrypt(&key);
        let mut wrong = key.clone();
        wrong[0] ^= 1;
        assert!(SessionPickle::from_encrypted(&encrypted, &wrong).is_err());
        let mut restarted = Session::from_pickle(SessionPickle::from_encrypted(&encrypted, &key).unwrap());
        assert_eq!(restarted.decrypt(&a.encrypt(b"after restart").unwrap()).unwrap(), b"after restart");
    }

    #[test]
    fn discarded_send_candidate_and_exact_ciphertext_retry() {
        let (committed, mut receiver) = pair(&Account::new(), &mut Account::new());
        let mut aborted = Session::from_pickle(committed.pickle());
        let _never_sent = aborted.encrypt(b"aborted candidate").unwrap();
        drop(aborted); // Simulated failure before durable commit: no bytes may leave.
        let mut candidate = Session::from_pickle(committed.pickle());
        let outgoing = candidate.encrypt(b"committed fixture").unwrap();
        let exact_outbox = outgoing.to_parts();
        let _advanced_state = candidate.pickle(); // Must share a real DB transaction with outbox later.
        let retry = OlmMessage::from_parts(exact_outbox.0, &exact_outbox.1).unwrap();
        assert_eq!(retry.to_parts(), exact_outbox);
        assert_eq!(receiver.decrypt(&retry).unwrap(), b"committed fixture");
        assert!(receiver.decrypt(&retry).is_err());
    }

    #[test]
    fn discarded_receive_candidate_preserves_committed_state() {
        let (mut sender, committed) = pair(&Account::new(), &mut Account::new());
        let incoming = sender.encrypt(b"receive fixture").unwrap();
        let mut aborted = Session::from_pickle(committed.pickle());
        assert!(aborted.decrypt(&incoming).is_ok());
        drop(aborted); // No UI or acknowledgement before a real durable commit.
        let mut retry = Session::from_pickle(committed.pickle());
        assert_eq!(retry.decrypt(&incoming).unwrap(), b"receive fixture");
    }
}
