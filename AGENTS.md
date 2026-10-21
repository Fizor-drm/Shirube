## Agent selection

- Prefer current code, config, Source of Truth, and execution results. Never fill in specs by guessing.
- The parent agent decides scope, execution mode, and completion criteria; it delegates implementation by default and handles necessary integration itself. Do not launch unnecessary agents.
- Before delegating, call `orchestrator_capabilities` (T3 Code, `pingdotgg/t3code`) to confirm the available providers, models, and options.
- Launch every agent below with `delegate_task` (T3-owned child), always passing `target.providerInstanceId`, `target.model`, and `target.options` explicitly. Never rely on inheritance: it is lost when the provider or model changes, and an unset model on another provider falls back to that provider's first catalog model. Do not use provider-native subagents (e.g. `collaboration.spawn_agent`) for these agents; their provider / model selection is not guaranteed. When a superpowers skill tells you to dispatch a subagent, launch it with `delegate_task` per the Agents table instead of the skill's default mechanism.
- Effort keys differ by provider: Codex `options.reasoningEffort`; OpenCode `options.variant`; Antigravity has none (effort is part of the model name).
- After launch, verify `providerInstanceId` and `model` in the launch result / `task_status` against the spec. The API does not report effort, so confirm only that it was passed. If `model` is not returned (null), report it as unverified, never as success, and ask the user whether to continue. If unavailable (e.g. `model_unavailable`) or mismatched, stop, report to the user, and wait for instructions. Never substitute models, fall back to defaults, or silently swap in a general subagent, a different execution mode, or a different provider.
- `delegate_task` does not copy the parent's conversation, and delivery of `AGENTS.md` / global rules to children is not guaranteed. Each task text therefore states the goal, scope, off-limits areas, reference files, completion criteria, verification, and constraints (including read-only where it applies and the Baseline). When splitting work in Native mode, it also states each owner's scope, edit targets, dependencies, and the integrator; never parallelize conflicting edits.
- Never use ChatGPT-family models via OpenCode. GPT models are allowed only via Codex.
- "Critical" means anything that affects data loss, security, or public API / compatibility. The parent decides; when unsure, treat it as critical.

## Agents

| Agent | provider / model / options | When to launch / role |
|---|---|---|
| Analysis | `antigravity` / `gemini-3.8-flash-high` / none | Only when investigating a bug with unknown cause, or design, dependencies, or impact (multiple files alone is not enough). Organize code, constraints, change candidates, and test perspectives. |
| Implementation | `opencode` / `zen-proton/deepseek-v4.1-flash-free` / `variant: Max` | The only model allowed on OpenCode. Before starting, check scope, existing changes, and affected areas. Follow `superpowers:test-driven-development` for tests, implementation, and verification. Skipping new tests is allowed only when existing tests can verify the behavior; otherwise prefer TDD. No out-of-scope edits, unnecessary abstractions, or reverting existing changes. Report results of related tests and the required lint / typecheck / build, plus anything unverified. |
| Review | `codex` / `gpt-6.1-sol` / `reasoningEffort: high` | Follow `superpowers:requesting-code-review`: check the diff, related code, test results, and consistency with the request. Attach severity, evidence, location, and fix condition to each finding. |
| Consultation | `codex` / `gpt-6.1-sol` / `reasoningEffort: max` | Only when hard design decisions, critical trade-offs, or disagreements remain after Analysis. |
| Audit | `antigravity` / `gemini-3.8-flash-high` / none | Runs `security-audit` as described in "Security audit". Does not edit the repo (audit output goes outside it). |

Analysis / Review / Consultation are read-only: launch them with `interactionMode: "plan"` and state "read-only" in the task text. This is an instruction-level constraint, not OS-enforced (`runtimeMode: approval-required` is not a write ban), so the parent checks the diff afterward. Audit writes its output outside the repo, so it is not launched in plan mode; its task text forbids repo edits. Implementation is not launched in plan mode, and its `runtimeMode` follows the user's setting. Because plan mode may block command execution, Review uses the reported test results; if a re-run is needed, the parent runs it and passes the result.

## Execution mode

"Native" and "Subagent-driven" are execution modes of this workflow; they are unrelated to provider-native subagents. The parent chooses the mode before starting, based on whether each Task needs independent review (not on whether work is split or how large it is). Both modes apply the model constraints, implementation/review separation, and security audits.

