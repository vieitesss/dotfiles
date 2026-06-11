# Global Pi agent instructions

## Source control safety

- Do not run `git commit`, `git push`, or commands that create commits or push branches/tags unless the user explicitly requests that action.
- If the user explicitly requests a commit or push, that request is sufficient approval for the corresponding action.
- Do not infer commit or push permission from broad requests like "finish", "save", "apply", "ship", or "clean up".
