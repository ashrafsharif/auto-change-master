# Auto Change Master

This script will automate the `CHANGE MASTER` statement to failover a slave to another master if the existing replication breaks, suitable to run on a Galera-to-Galera replication over standard asynchronous replication.

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
* 2 x MariaDB 10.4 Galera (master cluster and slave cluster)
* MariaDB replication is using GTID.
* Replication username and password are the same for all nodes in the cluster.
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

The script should be running on the slave node. In the following example architecture, the script should be running on node `DB 6`:

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

In this example, `DB 6` (slave) should be replicating from `DB 3` (master). In case if `DB 3` goes down or unreachable, the script will perform failover to `DB 1` or `DB 2`, depending on the availability, and the next in the list.

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

# Configuration Options

The configuration options are defined in the script until line 26.

* ``FLAGFILE=/var/run/auto_change_master`` - Path to the flag file where the script will create to determine if the replication is healthy. If replication is broken, this file will be removed to indicate replication is not healthy and trigger failover.

* ``LOGFILE=/var/log/auto_change_master.log`` - Path the log file of this script.

* ``RETRIES=3`` - The number of retries to check whether the current master is indeed unhealthy.

* ``INTERVAL=10`` - Check interval for the script in seconds. It will loop every this value to check the output of `SHOW SLAVE STATUS` and verify if replication is healthy.

* ``FAIL_INTERVAL=3`` - The number of seconds for every retry if replication is unhealthy.

* ``AUTO_FAILOVER=1`` - Set to 1 to allow automatic failover. Set to 0 to deactivate failover. If failover is deactivated, the script will do nothing if the replication is broken.
