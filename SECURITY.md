# Security policy

## Reporting a vulnerability

Use a GitHub private security advisory when the repository enables them. Do not open a public issue containing credentials, private Codex task content, Feishu identifiers, or unredacted logs.

## Secrets and private data

The repository must never contain:

- `settings.local.json`, `previous-notify.json`, or `install-state.json`;
- Feishu/Lark access tokens, app secrets, webhook URLs, or real chat IDs;
- `.lark-channel` profile files;
- files under `spool/`, `logs/`, or `backups/`;
- raw Codex notification payloads or user-specific absolute paths.

The notifier queues only shortened, redacted task/result previews. Disable previews in local settings when task content is sensitive.

Permission events omit `tool_input`, commands, paths, and approval descriptions. The tool name is also omitted unless `message.include_permission_tool` is explicitly enabled.

## Trust boundary

The project runs as the signed-in Windows user and invokes a locally authenticated `lark-cli` profile. It does not copy authentication material into the project directory. Review PowerShell changes before installing an untrusted fork.

The one-click Release installer runs per-user with `asInvoker`, embeds the same public Release ZIP, rejects archive paths outside its product staging directory, and does not request elevation or contain local credentials. It only installs the management files, creates a Start menu shortcut, and opens the graphical settings tool; Codex hooks, scheduled tasks, and private settings still require an explicit confirmation in that tool. The installer is not currently Authenticode-signed, so verify its SHA-256 attachment before running it. An unknown-publisher SmartScreen warning is not proof that a download is safe.

Lifecycle hooks are notification-only. They must not return `allow`, `deny`, `block`, updated permissions, arbitrary input, or automatic continuation instructions. The strict completion gate prevents ordinary accidental completion reports; it is not cryptographic authentication against another process running as the same Windows user.

Feishu card callbacks, remote approvals, and terminal input require a separate listener and a stronger authorization boundary. They are intentionally disabled; see `docs/remote-control-evaluation.md`.

## v0.6 safety boundaries

New installations keep task/result previews disabled; upgrades preserve explicit existing choices. Redaction is best-effort, not a guarantee that business-sensitive content is safe to share. Raw transport stdout/stderr is not written to logs. An explicit receipt is required before removing a pending item.

Disabling delivery prevents subsequent submissions but cannot retract requests already submitted to Feishu. Unknown desktop state schemas fail closed; desktop registration is a heuristic filter, never an authorization boundary. Permission events without a stable provider request ID cannot be perfectly correlated under arbitrary reordering; ambiguous resolution leaves state until turn/session cleanup or expiry.

Release archives are checked against an individual-file allowlist and scanned before publication. The unsigned setup EXE still requires the user to verify origin and SHA-256. Backups are retained locally and may contain previous credentials or sensitive configuration; protect or remove them deliberately.
