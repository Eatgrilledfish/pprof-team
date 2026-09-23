# pprof-team — Go 服务 pprof 性能分析多智能体团队

针对 Go 服务（如 multica，Go 1.24，暴露 `net/http/pprof`）的性能分析多智能体团队。团队方法论只有一句话：**基于两期 profile 差分（`go tool pprof -diff_base`）定位 CPU 增长点与内存增长点**，禁止拿单点 `top` 排名当增长结论。

核心红线（全局约定，所有 agent 共同遵守）：

> **双轴不互换**：禁止以牺牲内存换取 CPU 优化，也禁止以牺牲 CPU 换取内存优化。任何优化提案必须论证双轴影响；验收标准为 benchstat 比较中 **ns/op、B/op、allocs/op 三轴任一轴出现统计显著回归（p<0.05）即否决该变更**，无论另一轴改善幅度多大。

本目录参数化、可移植：把 `GO_PROJECT_DIR` 指向任意暴露 `net/http/pprof` 的 Go 项目即可复用全套流程。

## 目录结构

```
pprof-team/
├── README.md                      # 本文件：团队总览与使用手册
├── agents/                        # 六个 agent 的角色定义（prompt），按编号顺序消费
│   ├── 01-profiler-collector.md   # 采集员：两期 profile 成对采集与校验
│   ├── 02-cpu-analyst.md          # CPU 分析：cpu/block/mutex 差分
│   ├── 03-memory-analyst.md       # 内存分析：heap/allocs/goroutine 差分
│   ├── 04-code-correlator.md      # 源码关联：符号→file:line + 优化假设（双轴论证）
│   ├── 05-report-architect.md     # 报告架构师：汇总 report.md，红线最后守门员
│   └── 06-optimizer.md            # 优化实施：唯一改代码的 agent，逐条双轴验收
├── scripts/
│   ├── collect_profiles.sh        # collect_profiles.sh <baseline|current>
│   ├── diff_profiles.sh           # diff_profiles.sh [SESSION_DIR]
│   └── bench_verify.sh            # 双轴验收脚本（06 引用；文件缺失时用 benchstat 等价命令，见"快速上手"第 6 步）
├── templates/
│   └── report-template.md         # report.md 结构模板（05 必须遵循）
└── install.sh                     # 一键导入目标项目：./install.sh /path/to/multica
```

## 导入目标项目（如 multica）

在本仓库根目录执行：

```bash
./install.sh /path/to/multica
```

脚本会把团队复制到 `<目标项目>/pprof-team/`，并自动完成三件事：检查目标项目源码是否已暴露 `net/http/pprof`（未暴露则打印需要添加的代码片段）、向目标项目 `.gitignore` 追加 `pprof-reports/`（分析产物不入库）、打印导入后的环境变量与采集命令。脚本幂等，可重复执行。

也可以不用脚本，手动 `git clone` 本仓库到目标项目根目录，效果相同；脚本只是多做接入检查。

## 六个 agent 一览

| 编号 | name | 职责 | 输入 | 输出 |
|---|---|---|---|---|
| 01 | `pprof-profiler-collector` | 成对采集 baseline/current 六类 profile（cpu/heap/allocs/goroutine/block/mutex），校验完整性并生成差分产物；只采集不分析 | 运行中的目标服务 + `PPROF_ADDR` + 两个采集脚本 | `baseline/`、`current/`、`diff/`、`notes/collector.md` |
| 02 | `pprof-cpu-analyst` | 对 cpu/block/mutex 做两期差分，定位 CPU 增长点，区分业务增长与劣化，联动 block/mutex 判断锁竞争 | cpu/block/mutex 两期 profile、`diff/cpu-diff`、`notes/collector.md` | `notes/cpu-analysis.md`（含"给 04 的待映射符号列表"） |
| 03 | `pprof-memory-analyst` | 对 heap/allocs/goroutine 做两期差分，定位内存增长点，区分真泄漏与高分配率（强制 GC 验证） | heap/allocs/goroutine 两期 profile、`notes/collector.md` | `notes/memory-analysis.md`（含"给 04 的符号列表"） |
| 04 | `pprof-code-correlator` | 把 02/03 的符号清单映射回源码 file:line，逐符号读码，产出带双轴影响论证的优化假设；只读源码 | `notes/cpu-analysis.md`、`notes/memory-analysis.md`、`notes/collector.md`、diff 产物、`GO_PROJECT_DIR` | `notes/code-correlation.md`（假设 ID 形如 `H-04-x-y`） |
| 05 | `pprof-report-architect` | 交叉核对三份笔记与原始 profile（重算 diff 为准），评定 P0–P2 优先级，汇总 report.md；红线进入代码前的最后守门员 | 02/03/04 三份笔记、原始 profile、`diff/*.txt`、`templates/report-template.md` | `report.md`（含优化建议、违规提案隔离区、验证计划） |
| 06 | `pprof-optimizer` | 唯一有权改代码的 agent；按 P0→P1→P2 逐条实施（一次只改一条），benchstat 双轴验收，否决即回退 | `report.md`（已获批条目）、`notes/code-correlation.md`、`GO_PROJECT_DIR` 源码 | 源码改动（每条建议独立 commit）、`notes/bench-<建议ID>-{before,after}.txt`、`notes/verification.md` |

