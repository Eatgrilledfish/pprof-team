#!/usr/bin/env bash
# bench_verify.sh — 双轴验收脚本：对 before/after 两组基准做 benchstat 统计显著性判定
#
# 调用方：agents/06-optimizer.md 工作流程 1.6「双轴验收」（05-report-architect 的验证计划亦引用本脚本）。
# 全局红线在此落地：benchstat -alpha 0.05 的输出中，ns/op、B/op、allocs/op 三轴
# 任一轴 delta 为正值（变差）且 p<0.05，即判定「否决」（退出码 2）；三轴均无统计
# 显著回归则判定「通过」（退出码 0）。目标轴（TARGET_AXIS=cpu→ns/op，mem→B/op，
# 默认 cpu）要求改善或持平，另一轴与 allocs/op 要求不显著变差。
#
# 用法:
#   bench_verify.sh -pkg <包路径> -bench <Benchmark 正则> -base <before.txt> -out <结果目录>
#   bench_verify.sh --help
#
# 参数:
#   -pkg    被测包路径（相对 GO_PROJECT_DIR），如 ./internal/parser
#   -bench  Benchmark 名称正则（原样传给 go test -bench），如 '^BenchmarkHotFunc$'
#   -base   before 基准文件：go test -benchmem -count=10 的输出原文
#   -out    结果目录：写入 after.txt（after 基准原文）、benchstat.txt（benchstat 输出
#           原文）、verdict.txt（判定结论）；
#           若值以 .txt 结尾则按文件处理：该文件即 after 基准原文，benchstat 原文与
#           判定写入同目录 <名>-benchstat.txt / <名>-verdict.txt
#           （兼容 06-optimizer.md 示例中 -out 指向 bench-<建议ID>-after.txt 的用法）
#
# 环境变量:
#   GO_PROJECT_DIR  被测项目根目录（go.mod 所在），默认当前目录
#   TARGET_AXIS     目标轴：cpu（看 ns/op，默认）| mem（看 B/op）
#   BENCH_COUNT     go test -count 样本组数，默认 10（benchstat 显著性检验的样本量底线，
#                   对应 06 的 -count=10 纪律，禁止削减）
#
# benchstat 获取顺序: PATH 中已有的 benchstat 优先；否则 go run golang.org/x/perf/cmd/benchstat@latest
# （首次运行需联网下载；解析按 x/perf 新版表格输出格式，旧版 rsc benchstat 不在支持范围）。
#
# 退出码:
#   0  通过（三轴均无统计显著回归）
#   2  否决（任一轴出现统计显著回归 p<0.05，须按 06-optimizer 流程回退）
#   1  用法 / 环境错误

set -euo pipefail

ALPHA="0.05"   # benchstat 显著性水平，全局约定固定 0.05，不提供覆盖入口

usage() {
    cat <<'EOF'
用法: bench_verify.sh -pkg <包路径> -bench <Benchmark 正则> -base <before.txt> -out <结果目录>

参数:
  -pkg    被测包路径（相对 GO_PROJECT_DIR），如 ./internal/parser
  -bench  Benchmark 名称正则（原样传给 go test -bench），如 '^BenchmarkHotFunc$'
  -base   before 基准文件：go test -benchmem -count=10 的输出原文
  -out    结果目录（写入 after.txt / benchstat.txt / verdict.txt）；
          若以 .txt 结尾则视为 after 基准文件路径，benchstat 与判定写入同目录
          <名>-benchstat.txt / <名>-verdict.txt（兼容 06-optimizer 的文件形态用法）

环境变量:
  GO_PROJECT_DIR  被测项目根目录（go.mod 所在），默认当前目录
  TARGET_AXIS     目标轴：cpu（看 ns/op，默认）| mem（看 B/op）
  BENCH_COUNT     go test -count 样本组数，默认 10

退出码: 0=通过  2=否决（任一轴 p<0.05 显著回归）  1=用法/环境错误
EOF
}

