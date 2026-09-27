#!/bin/bash
# load.sql.sh N -> SQL on stdout: N scheduler-like rounds (shedlock updates,
# metering upserts, audit and event inserts, an event cleanup), so the binary
# logs carry row events for section I to attribute. Sourced by up.sh / load.sh.
n="${1:-300}"
echo "INSERT IGNORE INTO account.Account (id,email,name) VALUES (1,'a1@example.test','acct1'),(2,'a2@example.test','acct2');"
echo "INSERT IGNORE INTO account.Project (pcode,account_id,name,platform) VALUES (1001,1,'p1','JAVA'),(1002,1,'p2','NODE'),(1003,2,'p3','PY');"
for i in $(seq 1 "$n"); do
  p=$((1001 + i % 3))
  echo "UPDATE account.shedlock SET lock_until=NOW(3)+INTERVAL 30 SECOND, locked_at=NOW(3) WHERE name='MeteringScheduler.hourly';"
  echo "UPDATE notihub.shedlock SET lock_until=NOW(3)+INTERVAL 5 SECOND, locked_at=NOW(3) WHERE name='deleteReserveEvent';"
  echo "INSERT INTO account.MeteringDaily (pcode,day,agents,txcount) VALUES ($p,CURDATE(),$((i%7)),$i) ON DUPLICATE KEY UPDATE txcount=txcount+1, agents=VALUES(agents);"
  echo "INSERT IGNORE INTO account.MeteringHourly (pcode,hour,agents) VALUES ($p, DATE_FORMAT(NOW(),'%Y-%m-%d %H:00:00') - INTERVAL $((i%48)) HOUR, $((i%5)));"
  echo "INSERT INTO notihub.monitor_event (pcode,level,title) VALUES ($p,'WARN','cpu high $i');"
  echo "INSERT INTO notihub.ReserveEvent (pcode,fire_at,payload) VALUES ($p, NOW()+INTERVAL 1 HOUR, 'r$i');"
  [ $((i % 10)) = 0 ] && echo "DELETE FROM notihub.ReserveEvent WHERE id < (SELECT m FROM (SELECT MAX(id)-20 m FROM notihub.ReserveEvent) t);"
  [ $((i % 25)) = 0 ] && echo "INSERT INTO account.AuditLog (account_id,action,detail) VALUES (1,'login','round $i');"
  [ $((i % 100)) = 0 ] && echo "INSERT INTO account.DeniedIPAddress (pcode,ip,reason) VALUES ($p,'10.0.$((i/100)).1','test');"
done
