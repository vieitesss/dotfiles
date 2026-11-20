---
name: clockify-fill
description: Fill Clockify from GitHub activity and Google Chat hours via gog, then preview and commit via clockify-cli.
disable-model-invocation: true
---

# Clockify Fill

Gather GitHub activity, read work-hour messages from Google Chat with `gog`, build Clockify time entries, preview them, and commit after user confirmation.

## Configuration

- **GitHub account**: the active `gh` account. Get its login with `gh api user --jq .login`.
- **GitHub scope**: all repositories visible to that account, except `vieitesss/*`. Local clones do not limit the search.
- **Clockify project**: `Firestarter: a CI/CD service`, unless the user names another.
- **Workweek**: Monday through Friday.
- **Timezone**: `Europe/Madrid`.
- **Chat account**: `daniel.vieites@prefapp.es`.
- **Chat space**: `spaces/AAAAoS6q0wc` (General).
- **Chat sender**: `users/102872558289962052911`.

## Workflow

### Step 1: Determine the date range

Run `clockify-cli report last-day` to find the last day with entries.

- **Fill range**: the day after that last entry through today (or through the user-specified end date).
- **Chat range**: that last filled day (inclusive, 00:00 `Europe/Madrid`) through now.

If the user provides explicit dates, those dates are both the fill range and the Chat range. Apply any excluded day to the schedule, activity report, entries and totals.

Done when both ranges are concrete `YYYY-MM-DD` bounds.

### Step 2: Gather activity

Gather all sources for the full fill range, even when one already covers every day. Run contribution, event and search queries in parallel; use their results to find PR and ticket IDs.

1. **Contributions:** query GraphQL `user.contributionsCollection` for commits by repository, PRs, issues and reviews.
2. **Events:** paginate `gh api "users/$login/events" --paginate` and collect pushes, PRs, reviews and ticket actions. Fetch commit details for relevant pushed branch heads not covered by PRs.
3. **Search:** use `gh search commits --author="$login"` with both author-date and committer-date queries. Search PRs and issues with `--involves="$login" --updated="$start..$end"`. Split date ranges when results hit a limit. Use search results to discover work items, not to attribute their `updatedAt` to the user.
4. **Details:** paginate `repos/{owner}/{repo}/pulls/{number}/commits` for relevant PRs and `repos/{owner}/{repo}/issues/{number}/timeline` for relevant issues and PRs. Keep commits and actions attributed to the configured account.

Exclude the `vieitesss` owner in every source, including detail fetches. Convert timestamps to `Europe/Madrid`, deduplicate by commit SHA or event identity, and summarize by day and work item. Flag source limits or permission gaps rather than treating missing data as inactivity.

Done when all four sources have been checked for the range and each day has evidence or a flagged gap.

### Step 2.5: Work hours from Chat

Pull the user's own messages from General with `gog`, from the Chat range in Step 1. Those timestamps are the workday schedule.

```bash
gog --account daniel.vieites@prefapp.es --readonly chat messages list spaces/AAAAoS6q0wc \
  --order 'createTime desc' --json --max 100
```

Paginate with `--page <nextPageToken>` until `createTime` is before the Chat-range start. Keep messages whose `sender` is `users/102872558289962052911`. Convert `createTime` to `Europe/Madrid`.

Map message text to events:

- "buenas" / greeting → **start of workday** (login)
- "paro a comer" → **lunch break start** (logout)
- "de vuelta" → **back from lunch** (login)
- "hasta mañana" / "buen finde!" → **end of workday** (logout)

Then:
1. Read kept messages chronologically.
2. For each workday in the **fill range**, extract the work sessions (start→lunch, back→end).
3. Round every time to a **multiple of 5 minutes**, with special rounding for minutes ending in 3 or 7:
   - **logging in** (start of day or back from lunch): round **down** (e.g. 8:03→8:00, 15:27→15:25)
   - **logging out** (lunch break or end of day): round **up** (e.g. 14:33→14:35, 17:07→17:10)
   - All other minutes: round to the **nearest** multiple of 5
