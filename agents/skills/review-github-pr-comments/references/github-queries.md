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

## Resolve a review thread

Use this only after the user explicitly asks you to resolve GitHub comments. Post the final reply first, then resolve the thread.

Fetch thread IDs and comment context:

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
        reviewThreads(first:100) {
          nodes {
            id
            isResolved
            isOutdated
            path
            line
            comments(last:20) {
              nodes {
                author { login }
                body
                url
              }
            }
          }
        }
      }
    }
  }'
```

Post a brief final reply:

```bash
THREAD_ID="PRRT_..."
BODY="Fixed in abc1234: handle missing input before parsing."

gh api graphql \
  -F threadId="$THREAD_ID" \
  -F body="$BODY" \
  -f query='mutation($threadId:ID!, $body:String!) {
    addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$threadId, body:$body}) {
      comment { url }
    }
  }'
```

Resolve the thread:

```bash
THREAD_ID="PRRT_..."

gh api graphql \
  -F threadId="$THREAD_ID" \
  -f query='mutation($threadId:ID!) {
    resolveReviewThread(input:{threadId:$threadId}) {
      thread { isResolved }
    }
  }'
```

## Filter to specific reviewers when needed

If the user mentions CodeRabbit, Qodo, Copilot, or another reviewer explicitly, filter the collected review data by `author.login` after fetching it.
