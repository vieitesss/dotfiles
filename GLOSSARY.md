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

### Rex project picker

How the Rex key `o` finds a place to work across machines.

**Host**:
A machine running a Rex server, named by a short label such as `mac` or `rpi`.
_Avoid_: Server, machine, endpoint

**Current host**:
The Host of the session the user is focused on when opening the picker.
_Avoid_: Local host, this machine

**Project**:
A directory on a Host that a session can be opened in.
_Avoid_: Repo, folder, workspace

**Session**:
A running Rex session on a Host, which the picker can switch to.
_Avoid_: Tab, window

### Agent workflow

How the user, a Manager, and its Subagents divide work in a session.

**Manager**:
The agent the user has put in charge of a session with `/manager`; it owns every decision, review, and the final report, and delegates all implementation to Subagents.
_Avoid_: Supervisor, parent, orchestrator

**Subagent**:
An agent launched in its own session to run one Stage of a Work Item (under a Manager) or an ad-hoc task and report back; it never delegates.
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

**Harness**:
The agent CLI runtime that executes a session, such as `pi`, `agy`, `claude`, or `opencode`.
_Avoid_: Engine, runner, backend

**Model profile**:
A named role's default Harness, model, and thinking effort — such as builder, writer, or critic — which launch flags can override.
_Avoid_: Model, effort setting

**Question**:
A mid-Stage message from a Subagent to the Manager asking for a decision, asking for input, or reporting a plan-changing discovery.
_Avoid_: Escalation, interruption

**Completion report**:
The summary a Subagent sends the Manager when its Stage finishes, pointing at its report file.
_Avoid_: Final response handoff, done message
