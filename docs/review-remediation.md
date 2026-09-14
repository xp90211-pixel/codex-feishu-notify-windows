# v0.6 审阅整改记录

基于用户提供的审阅结论，整改对象是 v0.5.0。保留真实时间窗触发器，不改成全天启动后再空转退出；保留单向通知边界，不加入远程审批或终端输入。

## 修复与验证对应

| 问题 | 实现 | 验证 |
|---|---|---|
| notify 落入末尾表、多行替换残留 | 管理模块共用完整 TOML 解析和闭合检查，只替换经过根节点探针验证的完整片段 | Reliability：根级、多行/注释、移除恢复、损坏 TOML；InstallTransaction：完整安装/卸载 |
| Windows PS 5.1 中文损坏 | 配置显式 UTF-8 读写，拒绝非法 UTF-8，非 ASCII 脚本保留 BOM | 两版 PowerShell，中文目录和 BOM-less config |
| 非 JSON/空白回包误判成功 | 严格回执、stdout/stderr 分离、原生参数转义、超时、先保存回执 | 原生 EXE 模拟空白、未知 JSON、错误码、非零退出、挂起；检查队列与 message ID |
| 并发/关闭后继续发送 | 排空互斥锁，开关与实际提交共用状态锁，每次提交前重读配置 | 两个 worker 并发，在首条在途时关闭，后续不再提交 |
| 授权同工具请求混淆 | 每请求文件，有 ID 的墓碑，无 ID 的 epoch + 代数，输入递归排序后哈希；同步本地 Hook | 多请求、无关 PostToolUse、明确请求匹配、迟到重放、本地代数；既有 Hook 进程测试 |
| 敏感内容与升级配置复位 | 摘要默认关闭，JSON 递归脱敏，默认→已有→显式合并 | JSON 嵌套 token/secret/password，扩展字段、超时和保留期升级不变 |
| 非托管首发进程绕过总开关 | 删除 GUI 直接 drain 启动，改用两秒后命名临时触发器；delivery.enabled 为运行时总开关 | ManualTaskControl：临时开始/暂停触发器往返；并发测试 |
| 安装非事务化、触发器过多 | 先生成/验证计划，备份再部署，异常还原文件/Hook/任务 XML，拒绝陈旧预检写入 | 注册后注入故障；60 日期的过大日历；同路径自定义日历 |
| emoji 越界 | ConvertFromUtf32 | 文本消息渲染路径 |
| DryRun 写状态或移动队列 | 只读分类和本地预览，不调用 CLI、不清理、不写日志 | 对整个运行目录文件哈希与时间戳做前后比较 |
| 诊断累计过去假日 | 安装/诊断使用同一计划，逐项比较触发器，忽略过去的单次触发器 | 共享生成器及事务检查 |
| 卸载误选任务/残留引用删除 | 默认读取安装记录任务名，校验所属动作；仍有引用拒绝 RemoveData | 自定义任务名卸载；显式不匹配拒绝 |
| CODEX_HOME | 统一读取自定义 Codex 根目录 | 隔离中文 CODEX_HOME 下安装/保存/卸载 |
| 无界状态与日志 | 日志 2 MiB × 当前及 3 个历史；清理 sent/expired/suppressed 和过期 waiting/ready/completion/generation/tombstone | 状态保留期测试；状态计数只显示有效记录 |
| 桌面状态原文误匹配 | 只读取已知 JSON 容器和字段；false 优先、未知不通过 | 明确 false 覆盖旧标题；无关字符串不通过 |
| 保存=重新安装 | SettingsOnly 不部署脚本、改 Hook 或 notify；仅时间变化重建任务 | 配置字节与任务 XML 不变性测试 |
| 状态缺少可操作信息 | 首页阻塞原因、下次允许时间、实际回执、有效计数；需确认的固定内容测试按钮 | GUI 模型与安装器 GUI 冒烟 |
| 打包可能混入未跟踪私有文件 | release-files.txt 逐文件复制；成品 ZIP 完整性、路径、隐私扫描；固定解析器 SHA-256 | 安装器打包/解包/重复安装与危险载荷拒绝 |

## 测试

在 Windows 上运行：

```powershell
pwsh -File .\tests\Test-Project.ps1
pwsh -File .\tests\Test-Reliability.ps1
pwsh -File .\tests\Test-InstallTransaction.ps1
powershell.exe -NoProfile -File .\tests\Test-Reliability.ps1
powershell.exe -NoProfile -File .\tests\Test-InstallTransaction.ps1
pwsh -File .\tests\Test-ManualTaskControl.ps1
pwsh -File .\tests\Test-OneClickInstaller.ps1
```

可靠性测试仅调用本地 C# CLI 模拟器，不联网发送消息。安装测试使用随机临时目录、禁用的独立计划任务和自定义 CODEX_HOME，结束后清理测试资源，不修改日常通知配置。

## 明确保留的限制

- 安装失败自动恢复针对捕获到的失败；断电、进程被强杀或磁盘故障不能视为跨文件/任务调度器的 ACID 事务，备份需保留。
- 关闭后不会再发起下一条请求；已提交给飞书的在途请求不能撤回。跨崩溃重试依赖飞书幂等键的服务端保证，不声称 exactly-once。
- 官方 PermissionRequest 没有保证提供稳定 request ID。无 ID 的重复事件不能同时做到完美去重和不漏报；多义工具完成不会猜测清理，等待会在回合/会话结束或 TTL 后失效。同步本地 Hook 缩小乱序窗口，不假装解决任意外部乱序。
- 桌面登记不是公开稳定索引，也不是授权来源。未知结构会停止通过该过滤器，需要更新适配或由用户明确关闭过滤。
- 脱敏是辅助措施。开启预览后仍可能包含无法识别的业务敏感内容；旧安装保留既有开关。
- 自定义任意 shell 包装器不自动执行；支持 EXE 与已知官方 npm CLI 包装器。真实认证、真实通知和 Codex Hook 信任仍须由用户验证。
- 保留 Windows 时间窗方案及 47 个持久触发器限制，内置日历仍需随官方年度数据更新。暂停/关闭期间没有额外全天维护进程；保留期清理在实际排空运行时进行。