数据流：

```
01-profiler-collector（采集 + 校验 + 差分）
   │  产出：baseline/  current/  diff/  notes/collector.md
   ├──► 02-cpu-analyst ──────► notes/cpu-analysis.md ────┐
   └──► 03-memory-analyst ───► notes/memory-analysis.md ─┤ 并行，GC ↔ alloc 互证
                                 ▼
                    04-code-correlator ──► notes/code-correlation.md
                                 ▼
                    05-report-architect ──► report.md（建议区 + 违规隔离区）
                                 ▼
                    06-optimizer ──► 源码改动 + notes/verification.md
                                 │
                                 └──► 回传 05 更新 report.md"验证结果/实施结果"附录（闭环）
```

## 快速上手

### 前置条件

1. 目标进程已挂载 `net/http/pprof`（默认 `http://127.0.0.1:6060`）：

   ```go
   import _ "net/http/pprof"

   go func() { _ = http.ListenAndServe("127.0.0.1:6060", nil) }()
   ```

2. 建议（非强制）启用 block / mutex 采样，否则这两类 profile 为空、锁竞争结论存在证据缺口：

   ```go
   runtime.SetBlockProfileRate(1)       // block profile：同步阻塞事件采样
   runtime.SetMutexProfileFraction(1)   // mutex profile：互斥锁竞争采样
   ```

   未启用时采集脚本仍会落盘合法的空 profile 并在 `notes/collector.md` 标注 `disabled`；是否开启由服务侧决定，采集 agent 不代为修改源码。

3. 本机 `go` 工具链版本与被分析服务的**构建版本一致**（否则 pprof 符号化错位）；`curl` 可用。
4. `GO_PROJECT_DIR` 指向被分析项目的模块根（`go.mod` 所在目录），`go build ./...` 通过。
5. benchstat 验收需要联网拉取一次 `golang.org/x/perf/cmd/benchstat`（或本机已安装）。
6. 06 实施前 `git status --porcelain` 必须为空（在独立分支 `pprof-opt/<会话ID>` 上实施）。

### 环境变量

| 变量 | 默认值 | 使用方 | 说明 |
|---|---|---|---|
| `PPROF_ADDR` | `http://127.0.0.1:6060` | collect/diff 脚本、01–04 | 目标服务的 pprof 地址 |
| `GO_PROJECT_DIR` | 无（02/03/04/06 必填） | 02/03/04/06 | 被分析项目源码模块根；符号映射、Grep 反查、改码都依赖它 |
| `PROFILE_SECONDS` | `30` | collect_profiles.sh、01 | CPU 采样时长；**两期必须一致**，否则样本总量不可比 |
| `SESSION_DIR` | 未设置时复用 `pprof-reports/.latest`，否则新建 `pprof-reports/<YYYYMMDD-HHMMSS>/` | collect/diff 脚本 | 显式指定会话目录；首采时脚本写入 `.latest` 指针 |
| `PPROF_SESSION_DIR` | 未设置时自动取最新会话目录 | 04/05/06 | agent 定位会话目录的方式；06 未指定时取 `pprof-team/pprof-reports/` 最新目录 |
| `PPROF_REPORTS_DIR` | `pprof-reports` | collect/diff 脚本 | 报告根目录（相对当前工作目录） |
| `TARGET_AXIS` | `both` | 05/06 | 声明本轮优化目标轴：`cpu` / `memory` / `both`；只影响 05 的优先级排序与 06 的验收预期，**不放松"任一轴 p<0.05 回归即否决"的红线** |

### 完整命令序列（以 multica 为例）

以下命令在包含 `pprof-team/` 的工作根目录执行；产物落在当前目录的 `pprof-reports/` 下。

