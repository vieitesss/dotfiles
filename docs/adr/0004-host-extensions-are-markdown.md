# Host extensions are Markdown the agent reads

A session host (Paseo, herdr, tmux, or one not written yet) is a Markdown file the Manager and its Subagents read and follow. `subagent.py` prepares the Stage and prints a launch spec, with `STAGES` still the one routing table; the extension starts, messages, and closes the session, and a pointer index picks it. Adding a host is adding a file, and `--extension FILE` accepts one from anywhere. Helper scripts beside an extension are optional conveniences for mechanics that must be exact (multi-line prompts, secrets, workspace targeting), never a required schema.

## Considered options

- **Python adapters in `subagent.py`, one per host.** Typed and unit-testable, but every host edit becomes a code change, the core grows a CLI dependency per host, and an unlisted host cannot be added without editing it.
- **A parsed manifest or registry.** Machine-readable, but it needs a schema, a loader, and callbacks that each host must fit, which is machinery for what an agent reads fine as prose.

## Consequences

- Subagents report through the host's own messaging, so the pi-intercom channel of [ADR 0001](0001-intercom-as-subagent-result-channel.md) is superseded; the Completion report, Question, and fire-and-forget delivery stay.
- [ADR 0003](0003-subagent-is-a-stage-instance.md) still holds for routing: `subagent.py --stage` remains the only way to prepare a Stage. It no longer opens the session.
- Following an extension depends on an agent reading prose. Helpers carry the exact mechanics, and offline tests cover them.
- Selection order and overlap (Paseo, then herdr, then tmux) live in the index text, not in code.
- Permission and trust handling lives with the host that needs it, so each extension states its own limits.
