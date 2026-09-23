# 部署 pprof-team 到 Multica

[Multica](https://github.com/multica-ai/multica) 是开源的多智能体任务协作平台：把 Claude Code、Codex、Kimi 等 26 种编码智能体 CLI 纳入同一个看板工作区，智能体像队友一样领取 issue、汇报进度、提交结果。

## 概念映射

Multica 没有"小队 JSON 导入"——小队的便携分享包目前还只是[待实现的功能请求](https://github.com/multica-ai/multica/issues/2707)。Multica 实际支持的导入单元是 **skill**（`SKILL.md` + 支持文件的文件夹或 `.skill`/`.zip` 压缩包，经 UI 或 `multica skill import` 导入）。因此本团队的映射方式是：

| pprof-team 概念 | Multica 概念 |
|---|---|
| `agents/0X-*.md` 角色定义 | 一个 **skill**（`skills/pprof-<role>/SKILL.md`），绑定给对应智能体 |
| 共享脚本与模板（`scripts/`、`templates/`） | 共享 skill **pprof-toolkit**，绑定给全部 6 个智能体 |
| 每个角色 | 一个 Multica **智能体**（`multica agent create`，instructions 指向其 skill） |
| 整支队伍 | 一个 **小队 squad**（`multica squad create`），leader 为 pprof-report-architect |
| 分析任务 | 一个 **issue**，指派给小队，leader 按 01 → 02/03 → 04 → 05 → 06 路由 |

## 目录

```
multica/
├── README.md                    # 本文件
├── setup-multica.sh             # 一键部署：导入 skill + 建智能体 + 建小队（幂等）
└── skills/
    ├── pprof-toolkit/           # 共享工具包：3 个脚本 + 报告模板 + 全局约定与红线
    │   ├── SKILL.md
    │   ├── scripts/             # collect_profiles.sh / diff_profiles.sh / bench_verify.sh
    │   └── templates/           # report-template.md
    ├── pprof-profiler-collector/SKILL.md
    ├── pprof-cpu-analyst/SKILL.md
    ├── pprof-memory-analyst/SKILL.md
    ├── pprof-code-correlator/SKILL.md
    ├── pprof-report-architect/SKILL.md
    └── pprof-optimizer/SKILL.md
```

## 部署步骤

前置条件：已安装并登录 [Multica CLI](https://multica.ai/docs/zh/cli)（`multica auth status` 正常），且目标运行时上已装至少一个编码智能体 CLI（kimi / claude 等），本机有 `zip` 和 `python3` 或 `jq`。

```bash
# 1. 找到运行时 ID
multica runtime list

# 2. 一键部署（导入 7 个 skill、创建 6 个智能体并绑定 skill、创建小队并设 leader）
./setup-multica.sh --runtime-id <运行时ID>
```

脚本幂等：重复执行时同名 skill / 智能体 / 小队会被复用而不是报错。

## 部署后使用

1. 确认被分析的 Go 服务（如 multica 后端本身，它是 Go + Chi）已暴露 `/debug/pprof`——可参考根目录 README 的"快速上手"接入片段；
2. 给智能体设置环境变量（owner/admin 可用）：
   ```bash
   multica agent env set <agent-id>   # PPROF_ADDR / GO_PROJECT_DIR / PROFILE_SECONDS
   ```
3. 创建 issue 并指派给小队：
   ```bash
   multica issue create --title "分析服务近一小时 CPU 与内存增长点"
   multica issue assign <issue-id> --to "pprof-team"
   ```
4. 小队按流水线执行：采集 → CPU/内存并行差分分析 → 源码关联 → 报告 → 实施与双轴验收，最终产出 `report.md` 与 `notes/verification.md`。

## 手动替代（不用脚本）

也可以全部在 Web UI 操作：**Skills** 页逐个"从本地导入" `skills/` 下的文件夹（或先 zip 成 `.skill`）→ **Agents** 页新建 6 个智能体并在其 **Skills** 标签页绑定对应 skill + pprof-toolkit → **小队** 页创建小队、添加 6 个成员、把 pprof-report-architect 设为 leader。

## 注意

- skill 导入即快照：之后改了 `skills/` 里的文件，需要重新导入或在工作区内编辑才会生效；
- 导入的 skill 内容会原样提供给智能体执行（Multica 不做沙盒审查），本团队 skill 含 shell 脚本，请确认你了解其内容；
- `setup-multica.sh` 使用的 CLI flag 以[官方 CLI 文档](https://multica.ai/docs/zh/cli)为准，版本差异以本机 `multica <command> --help` 微调。
