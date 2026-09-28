# Mock WhaTap DBX-agent host, JDK 8 (Nashorn jrunscript) path of
# collectors/db/collect-db.sh's JDBC runner. No real DBX agent jar is
# needed for the runner (it only needs java + a driver jar + whatap.conf) —
# see tools/lab/README.md and ~/.claude/lab-environment.md.
FROM eclipse-temurin:8-jdk

# a tiny long-running "agent" whose cmdline names whatap.agent.dbx, so
# collect-db.sh's process scan (_kind_of_proc) counts it as a dbx component
# and its cwd becomes the discovered install dir.
RUN mkdir -p /src && \
    printf '%s\n' \
      'public class Mock {' \
      '  public static void main(String[] a) throws Exception {' \
      '    while (true) { Thread.sleep(3600000); }' \
      '  }' \
      '}' > /src/Mock.java && \
    javac -d /src /src/Mock.java && \
    mkdir -p /opt/whatap-dbx/jdbc /opt/whatap-dbx/pg /opt/whatap-dbx/mysql && \
    cd /src && jar cfe /opt/whatap-dbx/whatap.agent.dbx-mock.jar Mock Mock.class && \
    rm -rf /src

# the proven drivers a real DBX install carries in jdbc/ (rule: cheapest
# equivalent source — fetched at build time, not vendored in this repo)
ADD https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.4/postgresql-42.7.4.jar /opt/whatap-dbx/jdbc/postgresql-42.7.4.jar
ADD https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/8.4.0/mysql-connector-j-8.4.0.jar /opt/whatap-dbx/jdbc/mysql-connector-j-8.4.0.jar

COPY whatap.conf.pg /opt/whatap-dbx/pg/whatap.conf
COPY whatap.conf.mysql /opt/whatap-dbx/mysql/whatap.conf

WORKDIR /opt/whatap-dbx
CMD ["java", "-jar", "/opt/whatap-dbx/whatap.agent.dbx-mock.jar"]
