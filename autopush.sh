#!/usr/bin/env bash
# =============================================================================
#  autopush.sh — Smart Git Auto-Push Monitor
#  Drop this script into any project folder and run it.
#  It will watch for file changes and push like a senior dev.
# =============================================================================

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Config ────────────────────────────────────────────────────────────────────
WATCH_INTERVAL=10          # seconds between change checks
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAST_HASH_FILE="$SCRIPT_DIR/.autopush_last_hash"

# =============================================================================
#  SECTION 1 — Preflight checks
# =============================================================================

print_banner() {
  echo ""
  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${CYAN}${BOLD}║        🚀  AutoPush — Smart Git Monitor       ║${RESET}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════╝${RESET}"
  echo ""
}

check_git_installed() {
  if ! command -v git &>/dev/null; then
    echo -e "${RED}✖  Git is not installed. Please install Git first.${RESET}"
    exit 1
  fi
}

# =============================================================================
#  SECTION 2 — Repository detection
# =============================================================================

detect_repo() {
  echo -e "${BLUE}▶  Scanning: ${BOLD}$SCRIPT_DIR${RESET}"
  echo ""

  # Walk up from script dir to find a .git folder
  local dir="$SCRIPT_DIR"
  local git_root=""

  while [[ "$dir" != "/" ]]; do
    if [[ -d "$dir/.git" ]]; then
      git_root="$dir"
      break
    fi
    dir="$(dirname "$dir")"
  done

  if [[ -z "$git_root" ]]; then
    echo -e "${RED}${BOLD}✖  NOT a Git repository!${RESET}"
    echo -e "${YELLOW}   This folder (or any of its parents) does not contain a .git directory.${RESET}"
    echo ""
    echo -e "   To fix this, run one of the following:"
    echo -e "   ${CYAN}git init${RESET}                   — start a new local repo"
    echo -e "   ${CYAN}git clone <url> .${RESET}          — clone an existing remote repo here"
    echo ""
    exit 1
  fi

  # Switch working directory to the repo root
  cd "$git_root" || exit 1
  REPO_ROOT="$git_root"
  echo -e "${GREEN}✔  Git repo found at: ${BOLD}$REPO_ROOT${RESET}"
}

# =============================================================================
#  SECTION 3 — Remote URL detection & validation
# =============================================================================

detect_remote() {
  # Try origin first, then any other remote
  REMOTE_NAME=$(git remote | grep -m1 "origin" || git remote | head -n1)

  if [[ -z "$REMOTE_NAME" ]]; then
    echo ""
    echo -e "${RED}${BOLD}✖  No remote configured!${RESET}"
    echo -e "${YELLOW}   This repo has no remote URL (e.g. GitHub).${RESET}"
    echo ""
    echo -e "   To fix this, run:"
    echo -e "   ${CYAN}git remote add origin https://github.com/<user>/<repo>.git${RESET}"
    echo ""
    exit 1
  fi

  REMOTE_URL=$(git remote get-url "$REMOTE_NAME" 2>/dev/null)

  if [[ -z "$REMOTE_URL" ]]; then
    echo -e "${RED}✖  Remote '${REMOTE_NAME}' has no URL set.${RESET}"
    exit 1
  fi

  # Detect current branch
  CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "main")

  echo -e "${GREEN}✔  Remote : ${BOLD}$REMOTE_NAME${RESET}${GREEN} → ${BOLD}$REMOTE_URL${RESET}"
  echo -e "${GREEN}✔  Branch : ${BOLD}$CURRENT_BRANCH${RESET}"
  echo ""
}

# =============================================================================
#  SECTION 4 — Change detection
# =============================================================================

get_tree_hash() {
  # Hash the entire working tree (tracked + untracked, excluding .git)
  git status --porcelain 2>/dev/null | md5sum | awk '{print $1}'
}

has_changes() {
  # Returns 0 (true) if there are any staged or unstaged changes
  ! git diff --quiet 2>/dev/null || \
  ! git diff --cached --quiet 2>/dev/null || \
  [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]
}

# =============================================================================
#  SECTION 5 — Smart commit message generation
# =============================================================================

