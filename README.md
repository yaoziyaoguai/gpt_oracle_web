# gpt-oracle-web

一个面向 Codex Desktop 的可安装 Skill：通过用户已经登录的 Chrome，把复杂规划、代码审查、根因分析和第二意见交给 ChatGPT 网页端，再由当前 Codex 负责实现与验证。

> English summary: an installable Codex Skill and a verified browser wrapper for high-effort ChatGPT consultations. It keeps the current Codex in charge of implementation, pins the supported Oracle runtime, and fails closed when the web UI cannot prove the selected effort or submitted message.

## 为什么有这个项目

上游 [Oracle](https://github.com/steipete/oracle) 已经提供了把 prompt 和文件送入模型的 CLI。本项目不重写 Oracle，也不提供新的模型；它补的是 Codex Desktop 与 ChatGPT 网页之间缺少的“可靠工作流”层：

- 根据任务复杂度在网页五档强度中的第 4、5 档之间自动选择。
- 只相信网页实际显示的标签和位置，不把 CLI 请求值冒充为网页模型证据。
- 强度无法确认时 fail closed，禁止静默降级后继续发送。
- 页面首次未进入 ready state 时，只在同一个隔离 tab 内做一次有界 reload；仍不可验证就 fail closed。
- 把网页版限定为 planner/reviewer，把实现、测试和最终判断留给当前 Codex。
- 隔离多批咨询，避免把第二批材料串进第一批会话。
- 修复附件已完成却被误判为仍在上传的问题。
- 修复网页附件卡片不显示本地文件名时，普通附件和多文件自动合包被误判为附件缺失的问题。
- 修复附件卡片遮住 composer 中心时，可信点击把有效输入框误判为目标不匹配的问题。
- 修复发送按钮事件未被页面接受、草稿存在却没有真正提交的问题。
- 用新会话和 committed user turn 验证发送成功，而不是只看 `promptSubmitted`。
- 固定自动化 Chrome 的初始窗口尺寸，并在档位选择和提交前恢复该尺寸。
- 每次 trusted pointer 操作前重新定位元素、核对 viewport 并执行 `elementFromPoint` 命中检查；窗口尺寸变化时丢弃旧坐标。
- 为每次咨询绑定独立的 session、Chrome PID、CDP port、target ID 和临时 Profile；Chrome 启动后立即记录 identity，无论成功、失败、超时或恢复结束都只清理这组资源。
- 把本地修改保存为可校验、可回滚的版本化 patch，避免只存在于 Homebrew Cellar。

## 它不是什么

- 不是 OpenAI、ChatGPT、Chrome 或上游 Oracle 的官方项目。
- 不是新的模型、API 代理或绕过订阅限制的工具。
- 不会让正在运行的 Codex 主任务原地切换模型或 reasoning effort。
- 不会自动执行 Oracle 的建议；当前 Codex 仍需检查范围、安全性和代码证据。
- 不保证 ChatGPT 网页内部实际使用了某个不可见的后端模型。

## 工作方式

```text
Codex Desktop
  │
  │ 读取 oracle-web Skill，选择第 4 或第 5 档
  ▼
oracle-web wrapper
  │ 固定 browser engine / current model strategy
  │ 创建唯一 session，复制已登录 Chrome Profile 到临时目录
  ▼
patched @steipete/oracle 0.17.3
  │ 启动即记录 Chrome PID / CDP port / target ID / userDataDir
  │ 验证五档强度、附件状态、发送动作和 committed turn
  ▼
ChatGPT Web ──返回规划/审查/执行建议──▶ 当前 Codex 实现并验证
  │
  └── finally：关闭本次 Chrome，删除本次临时 Profile
```

临时 Chrome 窗口是正常现象。wrapper 不靠窗口标题或创建时间猜测归属，而是使用本次 runtime identity 精确关联。退出后 runtime 会关闭隔离窗口并清理临时 Profile；session 元数据只用于短期恢复和排障，不是仍在运行的网页。

Prompt 写入使用 `Input.insertText`，附件使用 `DOM.setFileInputFiles`。这两步不依赖屏幕坐标。ChatGPT 的五档 power control 不是标准 `select`，发送按钮也需要网页接受可信输入事件，因此这两类操作仍通过 CDP keyboard/pointer 完成。runtime 优先读取 ARIA slider 并发送键盘事件；需要 pointer 时，点击前会重新定位目标并验证命中，不使用截图坐标或人工补点。

Oracle Chrome 会设置为 `1280×720`，并在档位选择和提交前恢复该尺寸。如果用户在一次动作中改变窗口尺寸，旧 viewport 和旧坐标会失效，runtime 会重做当前动作。其他应用窗口覆盖 Oracle Chrome 不改变 DOM 命中结果；不要最小化窗口或持续拖动边框，因为 Chrome 可能暂停合成或节流页面，最终会按 fail-closed 规则停止。

### 为什么不直接调用网页接口

这个项目已经在用接口：Chrome DevTools Protocol 负责定位 DOM、写入 Prompt、挂载附件和发送可信输入事件。难点只在 ChatGPT 网页自身没有面向此用途的稳定公开接口：

- 网页五档强度属于 ChatGPT UI 状态，没有公开的订阅版 API 可直接设置并回读。
- OpenAI API 可以直接传请求参数，但使用独立 API 额度，不再是复用用户的 ChatGPT Web 订阅。
- ChatGPT 私有内部请求依赖登录 Cookie、短期字段和未承诺的协议。直接复刻会扩大凭据风险，并在网页更新时失效。

因此本项目使用公开的浏览器自动化边界：能用 DOM/CDP 直接完成的步骤不走坐标；必须由网页接收可信事件的控件才使用经过重新定位和命中验证的 keyboard/pointer 输入。

## 仓库结构

```text
.
├── bin/oracle-web                         可移植 wrapper
├── skill/oracle-web/
│   ├── SKILL.md                           Codex Skill 入口
│   ├── agents/openai.yaml                 Codex UI 元数据
│   └── references/
│       ├── execution-advice.md            Oracle 输出给 Codex 的建议格式
│       └── troubleshooting.md             fail-closed 故障解释
├── patches/
│   ├── oracle-0.17.3.patch                最小 runtime patch
│   ├── oracle-0.17.3.sha256               原始/修改后文件校验和
│   ├── oracle-0.17.3-from-2fe5969.patch   上一受管版本到当前版本的增量 patch
│   ├── oracle-0.17.3-2fe5969.sha256        上一受管版本校验和
│   ├── oracle-0.17.3-from-209f3ba.patch   上一受管版本到当前版本的增量 patch
│   ├── oracle-0.17.3-209f3ba.sha256        上一受管版本校验和
│   ├── oracle-0.17.3-from-f0ea8d6.patch   上一受管版本到当前版本的增量 patch
│   └── oracle-0.17.3-f0ea8d6.sha256       上一受管版本校验和
├── scripts/
│   ├── install.sh                         安装或幂等更新
│   ├── verify.sh                          离线安装验证
│   ├── uninstall.sh                       安全回滚和卸载
│   ├── test.sh                            隔离安装/幂等/回滚测试
│   └── live-smoke.sh                      显式授权后才运行的网页测试
└── .github/workflows/ci.yml               不接触 ChatGPT 的离线 CI
```

## 支持范围

当前发布范围有意保持窄：

- macOS。
- Codex Desktop。
- Google Chrome，且目标 Profile 已登录 ChatGPT。
- `@steipete/oracle` **准确版本 `0.17.3`**。
- Node.js 24 或更高版本，这是上游 `0.17.3` 的要求。
- 当前 ChatGPT 五档 power control；Oracle 咨询只使用第 4、5 档。
- `bash`、`patch`、`rsync` 和 `shasum`。

安装器不会下载、安装或升级 Oracle。如果版本、文件内容或 patch anchor 不符合预期，它会停止，不会覆盖未知 runtime。

## 安装前准备

确认工具：

```bash
node --version
oracle --version
command -v oracle
command -v patch
command -v rsync
```

如果还没有上游 Oracle，可以用你信任的包管理方式安装准确版本。例如 npm：

```bash
npm install --global @steipete/oracle@0.17.3
```

本项目不会替你执行该命令，也不会自动查询或切换到最新版本。

## 安装

```bash
git clone https://github.com/yaoziyaoguai/gpt_oracle_web.git
cd gpt_oracle_web
./scripts/install.sh
```

默认安装位置：

- wrapper：`$HOME/.local/bin/oracle-web`
- Skill：`${CODEX_HOME:-$HOME/.codex}/skills/oracle-web`
- 安装回执：`${XDG_STATE_HOME:-$HOME/.local/state}/gpt-oracle-web/install-receipt.tsv`
- Oracle session：`${XDG_STATE_HOME:-$HOME/.local/state}/oracle-web`

如果 `$HOME/.local/bin` 不在 `PATH`：

```bash
export PATH="$HOME/.local/bin:$PATH"
```

也可以把 wrapper 安装到上游 `oracle` 所在目录：

```bash
./scripts/install.sh --bin-dir "$(dirname "$(command -v oracle)")"
```

安装器遇到不同内容的现有 wrapper 或 Skill 时会拒绝覆盖。确认已检查旧内容后，使用：

```bash
./scripts/install.sh --force
```

`--force` 会先把被替换的 wrapper 和 Skill 保存到 state 目录的时间戳备份中，然后才更新托管文件。目标冲突检查发生在 runtime patch 之前，失败不会留下半安装的 runtime。

### 自定义安装路径

```bash
./scripts/install.sh \
  --oracle-root "/path/to/@steipete/oracle" \
  --codex-home "/path/to/codex-home" \
  --bin-dir "/path/to/bin" \
  --state-dir "/path/to/state"
```

同样可以使用对应环境变量：

| 变量 | 用途 |
| --- | --- |
| `ORACLE_WEB_ORACLE_ROOT` | 上游 npm package 根目录，必须含 `package.json` |
| `ORACLE_WEB_ORACLE_BIN` | wrapper 实际执行的上游 `oracle` |
| `ORACLE_WEB_CODEX_HOME` | 安装 Skill 的 Codex home |
| `ORACLE_WEB_BIN_DIR` | 安装 wrapper 的目录 |
| `ORACLE_WEB_STATE_DIR` | 安装回执目录 |

## 运行时配置

wrapper 不写入个人绝对路径。需要时在启动 Codex 的环境中设置：

wrapper 默认传入 `--browser-attachment-timeout 300s` 和 `--retain-hours 24`；调用者显式提供对应参数时，以调用者的值为准且不会重复添加。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `ORACLE_WEB_CHROME_USER_DATA_DIR` | `$HOME/Library/Application Support/Google/Chrome` | Chrome user-data 根目录 |
| `ORACLE_WEB_CHROME_PROFILE` | `Default` | 要复制的已登录 Profile 名称 |
| `ORACLE_WEB_SESSION_DIR` | `${XDG_STATE_HOME:-$HOME/.local/state}/oracle-web` | Oracle session 与 artifacts |
| `ORACLE_WEB_SESSION_RETENTION_HOURS` | `24` | 每次启动前清理超过该时长的 session 审计记录 |
| `ORACLE_WEB_REQUEST_MODEL` | `gpt-5.6-sol` | CLI 请求标识；不是网页实际模型证明 |
| `ORACLE_WEB_ORACLE_BIN` | `command -v oracle` | 上游 CLI 路径 |

示例：

```bash
export ORACLE_WEB_CHROME_PROFILE="Profile 2"
export ORACLE_WEB_SESSION_DIR="$HOME/.local/state/oracle-web"
```

## 在 Codex Desktop 中使用

可以直接告诉 Codex：

```text
使用 $oracle-web 审查这个复杂任务。先选择最小必要文件，让网页版返回结论、实现建议和验证要求，然后由当前 Codex 实现。
```

Skill 会自动判断：

| 情况 | 网页位置 | CLI 参数 |
| --- | --- | --- |
| 普通机械任务 | 不调用 Oracle | N/A |
| 复杂但边界清晰 | 第 4 项，共 5 项 | `extra-high` |
| 高风险、强耦合或确需多角度综合 | 第 5 项，共 5 项 | `max` |

网页标签可能随语言变化，因此日志必须同时证明位置。即使 CLI 输出 `requested=gpt-5.6-sol`，也不能据此声称网页实际选中了 GPT-5.6 Sol。

## 直接使用 wrapper

先预检；预检不会打开 ChatGPT，也不会上传文件：

```bash
oracle-web --dry-run summary --files-report \
  --browser-thinking-time extra-high \
  -p "审查这个模块的失败恢复设计" \
  --file "src/recovery/**" \
  --file "!**/*.snapshot.*"
```

确认文件范围和隐私后再发送：

```bash
oracle-web --timeout 20m \
  --slug "recovery-design-review-001" \
  --browser-thinking-time extra-high \
  -p "审查失败恢复设计，返回最小修改方案与验证要求" \
  --file "src/recovery/**"
```

每次独立咨询都应使用新的 slug。wrapper 会拒绝 `--browser-keep-browser`、`--browser-tab`、`--browser-attach-running`、`--followup` 和 `--browser-follow-up`，防止保留或复用旧网页。已确认提交后若只差回答捕获，按 Skill 使用上游 `oracle session <session-id>` 恢复同一会话；恢复完成也会清理它拥有的临时 Chrome。

## 强度、模型与 subagent 的边界

`oracle-web` 能调整的是外部 ChatGPT 咨询强度，不能改变已经运行中的 Codex 主任务。Oracle 可以建议后续实现使用哪个 Codex 模型、reasoning effort 或可选 subagent，但这些只是建议：

- 当前 Codex 必须检查建议是否可用、必要且在授权范围内。
- 不需要不同上下文或独立审查时，`optional_subagents` 应为空。
- 如果启动 implement subagent，必须限定文件或模块所有权。
- 当前 Codex 始终负责合并、回归测试和最终报告。

输出契约见 [`skill/oracle-web/references/execution-advice.md`](skill/oracle-web/references/execution-advice.md)。

## 多批咨询与防串线

优先减少文件，不要因为材料多就立即拆批。必须拆分时：

1. 发送前定义全部 batch 边界。
2. 每批使用独立 prompt、唯一 slug 和新 ChatGPT conversation。
3. 每批写明 `Batch: 1/2`、范围、排除项、问题和期望输出。
4. 浏览器 session 串行运行。
5. 当前 Codex 在本地汇总结果；后续 batch 不依赖前一批的隐式记忆。

这条规则专门避免“大 prompt 分两批后，第二批附着到错误会话”的问题。

## 安全与隐私

### 发送到 ChatGPT 的内容

任何 `-p` prompt 和 `--file` 文件都会提交给 ChatGPT 网页服务，可能受其日志、缓存和数据政策约束。发送前必须检查文件清单。

禁止上传：

- `.env`、API key、access token、private key。
- Chrome Profile、Cookie、登录数据库或 session artifacts。
- 生产数据库导出、未脱敏个人数据。
- 与问题无关的大目录、依赖和构建产物。

### Chrome Profile 复制

为了复用现有登录，上游 runtime 会把指定 Profile 和必要的 `Local State` 复制到临时目录。临时副本本身包含敏感认证状态：

- 本项目不会读取或打印 Cookie 内容。
- 不要把临时目录加入仓库、压缩包或错误报告。
- wrapper 正常结束、失败、超时或收到终止信号时都会要求 runtime 清理临时副本；恢复路径同样使用 `finally` 收尾。
- 清理优先调用本次 CDP client 的 `Browser.close()`；必要时只向 session 记录的 `chromePid` 发信号。代码不使用按名称批量杀进程的命令，也不操作 `controllerPid`。
- 删除目录前必须同时确认 copy-profile 模式、系统临时目录边界以及 `oracle-browser-*` / `oracle-reattach-*` 名称。正常 Chrome Profile 和 Codex 进程不在清理范围内。

### 公开仓库保证

离线测试会扫描仓库，拒绝包含维护者的 macOS home 绝对路径。CI 不登录 ChatGPT、不复制真实 Profile、也不发送 prompt。

## Runtime patch 做了什么

`patches/oracle-0.17.3.patch` 只支持上游 `0.17.3`，覆盖八个明确边界：

1. **Thinking time**：识别当前五档 power slider，通过真实 CDP pointer/keyboard 事件选择第 4、5 档，并对未验证选择 fail closed。
2. **Page readiness**：首次文档 readiness 超时只 reload 当前隔离 tab 一次；能力控件缺失时也只对当前页做一次 bounded reload，之后仍然 fail closed。
3. **Early runtime identity**：Chrome 启动后、首次导航前就持久化 PID、port 和 `userDataDir`，使早期失败也能按精确身份审计。
4. **Attachment readiness**：在 prompt 尚未写入时，不再把发送按钮因空编辑器而 disabled 误判为附件上传未完成；prompt 写入后，带附件的 disabled 发送按钮会在 300 秒窗口内继续轮询。
5. **Stable viewport**：本地自动化 Chrome 使用固定窗口尺寸；档位与发送动作在 pointer 输入前重新定位目标、比较 viewport、验证 DOM 命中，resize 后不使用旧坐标。
6. **Prompt submission**：始终优先真实 `#prompt-textarea`，先用 trusted CDP click 激活编辑器再写入；只有未出现 submission signal 时才单次 Enter 兜底，并要求 committed turn。
7. **Recovery lifecycle**：新开的 recovery Chrome 在连接失败或后续任意异常时都经幂等 `finally` 清理；附着到已有临时 runtime 后按精确 identity 关闭和删除，不复用或猜测别的窗口。
8. **Copied Profile reliability**：把临时副本标记为正常退出；`rsync exit 23` 只有在已复制 Cookie 数据库时才允许进入后续登录验证，否则仍然 fail closed。

安装器先检查七个原始文件 SHA-256。只有全部处于已知 pristine 状态时才应用 patch；全部处于已知 patched 状态时幂等退出；mixed 或 unknown 状态一律停止。

## 验证与测试

验证当前安装，不打开浏览器：

```bash
./scripts/verify.sh
```

运行完整离线测试：

```bash
./scripts/test.sh
```

离线测试会：

- 下载准确版本 `@steipete/oracle@0.17.3` 到临时目录，或使用 `ORACLE_TEST_PACKAGE_ROOT` 指定的副本。
- 安装 patch、wrapper 和 Skill。
- 模拟双编辑器 DOM，确认写入和 Enter 始终落在真实 `#prompt-textarea`。
- 验证窗口尺寸变化后旧坐标不会收到 pointer 事件，重新定位成功后只点击新坐标。
- 验证 `elementFromPoint` 与预期目标不一致时不点击，且判断不依赖 `document.visibilityState`。
- 验证 Chrome 窗口尺寸被恢复为 `1280×720`，失败时给出明确错误。
- 验证 recovery cleanup 幂等、只使用记录的 Chrome PID、拒绝普通 Profile，并禁止批量进程清理命令。
- 验证第二次安装幂等。
- 使用 fake Oracle 检查 wrapper 参数，不接触 ChatGPT。
- 卸载并验证 runtime 精确恢复 pristine 状态。
- 扫描公开文件中的个人绝对路径。

### 可选真实网页 smoke test

真实测试会向 ChatGPT 发送一条无敏感 prompt 和一个临时文本附件，因此默认拒绝运行。检查脚本后显式授权：

```bash
ORACLE_WEB_LIVE_TEST=1 ./scripts/live-smoke.sh
```

默认测试第 4 档。测试第 5 档：

```bash
ORACLE_WEB_LIVE_TEST=1 ORACLE_WEB_LIVE_LEVEL=max ./scripts/live-smoke.sh
```

默认 fixture 是一个小文本附件。多文件与接近真实审查体量的自动合包测试：

```bash
ORACLE_WEB_LIVE_TEST=1 ORACLE_WEB_LIVE_FIXTURE=bundle ./scripts/live-smoke.sh
ORACLE_WEB_LIVE_TEST=1 ORACLE_WEB_LIVE_LEVEL=max ORACLE_WEB_LIVE_FIXTURE=large-bundle ./scripts/live-smoke.sh
```

成功要求同时包含网页 `4/5` 或 `5/5` 证据和精确回复 `ORACLE-WEB-LIVE-OK`。
测试会强制上传临时附件，并使用 300 秒附件就绪上限。

## 故障排查

完整决策规则见 [`skill/oracle-web/references/troubleshooting.md`](skill/oracle-web/references/troubleshooting.md)。常见含义：

- `rsync failed copying Chrome profile`：Profile 复制阶段失败，没有证据表明内容已发送。
- `Page did not reach ready state in time`：同一隔离 tab 的一次 reload 后仍未就绪，强度和提交都未验证。
- `selection unverified`：强度不可信，必须停止且不能使用结果。
- `Attachments did not finish uploading before timeout`：附件完成状态没有得到证明。
- `attachment-send-not-ready`：附件卡片存在，但发送按钮在 300 秒窗口内始终没有变为 enabled；没有提交。
- `prompt-commit-timeout`：尝试过发送，但没有 committed user turn；`promptSubmitted=true` 仍不能算成功。

不要在 wrapper 运行时人工抢点发送按钮。安全恢复只适用于“已确认提交、但等待回答超时”的同一个 session。

## 更新

当前 patch 锁定 `0.17.3`。更新本仓库代码后，可以重新运行：

```bash
git pull --ff-only
./scripts/install.sh
./scripts/verify.sh
```

上游 Oracle 版本变化不是普通更新。必须重新审计 UI 行为、重新生成 patch 和 checksum，并分别通过第 4、5 档 live probe 后，才能声明支持新版本。安装器不会自动做这件事。

安装器为受管提交 `f0ea8d6` 提供精确迁移：7 个 runtime 文件全部匹配该提交的 patched checksum 时，才应用增量 patch。任何其他旧版本、混合状态或本地修改仍按 unknown runtime 停止，不会被 `--force` 覆盖。

安装器也为受管提交 `209f3ba` 提供精确迁移，用于把已安装的稳定窗口版本升级到当前版本。

安装器为受管提交 `2fe5969` 提供精确迁移，用于升级已经包含无文件名附件修复的安装。

Skill 安装到 Codex home 后，已有 Codex 任务在下一次调用 `oracle-web` 时读取当前安装版本。正在执行的咨询不会中途热更新；让该次运行结束，再发起一次新调用即可。

## 卸载与回滚

```bash
./scripts/uninstall.sh
```

卸载器会：

- 仅在 runtime 精确匹配本项目 patched checksum 时反向应用 patch。
- 仅删除仍与仓库版本相同的 wrapper 和 Skill 文件。
- 遇到未知 runtime 或用户改过的托管文件时会在修改 runtime 之前停止，避免半卸载；不会盲目覆盖。

自定义安装路径时，卸载应传入相同的 `--oracle-root`、`--codex-home`、`--bin-dir` 和 `--state-dir`。只有明确检查并接受覆盖时才使用 `--force`。

## 开发与贡献

修改时保持边界清晰：

- `skill/` 只描述 Codex 决策和安全工作流。
- `bin/` 只负责稳定地调用上游 Oracle，不放业务推理。
- `patches/` 只包含必须进入上游 runtime 的网页自动化修复。
- `scripts/` 负责可重复安装、校验和回滚。
- 普通 CI 永远不能发送 ChatGPT prompt。

变更 patch 时，必须从准确的 npm `0.17.3` pristine 包重新生成差异，同时更新原始/修改后 checksum。不要拿已经 patch 过的 Cellar 文件当作 pristine 基线。

## 上游与许可说明

本仓库使用 [MIT License](LICENSE)。上游 Oracle `0.17.3` 同样使用 MIT License；归属和商标说明见 [NOTICE.md](NOTICE.md)。
