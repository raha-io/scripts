#!/usr/bin/env bash

# Push local git repositories to GitHub organization/user account.
# Can operate on a single repo or traverse a directory of repos.

usage() {
	echo -n "push local git repositories to GitHub organization/user account"
	# shellcheck disable=2016
	echo '
       _           _       _
  __ _| |__  _ __ | |_ ___| |__
 / _` | |_ \| |_ \| __/ _ \ |_ \
| (_| | | | | |_) | ||  __/ | | |
 \__, |_| |_| .__/ \__\___|_| |_|
 |___/      |_|
	'
}

root=${root:?"root must be set"}

# Module name for messages
MODULE="gh-push"

# Default values
_org_name=""
_prefix=""
_reauthor=false
_visibility="private"
_recursive=false
_dry_run=false
_force=false
_directories=()

main_brew() {
	require_brew gh
}

main_apt() {
	require_apt gh
}

main_pacman() {
	require_pacman github-cli
}

_parse_args() {
	while [[ $# -gt 0 ]]; do
		case $1 in
		-o | --org)
			_org_name="$2"
			shift 2
			;;
		-x | --prefix)
			_prefix="$2"
			shift 2
			;;
		-a | --reauthor)
			_reauthor=true
			shift
			;;
		-p | --public)
			_visibility="public"
			shift
			;;
		-r | --recursive)
			_recursive=true
			shift
			;;
		-d | --dry-run)
			_dry_run=true
			shift
			;;
		-f | --force)
			_force=true
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
			_directories+=("$1")
			shift
			;;
		esac
	done
}

_show_help() {
	cat <<EOF
Usage: start.sh gh-push-repos [OPTIONS] [DIRECTORY...]

Push local git repositories to GitHub using gh CLI.

OPTIONS:
    -o, --org NAME       GitHub organization or username (required)
    -x, --prefix PREFIX  Add prefix to repository names (e.g., "work-" creates "work-reponame")
    -a, --reauthor       Run 'git reauthor' to rewrite commits before pushing
    -p, --public         Create public repositories (default: private)
    -r, --recursive      Traverse directories and push all git repos found
    -d, --dry-run        Show what would be done without making changes
    -f, --force          Skip confirmation prompts
    -h, --help           Show this help message

ARGUMENTS:
    DIRECTORY            One or more directories to process (default: current directory)

EXAMPLES:
    # Push current directory to organization
    start.sh gh-push-repos -o myorg

    # Push all repos in a directory to organization
    start.sh gh-push-repos -o myorg -r ~/projects/

    # Push specific directories as public repos
    start.sh gh-push-repos -o myorg -p ./repo1 ./repo2

    # Push with a prefix (creates "work-reponame" instead of "reponame")
    start.sh gh-push-repos -o myorg -x "work-" ./myrepo

    # Reauthor commits before pushing
    start.sh gh-push-repos -o myorg -a ./myrepo

    # Dry run to see what would happen
    start.sh gh-push-repos -o myorg -r -d ~/projects/
EOF
}

_push_repo() {
	local dir="$1"
	local repo_name
	repo_name="${_prefix}$(basename "$(cd "$dir" && pwd)")"

	running "${MODULE}" "processing: ${repo_name}"

	if [[ ! -d "$dir/.git" ]]; then
		message "${MODULE}" "skipping '${repo_name}': not a git repository" "warn"
		return 0
	fi

	cd "$dir" || exit

	# Reauthor commits if requested
	if [[ "$_reauthor" == true ]]; then
		if [[ "$_dry_run" == true ]]; then
			message "${MODULE}" "[DRY-RUN] would run 'git reauthor' to rewrite commits" "notice"
		else
			action "${MODULE}" "rewriting commits with 'git reauthor'..."
			if ! git reauthor; then
				message "${MODULE}" "failed to reauthor commits in ${repo_name}" "error"
				return 1
			fi
		fi
	fi

	# Check if repo already exists on GitHub
	if gh repo view "$_org_name/$repo_name" &>/dev/null; then
		message "${MODULE}" "repository '${_org_name}/${repo_name}' already exists on GitHub" "warn"

		if [[ "$_force" != true && "$_dry_run" != true ]]; then
			if ! yes_or_no "${MODULE}" "update remote origin and push anyway?"; then
				message "${MODULE}" "skipping ${repo_name}" "notice"
				return 0
			fi
		fi

		if [[ "$_dry_run" == true ]]; then
			message "${MODULE}" "[DRY-RUN] would update origin and push to existing repo" "notice"
			return 0
		fi

		# Update origin and push
		if git remote get-url origin &>/dev/null; then
			git remote remove origin
		fi
		git remote add origin "https://github.com/$_org_name/$repo_name.git"
		git push -u origin --all
		git push origin --tags

		ok "${MODULE}" "pushed to existing repository: https://github.com/${_org_name}/${repo_name}"
	else
		if [[ "$_dry_run" == true ]]; then
			message "${MODULE}" "[DRY-RUN] would create ${_visibility} repo '${_org_name}/${repo_name}' and push" "notice"
			return 0
		fi

		# Remove existing origin if present
		if git remote get-url origin &>/dev/null; then
			action "${MODULE}" "removing existing origin remote..."
			git remote remove origin
		fi

		# Create and push
		action "${MODULE}" "creating repository ${_org_name}/${repo_name}..."
		gh repo create "$_org_name/$repo_name" "--$_visibility" --source=. --push

		ok "${MODULE}" "created and pushed: https://github.com/${_org_name}/${repo_name}"
	fi
}

_process_directory() {
	local base_dir="$1"

	if [[ ! -d "$base_dir" ]]; then
		message "${MODULE}" "directory not found: ${base_dir}" "error"
		return 1
	fi

	base_dir=$(cd "$base_dir" && pwd)

	if [[ "$_recursive" == true ]]; then
		# Find all directories containing .git
		while IFS= read -r -d '' git_dir; do
			repo_dir=$(dirname "$git_dir")
			_push_repo "$repo_dir"
			echo ""
		done < <(find "$base_dir" -maxdepth 2 -name ".git" -type d -print0 2>/dev/null)
	else
		_push_repo "$base_dir"
	fi
}

main() {
	_parse_args "$@"

	# Validate required arguments
	if [[ -z "$_org_name" ]]; then
		message "${MODULE}" "organization name is required (-o/--org)" "error"
		_show_help
		return 1
	fi

	# Check gh is authenticated
	if ! gh auth status &>/dev/null; then
		message "${MODULE}" "not authenticated with gh. run 'gh auth login' first." "error"
		return 1
	fi

	# Default to current directory if none specified
	if [[ ${#_directories[@]} -eq 0 ]]; then
		_directories=(".")
	fi

	# Show configuration
	message "${MODULE}" "target organization: ${_org_name}"
	[[ -n "$_prefix" ]] && message "${MODULE}" "repository prefix: ${_prefix}"
	[[ "$_reauthor" == true ]] && message "${MODULE}" "reauthor: enabled"
	message "${MODULE}" "visibility: ${_visibility}"
	[[ "$_dry_run" == true ]] && message "${MODULE}" "DRY RUN MODE - no changes will be made" "warn"
	echo ""

	for dir in "${_directories[@]}"; do
		_process_directory "$dir"
	done

	message "${MODULE}" "done!" "success"
}
