## What changed

Describe the user-visible behavior and why it is needed.

## Verification

- [ ] `pwsh -File .\tests\Test-Project.ps1` passes.
- [ ] No real chat ID, token, webhook URL, profile config, queue item, log, or user-specific path is included.
- [ ] `notify.ps1` still never starts the scheduled task.
- [ ] The daily trigger remains daily, not a one-time trigger.
- [ ] Holiday triggers cover only the missing time-window gaps, and calendar changes cite an official source.
- [ ] Documentation is updated for behavior or configuration changes.
