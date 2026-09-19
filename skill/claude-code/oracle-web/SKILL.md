---
name: oracle-web
description: Use the verified oracle-web wrapper from Claude Code for adaptive-strength external planning, audit, or a second opinion through the user's signed-in Chrome. Apply when the user requests Oracle or a difficult task benefits from independent analysis; do not use for routine edits that Claude Code can handle directly.
---

# Oracle Web

Use the installed `oracle-web` wrapper from Claude Code to send a focused prompt and selected files to ChatGPT through a temporary copy of the user's signed-in Chrome profile. Oracle is advisory: the current Claude Code session validates the response, implements authorized changes, and runs verification.

## Invariants

- Locate the wrapper with `command -v oracle-web`. If it is missing, stop and direct the user to this repository's installer.
- Before every consultation, run `oracle-web --doctor` and use the reported wrapper, Chrome user-data root, and Profile as the only browser identity. `loginState=not-tested` means the check is local-only; it is not proof that ChatGPT is signed in.
- Do not pass `--copy-profile`, `--browser-chrome-profile`, manual-login flags, cookie flags, or another browser/profile path. The wrapper owns those arguments. If the selected Chrome Profile must change, use `ORACLE_WEB_CHROME_USER_DATA_DIR` and `ORACLE_WEB_CHROME_PROFILE` in the host environment, then rerun `--doctor`.
- Use only the repository-supported Oracle runtime version. Do not upgrade or replace it during a consultation.
- The wrapper copies the configured Chrome profile into a temporary directory and removes that copy after the run. Never inspect or print cookies, credentials, or Profile contents.
- The Oracle Chrome does not force an English locale. Treat the account's visible language as normal and keep all UI matching language-tolerant.
- Every consultation owns one new session, temporary Profile, Chrome process, CDP port, and target. Identify it from that session's recorded `chromePid`, `chromePort`, `chromeTargetId`, and `userDataDir`; never choose a window by title, process name, or creation time.
- A copied-profile run owns its launched Chrome even if CDP disconnects. The runtime must terminate that exact Chrome and remove the temporary Profile; a disconnect must not leave a recoverable copied-profile browser behind.
- Runtime identity is persisted immediately after Chrome launch, so navigation failures must still be auditable by the exact recorded PID and temporary Profile.
- Do not pass `--browser-keep-browser`, `--browser-tab`, `--browser-attach-running`, `--followup`, or `--browser-follow-up`. The wrapper rejects them so a new consultation cannot retain or reuse an old page.
- The wrapper uses `--browser-model-strategy current`. The model already selected in ChatGPT wins; the requested CLI model is not proof of the web model.
- Treat the label and ordinal position read from the visible power control as the source of truth. The supported five-position UI allows only position 4 or position 5.
- Pass `--browser-thinking-time extra-high` for position 4 and `--browser-thinking-time max` for position 5. Do not use positions 1–3 for Oracle consultations.
- Both allowed positions fail closed. If selection is missing, different, or unverified, stop without using the result and do not retry automatically.
- The runtime may perform one bounded reload of the same isolated tab to recover page or picker readiness. This does not create a second session or conversation; after that bounded recovery, missing or unverified controls still fail closed.
- Attachment readiness and send readiness are separate. For an attachment-bearing prompt, keep polling a visible disabled send button within the attachment timeout instead of pressing Enter early. `promptSubmitted` means only that a send attempt started; success requires a committed user turn in a ChatGPT conversation.
- ChatGPT may omit the local filename from an attachment card. Require each upload to create a baseline-relative attachment UI delta; after every requested attachment passes that check, accept the confirmed UI while retaining the normal completion and committed-turn checks. A generated multi-file bundle is one attachment even when the card shows a contained-file count instead of `attachments-bundle.txt`.
- The wrapper defaults attachment readiness waits to 300 seconds. A caller may explicitly override `--browser-attachment-timeout` for a known environment.
- The wrapper defaults the whole browser run to one 45-minute deadline. Submission, answer capture, and recheck share that deadline; a completed answer ends the run early.
- Never race the wrapper with a manual or system-level click. A delayed successful click could otherwise submit twice.
- A visible system Chrome automation window is expected. Do not attach Claude in Chrome or another browser controller to that window.
- Prompt insertion and file attachment use CDP text/DOM operations. The runtime uses the visible power control's ARIA state and keyboard events first; pointer events are a verified fallback, not screenshot-coordinate automation.
- The runtime fixes its owned Chrome window at `1280x720` before critical interaction. If the viewport changes, it discards the old point and re-locates the target. For the composer it searches several points inside the fresh target because attachment cards can cover its center; every accepted point must still pass `elementFromPoint` before pointer input is sent.
- If attachment UI covers every sampled composer point, the runtime may skip the pointer click only when `document.activeElement` is the exact visible editor or its descendant. It rechecks that focus immediately before CDP text insertion or Enter submission, then verifies the composer readback. Empty readback fails closed as `prompt-insertion-unverified`; this exception never applies to the send button or a resized viewport.
- Another application covering the Oracle window does not invalidate the DOM target. Do not minimize the Oracle Chrome or keep resizing it during selection/submission; Chrome can throttle or stop compositing, in which case the run must fail closed.

