#!/bin/bash
###############################################################################
# Post-Validation Script — Oracle RAC Node Checks via Ansible (Ansible 2.9)
# Usage:   ./post_validation.sh <group_name>
# Example: ./post_validation.sh rac_nodes
#
# - No vault password needed
# - Runs every check even if an earlier one fails
# - Continues past missing users / paths / fstab entries and reports them
# - Blank line between each server's output
# - Exit code: 0 = all passed, 1 = at least one check failed
###############################################################################

GROUP_NAME="${1:-}"

if [ -z "$GROUP_NAME" ]; then
  echo "Usage: $0 <group_name>"
  echo "Example: $0 rac_nodes"
  exit 1
fi

# --- Suppress Ansible warnings (Ansible 2.9) ---
export ANSIBLE_INTERPRETER_PYTHON=auto_legacy_silent
export ANSIBLE_DEPRECATION_WARNINGS=False
export ANSIBLE_COMMAND_WARNINGS=False
export ANSIBLE_SYSTEM_WARNINGS=False
export ANSIBLE_LOCALHOST_WARNING=False
export ANSIBLE_INVENTORY_UNPARSED_WARNING=False

PASSED=()
FAILED=()
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

# --- Runs one ad-hoc check; records result; never aborts the script ---
run_check() {
  local desc="$1"
  local cmd="$2"

  echo -e "\n--- $desc ---"
  ansible "$GROUP_NAME" -m shell -a "$cmd" 2>&1 \
    | sed -E 's/non-zero return code$//; s/^([^ ]+ \| (CHANGED|SUCCESS|FAILED|UNREACHABLE)[^>]*>>)/\n\1/' \
    | sed '1{/^$/d}' \
    | tee -a "$OUT"
  local rc=${PIPESTATUS[0]}      # exit code of ansible, not tee

  if [ "$rc" -eq 0 ]; then
    PASSED+=("$desc")
  else
    FAILED+=("$desc")
    echo ">>> FAILED (continuing with next check): $desc"
  fi
}

# ---------------- Remote check scripts ----------------
read -r -d '' CHK_USERS <<'REMOTE_EOF'
rc=0
for u in oracrs oradb gcagent; do
  if id "$u" >/dev/null 2>&1; then
    echo "[OK]      $(hostname -s): $u exists -> $(id "$u")"
  else
    echo "[MISSING] $(hostname -s): user $u does not exist"
    rc=1
  fi
done
exit $rc
REMOTE_EOF

read -r -d '' CHK_AGING <<'REMOTE_EOF'
rc=0
for u in oracrs oradb gcagent; do
  if id "$u" >/dev/null 2>&1; then
    echo "--- $(hostname -s): $u ---"
    chage -l "$u" || rc=1
  else
    echo "[MISSING] $(hostname -s): user $u does not exist (aging check skipped)"
    rc=1
  fi
done
exit $rc
REMOTE_EOF

read -r -d '' CHK_MOUNTS <<'REMOTE_EOF'
rc=0
for p in /d01 /d02; do
  if [ ! -e "$p" ]; then
    echo "[MISSING] $(hostname -s): $p does not exist"
    rc=1
  elif ! mountpoint -q "$p"; then
    echo "[MISSING] $(hostname -s): $p exists but is NOT a mounted filesystem"
    rc=1
  else
    df -hT "$p"
  fi
done
exit $rc
REMOTE_EOF

read -r -d '' CHK_DIRS <<'REMOTE_EOF'
rc=0
for p in /d01 /d02; do
  if [ -d "$p" ]; then
    ls -ld "$p"
  else
    echo "[MISSING] $(hostname -s): directory $p does not exist"
    rc=1
  fi
done
exit $rc
REMOTE_EOF

read -r -d '' CHK_FSTAB <<'REMOTE_EOF'
rc=0
for p in /d01 /d02; do
  line=$(awk -v p="$p" '$0 !~ /^[[:space:]]*#/ && $2 == p' /etc/fstab)
  if [ -n "$line" ]; then
    echo "[OK]      $(hostname -s): fstab entry found -> $line"
  else
    echo "[MISSING] $(hostname -s): no fstab entry for $p"
    rc=1
  fi
done
exit $rc
REMOTE_EOF

# ---------------- Run checks ----------------
echo "=================================================================="
echo " Running post-validation checks against group: $GROUP_NAME"
echo "=================================================================="

run_check "[1/6] User accounts (oracrs, oradb, gcagent)"        "$CHK_USERS"
run_check "[2/6] Password aging policy"                         "$CHK_AGING"
run_check "[3/6] Filesystem mounts (/d01, /d02)"                "$CHK_MOUNTS"
run_check "[4/6] Directory ownership/permissions (/d01, /d02)"  "$CHK_DIRS"
run_check "[5/6] Installed Oracle RPM packages"                 "rpm -qa | grep oracle"
run_check "[6/6] /etc/fstab entries (/d01, /d02)"               "$CHK_FSTAB"

# ---------------- Summary ----------------
echo -e "\n=================================================================="
echo " SUMMARY for group: $GROUP_NAME"
echo "=================================================================="
echo "PASSED: ${#PASSED[@]}"
for c in "${PASSED[@]}"; do echo "  [OK]   $c"; done
echo "FAILED: ${#FAILED[@]}"
for c in "${FAILED[@]}"; do echo "  [FAIL] $c"; done
echo "MISSING ITEMS:"
if grep -q '\[MISSING\]' "$OUT"; then
  grep -h '\[MISSING\]' "$OUT" | sort -u | sed 's/^/  /'
else
  echo "  none"
fi
echo "=================================================================="

# Non-zero exit if anything failed (useful for CI/automation)
[ ${#FAILED[@]} -eq 0 ] || exit 1
