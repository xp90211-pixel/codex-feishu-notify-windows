# Contributing

1. Create a focused branch from `main`.
2. Keep machine-specific settings and runtime data out of Git.
3. Run `pwsh -File .\tests\Test-Project.ps1`.
4. On Windows, run `pwsh -STA -File .\scripts\Settings-Gui.ps1 -SmokeTest` for GUI changes.
5. Inspect `git diff --check` and the staged diff.
6. Open a draft pull request and complete the security checklist.

Changes to scheduling must preserve exactly one true `MSFT_TaskDailyTrigger` and verify `DaysInterval=1`, repetition interval, repetition duration, and `StartWhenAvailable=false`. Holiday extensions must use date-specific `MSFT_TaskTimeTrigger` objects, cover only the gaps outside the normal window, and use dates traceable to an official source. Changes to `notify.ps1` must not call `Start-ScheduledTask` or send directly to Feishu.

GUI changes must remain a control layer over `Install.ps1` and `Test-Configuration.ps1`. Do not duplicate task-registration logic or add a manual-run button.