4. Calculate total worked hours per day.
5. Present the parsed schedule to the user for confirmation before building entries.

A fill-range day with no Chat events uses the default 8h/day (08:00–16:00).

Done when every own General message in the Chat range is in hand, the fill-range schedule is rounded, and that schedule has been shown to the user.

**Relative time statements in conversation:**

The user may also report a work event conversationally, as a duration relative to *now* (e.g. "salí hace 30 min", "he vuelto hace 10 minutos", "empecé hace 2 horas", "llevo media hora comiendo"), on top of the Chat fetch. Watch for this pattern in any message during the conversation, not only when the schedule is first requested. The same verbs map to the same events:

- "empecé" / "buenas" → **start of workday** (login)
- "paro a comer" / "me voy a comer" → **lunch break start** (logout)
- "he vuelto" / "de vuelta" → **back from lunch** (login)
- "salí" / "hasta mañana" → **end of workday** (logout)

To resolve a relative statement:
1. Get the current real time (e.g. `date "+%Y-%m-%d %H:%M"`) — never guess "now" from context.
2. Subtract the stated duration from the current time to get the absolute event time.
3. Assume the event belongs to today unless the user says otherwise.
4. Apply the same rounding rule as Step 2.5 item 3 (round down when logging in, round up when logging out).
5. Update that day's schedule with the resolved time. If entries were already built or previewed from the old schedule, rebuild and re-present the affected entries before continuing.

### Step 3: Correlate and build entries

For each workday in the range:

1. Cross-reference commits, PRs, and issues to identify distinct work items
2. Group related activity (e.g. multiple commits to the same issue/PR = one entry)
3. Use the default Clockify project unless the user specifies another
4. Fit entries into the **actual work sessions** from Step 2.5 (or default 8h/day for a day with no Chat events)
5. Split time proportionally across work items within the real time blocks
6. Build a description for each entry summarizing the work (repo, issue/PR number, brief description)

**Time allocation heuristics:**
- Total hours per day = actual worked hours from Step 2.5
- Split time proportionally across identified work items
- Entries must not overlap with lunch breaks — create separate entries for morning and afternoon sessions when needed
- Minimum entry size: 30 minutes
- Round internal splits to 30-minute blocks where possible. Keep confirmed session boundaries exact.

### Step 4: Preview entries

Write one temporary batch with one row per entry: `START|END|PROJECT|DESCRIPTION`. Use `YYYY-MM-DD HH:MM` in `Europe/Madrid`. Leave `PROJECT` empty to use the default. Check that the rows exactly cover the confirmed work sessions without crossing breaks.

Run the script next to this `SKILL.md` (requires `python3`):

```bash
"$HOME/.agents/skills/clockify-fill/commit-entries.py" preview /path/to/entries-file
```

Show the complete rendered table and its totals, plus any days without activity. Keep the preview token with the batch. If entries change, render the complete table again. **Commit only after the user explicitly confirms that preview.**

### Step 5: Commit entries

After confirmation, commit the same file with its preview token:

```bash
"$HOME/.agents/skills/clockify-fill/commit-entries.py" commit /path/to/entries-file PREVIEW_TOKEN
```

The script rejects a changed batch or destination, writes by project and workspace ID, and verifies each row against a Clockify report. Report the verified count and totals. If a batch partially fails, the same command skips rows already recorded. A change to the batch requires a new preview and confirmation.

## Error Handling

- If a project name is not found: list available projects and ask the user which one to use
- If no activity found for a day: ask the user what they worked on that day

## Notes

- Always use `-i=0` with `clockify-cli` commands to prevent interactive prompts
- Always use `--allow-name-for-id` to make project matching by name possible
- Descriptions should be concise: `repo#number: brief summary`
- If the user provides additional context about what they worked on, incorporate it
- Use `commit-entries.py` for preview and commit; never construct a separate commit table.
