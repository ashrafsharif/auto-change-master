# Auto Change Master

This script will automate the `CHANGE MASTER` statement to resume the replication to another master if the existing replication is broken, suitable to run on a Galera-to-Galera replication over standard asynchronous replication.

Generally, the script performs the following procedures:

1) Monitors the output of `SHOW SLAVE STATUS` and verify if replication is healthy every `INTERVAL`.
2) If replication is healthy, create the `FLAGFILE`.
3) If replication is broken, remove the `FLAGFILE`.
4) Try to connect to the current master and see its status every `FAIL_INTERVAL` for `RETRIES` times.
5) If still fails, it will check other masters in the list by using the `SQL_CHECK` statement.
6) If one of the other masters is healthy, it will initiate failover by running `CHANGE MASTER TO MASTER_HOST={IP_ADDRESS_MASTER}`
7) Verify the replication state of by executing step 1.

# Requirements

The script has been tested under the following conditions:

* 2 x MariaDB 10.4 Galera (master cluster and slave cluster).
* MariaDB replication is using GTID.
* Replication username and password are identical for all nodes in the cluster.
* Intra-cluster values for `server_id`, `wsrep_gtid_domain_id` and `gtid_domain_id` are identical, while inter-cluster values are different.

The GTID-related settings are:

Cluster A (master cluster):

```bash
log_bin = binlog
log_slave_updates = 1
server_id = 100
gtid_domain_id = 100
gtid_strict_mode = ON
gtid_ignore_duplicates = ON
wsrep_gtid_domain_id = 100
wsrep_gtid_mode = ON
```

Cluster B (slave cluster):

```bash
log_bin = binlog
log_slave_updates = 1
server_id = 200
gtid_domain_id = 200
gtid_strict_mode = ON
gtid_ignore_duplicates = ON
wsrep_gtid_domain_id = 200
wsrep_gtid_mode = ON
```

# Usage

The script should be running on the slave node. In the following example architecture, the script should be running on `DB 6`:

```
        DC A                                   DC B
(Master Galera cluster)               (Slave Galera cluster)

     +--------+                             +--------+
     |  DB 1  |                             |  DB 4  |
     +--------+                             +--------+
         |                                      |
     +--------+                             +--------+
     |  DB 2  |                             |  DB 5  |
     +--------+                             +--------+
         |                                      |
     +--------+                             +--------+
     |  DB 3  | -----async replication----> |  DB 6  |
     +--------+                             +--------+
```

In this example, `DB 6` (slave) should be replicating from `DB 3` (master). In case if `DB 3` (master) goes down or unreachable, the script will perform failover to `DB 1` or `DB 2`, depending on the availability, and the next in the list.

## Create database user

For performance matters, this script requires two database users with SUPER privileges (so it can perform replication health check and run `CHANGE MASTER` statement) - One for localhost via socket and one for TCP/IP connection. Therefore, create two user-host as below:

```
MariaDB> CREATE USER 'replication_checker'@'localhost' IDENTIFIED BY 'checkerpassword';
MariaDB> GRANT SUPER ON *.* TO 'replication_checker'@'localhost';
MariaDB> CREATE USER 'replication_checker'@'192.168.10.%' IDENTIFIED BY 'checkerpassword';
MariaDB> GRANT SUPER ON *.* TO 'replication_checker'@'192.168.10.%';
```

** We created two users with same username but different hosts (localhost = socket while 192.168.10.% = pattern matching for all IP under 192.168.10.0/24 network).

## Running as script

To run the script in the foreground, do:

```bash
./auto_change_master.sh 192.168.10.101,192.168.10.102,192.168.10.103
```
Where, `192.168.10.101,192.168.10.102,192.168.10.103` is the comma-delimited list of nodes in the master cluster that potentially can become a master for this node. If 192.168.10.101 goes down, this script will automatically perform the `CHANGE MASTER` to the next master inline, 192.168.10.102 and so on.

## Running as daemon

To daemonize the script and run it in the background, you could use `supervisord` or just run the command as the following:

```bash
nohup ./auto_change_master.sh 192.168.10.101,192.168.10.102,192.168.10.103 &
```

## Example Output

Example output from `/var/log/auto_change_master.log`:

