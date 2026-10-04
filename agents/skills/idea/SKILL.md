---
name: idea
description: Write the idea the user provides into their `ideas.md` file.
disable-model-invocation: true
---

You must write a brief line that summarizes the idea the user is providing to you
into the `ideas.md` file from `./IDEAS_SOURCE.md` value.

If `./IDEAS_SOURCE.md` does not exist
1. Ask the user the path to the `ideas.md` file.
2. Create the `./IDEAS_SOURCE.md` relative to this skill.
3. Set as the content just the absolute path to the `ideas.md` file that the user
has provided.

Read the `ideas.md` file. Then write the synthesised idea in the file.
