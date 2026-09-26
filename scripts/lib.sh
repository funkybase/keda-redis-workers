# Shared helpers, sourced by producer.sh and check.sh.
#
# Every Redis call runs redis-cli inside the Redis pod via `kubectl exec`, so
# no port-forward is needed and the password never appears on a command line:
# the Redis container gets it from the Secret as $REDIS_PASSWORD, and
# redis-cli picks it up from $REDISCLI_AUTH.

NAMESPACE="${NAMESPACE:-ingest}"
REDIS_TARGET="${REDIS_TARGET:-deploy/redis}"

# rcli ARGS...   run one redis-cli command; with no args, read commands from stdin.
rcli() {
  kubectl -n "$NAMESPACE" exec -i "$REDIS_TARGET" -c redis -- \
    sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" exec redis-cli --no-auth-warning "$@"' rcli "$@"
}
