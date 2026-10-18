# 个人机抹盘后恢复清单（Lin / chips）

本文件是 **个人侧** 一键恢复的补充说明。上游 README 管 nix-darwin 骨架；这里管「抹盘后还要手动挂上的东西」。
**禁止**把密钥、token、公司内网配置写进本仓库。

## 0. 前置决策（已确认项可勾）

- [x] 个人 git：`user.name=chipssss`，`user.email=694590896@qq.com`（见 `home/git/gitconfig.personal.template`）
- [x] SSH / 密钥恢复：优先 **Apple 钥匙串 / iCloud**；1Password 仅可选付费备用
- [ ] Clash / 代理配置从哪里导入？（仅订阅与规则，不要 commit）
- [x] Firstmate 路径统一：`~/ai/firstmate`
- [x] 个人 fork：`https://github.com/chipssss/dotfiles`（origin）；upstream 可指 `kunchenguid/dotfiles`

## 1. 系统与 Dotfiles（nix-darwin）

```sh
git clone https://github.com/chipssss/dotfiles.git ~/Project/dotfiles
cd ~/Project/dotfiles
# 确认 flake.nix 里 user = 你的 macOS 用户名（现为 chips）
./bootstrap.sh
./rebuild.sh   # 之后改配置都用这个
```

说明：

- `bootstrap.sh`：装 Determinate Nix → 链 `~/.dotfiles` → 首次 `darwin-rebuild switch`。
- 当前 checkout 上 **nix-homebrew / homebrew 模块是关闭的**（避免 `cleanup = "zap"` 清掉未声明的包）。CLI 用下面的 Brewfile。

## 2. Homebrew 个人包

```sh
# 若尚无 Homebrew：
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)"

brew bundle --file=~/.dotfiles/Brewfile
```

Brewfile 含 Ghostty 与 `font-caskaydia-cove-nerd-font`（Ghostty 默认字体）。

## 3. Shell 增量片段

`home/.zshrc.additions` / `home/.zshenv.additions` 由仓库维护。Home Manager activation 会确保你的 `~/.zshrc` / `~/.zshenv` 里有 sourcemarker；若没有，手动加：

```sh
# ~/.zshenv
# >>> dotfiles incremental additions >>>
source "$HOME/.dotfiles/home/.zshenv.additions"
# <<< dotfiles incremental additions <<<

# ~/.zshrc
# >>> dotfiles incremental additions >>>
source "$HOME/.dotfiles/home/.zshrc.additions"
# <<< dotfiles incremental additions <<<
```

## 4. Git 个人身份（本机执行）

已确认个人身份（**不是**公司邮箱）：

```sh
git config --global user.name "chipssss"
git config --global user.email "694590896@qq.com"
# 或一次性 include 模板（含 core.excludesfile → home/git/gitignore_global）：
# git config --global include.path ~/.dotfiles/home/git/gitconfig.personal.template
gh auth login
```

全局忽略规则在 `home/git/gitignore_global`；模板已设 `core.excludesfile = ~/.dotfiles/home/git/gitignore_global`。

## 5. 密钥与私密项（只挂载，不入库）

**优先：Apple 钥匙串 / iCloud Keychain**（Lin 已确认）。在新机登录同一 Apple ID 后，SSH 相关项可经钥匙串恢复；再用：

```sh
ssh-add --apple-use-keychain ~/.ssh/id_ed25519
```

| 项 | 建议 |
| --- | --- |
| SSH | 优先从 **Apple 钥匙串 / iCloud** 恢复 `~/.ssh`；`ssh-add --apple-use-keychain` |
| 1Password | **可选付费备用**（Brewfile 含 `1password-cli`）；非必需 |
| Pi / Codex / Claude 登录 | 各 CLI 交互登录；勿把 `auth.json` / session 拷进 git |
| 项目 `.env` | 从安全笔记 / 钥匙串备注重建；仓库只保留 `*.example` |
| `~/.fm-adp-secrets.env` 一类 | **永不**进 Dotfiles；需要时本机创建 |
| Clash 订阅 | App 内导入；配置目录不进仓库 |

`.gitignore` 已排除常见 Pi 凭证与运行态；新增私密路径时继续加排除规则。

## 6. 语言工具链（个人侧）

Brewfile 覆盖：Node、pnpm、Go、uv/Python、Deno。另需：

