---
name: update-subagents
description: Swap the model behind a Subagent model role (builder, writer, critic).
disable-model-invocation: true
---

1. Check the new model

You receive a message like: "use <model> [instead of <model>]"
- `<model>` ~= `<provider>/<actual_model>`. If `model` is not provided like `provider/actual_model`, ask the user to specify both elements.
- Ask the user for the thinking effort too, even if the message gives none.
- the text in `[]` is optional by the user.

2. Show current models

Show the roles, models and efforts in the model table near the top of ../subagents/scripts/subagent.
The user decides which role's model is replaced with the model they indicated at the beginning.

3. Update script

Update the script, replacing that role's model and effort with the new ones. Stages pin roles, never model ids, so the model table is the only place to change.
