# 当前修复状态

更新日期：2026-10-02

## 目标与范围

修复当前 `oracle-web` 使用失败，更新 Codex 和 Claude Code 全局技能及共用 Runtime。保留指定登录源、独立浏览器会话、选档验证和精确清理约束。用户于 2026-10-02 授权提交并推送本轮代码；文章发布不在本轮范围内。

## 已确认的证据

- 工作分支：`codex/fix-thinking-control-selector`，开始时工作树干净，HEAD 为 `fa204c9`。
- 两个入口共用 `~/.local/bin/oracle-web`，指定登录源为 `~/.local/share/oracle-web/chrome-source` 的 `Default`，没有发现技能入口混用。
- 最近两个项目 session 都以 `Prompt textarea did not appear before timeout` 失败，`promptSubmitted=false`。
- 本轮无敏感附件复现：`ow-live-20261001-230842-78888`。登录探针报告 session 已认证，之后精确隔离 tab 位于 `https://chatgpt.com/auth/login`，没有 composer。未发送，Chrome PID 78948 已退出。
- `scripts/verify.sh --claude-home ~/.claude` 失败：Runtime hash unknown。仅 `thinkingTime.js` 存在未纳入仓库的 2026-09-24 修改，为 Escape 失效后点击可见 composer 关闭菜单；已复制完整 Runtime 到本轮临时目录保存，不覆盖丢弃该修改。

## 当前调查与验收

- 保留/丢弃 Local Storage 的对照都跳到认证页，已排除该因素，不改变 Profile 的复制排除规则。
- 认证探针使用异步请求前的 URL，存在晚到登录跳转误判；中文登录提示未被识别。新回归在旧代码失败，修复后通过。
- 用户在指定持久登录源手动完成登录后，本轮 staged Runtime 带附件实测 `ow-live-20261001-233745-95731` 完成：5/5 上传后重验、提交新对话、回答 `ORACLE-WEB-LIVE-OK`、完整答案 artifact、精确 Chrome/Profile 清理，耗时 89.2 秒。
- 已保留 2026-09-24 的 composer 点击关闭菜单修复，纳入主 patch、历史迁移和 SHA-256 清单。
- 新 Native DOM 回归模拟网页忽略 Escape，保留真实 CDP 点击与回读；原 fixture 的原生 Escape 会影响测试页面，不能用该页面重载替代菜单关闭证据。
- 针对性认证回归和原生附件/composer 回归已通过；完整离线检查 `ORACLE_TEST_PACKAGE_ROOT=/tmp/oracle-web-repair.Mj2LKb/package ./scripts/test.sh` 已通过，exit 0，末尾 `All offline tests passed`。覆盖安装幂等、各已支持历史版本迁移、回滚、附件/选档、长答案等待与清理。
- 修复已支持的原因及错误诊断，保留合理的本机选档修改并纳入托管校验。
- 实际 Runtime 已按本轮精确差分安装，旧代码持久备份为 `~/.local/state/oracle-web/backups/runtime-repair-20261001.yW81Fq`。更新前先核对实际代码仍等于开始时快照，未覆盖其他改动。Runtime 现在与当前托管 hash 一致。
- `scripts/install.sh --force --claude-home /Users/jinkun.wang/.claude` 已同步 Codex 和 Claude Code；`scripts/verify.sh --claude-home /Users/jinkun.wang/.claude` 通过，两个 wrapper 内容一致。两边 `quick_validate.py` 通过；本机 Python 缺少 PyYAML，使用 `uv run` 的隔离依赖完成验证，没有修改全局 Python。
- 实际安装入口多附件实测 `ow-live-20261001-235408-15361` 完成：4/5 上传后重验、10 个无敏感附件、提交新对话、保存 `ORACLE-WEB-LIVE-OK`、metadata `completed`，耗时 113.1 秒。临时 Chrome PID 15449 已退出，临时 Profile 已删除。
- 两轮成功测试的答案、档位证据及精确清理已独立核对；指定登录源和源 Chrome PID 37707 仍在。实际安装 Runtime 的认证就绪回归也已通过。
- 验收：针对性 DOM/状态回归、隔离安装与升级/回滚检查、真实附件网页闭环、Codex/Claude Code 安装一致性、精确 PID/Profile 清理。

## 交付状态与限制

本轮修复、全局安装与适用验证已完成。本次交付沿用工作分支 `codex/fix-thinking-control-selector`，推送目标为 `origin/codex/fix-thinking-control-selector`；不修改 `main`，不发布文章。真实登录可过期；本轮登录由用户手动完成，技能复用指定登录源，不会自动重新认证。两轮短附件闭环不证明未来登录永不失效，也不替代真实项目的长回答验收。
