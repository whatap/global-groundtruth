-- A WhaTap-like backend schema: account and notihub metadata, with the table
-- names section F looks for (lock / meter / event / audit, DeniedIPAddress,
-- ApmRegion). Table and column shapes are made up except shedlock, which is
-- ShedLock's JdbcTemplateLockProvider table. No credentials in this file.
CREATE DATABASE IF NOT EXISTS account;
CREATE DATABASE IF NOT EXISTS notihub;

CREATE TABLE account.shedlock (
  name VARCHAR(64) NOT NULL PRIMARY KEY,
  lock_until TIMESTAMP(3) NOT NULL,
  locked_at  TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  locked_by  VARCHAR(255) NOT NULL
) ENGINE=InnoDB;
CREATE TABLE account.Account (
  id BIGINT AUTO_INCREMENT PRIMARY KEY, email VARCHAR(128) NOT NULL,
  name VARCHAR(64), created_at DATETIME DEFAULT CURRENT_TIMESTAMP, KEY (email)
) ENGINE=InnoDB;
CREATE TABLE account.Project (
  pcode BIGINT PRIMARY KEY, account_id BIGINT NOT NULL, name VARCHAR(64),
  platform VARCHAR(16), created_at DATETIME DEFAULT CURRENT_TIMESTAMP, KEY (account_id)
) ENGINE=InnoDB;
CREATE TABLE account.DeniedIPAddress (
  id BIGINT AUTO_INCREMENT PRIMARY KEY, pcode BIGINT NOT NULL, ip VARCHAR(45) NOT NULL,
  reason VARCHAR(128), created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;
CREATE TABLE account.ApmRegion (
  code VARCHAR(16) PRIMARY KEY, name VARCHAR(64), endpoint VARCHAR(128)
) ENGINE=InnoDB;
CREATE TABLE account.MeteringDaily (
  pcode BIGINT NOT NULL, day DATE NOT NULL, agents INT, txcount BIGINT,
  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (pcode, day)
) ENGINE=InnoDB;
CREATE TABLE account.MeteringHourly (
  pcode BIGINT NOT NULL, hour DATETIME NOT NULL, agents INT,
  PRIMARY KEY (pcode, hour)
) ENGINE=InnoDB;
CREATE TABLE account.AuditLog (
  id BIGINT AUTO_INCREMENT PRIMARY KEY, account_id BIGINT, action VARCHAR(64),
  detail VARCHAR(255), created_at DATETIME DEFAULT CURRENT_TIMESTAMP, KEY (created_at)
) ENGINE=InnoDB;
CREATE TABLE notihub.shedlock LIKE account.shedlock;
CREATE TABLE notihub.monitor_event (
  id BIGINT AUTO_INCREMENT PRIMARY KEY, pcode BIGINT, level VARCHAR(8), title VARCHAR(128),
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP, KEY (created_at)
) ENGINE=InnoDB;
CREATE TABLE notihub.ReserveEvent (
  id BIGINT AUTO_INCREMENT PRIMARY KEY, pcode BIGINT, fire_at DATETIME, payload VARCHAR(255)
) ENGINE=InnoDB;

INSERT INTO account.ApmRegion VALUES ('id-jkt','Jakarta','https://jkt.example'),('kr-sel','Seoul','https://sel.example');
INSERT INTO account.shedlock (name, lock_until, locked_by) VALUES
  ('MeteringScheduler.daily', NOW(3), 'web02'), ('MeteringScheduler.hourly', NOW(3), 'web02'),
  ('AccountCleaner', NOW(3), 'web02');
INSERT INTO notihub.shedlock (name, lock_until, locked_by) VALUES
  ('deleteReserveEvent', NOW(3), 'web02'), ('clean_event', NOW(3), 'web02');