```
[Thu Jul 30 03:11:18 UTC 2020] ------------------------------------
[Thu Jul 30 03:11:18 UTC 2020] Starting auto_change_master daemon..
[Thu Jul 30 03:11:18 UTC 2020] ------------------------------------
[Thu Jul 30 03:11:18 UTC 2020] Loaded configurations:
[Thu Jul 30 03:11:18 UTC 2020]   AUTO_FAILOVER            = 1
[Thu Jul 30 03:11:18 UTC 2020]   NUMBER_OF_RETRY_IF_FAIL  = 3
[Thu Jul 30 03:11:18 UTC 2020]   CHECK_INTERVAL           = every 10 seconds
[Thu Jul 30 03:11:18 UTC 2020]   RETRY_IF_FAIL_INTERVAL   = every 3 seconds
[Thu Jul 30 03:11:18 UTC 2020] Replication is healthy. Will report if I find any anomaly.
[Thu Jul 30 03:11:18 UTC 2020] Creating flag file to indicate replication is OK.
[Thu Jul 30 03:11:58 UTC 2020] Replication is NOT healthy. Removing flag file /var/run/auto_change_master to trigger failover.
[Thu Jul 30 03:11:58 UTC 2020] Check if the current master [192.168.10.101] is responding..
[Thu Jul 30 03:12:00 UTC 2020] Looks like 192.168.10.101 is not alive or unhealthy.
[Thu Jul 30 03:12:00 UTC 2020] Attempt #1: Master is not responding. Will retry in 3 seconds..
[Thu Jul 30 03:12:05 UTC 2020] Looks like 192.168.10.101 is not alive or unhealthy.
[Thu Jul 30 03:12:05 UTC 2020] Attempt #2: Master is not responding. Will retry in 3 seconds..
[Thu Jul 30 03:12:10 UTC 2020] Looks like 192.168.10.101 is not alive or unhealthy.
[Thu Jul 30 03:12:10 UTC 2020] Attempt #3: Master is not responding. Will retry in 3 seconds..
[Thu Jul 30 03:12:13 UTC 2020] Maximum retries reached.
[Thu Jul 30 03:12:13 UTC 2020] >> Failover is needed. <<
[Thu Jul 30 03:12:13 UTC 2020] AUTO_FAILOVER is set to 1. Proceed to initiate failover to a new master now.
[Thu Jul 30 03:12:13 UTC 2020] Initiating failover to a new master
[Thu Jul 30 03:12:13 UTC 2020] List of potential masters: 192.168.10.101 192.168.10.102 192.168.10.103
[Thu Jul 30 03:12:13 UTC 2020] Suspected problematic master is 192.168.10.101
[Thu Jul 30 03:12:13 UTC 2020] Looks like 192.168.10.102 is alive and healthy.
[Thu Jul 30 03:12:13 UTC 2020] Will use 192.168.10.102 as the new master
[Thu Jul 30 03:12:13 UTC 2020] Stopping slave on this server.
[Thu Jul 30 03:12:13 UTC 2020] Changing master to the new master: 192.168.10.102
[Thu Jul 30 03:12:13 UTC 2020] Starting replication with START SLAVE statement
[Thu Jul 30 03:12:17 UTC 2020] Change master succeeded.
[Thu Jul 30 03:12:27 UTC 2020] Replication is healthy. Will report if I find any anomaly.
[Thu Jul 30 03:12:27 UTC 2020] Creating flag file to indicate replication is OK.
```

# Configuration Options

The configuration options are defined in the script until line 26.

* ``FLAGFILE=/var/run/auto_change_master`` - Path to the flag file where the script will create to determine if the replication is healthy. If replication is broken, this file will be removed to indicate replication is not healthy and triggers failover.

* ``LOGFILE=/var/log/auto_change_master.log`` - Path to the log file of this script.

* ``INTERVAL=10`` - Check interval for the script in seconds. It will loop every this value to check the output of `SHOW SLAVE STATUS` and verify if replication is healthy.

* ``RETRIES=3`` - The number of retries to check whether the current master is indeed unhealthy.

* ``FAIL_INTERVAL=3`` - The number of seconds between every retry.

* ``AUTO_FAILOVER=1`` - Set 1 to allow automatic failover. Set to 0 to deactivate failover. If deactivated, the script will detect if replication is broken but will do nothing against it.
