# Dotfiles

Personal configuration installed by symlinking files and directories from this repository into a machine's home directory.

## Language

**Managed config**:
A repository file or directory installed through an operating-system manifest.
_Avoid_: Package, deployment

**Manifest entry**:
A `source|destination` mapping that declares one managed symlink.
_Avoid_: Install rule, copy rule

**Subagent session**:
A persisted Pi conversation for one delegated task, identified independently from the agent's role and reused for follow-up prompts.
_Avoid_: Run, result file, role session

**Subagent turn**:
One execution within a persisted subagent session.
_Avoid_: Launch, invocation

**Model profile**:
A model identifier and thinking-effort level selected together for a subagent session.
_Avoid_: Model, effort setting

**Supervisor**:
The interactive Pi session that classifies work by kind, delegates subagent sessions, and receives their escalations and completion reports.
_Avoid_: Main agent, parent, agent manager

**Kind**:
The supervisor's classification of a user task as research, implement, or write.
_Avoid_: Type, role, review

**Researcher**:
A subagent session that gathers information from the repository.
_Avoid_: Scout

**Implementer**:
A subagent session that changes code, not standalone documentation.
_Avoid_: Worker

**Writer**:
A subagent session that writes standalone documentation.

**Reviewer**:
A subagent session that judges an implementer's work after that implementer finishes.
_Avoid_: Critic, plan review

**Result artifact**:
The file-captured output of one subagent turn, kept as crash diagnostics and follow-up context; results normally reach the supervisor as intercom messages instead.
_Avoid_: Transcript, session

**Escalation**:
A mid-task contact from a subagent to its supervisor requesting a decision, requesting structured input, or reporting a plan-changing discovery.
_Avoid_: Question, interruption

**Completion report**:
The summary message a subagent sends to its supervisor over intercom when its task finishes.
_Avoid_: Final response handoff, done message

**Bridge metadata**:
The environment variables supplied at launch that equip a subagent session with the supervisor-contacting tool.
_Avoid_: Intercom config, orchestration env

**Orchestrator target**:
The supervisor's intercom presence name that subagent sessions address their messages to.
_Avoid_: Supervisor ID, parent name

**Watch pane**:
A terminal pane displaying one subagent turn.
_Avoid_: Monitor pane

**Watch window**:
The supervisor's dedicated `subagents` tmux window containing watch panes, including the retained completed pane.
_Avoid_: Log window, dedicated session
