# Global Pi agent instructions

## Source control safety

- Do not run `git commit`, `git push`, or commands that create commits or push branches/tags unless the user explicitly requests that action.
- Commit/push approval is single-use and applies only to the changes already discussed at the time of the request.
- If more code or config changes are made after a commit/push request, ask for fresh explicit approval before committing or pushing those later changes.
- If a commit or push attempt is blocked, cancelled, or rejected by a guard or user action, treat the approval as revoked and ask again before retrying.
- Do not bypass git-write guards, hooks, aliases, approval prompts, or safety extensions to commit or push.
- Do not infer commit or push permission from broad requests like "finish", "save", "apply", "ship", or "clean up".
