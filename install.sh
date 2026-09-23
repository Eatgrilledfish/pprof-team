#!/usr/bin/env bash
# install.sh — 把 pprof-team 导入目标 Go 项目（如 multica）
#
# 用法:
#   ./install.sh <目标项目根目录>
#   例: ./install.sh /path/to/multica
#
# 行为:
#   1. 把团队文件复制到 <目标项目>/pprof-team/（已存在则覆盖同名文件，不删多余文件）
#   2. 检查目标项目是否已暴露 net/http/pprof，未暴露则打印需要添加的代码片段
#   3. 检查目标项目的 pprof-team/ 是否被 .gitignore 忽略，给出建议
#   4. 打印导入后的环境变量与快速上手命令
#
# 幂等：可重复执行，结果一致。

set -euo pipefail

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
    echo "用法: $0 <目标项目根目录>" >&2
    echo "例:   $0 /path/to/multica" >&2
    exit 1
fi
if [[ ! -f "$TARGET/go.mod" ]]; then
    echo "错误: $TARGET 下没有 go.mod，不是 Go 项目根目录" >&2
    exit 1
fi

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$TARGET/pprof-team"

# 1) 复制团队文件（排除 git 元数据与运行时产物）
mkdir -p "$DEST"
for item in README.md pprof-team.json agents scripts templates; do
    if [[ -e "$SRC/$item" ]]; then
        rm -rf "${DEST:?}/$item"
        cp -R "$SRC/$item" "$DEST/$item"
    fi
done
chmod +x "$DEST"/scripts/*.sh
echo "-> 团队文件已导入: $DEST"

# 2) 检查目标项目是否暴露 pprof（grep 源码中的 net/http/pprof 导入）
echo ""
if grep -rqs --include='*.go' 'net/http/pprof' "$TARGET" --exclude-dir=vendor --exclude-dir=pprof-team; then
    echo "OK  目标项目源码中已发现 net/http/pprof 导入"
else
    echo "!!  目标项目源码中未发现 net/http/pprof 导入，采集前需要在启动代码中加入："
    cat <<'EOF'

        import (
            "net/http"
            _ "net/http/pprof"
            "runtime"
        )

        func main() {
            runtime.SetBlockProfileRate(1)
            runtime.SetMutexProfileFraction(1)
            go func() { _ = http.ListenAndServe("127.0.0.1:6060", nil) }()
            // ... 原有启动逻辑
        }

    验证: 重启服务后执行 curl http://127.0.0.1:6060/debug/pprof/ 能列出清单即就绪。
EOF
fi

# 3) gitignore 建议：pprof-reports/ 是运行时产物，不应进目标项目的版本库
echo ""
GITIGNORE="$TARGET/.gitignore"
if [[ -f "$GITIGNORE" ]] && grep -qs '^pprof-reports/' "$GITIGNORE"; then
    echo "OK  $GITIGNORE 已忽略 pprof-reports/"
else
    echo "pprof-reports/" >> "$GITIGNORE"
    echo "-> 已向 $GITIGNORE 追加 pprof-reports/（分析产物不入库）"
fi

# 4) 打印后续操作
MODULE=$(head -1 "$TARGET/go.mod" | awk '{print $2}')
cat <<EOF

导入完成。后续在 $TARGET 下执行:

  export PPROF_ADDR=http://127.0.0.1:6060   # 目标服务($MODULE)的 pprof 地址，按实际改
  export GO_PROJECT_DIR=$TARGET

  ./pprof-team/scripts/collect_profiles.sh baseline   # 基线窗口采集
  # ...对服务施加代表性负载...
  ./pprof-team/scripts/collect_profiles.sh current    # 对比窗口采集
  ./pprof-team/scripts/diff_profiles.sh               # 生成差分到 pprof-reports/<ts>/diff/

  然后按 agents/02 -> 03 -> 04 -> 05 -> 06 的顺序调度各 agent 完成分析与优化。
EOF
