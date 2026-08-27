# Changelog

## 0.4.0 - 2026-08-27

- Added one dynamic `马上开始 / 立刻停止` control to the run-schedule tab without changing the saved daily window.
- Added expiring `force` and `pause` delivery states: an outside-window start runs immediately and repeats until the next normal trigger, while a running-window stop resumes automatically at the next trigger or on a second click.
- Added a named temporary Task Scheduler trigger, hidden first-drain launch, per-item stop checks, status diagnostics, and automatic override cleanup on master disable, apply, install, and uninstall.
- Reserved one of Task Scheduler's 48 trigger slots for temporary manual running and expanded schedule-boundary/state tests.
- Made the holiday-mode explanation row height responsive: it is compact for one line and grows only when narrower layouts wrap the text.
- Added a reproducible release-packaging script, checksum output, and packaged v0.4.0 release notes.

## 0.3.0 - 2026-08-26

- Added official Codex lifecycle-hook integration for permission waits, waiting-state resolution, and non-blocking Stop-based completion arming.
- Added a strict two-stage completion gate keyed by session and turn, with TTL and atomic one-time consumption.
- Added zero-dependency Windows WinRT Toast notifications, background-only foreground policy, persistent waiting reminders, and tag-based dismissal.
- Added Feishu interactive cards, structured transport-result validation, bounded retries, and preserved lark-cli idempotency.
- Added lifecycle-hook JSON merge/verification, deployment snapshots, owned-handler uninstall, GUI diagnostics, and protected rollback.
- Reworked the WinForms settings tool into a resizable, DPI-aware tabbed layout with bounded startup sizing, scrollable settings pages, and a persistent wrapping action bar.
- Added independent manual switches for the scheduled delivery task and Feishu delivery, including desktop-only behavior and recoverable suppression of pending items while Feishu is disabled.
- Clarified GUI portability by showing the full configuration source path, an empty-path auto-detection cue, and the resolved lark-cli executable path.
- Replaced the duplicate schedule checkbox and action button with one immediate persisted `运行计划：已开启/已关闭` toggle.
- Replaced the duplicate Feishu checkbox and action button with one immediate persisted `飞书通知：已开启/已关闭` toggle.
- Replaced free-form Lark profile entry with an existing-profile drop-down and disabled it automatically when isolated profile mode is cleared.
- Clarified the visible-thread filter as `仅通知已登记在 Codex 桌面端的任务（推荐）` to match its desktop-state registration check.
- Disabled dependent PC-notification choices while the PC notification master switch is off, without clearing their saved selections.
- Split scheduling into a dedicated GUI tab, added per-mode holiday explanations, and added optional Monday-through-Sunday all-day scheduling backed by weekly gap triggers.
- Fixed GUI lifecycle-hook diagnostics to parse `hooks.json` before comparing Windows command paths.
- Documented why Feishu remote approval and arbitrary Windows terminal input remain separate and disabled.
- Added third-party notices for the MIT-licensed projects whose implementation patterns were adapted.
- Added a maintenance-section `安装通知` button for first-time deployment and idempotent repair on another Windows/Codex installation; it reuses the backed-up installer and verifier and explicitly preserves Codex hook trust as a separate user action.
- Defaulted clean-machine GUI deployments to the familiar `Codex.LarkNotify.codex` task name while continuing to detect and maintain existing `Codex.FeishuNotify` tasks.
- Fixed GUI installation with no selected all-day weekdays by preventing the empty selection from collapsing to `null` and omitting the optional parameter so installer `ValidateSet` succeeds.

## 0.2.0 - 2026-08-26

- Added a Chinese WinForms settings tool with automatic discovery of the existing task and install root.
- Added managed and legacy configuration loading, input validation, masked chat-id handling, and custom holiday-calendar selection.
- Added safe apply/verify flow, task enable/disable controls, a double-click launcher, and headless validation/smoke-test modes.

## 0.1.0 - 2026-08-22

- Extracted the local Codex-to-Feishu integration into a portable Windows project.
- Added private JSON configuration, atomic queueing, preview redaction, idempotency markers, and expiry handling.
- Added a true daily 18:40-02:00 scheduled-task installer with demand start disabled.
- Added date-specific public-holiday gap triggers, Singapore 2026-2027 and China 2026 calendars, automatic region selection, and custom-calendar support.
- Added safe Codex notify-hook backup/chaining, uninstall safeguards, configuration diagnostics, tests, and GitHub Actions.
