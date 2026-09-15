# Claude Code execution advice

Ask Oracle to separate its analysis from implementation advice and finish with this structure:

```yaml
claude_code_execution_advice:
  implementation_plan:
    - <ordered, concrete step for the current Claude Code session>
  non_goals:
    - <explicit exclusion>
  optional_subagents:
    - role: analyze | implement | review
      agent_type: <available Claude Code agent type>
      model: <available Claude model or inherit>
      effort: <supported effort or inherit>
      rationale: <why delegation materially helps>
      scope:
        - <bounded responsibility>
      prompt: |
        <self-contained instructions>
  verification:
    - <check and expected evidence>
```

Use `optional_subagents: []` when the current Claude Code session can implement the work by itself. A recommendation is not authorization: the parent checks agent availability, model and effort support, scope, safety, and cost before delegating.

The running parent does not change its own model or effort in place. A separate background task or bounded subagent may use a supported model and effort. The parent remains responsible for integration, review, tests, and the final report.