```bash
# ---- 0. 环境准备 ----
export PPROF_ADDR="http://127.0.0.1:6060"
export GO_PROJECT_DIR="/path/to/multica"    # 被分析项目模块根
export PROFILE_SECONDS=30                   # 两期必须一致

# ---- 1. 采集基线：自动创建 pprof-reports/<ts>/ 并写入 .latest ----
./pprof-team/scripts/collect_profiles.sh baseline

# ---- 2. 保持正常业务负载，间隔 ≥5 分钟（建议取业务周期整数倍，如 15 分钟一轮则隔 15/30 分钟）----
#    期间禁止：发布、配置变更、手动 GC、重启；发生任何变更则本次对比作废，新建会话重采

# ---- 3. 采集对比期：自动复用 .latest 指向的同一会话目录 ----
./pprof-team/scripts/collect_profiles.sh current

# ---- 4. 生成差分：diff/{cpu,heap-inuse,heap-alloc,allocs}-diff.txt 与 goroutine-compare.txt ----
./pprof-team/scripts/diff_profiles.sh        # 等价于 ./pprof-team/scripts/diff_profiles.sh "$(cat pprof-reports/.latest)"

# ---- 5. 按序调度分析 agent（每个 agent 按其 agents/0X-*.md 定义执行）----
# 01 已在采集阶段完成。随后：
#   02-cpu-analyst 与 03-memory-analyst 并行 → notes/cpu-analysis.md、notes/memory-analysis.md
#   04-code-correlator                     → notes/code-correlation.md
#   05-report-architect                    → report.md（人工评审并标注"已批准"后才进入 06）

# ---- 6. 06 实施与双轴验收：一次只改一条建议 ----
# 本段在 GO_PROJECT_DIR 内执行（go test / git 需要）；bench_verify.sh 路径按 pprof-team/ 实际位置调整
SESSION_REL="$(cat pprof-reports/.latest)"
export PPROF_SESSION_DIR="$(cd "$(dirname "$SESSION_REL")" && pwd)/$(basename "$SESSION_REL")"   # 转绝对路径，cd 后仍有效
cd "$GO_PROJECT_DIR"
git switch -c "pprof-opt/$(basename "$PPROF_SESSION_DIR")"

# 对每条获批 OPT：先补/复用 benchmark（必须 b.ReportAllocs()），采 before 基线：
go test -run '^$' -bench '^BenchmarkXxx$' -benchmem -count=10 ./internal/xxx \
  | tee "$PPROF_SESSION_DIR/notes/bench-OPT-1-before.txt"

# 改码（go build ./... 通过、既有测试全绿、gofmt 干净），然后验收：
bash pprof-team/scripts/bench_verify.sh \
  -pkg ./internal/xxx -bench '^BenchmarkXxx$' \
  -base "$PPROF_SESSION_DIR/notes/bench-OPT-1-before.txt" \
  -out  "$PPROF_SESSION_DIR/notes/bench-OPT-1-after.txt"

# bench_verify.sh 缺失时的等价命令（与 06 定义一致）：
go test -run '^$' -bench '^BenchmarkXxx$' -benchmem -count=10 ./internal/xxx \
  | tee "$PPROF_SESSION_DIR/notes/bench-OPT-1-after.txt"
go run golang.org/x/perf/cmd/benchstat@latest -alpha 0.05 \
  "$PPROF_SESSION_DIR/notes/bench-OPT-1-before.txt" \
  "$PPROF_SESSION_DIR/notes/bench-OPT-1-after.txt"

# 判定：benchstat 输出 ns/op、B/op、allocs/op 三行，任一行为正 delta（变差）且 p<0.05
#       → 否决该条：git restore -- <文件> 精确回退，记入 notes/verification.md，退回 04 重论证
#       → 三轴均无显著回归且目标轴显著改善：git commit（message 带建议 ID），进入下一条

# ---- 7. 全部通过后：优化后 profile 复测（真实负载端到端确认）----
cd <工作根目录>
go build -o /tmp/multica-opt "$GO_PROJECT_DIR" && /tmp/multica-opt &   # 确保 pprof 监听 $PPROF_ADDR
sleep 5
# 用与 baseline 可比的负载（同一压测脚本、同一 QPS/数据规模）采优化后两期：
SESSION_DIR="pprof-reports/$(date +%Y%m%d-%H%M%S)-after" ./pprof-team/scripts/collect_profiles.sh baseline
#   …施加同样负载、间隔同样时长…
SESSION_DIR="pprof-reports/<ts>-after" ./pprof-team/scripts/collect_profiles.sh current
SESSION_DIR="pprof-reports/<ts>-after" ./pprof-team/scripts/diff_profiles.sh
# 验收：与优化前 baseline 做 -diff_base，目标函数 flat/cum diff 为负，且无新增显著增长点；
#       内存类优化须 alloc_space 与 inuse_space 两视角均无显著正值。
```

