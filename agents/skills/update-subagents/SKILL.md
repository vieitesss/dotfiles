---
name: update-subagents
description: Pin or unpin the model profile for a subagent kind.
disable-model-invocation: true
---

1. Check the new model

You receive a message like: "use <model> [instead of <model>]"
- `<model>` ~= `<provider>/<actual_model>`. If `model` is not provided like `provider/actual_model`, ask the user to specify both elements.
- the text in `[]` is optional by the user.

2. Show current models

Provide the models that are already available in the ../subagents/scripts/subagent.py script, in the MODELS object within the first 50 lines of code.
The user has to decide between those models the one that's going to be replaced with the model they have indicated at the beginning.

3. Update script

Update the script, replacing the selected model to switch with the new one.
