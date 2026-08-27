# 递交 GitHub 的具体攻略

下面步骤适用于第一次把本项目提交到你自己的 GitHub 仓库。建议先建私有仓库，完成 Actions 和泄密检查后再改为公开。

## 一、发布前检查

在项目根目录执行：

```powershell
pwsh -File .\tests\Test-Project.ps1
```

该测试包含本机用户名、真实格式群 ID、webhook 与典型密钥扫描。再确认以下文件不存在于项目中：

- `settings.local.json`；
- `previous-notify.json`；
- `install-state.json`；
- `spool/`、`logs/`、`backups/`；
- 从本机导出的计划任务 XML；
- 私有或临时的 `holidays.local.json`；
- 真实飞书会话 ID、token、应用密钥或 webhook URL。

同时审核 `config/holidays.*.json`：日期必须来自正文可追溯的政府官方来源，包含顺延假日，且不要把普通周末凭空列为法定假日。

如果曾经误把秘密加入 Git，仅从当前文件删除并不够；在公开前应重写历史并立即轮换相关凭据。

## 二、准备 Git 身份

只需配置一次：

```powershell
git config --global user.name "你的 GitHub 显示名"
git config --global user.email "你的 GitHub noreply 邮箱"
```

noreply 邮箱可在 GitHub `Settings > Emails` 查看，例如 `123456+name@users.noreply.github.com`。

## 三、初始化本地仓库

```powershell
Set-Location "项目实际路径\codex-feishu-notify-windows"
git init -b main

git add -- `
  .editorconfig .gitattributes .gitignore `
  LICENSE README.md SECURITY.md CONTRIBUTING.md CHANGELOG.md THIRD_PARTY_NOTICES.md `
  .github config docs scripts src tests

git status --short
git diff --cached --check
git diff --cached
```

不要使用 `git add .` 或 `git add -A`。上面的命令只暂存已经审核的项目路径，避免把同目录下的私有文件意外加入。

确认 staged diff 不含秘密后提交：

```powershell
git commit -m "feat: publish initial Codex-to-Feishu notifier"
```

## 四、在 GitHub 创建空仓库

网页方式：

1. 登录 GitHub，点击右上角 `+`，选择 `New repository`。
2. Repository name 填 `codex-feishu-notify-windows`。
3. Description 可填：`Reliable Codex completion notifications to Feishu on Windows.`
4. 首次建议选择 `Private`。
5. 不要勾选 README、`.gitignore` 或 License，因为本地已经存在。
6. 点击 `Create repository`。

## 五、连接并首次推送

将下面的 `YOUR_NAME` 替换成 GitHub 用户名或组织名：

```powershell
git remote add origin https://github.com/YOUR_NAME/codex-feishu-notify-windows.git
git remote -v
git push -u origin main
```

也可以使用 GitHub CLI：

```powershell
gh auth login
gh repo create YOUR_NAME/codex-feishu-notify-windows `
  --private `
  --source . `
  --remote origin `
  --push
```

网页创建和 `gh repo create` 二选一，不要重复添加 `origin`。

## 六、确认 GitHub Actions

进入仓库 `Actions`，打开 `PowerShell checks`。首次运行应在 `windows-latest` 上通过：

- 所有 PowerShell 文件语法正确；
- 18:40–02:00 被计算为 440 分钟和 `PT7H20M`；
- 节假日日间缺口被计算为 1000 分钟和 `PT16H40M`，官方日历可解析且没有重复日期；
- 过滤、脱敏和事件 ID 测试通过；
- `SessionStart → Stop → agent-turn-complete` 完成门、权限等待撤销和旧会话兼容测试通过；
- 飞书卡片 JSON、Windows Toast XML 和结构化发送结果校验通过；
- 含中文的 PowerShell 文件带 UTF-8 BOM，可在 Windows PowerShell 5.1 正确解析；
- 仓库没有已知的本机路径、真实群 ID 或典型密钥。

如果 Actions 未自动启动，检查仓库 `Settings > Actions > General` 是否允许 Actions。

## 七、完善仓库设置

建议设置：

1. `About`：填写描述、MIT License 和 topics：`codex`、`feishu`、`lark`、`windows`、`powershell`、`notifications`。
2. `Settings > Security`：开启 Dependabot alerts、secret scanning、push protection 和 private vulnerability reporting（可用项取决于仓库类型）。
3. `Settings > Branches`：为 `main` 添加保护规则，至少要求 PR 和 Actions 通过。
4. `Settings > Actions > General`：Workflow permissions 设为 `Read repository contents`。
5. 确认 Issue 和 PR 模板能正常显示。

私有仓库检查完成后，若要开源：`Settings > General > Danger Zone > Change repository visibility > Public`。公开前再跑一次发布前检查。

## 八、后续修改使用分支和 Draft PR

```powershell
git switch main
git pull --ff-only
git switch -c feat/short-description

# 修改并测试后，只暂存本次确认的路径
git add -- src/notify.ps1 tests/Test-Project.ps1 README.md
git diff --cached --check
git diff --cached
git commit -m "feat: describe the focused change"
git push -u origin feat/short-description
```

然后在 GitHub 创建 Draft Pull Request：

- base：`main`；
- compare：`feat/short-description`；
- 完成 PR 模板中的测试、调度和泄密检查；
- Actions 通过且人工审核后，再标记 Ready for review 并合并。

## 九、发布 v0.4.0

合并并确认 `main` 通过后：

```powershell
git switch main
git pull --ff-only
git tag -a v0.4.0 -m "Codex Feishu Notify for Windows v0.4.0"
git push origin v0.4.0

pwsh -File .\scripts\New-ReleasePackage.ps1 -Version 0.4.0
```

在 GitHub `Releases > Draft a new release`：

1. 选择 `v0.4.0`；
2. 标题填 `v0.4.0 - Windows scheduling controls`；
3. 使用 `docs/releases/v0.4.0.md` 作为发布说明；
4. 上传 `dist/codex-feishu-notify-windows-v0.4.0.zip` 及其 `.sha256`；
5. 首次可勾选 pre-release 供少量用户验证，确认安装、卸载和临时开始/停止后再转为稳定版。

## 十、每次发布前的最小清单

- [ ] `tests/Test-Project.ps1` 本地和 Actions 均通过。
- [ ] staged diff 已人工检查。
- [ ] 没有真实 chat ID、token、webhook、配置目录、队列或日志。
- [ ] `notify.ps1` 不调用 `Start-ScheduledTask`。
- [ ] 生命周期 Hook 不返回批准、拒绝、阻止或自动继续决定，且安装/卸载只增删本项目处理器。
- [ ] `THIRD_PARTY_NOTICES.md` 与实际借鉴或移植内容一致。
- [ ] 计划任务仍为每日触发，且验证 `DaysInterval=1`。
- [ ] 节假日日期触发器只补齐普通时间窗未覆盖的部分，日历年份和官方来源已复核。
- [ ] 时间窗、升级、卸载和回滚文档与代码一致。
- [ ] `CHANGELOG.md` 和版本标签一致。
