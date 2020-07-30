#!/bin/bash
# Automatically perform change master if the current master fails
# nohup ./auto_change_master.sh 192.168.10.101,192.168.10.102,192.168.10.103 &
#

## Database user ##
# The database user to perform healthcheck and change master. It must have SUPER privileges.
# Examples:
# CREATE USER 'replication_checker'@'localhost' IDENTIFIED BY 'checkerpassword';
# GRANT SUPER ON *.* TO 'replication_checker'@'localhost';
# CREATE USER 'replication_checker'@'192.168.10.%' IDENTIFIED BY 'checkerpassword';
# GRANT SUPER ON *.* TO 'replication_checker'@'192.168.10.%';
#
DBUSER='replication_checker'
DBPASS='checkerpassword'
DBSOCK='/var/lib/mysql/mysql.sock'
DBPORT=3306

## Variables ##
FLAGFILE=/var/run/auto_change_master
LOGFILE=/var/log/auto_change_master.log
RETRIES=3
INTERVAL=10
FAIL_INTERVAL=3
AUTO_FAILOVER=1

if [ -z $1 ]; then
	echo 'Please specify a comma-delimited list of potential masters'
	echo 'Example: auto_change_master.sh 192.168.10.101,192.168.10.102,192.168.10.103'
	exit 1
else
	MASTER_SERVERS=$1
fi

LOCAL_MYSQL_COMMAND="mysql -u${DBUSER} -p${DBPASS} -S ${DBSOCK} --connect-timeout=2 -A -Bse "
REMOTE_MYSQL_COMMAND="mysql -u${DBUSER} -p${DBPASS} --connect-timeout=2 "

[ -f $LOGFILE ] || touch $LOGFILE

function logging() {
	local message=$1
	echo "[$(date)] $message" >> $LOGFILE
}

function check_master_alive() {
	master_host=$1

	SQL_CHECK='SHOW STATUS LIKE "wsrep_local_state"'
	RESULT='4'

	result=$($REMOTE_MYSQL_COMMAND -h$master_host -A -Bse "$SQL_CHECK" | awk {'print $2'})
	if [ ${result} == ${RESULT} ]; then
		logging "Looks like $master_host is alive and healthy."
		return 0
	else
		logging "Looks like $master_host is not alive or unhealthy."
		return 1
	fi
}

function change_master() {
	local master_host=$1

	logging "Stopping slave on this server."
	$LOCAL_MYSQL_COMMAND "STOP SLAVE"

	if [ $? -eq 0 ]; then
		logging "Changing master to the new master: $master_host"
		$LOCAL_MYSQL_COMMAND "CHANGE MASTER TO MASTER_HOST = '$master_host'"
	 	if [ $? -eq 0 ]; then
			logging "Starting replication with START SLAVE statement"
			$LOCAL_MYSQL_COMMAND "START SLAVE"
			if [ $? -eq 0 ]; then
				sleep 3
				yes=$(${LOCAL_MYSQL_COMMAND} 'SHOW SLAVE STATUS\G' | grep -E 'Slave_.*_Running:' | awk {'print $2'} | grep 'Yes' | wc -l)
				if [ $yes -eq 2 ]; then
					logging "Change master succeeded."
					return 0
				else
					logging "Change master failed. Replication doesn't seem to work. Check the slave error log."
					replication_output=${LOCAL_MYSQL_COMMAND} 'SHOW SLAVE STATUS\G'
					logging $replication_output
					return 1
				fi
			else
				logging "Unable to run START SLAVE statement."
				return 1
			fi
		else
			logging "Unable to perform CHANGE MASTER statement."
			return 1
		fi
	else
		logging "Unable to perform STOP SLAVE statement."
		return 1
	fi
}

function inititiate_failover(){

	SERVERS=$(echo $MASTER_SERVERS | sed 's/,/ /g')

	logging "Initiating failover to a new master"
	logging "List of potential masters: $SERVERS"
	logging "Suspected problematic master is $CURRENT_MASTER"

	POTENTIAL_MASTERS=$(echo $SERVERS | sed "s/$CURRENT_MASTER//g")
	for s in $POTENTIAL_MASTERS; do
 		check_master_alive $s
		if [ $? -eq 0 ]; then
			logging "Will use $s as the new master"
			change_master $s
			break
		else
      			continue
		fi
	done
}

STATE=OK
logging "------------------------------------"
logging "Starting auto_change_master daemon.."
logging "------------------------------------"
logging "Loaded configurations:"
logging "  AUTO_FAILOVER            = $AUTO_FAILOVER"
logging "  NUMBER_OF_RETRY_IF_FAIL  = $RETRIES"
logging "  CHECK_INTERVAL           = every $INTERVAL seconds"
logging "  RETRY_IF_FAIL_INTERVAL   = every $FAIL_INTERVAL seconds"
while true; do
	YES=$(${LOCAL_MYSQL_COMMAND} 'SHOW SLAVE STATUS\G' | grep -E 'Slave_.*_Running:' | awk {'print $2'} | grep 'Yes' | wc -l)
	echo "YES: $YES"

	if [ $YES -eq 2 ]; then
		# Replication is OK
		if [ ! -e $FLAGFILE ]; then
			logging "Replication is healthy. Will report if I find any anomaly."
			logging "Creating flag file to indicate replication is OK."
			[ -e $FLAGFILE ] || touch $FLAGFILE
		fi

	else
		logging "Replication is NOT healthy. Removing flag file $FLAGFILE to trigger failover."
		rm -f $FLAGFILE
	fi


	if [ ! -e $FLAGFILE ]; then
		# Replication is NOT OK. Do something
		rm -f $FLAGFILE
		CURRENT_MASTER=$(${LOCAL_MYSQL_COMMAND} 'SHOW SLAVE STATUS\G' | grep 'Master_Host' | awk {'print $2'})
		if [ -z $CURRENT_MASTER ]; then
			logging "Unable to detect master."
		else
			logging "Check if the current master [$CURRENT_MASTER] is responding.."

			for (( i=1; i<=$RETRIES; i++ )); do
		 		check_master_alive $CURRENT_MASTER

				if [ $? -ne 0 ]; then
					logging "Attempt #${i}: Master is not responding. Will retry in $FAIL_INTERVAL seconds.."
					sleep $FAIL_INTERVAL
					STATE=Failover
					if [ $i -ne $RETRIES ]; then
						continue
					else
						logging "Maximum retries reached."
						break
					fi
				else
					logging "Attempt #${i}: Master is responding. Do nothing."
					STATE=OK
					break
				fi
			done
		fi

		if [ $STATE == 'Failover' ]; then
			logging ">> Failover is needed. <<"
			if [ $AUTO_FAILOVER -eq 1 ]; then
				logging "AUTO_FAILOVER is set to 1. Proceed to initiate failover to a new master now."
				inititiate_failover
			else
				logging "AUTO_FAILOVER is set to 0. I will do nothing."
			fi

			if [ $? -ne 0 ]; then
				logging "Failover failed. You have to perform CHANGE MASTER statement manually on this slave."
				logging 'Suggested command: CHANGE MASTER TO MASTER_HOST = {THE_MASTER_IP};'
			fi
		else
				logging "Unknown state."
 		fi
 	fi
	sleep $INTERVAL
done
