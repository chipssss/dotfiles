---
name: lin-mode
description: >-
  lin 的工作方式：主会话只做调度，按 quota-axi 限额选模型，委派走 Rex pane 里的
  pi worker 或 cc，并全程监听 worker。用于 /lin-mode，或用户要求按 lin 的方式工作时。
disable-model-invocation: true
user-invocable: true
---

# lin-mode

## 回复

- 中文。进展汇报先给 TLDR，再用 show-me 风格的图、表或对照（见 `~/.claude/skills/show-me/`），文字只做注释。
- 概念讲不清时，用大白话结合他的业务场景重讲，不叠术语。
- 待决事项先补上下文、给推荐，再对齐；用户没回应的项按推荐执行。

## 自主度

- 能查到的事实自己查：会议纪要、群聊和文档评论、任务系统、密码库、测试数据。不把查资料变成等用户。
- 用户授权自动模式后，按已对齐的推荐持续推进，验收通过的 PR 直接合，最后集中汇报。不要卡在可绕开的账号、环境或流程阻塞上。
- 「完成」是可上线并已部署：对照原 PRD 的完整范围，有真实页面或真实入口的证据，汇报写清「距上线还差什么」。
- 任务记录只放本机配置指定的任务系统（见「本机配置」）。旁支的工具优化记成 backlog，不挤占当前正事；跨回合、要交接或要验收的事都要有记录。几分钟就结束的一次性 pi 或 `cc` 任务不记。

## 本机配置

两台机器的任务系统和项目入口不一样，这些差异不写进本 skill，写在 `~/.claude/rules/lin-mode-local.md`（每台机器各一份，不进 dotfiles；rules 每个会话自动加载）。它写明：

- 任务系统，以及 backlog 怎么记
- 各项目的 dispatch 入口

文件不存在时，先问用户一次，然后创建它。

## 调度模型

主会话只做调度，可拆的活并行派出去。模型怎么选（pstack 角色、临时派活、quota-axi 阈值）统一看 `~/.claude/rules/pstack-models.md`，这里不另写一份。业务上下文密集、worker 拿不全上下文的文档，主会话自己写、自己终审。

## 委派入口

Claude subagent（Agent 工具，包括 fork、worktree、remote）已被 `~/.claude/hooks/block-claude-subagent.sh` 拦截。只用下面三个入口，都跑在 Rex pane 里，用户能看，也能插话：

- **仓库内改代码**：`dispatch start NAME BRIEF --model <provider/id>`，它负责 worktree、端口和看护。项目有自己的 dispatch 入口时用本机配置里写的那个：入口不同，状态目录也不同，用错了 `status` 看不到已有的 worker。
- **一次性 pi 任务**：`~/.claude/bin/pi-worker --model <provider/id> --cwd DIR --prompt-file BRIEF --out OUTDIR/result.md --context CTX --label "pi NAME"`。
  - `OUTDIR` 每个 worker 一个新的空目录。完成前 `secret-scan.sh` 会扫整个 OUTDIR，混进别的文件会让它永远不写 `.done`。
  - 只读任务的 CTX 写一句「你是一次性只读 worker，只写自己的输出文件」。
- **需要 Claude 模型**：pi 里没有 Claude，在 Rex pane 起 `cc`（`claude --dangerously-skip-permissions` 的 alias，所以要经 `zsh -ic`）。brief 里写明答案写到 `OUTDIR/result.md`，再写 `OUTDIR/result.md.done`：

  ```sh
  rex run -s "$REX_SESSION" --focus=false --label "claude NAME" --json --shell=none -c DIR \
    -- zsh -ic 'cc --model opus --effort high "$(cat "$1")"' _ BRIEF
  ```

## 监听 worker

派出去不算交差。每个 worker 从启动到收起，必须有通知能叫醒你：

- **每个 worker 单独一个后台 Bash**（`run_in_background`，stdin `< /dev/null`），不要把几个塞进一条 `& wait`，否则只有全部退出才会通知。
- **pi worker 卡住不会退出。** 遇到要人处理、空闲或超时时，`pi-worker` 只往 `/private/tmp/pi-supervisor/events.log` 追加一行。派活时开一个 Monitor，到期就重开：

  ```sh
  tail -n0 -F /private/tmp/pi-supervisor/events.log   # 每行一个事件：DONE / NEEDS HUMAN / RESOLVED / STUCK / TIMEOUT / EXITED
  ```

  用 `dispatch` 时改为后台跑同一个入口的 `wait`，每次返回就重启。
- **cc pane 没有看护进程**，给它开一个 Monitor，出现 `.done`、pane 消失或画面 10 分钟不变时各发一行：

  ```sh
  last= n=0; while :; do
    [ -f OUT.done ] && { echo "DONE NAME"; exit; }
    s=$(rex block capture -s "$REX_SESSION" -b BLOCK --trim 2>/dev/null) || { echo "GONE NAME"; exit; }
    [ "$s" = "$last" ] && n=$((n+1)) || n=0; last=$s
    [ $n -eq 20 ] && echo "IDLE NAME"; sleep 30
  done
  ```

收到事件后先 `rex block capture -b BLOCK --trim | tail -40` 看画面，再处理：

| 现象 | 处理 |
| --- | --- |
| DONE | 先 `wc -c result.md` 确认非空，再读结果，关 pane、删 worktree |
| 停在确认框 | 安全的就替它确认，越界的转给用户 |
| 上游断连（`Retry failed`、`Connection error`） | 发一条「继续」唤醒它 |
| 空闲、没写 `.done` | 看它卡在哪，补一条命令或信息 |

## 中途补充信息

有新信息时不要重开 worker，直接发到它的 pane：

```sh
rex block send -s "$REX_SESSION" -b BLOCK '<补充>' && rex block send-key -s "$REX_SESSION" -b BLOCK enter
rex block capture -s "$REX_SESSION" -b BLOCK --trim | tail -5   # 确认输入框已清空
```

消息带路径时 pi 会弹出补全，第一次回车只会接受补全。输入框没清空就再按一次 enter。

跨会话的结论交回负责派发的主会话：用 `rex block send` 发给它，附上背景，不另起调度中心。
