---
name: update-subagents
description: Swap the harness, model, or thinking effort behind a Subagent model role (builder, writer, critic).
disable-model-invocation: true
---

1. Check the new profile

You receive a message like: "use <model> [on <harness>] [instead of <model>]"
- Confirm the **harness** (`pi`, `agy`, `claude`, or `opencode`). For `pi` and `opencode`, `<model>` should be `<provider>/<actual_model>`; if either part is missing, ask the user.
- Ask the user for the thinking effort too (`off`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`), even if the message gives none.
- The text in `[]` is optional by the user.

2. Show current profiles

Show the roles, harnesses, models, and efforts in `load_profile` near the top of `../subagents/scripts/subagent`.
The user decides which role's profile is replaced with the harness, model, and effort they indicated at the beginning.

3. Update script

Update `load_profile` in `../subagents/scripts/subagent`, replacing that role's `profile_harness`, `profile_model`, and `profile_effort` with the new ones. Stages pin roles, never model ids, so `load_profile` is the only place to change.
