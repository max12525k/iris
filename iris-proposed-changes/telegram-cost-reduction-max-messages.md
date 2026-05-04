# Proposal: `max_messages` Trigger for SessionResetPolicy

**Branch:** `iris-proposed/telegram-cost-reduction`  
**Author:** Iris  
**Date:** 2026-05-04  
**Status:** Proposed — requires user review before implementation

---

## Problem

The existing `SessionResetPolicy` supports `daily` and `idle` triggers (or `both`), but
neither is aggressive enough for Telegram DM sessions. A user sending 40 messages
over 30 minutes can rack up 80K+ tokens in tool-call output before the 45-minute
idle timeout fires (or the daily 4am reset). By then the per-turn cost has
compounded across every subsequent turn.

We need a hard cap: "reset after N messages, regardless of time."

---

## Proposed Change

Add `max_messages: Optional[int] = None` to `SessionResetPolicy`. When set, any
session exceeding this message count triggers a reset on the *next* incoming
message (not mid-turn, avoiding data loss).

### Files to Modify

| File | Change |
|------|--------|
| `gateway/config.py` (~line 212) | Add `max_messages: Optional[int] = None` to `SessionResetPolicy` dataclass; update `to_dict()` and `from_dict()` |
| `gateway/config.py` (~line 480) | Update `get_reset_policy()` docstring |
| `gateway/session.py` (~line 784) | Add `_should_reset_by_message_count(entry)` helper; call from `_should_reset()` |
| `gateway/session.py` (~line 750) | Add `_is_expired()` message-count check |
| `gateway/run.py` (~line 9007) | `/compress` command already exists; no change needed |
| `gateway/run.py` (~line 5672) | Verify `_compress_context()` handles message-count resets correctly |

### Schema

```python
@dataclass
class SessionResetPolicy:
    mode: str = "both"
    at_hour: int = 4
    idle_minutes: int = 1440
    max_messages: Optional[int] = None   # NEW
    notify: bool = True
    notify_exclude_platforms: tuple = ("webhook",)
```

### Behavior

- `max_messages: None` → no message-count trigger (backward compatible)
- `max_messages: 30` → on the 31st message, reset before processing
- Reset reason string: `"message_count"`
- Respects `notify` flag (Telegram gets a notification: "Session reset after 30 messages to manage context cost.")

### Config Example

```yaml
session_reset:
  reset_by_platform:
    telegram:
      mode: "idle"
      idle_minutes: 45
      max_messages: 30       # NEW: hard cap regardless of idle
      notify: true
```

---

## Why Not Just Lower `idle_minutes` Further?

Lowering `idle_minutes` to 15 minutes creates a terrible user experience: a user
stepping away for a coffee loses all context. A `max_messages` cap is
**activity-aware**: it only resets when the user has actually been *active*,
which is exactly when costs compound.

---

## Testing Plan

1. **Unit test** in `tests/gateway/test_session_reset.py` (new file):
   - Mock session with 29 messages → no reset
   - Mock session with 30 messages → reset on next message
   - Verify reset reason = `"message_count"`
   - Verify `notify=True` emits gateway hook

2. **Integration test**: Spin up gateway, send 31 Telegram messages, assert
   session ID changes and notification fires.

3. **Regression test**: Verify `max_messages: None` (default) preserves existing
   behavior exactly.

---

## Cost Impact Estimate

Current worst-case Telegram session (no reset for 24h):
- 100 messages × avg 800 tokens × $3.49/1M output = **~$2.80**
- Plus prompt tokens at $0.74/1M × ~400K = **~$0.30**
- **Total: ~$3.10/session**

With `max_messages: 30` + `idle: 45m`:
- Session resets at 30 messages
- Avg 400 tokens/turn after compression kicks in
- 30 messages × $3.49/1M + compression cost (~$0.02) = **~$0.44**
- **Savings: ~85% on long sessions**

---

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| User frustration at mid-work reset | `notify: true` + clear message; user can tune `max_messages` |
| Lost context during deep research | User can escalate to `/reasoning high` or run in CLI (no message cap) |
| Backward compat break | `max_messages` defaults to `None`; no behavior change for existing configs |
| Config validation failure | `from_dict()` gracefully handles missing key (use `_coerce_int`) |

---

## Decision Required

This change requires modifying protected paths (`gateway/config.py`, `gateway/session.py`,
`gateway/run.py`) which are human-only territory per the pre-commit rules. I
propose the implementation but **I cannot commit this to iris-self/** — it needs
human review and merge to `main`.

**Suggested next step:**
```bash
cd ~/personal_assistant/iris
git checkout main
git merge iris-proposed/telegram-cost-reduction --no-commit  # config + SOUL changes
# Then manually apply the gateway/ code changes per this doc
```

Or: approve this proposal and I'll implement the code changes in the same
branch, leaving them unstaged for your review.
