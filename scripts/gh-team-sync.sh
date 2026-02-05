#!/usr/bin/env bash

# GitHub Team Management Script
# Syncs team configuration from JSON file to GitHub using gh CLI

usage() {
  echo -n "sync GitHub team configuration from JSON file"
  # shellcheck disable=2016
  echo '
          __          __
   ____ _/ /_        / /____  ____ _____ ___        _______  ______  _____
  / __ `/ __ \______/ __/ _ \/ __ `/ __ `__ \______/ ___/ / / / __ \/ ___/
 / /_/ / / / /_____/ /_/  __/ /_/ / / / / / /_____(__  ) /_/ / / / / /__
 \__, /_/ /_/      \__/\___/\__,_/_/ /_/ /_/     /____/\__, /_/ /_/\___/
/____/                                                /____/
	'
}

root=${root:?"root must be set"}

# Module name for messages
MODULE="gh-team-sync"

# Default values
_config_file=""
_dry_run=false

main_brew() {
  require_brew gh jq
}

main_apt() {
  require_apt gh jq
}

main_pacman() {
  require_pacman github-cli jq
}

_parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
    -d | --dry-run)
      _dry_run=true
      shift
      ;;
    -h | --help)
      _show_help
      exit 0
      ;;
    -*)
      message "${MODULE}" "unknown option: $1" "error"
      _show_help
      exit 1
      ;;
    *)
      _config_file="$1"
      shift
      ;;
    esac
  done
}

_show_help() {
  cat <<EOF
Usage: start.sh gh-team-sync [OPTIONS] <config-file.json>

Sync GitHub team configuration from a JSON config file.

OPTIONS:
    -d, --dry-run    Preview changes without applying them
    -h, --help       Show this help message

CONFIG FILE FORMAT (JSON):
{
  "organization": "your-org",
  "teams": [
    {
      "name": "team-name",
      "description": "Team description",
      "privacy": "closed",        # closed or secret
      "members": [
        { "username": "user1", "role": "maintainer" },
        { "username": "user2", "role": "member" }
      ],
      "repositories": [
        { "name": "repo-name", "permission": "push" }
      ]
    }
  ]
}

PERMISSIONS: pull, triage, push, maintain, admin

FEATURES:
  - Creates/updates teams and syncs members
  - Syncs repository access per team
  - Removes direct collaborator access for team members
    (ensures access is only through team membership)

EXAMPLES:
    # Apply config
    start.sh gh-team-sync team-config.json

    # Preview changes (dry run)
    start.sh gh-team-sync -d team-config.json
EOF
}

# Run gh command (respects dry run mode)
_run_gh() {
  if [[ "$_dry_run" == true ]]; then
    message "${MODULE}" "[DRY-RUN] gh $*" "notice"
    return 0
  fi
  gh "$@"
}

# Create or update a team
_sync_team() {
  local org="$1"
  local team_name="$2"
  local description="$3"
  local privacy="$4"

  running "${MODULE}" "syncing team: ${team_name}"

  # Check if team exists
  if gh api "orgs/$org/teams/$team_name" &>/dev/null; then
    action "${MODULE}" "team exists, updating..."
    _run_gh api --method PATCH "orgs/$org/teams/$team_name" \
      -f description="$description" \
      -f privacy="$privacy" \
      --silent || message "${MODULE}" "failed to update team settings" "warn"
  else
    action "${MODULE}" "creating team..."
    if _run_gh api --method POST "orgs/$org/teams" \
      -f name="$team_name" \
      -f description="$description" \
      -f privacy="$privacy" \
      --silent; then
      ok "${MODULE}" "team created"
    else
      message "${MODULE}" "failed to create team" "error"
      return 1
    fi
  fi
}

# Get current team members
_get_team_members() {
  local org="$1"
  local team_name="$2"
  gh api --paginate "orgs/$org/teams/$team_name/members" --jq '.[].login' 2>/dev/null || echo ""
}

# Sync team members
_sync_team_members() {
  local org="$1"
  local team_name="$2"
  local members_json="$3"

  running "${MODULE}" "syncing members..."

  # Get current members
  local current_members
  current_members=$(_get_team_members "$org" "$team_name")

  # Get desired members from config
  local desired_members
  desired_members=$(echo "$members_json" | jq -r '.[].username')

  # Add/update members from config
  while IFS= read -r member_obj; do
    local username role
    username=$(echo "$member_obj" | jq -r '.username')
    role=$(echo "$member_obj" | jq -r '.role')

    [[ -z "$username" || "$username" == "null" ]] && continue

    action "${MODULE}" "adding/updating member: ${username} (role: ${role})"
    if _run_gh api --method PUT "orgs/$org/teams/$team_name/memberships/$username" \
      -f role="$role" \
      --silent; then
      ok "${MODULE}" "member synced: ${username}"
    else
      message "${MODULE}" "failed to sync member: ${username}" "warn"
    fi
  done < <(echo "$members_json" | jq -c '.[]')

  # Remove members not in config
  while IFS= read -r current_member; do
    [[ -z "$current_member" ]] && continue
    if ! echo "$desired_members" | grep -qx "$current_member"; then
      message "${MODULE}" "removing member not in config: ${current_member}" "warn"
      if _run_gh api --method DELETE "orgs/$org/teams/$team_name/memberships/$current_member" \
        --silent; then
        ok "${MODULE}" "member removed: ${current_member}"
      else
        message "${MODULE}" "failed to remove member: ${current_member}" "warn"
      fi
    fi
  done <<<"$current_members"
}

# Get current team repositories
_get_team_repos() {
  local org="$1"
  local team_name="$2"
  gh api --paginate "orgs/$org/teams/$team_name/repos" --jq '.[].name' 2>/dev/null || echo ""
}

# Sync team repositories
_sync_team_repos() {
  local org="$1"
  local team_name="$2"
  local repos_json="$3"

  running "${MODULE}" "syncing repositories..."

  # Get current repos
  local current_repos
  current_repos=$(_get_team_repos "$org" "$team_name")

  # Get desired repos from config
  local desired_repos
  desired_repos=$(echo "$repos_json" | jq -r '.[].name')

  # Add/update repos from config
  while IFS= read -r repo_obj; do
    local repo_name permission
    repo_name=$(echo "$repo_obj" | jq -r '.name')
    permission=$(echo "$repo_obj" | jq -r '.permission')

    [[ -z "$repo_name" || "$repo_name" == "null" ]] && continue

    action "${MODULE}" "adding/updating repo: ${repo_name} (permission: ${permission})"
    if _run_gh api --method PUT "orgs/$org/teams/$team_name/repos/$org/$repo_name" \
      -f permission="$permission" \
      --silent; then
      ok "${MODULE}" "repo synced: ${repo_name}"
    else
      message "${MODULE}" "failed to sync repo: ${repo_name}" "warn"
    fi
  done < <(echo "$repos_json" | jq -c '.[]')

  # Remove repos not in config
  while IFS= read -r current_repo; do
    [[ -z "$current_repo" ]] && continue
    if ! echo "$desired_repos" | grep -qx "$current_repo"; then
      message "${MODULE}" "removing repo not in config: ${current_repo}" "warn"
      if _run_gh api --method DELETE "orgs/$org/teams/$team_name/repos/$org/$current_repo" \
        --silent; then
        ok "${MODULE}" "repo removed: ${current_repo}"
      else
        message "${MODULE}" "failed to remove repo: ${current_repo}" "warn"
      fi
    fi
  done <<<"$current_repos"
}

# Get all repositories from config
_get_all_repos() {
  jq -r '.teams[].repositories[].name' "$_config_file" | sort -u
}

# Get all team members from config
_get_all_team_members() {
  jq -r '.teams[].members[].username' "$_config_file" | sort -u
}

# Remove direct collaborators from repositories (keep only team-based access)
_cleanup_direct_collaborators() {
  local org="$1"

  running "${MODULE}" "cleaning up direct collaborator access..."

  # Get all team members
  local team_members
  team_members=$(_get_all_team_members)

  # Get all repos from config
  local repos
  repos=$(_get_all_repos)

  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue

    action "${MODULE}" "checking repo: ${repo}"

    # Get direct collaborators (excluding org members with inherited access)
    local collaborators
    collaborators=$(gh api --paginate "repos/$org/$repo/collaborators?affiliation=direct" --jq '.[].login' 2>/dev/null || echo "")

    while IFS= read -r collaborator; do
      [[ -z "$collaborator" ]] && continue

      # Check if this collaborator is a team member
      if echo "$team_members" | grep -qx "$collaborator"; then
        message "${MODULE}" "removing direct access for team member: ${collaborator}" "warn"
        if _run_gh api --method DELETE "repos/$org/$repo/collaborators/$collaborator" \
          --silent; then
          ok "${MODULE}" "direct access removed: ${collaborator}"
        else
          message "${MODULE}" "failed to remove direct access: ${collaborator}" "warn"
        fi
      else
        message "${MODULE}" "found non-team direct collaborator: ${collaborator} (not removing - not in config)" "warn"
      fi
    done <<<"$collaborators"
  done <<<"$repos"
}

main() {
  _parse_args "$@"

  # Validate config file
  if [[ -z "$_config_file" ]]; then
    message "${MODULE}" "config file is required" "error"
    _show_help
    return 1
  fi

  if [[ ! -f "$_config_file" ]]; then
    message "${MODULE}" "config file not found: ${_config_file}" "error"
    return 1
  fi

  # Check gh is authenticated
  if ! gh auth status &>/dev/null; then
    message "${MODULE}" "not authenticated with gh. run 'gh auth login' first." "error"
    return 1
  fi

  # Show configuration
  message "${MODULE}" "using config: ${_config_file}"
  [[ "$_dry_run" == true ]] && message "${MODULE}" "DRY RUN MODE - no changes will be made" "warn"
  echo ""

  # Read organization
  local org
  org=$(jq -r '.organization' "$_config_file")

  if [[ -z "$org" || "$org" == "null" ]]; then
    message "${MODULE}" "organization not specified in config" "error"
    return 1
  fi

  message "${MODULE}" "organization: ${org}"
  echo ""

  # Process each team
  local team_count
  team_count=$(jq '.teams | length' "$_config_file")

  for ((i = 0; i < team_count; i++)); do
    local team_name description privacy members repos

    team_name=$(jq -r ".teams[$i].name" "$_config_file")
    description=$(jq -r ".teams[$i].description // \"\"" "$_config_file")
    privacy=$(jq -r ".teams[$i].privacy // \"closed\"" "$_config_file")
    members=$(jq -c ".teams[$i].members // []" "$_config_file")
    repos=$(jq -c ".teams[$i].repositories // []" "$_config_file")

    section_header "Team: ${team_name}"
    _sync_team "$org" "$team_name" "$description" "$privacy"
    _sync_team_members "$org" "$team_name" "$members"
    _sync_team_repos "$org" "$team_name" "$repos"
    echo ""
  done

  # Remove direct collaborator access for team members
  section_header "Cleanup"
  _cleanup_direct_collaborators "$org"
  echo ""

  message "${MODULE}" "sync complete!" "success"
}
