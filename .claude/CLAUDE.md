## Rules

1. Think before coding: State assumptions explicitly. Ask rather than guess. Push back when a simpler approach exists. Stop when confused.
2. Simplicity first: Minimum code that solves a problem. Nothing speculative. No abstractions for single-use code.
3. Surgical changes: Touch only what you must. Don't improve adjacent code. Match existing style. Don't refactor what isn't broken.
4. Goal-driven execution: Define success criteria. Loop until verified. Strong success criteria let Claude loop independently.

## Conventions

- use conventional commit messages everywhere, including PR titles.

## Model Selection

For choosing the right model for workflow steps, subagents, and agent team members.
Ranks 1-10, higher = better.

### Dimentions

- Speed: latency + throughput.
- Taste: output craft - prose, coding, UI/UX, restraint.
- Intelligence: reasoning depth, long-horizon reliability, tool use, completion rate.
- Cost: efficiency of total spend to complete task, not per-token price. One-shot beats cheap-but-looping.

### Matrix

| Model | Speed | Taste | Intelligence | Cost |
| --- | --- | --- | --- | --- |
| Fable 5 | 2 | 10 | 10 | 2 |
| Opus 4.8 | 4 | 9 | 9 | 5 |
| Sonnet 5 | 5 | 7 | 8 | 7 |
| Sonnet 4.6 | 6 | 6 | 6 | 7 |
| Haiku 4.5 | 10 | 2 | 2 | 10 |

### Roles → dimension priorities

| Role | Tasks | Priority |
|---|---|---|
| Orchestrator / team lead | plan, decompose, delegate, synthesise | Intelligence > Taste > Cost > Speed |
| Heavy worker | complex implementation, deep analysis, long-horizon | Intelligence > Cost > Speed > Taste |
| Light worker | search, classify, extract, file reads, fan-out | Cost > Speed > Intelligence > Taste |
| Reviewer / critic | code review, verification, security, QA | Intelligence > Taste > Speed > Cost |
| Writer / communicator | docs, prose, UI copy, emails, reports | Taste > Intelligence > Cost > Speed |

### Selection

1. Classify task → role.
2. Exclude Fable 5 (gated, below).
3. Pick highest score on priority dim 1; tie → next dim; still tied → newer generation.

### Escalation

- Trigger: same task fails 2x (wrong, incomplete, looping).
- Action: re-run on next-highest Intelligence model.
- Ceiling: Fable 5 — reachable only via escalation or explicit human instruction, never a starting model.
- Post-escalation: similar tasks in session may start at escalated model.

### Fable 5 gate

- Never autonomous starting model.
- Has safety classifiers, can refuse mid-task. Classifier refusal → stop escalating, no retry, surface to human.
