#!/usr/bin/env bash
set -euo pipefail

REPO="essenius/Sandbox"
BACKLOG_FILE="backlog-example.json"

if [ ! -f "$BACKLOG_FILE" ]; then
  echo "Backlog file '$BACKLOG_FILE' not found" >&2
  exit 1
fi

jq -c '.[]' "$BACKLOG_FILE" | while read -r item; do
  title=$(echo "$item" | jq -r '.title')
  description=$(echo "$item" | jq -r '.description')
  type=$(echo "$item" | jq -r '.type // "n/a"')
  priority=$(echo "$item" | jq -r '.priority // "n/a"')
  estimate=$(echo "$item" | jq -r '.estimate // "n/a"')
  labels=$(echo "$item" | jq -r '.labels // [] | join(",")')

  # Build acceptance criteria in BDD format
  acceptance_md=$(echo "$item" | jq -r '
    .acceptance_criteria // [] |
    if length == 0 then "" else
      "### Acceptance Criteria (BDD)\n" +
      (map(
        "**Scenario:**\n" +
        "- **Given** " + .given + "\n" +
        "- **When** " + .when + "\n" +
        "- **Then** " + .then + "\n"
      ) | join("\n"))
    end
  ')

  # Build full body
  body=$(cat <<EOF
$description

$acceptance_md
---

**Type:** $type  
**Priority:** $priority  
**Estimate:** $estimate
EOF
)

  echo "Creating issue: $title"

  if [ -n "$labels" ]; then
    gh issue create \
      --repo "$REPO" \
      --title "$title" \
      --body "$body" \
      --label "$labels"
  else
    gh issue create \
      --repo "$REPO" \
      --title "$title" \
      --body "$body"
  fi
done