- **Native (default)**: Delegate to one Implementation agent by default (split across several in parallel only when the work is independent and splitting clearly helps). The parent integrates (implementing the integration part if needed) and verifies, then an independent Review agent reviews the whole change. No per-Task review.
- **Subagent-driven**: Use `superpowers:subagent-driven-development` when each Task needs its own implementation, verification, and independent review.
- Review NG: the Implementation agent that owns the flagged area fixes it with new commits (the parent for integration parts) → verify → a Review agent different from the implementer re-reviews. Re-review at most 6 times; beyond that the parent stops and reports. Never close out with unresolved critical findings.

## Flow

- Normal: `Implementation → Review`
- With investigation: `Analysis → Implementation → Review`
- Critical design decision: `Analysis → Consultation → Implementation → Review`
- If investigation or consultation alone resolves the request, do not launch Implementation / Review.
- Security audits run alongside this flow (see "Security audit").

## Commits

- Commit in small logical units: one behavior, fix, or refactor per commit, together with its tests. Do not mix refactors with behavior changes.
- Commit only when the related verification passes; never commit a failing state.
- The agent that made a change commits it (the parent for integration changes). When work is split in parallel, each agent stages only its own files by explicit path (never `git add -A` or `git add .`), so commits do not absorb other agents' changes.
- Delegated tasks share the parent's working tree, and `delegate_task` cannot set a branch or worktree. Before delegating, the parent confirms work is on a non-default branch, creating one if needed.
- Never amend, rebase, reset, or force-push existing commits without explicit permission.

## Security audit

Uses the Cloudflare `security-audit` skill (`cloudflare/security-audit-skill`).

- Use tests and independent code review by default. Routine UI, layout, navigation, business-logic fixes, refactors, documentation, tests, comments, and formatting do not require a security audit unless the diff materially changes a security boundary or review identifies a concrete security concern. The parent decides from the actual diff and affected runtime paths, not file names or keywords alone.
- Run a scoped `quick` audit when a coherent change materially affects authentication, authorization, secret handling, validation at an external trust boundary, security-relevant configuration or dependencies, external communication, or cryptography. Batch related commits and review fixes into one checkpoint; do not audit every commit, delegated Task, or review round. Report it as partial coverage and record the audited HEAD as the next starting point. Launch alongside independent Review with `mode: "async"` when applicable.
- A push, PR, merge, release candidate, or deployment is not an audit trigger by itself. Before publishing or activating a qualifying security-sensitive change, audit any relevant changes not yet covered. Low-risk local deployments need tests, review, backup, and runtime verification, not an automatic audit.
- Re-audit a confirmed security fix or a later change that materially alters a security boundary. Ordinary review fixes do not trigger another audit. Do not repeat an audit for unchanged code or solely because the same environment limitation remains; report incomplete coverage honestly and never proceed with unresolved critical findings.
- Run a full `standard` audit only on explicit user request, a major new or redesigned trust boundary, or a high-risk release with broad security-sensitive changes. The parent states the concrete reason and scope before launching it.
- State the audit decision and reason once per coherent change in the final report. Keep tests, independent review, and resolution of critical findings even when no audit is needed.
- The parent launches the Audit agent; the implementer never audits its own change.
- Never use GPT-family models for audits (token cost), including the hunters / verifiers the skill spawns, unless the user explicitly approves. The skill does not pin those models, so the Audit task text must forbid GPT-family models and providers other than the spec, and the parent checks what it can via `task_status`.
- If the Audit agent or the `security-audit` skill is unavailable (for example, not installed for the Audit agent's provider), stop and report instead of switching models or treating the change as audited.
- Keep audit output outside the repo (the skill's default location). Write into the repo only to a VCS-ignored directory.
- Resolve every `confirmed` finding (fix via Implementation, then re-audit). For each `needs_validation`, the parent checks the stated evidence before proceeding. If it cannot be resolved (for example, no sandbox to run the target code), record it as unresolved and continue unless it is critical. State anything not run or unresolved in the final report.

## Operation rules

- The parent does not rely on reports alone: check the diff, verification results, and open issues, and re-run the relevant verification after integration. Resume on completion notifications; do not poll with sleep or similar.
- On errors or verification failures, identify cause and impact and delegate the fix; if unresolved, stop and report.
- Obsidian Vault (`om`) search and recording are done by the parent only. Child agents do not access the Vault; the parent passes only the constraints a task needs.
- The final report states changes, verification commands and results, review / audit results, and open issues, and marks anything not run as not run.

## Baseline (repeated from the global rules because child agents may not receive them)

- Make only minimal changes within the requested scope: no unnecessary abstractions or unrelated edits.
- No destructive operations, secret exposure, or discarding of existing changes without prior explicit permission.
- Report failures and unverified items honestly; never treat unverified work as success.
