#!/usr/bin/env bash
# Chapter 4 lab: every recovery scenario in the chapter, replayed against a
# throwaway bare "origin". Exits non-zero if any documented behavior changes.
set -uo pipefail

LAB="${LAB_DIR:-${TMPDIR:-/tmp}/resnav-ch04}"
rm -rf "$LAB"; mkdir -p "$LAB"; cd "$LAB" || exit 1

cat > "$LAB/gitconfig" <<'EOF'
[user]
	name = Alice
	email = alice@example.com
[init]
	defaultBranch = main
[core]
	autocrlf = false
[advice]
	detachedHead = false
	skippedCherryPicks = false
[pull]
	ff = only
EOF
export GIT_CONFIG_GLOBAL="$LAB/gitconfig" GIT_CONFIG_NOSYSTEM=1
export GIT_EDITOR=true LANGUAGE=en LC_ALL=C
export GIT_AUTHOR_DATE="2026-01-05T10:00:00+0800" GIT_COMMITTER_DATE="2026-01-05T10:00:00+0800"

FAILED=0
section() { printf '\n========== %s ==========\n' "$*"; }
show() { printf '$ %s\n' "$*"; "$@" 2>&1; printf '[exit=%s]\n' "$?"; }
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then printf 'PASS  %s\n' "$desc"
  else printf 'FAIL  %s\n' "$desc"; FAILED=1; fi
}

git init -q --bare origin.git
git clone -q "$LAB/origin.git" alice 2>/dev/null
cd "$LAB/alice"
printf 'title,url,category\nGitHub Docs,https://docs.github.com/,GitHub\n' > resources.csv
printf '# resource-nav\n\nA curated list of learning resources.\n' > README.md
git add . && git commit -qm "chore: initial catalog"
printf 'Python Docs,https://docs.python.org/3/,Python\n' >> resources.csv
git commit -qam "feat: add Python docs"
git push -q origin main

# --------------------------------------------------------------------------
section "4.3 state snapshot"
printf 'Git Book,https://git-scm.com/book,Git\n' >> resources.csv
git add resources.csv
printf '\nSee CONTRIBUTING.md before opening a PR.\n' >> README.md
printf 'scratch\n' > notes.txt
show git status --short --branch
check "status shows staged, unstaged and untracked" \
  bash -c '[ "$(git status --porcelain)" = "$(printf " M README.md\nM  resources.csv\n?? notes.txt")" ]'

# --------------------------------------------------------------------------
section "4.4 restore"
show git restore README.md
show git restore --staged resources.csv
show git status --short
check "restore --staged keeps the worktree edit" bash -c 'git diff --quiet resources.csv; [ $? -eq 1 ]'
show git restore resources.csv
rm notes.txt
show git restore --source=HEAD~1 resources.csv
show git diff --stat
check "restore --source rolls one file back to HEAD~1" \
  bash -c '[ "$(wc -l < resources.csv)" -eq 2 ]'
git restore resources.csv

section "4.4 fsck: content that was staged once is still in the object store"
printf 'Pro Git (zh),https://git-scm.com/book/zh/v2,Git\n' >> resources.csv
git add resources.csv
git restore --staged resources.csv && git restore resources.csv
show git fsck --lost-found
show bash -c 'grep -l "Pro Git" .git/lost-found/other/*'
BLOB=$(basename "$(grep -l 'Pro Git' .git/lost-found/other/* | head -n1)")
show git show "$BLOB"
check "lost staged content recovered from dangling blob" \
  bash -c "git show $BLOB | grep -q 'Pro Git (zh)'"
rm -rf .git/lost-found

# --------------------------------------------------------------------------
section "4.5 stash structure"
printf 'MDN,https://developer.mozilla.org/,Web\n' >> resources.csv
printf 'draft\n' > TODO.md
show git stash push -m "wip: mdn"
show git status --short
check "plain stash leaves untracked file behind" test -f TODO.md
git stash pop -q
show git stash push -u -m "wip: mdn + todo"
show git status --short
show git rev-list --parents -n 1 'stash@{0}'
check "stash -u commit has three parents" \
  bash -c '[ "$(git rev-list --parents -n 1 "stash@{0}" | wc -w)" -eq 4 ]'
STASH_SHA=$(git rev-parse 'stash@{0}')
show git stash drop
show git stash list
show bash -c "git fsck --unreachable --no-reflogs 2>/dev/null | grep commit"
check "dropped stash commit is unreachable but present" \
  bash -c "git fsck --unreachable --no-reflogs 2>/dev/null | grep -q $STASH_SHA"
show git stash apply "$STASH_SHA"
check "dropped stash re-applied (tracked + untracked)" \
  bash -c 'grep -q MDN resources.csv && test -f TODO.md'