```sh
# Bun（官方安装器，非 brew 必选）
curl -fsSL https://bun.sh/install | bash

# 常用全局 npm（Firstmate 相关；以 firstmate INSTALL.md 为准）
npm install -g @openai/codex @earendil-works/pi-coding-agent \
  gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi
```

## 7. Firstmate / Lighthouse（代码不进 Dotfiles）

环境齐后按 Firstmate 仓库自己的安装说明。**路径统一：`~/ai/firstmate`**（不要用 `~/firstmate`，除非你刻意改 symlink）。

```sh
mkdir -p ~/ai
git clone https://github.com/lighthouser-agent/firstmate ~/ai/firstmate
cd ~/ai/firstmate
# 然后严格按该仓库 INSTALL.md 执行 preset / dispatch / toolchain
# 需要：gh 已登录且能访问 lighthouser-agent org；tmux；codex login；pi /login
```

Lighthouse / LightHouser 工程：从组织仓库按需 clone（如 `lighthouser-agent/...`），**不要**指望 Dotfiles 带代码。
ego lite（Citro Labs）、Clash Verge：Brewfile 已含 `clash-verge-rev`；ego 从官网/既有安装恢复。

## 8. 编辑器 / 终端

| 已由 Dotfiles 覆盖 | 需另恢复 |
| --- | --- |
| Neovim（`home/.config/nvim`） | Cursor / VS Code：见 `home/editor/README.md` |
| WezTerm / Ghostty（`home/.config/ghostty`，HM 链接） | 公司策略插件：**不要**进本公开仓库 |
| Ghostty 字体：`font-caskaydia-cove-nerd-font`（Brewfile） | |

若尚未跑 home-manager，可手动：`ln -sfn ~/.dotfiles/home/.config/ghostty ~/.config/ghostty`。

## 9. 验收清单

- [ ] `nix` / `darwin-rebuild` 可用，`./rebuild.sh` 成功
- [ ] `brew bundle` 后 `node` `gh` `tmux` `pnpm` `uv` `go` 在 PATH
- [ ] starship + zsh additions 生效
- [ ] Ghostty 能打开且字体为 CaskaydiaCove Nerd Font
- [ ] `git` 显示 `chipssss` / `694590896@qq.com`；`gh auth status` 通过；全局 ignore 生效
- [ ] SSH 能 `git@github.com`（钥匙串已加载）
- [ ] `codex` / `pi` / `claude` 已各自登录
- [ ] Firstmate 在 `~/ai/firstmate`，INSTALL.md 预检全绿，能完成一次 scout dispatch
- [ ] 代理可用（若开发需要）
- [ ] 确认无公司邮箱/证书/内网配置误入本仓库

## 10. 明确排除（公司侧，不进 Dotfiles）

- 公司邮箱硬编码、公司 git hook（如 bytesec）、公司 VPN/证书
- 字节内网工具、工作项目专属 env
- 任何明文 API key / token

## 11. MacBook 个人侧已同步进仓库

从即将抹盘的 MacBook（用户 `bytedance`）只读同步了**个人通用**部分：

| 内容 | 仓库位置 |
| --- | --- |
| Shell aliases / fzf | `home/.zshrc.additions` |
| Starship（可选 powerline） | `home/.config/starship.powerline.toml`（默认仍用 `starship.toml`） |
| Cursor settings / keybindings / 扩展列表 | `home/editor/cursor/` |
| VS Code settings / 扩展列表 | `home/editor/vscode/` |
| Git 个人模板 + 全局 ignore | `home/git/gitconfig.personal.template`、`home/git/gitignore_global` |
| Ghostty 配置 | `home/.config/ghostty/config`（HM 链接） |
| Brewfile 合并 cask | 根目录 `Brewfile`（含 cursor、obsidian、rectangle、clash-verge-rev、ghostty、font-caskaydia-cove-nerd-font） |
| 工具链版本表 | `docs/TOOLCHAIN.md` |

**未同步（有意排除）：** 公司 email、bytesec hook、`byted-*` 扩展、代理口令、任何 `.env` / token、Lighthouse 业务代码与 `config.yaml`。

### Lighthouse / Firstmate 路径习惯

- Firstmate：**统一 `~/ai/firstmate`**（已确认）。
- Lighthouse（MacBook 有 `~/ai/lighthouse`）：抹盘后**重新 clone** 对应仓库，用 `config.example.yaml` 重建本地配置；不要从旧机拷 `config.yaml` / `.env`。
- LightHouser 工程：经 Firstmate / `lighthouser-agent` org 按需 clone。

恢复编辑器：见 `home/editor/README.md`。
