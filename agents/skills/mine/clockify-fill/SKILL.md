---
name: clockify-fill
description: Fill Clockify from GitHub activity and Google Chat hours via gog, then preview and commit via clockify-cli.
disable-model-invocation: true
---

# Clockify Fill

Gather GitHub activity, read work-hour messages from Google Chat with `gog`, build Clockify time entries, preview them, and commit after user confirmation.

## Configuration

- **GitHub user**: `vieitesss`.
- **Repos to search**: all repos under the `~/work` path in this machine. First level are organization names, and second level are repositories names (`~/work/<organization>/<repository>`).
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

If the user provides explicit dates, those dates are both the fill range and the Chat range.

Done when both ranges are concrete `YYYY-MM-DD` bounds.

### Step 2: Gather activity

Run all of these in parallel for the determined date range:

#### 2a. GitHub activity

First derive the owners to search from the org directories under `~/work`, then build the `--owner` flags:

```bash
owners=$(ls -d ~/work/*/ | xargs -n1 basename | sed 's/^/--owner=/' | tr '\n' ' ')
```

Search commits, PRs, and issues across those owners:

```bash
# Commits by user in date range
gh search commits --author=vieitesss --committer-date=YYYY-MM-DD..YYYY-MM-DD $owners --json repository,sha,commit --limit 100

# PRs authored/reviewed
gh search prs --author=vieitesss --created=YYYY-MM-DD..YYYY-MM-DD $owners --json title,repository,url,createdAt --limit 100

# Issues assigned or mentioned
gh search issues --assignee=vieitesss --created=YYYY-MM-DD..YYYY-MM-DD $owners --json title,repository,url,createdAt --limit 100
```

#### 2b. Clockify projects

Fetch the available project list to map work to correct projects:

```bash
clockify-cli project list
```

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
3. Map each work item to a Clockify project based on the repo/client relationship
4. Fit entries into the **actual work sessions** from Step 2.5 (or default 8h/day for a day with no Chat events)
5. Split time proportionally across work items within the real time blocks
6. Build a description for each entry summarizing the work (repo, issue/PR number, brief description)

**Time allocation heuristics:**
- Total hours per day = actual worked hours from Step 2.5
- Split time proportionally across identified work items
- Entries must not overlap with lunch breaks — create separate entries for morning and afternoon sessions when needed
- Minimum entry size: 30 minutes
- Round to nearest 30-minute block

### Step 4: Preview entries

Present a markdown table to the user with ALL proposed entries:

```
| Date       | Project              | Description                              | Start | End   | Duration |
|------------|----------------------|------------------------------------------|-------|-------|----------|
| 2026-05-05 | usc-devops           | gitops-k8s#1556: Fix helm chart defaults | 09:00 | 12:00 | 3:00     |
| 2026-05-05 | prefapp-dev          | tfm#1253: Add validation module          | 12:00 | 14:00 | 2:00     |
| ...        | ...                  | ...                                      | ...   | ...   | ...      |
```

After the table, show:
- Total hours per day
- Total hours for the full range
- Any days with no activity found (flag for user attention)

**This full entry table is the table that gets committed.** Never substitute it with an hours-per-day summary — the per-day/per-range totals are an addition to the table, not a replacement for it. Whenever entries change (user-requested edits, retries after failures) or the table is shown again for any reason, re-render the complete table with every entry, not a summary.

**CRITICAL: Do NOT proceed to commit entries until the user explicitly confirms the preview is correct.** Ask the user to review and confirm. The user may request changes (adjust times, change projects, add/remove entries).

### Step 5: Commit entries

Only after user confirmation, write the confirmed table to a temp file, one line per entry, pipe-separated as `START|END|PROJECT|DESCRIPTION` (`START`/`END` as `YYYY-MM-DD HH:MM`), then commit it with the skill's script:

```bash
agents/skills/mine/clockify-fill/commit-entries.sh /path/to/entries-file
```

The script calls `clockify-cli manual --allow-name-for-id -i=0 -b` for each line, prints `OK`/`FAILED` per entry, and ends with a `SUMMARY: N succeeded, M failed` line. If any entry fails, its error is printed; report it and continue — the script already processes the rest sequentially. Never hand-roll this loop inline; always invoke the script.

### Step 6: Verify

After committing, run a report to confirm:

```bash
clockify-cli report <start-date> <end-date> --with-totals
```

Show the final report to the user.

## Error Handling

- If a project name is not found: list available projects and ask the user which one to use
- If no activity found for a day: ask the user what they worked on that day

## Notes

- Always use `-i=0` with `clockify-cli` commands to prevent interactive prompts
- Always use `--allow-name-for-id` to make project matching by name possible
- Descriptions should be concise: `repo#number: brief summary`
- If the user provides additional context about what they worked on, incorporate it
- Commit entries only via `commit-entries.sh` (see Step 5), resolved relative to this SKILL.md's directory
- Always show the full entries table (never an hours-only summary) whenever entries are presented or re-presented