## 产物目录结构

一次分析会话的所有产物集中在会话目录 `pprof-reports/<YYYYMMDD-HHMMSS>/`（目录名即会话 ID，按字典序即时间序，禁止手工改名）：

```
pprof-reports/
├── .latest                            # 文本指针：内容为最近一次会话目录路径，collect_profiles.sh 首次调用时写入
└── <YYYYMMDD-HHMMSS>/                 # 会话目录
    ├── baseline/                      # 基线期：cpu/heap/allocs/goroutine/block/mutex .pprof + goroutine.txt
    ├── current/                       # 对比期：同名 6+1 个文件，与 baseline 一一配对（命名零偏差，才可差分）
    ├── diff/                          # 差分产物（diff_profiles.sh 生成）
    │   ├── cpu-diff.txt               #   CPU 差分 top（-diff_base），定位 CPU 增长点
    │   ├── heap-inuse-diff.txt        #   inuse_space 差分，定位堆驻留增长/泄漏
    │   ├── heap-alloc-diff.txt        #   alloc_space 差分，定位分配速率增长（GC 压力）
    │   ├── allocs-diff.txt            #   alloc_objects 差分，对应 allocs/op 轴
    │   └── goroutine-compare.txt      #   goroutine 数量对比 + 两侧 -traces 摘要
    ├── notes/
    │   ├── collector.md               # 01 采集日志：时间窗、负载窗口、block/mutex 启用状态、校验结果
    │   ├── cpu-analysis.md            # 02 CPU 增长点清单 + 待映射符号列表
    │   ├── memory-analysis.md         # 03 内存增长点清单 + 符号列表
    │   ├── code-correlation.md        # 04 符号→源码映射 + 优化假设（五要素 + 双轴论证）
    │   ├── bench-<建议ID>-before.txt  # 06 bench 原始输出（-benchmem -count=10），按建议 ID 命名
    │   ├── bench-<建议ID>-after.txt
    │   └── verification.md            # 06 逐条验收记录：PASS/REJECTED 判定、benchstat 原文、否决轴与 p 值
    └── report.md                      # 05 汇总报告（遵循 templates/report-template.md），含"验证结果"附录待 06 回填
```

约定：

- 交接以文件系统目录为契约，不复制文件、不发消息；下游 agent 通过会话目录定位上游产物。
- 定位会话目录的优先级：显式 `PPROF_SESSION_DIR` > `pprof-reports/.latest` > 最新时间戳目录。
- `diff/` 里只有"减"的结果，没有任何解读；解读是 02/03/04 的职责。
- 优化后复测必须新建会话目录（如 `<ts>-after`），禁止覆盖本次分析会话的 profile。

## 双轴不互换红线（专章）

### 为什么禁止

互换式优化只是**转移成本，不是降低成本**：

- 加缓存 / 常驻大缓冲换 CPU：内存驻留上升 → GC 频率与 GC CPU 上升 → 省下的 CPU 被 GC 吃回去，还附赠堆膨胀风险；
- 预分配远超真实用量换 append 效率：B/op 与 allocs 驻留上升，低流量时段内存白白占用；
- 反过来"用更多 CPU 计算换更少内存"（如每次请求重算可共享的结果）同样只是把账记在另一轴上。

本团队的目标是把整体资源消耗做下去。凡是"一轴改善、另一轴变差"的方案，benchstat 阶段必然被三轴检验拦下，与其在验收时回退，不如在提案阶段就不立项。

### 允许的优化类别（仅六类）

1. **减少实际工作量**（算法降复杂度）；
2. **消除重复计算**（循环不变量外提、包级预编译）；
3. **减少分配**（同时降低 GC CPU 与堆增长，天然双轴共赢）；
4. **修复泄漏**（泄漏修复只降不升，双轴共赢）；
5. **降低锁竞争**（分片锁、原子化；新增内存必须有界）；
6. **减少系统调用**（bufio 批量写等）。

共同特征：**双轴共赢，或单轴改善且另一轴中性**。凡涉及常驻内存（缓存、池、预分配），必须论证"容量有界且与真实用量同阶"，并写上界来源；写不出上界来源的一律不得立项。

