# shellcheck shell=bash disable=SC2034  # the variables are read by run.sh
# Mock WhaTap DBX-agent host: eclipse-temurin:8-jdk (JDK 8, so the JDBC
# runner in collect-db.sh falls back to jrunscript/Nashorn, never jshell),
# a long-running java process whose cmdline names whatap.agent.dbx (so
# _kind_of_proc counts it), two agent instances under its cwd
# (/opt/whatap-dbx/pg, /opt/whatap-dbx/mysql) each with a whatap.conf
# pointing at a real, permanent lab DB (jjsong-ggt-postgres, TLS on;
# jjsong-ggt-mysql-primary), plus jdbc/postgresql*.jar and
# jdbc/mysql-connector*.jar fetched at image build time. See
# tools/lab/README.md and ~/.claude/lab-environment.md.
DESC="JDK 8 DBX-agent host (mock), JDBC runner over jrunscript against jjsong-ggt-postgres + jjsong-ggt-mysql-primary"
COLLECTORS="db/collect-db.sh"
docker_target jjsong-ggt-db-agent jjsong-ggt-db-agent:1 --network jjsong-ggt-dbnet
# WHATAP_GGT_USER/PW are left empty by default (no secret in this repo): the
# "sql" argset then just reports "no credentials" for both instances, which
# is a real, valid collect-db.sh outcome, not a failure. Export
# GGT_DBAGENT_PG_USER/PW (or _MYSQL_) before running the lab to exercise the
# JDBC pack for real; credentials live in ~/.claude/lab-secrets/, never here.
ARGSETS=(
    "help|0|bash -s||--help"
    "badarg|0|bash -s||--no-such-arg"
    "default|0|bash -s||--stdout"
    "sql|0|bash -s|WHATAP_GGT_USER=${GGT_DBAGENT_PG_USER:-} WHATAP_GGT_PW=${GGT_DBAGENT_PG_PW:-}|--stdout --sql"
)
t_health() { t_sh 0 'pgrep -f whatap.agent.dbx-mock.jar >/dev/null && echo "dbx mock running"'; }
CHECKS=(
    "collect-db|default|whatap component processes: dbx=1"
    "collect-db|default|agent instances \\(dir with whatap\\.conf\\): 2"
    "collect-db|default|db reachability: tcp connect to jjsong-ggt-postgres:5432 succeeded"
    "collect-db|default|db reachability: tcp connect to jjsong-ggt-mysql-primary:3306 succeeded"
    "collect-db|default|New, TLSv1\\.3, Cipher is"
    "collect-db|sql|runner: jrunscript from"
)
