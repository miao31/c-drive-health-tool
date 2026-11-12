@{
    # 可选配置：只影响扫描节奏与报告呈现。
    # 路径清单 $catalog、Guard-Path 守卫与删除逻辑永不从本文件读取。
    # 本文件缺失、解析失败或数值越界时，脚本自动回退内置默认值。
    # 默认不加载，需显式传入 -Config .\tool.config.psd1

    DirTimeoutSec = 20      # 单目录扫描超时秒数，允许 1..3600
    TopFiles      = 20      # 每项列出的最大文件数，允许 1..200
    TopSubdirs    = 10      # 每项列出的最大子目录数，允许 1..200
    ArchiveOnScan = $false  # 只读扫描结束时另存 weekly-report-<yyyyMMdd>.md
    AssessSystemChannelsOnScan = $false  # 只读评估系统官方通道（报告第 11 节 + 状态字段）
}
