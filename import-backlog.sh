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

BACKLOG_FIELD_ID=$(get_field_id "Backlog ID")

##############################################
# PHASE 0 — LOAD EXISTING PROJECT ITEMS
##############################################

echo "=== Phase 0: Load existing project items by Backlog ID ==="

PROJECT_ITEMS=$(gh api graphql -f query='
  query($project:ID!) {
    node(id:$project) {
      ... on ProjectV2 {
        items(first:100) {
          nodes {
            id
            content {
              ... on Issue {
                number
                id
              }
            }
            fieldValues(first:50) {
              nodes {
                ... on ProjectV2ItemFieldTextValue {
                  text
                }
              }
            }
          }
        }
      }
    }
  }
' -F project="$PROJECT_ID")

declare -A ISSUE_MAP
declare -A ITEM_MAP

while IFS= read -r item; do
  issue_number=$(echo "$item" | jq -r '.content.number')
  item_id=$(echo "$item" | jq -r '.id')

  backlog_id=$(echo "$item" | jq -r '
    .fieldValues.nodes[]
    | select(.text != null)
    | .text
    | select(test("^[A-Za-z]+-[0-9]+$"))
  ')

  if [ -n "$backlog_id" ]; then
    ISSUE_MAP["$backlog_id"]="$issue_number"
    ITEM_MAP["$backlog_id"]="$item_id"
    echo "Found: $backlog_id -> issue #$issue_number, item $item_id"
  fi
done < <(echo "$PROJECT_ITEMS" | jq -c '.data.node.items.nodes[]')

##############################################
# PHASE 1 — CREATE OR UPDATE ISSUES
##############################################

echo "=== Phase 1: Create or update issues ==="

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

**Backlog ID:** $id
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

echo "=== Phase 3: Update Project Fields ==="

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
  issue_node_id=$(gh api /repos/"$REPO"/issues/"$issue_number" --jq '.node_id')

  item_id=${ITEM_MAP[$id]}

  if [ -z "${item_id:-}" ]; then
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
  fi

  item_json=$(jq -c ".[] | select(.id == \"$id\")" "$BACKLOG_FILE")

  type=$(echo "$item_json" | jq -r '.type')
  size=$(echo "$item_json" | jq -r '.size')
  value=$(echo "$item_json" | jq -r '.value')
  area=$(echo "$item_json" | jq -r '.area')
  sub_area=$(echo "$item_json" | jq -r '.sub_area')
  risk=$(echo "$item_json" | jq -r '.risk // "Low"')
  blocked_bool=${BLOCKED_MAP[$id]}

  if [ "$blocked_bool" = "true" ]; then blocked="Yes"; else blocked="No"; fi

  score=$(awk "BEGIN { printf \"%.2f\", $value / ($size == 0 ? 1 : $size) }")

  echo "Updating Project fields for $id (#$issue_number)"

  update_field "$item_id" "$(get_field_id 'Work Type')" \
    "{\"singleSelectOptionId\":\"$(get_option_id 'Work Type' "$(tr '[:lower:]' '[:upper:]' <<< ${type:0:1})${type:1}")\"}"

  update_field "$item_id" "$(get_field_id 'Size')" "{\"number\":$size}"
  update_field "$item_id" "$(get_field_id 'Value')" "{\"number\":$value}"
  update_field "$item_id" "$(get_field_id 'Score')" "{\"number\":$score}"

  update_field "$item_id" "$(get_field_id 'Blocked')" \
    "{\"singleSelectOptionId\":\"$(get_option_id 'Blocked' "$blocked")\"}"

  update_field "$item_id" "$(get_field_id 'Area')" \
    "{\"singleSelectOptionId\":\"$(get_option_id 'Area' "$area")\"}"

  update_field "$item_id" "$(get_field_id 'Sub-area')" \
    "{\"text\":\"$sub_area\"}"

  update_field "$item_id" "$(get_field_id 'Risk')" \
    "{\"singleSelectOptionId\":\"$(get_option_id 'Risk' "$risk")\"}"

  update_field "$item_id" "$BACKLOG_FIELD_ID" \
    "{\"text\":\"$id\"}"

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