git restore resources.csv; rm -f TODO.md

section "4.5 a conflicting pop keeps the stash"
printf 'Stash side,https://example.com/stash,Misc\n' >> resources.csv
git stash push -q -m "wip: stash side"
printf 'Commit side,https://example.com/commit,Misc\n' >> resources.csv
git commit -qam "feat: commit side"
show git stash pop
show git stash list
check "stash entry kept after conflicting pop" \
  bash -c '[ "$(git stash list | wc -l)" -eq 1 ]'
git reset -q --hard origin/main; git stash drop -q

# --------------------------------------------------------------------------
section "4.6 reset modes"
printf 'Rust Book,https://doc.rust-lang.org/book/,Rust\n' >> resources.csv
git commit -qam "feat: add Rust book"
git branch backup/before-reset
for mode in soft mixed hard; do
  git reset -q --hard backup/before-reset
  printf -- '--- reset --%s HEAD~1\n' "$mode"
  git reset -q --"$mode" HEAD~1
  printf 'HEAD -> %s\n' "$(git log -1 --format=%s)"
  git status --short; printf '(end of status)\n'
done
check "after --hard the Rust line is gone from the worktree" bash -c '! grep -q Rust resources.csv'
show git reset --hard ORIG_HEAD
check "ORIG_HEAD restores the commit removed by reset" \
  bash -c '[ "$(git log -1 --format=%s)" = "feat: add Rust book" ]'

section "4.6 reset --keep refuses to destroy local edits"
printf 'local edit\n' >> resources.csv
show git reset --keep HEAD~1
check "reset --keep aborted, commit still there" \
  bash -c '[ "$(git log -1 --format=%s)" = "feat: add Rust book" ]'
check "reset --keep aborted, local edit still there" grep -q 'local edit' resources.csv
printf 'unrelated\n' >> README.md
git restore resources.csv
show git reset --keep HEAD~1
check "reset --keep moved HEAD and kept unrelated edit" \
  bash -c 'grep -q unrelated README.md && [ "$(git log -1 --format=%s)" = "feat: add Python docs" ]'
git restore README.md; git reset -q --hard backup/before-reset; git branch -q -D backup/before-reset
git reset -q --hard origin/main

# --------------------------------------------------------------------------
section "4.7 reflog: recover a deleted branch"
git switch -q -c feature/link-check
printf 'def check(url):\n    return url.startswith("https://")\n' > linkcheck.py
git add linkcheck.py && git commit -qm "feat: add link checker skeleton"
LOST=$(git rev-parse HEAD)
git switch -q main
show git branch -d feature/link-check
show git branch -D feature/link-check
show git reflog show feature/link-check
show git reflog -n 4
FOUND=$(git reflog --format='%H %gs' | awk '/checkout: moving from feature\/link-check to main/ {getline; print $1; exit}')
[ -n "$FOUND" ] || FOUND=$(git rev-parse 'HEAD@{1}')
show git branch feature/link-check "$FOUND"
check "deleted branch restored from HEAD reflog" \
  bash -c "[ \"\$(git rev-parse feature/link-check)\" = \"$LOST\" ]"

section "4.7 reflog: undo a rebase"
git switch -q feature/link-check
printf '\nRun `python linkcheck.py` to check links.\n' >> README.md
git commit -qam "docs: document link checker"
BEFORE=$(git rev-parse HEAD)
show git log --oneline -3
show git rebase --onto main HEAD~1
show git log --oneline -3
check "wrong --onto dropped the skeleton commit" test ! -e linkcheck.py
show bash -c "git reflog -n 6 | grep -E 'rebase|commit'"
ENTRY=$(git reflog --format='%gd %gs' | awk '/rebase \(start\)/ {print $1; exit}')
PRE=$(echo "$ENTRY" | sed -E 's/HEAD@\{([0-9]+)\}/\1/'); PRE=$((PRE + 1))
show git reset --hard "HEAD@{$PRE}"
check "reflog entry before 'rebase (start)' restores pre-rebase tip" \
  bash -c "[ \"\$(git rev-parse HEAD)\" = \"$BEFORE\" ]"
git switch -q main
git branch -q -D feature/link-check

# --------------------------------------------------------------------------
section "4.8 revert a plain commit"
printf 'Broken,https://broken.invalid/,Misc\n' >> resources.csv
git commit -qam "feat: add broken link"
git push -q origin main
show git revert --no-edit HEAD
show git log --oneline -3
check "revert removed the line" bash -c '! grep -q broken.invalid resources.csv'
git push -q origin main

