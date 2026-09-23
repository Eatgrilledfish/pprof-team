---
name: pprof-toolkit
description: pprof 分析工具包与全局约定 —— pprof-team 小队所有成员共用：采集/差分/双轴验收脚本、报告模板、环境变量与会话目录契约、双轴不互换红线。任何涉及 pprof 采集、差分、benchmark 验收的工作都需要本工具包。
---

# 使命

为 pprof-team 小队的全部角色提供共享工具与统一约定：三个脚本（采集、差分、双轴验收）、报告模板、环境变量契约、产物目录结构、双轴不互换红线。本 skill 不含分析流程，分析流程在各角色 skill 中。

# 支持文件

```
scripts/collect_profiles.sh   # 成对采集两期 profile：collect_profiles.sh <baseline|current>
scripts/diff_profiles.sh      # 生成两期差分：diff_profiles.sh [SESSION_DIR]
scripts/bench_verify.sh       # benchstat 双轴验收：bench_verify.sh -pkg <包> -bench <正则> -base <before.txt> -out <目录>
templates/report-template.md  # 最终报告 report.md 的结构模板（05 号角色必须遵循）
```

# 环境变量契约

| 变量 | 默认值 | 用途 |
|---|---|---|
| `PPROF_ADDR` | `http://127.0.0.1:6060` | 被分析服务的 pprof 地址 |
| `GO_PROJECT_DIR` | `.` | 被分析项目源码路径（行号解析与 Grep 反查依赖它，版本须与线上构建一致） |
| `PROFILE_SECONDS` | `30` | CPU profile 采样时长（秒） |
| `SESSION_DIR` | 自动创建 | 分析会话目录；未设置时创建 `pprof-reports/<YYYYMMDD-HHMMSS>/` 并写入 `.latest` |
| `PPROF_SESSION_DIR` | — | `SESSION_DIR` 的兼容别名（分析/实施角色使用） |
| `TARGET_AXIS` | `cpu` | bench_verify.sh 的目标优化轴：`cpu` 或 `mem` |

# 产物目录结构

```
pprof-reports/<YYYYMMDD-HHMMSS>/
├── baseline/   # 基线 profile：cpu/heap/allocs/goroutine/block/mutex .pprof（+ goroutine.txt）
├── current/    # 对比期 profile，命名与 baseline 一致
├── diff/       # 差分产物：cpu-diff.txt、heap-inuse-diff.txt、heap-alloc-diff.txt、
│               # allocs-diff.txt、goroutine-compare.txt
├── notes/      # 各角色笔记：collector.md、cpu-analysis.md、memory-analysis.md、
│               # code-correlation.md、verification.md
└── report.md   # 最终报告（05 产出，06 回填验证结果）
```

# 增长点定义

增长点必须基于 baseline/current 两期 profile 差分（`go tool pprof -diff_base`），禁止用单点 top 当增长结论。两期流量差一个数量级时，差分结论无效，需重新采集。

# 红线约束（全员适用）

**禁止以牺牲内存换取 CPU 优化，也禁止以牺牲 CPU 换取内存优化。**

- 任何优化提案必须论证双轴影响（CPU 轴与内存轴各自为何改善或中性）；
- 验收标准：benchstat 比较 ns/op、B/op、allocs/op，任一轴统计显著回归（p<0.05）即否决并回退该变更；
- 允许的优化类别：减少实际工作量（算法/复杂度）、消除重复计算、减少分配（同时降低 GC CPU 与堆增长）、修复泄漏、降低锁竞争、减少系统调用；
- 违反红线的假设必须标记违规、只入报告"违规提案隔离区"留痕，不得进入建议区。

# 使用注意

- 脚本支持文件随本 skill 提供给智能体；执行时先 `chmod +x`（若权限丢失），按上表设好环境变量再调用。
- block/mutex profile 为空说明服务端未启用 `runtime.SetBlockProfileRate` / `runtime.SetMutexProfileFraction`，此时锁竞争结论必须标注"证据缺口"，禁止用空 profile 反推"无竞争"。
