# Troubleshooting

Use the session metadata and concise browser log as evidence. Do not print prompt bodies, cookies, credentials, or Chrome Profile contents.

## Failure meanings

- `rsync failed copying Chrome profile`: no browser consultation started. The source Profile changed or could not be copied. Do not claim content was sent.
- `Page did not reach ready state in time`: ChatGPT never exposed a usable composer after one bounded reload of the same isolated tab. Thinking strength and submission were not verified.
- `selection unverified` or a different slider position: fail closed. Stop and do not use any answer.
- `Attachments did not finish uploading before timeout`: attachment readiness was not proven. A visible draft card alone is not a submitted message.
- `attachment-send-not-ready`: attachment UI appeared, but the visible send button never became enabled within the configured attachment timeout. No committed turn was proven.
- `prompt-commit-timeout`: a send action was attempted but no committed user turn appeared. `promptSubmitted=true` is not success.

## Safe checks

1. Inspect the exact session's `status`, structured `error`, `browser.modelSelection`, and `browser.runtime.promptSubmitted`.
2. Read `browser.runtime.chromePid`, `chromePort`, `chromeTargetId`, `userDataDir`, and `controllerPid` from that exact session. These fields identify the owned browser; timestamps and window titles do not.
3. After the run exits, verify only the recorded `chromePid` and temporary `userDataDir`. Never use a process-name-wide kill, never signal `controllerPid`, and never delete a normal Chrome Profile.
4. If selection or submission was not confirmed, stop. Do not click the browser manually and do not automatically create another session.
5. If submission was confirmed and only response capture timed out, recover that exact session with the same configured `ORACLE_HOME_DIR`. Recovery cleanup is scoped to that session's recorded temporary browser identity.
6. Run `scripts/verify.sh` from the repository when installation drift is suspected.
