#!/usr/bin/env bash
#
# maichess maintenance — operational cleanup for the k3s deployment.
#
# Runs against the cluster the current KUBECONFIG points at (on the droplet that
# is /etc/rancher/k3s/k3s.yaml). Every destructive subcommand prints what it will
# touch and asks for confirmation unless --yes is given.
#
# It talks to the data stores by exec-ing into their pods, so no passwords are
# ever passed on the host command line — they stay inside the pod environment
# (MONGO_INITDB_ROOT_PASSWORD / REDIS_PASSWORD). Elasticsearch has security
# disabled in-cluster; Kafka is PLAINTEXT on kafka:9092.
#
# Subcommands
#   status            Show data-store sizes (Mongo collections, Redis, ES, stuck games).
#   clean-analysis    Drop stale engine-analysis cache (optionally only one bot_id).
#   purge-stale-games Remove matches stuck at status "ongoing" (read model + live state).
#   flush-caches      FLUSHALL Redis (every namespace is a rebuildable cache).
#   rebuild-search    Drop + rebuild the Elasticsearch indexes via a detached Job.
#   reset-kafka       Delete + recreate the app event/command/cdc topics (advanced).
#   reset-data        FULL RESET: scale down, wipe Mongo + Redis + ES, scale up.
#
# Usage
#   ./maintenance.sh <subcommand> [--staging | -n <namespace>] [--yes] [extra opts]
#
# Examples
#   ./maintenance.sh status
#   ./maintenance.sh reset-data --yes
#   ./maintenance.sh clean-analysis --bot-id tier3_classical
#   ./maintenance.sh rebuild-search --wait
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config / globals
# ---------------------------------------------------------------------------
: "${KUBECONFIG:=/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

NS="maichess"            # production namespace; --staging switches to maichess-staging
ASSUME_YES=0
MONGO_DB="maichess"      # database-service GetDatabase("maichess") — the match-db read models
ES_INDEXES="analysis_games,matches,positions"

# App event/command/cdc topics owned by maichess services. Internal/Streams-managed
# topics (…-changelog, _consumer_offsets, connect-*) are intentionally excluded —
# their owners recreate them with the right config.
KAFKA_APP_TOPICS=(
  match.commands.v1 match.events.v1
  matchmaking.commands.v1 matchmaking.events.v1 matchmaking.skill.v1
  analysis.commands.v1 analysis.events.v1
  engine.commands.v1 engine.events.v1
  user.events.v1 socket.outbound.v1 cheat.events.v1
  user.cdc.v1 match.cdc.v1
)

c_red() { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
hr()    { printf '%s\n' "----------------------------------------------------------------"; }

die() { c_red "error: $*" >&2; exit 1; }

confirm() {
  # confirm "<message>"
  [ "$ASSUME_YES" -eq 1 ] && return 0
  c_ylw "$1"
  read -r -p "Type 'yes' to continue: " reply
  [ "$reply" = "yes" ] || die "aborted"
}

# Resolve the first ready/any pod for a component label.
pod_for() {
  local component="$1" name
  name="$(kubectl get pod -n "$NS" -l "app.kubernetes.io/component=$component" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$name" ] || die "no pod found for component '$component' in namespace '$NS'"
  printf '%s' "$name"
}

# ---------------------------------------------------------------------------
# Store accessors (password stays inside the pod)
# ---------------------------------------------------------------------------
mongo_eval() {
  # mongo_eval '<js>'  — db name + JS are passed as positional args so no shell
  # escaping of the JS is needed; the password expands inside the pod only.
  local pod; pod="$(pod_for mongo)"
  kubectl exec -n "$NS" "$pod" -c mongodb -- sh -c '
    mongosh "mongodb://maichess:$MONGO_INITDB_ROOT_PASSWORD@localhost:27017/$1?authSource=admin&directConnection=true" --quiet --eval "$2"
  ' _ "$MONGO_DB" "$1"
}

redis_cli() {
  # redis_cli <args...>
  local pod; pod="$(pod_for redis)"
  kubectl exec -n "$NS" "$pod" -- sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning "$@"' _ "$@"
}

es_curl() {
  # es_curl <curl-args...>
  local pod; pod="$(pod_for elasticsearch)"
  kubectl exec -n "$NS" "$pod" -- curl -s "$@"
}

