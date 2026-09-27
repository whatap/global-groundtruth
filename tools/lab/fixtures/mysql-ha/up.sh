#!/bin/bash
# up.sh -> MySQL 8.0 (Ubuntu package) primary + GTID async replica, and a
# MySQL 5.7 single node. Idempotent: running containers are reused, stopped
# ones started, only absent ones created; seeding runs once per data set.
set -u
. "$(dirname "$0")/common.sh"

# ---- credentials (throwaway, outside the repo) ----
if [ ! -s "$SECRETS" ]; then
    mkdir -p "$(dirname "$SECRETS")" && chmod 700 "$(dirname "$SECRETS")"
    gen() { tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24; }
    ( umask 077
      { echo "# jjsong-ggt-mysql-* throwaway credentials, made by up.sh $(date -u +%FT%TZ)"
        echo "APP_USER=whatap";  echo "APP_PASS=$(gen)"
        echo "MON_USER=ggtmon";  echo "MON_PASS=$(gen)"
        echo "REPL_USER=repl";   echo "REPL_PASS=$(gen)"
        echo "ROOT57_PASS=$(gen)"; } > "$SECRETS" )
    say "credentials generated: $SECRETS"
fi
load_secrets

# ---- images ----
docker image inspect "$IMG80" >/dev/null 2>&1 || docker build -t "$IMG80" -f "$FIX_DIR/Dockerfile.ubuntu80" "$FIX_DIR" || die "build $IMG80"
docker image inspect "$IMG57" >/dev/null 2>&1 || docker build -t "$IMG57" -f "$FIX_DIR/Dockerfile.mysql57" "$FIX_DIR" || die "build $IMG57"
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null || die "network $NET"

# ---- containers ----
# CAP_SYS_PTRACE: a root on a host has it, docker root does not (the collector
# reads other uids' /proc/<pid>/environ, root, cwd)
common_run=(--network "$NET" --restart unless-stopped --init --memory 768m --cap-add SYS_PTRACE)
start_or_create() {  # NAME PORT IMAGE [mysqld args...]
    local n="$1" port="$2" img="$3"; shift 3
    if running "$n"; then say "$n: running, reused"; return; fi
    if exists "$n"; then say "$n: stopped, starting"; docker start "$n" >/dev/null || die "start $n"; return; fi
    say "$n: creating"
    if is57 "$n"; then
        docker create --name "$n" --hostname "$n" "${common_run[@]}" -p "127.0.0.1:$port:3306" \
            -e MYSQL_ROOT_PASSWORD_FILE=/run/ggt-root-pw "$img" >/dev/null || die "create $n"
        local t; t="$(mktemp)"; ( umask 077; printf '%s' "$ROOT57_PASS" > "$t" )
        docker cp "$t" "$n:/run/ggt-root-pw" >/dev/null; rm -f "$t"
    else
        docker create --name "$n" --hostname "$n" "${common_run[@]}" -p "127.0.0.1:$port:3306" "$img" "$@" >/dev/null || die "create $n"
    fi
    docker start "$n" >/dev/null || die "start $n"
}
start_or_create "$PRIMARY" 33081 "$IMG80" --server-id=1
start_or_create "$REPLICA" 33082 "$IMG80" --server-id=2 --read-only=ON --super-read-only=ON --relay-log=relay-bin
start_or_create "$M57"     33057 "$IMG57"

# The entrypoint reads MYSQL_ROOT_PASSWORD_FILE on every start and exits when
# the file is gone, but uses the value only on an empty datadir; so after the
# first init the file stays, holding a placeholder instead of the password.
scrub_pwfile() {
    local t; t="$(mktemp)"; echo 'used-at-init-only' > "$t"
    docker cp "$t" "$1:/run/ggt-root-pw" >/dev/null; rm -f "$t"
}
wait_ready() {  # NAME
    local n="$1"
    for _ in $(seq 1 120); do
        if is57 "$n"; then
            # the image's entrypoint runs a temporary server first; wait for the real one
            if docker logs "$n" 2>&1 | grep -q 'init process done\|port: 3306 ' ; then
                docker exec "$n" test -s /root/.ggt-root.cnf 2>/dev/null || \
                    printf '[client]\nuser=root\npassword=%s\n' "$ROOT57_PASS" | \
                    docker exec -i "$n" sh -c 'umask 077; cat > /root/.ggt-root.cnf'
                echo 'SELECT 1' | root_sql "$n" >/dev/null 2>&1 && { scrub_pwfile "$n"; return 0; }
            fi
        else
            echo 'SELECT 1' | root_sql "$n" >/dev/null 2>&1 && return 0
        fi
        sleep 2
    done
    die "$n not ready after 240 s (docker logs $n)"
}
for c in $ALL_CONTAINERS; do wait_ready "$c"; done
say "all three answer"

seeded() { [ "$(echo "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='ggt_lab' AND table_name='meta'" | root_sql "$1")" = 1 ]; }
users_sql() {
    cat <<SQL
CREATE USER IF NOT EXISTS '$APP_USER'@'%' IDENTIFIED BY '$APP_PASS';
GRANT ALL PRIVILEGES ON account.* TO '$APP_USER'@'%';
GRANT ALL PRIVILEGES ON notihub.* TO '$APP_USER'@'%';
CREATE USER IF NOT EXISTS '$MON_USER'@'%' IDENTIFIED BY '$MON_PASS';
GRANT SELECT, PROCESS, REPLICATION CLIENT, SHOW VIEW ON *.* TO '$MON_USER'@'%';
SQL
}
seed() {  # NAME
    say "$1: seeding (users, schema, $2 load rounds)"
    { users_sql
      [ "$1" = "$PRIMARY" ] && echo "CREATE USER IF NOT EXISTS '$REPL_USER'@'%' IDENTIFIED BY '$REPL_PASS'; GRANT REPLICATION SLAVE ON *.* TO '$REPL_USER'@'%';"
      cat "$FIX_DIR/seed.sql"
      bash "$FIX_DIR/load.sql.sh" "$2"
      echo "CREATE DATABASE ggt_lab; CREATE TABLE ggt_lab.meta (k VARCHAR(32) PRIMARY KEY, v VARCHAR(64)); INSERT INTO ggt_lab.meta VALUES ('seeded', NOW());"
    } | root_sql "$1" || die "$1: seed failed"
}
seeded "$PRIMARY" || seed "$PRIMARY" 3000
seeded "$M57"     || seed "$M57" 3000

# replica: GTID auto-position from the primary (it replays the seed itself)
if [ -z "$(echo 'SHOW REPLICA STATUS' | root_sql "$REPLICA")" ]; then
    say "$REPLICA: configuring replication from $PRIMARY"
    echo "CHANGE REPLICATION SOURCE TO SOURCE_HOST='$PRIMARY', SOURCE_PORT=3306, SOURCE_USER='$REPL_USER', SOURCE_PASSWORD='$REPL_PASS', SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1; START REPLICA;" \
        | root_sql "$REPLICA" || die "replica setup"
fi
for _ in $(seq 1 60); do seeded "$REPLICA" && break; sleep 2; done
seeded "$REPLICA" || say "WARNING: replica has not caught up yet"
docker exec "$REPLICA" mysql -e 'SHOW REPLICA STATUS\G' | grep -E 'Replica_(IO|SQL)_Running:|Seconds_Behind|Last_(IO|SQL)_Error:' >&2
docker ps --filter name=jjsong-ggt-mysql- --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' >&2
