## Delegation routing

Classify each user task as research, implement, or write and spawn it via `subagents` — the child does that work. After implement, spawn reviewer and wait for PASS before write. Multi-step implement uses the arc; trivial implement is `start` then reviewer. You can use pi-intercom to communicate with your subagents. If you are a subagent, report back to the parent through the channel your task prompt names (pi-intercom or herdr).

NOTE: if the user tells you not to use subagents, don't use subagents, do the work yourself.
