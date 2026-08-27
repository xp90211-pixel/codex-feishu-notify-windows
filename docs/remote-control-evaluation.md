# Feishu remote-control evaluation

## Decision

Remote approval and arbitrary terminal input are **not enabled in this notifier**. Notification lifecycle hooks are implemented, but they never approve, deny, block, continue, or inject text.

The reviewed `feishu-bridge` implementation is mature on macOS/Linux, but its terminal-control layer depends on `tmux`, Unix PTYs, FIFO relays, and `TIOCSTI`-style injection. Those mechanisms do not provide a safe or stable control path into a running Windows Codex desktop task.

## Difficulty matrix

| Capability | Windows difficulty | Main blockers | Decision |
|---|---:|---|---|
| Receive Feishu card-button callbacks | 3/5 | Requires a separately published Feishu custom app, long-lived listener, credentials, callback acknowledgement, and user allowlist | Possible only as a separate opt-in service |
| Notify about `PermissionRequest` | 1/5 | Supported by current Codex lifecycle hooks | Implemented; notification only |
| Return allow/deny from Feishu | 4/5 | Requires a local decision broker, request correlation, timeout, replay protection, authenticated Feishu user identity, and a synchronous `PermissionRequest` hook | Deferred until a separate security review and explicit enablement |
| Send arbitrary text to the current Codex desktop task | 5/5 | No stable public Windows desktop-task input endpoint; POSIX terminal injection is inapplicable | Excluded |
| Send commands to a separately launched CLI session | 3/5 | Needs a dedicated ConPTY/App Server owner process and clear session ownership | Must be a separate bridge project, not this notifier |

## Safe reference architecture for a future approval-only service

```text
Codex PermissionRequest Hook
        |
        | writes fixed request metadata and waits with a short timeout
        v
Owner-only local decision broker
        ^
        | one-time request id, session binding, expiry, replay protection
        |
Feishu custom-app long connection <--- owner allowlist + signed card action
```

The service would have to meet all of these conditions:

1. Use a new, separately named task such as `Codex.FeishuRemoteApproval`; never modify `LarkChannelBridge.Bot.codex`.
2. Default to disabled and fail closed. Timeout or listener failure must leave the normal Codex approval prompt in control.
3. Accept only `allow` or `deny` for an outstanding `PermissionRequest`; never accept arbitrary shell text.
4. Bind every action to a session, turn, request id, authorized Feishu user, and short expiry time.
5. Consume each request id exactly once and reject replayed or cross-session actions.
6. Keep command text, prompts, file paths, credentials, and tool inputs out of Feishu cards and logs by default.
7. Require an explicit installation step for the Feishu app, permissions, publication, and user allowlist.
8. Keep the notification schedule and the remote-approval listener independent. An approval service cannot wait until the 18:40–02:00 delivery window.

## Why the current project stops at notifications

The notification path is asynchronous and non-authoritative: a failed notification cannot change what Codex is allowed to do. Remote approval changes the authorization boundary. Combining both in one scheduled notifier would make a delivery bug capable of becoming an authorization bug.

References:

- [Official Codex Hooks guide](https://developers.openai.com/codex/hooks)
- [`feishu-bridge` terminal injector](https://github.com/Mo-ZheHan/feishu-bridge/blob/17e427070a38b0eb797f983346598bb784c74132/src/lib/terminal-inject.js)
- [`feishu-bridge` Feishu listener](https://github.com/Mo-ZheHan/feishu-bridge/blob/17e427070a38b0eb797f983346598bb784c74132/src/apps/feishu-listener.js)
