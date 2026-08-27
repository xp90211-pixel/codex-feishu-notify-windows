# 节假日日历维护

## 运行语义

日历只决定哪些日期放宽为全天运行，不改变普通日的固定时间窗。默认 18:40–次日 02:00 已覆盖节假日当天的两个边缘区间，安装器会为每个节假日增加 02:00–18:40 的一次性日期触发器。普通周末不会自动视为节假日，但可以在图形设置器中把任意周一至周日选为固定“全天运行日”；安装器会以每周触发器补齐同一时间缺口。

节假日日历与固定全天运行日可以叠加。某个节假日若恰好落在已选星期，该星期的每周触发器已经覆盖全天，安装器会跳过重复的一次性节假日触发器。

## 内置日历

| 文件 | 范围 | 官方来源 |
|---|---|---|
| `config/holidays.sg.json` | 新加坡 2026–2027 | 新加坡人力部 2026、2027 公共假日公告 |
| `config/holidays.cn.2026.json` | 中国 2026 | 国务院办公厅 2026 年部分节假日安排 |

- 新加坡人力部：[2026 年公告](https://www.mom.gov.sg/newsroom/press-releases/2025/0616-public-holidays-for-2026)、[2027 年公告](https://www.mom.gov.sg/newsroom/press-releases/2026/0618-public-holidays-for-2027)
- 中国国务院办公厅：[2026 年公告](https://www.gov.cn/zhengce/zhengceku/202511/content_7047091.htm)

新加坡星期日公共假日依法顺延到星期一，因此原日期和 observed 日期都列入日历。中国日历的 `holidays` 是官方放假日期；调休上班日另记在 `workdays`，便于审计，但不会创建全天触发器。

## 自定义格式

```json
{
  "schema": 1,
  "region": "SG",
  "timezone": "Singapore Standard Time",
  "source": {
    "name": "Official publisher",
    "url": "https://official.example/holiday-notice",
    "retrieved": "2026-08-22"
  },
  "holidays": [
    { "date": "2027-01-01", "name": "New Year's Day" },
    { "date": "2027-02-08", "name": "Observed holiday", "observed": true }
  ],
  "workdays": []
}
```

要求：

- `region` 非空；
- `holidays` 至少有一个日期；
- 日期严格使用 `yyyy-MM-dd`，不得重复；
- 只收录官方确认的放假日和顺延假日；
- 官方公告发生修订时，以最新公告为准。

通过 `-HolidayCalendarPath` 安装自定义文件。安装器会验证并复制成被 Git 忽略的 `holidays.local.json`，然后只为当天及未来日期创建触发器。

## 年度更新流程

1. 等待主管机关发布下一年度正式日历，不根据预测网站预填。
2. 对照公告逐日更新对应 JSON，同时更新来源 URL 和 `retrieved`。
3. 运行 `pwsh -File .\tests\Test-Project.ps1`。
4. 在测试电脑以隔离任务名安装，核对每日触发器、日期触发器数量和持续时间。
5. 重新运行正式安装器并执行 `scripts/Test-Configuration.ps1`。

Windows 单个任务最多容纳 48 个触发器。项目将持久触发器限制为 47 个，预留 1 个给图形设置器的临时“马上开始”功能；追加新年度前应移除已过期且不再需要审计的日期，或拆分为新的年度文件。
