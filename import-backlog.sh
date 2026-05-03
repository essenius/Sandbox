#!/usr/bin/env bash
set -euo pipefail

###############################################
# CONFIGURATION
###############################################

GITHUB_OWNER="essenius"
GITHUB_REPO="Sandbox"
PROJECT_ID="PVT_kwHOAQnFFc4BWZ2G"
BACKLOG_JSON="backlog.json"

###############################################
# FIELD TYPES
###############################################
declare -A FIELD_TYPES=(
  ["Work Type"]="single"
  ["Area"]="single"
  ["Risk"]="single"
  ["Blocked"]="single"

  ["Sprint"]="iteration"

  ["Size"]="number"
  ["Value"]="number"
  ["Score"]="number"

  ["Sub-area"]="text"
  ["Backlog ID"]="text"
)

###############################################
# JSON → FIELD MAPPING
###############################################
declare -A JSON_KEY=(
  ["Work Type"]="type"
  ["Area"]="area"
  ["Sub-area"]="sub_area"
  ["Risk"]="risk"
  ["Size"]="size"
  ["Value"]="value"
  ["Backlog ID"]="id"
)

###############################################
# HELPERS
###############################################

# Find an existing issue by searching for the hidden BACKLOG_ID comment
find_issue_by_backlog_id() {
  local backlog_id="$1"

  gh api \
    -X GET \
    search/issues \
    -f q="repo:$GITHUB_OWNER/$GITHUB_REPO \"BACKLOG_ID: $backlog_id\"" \
    --jq '.items[0].number // empty' \
    || true
}

# Find an existing project item for a given issue node ID
find_existing_item_id() {
  local issue_node_id="$1"

  gh api graphql -f query='
    query($project:ID!) {
      node(id:$project) {
        ... on ProjectV2 {
          items(first:200) {
            nodes {
              id
              content {
                ... on Issue { id }
              }
            }
          }
        }
      }
    }
  ' -F project="$PROJECT_ID" \
    --jq ".data.node.items.nodes[] | select(.content.id == \"$issue_node_id\") | .id" \
    || true
}

###############################################
# LOAD FIELD IDS
###############################################
echo "Loading project fields…"