generate_commit_message() {
  local staged_files modified_files deleted_files new_files renamed_files
  local msg_parts=()
  local scope=""
  local summary=""

  # ── Collect git status data ──────────────────────────────────────────────
  staged_files=$(git diff --cached --name-only 2>/dev/null)
  modified_files=$(git diff --name-only 2>/dev/null)
  deleted_files=$(git ls-files --deleted 2>/dev/null)
  new_files=$(git ls-files --others --exclude-standard 2>/dev/null)
  renamed_files=$(git diff --cached --name-status 2>/dev/null | grep "^R" | awk '{print $2 " → " $3}')

  # Stage everything before inspecting
  git add -A 2>/dev/null

  # Re-read after staging
  local all_changed
  all_changed=$(git diff --cached --name-status 2>/dev/null)

  local added_list modified_list deleted_list renamed_list
  added_list=$(echo "$all_changed"   | grep "^A" | awk '{print $2}')
  modified_list=$(echo "$all_changed"| grep "^M" | awk '{print $2}')
  deleted_list=$(echo "$all_changed" | grep "^D" | awk '{print $2}')
  renamed_list=$(echo "$all_changed" | grep "^R" | awk '{print $2 " → " $3}')

  local add_count mod_count del_count ren_count total_count
  add_count=$(echo "$added_list"   | grep -c . || true)
  mod_count=$(echo "$modified_list"| grep -c . || true)
  del_count=$(echo "$deleted_list" | grep -c . || true)
  ren_count=$(echo "$renamed_list" | grep -c . || true)
  total_count=$((add_count + mod_count + del_count + ren_count))

  # ── Determine conventional commit type ──────────────────────────────────

  # Look for test files
  local has_tests has_config has_docs has_ci has_src
  has_tests=$(echo "$all_changed" | grep -iE "(test|spec)\." | head -1)
  has_config=$(echo "$all_changed" | grep -iE "\.(env|config|cfg|ini|yaml|yml|toml|json)$|Dockerfile|Makefile" | head -1)
  has_docs=$(echo "$all_changed" | grep -iE "\.(md|txt|rst|adoc)$|README|CHANGELOG|LICENCE|LICENSE" | head -1)
  has_ci=$(echo "$all_changed" | grep -iE "\.github/|\.gitlab|\.circleci|jenkinsfile|\.travis" | head -1)
  has_src=$(echo "$all_changed" | grep -vE "(test|spec|\.md|\.txt|Dockerfile|\.yml|\.yaml|\.env)" | head -1)

  local commit_type="chore"
  [[ -n "$has_tests" && -z "$has_src"  ]]  && commit_type="test"
  [[ -n "$has_docs"  && -z "$has_src"  ]]  && commit_type="docs"
  [[ -n "$has_ci"    && -z "$has_src"  ]]  && commit_type="ci"
  [[ -n "$has_config"&& -z "$has_src"  ]]  && commit_type="build"
  [[ -n "$has_src"   && del_count -gt 0 && add_count -eq 0 && mod_count -lt 2 ]] && commit_type="refactor"
  [[ -n "$has_src"   && add_count -gt 0 ]]  && commit_type="feat"
  [[ -n "$has_src"   && mod_count -gt 0 && add_count -eq 0 ]] && commit_type="fix"
  # If only renaming/moving
  [[ $ren_count -gt 0 && $add_count -eq 0 && $mod_count -eq 0 && $del_count -eq 0 ]] && commit_type="refactor"

  # ── Build scope from most-changed directory ──────────────────────────────
  local top_dir
  top_dir=$(echo "$all_changed" | awk '{print $2}' | \
    awk -F'/' 'NF>1{print $1}' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
  [[ -n "$top_dir" ]] && scope="($top_dir)"

  # ── Build human-readable summary ─────────────────────────────────────────

  # For a single file change — be specific
  if [[ "$total_count" -eq 1 ]]; then
    local only_file change_type
    only_file=$(echo "$all_changed" | awk '{print $2}' | head -1)
    change_type=$(echo "$all_changed" | awk '{print $1}' | head -1)
    local basename_file
    basename_file=$(basename "$only_file")
    local ext="${basename_file##*.}"
    local name_no_ext="${basename_file%.*}"

    case "$change_type" in
      A) summary="add ${name_no_ext} ${ext} file" ;;
      M) summary="update ${name_no_ext} in ${only_file%/*}" ;;
      D) summary="remove ${basename_file}" ;;
      R*) summary="rename ${basename_list}" ;;
      *) summary="update ${basename_file}" ;;
    esac

  # For 2–5 files — list them
  elif [[ "$total_count" -le 5 ]]; then
    local file_names
    file_names=$(echo "$all_changed" | awk '{print $2}' | xargs -I{} basename {} | tr '\n' ', ' | sed 's/,$//')

    local parts=()
    [[ $add_count -gt 0 ]] && parts+=("add $add_count file(s)")
    [[ $mod_count -gt 0 ]] && parts+=("update $mod_count file(s)")
    [[ $del_count -gt 0 ]] && parts+=("remove $del_count file(s)")
    [[ $ren_count -gt 0 ]] && parts+=("rename $ren_count file(s)")

    local action_str
    action_str=$(IFS=', '; echo "${parts[*]}")
    summary="${action_str}: ${file_names}"

  # For large changesets — describe at directory level
  else
    local changed_dirs
    changed_dirs=$(echo "$all_changed" | awk '{print $2}' | \
      awk -F'/' 'NF>1{print $1} NF==1{print "."}' | sort -u | tr '\n' ', ' | sed 's/,$//')

    local parts=()
    [[ $add_count -gt 0 ]] && parts+=("$add_count added")
    [[ $mod_count -gt 0 ]] && parts+=("$mod_count modified")
    [[ $del_count -gt 0 ]] && parts+=("$del_count deleted")

    local counts_str
    counts_str=$(IFS=', '; echo "${parts[*]}")
    summary="${counts_str} across ${changed_dirs}"
  fi

  # ── Assemble the full commit message ────────────────────────────────────
  local subject="${commit_type}${scope}: ${summary}"

  # Build body with file breakdown
  local body=""
  body+="Changes (${total_count} file(s) affected):\n"
  [[ $add_count -gt 0 ]] && body+="  + added   : $(echo "$added_list"   | tr '\n' ' ')\n"
  [[ $mod_count -gt 0 ]] && body+="  ~ modified: $(echo "$modified_list"| tr '\n' ' ')\n"
  [[ $del_count -gt 0 ]] && body+="  - removed : $(echo "$deleted_list" | tr '\n' ' ')\n"
  [[ $ren_count -gt 0 ]] && body+="  > renamed : $(echo "$renamed_list" | tr '\n' ' ')\n"

  # Return subject and body separated by a delimiter
  echo "${subject}|||${body}"
}

