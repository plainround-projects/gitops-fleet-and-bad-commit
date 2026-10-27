# 0004. Protections against a destructive commit

## Context

A commit that deletes the production namespace's manifest would, with pruning on, delete the namespace and everything in it.

## Decision

Two layers, either of which is enough. Production's file sets `prune: false`, which the ApplicationSet turns into the Application's sync policy. The Namespace carries `argocd.argoproj.io/sync-options: Prune=false`, so it is never pruned in any stage even if a stage turns pruning on. A deleted manifest leaves the object running and the Application `OutOfSync`, with the namespace listed as needing pruning, until a person decides: restore the file with `git revert`, or prune by hand.

## Alternatives

- **A finalizer on the Namespace.** Blocks deletion of the namespace but not the deletion of its contents.
- **No protection, rely on review.** The point of the step is that review is not a control.

## Consequences

- Prune stays on in dev and staging for everything but the Namespace, so deleting a ConfigMap's file still deletes the ConfigMap there.
- The wave gate must judge health, not `Synced`: a protected deletion leaves the stage `OutOfSync` on purpose, so the gate looks at the last sync operation and the health status.