FIELDS_JSON=$(gh api graphql -f query='
  query($project:ID!) {
    node(id:$project) {
      ... on ProjectV2 {
        fields(first:50) {
          nodes {
            __typename

            ... on ProjectV2FieldCommon {
              id
              name
            }

            ... on ProjectV2SingleSelectField {
              id
              name
              options { id name }
            }

            ... on ProjectV2IterationField {
              id
              name
              configuration { iterations { id title } }
            }
          }
        }
      }
    }
  }
' -F project="$PROJECT_ID")

declare -A FIELD_IDS
declare -A OPTION_IDS
declare -A ITERATION_IDS

while read -r field; do
  name=$(echo "$field" | jq -r '.name')
  id=$(echo "$field" | jq -r '.id')
  FIELD_IDS["$name"]="$id"

  typename=$(echo "$field" | jq -r '.__typename')

  if [[ "$typename" == "ProjectV2SingleSelectField" ]]; then
    while read -r opt; do
      opt_name=$(echo "$opt" | jq -r '.name')
      opt_id=$(echo "$opt" | jq -r '.id')
      OPTION_IDS["$name::$opt_name"]="$opt_id"
    done < <(echo "$field" | jq -c '.options[]')
  fi

  if [[ "$typename" == "ProjectV2IterationField" ]]; then
    while read -r it; do
      it_title=$(echo "$it" | jq -r '.title')
      it_id=$(echo "$it" | jq -r '.id')
      ITERATION_IDS["$name::$it_title"]="$it_id"
    done < <(echo "$field" | jq -c '.configuration.iterations[]')
  fi

done < <(echo "$FIELDS_JSON" | jq -c '.data.node.fields.nodes[]')

echo "Field metadata loaded."

###############################################
# PROCESS BACKLOG JSON
###############################################
echo "Importing backlog…"

jq -c '.[]' "$BACKLOG_JSON" | while read -r item; do
  title=$(echo "$item" | jq -r '.title')
  backlog_id=$(echo "$item" | jq -r '.id')

  echo "Processing: $title ($backlog_id)"

  ###############################################
  # FIND OR CREATE ISSUE (BY HIDDEN COMMENT)
  ###############################################
  issue=$(find_issue_by_backlog_id "$backlog_id")

  if [[ -n "$issue" ]]; then
    echo " → Reusing existing issue #$issue"
  else
    echo " → Creating new issue…"
    issue=$(gh api repos/$GITHUB_OWNER/$GITHUB_REPO/issues \
      -f title="$title" \
      -f body="<!-- BACKLOG_ID: $backlog_id -->"$'\n\n'"$(echo "$item" | jq -r '.description // ""')" \
      --jq '.number')
    echo " → Created issue #$issue"
  fi

  ###############################################
  # GET ISSUE NODE ID
  ###############################################
  issue_node_id=$(gh api graphql -f query='
    query($owner:String!, $repo:String!, $issue:Int!) {
      repository(owner:$owner, name:$repo) {
        issue(number:$issue) { id }
      }
    }
  ' -F owner="$GITHUB_OWNER" -F repo="$GITHUB_REPO" -F issue="$issue" --jq '.data.repository.issue.id')

  ###############################################
  # FIND OR ADD PROJECT ITEM
  ###############################################
  item_id=$(find_existing_item_id "$issue_node_id")

  if [[ -n "$item_id" ]]; then
    echo " → Reusing existing project item $item_id"
  else
    echo " → Adding issue to project…"
    item_id=$(gh api graphql -f query='
      mutation($project:ID!, $content:ID!) {
        addProjectV2ItemById(input:{
          projectId:$project
          contentId:$content
        }) {
          item { id }
        }
      }
    ' -F project="$PROJECT_ID" -F content="$issue_node_id" --jq '.data.addProjectV2ItemById.item.id')
    echo " → Added as new item $item_id"
  fi

  ###############################################
  # UPDATE FIELDS
  ###############################################
  for field_name in "${!FIELD_TYPES[@]}"; do
    field_id="${FIELD_IDS[$field_name]:-}"
    [[ -z "$field_id" ]] && continue

    json_key="${JSON_KEY[$field_name]:-}"
    value=""

    if [[ -n "$json_key" ]]; then
      value=$(echo "$item" | jq -r --arg k "$json_key" '.[$k]')
      [[ "$value" == "null" ]] && value=""
    fi

    # Defaults
    # Blocked: default based on children/dependencies if not explicitly set
    if [[ "$field_name" == "Blocked" && -z "$value" ]]; then
      deps=$(echo "$item" | jq '.dependencies | length')
      kids=$(echo "$item" | jq '.children | length')
      value=$([[ $deps -gt 0 || $kids -gt 0 ]] && echo "Yes" || echo "No")
    fi

    # Score: example default (Value + Size)
    if [[ "$field_name" == "Score" && -z "$value" ]]; then
      sz=$(echo "$item" | jq '.size // 0')
      val=$(echo "$item" | jq '.value // 0')
      value=$((sz + val))
    fi

    # Skip if still empty
    [[ -z "$value" ]] && continue

    field_type="${FIELD_TYPES[$field_name]}"

    case "$field_type" in
      "single")
        opt_id="${OPTION_IDS[$field_name::$value]:-}"
        [[ -z "$opt_id" ]] && continue
        value_json="{\"singleSelectOptionId\":\"$opt_id\"}"
        ;;
      "number")
        value_json="{\"number\":$value}"
        ;;
      "iteration")
        it_id="${ITERATION_IDS[$field_name::$value]:-}"
        [[ -z "$it_id" ]] && continue
        value_json="{\"iterationId\":\"$it_id\"}"
        ;;
      "text")
        value_json="{\"text\":\"$value\"}"
        ;;
    esac
    echo "   → Preparing $field_name = $value"
    echo "DEBUG: $field_name → $value_json"
    gh api graphql \
      --raw-field query='
        mutation($project:ID!, $item:ID!, $field:ID!, $value:ProjectV2FieldValue!) {
          updateProjectV2ItemFieldValue(input:{
            projectId:$project
            itemId:$item
            fieldId:$field
            value:$value
          }) {
            projectV2Item { id }
          }
        }
      ' \
      --raw-field project="$PROJECT_ID" \
      --raw-field item="$item_id" \
      --raw-field field="$field_id" \
      --raw-field value="$value_json" \
      >/dev/null

    echo "   → Updated $field_name"
  done

done

echo "Import complete."
