# Troubleshooting

Use the session metadata and concise browser log as evidence. Do not print prompt bodies, cookies, credentials, or Chrome Profile contents.

## Failure meanings

- `rsync failed copying Chrome profile`: no browser consultation started. The source Profile changed or could not be copied. Do not claim content was sent.
- `Page did not reach ready state in time`: ChatGPT never exposed a usable composer. Thinking strength and submission were not verified.
- `selection unverified` or a different slider position: fail closed. Stop and do not use any answer.
- `Attachments did not finish uploading before timeout`: attachment readiness was not proven. A visible draft card alone is not a submitted message.
- `prompt-commit-timeout`: a send action was attempted but no committed user turn appeared. `promptSubmitted=true` is not success.

## Safe checks

1. Inspect the exact session's `status`, structured `error`, `browser.modelSelection`, and `browser.runtime.promptSubmitted`.
2. Check for an active wrapper, upstream Oracle process, or isolated `oracle-browser-*` Chrome process separately from any launch command.
3. If selection or submission was not confirmed, stop. Do not click the browser manually and do not automatically create another session.
4. If submission was confirmed and only response capture timed out, recover that exact session with the same configured `ORACLE_HOME_DIR`.
5. Run `scripts/verify.sh` from the repository when installation drift is suspected.
