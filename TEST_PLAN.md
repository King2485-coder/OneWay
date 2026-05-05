# CipherChat Test Expansion Plan

## Service Unit Tests
- MessagingService: send text/media, failed send, retry, delivery/read status transitions.
- StoryService: publish with visibility, expiry filtering, seen-state behavior.
- GroupService: member fetch + invite link generation.
- DeviceSessionService: link session + revoke others.
- BackupService: opt-in state and create/restore workflows.
- SafetyService: block/report/preset/kill-switch actions.

## ViewModel Tests
- ChatsListViewModel: search filtering, pin/mute/archive state transitions.
- ChatThreadViewModel: attachment size validation, typing pulse, retry path.
- Settings/Profile view models: dummy account creation, timer scheduling.

## UI Tests
- Story viewer opens from chats and advances tap-through.
- Chat thread retry button path from failed state.
- Settings flows for Safety Center, Device Sessions, Backup & Restore.
- Burn button visibility toggle and destructive confirmation.

## Regression Scenarios
- Timed account deletion with pending burn toggle enabled.
- Dummy account switch during active story posting.
- Archived chat visibility while search is active.
