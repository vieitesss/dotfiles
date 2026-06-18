# GitHub Review Queries

Use these commands when you need fresh PR review data from GitHub.

## Fetch reviews and review threads

Use this query to collect review summaries, inline comments, whether the thread is resolved, whether the thread is outdated, and what the latest reviewer comment says now.

```bash
OWNER=$(gh repo view --json owner --jq '.owner.login')
REPO=$(gh repo view --json name --jq '.name')
PR=$(gh pr view --json number --jq '.number')

gh api graphql \
  -F owner="$OWNER" \
  -F repo="$REPO" \
  -F pr="$PR" \
  -f query='query($owner:String!, $repo:String!, $pr:Int!) {
    repository(owner:$owner, name:$repo) {
      pullRequest(number:$pr) {
        reviews(last:100) {
          nodes {
            author { login }
            state
            body
            submittedAt
            updatedAt
            url
          }
        }
        reviewThreads(first:100) {
          nodes {
            isResolved
            isOutdated
            path
            line
            originalLine
            comments(last:20) {
              nodes {
                author { login }
                body
                createdAt
                updatedAt
                url
              }
            }
          }
        }
      }
    }
  }'
```

## Interpret the thread data

- Read the full `comments.nodes` list before deciding what the thread means.
- Use the latest reviewer-authored comment as the current request when the thread changed over time.
- Treat `isResolved: true` as informational unless the user explicitly asked to re-open past decisions.
- Treat `isOutdated: true` as a signal to compare against the current file and current diff before acting.

## Filter to specific reviewers when needed

If the user mentions CodeRabbit, Qodo, Copilot, or another reviewer explicitly, filter the collected review data by `author.login` after fetching it.