### 违规提案的处理流程

1. **04 标记**：只能靠增加常驻内存换 CPU 的假设（无界缓存、无淘汰的全局 memoization、远超用量的预分配）在 `notes/code-correlation.md` 中标记 `状态：[违规-仅附录]`，写入第 4 节违规表，不得进入建议区；拿不准的标 `[需 bench 验证]` 并写明疑点。
2. **05 隔离**：report.md 设"违规提案隔离区"，逐条记录假设内容、违反哪条红线、否决理由（哪一轴会以什么方式回归）、翻案需要补什么证据（回 04 重做双轴论证）。**隔离区留痕供审计，禁止直接删除或弱化为"暂不实施"**。05 是红线进入代码前的最后守门员：双轴论证缺失或空洞的条目一律移入隔离区，不得留在建议区凑数。
3. **06 禁令**：只许实施 report.md"优化建议"章节中已获批的条目；实施中禁止临场改用"有界缓存扩容、预计算大表"这类以内存换 CPU 的兜底方案，一经发现立即停手退回 04。
4. **验收兜底**：benchstat 三轴（`-alpha 0.05`，ns/op、B/op、allocs/op）任一轴正 delta 且 p<0.05 → 该条否决，`git restore -- <文件>` 精确回退，在 `notes/verification.md` 记录否决轴与 p 值，退回 04 重新论证；被否决项在 report.md 中显式标注"已否决 + 否决轴与 p 值"。

## 常见问题

### block / mutex profile 为空怎么办

空 profile 是**合法产物**（`go tool pprof -top` 校验通过），说明服务未启用对应采样器：

- `block` 为空 → 服务侧需 `runtime.SetBlockProfileRate(1)`；
- `mutex` 为空 → 服务侧需 `runtime.SetMutexProfileFraction(1)`。

处理：采集照常进行，`notes/collector.md` 标注 `block=disabled` / `mutex=disabled`；下游分析在报告中写明"锁竞争/阻塞结论证据缺口"，**禁止用空 profile 反推"无竞争"**；需要补证据时由服务侧开启后另行新建会话补采（采集 agent 不代为修改被分析服务源码）。

### 两期流量不可比怎么办

判据：两期流量差**一个数量级**（以 `notes/collector.md` 的负载窗口描述为准），或两期总采样数偏差 > 20–30% 且无法用 `PROFILE_SECONDS` 解释。此时差分结论无效，处置：

- **放弃差分**：退回 01 重新采集——选择负载相近的窗口，或用压测工具对齐两期 QPS/接口 mix/数据规模后重采；
- **对齐窗口**：baseline 与 current 必须覆盖相同负载特征（同一 QPS 量级、同一接口 mix），间隔 ≥5 分钟且取业务周期整数倍，期间禁止发布/变更；
- collector.md 缺失负载记录时，所有量化结论一律降级为"需复测"，不得定级 P0。

### 单点 top 为何不能当增长点结论

单点 `-top` 只描述"现在哪里热"，区分不了**"一直高"与"在增长"**：一个函数常年占 15% CPU 是现状，不是增长点；流量翻倍导致的绝对耗时上升是业务增长，也不是劣化。只有两期差分（`-diff_base`）能给出归一化后的占比增量——**占比上升 = 单位请求成本上升 = 劣化**，这才是优化对象。因此全局约定要求一切"增长点"结论必须来自差分（判定阈值：diff 后占比上升 ≥ 2 个百分点、排名跃升，或调用链级样本增量显著），单点 top 只允许用于建立现状认知；05 汇总报告时的第一遍交叉核对就是用原始 profile 重算 diff，与笔记矛盾时以重算为准。

### 其他

- **`source file not found` / 行号错位**：多为 `-trimpath` 构建或工具链版本不一致。用 `-source_path="$GO_PROJECT_DIR"` 修正；版本不一致时先对齐版本再分析，禁止强行映射。
- **符号在源码中 grep 不到**：二进制与源码不来自同一次构建。以 `git -C "$GO_PROJECT_DIR" log -1` 与 collector.md 的版本信息对照，禁止编造映射。
- **采样噪声边界**：`PROFILE_SECONDS=30` 下 diff 噪声约 ±0.5pp；介于 +0.5 ~ +2pp 的记"观察项"，边界内标"待 01 重采确认"，任何 agent 不得自行补采混入（防止采样窗口口径被破坏）。
