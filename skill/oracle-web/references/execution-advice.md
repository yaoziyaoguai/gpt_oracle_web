# Codex execution advice

Ask Oracle to separate its analysis from implementation advice and finish with this structure:

```yaml
codex_execution_advice:
  implementation_plan:
    - <ordered, concrete step for the current Codex>
  non_goals:
    - <explicit exclusion>
  optional_subagents:
    - role: analyze | implement | review
      model: <available Codex model>
      reasoning_effort: <supported effort>
      rationale: <why delegation materially helps>
      scope:
        - <bounded responsibility>
      prompt: |
        <self-contained instructions>
  verification:
    - <check and expected evidence>
```

Use `optional_subagents: []` when the current Codex can implement efficiently by itself. A recommendation is not authorization: the parent independently checks model availability, scope, safety, and cost before delegating.

The running parent cannot switch its own model or effort in place. A different model or effort can be used only by a separately configured task or an optional bounded subagent. The parent remains responsible for integration, review, tests, and the final report.
