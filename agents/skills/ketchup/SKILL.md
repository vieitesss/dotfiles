---
name: ketchup
description: "Catch the user up on what changed since their last message, listing every decision waiting on them so they can decide from the reply alone. Use for /ketchup, 'catch me up', or 'where are we'."
---

# Ketchup

Catch the user up on what changed since their last message and lay out every call waiting on them so they can decide from the reply alone. Notifications and subagent results are not user messages; assume the user remembers their last message and nothing after it.

Keep this turn read-only: edit no file, start no job, and post nothing.

## Gather

1. Read live state first. In a Manager session, read `.agents/ledger.md` and the latest reports in `.agents/reports/` at the main checkout's root. Check current `git` status, unmerged branches, open PRs, and CI runs touched since the user's last message.
2. Verify every number and status against its source; note any correction.
3. Collect every **action item**: a call or step only the user can take (product choice, approval, irreversible action, missing access), including any raised earlier and still open. Work you can finish yourself is not an action item; never invent a call.
4. For each action item, gather its link or number, user-visible change, your **pick**, the **evidence** behind it, and its **risk**. Write `unknown` for any needed fact you lack.

## Reply

Use plain words and short sentences—what changed for the user, not how you built it. Omit hashes, file paths, commands, and test counts unless needed to act. Name PRs, branches, and items the way the user knows them.

1. **Opening**: one sentence naming what waits on the user, or saying nothing does. If nothing changed and nothing waits on them, stop here.
2. **What happened**: keep short—one line per Work Item stating what changed for the user and its Verdict (done, running, blocked, failed, or unchecked). Write each line to stand alone; omit anything covered under calls or that changed nothing for the user.
3. **Waiting on you**: list every call so the user can decide from this reply alone.
   - One item: one bullet with the call, your pick, user-visible change, evidence, and risk (even when low).
   - Shared call (e.g. PRs awaiting merge): state the call and default pick once, then one bullet per item, riskiest first, noting any item whose pick differs.
   - Choice between options: list every option weighed with its gain and cost (cost serves as the risk), plus the current state if any.
   - Include PR/issue links or numbers; state what waiting costs only when it exceeds a delay.
4. **Housekeeping**: list unmerged branches (and what each waits on, or "none"), skipped Stages with why, and any uncommitted work.

## Diagrams

Add a visual only when a picture beats prose (architecture, PR stack, before/after, options side by side)—never for a status or action list, and never repeating prose. Embed existing screenshots inline when the change is visible; generate diagrams through the `archify` skill, keeping them compact (at most six boxes, plain labels).

---

*Adapted from pstack (`skills/ketchup/SKILL.md`), Copyright (c) 2026 Lauren Tan, MIT License.*
