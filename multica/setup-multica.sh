#!/usr/bin/env bash
# setup-multica.sh — 把 pprof-team 小队部署到 Multica 工作区
#
# 用法:
#   ./setup-multica.sh --runtime-id <运行时ID> [--model <模型>] [--squad-name pprof-team]
#
# 前置条件:
#   1. 已安装并登录 Multica CLI（multica auth status 正常）
#   2. 目标运行时（--runtime-id）上已安装至少一个编码智能体 CLI（如 kimi / claude）
#   3. 本机有 zip 和 python3 或 jq（解析 CLI 的 JSON 输出）
#
# 行为（幂等，可重复执行）:
#   1. 把 multica/skills/ 下 7 个 skill 目录打包成 .skill 并逐个 multica skill import
#      （同名冲突时跳过导入、复用工作区已有同名 skill 的 id）
#   2. 创建 6 个智能体（已存在同名则复用），instructions 指向各自 skill
#   3. 给每个智能体绑定「自己的角色 skill + pprof-toolkit」
#   4. 创建小队 pprof-team 并把 6 个智能体加为成员，leader 设为 pprof-report-architect
#
# 说明: CLI flag 以 multica.ai/docs/zh/cli 为准；不同版本如有出入，以本机
#       `multica <command> --help` 为准微调本脚本。

set -euo pipefail

RUNTIME_ID=""
MODEL=""
SQUAD_NAME="pprof-team"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --runtime-id) RUNTIME_ID="$2"; shift 2 ;;
        --model)      MODEL="$2"; shift 2 ;;
        --squad-name) SQUAD_NAME="$2"; shift 2 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$RUNTIME_ID" ]]; then
    echo "用法: $0 --runtime-id <运行时ID> [--model <模型>] [--squad-name pprof-team]" >&2
    echo "运行时 ID 用 multica runtime list 查看" >&2
    exit 1
fi

command -v multica >/dev/null || { echo "错误: 未找到 multica CLI，请先安装并登录" >&2; exit 1; }
multica auth status >/dev/null 2>&1 || { echo "错误: multica 未登录，请先 multica setup / multica login" >&2; exit 1; }

SKILLS_DIR="$(cd "$(dirname "$0")/skills" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 从 CLI 的 JSON 输出按点分路径取值（优先 jq，回退 python3）
json_val() {
    local path="$1"
    if command -v jq >/dev/null; then
        jq -r ".$path // empty"
    else
        python3 - "$path" <<'PY'
import sys, json
path = sys.argv[1].split('.')
d = json.load(sys.stdin)
for k in path:
    if isinstance(d, list):
        d = d[int(k)]
    else:
        d = d.get(k) if isinstance(d, dict) else None
    if d is None:
        break
print('' if d is None else d)
PY
    fi
}

SKILL_NAMES=(pprof-toolkit pprof-profiler-collector pprof-cpu-analyst pprof-memory-analyst pprof-code-correlator pprof-report-architect pprof-optimizer)

echo "== 1/4 导入 7 个 skill =="
declare -a SKILL_IDS=()
for name in "${SKILL_NAMES[@]}"; do
    pkg="$TMP/$name.skill"
    (cd "$SKILLS_DIR/$name" && zip -qr "$pkg" .)
    if out=$(multica skill import --file "$pkg" --output json 2>"$TMP/err"); then
        id=$(echo "$out" | json_val id)
        echo "   导入 $name -> $id"
    else
        # 同名冲突等失败：从列表里找已有同名 skill 复用
        id=$(multica skill list --output json | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    if s.get('name') == '$name':
        print(s.get('id','')); break
" 2>/dev/null || true)
        [[ -n "${id:-}" ]] || { echo "错误: 导入 $name 失败且未找到同名 skill: $(cat "$TMP/err")" >&2; exit 1; }
        echo "   复用已有 $name -> $id"
    fi
    SKILL_IDS+=("$id")
done

toolkit_id="${SKILL_IDS[0]}"

echo "== 2/4 创建 6 个智能体 =="
# 角色名 -> 一句话定位（完整流程在各角色 skill 内）
role_brief() {
    case "$1" in
        pprof-profiler-collector) echo "数据采集员：对目标 Go 服务做两期 profile 成对采集与校验，只采集不分析，产出交接给 02/03" ;;
        pprof-cpu-analyst)        echo "CPU 增长点分析：cpu/block/mutex 两期差分，区分业务增长与劣化，产出 notes/cpu-analysis.md" ;;
        pprof-memory-analyst)     echo "内存增长点分析：heap/allocs/goroutine 两期差分，区分真泄漏与高分配率，产出 notes/memory-analysis.md" ;;
        pprof-code-correlator)    echo "源码关联：热点符号映射 file:line，产出带双轴影响论证的优化假设，只读源码" ;;
        pprof-report-architect)   echo "报告架构师兼小队 leader：交叉核对笔记、评定优先级、汇总 report.md，是双轴红线最后守门员；收到性能分析 issue 时按 01 → 02/03 → 04 → 05 → 06 路由" ;;
        pprof-optimizer)          echo "优化实施：唯一有权改代码的成员，逐条实施 + benchstat 双轴验收，否决即回退，产出 notes/verification.md" ;;
    esac
}

