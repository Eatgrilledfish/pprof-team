# 性能分析报告（<会话目录名 YYYYMMDD-HHMMSS>）

<!-- 本模板是 report.md 的唯一结构骨架，由 05-report-architect 填充（见 agents/05-report-architect.md）。
     章节标题与顺序固定，不得删改；每处 <!-- ... --> 注释说明该填什么，定稿时删除全部注释。
     编号契约：增长点 CPU-x / MEM-x，建议 OPT-<n>，隔离区 REJ-<n>；与 notes/ 各文件的 ID 全链一致。 -->

- 会话目录：`pprof-reports/<YYYYMMDD-HHMMSS>/` <!-- 本次会话目录相对路径 -->
- 采集时间窗：baseline `<YYYY-MM-DD HH:MM:SS>` → current `<YYYY-MM-DD HH:MM:SS>`，间隔 N 分钟 <!-- 来自 notes/collector.md 的采集日志 -->
- PPROF_ADDR：`http://127.0.0.1:6060` <!-- 实际采集地址；非默认值时写明覆盖来源 -->
- PROFILE_SECONDS：`30` <!-- CPU 采样时长；两期必须一致，不一致时本报告量化结论全部降级"需复测" -->
- 源码版本：`<git commit sha>`（`git -C "$GO_PROJECT_DIR" log -1`） <!-- 被分析服务版本；两期 profile 必须来自同一 commit -->
- 负载可比性：可比 / 不可比 <!-- 05 第 6 步判定：两期 Duration/总样本比值偏差 > 30% 即不可比，相关结论降级"需复测" -->

# 摘要

<!-- 3–5 条全报告最重要的结论，每条一句话并标注支撑它的增长点编号（CPU-x / MEM-x）；
     只收录"证据充分"项或已显式标注"需复测"的高分结论；禁止出现无编号支撑的结论。 -->

- <!-- 结论 1：……（支撑：CPU-1，OPT-1 预计改善 ns/op 约 XX%） -->
- <!-- 结论 2：……（支撑：MEM-2） -->
- <!-- 结论 3：……（支撑：CPU-3、MEM-1） -->

# CPU 增长点

<!-- 数据口径：go tool pprof -top -nodecount=20 -diff_base baseline/cpu.pprof current/cpu.pprof 的 05 重算值；
     按 |Δflat%| 降序；|Δflat%| < 1pp 的噪声项不入本表，移入附录；
     定性取值仅限：增长 / 下降 / 持平；源码位置为 04 的 file:line 且经 05 行级复核（-list diff > 0）。 -->

| 编号 | 函数 | 包 | diff 占比变化 | 定性 | 源码位置 |
|---|---|---|---|---|---|
| CPU-1 | <!-- 包路径.函数名 --> | <!-- 包路径 --> | <!-- +3.1pp（flat） --> | <!-- 增长 --> | <!-- internal/parser/parser.go:87 --> |
| CPU-2 |  |  |  |  |  |

# 内存增长点

<!-- 与 CPU 表同构；inuse_space 榜与 alloc_space 榜必须分两段列示，
     杜绝把"分配快"与"堆滞留"混为一谈；泄漏定性必须有 inuse 增长支撑，最好附强制 GC（?gc=1）验证。 -->

## inuse_space 榜（驻留 / 泄漏视角）

| 编号 | 函数 | 包 | diff 占比变化 | 定性 | 源码位置 |
|---|---|---|---|---|---|
| MEM-1 | <!-- 包路径.函数名 --> | <!-- 包路径 --> | <!-- +42MB（GC 后不回落） --> | <!-- 泄漏 / 驻留增长 / 正常增长 --> | <!-- internal/cache/cache.go:91 --> |

## alloc_space 榜（分配速率 / GC 压力视角）

| 编号 | 函数 | 包 | diff 占比变化 | 定性 | 源码位置 |
|---|---|---|---|---|---|
| MEM-2 | <!-- 包路径.函数名 --> | <!-- 包路径 --> | <!-- +180MB（约 2.0× 基线速率） --> | <!-- 高分配率 / 正常增长 --> | <!-- internal/parser/parser.go:112 --> |

# 优化建议

