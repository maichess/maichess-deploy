# Maintenance & data-reset guide

`maintenance.sh` is an operator tool for cleaning and rebuilding the data stores of
the maichess k3s deployment. Use it for the recurring operational chores:

- the engine-analysis cache went stale after the default bot changed,
- games are stuck in an unresolved `ongoing` state,
- caches / Elasticsearch need flushing or rebuilding,
- a full clean-slate reset (the platform is not live yet, so this is cheap).

It also documents the **deploy-hang fix** (see the bottom of this file).

---

## Where to run it

The script drives the cluster through `kubectl` and `kubectl exec`. Run it **on the
droplet that hosts k3s**, where `/etc/rancher/k3s/k3s.yaml` exists (the script
defaults `KUBECONFIG` to it):

```bash
ssh <droplet-user>@<droplet-host>
cd ~/maichess-deploy          # the checkout the deploy pipeline uses
git pull                      # make sure you have this script
./helm/scripts/maintenance.sh status
```

You can also run it from anywhere that has a working `kubectl` context for the
cluster (`export KUBECONFIG=...` first).

### Global flags (work with every subcommand)

| Flag             | Effect                                                        |
|------------------|--------------------------------------------------------------|
| `--staging`      | Target the `maichess-staging` namespace instead of `maichess`|
| `-n <namespace>` | Target an explicit namespace                                 |
| `--yes` / `-y`   | Skip the confirmation prompt (for scripted / non-interactive runs) |

No passwords are ever passed on the command line — the script reads Mongo/Redis
credentials from inside the pods.

---

## Subcommands

### `status` — see what's there (read-only, always safe)

```bash
./helm/scripts/maintenance.sh status
```

Prints Mongo collection counts (incl. `matches.ongoing`, i.e. stuck games), Redis
key counts per namespace, Elasticsearch index doc counts, app-deployment readiness,
and recent Jobs. Start here to decide what needs cleaning.

### `clean-analysis` — drop stale engine-analysis (the default-bot-changed case)

Engine analysis is cached per `bot_id` in Mongo `analysis_results` and in the Redis
`analysis:{botId}:{fen}` hashes. When the default analysis bot changed, the old
bot's entries are dead weight.

```bash
# Targeted: remove only the old bot's cached analysis
./helm/scripts/maintenance.sh clean-analysis --bot-id <old_bot_id>

# Everything: drop the whole analysis cache (saved games are kept)
./helm/scripts/maintenance.sh clean-analysis
```

Analysis re-populates lazily the next time a position is analysed.

### `purge-stale-games` — remove games stuck in `ongoing`

Deletes every match still at `status: "ongoing"` from the Mongo read model, plus
its live state (`match:live:*`) and the user page caches. Finished games are kept.
The projector will **not** resurrect them — its Kafka offsets are already committed.

```bash
./helm/scripts/maintenance.sh purge-stale-games
```

### `flush-caches` — wipe Redis

```bash
./helm/scripts/maintenance.sh flush-caches
```

`FLUSHALL` on Redis. Every namespace is rebuildable: finished-match and page caches
repopulate from match-db on a miss, the matchmaking queue is transient (clients
re-enqueue), and the leaderboard ZSET refills from new rating events.

### `rebuild-search` — drop + rebuild Elasticsearch (the reindex-that-times-out fix)

The pipeline's reindex option runs as a **blocking Helm hook**, so it stalls the
whole deploy. This subcommand instead drops the indexes and launches the reindex as
a **detached Job**, so it never blocks anything:

```bash
# fire-and-forget (returns immediately, prints how to follow the logs)
./helm/scripts/maintenance.sh rebuild-search

# block until it finishes (up to 30m) and print the result
./helm/scripts/maintenance.sh rebuild-search --wait
```

Follow a detached run with:

```bash
kubectl logs -n maichess -f job/search-reindex-manual
```

> Tip: run `clean-analysis` / `purge-stale-games` / `reset-data` **before**
> reindexing — fewer source documents means a much faster rebuild.

### `reset-data` — FULL RESET (recommended clean slate)

```bash
./helm/scripts/maintenance.sh reset-data            # prompts for confirmation
./helm/scripts/maintenance.sh reset-data --yes      # non-interactive
./helm/scripts/maintenance.sh reset-data --with-kafka  # also wipe the Kafka event log
```

Sequence: scale all app services to 0 → drop every Mongo collection in the
`maichess` DB → `FLUSHALL` Redis → (optionally reset Kafka topics) → drop the ES
indexes → scale services back up → rebuild the (now empty) ES indexes.

Use `--with-kafka` only if you also want to purge match/analysis **history** from
the Kafka log. Without it, the read models are wiped but the event log is retained
(harmless — nothing surfaces it, and it expires via `retention.ms`).

### `reset-kafka` — reset the event log only (advanced)

```bash
./helm/scripts/maintenance.sh reset-kafka
```

Scales consumers down, deletes + recreates the maichess app topics
(`match.*`, `analysis.*`, `engine.*`, `*.cdc.v1`, …) preserving partition counts,
restarts kafka-connect, and scales consumers back up. Streams changelog and
connect-internal topics are left for their owners to recreate. You rarely need this
on its own — prefer `reset-data --with-kafka`.

---

## Typical recipes

```bash
# "Default bot changed; clear the old analysis and rebuild search"
./helm/scripts/maintenance.sh clean-analysis
./helm/scripts/maintenance.sh rebuild-search --wait

# "Get rid of the stuck games"
./helm/scripts/maintenance.sh purge-stale-games

# "Just give me a clean slate" (it's not live yet)
./helm/scripts/maintenance.sh reset-data --yes

# Staging instead of prod
./helm/scripts/maintenance.sh reset-data --staging --yes
```

---

## The deploy-hang fix (old pods that won't shut down)

**Root cause:** the app Deployment template had no `strategy`, so Kubernetes used
the default `RollingUpdate` (`maxSurge 25%` / `maxUnavailable 25%`). At
`replicas: 1` that rounds `maxUnavailable` **down to 0**, so a new pod must be
scheduled *before* the old one may terminate. The deploy pipeline restarts *every*
app service at once (`kubectl rollout restart -l maichess.io/container-update=true`),
and the resource-tight `ubuntu` node (8Gi, where stateful workloads are pinned)
can't fit the surge — the new pod stays `Pending`, the old pod therefore never
terminates, and `kubectl rollout status` blocks until its timeout, i.e. the deploy
"hangs until the pipeline times out."

**Fix (applied in `templates/_app-deployment.tpl`):** a zero-surge rolling update —

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 0
    maxUnavailable: 1
```

The old pod's resources are freed **first**, then the new pod schedules. This
trades a few seconds of per-service downtime (fine — not yet live) for a deploy
that no longer deadlocks. Override per-service via the deployment macro
(`strategyType` / `maxSurge` / `maxUnavailable`) if a service needs surge instead.

This ships automatically on the next `helm upgrade` (the normal pipeline run). No
manual pod-deletion should be needed after that; if a single pod is ever wedged in
`Terminating`, `kubectl delete pod -n maichess <name> --grace-period=0 --force`
clears it, but that should now be the rare exception, not routine.
```