AGENT_NAMES=(pprof-profiler-collector pprof-cpu-analyst pprof-memory-analyst pprof-code-correlator pprof-report-architect pprof-optimizer)
declare -a AGENT_IDS=()
for i in "${!AGENT_NAMES[@]}"; do
    name="${AGENT_NAMES[$i]}"
    skill_id="${SKILL_IDS[$((i+1))]}"
    instructions="你是 pprof-team 小队的成员：$(role_brief "$name")。完整工作流程严格遵循你的 skill「$name」；共享脚本、环境变量契约、产物目录与双轴红线见 skill「pprof-toolkit」。红线：禁止以牺牲内存换取 CPU 优化，也禁止以牺牲 CPU 换取内存优化；benchstat 三轴（ns/op、B/op、allocs/op）任一统计显著回归（p<0.05）即否决变更。"
    args=(agent create --name "$name" --runtime-id "$RUNTIME_ID" --instructions "$instructions" --output json)
    [[ -n "$MODEL" ]] && args+=(--model "$MODEL")
    if out=$(multica "${args[@]}" 2>"$TMP/err"); then
        id=$(echo "$out" | json_val id)
        echo "   创建 $name -> $id"
    else
        id=$(multica agent list --output json | python3 -c "
import sys, json
for a in json.load(sys.stdin):
    if a.get('name') == '$name':
        print(a.get('id','')); break
" 2>/dev/null || true)
        [[ -n "${id:-}" ]] || { echo "错误: 创建 $name 失败: $(cat "$TMP/err")" >&2; exit 1; }
        echo "   复用已有 $name -> $id"
    fi
    AGENT_IDS+=("$id")

    echo "   绑定 skill: $name + pprof-toolkit"
    multica agent skills add "$id" --skill-ids "$skill_id,$toolkit_id" >/dev/null
done

echo "== 3/4 创建小队并加成员 =="
if out=$(multica squad create --name "$SQUAD_NAME" --output json 2>"$TMP/err"); then
    squad_id=$(echo "$out" | json_val id)
    echo "   创建小队 $SQUAD_NAME -> $squad_id"
else
    squad_id=$(multica squad list --output json | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    if s.get('name') == '$SQUAD_NAME':
        print(s.get('id','')); break
" 2>/dev/null || true)
    [[ -n "${squad_id:-}" ]] || { echo "错误: 创建小队失败: $(cat "$TMP/err")" >&2; exit 1; }
    echo "   复用已有小队 -> $squad_id"
fi

for i in "${!AGENT_IDS[@]}"; do
    multica squad member add "$squad_id" --member-id "${AGENT_IDS[$i]}" >/dev/null 2>&1 || true
done
# leader 设为 05 report-architect（守门员，负责路由与质量）
multica squad member set-role "$squad_id" --member-id "${AGENT_IDS[4]}" --role leader >/dev/null 2>&1 || true

echo "== 4/4 完成 =="
echo ""
echo "小队 $SQUAD_NAME 已就绪。使用方式："
echo "  1. 确认目标 Go 服务已暴露 /debug/pprof（见仓库 README 快速上手）"
echo "  2. 在 Multica 里创建 issue，例如「分析服务近一小时的 CPU 与内存增长点」，"
echo "     指派给小队 $SQUAD_NAME（multica issue assign <id> --to \"$SQUAD_NAME\"）"
echo "  3. 需要环境变量时，用 multica agent env set <agent-id> 给成员设置"
echo "     PPROF_ADDR / GO_PROJECT_DIR / PROFILE_SECONDS"
