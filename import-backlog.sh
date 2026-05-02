#!/usr/bin/env bash
set -euo pipefail

##############################################
# CONFIGURATION
##############################################

REPO="essenius/Sandbox"
BACKLOG_FILE="backlog.json"

# Project location
PROJECT_SCOPE="repo"          # "user", "org", or "repo"
PROJECT_OWNER="essenius"      # user or org
PROJECT_REPO="Sandbox"        # only used when PROJECT_SCOPE="repo"
PROJECT_NUMBER=6

##############################################
# LOAD PROJECT + FIELDS
##############################################

echo "=== Loading Project and Field IDs ==="

if [ "$PROJECT_SCOPE" = "user" ]; then
  PROJECT_QUERY='
    query($owner:String!, $number:Int!) {
      user(login:$owner) {
        projectV2(number:$number) {
          id
          fields(first:50) {
            nodes {
              ... on ProjectV2FieldCommon { id name }
              ... on ProjectV2SingleSelectField { id name options { id name } }
              ... on ProjectV2IterationField { id name }
            }
          }
        }
      }
    }
  '
  PROJECT_PATH=".data.user.projectV2"

elif [ "$PROJECT_SCOPE" = "org" ]; then
  PROJECT_QUERY='
    query($owner:String!, $number:Int!) {
      organization(login:$owner) {
        projectV2(number:$number) {
          id
          fields(first:50) {
            nodes {
              ... on ProjectV2FieldCommon { id name }
              ... on ProjectV2SingleSelectField { id name options { id name } }
              ... on ProjectV2IterationField { id name }
            }
          }
        }
      }
    }
  '
  PROJECT_PATH=".data.organization.projectV2"

elif [ "$PROJECT_SCOPE" = "repo" ]; then
  PROJECT_QUERY='
    query($owner:String!, $repo:String!, $number:Int!) {
      repository(owner:$owner, name:$repo) {
        projectV2(number:$number) {
          id
          fields(first:50) {
            nodes {
              ... on ProjectV2FieldCommon { id name }
              ... on ProjectV2SingleSelectField { id name options { id name } }
              ... on ProjectV2IterationField { id name }
            }
          }
        }
      }
    }
  '
  PROJECT_PATH=".data.repository.projectV2"
fi

PROJECT_JSON=$(gh api graphql -f query="$PROJECT_QUERY" \
  -F owner="$PROJECT_OWNER" \
  -F repo="$PROJECT_REPO" \
  -F number="$PROJECT_NUMBER")

PROJECT_ID=$(echo "$PROJECT_JSON" | jq -r "$PROJECT_PATH.id")
FIELDS_JSON=$(echo "$PROJECT_JSON" | jq -r "$PROJECT_PATH.fields.nodes")

echo "Project ID: $PROJECT_ID"

##############################################
# FIELD LOOKUP HELPERS
##############################################

get_field_id() {
  local name="$1"
  echo "$FIELDS_JSON" | jq -r ".[] | select(.name == \"$name\") | .id"
}

