## Resume: agent-drop design spec — awaiting approval before writing the implementation plan

**Artifact:** `docs/superpowers/specs/2026-09-10-agent-drop-design.md`
(in the `screenpresso-localsend` repo, branch `docs/agent-drop-spec` — parked there
only because the target repo `freaxnx01/agent-drop` does not exist yet).

**Phase:** brainstorming, architectural path. The spec is **complete but DRAFT** —
it has NOT been approved. No code exists. Design decisions D1–D7, the rejected
alternatives, the measured benchmarks and three hard-won gotchas are all recorded
in the spec; read it first and do not re-litigate settled decisions.

**Next step:** get the user's answers to the three open items in §11 of the spec —
(1) what `remoteDir` should be on `srvdmsk8s01`, (2) approval of the design plus a
chance to flip D6 (`archive` vs `delete` default) and D7 (single-phase clipboard),
(3) optionally the home-box facts for Phase 3. Only once approved: invoke
`superpowers:writing-plans` to turn the spec into an implementation plan, then
execute that plan with `superpowers:subagent-driven-development`. When the
`agent-drop` repo is created, move the spec into it.

**Do not** skip the approval gate, and do not start implementing from the spec alone.