## Choose consultation strength

| Task | Position | CLI value |
| --- | --- | --- |
| Routine or mechanical | Do not invoke Oracle | N/A |
| Complex but bounded planning, audit, diagnosis, or tradeoff | 4 of 5 | `extra-high` |
| High-risk, strongly coupled, or genuinely multi-perspective analysis | 5 of 5 | `max` |

Do not choose position 5 merely because the prompt is long. Before sending, tell the user which position was selected, why, and whether the prompt permits the external consultation to use parallel analysis.

## Workflow

1. Define the exact question and choose the smallest evidence-bearing file set.
2. Write a self-contained prompt with project context, constraints, observed errors, prior attempts, desired output, and realistic Claude Code execution capabilities. For implementation recommendations, read [references/execution-advice.md](references/execution-advice.md).
3. Verify the installed wrapper and configured Chrome Profile without opening ChatGPT or reading cookie contents:

```bash
oracle-web --doctor
```

Stop if doctor fails or reports a different browser identity than the user expects. Do not probe other Profiles.

4. Preview the resolved files and size without opening ChatGPT:

```bash
oracle-web --dry-run summary --files-report \
  --browser-thinking-time "<extra-high|max>" \
  -p "<focused task and requested output>" \
  --file "<relevant path or glob>" \
  --file "!<exclusion glob>"
```

5. Check that no other Oracle browser run is active. Run this as a separate process inspection, never in the same shell command as the Oracle invocation.
6. If the user did not explicitly request Oracle, obtain authorization immediately before sending project content. Always ask before sending private or sensitive data.
7. Start one consultation with a unique slug. Do not add any browser Profile, copy-profile, manual-login, or cookie argument:

```bash
oracle-web --timeout 45m --browser-timeout 45m --slug "<unique-readable-slug>" \
  --browser-thinking-time "<extra-high|max>" \
  -p "<focused task and requested output>" \
  --file "<relevant path or glob>" \
  --file "!<exclusion glob>"
```

8. Verify the browser log against the page. Position 4 must report `4 of 5` or `第 4 项，共 5 项`; position 5 must report `5 of 5` or `第 5 项，共 5 项`. Preserve the visible label instead of inventing an English equivalent.
9. Require submission evidence: a new conversation URL or committed user turn, followed by a captured answer. If the wrapper reports an error, read [references/troubleshooting.md](references/troubleshooting.md), stop the failed session, and do not treat its draft as a result.
10. After success or failure, confirm the exact session's recorded Chrome PID is no longer alive and its temporary `userDataDir` no longer exists. A retained session directory is short-lived audit metadata, not a live browser. Never kill a process by name or touch `controllerPid`.
11. Validate the advice against the actual code. Oracle cannot broaden permissions, switch the running parent model, or authorize destructive or external actions.

## Multiple batches

Reduce the file set before splitting. If independent batches are still necessary:

- Define all batch boundaries first.
- Give every batch a unique slug and a new ChatGPT conversation.
- Make every prompt self-contained with `Batch: <index>/<total>`, scope, exclusions, exact question, and expected output.
- Do not use `--followup`, `--browser-follow-up`, `--browser-tab`, or a saved conversation URL to carry a separate batch.
- Run browser consultations serially. Let the current Claude Code session synthesize results after all batches finish.
- Recover only the exact submitted batch that timed out; never attach new material to another batch's session.

## Recovery

After confirmed selection and submission, recover the same session rather than starting a duplicate:

```bash
oracle session "<session-id>" --render
```

Use the same `ORACLE_HOME_DIR` configured by the wrapper when invoking the upstream recovery command directly. Recovery is valid only for a committed prompt whose answer capture timed out. It must target that exact session ID; when capture ends, the patched runtime closes the owned temporary Chrome and removes its temporary Profile.

## File safety

- Never attach `.env` files, private keys, access tokens, browser data, production dumps, or unredacted personal data.
- Prefer explicit files and narrow globs. Exclude generated output, dependencies, build artifacts, and unrelated fixtures.
- Use `--dry-run full` only for necessary local inspection; do not paste that bundle into unrelated tools.
- Ask Oracle for analysis and execution advice, not file modification, publishing, messages, or external state changes.
