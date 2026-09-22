#!/usr/bin/env bash
# diff_profiles.sh — 对 baseline / current 两个时间点的 profile 做差分
#
# 用法:
#   diff_profiles.sh [SESSION_DIR]
#   不传参数时依次回退：环境变量 SESSION_DIR、PPROF_SESSION_DIR、pprof-reports/.latest。
#
# 前置条件:
#   $SESSION_DIR/baseline/ 与 $SESSION_DIR/current/ 均已由 collect_profiles.sh 采集完成。
#
# 产物（写入 $SESSION_DIR/diff/）:
#   cpu-diff.txt           CPU 差分（-diff_base），定位 CPU 增长点
#   heap-inuse-diff.txt    堆存活空间差分（-sample_index=inuse_space），定位内存增长
#   heap-alloc-diff.txt    累计分配空间差分（-sample_index=alloc_space），定位分配增长
#   allocs-diff.txt        累计分配对象数差分（-sample_index=alloc_objects）
#   goroutine-compare.txt  goroutine 数量对比 + 两侧 -traces 摘要
#
# 判读要点:
#   diff 输出中 Flat/Cum 列为 current 相对 baseline 的变化量，正值即“增长点”；
#   重点看 diff 后排名上升且 flat 增量占比较高的函数，单点 top 不能作为增长点证据。

set -euo pipefail

SESSION_DIR="${1:-${SESSION_DIR:-${PPROF_SESSION_DIR:-}}}"
REPORTS_DIR="${PPROF_REPORTS_DIR:-pprof-reports}"

if [[ -z "$SESSION_DIR" ]]; then
    if [[ ! -f "$REPORTS_DIR/.latest" ]]; then
        echo "错误: 未找到 $REPORTS_DIR/.latest，请先运行 collect_profiles.sh 采集 baseline 和 current" >&2
        exit 1
    fi
    SESSION_DIR="$(cat "$REPORTS_DIR/.latest")"
fi

BASE="$SESSION_DIR/baseline"
CUR="$SESSION_DIR/current"
if [[ ! -d "$BASE" || ! -d "$CUR" ]]; then
    echo "错误: $SESSION_DIR 下必须同时存在 baseline/ 与 current/（当前缺失其一）" >&2
    exit 1
fi
for f in cpu.pprof heap.pprof allocs.pprof goroutine.pprof; do
    if [[ ! -f "$BASE/$f" || ! -f "$CUR/$f" ]]; then
        echo "错误: 缺少 $f，请确认两个时间点均已完整采集" >&2
        exit 1
    fi
done

mkdir -p "$SESSION_DIR/diff"
DIFF="$SESSION_DIR/diff"
echo "会话目录: $SESSION_DIR"

# 1) CPU 差分：-diff_base <base> <current>，flat/cum 为两个采样窗口的差值，
#    正值函数即 CPU 增长点。解读时优先看 flat 增量大的叶子函数。
echo "-> 生成 CPU 差分..."
go tool pprof -top -diff_base="$BASE/cpu.pprof" "$CUR/cpu.pprof" > "$DIFF/cpu-diff.txt"

# 2) 堆存活空间差分：inuse_space 回答“当前比基线多占了多少存活堆内存”，
#    是判断内存增长/泄漏的核心证据。
echo "-> 生成 heap inuse_space 差分..."
go tool pprof -top -sample_index=inuse_space -diff_base="$BASE/heap.pprof" \
    "$CUR/heap.pprof" > "$DIFF/heap-inuse-diff.txt"

# 3) 累计分配空间差分：alloc_space 回答“分配速率是否上升”，
#    区分是“分配变多”还是“对象没释放”（结合 inuse 一起看）。
echo "-> 生成 heap alloc_space 差分..."
go tool pprof -top -sample_index=alloc_space -diff_base="$BASE/heap.pprof" \
    "$CUR/heap.pprof" > "$DIFF/heap-alloc-diff.txt"

# 4) 累计分配对象数差分：alloc_objects 定位分配次数增长，
#    直接对应 allocs/op 轴，佐证“减少分配”类优化。
echo "-> 生成 allocs 差分（alloc_objects）..."
go tool pprof -top -sample_index=alloc_objects -diff_base="$BASE/allocs.pprof" \
    "$CUR/allocs.pprof" > "$DIFF/allocs-diff.txt"

# 5) goroutine 对比：debug=1 文本首行为 "goroutine profile: total N"，取 N 做数量对比；
#    兼容 debug=2 格式（每个 goroutine 以 "goroutine <id> [" 开头）时退化为按行计数。
#    再各取 -traces 前 60 行作为摘要，暴露新增的阻塞/泄漏栈。
echo "-> 生成 goroutine 对比..."
gcount() {
    local f="$1" n
    n=$(awk '/^goroutine profile: total/ {print $NF; exit}' "$f")
    if [[ -z "$n" ]]; then
        n=$(grep -c '^goroutine ' "$f" || true)
    fi
    echo "$n"
}
BASE_GCOUNT=$(gcount "$BASE/goroutine.txt")
CUR_GCOUNT=$(gcount "$CUR/goroutine.txt")
{
    echo "baseline goroutines: $BASE_GCOUNT"
    echo "current  goroutines: $CUR_GCOUNT"
    echo "delta: $((CUR_GCOUNT - BASE_GCOUNT))"
    echo ""
    echo "===== baseline -traces (前 60 行) ====="
    go tool pprof -traces -nodecount=1 "$BASE/goroutine.pprof" 2>/dev/null | head -60 || echo "(baseline -traces 解析失败)"
    echo ""
    echo "===== current -traces (前 60 行) ====="
    go tool pprof -traces -nodecount=1 "$CUR/goroutine.pprof" 2>/dev/null | head -60 || echo "(current -traces 解析失败)"
} > "$DIFF/goroutine-compare.txt"

# 输出清单与交接提示
echo ""
echo "差分完成，清单如下:"
ls -lh "$DIFF"
echo ""
echo "交接提示:"
echo "  - cpu-diff.txt                        -> 交给 pprof-cpu-analyst，定位 CPU 增长点"
echo "  - heap-inuse-diff.txt / heap-alloc-diff.txt / allocs-diff.txt -> 交给 pprof-memory-analyst，定位内存与分配增长点"
echo "  - goroutine-compare.txt               -> 交给 pprof-memory-analyst（goroutine 泄漏排查）"
