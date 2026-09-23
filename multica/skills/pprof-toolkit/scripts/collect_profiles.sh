#!/usr/bin/env bash
# collect_profiles.sh — 采集 baseline / current 两个时间点的 pprof profile
#
# 用法:
#   collect_profiles.sh <baseline|current>
#
# 环境变量:
#   PPROF_ADDR      被分析服务的 pprof 地址，默认 http://127.0.0.1:6060
#   PROFILE_SECONDS CPU profile 采样时长（秒），默认 30
#   SESSION_DIR     会话目录；未设置时回退读取 PPROF_SESSION_DIR（04/05/06 号 agent 的命名）；
#                   两者都未设置时自动创建 pprof-reports/<YYYYMMDD-HHMMSS>/，
#                   并在首次调用时写入 pprof-reports/.latest 供后续调用复用同一会话
#
# 产物:
#   $SESSION_DIR/<mode>/{cpu.pprof,heap.pprof,allocs.pprof,goroutine.pprof,goroutine.txt,block.pprof,mutex.pprof}
#   其中 goroutine.txt 为 debug=1 文本格式，供 diff_profiles.sh 做 goroutine 数量对比。

set -euo pipefail

MODE="${1:-}"
if [[ "$MODE" != "baseline" && "$MODE" != "current" ]]; then
    echo "用法: $0 <baseline|current>" >&2
    exit 1
fi

PPROF_ADDR="${PPROF_ADDR:-http://127.0.0.1:6060}"
PROFILE_SECONDS="${PROFILE_SECONDS:-30}"
REPORTS_DIR="${PPROF_REPORTS_DIR:-pprof-reports}"

# 前置检查：必须能找到 go 工具，且目标 pprof 端口可达
if ! command -v go >/dev/null 2>&1; then
    echo "错误: 未找到 go 命令，请先安装 Go 或检查 PATH" >&2
    exit 1
fi
if ! curl -fsS --max-time 5 "$PPROF_ADDR/debug/pprof/" >/dev/null 2>&1; then
    echo "错误: 无法访问 $PPROF_ADDR/debug/pprof/，请确认目标服务已暴露 net/http/pprof" >&2
    exit 1
fi

# 兼容 04/05/06 号 agent 使用的 PPROF_SESSION_DIR 命名（显式 SESSION_DIR 优先）
SESSION_DIR="${SESSION_DIR:-${PPROF_SESSION_DIR:-}}"

# 会话目录解析：显式 SESSION_DIR 优先；否则复用 .latest；否则新建时间戳目录
if [[ -z "${SESSION_DIR:-}" ]]; then
    if [[ -f "$REPORTS_DIR/.latest" ]]; then
        SESSION_DIR="$(cat "$REPORTS_DIR/.latest")"
    else
        SESSION_DIR="$REPORTS_DIR/$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$SESSION_DIR"
        echo "$SESSION_DIR" > "$REPORTS_DIR/.latest"
    fi
fi
mkdir -p "$SESSION_DIR/$MODE"
echo "会话目录: $SESSION_DIR (mode=$MODE, addr=$PPROF_ADDR, cpu_seconds=$PROFILE_SECONDS)"

OUT="$SESSION_DIR/$MODE"

# 1) CPU profile：采样 PROFILE_SECONDS 秒，反映该窗口内各函数的 CPU 耗时占比
echo "-> 采集 cpu profile（${PROFILE_SECONDS}s）..."
curl -fsS "$PPROF_ADDR/debug/pprof/profile?seconds=$PROFILE_SECONDS" -o "$OUT/cpu.pprof"

# 2) heap profile：堆内存快照（默认 inuse_space 视图），用于定位存活对象占用
echo "-> 采集 heap profile..."
curl -fsS "$PPROF_ADDR/debug/pprof/heap" -o "$OUT/heap.pprof"

# 3) allocs profile：进程启动以来全部分配的累计视图，用于定位分配热点
echo "-> 采集 allocs profile..."
curl -fsS "$PPROF_ADDR/debug/pprof/allocs" -o "$OUT/allocs.pprof"

# 4) goroutine profile：二进制格式供 pprof -traces；文本格式（debug=1）供数量对比
echo "-> 采集 goroutine profile..."
curl -fsS "$PPROF_ADDR/debug/pprof/goroutine" -o "$OUT/goroutine.pprof"
curl -fsS "$PPROF_ADDR/debug/pprof/goroutine?debug=1" -o "$OUT/goroutine.txt"

# 5) block profile：同步阻塞事件（需在代码中启用 block profile rate 才有数据）
echo "-> 采集 block profile..."
curl -fsS "$PPROF_ADDR/debug/pprof/block" -o "$OUT/block.pprof"

# 6) mutex profile：互斥锁竞争事件（需在代码中设置 mutex profile fraction 才有数据）
echo "-> 采集 mutex profile..."
curl -fsS "$PPROF_ADDR/debug/pprof/mutex" -o "$OUT/mutex.pprof"

# 逐个校验：go tool pprof 能解析且至少能输出 top 视图，才认为采集有效。
# -nodecount=1 只取第 1 行，纯粹做“文件可解析”的烟雾校验，输出丢弃。
echo "-> 校验 profile 合法性..."
for f in cpu.pprof heap.pprof allocs.pprof goroutine.pprof block.pprof mutex.pprof; do
    if ! go tool pprof -top -nodecount=1 "$OUT/$f" >/dev/null 2>&1; then
        echo "错误: $OUT/$f 不是合法的 pprof 文件（采集失败或服务端返回非 protobuf 内容）" >&2
        exit 1
    fi
done

# 采集清单
echo ""
echo "采集完成，清单如下:"
ls -lh "$OUT"
echo ""
echo "下一步: 对另一时间点再次执行本脚本（baseline/current 各一次），"
echo "        然后运行 scripts/diff_profiles.sh 生成差分，交给 cpu-analyst / memory-analyst。"
