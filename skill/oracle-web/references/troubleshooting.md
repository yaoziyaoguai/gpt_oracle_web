# Troubleshooting

Use the session metadata and concise browser log as evidence. Do not print prompt bodies, cookies, credentials, or Chrome Profile contents.

## Failure meanings

- `rsync failed copying Chrome profile`: no browser consultation started. The source Profile changed or could not be copied. Do not claim content was sent.
- `Page did not reach ready state in time`: ChatGPT never exposed a usable composer after one bounded reload of the same isolated tab. Thinking strength and submission were not verified.
- `selection unverified` or a different slider position: fail closed. Stop and do not use any answer.
- `Attachment did not appear in ChatGPT composer`: the file-input step produced no accepted attachment evidence. A new upload-specific card or file-count UI is valid even when the page omits the local filename; an auto-generated multi-file bundle may appear as one card without the internal `attachments-bundle.txt` name.
- `Attachments did not finish uploading before timeout`: attachment readiness was not proven. A visible draft card alone is not a submitted message.
- `attachment-send-not-ready`: attachment UI appeared, but the visible send button never became enabled within the configured attachment timeout. No committed turn was proven.
- `Failed to set stable Chrome window bounds`: the owned window could not be restored to `1280x720`; no critical UI action should continue.
- `trusted-target-mismatch`: none of the checked points inside the re-located target passed DOM hit testing. A covered composer can continue without a pointer click only when the current visible editor owns `document.activeElement`; the send control and every unverified editor still fail closed.
- `trusted-target-resized`: the viewport kept changing across three fresh probes. Old coordinates were discarded and no pointer click was sent.
- `prompt-insertion-unverified`: the runtime used the verified focused composer but could not read the inserted prompt back from the editor. No send action was attempted.
- `prompt-commit-timeout`: a send action was attempted but no committed user turn appeared. `promptSubmitted=true` is not success.
- `browser-run-timeout`: the shared browser deadline expired. Submission, answer capture, and recheck do not receive fresh timeout budgets.
- `connection-lost`: CDP disconnected before completion. A copied-profile run is not retained for recovery; verify that its recorded Chrome PID stopped and its temporary Profile was removed.

## Safe checks

1. Inspect the exact session's `status`, structured `error`, `browser.modelSelection`, `browser.runtime.promptSubmitted`, and `browser.runtime.interruptedSignal`.
2. Read `browser.runtime.chromePid`, `chromePort`, `chromeTargetId`, `userDataDir`, and `controllerPid` from that exact session. These fields identify the owned browser; timestamps and window titles do not.
3. After the run exits, verify only the recorded `chromePid` and temporary `userDataDir`. Never use a process-name-wide kill, never signal `controllerPid`, and never delete a normal Chrome Profile.
4. If selection or submission was not confirmed, stop. Do not click the browser manually and do not automatically create another session.
5. If submission was confirmed and only response capture timed out, recover that exact session with the same configured `ORACLE_HOME_DIR`. Recovery cleanup is scoped to that session's recorded temporary browser identity.
6. Run `scripts/verify.sh` from the repository when installation drift is suspected.

Covering the Oracle window with another application is not a cleanup or target-identity problem, and the runtime does not use `document.visibilityState` as click evidence. Restoring the window from a minimized state or stopping an active resize can unblock Chrome compositing; retry policy still follows the main Skill.
