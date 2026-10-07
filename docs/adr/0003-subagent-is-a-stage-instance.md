# A Subagent is one Stage of one Work Item

`subagent.py --stage <stage>` is the only way to launch a Subagent: the Stage fixes its skills (and, for Write and Review, its model) from one table in the script, and Jev judges only the model and effort the table leaves open. Every Stage, and every fix round, runs in a fresh Subagent; follow-ups before the Manager accepts a report go to the same one. We traded away Jev's per-skill scoring and the `--skill` override because they loaded unrelated skills and hid which Stage a Subagent was in, and we traded away Build's context in Refine and Review for fresh eyes and clean isolation; Stages hand over through report files and the worktree diff instead.

> Update: [ADR 0004](0004-host-extensions-are-markdown.md) keeps this routing but splits launching in two: `subagent.py --stage` is the only way to prepare a Stage, and the host extension starts the session.
