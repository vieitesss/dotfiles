# Dotfiles

Personal configuration installed by symlinking files and directories from this
repository into a machine's home directory, plus the agent workflow its skills
define.

## Language

**Managed config**:
A repository file or directory installed through an operating-system manifest.
_Avoid_: Package, deployment

**Manifest entry**:
A `source|destination` mapping that declares one managed symlink.
_Avoid_: Install rule, copy rule

### Agent workflow

How the user, a Manager, and its Subagents divide work in a session.

**Manager**:
The agent the user has put in charge of a session with `/manager`; it owns every decision, review, and the final report.
_Avoid_: Supervisor, parent, orchestrator

**Subagent**:
An agent the Manager launches in its own tab to run one Stage of one Work Item and report back; it never delegates.
_Avoid_: Child, worker, delegate

**Work Item**:
One thing to deliver in a session, small enough to pass through the Stages on its own.
_Avoid_: Task, ticket, job

**Change Set**:
The Work Items reviewed together as one diff before they are shipped.
_Avoid_: Batch, PR

**Stage**:
A named step every Work Item passes through or skips, such as Build or Review; it decides which skills a Subagent uses.
_Avoid_: Step, phase, kind

**Ledger**:
The Manager's record of a session's Work Items and the Stage each one is at.
_Avoid_: Tracker, todo list

**Model profile**:
A model identifier and thinking-effort level selected together for a Subagent.
_Avoid_: Model, effort setting

**Question**:
A mid-Stage message from a Subagent to the Manager asking for a decision, asking for input, or reporting a plan-changing discovery.
_Avoid_: Escalation, interruption

**Completion report**:
The summary a Subagent sends the Manager when its Stage finishes, pointing at its report file.
_Avoid_: Final response handoff, done message