section "4.8 revert a merge, then the re-merge trap"
git switch -q -c feature/categories
printf 'CATEGORIES = ["Git", "GitHub", "Python"]\n' > categories.py
git add categories.py && git commit -qm "feat: add category list"
printf '\nCategories are defined in categories.py.\n' >> README.md
git commit -qam "docs: mention categories"
git switch -q main
git merge -q --no-ff -m "Merge feature/categories" feature/categories
MERGE=$(git rev-parse HEAD)
show git revert --no-edit "$MERGE"
show git revert --no-edit -m 1 "$MERGE"
check "merge revert removed categories.py" test ! -e categories.py
REVERT=$(git rev-parse HEAD)
git switch -q feature/categories
printf 'from categories import CATEGORIES\n\nassert "Git" in CATEGORIES\n' > test_categories.py
git add test_categories.py && git commit -qm "test: cover categories"
git switch -q main
show git merge --no-edit feature/categories
show git log --oneline --graph -6
show ls
check "TRAP: re-merge is clean but brings only the new commit" \
  bash -c 'test -f test_categories.py && test ! -e categories.py && ! grep -q categories.py README.md'
show git revert --no-edit "$REVERT"
check "reverting the revert restores the earlier commits" \
  bash -c 'test -f categories.py && grep -q categories.py README.md'
git push -q origin main

section "4.8 variant: follow-up touches a reverted file -> modify/delete conflict"
git switch -q -c feature/tags
printf 'TAGS = ["beginner"]\n' > tags.py
git add tags.py && git commit -qm "feat: add tags"
git switch -q main
git merge -q --no-ff -m "Merge feature/tags" feature/tags
git revert --no-edit -m 1 HEAD >/dev/null
git switch -q feature/tags
printf 'TAGS.append("advanced")\n' >> tags.py
git commit -qam "fix: add advanced tag"
git switch -q main
show git merge --no-edit feature/tags
check "modify/delete conflict reported" bash -c 'git status --porcelain | grep -q "^UD tags.py\|^DU tags.py"'
show git merge --abort
git reset -q --hard origin/main

# --------------------------------------------------------------------------
section "4.9 force push overwrites a teammate"
cd "$LAB"; git clone -q origin.git bob
cd "$LAB/bob"; git config user.name Bob; git config user.email bob@example.com
cd "$LAB/alice"
git switch -q -c feature/shared main
printf 'shared v1\n' > shared.txt; git add shared.txt; git commit -qm "feat: shared v1"
git push -q -u origin feature/shared
cd "$LAB/bob"
git fetch -q; git switch -q feature/shared
printf "Bob's work\n" >> shared.txt; git commit -qam "feat: bob adds work"
git push -q
BOB=$(git rev-parse HEAD)
cd "$LAB/alice"
git commit -q --amend -m "feat: shared v1 (reworded)"
show git push --force-with-lease
show git push --force-with-lease --force-if-includes
check "lease rejected an overwrite of Bob's unseen commit" \
  bash -c "[ \"\$(git --git-dir=$LAB/origin.git rev-parse feature/shared)\" = \"$BOB\" ]"
git fetch -q
show git push --force-with-lease
show git -C "$LAB/origin.git" log --oneline -1 feature/shared
check "after a background fetch, plain --force-with-lease overwrote Bob" \
  bash -c "[ \"\$(git --git-dir=$LAB/origin.git rev-parse feature/shared)\" != \"$BOB\" ]"
cd "$LAB/bob"
show git push origin "$BOB:refs/heads/feature/shared-bob"
check "Bob's commit restored on the remote from his clone" \
  bash -c "[ \"\$(git --git-dir=$LAB/origin.git rev-parse feature/shared-bob)\" = \"$BOB\" ]"

section "4.9 --force-if-includes catches the background-fetch case"
cd "$LAB/alice"
git push -q --force origin "$BOB:refs/heads/feature/shared"
git fetch -q
git reset -q --hard "$BOB~1"
git commit -q --allow-empty -m "feat: alice rewrites again"
show git push --force-with-lease --force-if-includes
check "--force-if-includes rejected despite fresh remote-tracking ref" \
  bash -c "[ \"\$(git --git-dir=$LAB/origin.git rev-parse feature/shared)\" = \"$BOB\" ]"

# --------------------------------------------------------------------------
section "4.10 a reverted secret is still in history"
cd "$LAB/alice"; git switch -q main
printf 'TOKEN=ghp_FAKE0000000000000000000000000000000\n' > .env
git add .env && git commit -qm "chore: local config"
git revert --no-edit HEAD >/dev/null
show git log --oneline -S ghp_FAKE
check "revert does not remove a secret from history" \
  bash -c '[ "$(git log --oneline -S ghp_FAKE | wc -l)" -eq 2 ]'

printf '\n'
if [ "$FAILED" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit "$FAILED"
