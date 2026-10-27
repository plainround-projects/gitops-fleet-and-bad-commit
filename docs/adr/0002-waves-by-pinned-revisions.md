# 0002. Waves are pinned revisions, promoted by commits

## Context

A change must reach dev, then staging, then production, with a health gate between waves, and every cluster must still self-heal. The lesson sketches a polling script that calls `argocd app sync web-staging`.

## Decision

`clusters/<stage>.yaml` holds the revision each stage deploys. Dev follows `main`; staging and production are pinned to a commit. `scripts/promote.sh` waits for dev's gate (`scripts/gate.sh`: the commit applied, then Healthy for `observeSeconds`), commits the new pin for staging, waits for staging's gate, then commits the pin for production. All three Applications keep `automated` sync with self-heal, so a drifted object is still corrected, and the order of waves is in the Git history.

## Alternatives

- **Manual-sync staging and production, and a script that runs `argocd app sync`.** The sync becomes an imperative event outside Git, and self-heal is off for the stages that matter most.
- **Argo CD progressive syncs (RollingSync).** An alpha feature that removes automated sync from the generated Applications, which also removes self-heal.

## Consequences

- The best-case time to production includes the ApplicationSet's re-read of `clusters/` (20 seconds here), which the lesson's script-driven sync does not have. `scripts/best-case.sh` computes both.
- The gate is a script, not a controller. A CI job or a Kargo-style promotion controller would run it in production.