# =============================================================================
#  SECTION 6 — Push logic
# =============================================================================

do_push() {
  echo ""
  echo -e "${YELLOW}${BOLD}⟳  Changes detected — preparing commit...${RESET}"
  echo ""

  # Show what changed (like git status output)
  echo -e "${CYAN}── Git Status ──────────────────────────────────────${RESET}"
  git status --short
  echo -e "${CYAN}────────────────────────────────────────────────────${RESET}"
  echo ""

  # Generate message
  local msg_raw
  msg_raw=$(generate_commit_message)
  local subject="${msg_raw%%|||*}"
  local body="${msg_raw##*|||}"

  echo -e "${BLUE}── Commit Message ──────────────────────────────────${RESET}"
  echo -e "  ${BOLD}${subject}${RESET}"
  echo ""
  echo -e "$(echo -e "$body")"
  echo -e "${BLUE}────────────────────────────────────────────────────${RESET}"
  echo ""

  # Commit (git add -A was already called inside generate_commit_message)
  if git commit -m "$subject" -m "$(echo -e "$body")" 2>/dev/null; then
    echo -e "${GREEN}✔  Committed successfully${RESET}"
  else
    echo -e "${YELLOW}⚠  Nothing new to commit (already up to date)${RESET}"
    return 0
  fi

  # Push
  echo -e "${BLUE}▶  Pushing to ${BOLD}${REMOTE_NAME}/${CURRENT_BRANCH}${RESET}${BLUE}...${RESET}"
  if git push "$REMOTE_NAME" "$CURRENT_BRANCH" 2>&1; then
    echo ""
    echo -e "${GREEN}${BOLD}✔  Push successful → ${REMOTE_URL}${RESET}"
  else
    echo ""
    echo -e "${RED}${BOLD}✖  Push failed!${RESET}"
    echo -e "${YELLOW}   Possible reasons:${RESET}"
    echo -e "   • No internet connection"
    echo -e "   • Authentication error (check your GitHub token)"
    echo -e "   • Remote branch is ahead — run: ${CYAN}git pull --rebase${RESET}"
    echo ""
    return 1
  fi

  # Save current hash to avoid re-pushing the same state
  get_tree_hash > "$LAST_HASH_FILE"
  echo ""
}

# =============================================================================
#  SECTION 7 — Watch loop
# =============================================================================

watch_loop() {
  # Load the last known hash (if any)
  local last_hash=""
  [[ -f "$LAST_HASH_FILE" ]] && last_hash=$(cat "$LAST_HASH_FILE")

  echo -e "${GREEN}${BOLD}👁  Watching for changes every ${WATCH_INTERVAL}s  (Ctrl+C to stop)${RESET}"
  echo -e "${CYAN}   Repo  : ${BOLD}$REPO_ROOT${RESET}"
  echo -e "${CYAN}   Remote: ${BOLD}$REMOTE_URL${RESET}"
  echo -e "${CYAN}   Branch: ${BOLD}$CURRENT_BRANCH${RESET}"
  echo ""

  while true; do
    sleep "$WATCH_INTERVAL"

    local current_hash
    current_hash=$(get_tree_hash)

    if [[ "$current_hash" != "$last_hash" ]] && has_changes; then
      do_push
      last_hash=$(get_tree_hash)
    fi
  done
}

# =============================================================================
#  SECTION 8 — Entry point
# =============================================================================

main() {
  print_banner
  check_git_installed
  detect_repo        # sets REPO_ROOT, cds into it
  detect_remote      # sets REMOTE_NAME, REMOTE_URL, CURRENT_BRANCH
  watch_loop
}

# Trap Ctrl+C for a clean exit message
trap 'echo ""; echo -e "${YELLOW}${BOLD}⏹  AutoPush stopped. Goodbye!${RESET}"; echo ""; exit 0' INT

main