get_option_id() {
  local field="$1"
  local option="$2"
  echo "$FIELDS_JSON" | jq -r "
    .[] | select(.name == \"$field\") |
    .options[]? | select(.name == \"$option\") | .id
  "
}

BACKLOG_FIELD_ID=$(get_field_id "Backlog ID") || true

##############################################
# PHASE 0 — LOAD EXISTING ISSUES + PROJECT ITEMS
##############################################

echo "=== Phase 0: Load existing issues and project items by Backlog ID (HTML comment) ==="

declare -A ISSUE_MAP      # Backlog ID -> issue number
declare -A NODEID_MAP     # Backlog ID -> issue node_id
declare -A ITEM_MAP       # Backlog ID -> project item id

# 0.1 Load all issues and extract BACKLOG_ID from hidden HTML comment
ISSUES_JSON=$(gh issue list --repo "$REPO" --state all --json number,body,node_id --limit 1000)

echo "$ISSUES_JSON" | jq -c '.[]' | while read -r issue; do
  number=$(echo "$issue" | jq -r '.number')
  node_id=$(echo "$issue" | jq -r '.node_id')
  body=$(echo "$issue" | jq -r '.body // ""')

  backlog_id=$(printf '%s\n' "$body" | perl -ne 'print "$1\n" if /<!--\s*BACKLOG_ID:\s*([^ >]+)\s*-->/')

  if [ -n "${backlog_id:-}" ]; then
    ISSUE_MAP["$backlog_id"]="$number"
    NODEID_MAP["$backlog_id"]="$node_id"
    echo "Issue map: $backlog_id -> #$number"
  fi
done

# 0.2 Load project items and map them via issue node_id -> backlog_id
PROJECT_ITEMS=$(gh api graphql -f query='
  query($project:ID!) {
    node(id:$project) {
      ... on ProjectV2 {
        items(first:100) {
          nodes {
            id
            content {
              ... on Issue {
                id
              }
            }
          }
        }
      }
    }
  }
' -F project="$PROJECT_ID")

echo "$PROJECT_ITEMS" | jq -c '.data.node.items.nodes[]' | while read -r item; do
  item_id=$(echo "$item" | jq -r '.id')
  issue_node_id=$(echo "$item" | jq -r '.content.id // empty')

  if [ -z "$issue_node_id" ]; then
    continue
  fi

  # Find backlog_id by matching issue_node_id in NODEID_MAP
  for bid in "${!NODEID_MAP[@]}"; do
    if [ "${NODEID_MAP[$bid]}" = "$issue_node_id" ]; then
      ITEM_MAP["$bid"]="$item_id"
      echo "Project map: $bid -> item $item_id"
      break
    fi
  done
done

##############################################
# PHASE 1 — CREATE OR UPDATE ISSUES
##############################################

echo "=== Phase 1: Create or update issues (with BACKLOG_ID HTML comment) ==="

while IFS= read -r item; do
  id=$(echo "$item" | jq -r '.id')
  title=$(echo "$item" | jq -r '.title')
  description=$(echo "$item" | jq -r '.description')
  type=$(echo "$item" | jq -r '.type')
  labels=$(echo "$item" | jq -r '.labels // [] | join(",")')
  size=$(echo "$item" | jq -r '.size')
  value=$(echo "$item" | jq -r '.value')
  area=$(echo "$item" | jq -r '.area')
  sub_area=$(echo "$item" | jq -r '.sub_area')
  risk=$(echo "$item" | jq -r '.risk // "Low"')

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

  body=$(cat <<EOF
$description

$acceptance_md
---

**Type:** $type  
**Size:** $size  
**Value:** $value  
**Area:** $area  
**Sub-area:** $sub_area  
**Risk:** $risk  

<!-- BACKLOG_ID: $id -->
EOF
)

  if [[ -v ISSUE_MAP["$id"] ]]; then
    issue_number=${ISSUE_MAP[$id]}
    echo "Updating issue: $id (#$issue_number)"

    if [ -n "$labels" ]; then
      gh api \
        --method PATCH \
        /repos/"$REPO"/issues/"$issue_number" \
        -f title="$title" \
        -f body="$body" \
        -f labels="[$(echo "$labels" | sed 's/,/","/g' | sed 's/^/"/;s/$/"/')]"
    else
      gh api \
        --method PATCH \
        /repos/"$REPO"/issues/"$issue_number" \
        -f title="$title" \
        -f body="$body"
    fi
  else
    echo "Creating new issue: $id ($title)"

    if [ -n "$labels" ]; then
      issue_url=$(gh issue create --repo "$REPO" --title "$title" --body "$body" --label "$labels")
    else
      issue_url=$(gh issue create --repo "$REPO" --title "$title" --body "$body")
    fi

    issue_number=$(basename "$issue_url")
    ISSUE_MAP["$id"]="$issue_number"

    node_id=$(gh api /repos/"$REPO"/issues/"$issue_number" --jq '.node_id')
    NODEID_MAP["$id"]="$node_id"
  fi

done < <(jq -c '.[]' "$BACKLOG_FILE")

##############################################
# PHASE 2 — COMPUTE BLOCKED
##############################################

echo "=== Phase 2: Compute blocked state ==="

compute_blocked() {
  local item="$1"
  local id=$(echo "$item" | jq -r '.id')

  local explicit=$(echo "$item" | jq -r '.blocked')
  if [ "$explicit" = "true" ] || [ "$explicit" = "false" ]; then
    echo "$explicit"
    return
  fi

  local blocked=false

  for dep in $(echo "$item" | jq -r '.dependencies // [] | .[]'); do
    dep_issue=${ISSUE_MAP[$dep]}
    dep_state=$(gh api /repos/"$REPO"/issues/"$dep_issue" --jq '.state')
    if [ "$dep_state" != "closed" ]; then blocked=true; fi
  done

  for child in $(echo "$item" | jq -r '.children // [] | .[]'); do
    child_issue=${ISSUE_MAP[$child]}
    child_state=$(gh api /repos/"$REPO"/issues/"$child_issue" --jq '.state')
    if [ "$child_state" != "closed" ]; then blocked=true; fi
  done

  echo "$blocked"
}

declare -A BLOCKED_MAP

while IFS= read -r item; do
  id=$(echo "$item" | jq -r '.id')
  BLOCKED_MAP["$id"]=$(compute_blocked "$item")
done < <(jq -c '.[]' "$BACKLOG_FILE")

##############################################
# PHASE 3 — UPDATE PROJECT FIELDS
##############################################

echo "=== Phase 3: Add to project and update fields ==="

update_field() {
  local item_id="$1"
  local field_id="$2"
  local value_json="$3"

  gh api graphql -f query='
    mutation($project:ID!, $item:ID!, $field:ID!, $value:ProjectV2FieldValue!) {
      updateProjectV2ItemFieldValue(
        input: {
          projectId: $project,
          itemId: $item,
          fieldId: $field,
          value: $value
        }
      ) {
        projectV2Item { id }
      }
    }
  ' \
  -F project="$PROJECT_ID" \
  -F item="$item_id" \
  -F field="$field_id" \
  -F value="$value_json" >/dev/null
}

for id in "${!ISSUE_MAP[@]}"; do
  issue_number=${ISSUE_MAP[$id]}
  issue_node_id=${NODEID_MAP[$id]:-}

  if [ -z "$issue_node_id" ]; then
    issue_node_id=$(gh api /repos/"$REPO"/issues/"$issue_number" --jq '.node_id')
    NODEID_MAP["$id"]="$issue_node_id"
  fi

  item_id="${ITEM_MAP[$id]:-}"

  if [ -z "$item_id" ]; then
    item_id=$(gh api graphql -f query='
      mutation($project:ID!, $content:ID!) {
        addProjectV2ItemById(input:{
          projectId:$project,
          contentId:$content
        }) {
          item { id }
        }
      }
    ' -F project="$PROJECT_ID" -F content="$issue_node_id" --jq '.data.addProjectV2ItemById.item.id')
    ITEM_MAP["$id"]="$item_id"
    echo "Added to project: $id -> item $item_id"
  fi

  item_json=$(jq -c ".[] | select(.id == \"$id\")" "$BACKLOG_FILE")

  type=$(echo "$item_json" | jq -r '.type')
  size=$(echo "$item_json" | jq -r '.size')
  value=$(echo "$item_json" | jq -r '.value')
  area=$(echo "$item_json" | jq -r '.area')
  sub_area=$(echo "$item_json" | jq -r '.sub_area')
  risk=$(echo "$item_json" | jq -r '.risk // "Low"')
  blocked_bool=${BLOCKED_MAP[$id]:-false}

  if [ "$blocked_bool" = "true" ]; then blocked="Yes"; else blocked="No"; fi

  score=$(awk "BEGIN { printf \"%.2f\", $value / ($size == 0 ? 1 : $size) }")

  echo "Updating Project fields for $id (#$issue_number)"

  wt_field=$(get_field_id 'Work Type')
  if [ -n "$wt_field" ] && [ "$type" != "null" ]; then
    wt_opt=$(get_option_id 'Work Type' "$(tr '[:lower:]' '[:upper:]' <<< ${type:0:1})${type:1}")
    [ -n "$wt_opt" ] && update_field "$item_id" "$wt_field" "{\"singleSelectOptionId\":\"$wt_opt\"}"
  fi

  size_field=$(get_field_id 'Size')
  [ -n "$size_field" ] && update_field "$item_id" "$size_field" "{\"number\":$size}"

  value_field=$(get_field_id 'Value')
  [ -n "$value_field" ] && update_field "$item_id" "$value_field" "{\"number\":$value}"

  score_field=$(get_field_id 'Score')
  [ -n "$score_field" ] && update_field "$item_id" "$score_field" "{\"number\":$score}"

  blocked_field=$(get_field_id 'Blocked')
  if [ -n "$blocked_field" ]; then
    blocked_opt=$(get_option_id 'Blocked' "$blocked")
    [ -n "$blocked_opt" ] && update_field "$item_id" "$blocked_field" "{\"singleSelectOptionId\":\"$blocked_opt\"}"
  fi

  area_field=$(get_field_id 'Area')
  if [ -n "$area_field" ]; then
    area_opt=$(get_option_id 'Area' "$area")
    [ -n "$area_opt" ] && update_field "$item_id" "$area_field" "{\"singleSelectOptionId\":\"$area_opt\"}"
  fi

  sub_area_field=$(get_field_id 'Sub-area')
  [ -n "$sub_area_field" ] && update_field "$item_id" "$sub_area_field" "{\"text\":\"$sub_area\"}"

  risk_field=$(get_field_id 'Risk')
  if [ -n "$risk_field" ]; then
    risk_opt=$(get_option_id 'Risk' "$risk")
    [ -n "$risk_opt" ] && update_field "$item_id" "$risk_field" "{\"singleSelectOptionId\":\"$risk_opt\"}"
  fi

  if [ -n "$BACKLOG_FIELD_ID" ]; then
    update_field "$item_id" "$BACKLOG_FIELD_ID" "{\"text\":\"$id\"}"
  fi
done

##############################################
# PHASE 4 — HIERARCHY LINKS
##############################################

echo "=== Phase 4: Create hierarchy links ==="

while IFS= read -r item; do
  parent_id=$(echo "$item" | jq -r '.id')
  parent_issue=${ISSUE_MAP[$parent_id]}

  jq -r '.children // [] | .[]' <<< "$item" | while read -r child_id; do
    child_issue=${ISSUE_MAP[$child_id]}

    echo "Linking: $child_id (#$child_issue) blocks $parent_id (#$parent_issue)"

    gh api \
      --method POST \
      /repos/"$REPO"/issues/"$parent_issue"/links \
      -f target_issue_number="$child_issue" \
      -f relationship=blocked_by
  done

done < <(jq -c '.[]' "$BACKLOG_FILE")

echo "=== Import complete ==="
