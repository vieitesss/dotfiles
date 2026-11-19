# A Subagent is one Stage of one Work Item

`subagent.py --stage <stage>` is the only way to launch a Subagent: the Stage fixes its skills (and, for Write and Review, its model) from one table in the script, and Jev judges only the model and effort the table leaves open. Every Stage, and every fix round, runs in a fresh Subagent; follow-ups before the Manager accepts a report go to the same one. We traded away Jev's per-skill scoring and the `--skill` override because they loaded unrelated skills and hid which Stage a Subagent was in, and we traded away Build's context in Refine and Review for fresh eyes and clean isolation; Stages hand over through report files and the worktree diff instead.

> Update: [ADR 0004](0004-host-extensions-are-markdown.md) keeps this routing but splits launching in two: `subagent.py --stage` is the only way to prepare a Stage, and the host extension starts the session.

> Update (2026-11-15): a Subagent that compacts has lost part of its brief, so the Manager sizes each Stage to one context window and splits larger Work Items before launch. When a report mentions compaction or dropped part of its brief, the rest is split across fresh Subagents instead of going to the same one as a follow-up.

> Update: [ADR 0007](0007-bash-launcher-rex-only.md) replaces `subagent.py` with one bash script, `agents/skills/subagents/scripts/subagent`. `subagent launch --stage <stage>` is still the only way to start a Subagent, and the Stage table in that script still fixes each Stage's skills and model profile. Jev no longer judges the effort: each model role has one fixed effort, and no host extension starts the session.