<!-- 逐条编号 ### OPT-<n>；排序 P0→P1→P2，同级按 Score 降序（Score = |Δflat%| × F × R，附计算过程）。
     优化类别只能选自全局约定允许类别：减少实际工作量（算法/复杂度）、消除重复计算、减少分配、
     修复泄漏、降低锁竞争、减少系统调用；
     预期双轴收益必须同时给 ns/op 与 B/op（及 allocs/op）两个方向，无推算依据必须标注"估算，待 bench 确认"；
     双轴影响论证是必答字段，须说明为何另一轴不会统计显著回归，禁止套话；
     置信度"需复测"项不得定级 P0，且在交叉核对记录中双写。 -->

### OPT-1

- **对应增长点**：<!-- CPU-1 / MEM-2，可填多个 -->
- **修改点**：<!-- `internal/parser/parser.go:87`（函数名），把什么改成什么，一句话 -->
- **优化类别**：<!-- 减少实际工作量 / 消除重复计算 / 减少分配 / 修复泄漏 / 降低锁竞争 / 减少系统调用 -->
- **预期双轴收益**：<!-- ns/op：-XX%（推算依据…）；B/op：持平（依据…）；allocs/op：-XX%；无推算依据写"估算，待 bench 确认" -->
- **双轴影响论证**：<!-- 引自 notes/code-correlation.md：CPU 轴与内存轴各自的机制，显式声明不存在以一轴换另一轴的机制 -->
- **优先级**：<!-- P0 / P1 / P2，附 Score = |Δflat%| × F × R 代入计算过程 -->
- **置信度**：<!-- 证据充分 / 需复测（需复测写明原因） -->
- **批准状态**：<!-- 待批准 / 已批准——06 只实施"已批准"条目 -->

<!-- 按 OPT-1 的结构复制 OPT-2、OPT-3……，直至覆盖全部通过守门自检的建议；条数须与底稿一致
     （写盘后用 grep -c '^### OPT-' 核对）。 -->

# 违规提案隔离区

<!-- 04 提出但违反双轴不互换红线的假设逐条入区，留痕供审计，禁止直接删除或弱化为"暂不实施"；
     每条注明：假设内容、违反哪条红线、否决理由（哪一轴会以什么方式回归）、翻案需要补什么证据。 -->

### REJ-1（原假设 ID：H-04-x-y）

- **假设内容**：<!-- 一句话 -->
- **违反红线**：<!-- 双轴不互换：以内存换 CPU / 以 CPU 换内存 -->
- **否决理由**：<!-- 哪一轴会以什么方式回归，如：依赖无界缓存，B/op 随 key 空间单调增长 -->
- **翻案条件**：<!-- 回 04 重做双轴论证需补的证据，如：容量有界证明 + 真实用量上界统计 -->

<!-- 无违规提案时写"本期无"，禁止删除本章节。 -->

# 验证计划

<!-- 三步走，命令可直接复制执行；阈值全部量化，禁止"观察一下"式表述。
     实施者：06-optimizer；下列命令中 <RUN_DIR> 指本次会话目录，<NEW_TS> 指优化后新会话目录名。 -->

## 第 1 步：优化后重采（新会话目录，避免覆盖本次 profile）

```bash
cd pprof-team
SESSION_DIR="pprof-reports/$(date +%Y%m%d-%H%M%S)-after" PPROF_ADDR=http://127.0.0.1:6060 PROFILE_SECONDS=30 ./scripts/collect_profiles.sh baseline
SESSION_DIR="pprof-reports/<NEW_TS>-after" PPROF_ADDR=http://127.0.0.1:6060 PROFILE_SECONDS=30 ./scripts/collect_profiles.sh current
```

<!-- 负载要求：与 baseline 采集时同一压测脚本、同一 QPS/数据规模，否则差分不可比、复测无效。 -->

## 第 2 步：重差分并核对阈值

