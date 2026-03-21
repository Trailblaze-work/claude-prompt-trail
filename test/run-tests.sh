#!/usr/bin/env bash
set -euo pipefail

# Test suite for claude-prompt-trail
# Tests hook functionality, plugin structure, worktree compatibility,
# multi-commit sessions, parallel sessions, and edge cases.
# All tests run in isolated /tmp directories — no side effects on the real repo.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="$PROJECT_DIR/hooks"

PASSED=0
FAILED=0
SKIPPED=0

# --- Helpers ---

pass() {
    printf "  \033[32mPASS\033[0m %s\n" "$1"
    PASSED=$((PASSED + 1))
}

fail() {
    printf "  \033[31mFAIL\033[0m %s: %s\n" "$1" "$2"
    FAILED=$((FAILED + 1))
}

skip() {
    printf "  \033[33mSKIP\033[0m %s: %s\n" "$1" "$2"
    SKIPPED=$((SKIPPED + 1))
}

section() {
    printf "\n\033[1m%s\033[0m\n" "$1"
}

# Create a fresh test repo in /tmp and cd into it.
# Sets TEST_DIR for cleanup.
make_test_repo() {
    TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cgpm-test.XXXXXX")
    cd "$TEST_DIR"
    git init -q -b main
    git config user.email "test@test.com"
    git config user.name "Test"
    git commit -q --allow-empty -m "init"
}

cleanup_test_repo() {
    if [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]]; then
        cd /tmp
        git -C "$TEST_DIR" worktree list --porcelain 2>/dev/null | grep "^worktree " | while read -r _ path; do
            [[ "$path" != "$TEST_DIR" ]] && git -C "$TEST_DIR" worktree remove --force "$path" 2>/dev/null || true
        done
        rm -rf "$TEST_DIR"
    fi
}

