# Git

## 1. What it is

Git is a version-control system: it stores the history of a folder as a chain of **commits**, each a snapshot with a message and a parent. A **repository** is that history. A **remote** is another copy (here a small server inside the cluster). `push` sends commits to a remote; `clone` copies one.

## 2. Why this repository uses it

Git is the source of truth, and in this lesson a **commit also moves a change between stages**: staging and production are pinned to a commit by a commit of their own (`clusters/<stage>.yaml`). A rollback is `git revert`.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `scripts/seed-repo.sh` | creates the working clone, a pre-push hook, a first commit, then a second that pins staging and production to the first |
| `scripts/promote.sh, lib.sh (`set_stage_value`, `commit_and_push`)` | each wave is a commit |
| `scripts/gate.sh, lib.sh (`applied_at`)` | `git merge-base --is-ancestor` |
| `scripts/runbook/*.sh` | `git revert`, `git rm`, commits |
| `docker/git-server/` | the server the hub's Argo CD reads |

## 4. How it works underneath

- A commit is identified by a 40-character hash of its content and parent. Changing anything changes the hash, so a hash names exactly one state.
- A **branch** is a movable name for a commit (`main`). `HEAD` is "where I am now".
- `git revert <commit>` makes a *new* commit that undoes an earlier one. History is kept, which is why GitOps uses it for rollback instead of rewriting history.
- A **hook** is a script Git runs at a moment such as `pre-push`; if it exits non-zero, the push is refused. `--no-verify` skips it.
- **Smart HTTP**: the server answers `GET .../info/refs?service=git-upload-pack` to list branches and `POST .../git-receive-pack` to accept a push. Anything that speaks that can be a Git server.

## 5. Walkthrough of this repository's use

Setup is as in the first project (see its Git note): a fresh clone in `.work/gitops-fleet`, a fixed author, `commit.gpgsign false`, a `pre-push` hook that runs `validate.sh`, `push --force` for the first push.

New here:
```bash
work_git commit --quiet -m "Initial fleet: web 1.0.0 in dev, staging and production, with admission policy"
first="$(work_head)"
set_stage_value staging revision "${first}"
set_stage_value production revision "${first}"
work_git add --all
work_git commit --quiet -m "Pin staging and production to the first commit"
```
Two commits: the first is the whole fleet; the second changes two lines so that staging and production point at the **first commit's hash** instead of `main`. After that a new commit on `main` reaches `dev` immediately (it follows `main`) and reaches the others only when `promote.sh` commits a new pin.

`git merge-base --is-ancestor <A> <B>` exits 0 if commit A is an ancestor of B, which is how the gate asks "did this stage apply my commit or something newer?". `git revert --no-edit <sha>` undoes the bad commit with a new commit; after a revert the runbook also commits new pins so that staging and production move to the revert. `git rm --quiet apps/web/base/namespace.yaml` stages a file deletion (the destructive commit).

## 6. Try it yourself

1. `git -C .work/gitops-fleet log --oneline` : the history after `make up` (two commits).
2. `grep revision .work/gitops-fleet/clusters/*.yaml` : `main` for dev, a 40-character hash for the others.
3. `scripts/runbook/03-waves.sh good` then the same `grep` : staging and production moved to the new commit.
4. `git -C .work/gitops-fleet merge-base --is-ancestor HEAD~1 HEAD && echo yes` : `yes`.
5. `git -C .work/gitops-fleet log --oneline --graph | head` : shows reverts as ordinary commits.

## 7. Mistakes people make

- Rewriting shared history (`push --force`) so other copies disagree. The runbook uses `revert`, and `--force` only on the demo repository when it is reset.
- Committing generated files or secrets. `.gitignore` lists what must not be tracked.
- Assuming a hook cannot be skipped. A hook is a convenience; the real gate is a check on the server or in CI.

## 8. Check yourself

1. What does a commit hash identify?
   *Answer:* Exactly one snapshot and its history.
2. Why use `git revert` instead of deleting a commit?
   *Answer:* It adds a new commit that undoes the old one and keeps the history intact.
3. What is a pre-push hook?
   *Answer:* A script that runs before a push and can refuse it by failing.
4. How can a hook be skipped?
   *Answer:* With `git push --no-verify`.
5. What is `main`?
   *Answer:* A branch name: a pointer to the newest commit of the main line.

## 9. Further reading

- Pro Git book: <https://git-scm.com/book/en/v2>. Git reference: <https://git-scm.com/docs>.
