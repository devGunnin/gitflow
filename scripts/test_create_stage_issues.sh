#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

STATE_FILE="$TMP_DIR/issues.db"
COUNTER_FILE="$TMP_DIR/counter"
CREATE_LOG="$TMP_DIR/create.log"

cat >"$STATE_FILE" <<'EOF_STATE'
1|open|https://example.test/1|[Stage 1] Bootstrap plugin architecture and async command runtime
2|open|https://example.test/2|[Stage 3] Add GitHub integration layer and single-stroke sync (legacy)
3|closed|https://example.test/3|[Stage 4] Build issue management UI (create, edit, label, comment)
EOF_STATE

echo "3" >"$COUNTER_FILE"
: >"$CREATE_LOG"

cat >"$TMP_DIR/gh" <<'EOF_GH'
#!/usr/bin/env bash
set -euo pipefail

state_file="${FAKE_GH_STATE:?}"
counter_file="${FAKE_GH_COUNTER:?}"
create_log="${FAKE_GH_CREATE_LOG:?}"

if [ "${1:-}" != "issue" ]; then
  echo "unsupported command" >&2
  exit 2
fi
shift

case "${1:-}" in
  list)
    shift
    query=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --search)
          query="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done

    requested_title="${query% in:title}"
    requested_title="${requested_title#\"}"
    requested_title="${requested_title%\"}"

    while IFS='|' read -r number state url title; do
      [ -z "$number" ] && continue
      case "$title" in
        *"$requested_title"*)
          printf '%s\t%s\t%s\t%s\n' "$number" "$state" "$url" "$title"
          ;;
      esac
    done <"$state_file"
    ;;
  create)
    shift
    title=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --title)
          title="$2"
          shift 2
          ;;
        --body-file)
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done

    next_number=$(( $(cat "$counter_file") + 1 ))
    echo "$next_number" >"$counter_file"
    url="https://example.test/$next_number"
    printf '%s|open|%s|%s\n' "$next_number" "$url" "$title" >>"$state_file"
    printf '%s\n' "$title" >>"$create_log"
    printf '%s\n' "$url"
    ;;
  *)
    echo "unsupported issue subcommand" >&2
    exit 2
    ;;
esac
EOF_GH
chmod +x "$TMP_DIR/gh"

assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [ "$expected" != "$actual" ]; then
    echo "assertion failed: $message" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
}

assert_contains() {
  local needle="$1"
  local haystack_file="$2"
  local message="$3"

  if ! grep -F -q "$needle" "$haystack_file"; then
    echo "assertion failed: $message" >&2
    exit 1
  fi
}

assert_not_contains() {
  local needle="$1"
  local haystack_file="$2"
  local message="$3"

  if grep -F -q "$needle" "$haystack_file"; then
    echo "assertion failed: $message" >&2
    exit 1
  fi
}

export FAKE_GH_STATE="$STATE_FILE"
export FAKE_GH_COUNTER="$COUNTER_FILE"
export FAKE_GH_CREATE_LOG="$CREATE_LOG"
export PATH="$TMP_DIR:$PATH"

run_log="$TMP_DIR/run.log"
bash "$ROOT_DIR/scripts/create_stage_issues.sh" "devGunnin/gitflow" >"$run_log"

created_count=$(wc -l <"$CREATE_LOG" | tr -d ' ')
assert_equals "6" "$created_count" "should create only missing stage issues"

assert_not_contains "[Stage 1] Bootstrap plugin architecture and async command runtime" "$CREATE_LOG" "should skip exact open duplicate"
assert_not_contains "[Stage 4] Build issue management UI (create, edit, label, comment)" "$CREATE_LOG" "should skip exact closed duplicate"
assert_contains "[Stage 3] Add GitHub integration layer and single-stroke sync" "$CREATE_LOG" "should create exact title when only fuzzy match exists"
assert_contains "created=6, skipped_existing=2" "$run_log" "summary should include created/skipped counts"

echo "create_stage_issues duplicate guard test passed"