```bash
./scripts/diff_profiles.sh "pprof-reports/<NEW_TS>-after"
go tool pprof -top -nodecount=20 -diff_base <RUN_DIR>/current/cpu.pprof "pprof-reports/<NEW_TS>-after/current/cpu.pprof"
go tool pprof -top -nodecount=20 -sample_index=inuse_space -diff_base <RUN_DIR>/current/heap.pprof "pprof-reports/<NEW_TS>-after/current/heap.pprof"
go tool pprof -top -nodecount=20 -sample_index=alloc_space -diff_base <RUN_DIR>/current/allocs.pprof "pprof-reports/<NEW_TS>-after/current/allocs.pprof"
```

通过阈值（量化）：

- 目标函数 diff 占比回落到 **±1pp 以内**（负值即显著下降，优于阈值）；
- 无任何非目标函数新增 **> 2pp** 的增长（新增长点 = 回归信号）；
- 泄漏类优化必须以 **inuse_space 回落**为准；alloc_space 不降但 inuse 回落时如实记录，不强行判过。

## 第 3 步：benchstat 双轴验收（每条 OPT 各跑一次）

```bash
./scripts/bench_verify.sh \
  -pkg ./path/to/pkg \
  -bench '^BenchmarkHotFunc$' \
  -base "<RUN_DIR>/notes/bench-<OPT-ID>-before.txt" \
  -out "<RUN_DIR>/notes/bench-<OPT-ID>-after.txt"
```

通过阈值（benchstat `-alpha 0.05`，基准以 `-benchmem -count=10` 采集）：

- benchstat 输出中 ns/op、B/op、allocs/op 三行指标，**任一轴 delta 为正值（变差）且 p < 0.05，即判定该 OPT 不通过**（否决并回退）；
- 目标轴（`TARGET_AXIS=cpu` 看 ns/op，`TARGET_AXIS=mem` 看 B/op）须改善或持平，其余轴不显著变差；
- benchstat 输出原文由 bench_verify.sh 保存到 `-out` 目录，06 原样粘贴进 verification.md，禁止手改数字。

# 交叉核对记录

<!-- 如实记录 05 工作流程第 2–6 步的核对过程，保证每个报告数字可追溯到 notes、diff/*.txt 或 pprof 命令输出：
     - 与 02/03/04 笔记的分歧及裁决（一律以 pprof 重算为准，分歧原样记录，禁止调和）；
     - 负载可比性判定（两期 Duration/总样本比值 vs collector.md 时间窗与流量，偏差 > 30% 即不可比）；
     - GC ↔ alloc 互证结论（GC 相关函数合计 diff 上升 > 2pp 时，alloc 榜须能把锅指回同一批业务分配点）；
     - 行级复核结果（04 标注行 diff ≤ 0 或无样本的，标"行级证据不足"，置信度降级）。 -->

| 核对项 | 笔记声称 | 重算结果 | 裁决 |
|---|---|---|---|
| <!-- CPU-1 diff 占比 --> |  |  | <!-- 一致 / 以重算为准，分歧已退回 02 --> |
| <!-- 负载可比性 --> |  |  | <!-- 可比 / 不可比，相关结论降级"需复测" --> |
| <!-- GC ↔ alloc 互证 --> |  |  |  |

# 验证结果附录

<!-- 初稿固定标注"待 06 回填"；06 完成后由 05 更新。
     按建议 ID 逐项引用 notes/verification.md 的 PASS / REJECTED 判定；
     benchstat 原文只引用路径 + 粘贴关键行，数字不得手改；
     被否决项在此显式标注"已否决 + 否决轴与 p 值"，并注明已退回 04-code-correlator 重新论证。 -->

**状态**：待 06 回填

| OPT 编号 | 判定 | benchstat 三轴结论（含 p 值） | benchstat 原文路径 | 复测会话目录 |
|---|---|---|---|---|
| OPT-1 | <!-- PASS / REJECTED --> | <!-- ns/op -10.9% p=0.000；B/op ~ p=0.310；allocs/op ~ p=0.080 --> | <!-- notes/bench-OPT-1-after-benchstat.txt --> | <!-- pprof-reports/<NEW_TS>-after --> |

## 优化后 profile diff 摘要

<!-- 由 06 回填：目标函数 flat/cum 从 X% 降至 Y%（diff 为负）；top 中无新增显著增长点；
     内存项 alloc_space / inuse_space 变化摘要；负载方式与 baseline 可比的说明。 -->
