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

**Result artifact**:
The final response from one subagent turn saved for the parent agent to read; it is not the complete session history.
_Avoid_: Transcript, session

**Model profile**:
A model identifier and thinking-effort level selected together for a subagent session.
_Avoid_: Model, effort setting
