#!/usr/bin/env bash
set -u

repo="${1:-$(git rev-parse --show-toplevel 2>/dev/null)}"
remote="${KOS_SYNC_REMOTE:-origin}"
branch="${KOS_SYNC_BRANCH:-main}"
interval="${KOS_SYNC_INTERVAL:-2}"
lock_dir="$repo/.git/kos-watch-sync.lock"

if [[ -z "${repo:-}" || ! -d "$repo/.git" ]]; then
  echo "watch-sync: run inside a git repo or pass repo path." >&2
  exit 2
fi

cleanup() {
  rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "watch-sync: $repo <= $remote/$branch every ${interval}s"

while true; do
  if mkdir "$lock_dir" 2>/dev/null; then
    if git -C "$repo" diff --quiet \
        && git -C "$repo" diff --cached --quiet; then
      if git -C "$repo" fetch --quiet "$remote" "$branch"; then
        local_head="$(git -C "$repo" rev-parse HEAD)"
        remote_head="$(git -C "$repo" rev-parse "$remote/$branch")"
        if [[ "$local_head" != "$remote_head" ]]; then
          if git -C "$repo" merge-base --is-ancestor "$local_head" "$remote_head"; then
            git -C "$repo" merge --ff-only --quiet "$remote/$branch" \
              && echo "watch-sync: updated to $(git -C "$repo" rev-parse --short HEAD)"
          else
            echo "watch-sync: local branch diverged from $remote/$branch; not merging." >&2
          fi
        fi
      else
        echo "watch-sync: fetch failed." >&2
      fi
    else
      echo "watch-sync: worktree dirty; skipping sync." >&2
    fi
    cleanup
  else
    echo "watch-sync: previous sync still running; skipping tick." >&2
  fi
  sleep "$interval"
done
