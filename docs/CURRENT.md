# 当前状态

更新日期：2026-10-06

## 2026-10-06 验证与文档更新

当前代码基线为 `main` 上的 `bf9a5b8`。2026-10-02 的登录与选档菜单修复已合并并推送；本轮只诊断网页中断、更新 README 和已发布文章，不修改 Runtime、Codex/Claude Code Skill 或登录配置。

用户补充故障与大量、大文件有关后，使用同一批 10,000 条人工任务记录测试两种布局：

| 布局 | 上传体积 | 本地材料 Token 估算 | 浏览器任务用时 | 验证结果 |
| --- | --- | --- | --- | --- |
| 10 个 CSV 直接上传 | 834,864 字节 | 352,327 | 11 分 41 秒 | 通过 |
| 12 个 CSV 合成一个文本包 | 896,913 字节 | 373,896 | 14 分 21 秒 | 通过 |

两轮均确认 5/5、上传后重验、提交新对话、捕获正文并落盘；行数、费用和六类问题清单与本地基准匹配，退出码 0。最终 metadata 为 `completed`，记录的 Chrome PID 不存在，临时 Profile 已删除，持久登录源保留。窗口关闭在保存答案之后。

小附件的 11 节点有向旅行商及先后约束测试也完成，答案由本地动态规划核对，最优费用为 153。此前一次同类测试被会话中断强制结束，不能当作完整通过或自然崩溃复现。

### 已确认的缺口

- CDP disconnect 会拒绝本轮执行；即使原 endpoint 和 target 可达并判为 recoverable，copy-profile 的 finally 仍关闭本轮 Chrome，没有在本轮内恢复原连接。实际运行时的纯替身测试已确认此分支，未触碰真实网页。
- 探测超时不等于进程退出。大附件直传时出现三次独立探测超时，Chrome 和执行器仍活着并随后恢复；当前错误文案仍可能称为窗口关闭。
- `SIGKILL` 后可能留下孤立 Chrome、临时 Profile 和过期 `running` metadata。已按精确身份清理本轮中断测试，不动登录源或 Codex。
- 打包临时目录未自动回收；本轮 dry-run 与实际提交生成的两份人工样本已归档，没有处理历史打包目录。
- 原生 Markdown 复制入口有 `copy-missing` 重试，快照读取能保存正文，但增加收尾时间。

历史 15/33 分钟后的首次断开仍未确认。本轮大附件运行没有复现自然断线，不能宣布故障已修复。默认 24 小时保留策略已清掉旧 session，排障需要在过期前保留脱敏证据。

### 本轮交付范围

README 与文章区分测试通过、已确认缺口和未确认原因。公开文档不包含个人 home 绝对路径、Cookie 值、Profile 内容或原始 session 日志。提交、推送仅包含本轮文档变更，不重新安装技能，也不声称实现了断线容错。

