---
name: clockify-fill
description: Fill Clockify time entries by gathering GitHub activity (commits, PRs, issues), then previewing and committing entries via clockify-cli.
disable-model-invocation: true
---

# Clockify Fill

Gather GitHub activity for a user, build Clockify time entries, preview them, and commit after user confirmation.

## Prerequisites

Check that `clockify-cli` is configured by running:

```bash
clockify-cli me
```

If it errors, tell the user to run `clockify-cli config init` and stop.

Verify `gh` CLI is available. If not, inform the user.

## Configuration

- **GitHub user**: `vieitesss`.
- **Repos to search**: all repos under the `~/work` path in this machine. First level are organization names, and second level are repositories names (`~/work/<organization>/<repository>`).
- **Workweek**: Monday through Friday.

## Workflow

### Step 1: Determine the date range

Run `clockify-cli report last-day` to find the last day with entries. The date range to fill starts the day after the last entry through today (or through the user-specified end date).

If the user provides explicit dates, use those instead.

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

### Step 2.5: Gather actual work hours

Ask the user for the times they started working, took lunch breaks, and stopped working each day. The user typically provides this as **screenshots of a group chat** (e.g. Slack, Teams) where they post messages like:

- "buenas" / greeting → **start of workday**
- "paro a comer" → **lunch break start**
- "de vuelta" → **back from lunch**
- "hasta mañana" / "buen finde!" → **end of workday**

Messages may include relative timestamps like "Yesterday" or "Mon" — resolve these relative to today's date.

**Processing the images:**
1. Read all messages chronologically, mapping each to its absolute date
2. For each workday, extract the work sessions (start→lunch, back→end)
3. Round every time to a **multiple of 5 minutes**, with special rounding for minutes ending in 3 or 7:
   - If the user is **logging in** (start of day or back from lunch): round **down** (e.g. 8:03→8:00, 15:27→15:25)
   - If the user is **logging out** (lunch break or end of day): round **up** (e.g. 14:33→14:35, 17:07→17:10)
   - All other minutes: round to the **nearest** multiple of 5
4. Calculate total worked hours per day
5. Present the parsed schedule to the user for confirmation before building entries

If the user does not provide images, fall back to the default 8h/day (08:00–16:00) assumption.

### Step 3: Correlate and build entries

For each workday in the range:

1. Cross-reference commits, PRs, and issues to identify distinct work items
2. Group related activity (e.g. multiple commits to the same issue/PR = one entry)
3. Map each work item to a Clockify project based on the repo/client relationship
4. Fit entries into the **actual work sessions** from Step 2.5 (or default 8h/day if not provided)
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

**CRITICAL: Do NOT proceed to commit entries until the user explicitly confirms the preview is correct.** Ask the user to review and confirm. The user may request changes (adjust times, change projects, add/remove entries).

### Step 5: Commit entries

Only after user confirmation, create each entry using:

```bash
clockify-cli manual \
  --allow-name-for-id \
  -i=0 \
  -b \
  -p "<project-name>" \
  -d "<description>" \
  -s "YYYY-MM-DD HH:MM" \
  -e "YYYY-MM-DD HH:MM"
```

Key flags:
- `--allow-name-for-id`: use project names instead of IDs
- `-i=0`: disable interactive mode (critical for automation)
- `-b`: mark entry as billable (always include)
- `-p`: project name
- `-d`: description
- `-s`: start time
- `-e`: end time

Process entries sequentially. If any entry fails, report the error and continue with the remaining entries. At the end, show a summary of successfully created vs failed entries.

### Step 6: Verify

After committing, run a report to confirm:

```bash
clockify-cli report <start-date> <end-date> --with-totals
```

Show the final report to the user.

## Error Handling

- If `clockify-cli me` fails: tell user to run `clockify-cli config init`
- If a project name is not found: list available projects and ask the user which one to use
- If no activity found for a day: ask the user what they worked on that day
- If `gh` commands fail: check authentication with `gh auth status`

## Notes

- Always use `-i=0` with `clockify-cli` commands to prevent interactive prompts
- Always use `--allow-name-for-id` to make project matching by name possible
- Descriptions should be concise: `repo#number: brief summary`
- If the user provides additional context about what they worked on, incorporate it
