---
tracker:
  kind: linear
  provider:
    project_slug: "<你的项目 slug>"
  required_labels:
    - symphony
  active_states:
    - Scoped
    - Executing
  terminal_states:
    - Archived
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
agent:
  max_concurrent_agents: 8
  max_turns: 20
  max_concurrent_agents_by_state:
    Scoped: 4
    Executing: 3
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  network_access: true
  resume_threads: true
  stall_timeout_ms: 600000
  turn_timeout_ms: 3600000
jobs:
  gated_states:
    - Executing
  heartbeat_ms: 60000        # stall_timeout_ms 的 1/10
  max_runtime_s: 43200
  default_compute: light
  max_concurrent_by_compute:
    heavy: 2
    light: 6
hooks:
  after_create: |
    git init -q .
    git config user.email <你的邮箱>
    git config user.name <你的名字>
    git commit -q --allow-empty -m "workspace init"
  before_remove: |
    <归档到冷区的命令>
---

# Issue {{ issue.identifier }} · {{ issue.title }}

当前 Issue 生命周期状态被设置为：{{ issue.state }}

## 任务

{% if issue.description %}{{ issue.description }}{% else %}Issue 正文为空。先读 Issue 的评论，把要做的事问清楚。{% endif %}

参考：{{ issue.url }}

## 你拥有的 Symphony 工具

```
linear_graphql       对 Linear 执行 GraphQL。你没有自己的 Linear 凭证，
                     所有 Linear 读写都走它。不要用它改状态。
                     你发的每条评论，正文开头加一行：
                     Agent automation comment via symphony

request_state_change 登记本轮结束时要切换到的状态。调用后你可以继续
                     把手头的事做完，状态在你真正停下时才生效。

job_submit           提交长时计算作业。仅在 Executing 状态下可用；
                     其他状态调用会被拒绝，那说明你该先请求执行批准。
job_status           查本 Issue 的作业槽：跑过什么、现在有没有在跑。
job_wait             阻塞等待作业结束或超时。不要轮询，不要在 shell 里 sleep。
job_cancel           终止本 Issue 的作业。
```

以上是 Symphony 注入的工具，不影响你自带的 shell、文件、编辑能力。

## 工作流协议

这是一个本机量化研究的计算侧流程。你负责建计算程序、向远端协作者确认口径、跑计算、交付。七个状态里只有两个由你推动。

### Scoped —— 你的唯一唤醒入口

人写完东西一律推到 Scoped，所以你醒来时不需要知道为什么醒。

1. 读 Issue 的评论，看自上次以来人说了什么
2. 扫仓库、写或改脚本、跑小样本确认口径
3. 收工时 `request_state_change` 到 `Awaiting Review`，并在评论里**写明这次是请求执行还是请求验收**

本状态下 `job_submit` 不开放。要跑长时计算，先请求执行批准。

### Executing —— 手上有作业

1. 提交作业后，先 `job_wait(60)` 确认它没有一启动就炸
2. 确认活着之后才允许长时间等待
3. 作业结束后分析结果、commit、把产出物落到数据区
4. 收工时 `request_state_change` 到 `Awaiting Review`（请求验收）或 `Awaiting Input`（有事要问）

### Awaiting Input / Awaiting Review / Draft / Completed / Archived

这些状态不派发给你。你只会从 Scoped 或 Executing 醒来。

### 收工方式

调用 `request_state_change` 就等于说"我这轮结束了"。调用之后你可以继续把手头的收尾做完，Symphony 会在你真正停下之后才去改 Linear 的状态。

### 硬性约束

1. **绝不走 Codex 自带的用户输入通道**。要问人就发 Linear 评论并 `request_state_change` 到 `Awaiting Input`。走用户输入通道会让这个 Issue 被永久卡死。
2. **不用 `linear_graphql` 改状态**。状态只能通过 `request_state_change` 登记。
3. 一个 Issue 同时只能有一个作业。多组参数扫描要么包成一个作业（脚本内部 fan-out），要么在脚本内部串行并表达进度。
4. 预计超过 10 分钟的作业，脚本必须周期性写 checkpoint 到**工作区之外**的固定路径，并在启动时自动探测续算。
5. 计算结果写到工作区之外的数据区。工作区只放代码和临时文件。
6. 这是无人值守会话，不要向人要任何东西再等回复；要问就按第 1 条走 Linear。
