#!/usr/bin/env bash
# install.sh — Install EPICS skills to AI coding assistants
#
# Usage: ./install.sh [options] <target>
#
# Targets: claude | opencode | gemini | codex | all
# Options:
#   --global          User-level install (default)
#   --project <path>  Project-local install
#   --copy            Copy skill directories (default)
#   --symlink         Symlink skill directories (git pull = auto-update)
#   --clone           Clone repo as the skills directory
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────
SCOPE="global"
METHOD="copy"
PROJECT_PATH=""

# ── Target directory map (global) ─────────────────────────────
declare -A GLOBAL_DIRS
GLOBAL_DIRS[claude]="$HOME/.claude/skills"
GLOBAL_DIRS[opencode]="$HOME/.config/opencode/skills"
GLOBAL_DIRS[gemini]="$HOME/.gemini/skills"
GLOBAL_DIRS[codex]="$HOME/.codex/skills"

# ── Target directory map (project-local suffix) ───────────────
declare -A PROJECT_SUFFIXES
PROJECT_SUFFIXES[claude]=".claude/skills"
PROJECT_SUFFIXES[opencode]=".opencode/skills"
PROJECT_SUFFIXES[gemini]=".gemini/skills"
PROJECT_SUFFIXES[codex]=".codex/skills"

# ── Help ──────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: ./install.sh [options] <target>

Install EPICS skills to AI coding assistants.

Targets:
  claude     Claude Code (default recommendation)
  opencode   OpenCode
  gemini     Gemini CLI
  codex      Codex CLI
  all        All of the above

Options:
  --global          Install to user-level directory (default)
  --project <path>  Install to a specific project
  --copy            Copy skill directories (default, safest)
  --symlink         Symlink skill directories (updates when source is git-pulled)
  --clone           Clone repo as the skills directory

Examples:
  ./install.sh claude                          # Claude Code, user-level, copy
  ./install.sh --project ~/my-ioc claude       # Claude Code, project-local
  ./install.sh --symlink opencode              # OpenCode, symlink for auto-update
  ./install.sh all                             # All tools, user-level
EOF
    exit 0
}

# ── Parse arguments ───────────────────────────────────────────
TARGETS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage ;;
        --global) SCOPE="global"; shift ;;
        --project)
            SCOPE="project"
            PROJECT_PATH="$2"
            if [[ -z "$PROJECT_PATH" ]]; then
                echo "ERROR: --project requires a path argument"
                exit 1
            fi
            shift 2
            ;;
        --copy) METHOD="copy"; shift ;;
        --symlink) METHOD="symlink"; shift ;;
        --clone) METHOD="clone"; shift ;;
        claude|opencode|gemini|codex|all) TARGETS+=("$1"); shift ;;
        *)
            echo "ERROR: Unknown argument: $1"
            usage
            ;;
    esac
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo "ERROR: No target specified."
    usage
fi

# ── Resolve target list ───────────────────────────────────────
ALL_TARGETS=(claude opencode gemini codex)
if [[ "${TARGETS[0]}" == "all" ]]; then
    TARGETS=("${ALL_TARGETS[@]}")
fi

# ── Find source skills directory ──────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR"

# Verify we are in the skills repo (look for at least one SKILL.md)
SKILL_COUNT=$(find "$SOURCE_DIR" -maxdepth 2 -name SKILL.md | wc -l)
if [[ "$SKILL_COUNT" -eq 0 ]]; then
    echo "ERROR: No SKILL.md files found. Run this script from the epics-skills repo root."
    exit 1
fi

# ── Install function ──────────────────────────────────────────
install_skills() {
    local target="$1"
    local dest_dir

    if [[ "$SCOPE" == "project" ]]; then
        dest_dir="${PROJECT_PATH}/${PROJECT_SUFFIXES[$target]}"
    else
        dest_dir="${GLOBAL_DIRS[$target]}"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Installing to: $target"
    echo "  Destination: $dest_dir"
    echo "  Method:      $METHOD"
    echo "  Scope:       $SCOPE"

    # ── Clone method ──────────────────────────────────────────
    if [[ "$METHOD" == "clone" ]]; then
        if [[ -d "$dest_dir/.git" ]]; then
            echo "  → Git repo exists, pulling latest..."
            (cd "$dest_dir" && git pull --ff-only) || echo "  ⚠ git pull failed; continuing"
        else
            echo "  → Cloning repo..."
            if [[ -d "$dest_dir" ]]; then
                echo "  ⚠ Removing existing non-git directory: $dest_dir"
                rm -rf "$dest_dir"
            fi
            mkdir -p "$(dirname "$dest_dir")"
            # Clone self — use file:// for local, or remote if available
            REMOTE=$(cd "$SOURCE_DIR" && git remote get-url origin 2>/dev/null || echo "")
            if [[ -n "$REMOTE" ]]; then
                git clone "$REMOTE" "$dest_dir"
            else
                echo "  → No git remote; copying instead"
                cp -r "$SOURCE_DIR" "$dest_dir"
                (cd "$dest_dir" && git init && git add . && git commit -m "Initial import") || true
            fi
        fi
        echo "  ✔ Done ($target)"
        return
    fi

    # ── Ensure destination directory exists ───────────────────
    mkdir -p "$dest_dir"

    # ── Install each skill ────────────────────────────────────
    local count=0
    for skill_dir in "$SOURCE_DIR"/*/; do
        local skill_name
        skill_name="$(basename "$skill_dir")"

        # Skip non-skill directories
        if [[ ! -f "$skill_dir/SKILL.md" ]]; then
            continue
        fi

        local target_skill_dir="$dest_dir/$skill_name"

        case "$METHOD" in
            copy)
                rm -rf "$target_skill_dir"
                cp -r "$skill_dir" "$target_skill_dir"
                ;;
            symlink)
                if [[ -L "$target_skill_dir" ]] || [[ -d "$target_skill_dir" ]]; then
                    rm -rf "$target_skill_dir"
                fi
                ln -s "$skill_dir" "$target_skill_dir"
                ;;
        esac
        count=$((count + 1))
    done

    echo "  ✔ Installed $count skills ($target)"
}

# ── Run install for each target ───────────────────────────────
for target in "${TARGETS[@]}"; do
    install_skills "$target"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Installation complete."
echo ""
echo "Restart your AI coding assistant to pick up the new skills."
echo ""
echo "To verify:"
for target in "${TARGETS[@]}"; do
    if [[ "$SCOPE" == "project" ]]; then
        echo "  ls ${PROJECT_PATH}/${PROJECT_SUFFIXES[$target]}/*/SKILL.md"
    else
        echo "  ls ${GLOBAL_DIRS[$target]}/*/SKILL.md"
    fi
done
