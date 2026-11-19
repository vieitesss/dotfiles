# Manager always delegates implementation

The Manager is invoked with `/manager` only when the user is ready to
implement. It manages Subagents and never builds: it does not edit repository
files. It may read files, run tests and lint, and merge finished branches.
Every round that writes code runs in fresh Subagents, and every code round is
reviewed by fresh Subagents, one per axis.

Shape, Design, Diagnose, Plan, Prove, and Ship leave the Manager, and so does
the trivial path. The Manager's Stages are Research, Build, Write, Refine, and
Review. Grilling, design, diagnosis, and planning happen before the Manager is
invoked; shipping happens after it reports.

This supersedes [ADR 0002](0002-manager-on-request.md), which let the Manager
do trivial work itself and launch a Subagent only when a trigger held. That
saved spawn latency, but it blurred who edits the code, and a Manager that also
builds carries the implementation context that the Subagent split keeps out.

## Considered options

- **Keep the trivial path.** The Manager builds one-line fixes itself. Rejected:
  the rule that the Manager never builds is what keeps its context on decisions,
  and a trivial path is where that rule would quietly erode.

## Consequences

- Each Build or Refine round is followed by Review. Spec always runs. Standards
  and Debt run when the change spans several modules or reshapes one. Write is
  not reviewed, and Review has no proof budget.
- A small code change costs one Subagent launch plus a Review round. That is the
  price of keeping the Manager out of the code.
- The Manager closes a Subagent's window once its report is accepted.