# Install plugin structure into current repo
install_plugin() {
    mkdir -p .claude-plugin hooks
    cp "$PROJECT_DIR/.claude-plugin/plugin.json" .claude-plugin/
    cp "$HOOKS_DIR/capture-prompts.sh" hooks/
    cp "$HOOKS_DIR/setup-notes.sh" hooks/
    cp "$HOOKS_DIR/hooks.json" hooks/
    chmod +x hooks/*.sh
    mkdir -p .claude
    cat > .claude/settings.json <<'JSON'
{
  "enabledPlugins": {
    ".": true
  }
}
JSON
}

# Create a mock transcript JSONL.
# Usage: make_transcript <path> [entries...]
# Entry format:
#   "user:Some prompt text"          → user message
#   "commit:git commit -m msg"       → assistant tool_use with git commit
#   "bash:some command"              → assistant tool_use with non-commit command
#   "tool:ToolName"                  → assistant tool_use for a named tool (e.g. Edit, Grep)
#
# Optional env vars (set before calling, affect ALL user/assistant records):
#   TRANSCRIPT_MODEL       → model name (default: claude-opus-4-6)
#   TRANSCRIPT_SLUG        → session slug (default: "")
#   TRANSCRIPT_VERSION     → client version (default: "")
#   TRANSCRIPT_BRANCH      → git branch (default: "")
#   TRANSCRIPT_PERMISSION  → permission mode (default: "")
#   TRANSCRIPT_TOKENS_IN   → input tokens per assistant turn (default: 0)
#   TRANSCRIPT_TOKENS_OUT  → output tokens per assistant turn (default: 0)
#   TRANSCRIPT_CACHE_READ  → cache read tokens per assistant turn (default: 0)
#   TRANSCRIPT_CACHE_WRITE → cache write tokens per assistant turn (default: 0)
make_transcript() {
    local path="$1"
    shift

    local model="${TRANSCRIPT_MODEL:-}"
    local slug="${TRANSCRIPT_SLUG:-}"
    local version="${TRANSCRIPT_VERSION:-}"
    local branch="${TRANSCRIPT_BRANCH:-}"
    local perm="${TRANSCRIPT_PERMISSION:-}"
    local tok_in="${TRANSCRIPT_TOKENS_IN:-0}"
    local tok_out="${TRANSCRIPT_TOKENS_OUT:-0}"
    local cache_r="${TRANSCRIPT_CACHE_READ:-0}"
    local cache_w="${TRANSCRIPT_CACHE_WRITE:-0}"

    # Build user record extra fields
    local user_extra=""
    [[ -n "$slug" ]] && user_extra="$user_extra,\"slug\":\"$slug\""
    [[ -n "$version" ]] && user_extra="$user_extra,\"version\":\"$version\""
    [[ -n "$branch" ]] && user_extra="$user_extra,\"gitBranch\":\"$branch\""
    [[ -n "$perm" ]] && user_extra="$user_extra,\"permissionMode\":\"$perm\""

    # Build assistant usage block
    local usage=""
    if [[ "$tok_in" -gt 0 || "$tok_out" -gt 0 || "$cache_r" -gt 0 || "$cache_w" -gt 0 ]]; then
        usage=",\"usage\":{\"input_tokens\":$tok_in,\"output_tokens\":$tok_out,\"cache_read_input_tokens\":$cache_r,\"cache_creation_input_tokens\":$cache_w}"
    fi

    # Build model field
    local model_field=""
    [[ -n "$model" ]] && model_field=",\"model\":\"$model\""

    > "$path"
    for entry in "$@"; do
        local type="${entry%%:*}"
        local content="${entry#*:}"
        case "$type" in
            user)
                content=$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g')
                printf '{"type":"user","message":{"content":"%s"}%s}\n' "$content" "$user_extra" >> "$path"
                ;;
            commit)
                content=$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g')
                printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"%s"}}]%s%s}}\n' "$content" "$model_field" "$usage" >> "$path"
                ;;
            bash)
                content=$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g')
                printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"%s"}}]%s%s}}\n' "$content" "$model_field" "$usage" >> "$path"
                ;;
            tool)
                # content is the tool name (e.g. "Edit", "Grep", "mcp__notion__search")
                content=$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g')
                printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":{}}]%s%s}}\n' "$content" "$model_field" "$usage" >> "$path"
                ;;
        esac
    done
}

# Build PostToolUse hook JSON for capture-prompts.sh
make_hook_input() {
    local commit_hash="$1"
    local transcript_path="$2"
    local session_id="${3:-test-session}"
    local branch="${4:-main}"
    local message="${5:-test}"

    cat <<EOF
{"tool_input":{"command":"git commit -m ${message}"},"tool_response":"[${branch} ${commit_hash}] ${message}\\n 1 file changed","transcript_path":"${transcript_path}","session_id":"${session_id}"}
EOF
}


# ============================================================
# setup-notes.sh tests
# ============================================================

test_setup_notes_configures_displayref() {
    make_test_repo
    trap cleanup_test_repo RETURN

    bash "$HOOKS_DIR/setup-notes.sh"

    local display_ref
    display_ref=$(git config --local --get notes.displayRef 2>/dev/null || echo "")
    if [[ "$display_ref" == "refs/notes/claude-prompt-trail" ]]; then
        pass "setup-notes sets notes.displayRef"
    else
        fail "setup-notes sets notes.displayRef" "got '$display_ref'"
    fi
}

test_setup_notes_configures_fetch_refspec() {
    make_test_repo
    trap cleanup_test_repo RETURN
    git remote add origin "https://example.com/test.git"

    bash "$HOOKS_DIR/setup-notes.sh"

    local fetch
    fetch=$(git config --local --get-all remote.origin.fetch 2>/dev/null | grep "claude-prompt-trail" || echo "")
    if [[ "$fetch" == "+refs/notes/claude-prompt-trail:refs/notes/claude-prompt-trail" ]]; then
        pass "setup-notes adds fetch refspec for notes"
    else
        fail "setup-notes adds fetch refspec for notes" "got '$fetch'"
    fi
}

test_setup_notes_idempotent() {
    make_test_repo
    trap cleanup_test_repo RETURN
    git remote add origin "https://example.com/test.git"

    bash "$HOOKS_DIR/setup-notes.sh"
    bash "$HOOKS_DIR/setup-notes.sh"
    bash "$HOOKS_DIR/setup-notes.sh"

    local count
    count=$(git config --local --get-all remote.origin.fetch 2>/dev/null | grep -c "claude-prompt-trail" || echo "0")
    if [[ "$count" -eq 1 ]]; then
        pass "setup-notes is idempotent (no duplicate fetch refspecs)"
    else
        fail "setup-notes is idempotent" "got $count fetch refspecs for claude-prompt-trail"
    fi
}

test_setup_notes_cleans_push_refspec() {
    make_test_repo
    trap cleanup_test_repo RETURN
    git remote add origin "https://example.com/test.git"

    # Simulate leftover push refspec from earlier version
    git config --add --local remote.origin.push "+refs/notes/claude-prompt-trail:refs/notes/claude-prompt-trail"

    bash "$HOOKS_DIR/setup-notes.sh"

    local push
    push=$(git config --local --get-all remote.origin.push 2>/dev/null | grep "claude-prompt-trail" || echo "")
    if [[ -z "$push" ]]; then
        pass "setup-notes removes leftover push refspec"
    else
        fail "setup-notes removes leftover push refspec" "still has: $push"
    fi
}

test_setup_notes_configures_rewrite_ref() {
    make_test_repo
    trap cleanup_test_repo RETURN

    bash "$HOOKS_DIR/setup-notes.sh"

    local rewrite_ref
    rewrite_ref=$(git config --local --get notes.rewriteRef 2>/dev/null || echo "")
    if [[ "$rewrite_ref" == "refs/notes/claude-prompt-trail" ]]; then
        pass "setup-notes sets notes.rewriteRef"
    else
        fail "setup-notes sets notes.rewriteRef" "got '$rewrite_ref'"
    fi
}

test_setup_notes_configures_rewrite_mode() {
    make_test_repo
    trap cleanup_test_repo RETURN

    bash "$HOOKS_DIR/setup-notes.sh"

    local rewrite_mode
    rewrite_mode=$(git config --local --get notes.rewriteMode 2>/dev/null || echo "")
    if [[ "$rewrite_mode" == "overwrite" ]]; then
        pass "setup-notes sets notes.rewriteMode to overwrite"
    else
        fail "setup-notes sets notes.rewriteMode to overwrite" "got '$rewrite_mode'"
    fi
}

test_notes_survive_rebase() {
    make_test_repo
    trap cleanup_test_repo RETURN

    bash "$HOOKS_DIR/setup-notes.sh"

    # Create base commit, then a feature commit with a note
    echo "base" > base.txt
    git add base.txt
    git commit -q -m "base"

    echo "feature" > feature.txt
    git add feature.txt
    git commit -q -m "feature"

    git notes --ref=claude-prompt-trail add -m "test note for rebase"

    # Rebase onto the root (rewrites SHAs)
    git rebase -q --onto HEAD~2 HEAD~1 HEAD

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == "test note for rebase" ]]; then
        pass "notes survive rebase"
    else
        fail "notes survive rebase" "got '$note'"
    fi
}

test_notes_survive_amend() {
    make_test_repo
    trap cleanup_test_repo RETURN

    bash "$HOOKS_DIR/setup-notes.sh"

    echo "original" > file.txt
    git add file.txt
    git commit -q -m "original commit"

    git notes --ref=claude-prompt-trail add -m "test note for amend"

    # Amend the commit (changes SHA)
    echo "amended" >> file.txt
    git add file.txt
    git commit -q --amend -m "amended commit"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == "test note for amend" ]]; then
        pass "notes survive amend"
    else
        fail "notes survive amend" "got '$note'"
    fi
}

test_setup_notes_no_remote() {
    make_test_repo
    trap cleanup_test_repo RETURN

    # No remote — should still set displayRef without error
    bash "$HOOKS_DIR/setup-notes.sh"

    local display_ref
    display_ref=$(git config --local --get notes.displayRef 2>/dev/null || echo "")
    if [[ "$display_ref" == "refs/notes/claude-prompt-trail" ]]; then
        pass "setup-notes works without a remote"
    else
        fail "setup-notes works without a remote" "got '$display_ref'"
    fi

    # Should NOT create orphaned remote.origin.fetch when no remote exists
    local fetch_ref
    fetch_ref=$(git config --local --get-all remote.origin.fetch 2>/dev/null || echo "")
    if [[ -z "$fetch_ref" ]]; then
        pass "setup-notes does not create orphaned fetch refspec"
    else
        fail "setup-notes does not create orphaned fetch refspec" "got '$fetch_ref'"
    fi
}


# ============================================================
# capture-prompts.sh — basic functionality
# ============================================================

test_capture_attaches_note() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "hello" > test.txt
    git add test.txt
    git commit -q -m "test commit"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Add a test file" \
        "user:Commit it" \
        "commit:git commit -m test commit"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"Claude Code Prompts"* && "$note" == *"Add a test file"* && "$note" == *"Commit it"* ]]; then
        pass "attaches note with prompts"
    else
        fail "attaches note with prompts" "note: $note"
    fi
}

test_capture_note_format() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "content" > file.txt
    git add file.txt
    git commit -q -m "format test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    TRANSCRIPT_MODEL="claude-opus-4-6" \
    TRANSCRIPT_SLUG="starry-hugging-otter" \
    TRANSCRIPT_VERSION="2.1.59" \
    TRANSCRIPT_BRANCH="main" \
    TRANSCRIPT_TOKENS_IN=1000 \
    TRANSCRIPT_TOKENS_OUT=500 \
    make_transcript "$transcript" \
        "user:Do the thing" \
        "bash:echo hello" \
        "commit:git commit -m format test"

    make_hook_input "$hash" "$transcript" "session-abc-123" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")

    local ok=true
    [[ "$note" == *"## Claude Code Prompts"* ]] || ok=false
    [[ "$note" == *"<!-- format:v2 -->"* ]] || ok=false
    [[ "$note" == *"**Session**: session-abc-123"* ]] || ok=false
    [[ "$note" == *"**Captured**:"* ]] || ok=false
    [[ "$note" == *"### Prompts"* ]] || ok=false
    [[ "$note" == *"**1.** Do the thing"* ]] || ok=false

    if $ok; then
        pass "note has correct v2 markdown format"
    else
        fail "note has correct v2 markdown format" "note: $note"
    fi
}

test_capture_multiple_prompts() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "content" > file.txt
    git add file.txt
    git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:First, create a new component" \
        "bash:touch component.tsx" \
        "user:Add validation to it" \
        "bash:echo validation > component.tsx" \
        "user:Now commit" \
        "commit:git commit -m test"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    local count
    count=$(echo "$note" | grep -c '^\*\*[0-9]' || echo "0")
    if [[ "$count" -eq 3 ]]; then
        pass "captures all prompts in session ($count)"
    else
        fail "captures all prompts in session" "expected 3, got $count"
    fi
}

test_capture_ignores_non_commits() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo '{"tool_input":{"command":"ls -la"},"tool_response":"total 0"}' \
        | bash "$HOOKS_DIR/capture-prompts.sh"

    local count
    count=$(git notes --ref=claude-prompt-trail list 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        pass "ignores non-commit commands"
    else
        fail "ignores non-commit commands" "found $count notes"
    fi
}

test_capture_ignores_failed_commits() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo '{"tool_input":{"command":"git commit -m test"},"tool_response":"nothing to commit, working tree clean"}' \
        | bash "$HOOKS_DIR/capture-prompts.sh"

    local count
    count=$(git notes --ref=claude-prompt-trail list 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        pass "ignores failed commits (no [branch hash] in output)"
    else
        fail "ignores failed commits" "found $count notes"
    fi
}

test_capture_amend_overwrites_note() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "v1" > file.txt
    git add file.txt
    git commit -q -m "original"
    local hash
    hash=$(git rev-parse --short HEAD)

    # First note
    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Original prompt" \
        "commit:git commit -m original"
    make_hook_input "$hash" "$transcript" "session-1" | bash "$HOOKS_DIR/capture-prompts.sh"

    # Amend commit (same hash target, different content)
    echo "v2" > file.txt
    git add file.txt
    git commit -q --amend -m "amended"
    local new_hash
    new_hash=$(git rev-parse --short HEAD)

    make_transcript "$transcript" \
        "user:Amend with updated content" \
        "commit:git commit --amend -m amended"
    make_hook_input "$new_hash" "$transcript" "session-1" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"Amend with updated content"* ]]; then
        pass "amend overwrites previous note"
    else
        fail "amend overwrites previous note" "note: $note"
    fi
}

test_capture_branch_with_slashes() {
    make_test_repo
    trap cleanup_test_repo RETURN

    git checkout -q -b feature/my-thing
    echo "content" > file.txt
    git add file.txt
    git commit -q -m "feature work"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Work on feature" \
        "commit:git commit -m feature work"

    # Branch name with slash in the response
    local hook_input
    hook_input=$(cat <<EOF
{"tool_input":{"command":"git commit -m feature work"},"tool_response":"[feature/my-thing ${hash}] feature work\\n 1 file changed","transcript_path":"${transcript}","session_id":"test-session"}
EOF
)
    echo "$hook_input" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"Work on feature"* ]]; then
        pass "handles branch names with slashes"
    else
        fail "handles branch names with slashes" "note: $note"
    fi
}

test_capture_detached_head() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "content" > file.txt
    git add file.txt
    git commit -q -m "detached work"
    local hash
    hash=$(git rev-parse --short HEAD)

    # Detach HEAD
    git checkout -q --detach HEAD

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Fix something in detached HEAD" \
        "commit:git commit -m detached work"

    # Simulate git's detached HEAD output format
    local hook_input
    hook_input=$(cat <<EOF
{"tool_input":{"command":"git commit -m detached work"},"tool_response":"[detached HEAD ${hash}] detached work\\n 1 file changed","transcript_path":"${transcript}","session_id":"test-session"}
EOF
)
    echo "$hook_input" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"Fix something in detached HEAD"* ]]; then
        pass "handles detached HEAD commit format"
    else
        fail "handles detached HEAD commit format" "note: $note"
    fi
}

test_capture_root_commit() {
    make_test_repo
    trap cleanup_test_repo RETURN

    # Create an orphan branch with a root commit
    git checkout -q --orphan orphan-branch
    echo "root content" > root.txt
    git add root.txt
    git commit -q -m "root commit"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Initialize orphan branch" \
        "commit:git commit -m root commit"

    # Simulate git's root-commit output format
    local hook_input
    hook_input=$(cat <<EOF
{"tool_input":{"command":"git commit -m root commit"},"tool_response":"[orphan-branch (root-commit) ${hash}] root commit\\n 1 file changed","transcript_path":"${transcript}","session_id":"test-session"}
EOF
)
    echo "$hook_input" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"Initialize orphan branch"* ]]; then
        pass "handles root-commit format"
    else
        fail "handles root-commit format" "note: $note"
    fi
}


# ============================================================
# capture-prompts.sh — multi-commit sessions
# ============================================================

test_multi_commit_session() {
    make_test_repo
    trap cleanup_test_repo RETURN

    # Build a transcript that has two commits
    local transcript="$TEST_DIR/transcript.jsonl"

    # --- First commit ---
    echo "file1" > a.txt
    git add a.txt
    git commit -q -m "first"
    local hash1
    hash1=$(git rev-parse --short HEAD)

    make_transcript "$transcript" \
        "user:Create file a" \
        "bash:echo file1 > a.txt" \
        "user:Commit a" \
        "commit:git commit -m first"

    make_hook_input "$hash1" "$transcript" "session-multi" | bash "$HOOKS_DIR/capture-prompts.sh"

    # --- Second commit (append to same transcript) ---
    echo "file2" > b.txt
    git add b.txt
    git commit -q -m "second"
    local hash2
    hash2=$(git rev-parse --short HEAD)

    # Append new entries to existing transcript
    printf '{"type":"user","message":{"content":"Now create file b"}}\n' >> "$transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo file2 > b.txt"}}]}}\n' >> "$transcript"
    printf '{"type":"user","message":{"content":"Commit b"}}\n' >> "$transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m second"}}]}}\n' >> "$transcript"

    make_hook_input "$hash2" "$transcript" "session-multi" | bash "$HOOKS_DIR/capture-prompts.sh"

    # First commit note should have "Create file a" but NOT "create file b"
    local note1
    note1=$(git notes --ref=claude-prompt-trail show HEAD~1 2>/dev/null || echo "")
    if [[ "$note1" == *"Create file a"* && "$note1" != *"create file b"* ]]; then
        pass "multi-commit: first note has only first prompts"
    else
        fail "multi-commit: first note has only first prompts" "note: $note1"
    fi

    # Second commit note should have "create file b" but NOT "Create file a"
    local note2
    note2=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note2" == *"create file b"* || "$note2" == *"Now create file b"* ]] && [[ "$note2" != *"Create file a"* ]]; then
        pass "multi-commit: second note has only second prompts"
    else
        fail "multi-commit: second note has only second prompts" "note: $note2"
    fi
}


# ============================================================
# Parallel sessions on same repo
# ============================================================

test_parallel_sessions_no_conflict() {
    make_test_repo
    trap cleanup_test_repo RETURN

    # Session A: commit on branch-a
    git checkout -q -b branch-a
    echo "a" > a.txt
    git add a.txt
    git commit -q -m "commit from session a"
    local hash_a
    hash_a=$(git rev-parse --short HEAD)

    local transcript_a="$TEST_DIR/transcript-a.jsonl"
    make_transcript "$transcript_a" \
        "user:Work from session A" \
        "commit:git commit -m commit from session a"

    # Session B: commit on branch-b (branched from main)
    git checkout -q main
    git checkout -q -b branch-b
    echo "b" > b.txt
    git add b.txt
    git commit -q -m "commit from session b"
    local hash_b
    hash_b=$(git rev-parse --short HEAD)

    local transcript_b="$TEST_DIR/transcript-b.jsonl"
    make_transcript "$transcript_b" \
        "user:Work from session B" \
        "commit:git commit -m commit from session b"

    # Run both hooks (simulating parallel sessions)
    local hook_a hook_b
    hook_a=$(cat <<EOF
{"tool_input":{"command":"git commit -m commit from session a"},"tool_response":"[branch-a ${hash_a}] commit from session a\\n 1 file changed","transcript_path":"${transcript_a}","session_id":"session-a"}
EOF
)
    hook_b=$(cat <<EOF
{"tool_input":{"command":"git commit -m commit from session b"},"tool_response":"[branch-b ${hash_b}] commit from session b\\n 1 file changed","transcript_path":"${transcript_b}","session_id":"session-b"}
EOF
)

    # Run sequentially (in practice, commits from different sessions
    # don't happen at the exact same instant)
    echo "$hook_a" | bash "$HOOKS_DIR/capture-prompts.sh"
    echo "$hook_b" | bash "$HOOKS_DIR/capture-prompts.sh"

    # Verify both notes exist
    local note_a note_b
    note_a=$(git notes --ref=claude-prompt-trail show branch-a 2>/dev/null || echo "")
    note_b=$(git notes --ref=claude-prompt-trail show branch-b 2>/dev/null || echo "")

    if [[ "$note_a" == *"session A"* ]]; then
        pass "parallel: session A note attached"
    else
        fail "parallel: session A note attached" "note: $note_a"
    fi

    if [[ "$note_b" == *"session B"* ]]; then
        pass "parallel: session B note attached"
    else
        fail "parallel: session B note attached" "note: $note_b"
    fi

    # Verify correct session IDs
    if [[ "$note_a" == *"session-a"* && "$note_b" == *"session-b"* ]]; then
        pass "parallel: session IDs are distinct"
    else
        fail "parallel: session IDs are distinct" "a=$note_a, b=$note_b"
    fi
}

test_parallel_notes_total_count() {
    make_test_repo
    trap cleanup_test_repo RETURN

    # Create 3 commits on separate branches, attach notes from separate sessions
    for i in 1 2 3; do
        git checkout -q main
        git checkout -q -b "branch-$i"
        echo "$i" > "file-$i.txt"
        git add "file-$i.txt"
        git commit -q -m "commit $i"
        local hash
        hash=$(git rev-parse --short HEAD)

        local transcript="$TEST_DIR/transcript-$i.jsonl"
        make_transcript "$transcript" \
            "user:Task $i" \
            "commit:git commit -m commit $i"

        local hook_input
        hook_input=$(cat <<EOF
{"tool_input":{"command":"git commit -m commit $i"},"tool_response":"[branch-$i ${hash}] commit $i\\n 1 file changed","transcript_path":"${transcript}","session_id":"session-$i"}
EOF
)
        echo "$hook_input" | bash "$HOOKS_DIR/capture-prompts.sh"
    done

    local count
    count=$(git notes --ref=claude-prompt-trail list 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -eq 3 ]]; then
        pass "parallel: all 3 notes created without conflict"
    else
        fail "parallel: all 3 notes created" "expected 3, got $count"
    fi
}


# ============================================================
# Plugin structure
# ============================================================

test_plugin_json_valid() {
    if python3 -c "
import json
with open('$PROJECT_DIR/.claude-plugin/plugin.json') as f:
    p = json.load(f)
assert p['name'] == 'prompt-trail', f'name: {p[\"name\"]}'
assert 'version' in p
assert 'description' in p
"; then
        pass "plugin.json is valid"
    else
        fail "plugin.json is valid" "validation failed"
    fi
}

test_hooks_json_valid() {
    if python3 -c "
import json
with open('$PROJECT_DIR/hooks/hooks.json') as f:
    h = json.load(f)
hooks = h['hooks']
assert 'PostToolUse' in hooks
assert 'SessionStart' in hooks
ptu = hooks['PostToolUse']
assert any('capture-prompts' in json.dumps(e) for e in ptu), 'capture-prompts missing'
ss = hooks['SessionStart']
assert any('setup-notes' in json.dumps(e) for e in ss), 'SessionStart missing setup-notes'
"; then
        pass "hooks.json is valid"
    else
        fail "hooks.json is valid" "validation failed"
    fi
}

test_settings_enables_plugin() {
    if python3 -c "
import json
with open('$PROJECT_DIR/.claude/settings.json') as f:
    s = json.load(f)
assert s.get('enabledPlugins', {}).get('.') is True, 'plugin not enabled'
assert 'hooks' not in s, 'settings.json should not have hooks key'
"; then
        pass "settings.json enables plugin without inline hooks"
    else
        fail "settings.json enables plugin without inline hooks" "validation failed"
    fi
}


# ============================================================
# Worktree compatibility
# ============================================================

test_plugin_present_in_worktree() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    git add .claude-plugin/ hooks/ .claude/
    git commit -q -m "add plugin"

    git worktree add -q "$TEST_DIR/wt" -b test-wt

    if [[ -f "$TEST_DIR/wt/.claude-plugin/plugin.json" && -x "$TEST_DIR/wt/hooks/capture-prompts.sh" && -f "$TEST_DIR/wt/hooks/hooks.json" ]]; then
        pass "plugin files present in worktree checkout"
    else
        fail "plugin files present in worktree checkout" "missing files"
    fi
}

test_setup_notes_in_worktree() {
    make_test_repo
    trap cleanup_test_repo RETURN
    git remote add origin "https://example.com/test.git"

    git worktree add -q "$TEST_DIR/wt" -b test-wt

    cd "$TEST_DIR/wt"
    bash "$HOOKS_DIR/setup-notes.sh"

    # Config should be visible from worktree
    local display_ref
    display_ref=$(git config --local --get notes.displayRef 2>/dev/null || echo "")
    if [[ "$display_ref" == "refs/notes/claude-prompt-trail" ]]; then
        pass "setup-notes works in worktree"
    else
        fail "setup-notes works in worktree" "got '$display_ref'"
    fi

    # And from main worktree (shared config)
    cd "$TEST_DIR"
    display_ref=$(git config --local --get notes.displayRef 2>/dev/null || echo "")
    if [[ "$display_ref" == "refs/notes/claude-prompt-trail" ]]; then
        pass "worktree config shared with main"
    else
        fail "worktree config shared with main" "got '$display_ref'"
    fi
}

test_capture_in_worktree() {
    make_test_repo
    trap cleanup_test_repo RETURN

    git worktree add -q "$TEST_DIR/wt" -b test-wt

    cd "$TEST_DIR/wt"
    echo "worktree content" > wt-file.txt
    git add wt-file.txt
    git commit -q -m "worktree commit"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/wt-transcript.jsonl"
    make_transcript "$transcript" \
        "user:Create a file in the worktree" \
        "commit:git commit -m worktree commit"

    local hook_input
    hook_input=$(cat <<EOF
{"tool_input":{"command":"git commit -m worktree commit"},"tool_response":"[test-wt ${hash}] worktree commit\\n 1 file changed","transcript_path":"${transcript}","session_id":"wt-session"}
EOF
)
    echo "$hook_input" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"Create a file in the worktree"* ]]; then
        pass "capture-prompts works in worktree"
    else
        fail "capture-prompts works in worktree" "note: $note"
    fi
}

test_worktree_note_visible_from_main() {
    make_test_repo
    trap cleanup_test_repo RETURN

    git worktree add -q "$TEST_DIR/wt" -b test-wt

    cd "$TEST_DIR/wt"
    echo "wt" > wt.txt
    git add wt.txt
    git commit -q -m "wt"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Worktree work" \
        "commit:git commit -m wt"
    local hook_input
    hook_input=$(cat <<EOF
{"tool_input":{"command":"git commit -m wt"},"tool_response":"[test-wt ${hash}] wt\\n 1 file changed","transcript_path":"${transcript}","session_id":"wt-session"}
EOF
)
    echo "$hook_input" | bash "$HOOKS_DIR/capture-prompts.sh"

    # Check from main worktree
    cd "$TEST_DIR"
    local note
    note=$(git notes --ref=claude-prompt-trail show test-wt 2>/dev/null || echo "")
    if [[ "$note" == *"Worktree work"* ]]; then
        pass "worktree note visible from main worktree"
    else
        fail "worktree note visible from main worktree" "note: $note"
    fi
}

test_notes_shared_between_worktrees() {
    make_test_repo
    trap cleanup_test_repo RETURN

    git worktree add -q "$TEST_DIR/wt" -b test-wt

    # Note from main
    echo "main" > main.txt
    git add main.txt
    git commit -q -m "main commit"
    local main_hash
    main_hash=$(git rev-parse --short HEAD)
    local transcript="$TEST_DIR/main-t.jsonl"
    make_transcript "$transcript" "user:Main work" "commit:git commit -m main commit"
    make_hook_input "$main_hash" "$transcript" "session-main" | bash "$HOOKS_DIR/capture-prompts.sh"

    # Note from worktree
    cd "$TEST_DIR/wt"
    echo "wt" > wt.txt
    git add wt.txt
    git commit -q -m "wt commit"
    local wt_hash
    wt_hash=$(git rev-parse --short HEAD)
    transcript="$TEST_DIR/wt-t.jsonl"
    make_transcript "$transcript" "user:Worktree work" "commit:git commit -m wt commit"
    local hook_input
    hook_input=$(cat <<EOF
{"tool_input":{"command":"git commit -m wt commit"},"tool_response":"[test-wt ${wt_hash}] wt commit\\n 1 file changed","transcript_path":"${transcript}","session_id":"session-wt"}
EOF
)
    echo "$hook_input" | bash "$HOOKS_DIR/capture-prompts.sh"

    # Both notes visible from either location
    local count_main count_wt
    cd "$TEST_DIR"
    count_main=$(git notes --ref=claude-prompt-trail list 2>/dev/null | wc -l | tr -d ' ')
    cd "$TEST_DIR/wt"
    count_wt=$(git notes --ref=claude-prompt-trail list 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$count_main" -eq 2 && "$count_wt" -eq 2 ]]; then
        pass "notes shared between main and worktree (both see 2)"
    else
        fail "notes shared between main and worktree" "main=$count_main, wt=$count_wt"
    fi
}


# ============================================================
# v2 format enrichment
# ============================================================

test_note_has_v2_format_marker() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt && git add x.txt && git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Do something" \
        "commit:git commit -m test"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"<!-- format:v2 -->"* ]]; then
        pass "note has v2 format marker"
    else
        fail "note has v2 format marker" "note: $note"
    fi
}

test_note_includes_model() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt && git add x.txt && git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    TRANSCRIPT_MODEL="claude-opus-4-6" \
    make_transcript "$transcript" \
        "user:Do something" \
        "bash:echo hi" \
        "commit:git commit -m test"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"**Model**: claude-opus-4-6"* ]]; then
        pass "note includes model"
    else
        fail "note includes model" "note: $note"
    fi
}

test_note_includes_client_version() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt && git add x.txt && git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    TRANSCRIPT_VERSION="2.1.59" \
    make_transcript "$transcript" \
        "user:Do something" \
        "commit:git commit -m test"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"**Client**: 2.1.59"* ]]; then
        pass "note includes client version"
    else
        fail "note includes client version" "note: $note"
    fi
}

test_note_includes_branch() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt && git add x.txt && git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    TRANSCRIPT_BRANCH="feature/avatar-upload" \
    make_transcript "$transcript" \
        "user:Do something" \
        "commit:git commit -m test"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"**Branch**: feature/avatar-upload"* ]]; then
        pass "note includes branch"
    else
        fail "note includes branch" "note: $note"
    fi
}

test_note_includes_stats() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt && git add x.txt && git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    TRANSCRIPT_MODEL="claude-opus-4-6" \
    TRANSCRIPT_TOKENS_IN=45230 \
    TRANSCRIPT_TOKENS_OUT=12847 \
    TRANSCRIPT_CACHE_READ=128450 \
    TRANSCRIPT_CACHE_WRITE=8200 \
    make_transcript "$transcript" \
        "user:Do something" \
        "bash:echo working" \
        "user:Continue" \
        "bash:echo done" \
        "commit:git commit -m test"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    local ok=true
    [[ "$note" == *"### Stats"* ]] || ok=false
    [[ "$note" == *"Turns"* ]] || ok=false
    [[ "$note" == *"Tokens in"* ]] || ok=false
    [[ "$note" == *"Tokens out"* ]] || ok=false
    [[ "$note" == *"Cache read"* ]] || ok=false
    [[ "$note" == *"Cache write"* ]] || ok=false

    if $ok; then
        pass "note includes stats table"
    else
        fail "note includes stats table" "note: $note"
    fi
}

test_note_includes_tools() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt && git add x.txt && git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Do something" \
        "tool:Edit" \
        "tool:Edit" \
        "tool:Read" \
        "tool:Grep" \
        "commit:git commit -m test"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    local ok=true
    [[ "$note" == *"### Tools"* ]] || ok=false
    [[ "$note" == *"Edit(2)"* ]] || ok=false
    [[ "$note" == *"Read(1)"* ]] || ok=false
    [[ "$note" == *"Grep(1)"* ]] || ok=false

    if $ok; then
        pass "note includes tools with counts"
    else
        fail "note includes tools with counts" "note: $note"
    fi
}

test_note_includes_permission() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt && git add x.txt && git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    TRANSCRIPT_PERMISSION="acceptEdits" \
    make_transcript "$transcript" \
        "user:Do something" \
        "commit:git commit -m test"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"**Permission**: accept-edits"* ]]; then
        pass "note includes permission mode (acceptEdits → accept-edits)"
    else
        fail "note includes permission mode" "note: $note"
    fi
}

test_note_permission_mode_labels() {
    make_test_repo
    trap cleanup_test_repo RETURN

    # Test each MODE_LABELS mapping: raw_mode:expected_label
    local all_ok=true
    local pair
    for pair in "plan:plan" "dontAsk:auto-accept" "bypassPermissions:bypass" "acceptEdits:accept-edits"; do
        local raw_mode="${pair%%:*}"
        local label="${pair#*:}"

        echo "$raw_mode" > "file-$raw_mode.txt"
        git add "file-$raw_mode.txt"
        git commit -q -m "commit $raw_mode"
        local hash
        hash=$(git rev-parse --short HEAD)

        local transcript="$TEST_DIR/transcript-$raw_mode.jsonl"
        TRANSCRIPT_PERMISSION="$raw_mode" \
        make_transcript "$transcript" \
            "user:Test $raw_mode" \
            "commit:git commit -m commit $raw_mode"

        make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

        local note
        note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
        if [[ "$note" != *"**Permission**: $label"* ]]; then
            fail "MODE_LABELS: $raw_mode → $label" "note: $note"
            all_ok=false
        fi
    done

    if $all_ok; then
        pass "all MODE_LABELS correctly transform permission modes"
    fi
}

test_multi_model_session() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt && git add x.txt && git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    # Build transcript manually to use different models per assistant turn
    local transcript="$TEST_DIR/transcript.jsonl"
    > "$transcript"
    printf '{"type":"user","message":{"content":"Do something"}}\n' >> "$transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{}}],"model":"claude-opus-4-6","usage":{"input_tokens":100,"output_tokens":50}}}\n' >> "$transcript"
    printf '{"type":"user","message":{"content":"Continue"}}\n' >> "$transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}],"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":50}}}\n' >> "$transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m test"}}]}}\n' >> "$transcript"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"claude-sonnet-4-6"* && "$note" == *"claude-opus-4-6"* ]]; then
        pass "multi-model session lists both models"
    else
        fail "multi-model session lists both models" "note: $note"
    fi
}

test_mcp_server_detection() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt && git add x.txt && git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Search my notes" \
        "tool:mcp__notion__search" \
        "tool:mcp__notion__get_page" \
        "tool:mcp__slack__post_message" \
        "tool:Read" \
        "commit:git commit -m test"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    local ok=true
    [[ "$note" == *"### MCP Servers"* ]] || ok=false
    [[ "$note" == *"notion"* ]] || ok=false
    [[ "$note" == *"slack"* ]] || ok=false

    if $ok; then
        pass "detects MCP servers from tool names"
    else
        fail "detects MCP servers from tool names" "note: $note"
    fi
}

test_v2_backward_compat() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt && git add x.txt && git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Do something" \
        "commit:git commit -m test"

    make_hook_input "$hash" "$transcript" "session-compat" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    local ok=true
    # v1 consumers expect these structural elements
    [[ "$note" == "## Claude Code Prompts"* ]] || ok=false
    [[ "$note" == *"**Session**:"* ]] || ok=false
    [[ "$note" == *"**Captured**:"* ]] || ok=false
    [[ "$note" == *"### Prompts"* ]] || ok=false
    [[ "$note" == *"**1.** Do something"* ]] || ok=false

    if $ok; then
        pass "v2 format is backward compatible with v1 structure"
    else
        fail "v2 format is backward compatible with v1 structure" "note: $note"
    fi
}


# ============================================================
# Plan-to-build recovery
# ============================================================

test_plan_to_build_recovers_parent_prompts() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt && git add x.txt && git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local parent_id="parent-sess-001"
    local build_id="build-sess-001"
    local parent_transcript="$TEST_DIR/$parent_id.jsonl"
    local build_transcript="$TEST_DIR/$build_id.jsonl"

    # Parent session: user's original prompts during planning
    printf '{"type":"user","sessionId":"%s","message":{"content":"Add dark mode to the app"}}\n' "$parent_id" > "$parent_transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}\n' >> "$parent_transcript"
    printf '{"type":"user","sessionId":"%s","message":{"content":"Make it toggle with a button in the header"}}\n' "$parent_id" >> "$parent_transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{}}]}}\n' >> "$parent_transcript"

    # Build session: interrupt record, plan record, build-phase prompt, commit
    printf '{"type":"user","sessionId":"%s","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}\n' "$parent_id" > "$build_transcript"
    printf '{"type":"user","sessionId":"%s","planContent":"# Dark Mode Plan","message":{"content":"Implement the following plan:\\n\\n# Dark Mode Plan"}}\n' "$build_id" >> "$build_transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{}}]}}\n' >> "$build_transcript"
    printf '{"type":"user","sessionId":"%s","message":{"content":"ok, please commit"}}\n' "$build_id" >> "$build_transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m test"}}]}}\n' >> "$build_transcript"

    make_hook_input "$hash" "$build_transcript" "$build_id" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    local ok=true
    # Parent prompts should be recovered
    [[ "$note" == *"Add dark mode to the app"* ]] || ok=false
    [[ "$note" == *"Make it toggle with a button in the header"* ]] || ok=false
    # Build-phase prompt should be included
    [[ "$note" == *"ok, please commit"* ]] || ok=false
    # Plan text should NOT appear as a prompt
    [[ "$note" != *"Implement the following plan"* ]] || ok=false
    # Parent session traceability comment
    [[ "$note" == *"$parent_id"* ]] || ok=false

    if $ok; then
        pass "plan-to-build recovers parent prompts"
    else
        fail "plan-to-build recovers parent prompts" "note: $note"
    fi
}

test_plan_to_build_no_parent_file() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt && git add x.txt && git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local parent_id="missing-parent-001"
    local build_id="build-sess-002"
    local build_transcript="$TEST_DIR/$build_id.jsonl"

    # Build session with reference to non-existent parent file
    printf '{"type":"user","sessionId":"%s","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}\n' "$parent_id" > "$build_transcript"
    printf '{"type":"user","sessionId":"%s","planContent":"# Some Plan","message":{"content":"Implement the following plan:\\n\\n# Some Plan"}}\n' "$build_id" >> "$build_transcript"
    printf '{"type":"user","sessionId":"%s","message":{"content":"ok, commit this"}}\n' "$build_id" >> "$build_transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m test"}}]}}\n' >> "$build_transcript"

    make_hook_input "$hash" "$build_transcript" "$build_id" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    local ok=true
    # Should still capture build-phase prompts (graceful fallback)
    [[ "$note" == *"ok, commit this"* ]] || ok=false
    # Note should still be created
    [[ "$note" == *"Claude Code Prompts"* ]] || ok=false

    if $ok; then
        pass "plan-to-build gracefully handles missing parent file"
    else
        fail "plan-to-build gracefully handles missing parent file" "note: $note"
    fi
}

test_plan_to_build_chained() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt && git add x.txt && git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local grandparent_id="grandparent-001"
    local parent_id="parent-sess-003"
    local build_id="build-sess-003"
    local grandparent_transcript="$TEST_DIR/$grandparent_id.jsonl"
    local parent_transcript="$TEST_DIR/$parent_id.jsonl"
    local build_transcript="$TEST_DIR/$build_id.jsonl"

    # Grandparent session
    printf '{"type":"user","sessionId":"%s","message":{"content":"This is the grandparent prompt"}}\n' "$grandparent_id" > "$grandparent_transcript"

    # Parent session (itself a build from grandparent)
    printf '{"type":"user","sessionId":"%s","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}\n' "$grandparent_id" > "$parent_transcript"
    printf '{"type":"user","sessionId":"%s","planContent":"# First Plan","message":{"content":"Implement the following plan:\\n\\n# First Plan"}}\n' "$parent_id" >> "$parent_transcript"
    printf '{"type":"user","sessionId":"%s","message":{"content":"Add dark mode to the app"}}\n' "$parent_id" >> "$parent_transcript"

    # Build session (build from parent)
    printf '{"type":"user","sessionId":"%s","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}\n' "$parent_id" > "$build_transcript"
    printf '{"type":"user","sessionId":"%s","planContent":"# Second Plan","message":{"content":"Implement the following plan:\\n\\n# Second Plan"}}\n' "$build_id" >> "$build_transcript"
    printf '{"type":"user","sessionId":"%s","message":{"content":"ok, commit"}}\n' "$build_id" >> "$build_transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m test"}}]}}\n' >> "$build_transcript"

    make_hook_input "$hash" "$build_transcript" "$build_id" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    local ok=true
    # Parent prompts recovered (one level back)
    [[ "$note" == *"Add dark mode to the app"* ]] || ok=false
    # Grandparent prompt NOT recovered (only one level)
    [[ "$note" != *"grandparent prompt"* ]] || ok=false
    # Build-phase prompt included
    [[ "$note" == *"ok, commit"* ]] || ok=false

    if $ok; then
        pass "plan-to-build traces back only one level"
    else
        fail "plan-to-build traces back only one level" "note: $note"
    fi
}


# ============================================================
# Edge cases
# ============================================================

test_capture_no_transcript() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt
    git add x.txt
    git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    # Hook input pointing to nonexistent transcript
    echo "{\"tool_input\":{\"command\":\"git commit -m test\"},\"tool_response\":\"[main ${hash}] test\\n 1 file changed\",\"transcript_path\":\"/nonexistent/path.jsonl\",\"session_id\":\"test\"}" \
        | bash "$HOOKS_DIR/capture-prompts.sh"

    local count
    count=$(git notes --ref=claude-prompt-trail list 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        pass "gracefully handles missing transcript"
    else
        fail "gracefully handles missing transcript" "found $count notes"
    fi
}

test_capture_empty_transcript() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt
    git add x.txt
    git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    # Empty transcript file
    local transcript="$TEST_DIR/empty.jsonl"
    > "$transcript"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local count
    count=$(git notes --ref=claude-prompt-trail list 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        pass "gracefully handles empty transcript"
    else
        fail "gracefully handles empty transcript" "found $count notes"
    fi
}

test_capture_malformed_json() {
    make_test_repo
    trap cleanup_test_repo RETURN

    # Garbage input that contains "git commit" (passes fast guard) but is invalid JSON
    echo 'this is not json but has git commit in it' \
        | bash "$HOOKS_DIR/capture-prompts.sh" || true

    local count
    count=$(git notes --ref=claude-prompt-trail list 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        pass "gracefully handles malformed JSON input"
    else
        fail "gracefully handles malformed JSON input" "found $count notes"
    fi
}

test_capture_long_prompt_verbatim() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt
    git add x.txt
    git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    # Create transcript with a very long prompt (3000+ chars)
    local transcript="$TEST_DIR/transcript.jsonl"
    local long_prompt
    long_prompt=$(python3 -c "print(' '.join('Fix the bug in line ' + str(i) + ' of the file.' for i in range(200)))" | head -c 3000)
    # Write manually to handle the long string
    printf '{"type":"user","message":{"content":"%s"}}\n' "$long_prompt" > "$transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m test"}}]}}\n' >> "$transcript"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"[truncated]"* ]]; then
        fail "long prompts are captured verbatim" "note was truncated"
    elif [[ "$note" == *"Fix the bug in line 0"* ]] && [[ ${#note} -gt 3000 ]]; then
        pass "long prompts are captured verbatim"
    else
        fail "long prompts are captured verbatim" "note length: ${#note}"
    fi
}

test_capture_image_placeholder() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt
    git add x.txt
    git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    # User message with mixed text and image content
    printf '{"type":"user","message":{"content":[{"type":"text","text":"Look at this screenshot"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBOR..."}}]}}\n' > "$transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m test"}}]}}\n' >> "$transcript"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"Look at this screenshot"* ]] && [[ "$note" == *"[image]"* ]]; then
        pass "image content replaced with [image] placeholder"
    else
        fail "image content replaced with [image] placeholder" "note: $note"
    fi
}


# ============================================================
# Secret redaction
# ============================================================

test_redact_anthropic_key() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt
    git add x.txt
    git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    # Build a fake Anthropic key dynamically to avoid triggering GitHub push protection
    local fake_key
    fake_key="sk-ant-api03-$(python3 -c "print('A' * 86)")-$(python3 -c "print('A' * 4)")AA"

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Here is my key ${fake_key} please use it" \
        "commit:git commit -m test"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"REDACTED"* && "$note" != *"sk-ant-api03"* ]]; then
        pass "redacts Anthropic API keys"
    else
        fail "redacts Anthropic API keys" "note: ${note:0:200}"
    fi
}

test_redact_github_token() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt
    git add x.txt
    git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Use this token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn for auth" \
        "commit:git commit -m test"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"REDACTED"* && "$note" != *"ghp_"* ]]; then
        pass "redacts GitHub tokens"
    else
        fail "redacts GitHub tokens" "note: ${note:0:200}"
    fi
}

test_redact_aws_key() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt
    git add x.txt
    git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:My AWS key is AKIAIOSFODNN7EXAMPLE" \
        "commit:git commit -m test"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"REDACTED"* && "$note" != *"AKIAIOSFODNN7"* ]]; then
        pass "redacts AWS access keys"
    else
        fail "redacts AWS access keys" "note: ${note:0:200}"
    fi
}

test_redact_generic_secret_assignment() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt
    git add x.txt
    git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Set api_key=super_secret_value_12345678 in the config" \
        "commit:git commit -m test"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"REDACTED"* && "$note" != *"super_secret"* ]]; then
        pass "redacts generic key=value secrets"
    else
        fail "redacts generic key=value secrets" "note: ${note:0:200}"
    fi
}

test_redact_preserves_normal_text() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt
    git add x.txt
    git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Add a login form with username and password fields" \
        "commit:git commit -m test"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"login form with username and password fields"* && "$note" != *"REDACTED"* ]]; then
        pass "preserves normal text (no false positives)"
    else
        fail "preserves normal text" "note: ${note:0:200}"
    fi
}


# ============================================================
# Squash merge note preservation
# ============================================================

# Build PostToolUse hook JSON for a squash merge command.
# Usage: make_squash_merge_hook_input <branch>
make_squash_merge_hook_input() {
    local branch="$1"
    cat <<EOF
{"tool_input":{"command":"git merge --squash ${branch}"},"tool_response":"Squash commit -- not updating HEAD\\nAutomatic merge went well; stopped before committing as requested."}
EOF
}

test_squash_merge_copies_notes() {
    make_test_repo
    trap cleanup_test_repo RETURN

    # Create a feature branch with 2 commits, each with a note
    git checkout -q -b feature
    echo "a" > a.txt
    git add a.txt
    git commit -q -m "feature commit 1"
    local hash1
    hash1=$(git rev-parse HEAD)
    git notes --ref=claude-prompt-trail add -m "## Claude Code Prompts

**Session**: sess-1

### Prompts

**1.** Add file a" "$hash1"

    echo "b" > b.txt
    git add b.txt
    git commit -q -m "feature commit 2"
    local hash2
    hash2=$(git rev-parse HEAD)
    git notes --ref=claude-prompt-trail add -m "## Claude Code Prompts

**Session**: sess-2

### Prompts

**1.** Add file b" "$hash2"

    # Switch back to main, squash merge
    git checkout -q main
    git merge --squash feature

    # Phase 1: fire the hook for the squash merge command
    make_squash_merge_hook_input "feature" | bash "$HOOKS_DIR/capture-prompts.sh"

    # Phase 2: commit the squash merge
    git commit -q -m "squash merge feature"
    local squash_hash
    squash_hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Squash merge the feature branch" \
        "commit:git commit -m squash merge feature"

    make_hook_input "$squash_hash" "$transcript" "squash-session" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    local ok=true
    # Should have the normal commit note
    [[ "$note" == *"Claude Code Prompts"* ]] || ok=false
    [[ "$note" == *"Squash merge the feature branch"* ]] || ok=false
    # Should have the squashed commit prompts section
    [[ "$note" == *"### Squashed Commit Prompts"* ]] || ok=false
    # Should contain notes from both source commits
    [[ "$note" == *"Add file a"* ]] || ok=false
    [[ "$note" == *"Add file b"* ]] || ok=false

    if $ok; then
        pass "squash merge copies notes from source commits"
    else
        fail "squash merge copies notes from source commits" "note: $note"
    fi
}

test_squash_merge_no_notes_no_section() {
    make_test_repo
    trap cleanup_test_repo RETURN

    # Create a feature branch with commits but NO notes
    git checkout -q -b feature-no-notes
    echo "c" > c.txt
    git add c.txt
    git commit -q -m "feature commit without notes"

    # Switch back to main, squash merge
    git checkout -q main
    git merge --squash feature-no-notes

    # Phase 1: fire the hook for the squash merge command
    make_squash_merge_hook_input "feature-no-notes" | bash "$HOOKS_DIR/capture-prompts.sh"

    # Phase 2: commit the squash merge
    git commit -q -m "squash merge no-notes"
    local squash_hash
    squash_hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Squash merge the feature branch" \
        "commit:git commit -m squash merge no-notes"

    make_hook_input "$squash_hash" "$transcript" "squash-session-2" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    local ok=true
    # Should have the normal commit note
    [[ "$note" == *"Claude Code Prompts"* ]] || ok=false
    # Should NOT have the squashed section
    [[ "$note" != *"Squashed Commit Prompts"* ]] || ok=false

    if $ok; then
        pass "squash merge without notes has no Squashed section"
    else
        fail "squash merge without notes has no Squashed section" "note: $note"
    fi
}


# ============================================================
# E2E tests (optional, require ANTHROPIC_API_KEY + claude CLI)
# ============================================================

# Guard: skip if claude CLI is missing.
# Usage: require_claude "test name" || return 0
require_claude() {
    if ! command -v claude >/dev/null 2>&1; then
        skip "$1" "claude CLI not installed"
        return 1
    fi
    return 0
}

# Guard: skip if prerequisites for API-calling E2E tests are missing.
# Usage: require_e2e "test name" || return 0
require_e2e() {
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        skip "$1" "ANTHROPIC_API_KEY not set"
        return 1
    fi
    require_claude "$1"
}

# Helper: ask Claude to create a file and commit it.
# Usage: claude_commit <filename> <commit-msg> [extra-flags...]
# Pass --plugin-dir "$PROJECT_DIR" to load the plugin for this session.
# Returns 0 if commit was created, 1 otherwise. Sets CLAUDE_OUTPUT.
# Retries once on failure to handle flaky LLM responses.
claude_commit() {
    local filename="$1"
    local msg="$2"
    shift 2
    local attempt
    for attempt in 1 2; do
        CLAUDE_OUTPUT=$(claude -p \
            "Create a file called ${filename} containing 'test content' and commit it with message '${msg}'. Do not push." \
            --model haiku \
            --dangerously-skip-permissions \
            "$@" \
            2>&1) || true

        local log
        log=$(git log --oneline -5 2>/dev/null || echo "")
        if [[ "$log" == *"$msg"* ]]; then
            return 0
        fi
        [[ $attempt -eq 1 ]] && echo "  (retry claude_commit after attempt $attempt)" >&2
    done
    return 1
}

test_e2e_plugin_validate() {
    require_claude "E2E plugin validate" || return 0

    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin
    git add .claude-plugin/ hooks/ .claude/
    git commit -q -m "add plugin"

    local output
    output=$(claude plugin validate . 2>&1)
    local rc=$?
    if [[ $rc -eq 0 && "$output" == *"Validation passed"* ]]; then
        pass "E2E: plugin validate passes"
    else
        fail "E2E: plugin validate passes" "rc=$rc output: ${output:0:200}"
    fi
}

test_e2e_basic_commit() {
    require_e2e "E2E basic commit" || return 0

    make_test_repo
    trap cleanup_test_repo RETURN
    bash "$HOOKS_DIR/setup-notes.sh"

    if claude_commit "hello.txt" "Add hello.txt" --plugin-dir "$PROJECT_DIR"; then
        local note
        note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
        if [[ "$note" == *"Claude Code Prompts"* ]]; then
            pass "E2E: commit with note attached"
        else
            fail "E2E: commit with note attached" "commit exists but no note"
            return
        fi
        # Check v2 format fields in the same note (avoids a second Claude invocation)
        local v2_ok=true
        [[ "$note" == *"format:v2"* ]] || { fail "E2E: note has v2 marker" "missing format:v2"; v2_ok=false; }
        [[ "$note" == *"**Session**:"* ]] || { fail "E2E: note has Session field" "missing Session"; v2_ok=false; }
        [[ "$note" == *"**Captured**:"* ]] || { fail "E2E: note has Captured field" "missing Captured"; v2_ok=false; }
        [[ "$note" == *"### Prompts"* ]] || { fail "E2E: note has Prompts section" "missing Prompts"; v2_ok=false; }
        if $v2_ok; then
            pass "E2E: note has v2 format fields"
        fi
    else
        fail "E2E: Claude created commit" "no matching commit. Output: ${CLAUDE_OUTPUT:0:200}"
    fi
}

test_e2e_worktree_commit() {
    require_e2e "E2E worktree commit" || return 0

    make_test_repo
    trap cleanup_test_repo RETURN
    bash "$HOOKS_DIR/setup-notes.sh"

    mkdir -p .claude/worktrees
    git worktree add -q .claude/worktrees/test-task -b worktree-test
    cd .claude/worktrees/test-task

    if claude_commit "wt.txt" "Add wt.txt" --plugin-dir "$PROJECT_DIR"; then
        local note
        note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
        if [[ "$note" == *"Claude Code Prompts"* ]]; then
            pass "E2E: worktree commit with note"

            cd "$TEST_DIR"
            note=$(git notes --ref=claude-prompt-trail show worktree-test 2>/dev/null || echo "")
            if [[ "$note" == *"Claude Code Prompts"* ]]; then
                pass "E2E: worktree note visible from main"
            else
                fail "E2E: worktree note visible from main" "not visible"
            fi
        else
            fail "E2E: worktree commit with note" "commit exists but no note"
        fi
    else
        fail "E2E: worktree commit created" "no matching commit. Output: ${CLAUDE_OUTPUT:0:200}"
    fi
}

test_e2e_no_plugin_dir_skips_capture() {
    require_e2e "E2E no --plugin-dir skips capture" || return 0

    make_test_repo
    trap cleanup_test_repo RETURN
    bash "$HOOKS_DIR/setup-notes.sh"

    # First commit with plugin loaded — should get a note
    if ! claude_commit "with-plugin.txt" "Add with-plugin" --plugin-dir "$PROJECT_DIR"; then
        fail "E2E: commit with --plugin-dir" "no commit. Output: ${CLAUDE_OUTPUT:0:200}"
        return
    fi
    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" != *"Claude Code Prompts"* ]]; then
        fail "E2E: note attached with --plugin-dir" "no note on commit"
        return
    fi
    pass "E2E: note attached with --plugin-dir"

    # Second commit WITHOUT --plugin-dir — should NOT get a note
    if ! claude_commit "no-plugin.txt" "Add no-plugin"; then
        fail "E2E: commit without --plugin-dir" "no commit. Output: ${CLAUDE_OUTPUT:0:200}"
        return
    fi
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ -z "$note" ]]; then
        pass "E2E: no note without --plugin-dir"
    else
        fail "E2E: no note without --plugin-dir" "note was attached: ${note:0:100}"
    fi
}

test_e2e_plugin_dir_resumes_capture() {
    require_e2e "E2E --plugin-dir resumes capture" || return 0

    make_test_repo
    trap cleanup_test_repo RETURN
    bash "$HOOKS_DIR/setup-notes.sh"

    # Commit without --plugin-dir — no note expected
    if ! claude_commit "no-plugin.txt" "Add no-plugin"; then
        fail "E2E: commit without --plugin-dir" "no commit. Output: ${CLAUDE_OUTPUT:0:200}"
        return
    fi
    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ -n "$note" ]]; then
        fail "E2E: no note without --plugin-dir" "note was attached: ${note:0:100}"
        return
    fi
    pass "E2E: no note without --plugin-dir"

    # Commit with --plugin-dir — note expected
    if ! claude_commit "with-plugin.txt" "Add with-plugin" --plugin-dir "$PROJECT_DIR"; then
        fail "E2E: commit with --plugin-dir" "no commit. Output: ${CLAUDE_OUTPUT:0:200}"
        return
    fi
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"Claude Code Prompts"* ]]; then
        pass "E2E: note resumes with --plugin-dir"
    else
        fail "E2E: note resumes with --plugin-dir" "no note with --plugin-dir"
    fi
}

test_e2e_clean_repo_no_capture() {
    require_e2e "E2E clean repo no capture" || return 0

    make_test_repo
    trap cleanup_test_repo RETURN

    # Commit in clean repo (no plugin) — no note expected
    if ! claude_commit "clean-repo.txt" "Add clean-repo"; then
        fail "E2E: commit in clean repo" "no commit. Output: ${CLAUDE_OUTPUT:0:200}"
        return
    fi
    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ -z "$note" ]]; then
        pass "E2E: no note in clean repo"
    else
        fail "E2E: no note in clean repo" "note was attached: ${note:0:100}"
    fi
}

test_e2e_add_plugin_dir_resumes_capture() {
    require_e2e "E2E add --plugin-dir resumes capture" || return 0

    make_test_repo
    trap cleanup_test_repo RETURN

    # Start without --plugin-dir
    if ! claude_commit "no-plugin.txt" "Add no-plugin"; then
        fail "E2E: commit without --plugin-dir" "no commit. Output: ${CLAUDE_OUTPUT:0:200}"
        return
    fi
    local note
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ -n "$note" ]]; then
        fail "E2E: no note without --plugin-dir" "note was attached: ${note:0:100}"
        return
    fi
    pass "E2E: no note without --plugin-dir"

    # Now add --plugin-dir
    bash "$HOOKS_DIR/setup-notes.sh"

    if ! claude_commit "with-plugin.txt" "Add with-plugin" --plugin-dir "$PROJECT_DIR"; then
        fail "E2E: commit with --plugin-dir" "no commit. Output: ${CLAUDE_OUTPUT:0:200}"
        return
    fi
    note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"Claude Code Prompts"* ]]; then
        pass "E2E: note attached with --plugin-dir"
    else
        fail "E2E: note attached with --plugin-dir" "no note"
    fi
}

test_e2e_plugin_dir_flag() {
    require_e2e "E2E --plugin-dir flag" || return 0

    make_test_repo
    trap cleanup_test_repo RETURN

    # Don't install plugin into the repo — load it via --plugin-dir instead
    bash "$HOOKS_DIR/setup-notes.sh"

    CLAUDE_OUTPUT=$(claude -p \
        "Create a file called plugdir.txt containing 'plugin-dir test' and commit it with message 'Add plugdir.txt'. Do not push." \
        --model haiku \
        --plugin-dir "$PROJECT_DIR" \
        --permission-mode acceptEdits \
        --allowedTools 'Bash(git:*)' 'Bash(echo:*)' 'Write' \
        2>&1) || true

    local log
    log=$(git log --oneline -5 2>/dev/null || echo "")
    if [[ "$log" == *"plugdir"* ]]; then
        local note
        note=$(git notes --ref=claude-prompt-trail show HEAD 2>/dev/null || echo "")
        if [[ "$note" == *"Claude Code Prompts"* ]]; then
            pass "E2E: --plugin-dir loads plugin and attaches note"
        else
            fail "E2E: --plugin-dir attaches note" "commit exists but no note"
        fi
    else
        fail "E2E: --plugin-dir commit" "no matching commit. Output: ${CLAUDE_OUTPUT:0:200}"
    fi
}

test_e2e_multiple_commits_distinct_notes() {
    require_e2e "E2E multiple commits distinct notes" || return 0

    make_test_repo
    trap cleanup_test_repo RETURN
    bash "$HOOKS_DIR/setup-notes.sh"

    # Ask Claude to create two files and make two separate commits
    CLAUDE_OUTPUT=$(claude -p \
        "Do these two steps in order: (1) Create file first.txt containing 'first' and commit with message 'Add first.txt'. (2) Create file second.txt containing 'second' and commit with message 'Add second.txt'. Do not push." \
        --model haiku \
        --plugin-dir "$PROJECT_DIR" \
        --permission-mode acceptEdits \
        --allowedTools 'Bash(git:*)' 'Bash(echo:*)' 'Write' \
        2>&1) || true

    local log
    log=$(git log --oneline -10 2>/dev/null || echo "")

    if [[ "$log" != *"first"* ]]; then
        fail "E2E: first commit created" "no first commit. Output: ${CLAUDE_OUTPUT:0:200}"
        return
    fi
    if [[ "$log" != *"second"* ]]; then
        fail "E2E: second commit created" "no second commit. Output: ${CLAUDE_OUTPUT:0:200}"
        return
    fi

    local note_count
    note_count=$(git notes --ref=claude-prompt-trail list 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$note_count" -ge 2 ]]; then
        pass "E2E: multiple commits each get a note ($note_count notes)"
    else
        fail "E2E: multiple commits each get a note" "only $note_count note(s)"
    fi
}

test_e2e_session_start_configures_git() {
    require_e2e "E2E SessionStart configures git" || return 0

    make_test_repo
    trap cleanup_test_repo RETURN
    git remote add origin "https://example.com/test.git"

    # Don't run setup-notes.sh manually — let the SessionStart hook do it
    # Run a trivial Claude session that triggers SessionStart
    claude -p "Say hello" --model haiku --plugin-dir "$PROJECT_DIR" --permission-mode acceptEdits --allowedTools 'Bash(echo *)' >/dev/null 2>&1 || true

    local display_ref
    display_ref=$(git config --local --get notes.displayRef 2>/dev/null || echo "")
    if [[ "$display_ref" == "refs/notes/claude-prompt-trail" ]]; then
        pass "E2E: SessionStart hook configures notes.displayRef"
    else
        fail "E2E: SessionStart hook configures notes.displayRef" "got '$display_ref'"
    fi

    local fetch
    fetch=$(git config --local --get-all remote.origin.fetch 2>/dev/null | grep "claude-prompt-trail" || echo "")
    if [[ "$fetch" == "+refs/notes/claude-prompt-trail:refs/notes/claude-prompt-trail" ]]; then
        pass "E2E: SessionStart hook configures fetch refspec"
    else
        fail "E2E: SessionStart hook configures fetch refspec" "got '$fetch'"
    fi
}


# ============================================================
# Runner
# ============================================================

main() {
    printf "\033[1mclaude-prompt-trail test suite\033[0m\n"

    section "setup-notes.sh"
    test_setup_notes_configures_displayref
    test_setup_notes_configures_fetch_refspec
    test_setup_notes_configures_rewrite_ref
    test_setup_notes_configures_rewrite_mode
    test_setup_notes_idempotent
    test_setup_notes_cleans_push_refspec
    test_setup_notes_no_remote
    test_notes_survive_rebase
    test_notes_survive_amend

    section "capture-prompts.sh — basics"
    test_capture_attaches_note
    test_capture_note_format
    test_capture_multiple_prompts
    test_capture_ignores_non_commits
    test_capture_ignores_failed_commits
    test_capture_amend_overwrites_note
    test_capture_branch_with_slashes
    test_capture_detached_head
    test_capture_root_commit

    section "capture-prompts.sh — multi-commit sessions"
    test_multi_commit_session

    section "parallel sessions"
    test_parallel_sessions_no_conflict
    test_parallel_notes_total_count

    section "plugin structure"
    test_plugin_json_valid
    test_hooks_json_valid
    test_settings_enables_plugin

    section "worktree compatibility"
    test_plugin_present_in_worktree
    test_setup_notes_in_worktree
    test_capture_in_worktree
    test_worktree_note_visible_from_main
    test_notes_shared_between_worktrees

    section "v2 format enrichment"
    test_note_has_v2_format_marker
    test_note_includes_model
    test_note_includes_client_version
    test_note_includes_branch
    test_note_includes_stats
    test_note_includes_tools
    test_note_includes_permission
    test_note_permission_mode_labels
    test_multi_model_session
    test_mcp_server_detection
    test_v2_backward_compat

    section "plan-to-build recovery"
    test_plan_to_build_recovers_parent_prompts
    test_plan_to_build_no_parent_file
    test_plan_to_build_chained

    section "edge cases"
    test_capture_no_transcript
    test_capture_empty_transcript
    test_capture_malformed_json
    test_capture_long_prompt_verbatim
    test_capture_image_placeholder

    section "secret redaction"
    test_redact_anthropic_key
    test_redact_github_token
    test_redact_aws_key
    test_redact_generic_secret_assignment
    test_redact_preserves_normal_text

    section "squash merge note preservation"
    test_squash_merge_copies_notes
    test_squash_merge_no_notes_no_section

    section "E2E with Claude (optional)"
    test_e2e_plugin_validate
    test_e2e_basic_commit
    test_e2e_worktree_commit
    test_e2e_no_plugin_dir_skips_capture
    test_e2e_plugin_dir_resumes_capture
    test_e2e_clean_repo_no_capture
    test_e2e_add_plugin_dir_resumes_capture
    test_e2e_plugin_dir_flag
    test_e2e_multiple_commits_distinct_notes
    test_e2e_session_start_configures_git

    # Summary
    printf "\n\033[1mResults: %d passed, %d failed, %d skipped\033[0m\n" "$PASSED" "$FAILED" "$SKIPPED"
    if [[ "$FAILED" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