kafka_cmd() {
  # kafka_cmd <bin> <args...>   e.g. kafka_cmd kafka-topics.sh --list
  local pod bin; pod="$(pod_for kafka)"; bin="$1"; shift
  kubectl exec -n "$NS" "$pod" -- "/opt/kafka/bin/$bin" --bootstrap-server kafka:9092 "$@"
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------
cmd_status() {
  hr; c_grn "Namespace: $NS"; hr
  echo "Mongo ($MONGO_DB):"
  mongo_eval '
    const cols = db.getCollectionNames().filter(c => !c.startsWith("system."));
    cols.forEach(c => print("  " + c.padEnd(22) + db.getCollection(c).countDocuments()));
    print("  --");
    print("  matches.ongoing".padEnd(24) + db.matches.countDocuments({status:"ongoing"}));
  ' || c_red "  (mongo unreachable)"
  echo
  echo "Redis:"
  printf '  keys total        %s\n' "$(redis_cli DBSIZE || echo '?')"
  for pat in 'match:live:*' 'match:*' 'matches:user:*' 'analysis:*' 'queue*' 'leaderboard:*'; do
    printf '  %-18s%s\n' "$pat" "$(redis_cli --scan --pattern "$pat" 2>/dev/null | wc -l | tr -d ' ')"
  done
  echo
  echo "Elasticsearch:"
  es_curl "http://localhost:9200/_cat/indices/${ES_INDEXES//,/,}?h=index,docs.count,store.size" 2>/dev/null \
    | sed 's/^/  /' || c_red "  (es unreachable)"
  echo
  echo "Workloads (app deployments):"
  kubectl get deploy -n "$NS" -l maichess.io/container-update=true \
    -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas --no-headers \
    | sed 's/^/  /'
  echo
  echo "Recent jobs:"
  kubectl get jobs -n "$NS" --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -n +1 | sed 's/^/  /' || true
}

cmd_clean_analysis() {
  local bot_id=""
  while [ $# -gt 0 ]; do case "$1" in --bot-id) bot_id="$2"; shift 2;; *) die "unknown opt $1";; esac; done

  if [ -n "$bot_id" ]; then
    confirm "Delete analysis_results AND Redis analysis cache for bot_id='$bot_id' in '$NS'."
    c_grn "Mongo: deleting analysis_results where bot_id='$bot_id'..."
    mongo_eval 'print("  deleted " + db.analysis_results.deleteMany({bot_id:"'"$bot_id"'"}).deletedCount + " docs")'
    c_grn "Redis: deleting analysis:$bot_id:* hashes..."
    redis_purge_pattern "analysis:$bot_id:*"
  else
    confirm "Drop the ENTIRE engine-analysis cache (analysis_results collection + all analysis:* Redis hashes) in '$NS'. Saved games (analysis_games) are kept."
    c_grn "Mongo: dropping analysis_results..."
    mongo_eval 'db.analysis_results.drop(); print("  dropped")'
    c_grn "Redis: deleting analysis:* hashes..."
    redis_purge_pattern "analysis:*"
  fi
  c_grn "Done. Analysis re-populates lazily on the next analysis request."
}

cmd_purge_stale_games() {
  confirm "Remove ALL matches stuck at status 'ongoing' (read model + live state + caches) in '$NS'. Finished games are kept."
  c_grn "Mongo: collecting + deleting ongoing matches..."
  # Print the ids (for the audit log) then delete them.
  mongo_eval '
    const ids = db.matches.find({status:"ongoing"}, {_id:1}).map(d => String(d._id));
    print("  ongoing ids: " + (ids.length ? ids.join(", ") : "(none)"));
    print("  deleted " + db.matches.deleteMany({status:"ongoing"}).deletedCount + " match docs");
  '
  c_grn "Redis: clearing live state + finished-match caches for stale games..."
  redis_purge_pattern "match:live:*"
  redis_purge_pattern "matches:user:*"   # page caches reference status; cheapest to drop all
  c_grn "Done. Stuck games are gone; the projector will not resurrect them (offsets committed)."
}

cmd_flush_caches() {
  confirm "FLUSHALL Redis in '$NS'. Every namespace is a rebuildable cache (match cache, page cache, matchmaking queue, analysis cache, leaderboard ZSET). The matchmaking queue is transient — queued clients re-enqueue; the leaderboard repopulates from new rating events."
  c_grn "Redis: FLUSHALL..."
  redis_cli FLUSHALL
  c_grn "Done."
}

# Delete every key matching a glob, in bounded batches (SCAN, never KEYS).
redis_purge_pattern() {
  local pattern="$1" pod; pod="$(pod_for redis)"
  kubectl exec -n "$NS" "$pod" -- sh -c '
    pat="$1"; n=0; cur=0
    while :; do
      set -- $(redis-cli -a "$REDIS_PASSWORD" --no-auth-warning SCAN "$cur" MATCH "$pat" COUNT 500)
      cur="$1"; shift
      if [ "$#" -gt 0 ]; then redis-cli -a "$REDIS_PASSWORD" --no-auth-warning DEL "$@" >/dev/null; n=$((n+$#)); fi
      [ "$cur" = "0" ] && break
    done
    echo "  deleted $n keys matching $pat"
  ' _ "$pattern"
}

cmd_rebuild_search() {
  local wait=0
  while [ $# -gt 0 ]; do case "$1" in --wait) wait=1; shift;; *) die "unknown opt $1";; esac; done

  confirm "Drop the Elasticsearch indexes ($ES_INDEXES) and rebuild them from Mongo via a detached Job in '$NS'."

  c_grn "ES: deleting indexes $ES_INDEXES (ignore_unavailable)..."
  es_curl -X DELETE "http://localhost:9200/${ES_INDEXES}?ignore_unavailable=true" >/dev/null || true
  echo

  local img
  img="$(kubectl get deploy -n "$NS" search-service -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  [ -n "$img" ] || die "search-service deployment not found in '$NS' (is services.searchService.enabled=true?)"

  c_grn "Launching detached reindex Job (image: $img)..."
  kubectl delete job -n "$NS" search-reindex-manual --ignore-not-found >/dev/null 2>&1 || true
  cat <<YAML | kubectl apply -n "$NS" -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: search-reindex-manual
  labels:
    app.kubernetes.io/component: search-reindex
spec:
  backoffLimit: 4
  ttlSecondsAfterFinished: 1800
  template:
    metadata:
      labels:
        app.kubernetes.io/component: search-reindex
    spec:
      restartPolicy: OnFailure
      imagePullSecrets:
        - name: ghcr-pull-secret
      containers:
        - name: search-reindex
          image: $img
          args: ["--reindex"]
          env:
            - name: Services__DatabaseService
              value: "http://match-db:8080"
            - name: Elasticsearch__Url
              value: "http://elasticsearch:9200"
YAML

  if [ "$wait" -eq 1 ]; then
    c_grn "Waiting for reindex to complete (up to 30m)..."
    if kubectl wait -n "$NS" --for=condition=complete job/search-reindex-manual --timeout=30m; then
      kubectl logs -n "$NS" job/search-reindex-manual --tail=20 | sed 's/^/  /'
      c_grn "Reindex complete."
    else
      c_red "Reindex did not complete in time; inspect: kubectl logs -n $NS job/search-reindex-manual"
      exit 1
    fi
  else
    c_grn "Job started. Follow it with:"
    echo "  kubectl logs -n $NS -f job/search-reindex-manual"
  fi
}

cmd_reset_kafka() {
  c_ylw "ADVANCED: this deletes the maichess event log. Consumers must be down first."
  confirm "Delete + recreate ${#KAFKA_APP_TOPICS[@]} app topics in '$NS' (event/command/cdc). Streams changelog + connect topics are left alone. This wipes all match/analysis history in Kafka."

  c_grn "Scaling app deployments to 0 (release the consumer groups)..."
  kubectl scale deploy -n "$NS" -l maichess.io/container-update=true --replicas=0 >/dev/null
  kubectl wait -n "$NS" --for=delete pod -l maichess.io/container-update=true --timeout=180s 2>/dev/null || true

  for t in "${KAFKA_APP_TOPICS[@]}"; do
    # Preserve partition count across the recreate (matchmaking/user topics must stay aligned).
    local parts
    parts="$(kafka_cmd kafka-topics.sh --describe --topic "$t" 2>/dev/null \
      | sed -n 's/.*PartitionCount: \([0-9]*\).*/\1/p' | head -1 || true)"
    parts="${parts:-3}"
    c_grn "  $t: delete + recreate (partitions=$parts)"
    kafka_cmd kafka-topics.sh --delete --topic "$t" >/dev/null 2>&1 || true
    kafka_cmd kafka-topics.sh --create --if-not-exists --topic "$t" --partitions "$parts" --replication-factor 1 >/dev/null
  done

  c_grn "Restarting kafka-connect (Debezium offsets referenced the old oplog/WAL)..."
  kubectl rollout restart deploy -n "$NS" kafka-connect >/dev/null 2>&1 || true

  c_grn "Scaling app deployments back to 1 (HPA will adjust)..."
  kubectl scale deploy -n "$NS" -l maichess.io/container-update=true --replicas=1 >/dev/null
  c_grn "Done. Topics are empty; consumers start fresh."
}

cmd_reset_data() {
  local with_kafka=0
  while [ $# -gt 0 ]; do case "$1" in --with-kafka) with_kafka=1; shift;; *) die "unknown opt $1";; esac; done

  c_red "FULL DATA RESET for namespace '$NS'"
  echo "This will:"
  echo "  1. Scale all app services down to 0"
  echo "  2. Drop every collection in Mongo '$MONGO_DB' (matches, analysis_games, analysis_results, …)"
  echo "  3. FLUSHALL Redis"
  [ "$with_kafka" -eq 1 ] && echo "  4. Delete + recreate the Kafka app topics"
  echo "  $([ "$with_kafka" -eq 1 ] && echo 5 || echo 4). Drop + rebuild the Elasticsearch indexes (empty after wipe)"
  echo "  $([ "$with_kafka" -eq 1 ] && echo 6 || echo 5). Scale services back up"
  confirm "This permanently deletes all match, analysis and search data in '$NS'."

  c_grn "[1/_] Scaling app deployments to 0..."
  kubectl scale deploy -n "$NS" -l maichess.io/container-update=true --replicas=0 >/dev/null
  kubectl wait -n "$NS" --for=delete pod -l maichess.io/container-update=true --timeout=180s 2>/dev/null || true

  c_grn "[2/_] Dropping all Mongo collections in '$MONGO_DB'..."
  mongo_eval '
    db.getCollectionNames().filter(c => !c.startsWith("system."))
      .forEach(c => { db.getCollection(c).drop(); print("  dropped " + c); });
  '

  c_grn "[3/_] FLUSHALL Redis..."
  redis_cli FLUSHALL

  if [ "$with_kafka" -eq 1 ]; then
    c_grn "[4/_] Resetting Kafka app topics..."
    for t in "${KAFKA_APP_TOPICS[@]}"; do
      local parts
      parts="$(kafka_cmd kafka-topics.sh --describe --topic "$t" 2>/dev/null \
        | sed -n 's/.*PartitionCount: \([0-9]*\).*/\1/p' | head -1 || true)"
      parts="${parts:-3}"
      kafka_cmd kafka-topics.sh --delete --topic "$t" >/dev/null 2>&1 || true
      kafka_cmd kafka-topics.sh --create --if-not-exists --topic "$t" --partitions "$parts" --replication-factor 1 >/dev/null
      echo "  reset $t (partitions=$parts)"
    done
    kubectl rollout restart deploy -n "$NS" kafka-connect >/dev/null 2>&1 || true
  fi

  c_grn "[_/_] Dropping Elasticsearch indexes..."
  es_curl -X DELETE "http://localhost:9200/${ES_INDEXES}?ignore_unavailable=true" >/dev/null || true

  c_grn "[_/_] Scaling app deployments back to 1..."
  kubectl scale deploy -n "$NS" -l maichess.io/container-update=true --replicas=1 >/dev/null
  kubectl rollout status deploy -n "$NS" -l maichess.io/container-update=true --timeout=10m || \
    c_ylw "Some services not ready yet — check 'kubectl get pods -n $NS'."

  echo
  if kubectl get deploy -n "$NS" search-service >/dev/null 2>&1; then
    c_grn "Rebuilding empty ES indexes..."
    cmd_rebuild_search --wait || true
  fi
  c_grn "Full reset complete. Clean slate."
}

# ---------------------------------------------------------------------------
# Arg parsing / dispatch
# ---------------------------------------------------------------------------
usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

[ $# -ge 1 ] || { usage; exit 1; }
SUB="$1"; shift

# Pull global flags out of the remaining args.
REST=()
while [ $# -gt 0 ]; do
  case "$1" in
    --staging) NS="maichess-staging"; shift;;
    -n) NS="$2"; shift 2;;
    --yes|-y) ASSUME_YES=1; shift;;
    *) REST+=("$1"); shift;;
  esac
done
if [ ${#REST[@]} -gt 0 ]; then set -- "${REST[@]}"; else set --; fi

command -v kubectl >/dev/null || die "kubectl not found on PATH"
kubectl get ns "$NS" >/dev/null 2>&1 || die "namespace '$NS' not found"

case "$SUB" in
  status)            cmd_status ;;
  clean-analysis)    cmd_clean_analysis "$@" ;;
  purge-stale-games) cmd_purge_stale_games "$@" ;;
  flush-caches)      cmd_flush_caches "$@" ;;
  rebuild-search)    cmd_rebuild_search "$@" ;;
  reset-kafka)       cmd_reset_kafka "$@" ;;
  reset-data)        cmd_reset_data "$@" ;;
  -h|--help|help)    usage ;;
  *) die "unknown subcommand '$SUB' (try: status, clean-analysis, purge-stale-games, flush-caches, rebuild-search, reset-kafka, reset-data)";;
esac