# ---------- 参数解析 ----------
PKG=""; BENCH_REGEX=""; BASE_FILE=""; OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -pkg)   [[ $# -ge 2 ]] || { echo "错误: -pkg 缺少参数值" >&2; exit 1; }
                PKG="$2"; shift 2 ;;
        -bench) [[ $# -ge 2 ]] || { echo "错误: -bench 缺少参数值" >&2; exit 1; }
                BENCH_REGEX="$2"; shift 2 ;;
        -base)  [[ $# -ge 2 ]] || { echo "错误: -base 缺少参数值" >&2; exit 1; }
                BASE_FILE="$2"; shift 2 ;;
        -out)   [[ $# -ge 2 ]] || { echo "错误: -out 缺少参数值" >&2; exit 1; }
                OUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "错误: 未知参数 $1" >&2; usage >&2; exit 1 ;;
    esac
done
if [[ -z "$PKG" || -z "$BENCH_REGEX" || -z "$BASE_FILE" || -z "$OUT" ]]; then
    echo "错误: -pkg / -bench / -base / -out 均为必填" >&2
    usage >&2
    exit 1
fi

# ---------- 环境与输入校验 ----------
GO_PROJECT_DIR="${GO_PROJECT_DIR:-$(pwd)}"
TARGET_AXIS="${TARGET_AXIS:-cpu}"
BENCH_COUNT="${BENCH_COUNT:-10}"
case "$TARGET_AXIS" in
    cpu) TARGET_METRIC="ns/op" ;;
    mem) TARGET_METRIC="B/op" ;;
    *) echo "错误: TARGET_AXIS 只能是 cpu 或 mem（当前: ${TARGET_AXIS}）" >&2; exit 1 ;;
esac

command -v go >/dev/null 2>&1 || { echo "错误: 未找到 go 命令，请先安装 Go 或检查 PATH" >&2; exit 1; }
[[ -d "$GO_PROJECT_DIR" ]] || { echo "错误: GO_PROJECT_DIR 目录不存在: $GO_PROJECT_DIR" >&2; exit 1; }
[[ -s "$BASE_FILE" ]] || { echo "错误: -base 基准文件不存在或为空: $BASE_FILE" >&2; exit 1; }
grep -q '^Benchmark' "$BASE_FILE" || {
    echo "错误: -base 文件中没有任何 Benchmark 行（应为 go test -benchmem 输出原文）: $BASE_FILE" >&2
    exit 1
}

# ---------- 产物路径 ----------
# -out 为目录：after.txt / benchstat.txt / verdict.txt；
# -out 以 .txt 结尾：视为 after 基准文件（兼容 06-optimizer 的 bench-<建议ID>-after.txt 形态）。
if [[ "$OUT" == *.txt ]]; then
    AFTER_FILE="$OUT"
    BENCHSTAT_OUT="${OUT%.txt}-benchstat.txt"
    VERDICT_FILE="${OUT%.txt}-verdict.txt"
    mkdir -p "$(dirname "$OUT")"
else
    mkdir -p "$OUT"
    AFTER_FILE="$OUT/after.txt"
    BENCHSTAT_OUT="$OUT/benchstat.txt"
    VERDICT_FILE="$OUT/verdict.txt"
fi

# ---------- 1) 采集 after 基准 ----------
# 与 06 的 before 采集口径严格一致：-run '^$' 跳过单测、-benchmem 输出三轴、-count=10 样本量；
# -timeout 放宽到 30m，避免多基准 × 10 组样本触发 go test 默认 10m panic 超时。
cd "$GO_PROJECT_DIR"
echo "-> 采集 after 基准: go test -run '^$' -bench '$BENCH_REGEX' -benchmem -count=$BENCH_COUNT $PKG"
if ! go test -run '^$' -bench "$BENCH_REGEX" -benchmem -count="$BENCH_COUNT" -timeout 30m "$PKG" 2>&1 | tee "$AFTER_FILE"; then
    echo "错误: go test 基准执行失败（输出已存至 ${AFTER_FILE}）" >&2
    exit 1
fi
grep -q '^Benchmark' "$AFTER_FILE" || {
    echo "错误: after 基准输出中没有任何 Benchmark 行，采集失败: $AFTER_FILE" >&2
    exit 1
}

# ---------- 2) benchstat 比较 ----------
if command -v benchstat >/dev/null 2>&1; then
    BENCHSTAT_CMD=(benchstat)
else
    BENCHSTAT_CMD=(go run golang.org/x/perf/cmd/benchstat@latest)
fi
echo "-> benchstat 比较（-alpha ${ALPHA}，before × after）..."
# go run ...@latest 首次需联网解析版本并可能触发工具链切换下载，偶发瞬断；
# 失败时原样重试一次，仍失败才报错退出。
if ! "${BENCHSTAT_CMD[@]}" -alpha "$ALPHA" "$BASE_FILE" "$AFTER_FILE" > "$BENCHSTAT_OUT" 2>&1; then
    echo "-> benchstat 首次执行失败，1s 后重试一次..."
    sleep 1
    if ! "${BENCHSTAT_CMD[@]}" -alpha "$ALPHA" "$BASE_FILE" "$AFTER_FILE" > "$BENCHSTAT_OUT" 2>&1; then
        echo "错误: benchstat 执行失败，输出如下（已存至 ${BENCHSTAT_OUT}）:" >&2
        cat "$BENCHSTAT_OUT" >&2
        exit 1
    fi
fi
cat "$BENCHSTAT_OUT"

# ---------- 3) 解析 benchstat 输出，逐轴判定 ----------
# 输出格式（x/perf 新版）：每个指标一节，表头行含指标名（ns/op|sec/op、B/op、allocs/op）；
# 数据行的基准名不带 "Benchmark" 前缀（benchstat 已剥离），行内必含 "(p=... n=...)"，
# delta 列为 "~"（不显著）或带符号百分比（显著，附 p 值）。
# 解析为逐行记录：指标|基准名|delta|p。
PARSED=$(awk '
    /allocs\/op/     { metric="allocs/op"; next }
    /ns\/op|sec\/op/ { metric="ns/op"; next }
    /B\/op/          { metric="B/op"; next }
    metric != "" && /\(p=/ {
        delta=""; p=""
        for (i=2; i<=NF; i++) {
            if ($i == "~" || $i ~ /^[+-][0-9.]+%$/) delta=$i
            if ($i ~ /^\(p=/) { p=$i; sub(/^\(p=/, "", p) }
        }
        printf "%s|%s|%s|%s\n", metric, $1, delta, p
    }
' "$BENCHSTAT_OUT")
[[ -n "$PARSED" ]] || {
    echo "错误: 未能从 benchstat 输出解析出任何基准数据行（要求 x/perf 新版表格输出）: $BENCHSTAT_OUT" >&2
    exit 1
}

p_significant() {  # $1=p 值；返回 0 表示 p < ALPHA（统计显著）
    [[ "${1:-}" =~ ^[0-9]*\.?[0-9]+$ ]] || return 1
    awk -v p="$1" -v a="$ALPHA" 'BEGIN{ exit !(p < a) }'
}

# classify_row <delta> <p> → 输出 "<code>|<描述>"，code: 0=无显著回归 1=显著回归 2=显著改善
classify_row() {
    local delta="${1:-}" p="${2:-}"
    if [[ -z "$delta" || "$delta" == "~" ]]; then
        echo "0|持平（差异不显著，p=${p:-n/a}）"
    elif [[ "$delta" == +* ]]; then
        if p_significant "$p"; then
            echo "1|显著回归 ${delta}（p=${p}）"
        else
            echo "0|变差但不显著 ${delta}（p=${p:-n/a}）"
        fi
    elif [[ "$delta" == -* ]]; then
        if p_significant "$p"; then
            echo "2|显著改善 ${delta}（p=${p}）"
        else
            echo "0|改善但不显著 ${delta}（p=${p:-n/a}）"
        fi
    else
        echo "0|delta 字段无法识别（${delta}），按持平处理"
    fi
}

NS_ROWS=(); B_ROWS=(); ALLOC_ROWS=()
NS_FAIL=0; B_FAIL=0; ALLOC_FAIL=0
NS_IMPROVED=0; B_IMPROVED=0; ALLOC_IMPROVED=0

# 逐行聚合：同一轴命中多个基准行时取最坏情况——任一行显著回归即该轴回归。
while IFS='|' read -r metric bench delta p; do
    [[ -z "${metric:-}" ]] && continue
    IFS='|' read -r code desc <<< "$(classify_row "$delta" "$p")"
    row="  - ${bench}: ${desc}"
    case "$metric" in
        ns/op)
            NS_ROWS+=("$row")
            [[ "$code" == "2" ]] && NS_IMPROVED=1
            [[ "$code" == "1" ]] && NS_FAIL=1
            ;;
        B/op)
            B_ROWS+=("$row")
            [[ "$code" == "2" ]] && B_IMPROVED=1
            [[ "$code" == "1" ]] && B_FAIL=1
            ;;
        allocs/op)
            ALLOC_ROWS+=("$row")
            [[ "$code" == "2" ]] && ALLOC_IMPROVED=1
            [[ "$code" == "1" ]] && ALLOC_FAIL=1
            ;;
    esac
done <<< "$PARSED"

axis_status() {  # $1=fail 标记 $2=improved 标记 → 轴级结论文字
    if [[ "$1" == "1" ]]; then echo "显著回归"
    elif [[ "$2" == "1" ]]; then echo "显著改善"
    else echo "持平"; fi
}

# ---------- 4) 输出判定结论 ----------
EXIT_CODE=0
{
    echo "==================== bench_verify 双轴验收 ===================="
    echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "包: $PKG    基准正则: $BENCH_REGEX    样本组数: -count=$BENCH_COUNT"
    echo "目标轴: $TARGET_AXIS ($TARGET_METRIC)    显著性水平: alpha=$ALPHA"
    echo "before: $BASE_FILE"
    echo "after : $AFTER_FILE"
    echo "benchstat 原文: $BENCHSTAT_OUT"
    echo ""
    echo "[ns/op] $(axis_status "$NS_FAIL" "$NS_IMPROVED")"
    if [[ ${#NS_ROWS[@]} -gt 0 ]]; then printf '%s\n' "${NS_ROWS[@]}"; else echo "  (benchstat 输出中无 ns/op 行)"; fi
    echo ""
    echo "[B/op] $(axis_status "$B_FAIL" "$B_IMPROVED")"
    if [[ ${#B_ROWS[@]} -gt 0 ]]; then printf '%s\n' "${B_ROWS[@]}"; else echo "  (benchstat 输出中无 B/op 行)"; fi
    echo ""
    echo "[allocs/op] $(axis_status "$ALLOC_FAIL" "$ALLOC_IMPROVED")"
    if [[ ${#ALLOC_ROWS[@]} -gt 0 ]]; then printf '%s\n' "${ALLOC_ROWS[@]}"; else echo "  (benchstat 输出中无 allocs/op 行)"; fi
    echo ""
    if [[ "$NS_FAIL" == "1" || "$B_FAIL" == "1" || "$ALLOC_FAIL" == "1" ]]; then
        EXIT_CODE=2
        echo "判定: 否决"
        echo "原因: 存在统计显著回归（p<${ALPHA}）的轴，违反双轴红线，该变更须回退（流程见 agents/06-optimizer.md 1.6）。"
        [[ "$NS_FAIL" == "1" ]]    && echo "  否决轴: ns/op"
        [[ "$B_FAIL" == "1" ]]     && echo "  否决轴: B/op"
        [[ "$ALLOC_FAIL" == "1" ]] && echo "  否决轴: allocs/op"
    else
        EXIT_CODE=0
        echo "判定: 通过"
        echo "说明: ns/op、B/op、allocs/op 三轴均无统计显著回归（方向改善或 p≥${ALPHA}）。"
        case "$TARGET_METRIC" in
            ns/op) [[ "$NS_IMPROVED" == "1" ]] || echo "提示: 目标轴 ns/op 未显著改善（持平）——不否决，但 verification.md 须如实记录。" ;;
            B/op)  [[ "$B_IMPROVED" == "1" ]]  || echo "提示: 目标轴 B/op 未显著改善（持平）——不否决，但 verification.md 须如实记录。" ;;
        esac
    fi
    echo "=============================================================="
} > "$VERDICT_FILE"
cat "$VERDICT_FILE"
exit "$EXIT_CODE"