已按 `humanizer-zh` 编辑文章，并使用 `publish-site-article` 覆盖现有公开文章 17：[《我为什么把 ChatGPT Web 和 Codex 分开用》](https://wangjinkun333.me/blog/gpt-oracle-web-reliable-browser-consultation)。发布脚本的认证回读与公开 API 验证通过；标题、slug、发布日期、标签值、封面和两张图保留，没有新增文章或媒体。文章区分 2026-10-02 离线验证与本轮大附件实测，没有把输入 Token 估算写成节省量。

本机 Codex/Claude Code 安装一致性检查 `scripts/verify.sh --claude-home "$HOME/.claude"` 通过；Markdown 空白检查通过。本轮不重跑未改动代码的完整离线套件。

下一步修复需要单独授权：已提交时在原 session、原 PID/target 内做有界连接恢复，不重发 Prompt、不新建对话、不重置 45 分钟总期限；补充断线前的进程、endpoint、target 与探测错误证据，并管理打包文件生命周期。

## 2026-10-02 登录修复（已交付）

### 当时的目标与范围

修复当前 `oracle-web` 使用失败，更新 Codex 和 Claude Code 全局技能及共用 Runtime。保留指定登录源、独立浏览器会话、选档验证和精确清理约束。用户于 2026-10-02 授权提交并推送本轮代码，随后要求清理工作树、合并到 `main` 并推送；文章发布不在本轮范围内。

### 当时已确认的证据

- 工作分支：`codex/fix-thinking-control-selector`，开始时工作树干净，HEAD 为 `fa204c9`。
- 两个入口共用 `~/.local/bin/oracle-web`，指定登录源为 `~/.local/share/oracle-web/chrome-source` 的 `Default`，没有发现技能入口混用。
- 最近两个项目 session 都以 `Prompt textarea did not appear before timeout` 失败，`promptSubmitted=false`。
- 本轮无敏感附件复现：`ow-live-20261001-230842-78888`。登录探针报告 session 已认证，之后精确隔离 tab 位于 `https://chatgpt.com/auth/login`，没有 composer。未发送，Chrome PID 78948 已退出。
- `scripts/verify.sh --claude-home ~/.claude` 失败：Runtime hash unknown。仅 `thinkingTime.js` 存在未纳入仓库的 2026-09-24 修改，为 Escape 失效后点击可见 composer 关闭菜单；已复制完整 Runtime 到本轮临时目录保存，不覆盖丢弃该修改。

### 调查与验收记录

- 保留/丢弃 Local Storage 的对照都跳到认证页，已排除该因素，不改变 Profile 的复制排除规则。
- 认证探针使用异步请求前的 URL，存在晚到登录跳转误判；中文登录提示未被识别。新回归在旧代码失败，修复后通过。
- 用户在指定持久登录源手动完成登录后，本轮 staged Runtime 带附件实测 `ow-live-20261001-233745-95731` 完成：5/5 上传后重验、提交新对话、回答 `ORACLE-WEB-LIVE-OK`、完整答案 artifact、精确 Chrome/Profile 清理，耗时 89.2 秒。
- 已保留 2026-09-24 的 composer 点击关闭菜单修复，纳入主 patch、历史迁移和 SHA-256 清单。
- 新 Native DOM 回归模拟网页忽略 Escape，保留真实 CDP 点击与回读；原 fixture 的原生 Escape 会影响测试页面，不能用该页面重载替代菜单关闭证据。
- 针对性认证回归和原生附件/composer 回归已通过；完整离线检查 `ORACLE_TEST_PACKAGE_ROOT=/tmp/oracle-web-repair.Mj2LKb/package ./scripts/test.sh` 已通过，exit 0，末尾 `All offline tests passed`。覆盖安装幂等、各已支持历史版本迁移、回滚、附件/选档、长答案等待与清理。
- 修复已支持的原因及错误诊断，保留合理的本机选档修改并纳入托管校验。
- 实际 Runtime 已按本轮精确差分安装，旧代码持久备份为 `~/.local/state/oracle-web/backups/runtime-repair-20261001.yW81Fq`。更新前先核对实际代码仍等于开始时快照，未覆盖其他改动。Runtime 现在与当前托管 hash 一致。
- `scripts/install.sh --force --claude-home "$HOME/.claude"` 已同步 Codex 和 Claude Code；`scripts/verify.sh --claude-home "$HOME/.claude"` 通过，两个 wrapper 内容一致。两边 `quick_validate.py` 通过；本机 Python 缺少 PyYAML，使用 `uv run` 的隔离依赖完成验证，没有修改全局 Python。
- 实际安装入口多附件实测 `ow-live-20261001-235408-15361` 完成：4/5 上传后重验、10 个无敏感附件、提交新对话、保存 `ORACLE-WEB-LIVE-OK`、metadata `completed`，耗时 113.1 秒。临时 Chrome PID 15449 已退出，临时 Profile 已删除。
- 两轮成功测试的答案、档位证据及精确清理已独立核对；指定登录源和源 Chrome PID 37707 仍在。实际安装 Runtime 的认证就绪回归也已通过。
- 验收：针对性 DOM/状态回归、隔离安装与升级/回滚检查、真实附件网页闭环、Codex/Claude Code 安装一致性、精确 PID/Profile 清理。
- 修复提交 `638d93b` 已推送到 `origin/codex/fix-thinking-control-selector`，远端与本地 SHA 已核对。未追踪的 `graphify-out` 生成文件移到仓库外保留，并加入忽略规则，避免以后生成的图缓存进入提交。

### 交付状态与限制

该轮修复、全局安装与适用验证已完成，后续以 `bf9a5b8` 合并到 `main` 并推送。文章不在 2026-10-02 的交付范围内，2026-10-06 用户要求覆盖现有文章。真实登录可过期；登录由用户手动完成，技能复用指定登录源，不会自动重新认证。两轮短附件闭环不证明未来登录永不失效，也不替代真实项目的长回答验收。
