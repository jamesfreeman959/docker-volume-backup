#!/bin/bash
#
# This script backs up a list of VMs using Borg Backup.
# An overview of the process is as follows:
# * invokes a "snapshot" which transfers VM disk I/O to new "snapshot" image file(s).
# * Use borg to backup the VM's image file(s)
# * invoke a "blockcommit" which merges (or "pivots") the snapshot image back
#   to the VM's primary image file(s)
# * delete the snapshot image file(s)
# * make a copy of the VM define/XML file
#
# If the process fails part way through the snapshot, copy, or blockcommit,
# the VM may be left running on the snapshot file which is Not desirable.
#
# Note: Paths and the virtual domains cannot contain spaces
#
# Doesn't work with Borg 1.1.5 (available from Ubuntu 18.04 repos) - tested with 1.1.11 from Ubuntu PPA
#
# Original source: https://gist.github.com/cabal95/e36c06e716d3328b512b
#
# Getting started:
# 1. Set parameters below
# 2. The script will fail on first run if the SSH host key is not accepted, so you will need to SSH in manually and accept the key (TO DO: Fix?)

source env.sh

# Define email recipient
#EMAIL_RECIPIENT=""

#HOST="$(hostname)"
SHCMD="$(basename -- $0)"
LOGS_DIR=$LOGS_DIR
DATE="$(date +%Y%m%d_%H%M)"
LOG="$LOGS_DIR/$BACKUP_FILENAME.$DATE.log"
ERRORED=0
BREAK=false
SRC_PATHS="$BACKUP_SOURCES"
#SRC_PATHS="/etc"

# Send summary email at the end of the backup?
EMAIL_SUMMARY="no"

# Output borg summary at end of backup?
END_SUMMARY="yes"

# How many days to keep logs and qemu.xml files.
KEEP_FILES_FOR="14"

# Should ionice and nice be used when creating backups?
BE_NICE="yes"

# Borg environment varibles
#export BORG_SSH_SERVER='borg-backup@nas.example.net'
#export BORG_SSH_SERVER="$BORG_SSH_SERVER"
#export BORG_REPO='/zfsdata1/borgbackuprepo'
#export BORG_REPO="ssh://$BORG_SSH_SERVER/volume1/BorgBackupRepo"
#BORG_LOCAL_PATH=""
BORG_REPO="ssh://${BORG_SSH_SERVER}${BORG_LOCAL_PATH}"
BORG_ARCHIVE_FOLDER=$BORG_REPO/$BACKUP_FILENAME

#export BORG_RSH='ssh -i /home/user/.ssh/id_ed25519 -o BatchMode=yes -o VerifyHostKeyDNS=yes'
#export BORG_RSH="ssh -p {{ backup_ssh_port }} -i /root/vpsra-id_rsa -o BatchMode=yes"
# See https://borgbackup.readthedocs.io/en/stable/faq.html#it-always-chunks-all-my-files-even-unchanged-ones
#export BORG_FILES_CACHE_TTL='100'

# Global Borg options for all operations
#BORG_GLOBAL_OPTIONS="--remote-path /mnt/datastore1a/freenas-tools/borg-freebsd64"
#BORG_GLOBAL_OPTIONS="--remote-path /usr/bin/borg"

# Borg create options
# Note: ZFS and BTRFS should use native compression.  
#	ionice and nice is used with the borg create command.
#BORG_CREATE_OPTIONS="--compression lz4 --list --filter AME --stats --files-cache=mtime,size --noctime --noatime"

#BORG_EXCLUDE_OPTIONS="--exclude '*/.cache'"

# Borg init options
#export BORG_PASSPHRASE="{{ borg_passphrase }}"
#BORG_INIT_OPTIONS="--make-parent-dirs --encryption=repokey-blake2"

# How long to keep borg archives
# --keep-hourly=24 --keep-daily=14 --keep-weekly=4 --keep-monthly=2"
# --keep-within=14d
#BORG_PRUNE_OPTIONS="-v --list --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --keep-yearly 1"

# Borg mtime touch file
# See: https://borgbackup.readthedocs.io/en/stable/faq.html#i-am-seeing-a-added-status-for-an-unchanged-file
BORG_MTIME_FILE="/root/borg_touch_mtime.txt"

# How often to perform full check on borg repositories.
# Day of the week to perform the full checK.  Use full weekday name (date %A).
CHECK_DOW="Friday"
# Which week in the month to perform the full check.  Put any number(s) 1-5.
CHECK_WEEKS="12345"
# Send email of check results?
EMAIL_CHECK_RESULTS="yes"
# Borg check options
BORG_CHECK_OPTIONS=""

##################  End Configuration Options  ##################

# Create directories if they are missing
[ ! -f $LOGS_DIR ] && mkdir -p $LOGS_DIR

# Check for $BE_NICE and set options
[ "$BE_NICE" = "yes" ] && NICE_OPTIONS="ionice -c2 -n7 nice -n19"

# Create summary temp file if required
[ "$EMAIL_SUMMARY" = "yes" -o "$END_SUMMARY" = "yes" ] && SUMMARY_FILE="$(mktemp /tmp/summary_XXXXXXX)"

# Check to see if the borg repo is using ssh and test connection.
echo "$BORG_REPO" | grep "ssh://" > /dev/null
RETVAL=$?
if [ "$RETVAL" -eq "0" -a "$BORG_SSH_SERVER" != "" ] 
then
	if [ "$BORG_RSH" == "" ]
	then
		ssh -oBatchMode=yes $BORG_SSH_SERVER ls > /dev/null 2>&1
		if [ "$?" -ne "0" ]
		then
			ERR="$SHCMD: Error!  Cannot connect to $BORG_SSH_SERVER with SSH key."
			echo $ERR >> $LOG
			echo "$ERR
Host:       $HOST
Command:    ssh -oBatchMode=yes $BORG_SSH_SERVER ls" | mail -s "$SHCMD ssh connection failed" $EMAIL_RECIPIENT
			echo $ERR
			exit 1
		fi
	else
		$BORG_RSH $BORG_SSH_SERVER ls > /dev/null 2>&1
	        if [ "$?" -ne "0" ]
        	then
                	ERR="$SHCMD: Error!  Cannot connect to $BORG_SSH_SERVER with SSH key."
	                echo $ERR >> $LOG
        	        echo "$ERR
Host:       $HOST
Command:    ssh -oBatchMode=yes $BORG_SSH_SERVER ls" | mail -s "$SHCMD ssh connection failed" $EMAIL_RECIPIENT
	        echo $ERR
        	exit 1
        	fi
	fi
fi

DAY_OF_WEEK="$(date +'%A')"
WEEK_IN_MONTH=$(echo $((($(date +%-d)-1)/7+1)))

echo "$SHCMD: Starting backups on $(date +'%d-%m-%Y %H:%M:%S')"  >> $LOG

# Check borg respositories if day of week and week in month match options.
echo $CHECK_WEEKS | grep -q $WEEK_IN_MONTH && CURRENT_WEEK="true"
if [ "$DAY_OF_WEEK" = "$CHECK_DOW" -a "$CURRENT_WEEK" = "true" ] 
then
	CHECK_RESULTS_FILE="$(mktemp /tmp/check_results_XXXXXXX)"
	echo -e "Perform full check of borg repositories\n" > $CHECK_RESULTS_FILE
	borg info $BORG_GLOBAL_OPTIONS $BORG_REPO/$BACKUP_FILENAME > /dev/null
	if [ "$?" -eq "0" ]
	then
		echo "Checking borg repository $BORG_REPO/$BACKUP_FILENAME:" >> $CHECK_RESULTS_FILE
		borg --verbose check $BORG_GLOBAL_OPTIONS $BORG_CHECK_OPTIONS $BORG_REPO/$BACKUP_FILENAME >> $CHECK_RESULTS_FILE 2>&1
		if [ "$?" -ne "0" ]
		then
			echo "Errors found in $BORG_REPO/$BACKUP_FILENAME repository!" >> $CHECK_RESULTS_FILE
			echo "Manual intervention is required." >> $CHECK_RESULTS_FILE
			REPOSITORY_ERRORS="true"
		fi
	fi
	
	if [ "$REPOSITORY_ERRORS" = "true" ]
	then
        echo -e "Borg repository errors found:\n\n
Host: $HOST

$(cat $CHECK_RESULTS_FILE)" | mail -s "Borg Repository Errors Found for $HOST" $EMAIL_RECIPIENT
	fi
	if [ "$EMAIL_CHECK_RESULTS" = "yes" -a "$REPOSITORY_ERRORS" != "true" ]
	then
        echo -e "Borg repository check results:\n\n
Host:       $HOST

$(cat $CHECK_RESULTS_FILE)" | mail -s "Borg Repository Check Results for $HOST" $EMAIL_RECIPIENT
	fi
fi



#        BREAK=false

        echo "---- Local Machine Backup start $DOMAIN ---- $(date +'%d-%m-%Y %H:%M:%S')"  >> $LOG

		if [ "$BORG_RSH" == "" ]
		then
        	[ ! -d $BORG_LOCAL_PATH ] && mkdir -p $BORG_LOCAL_PATH
		else
			$BORG_RSH $BORG_SSH_SERVER "[ ! -d $BORG_LOCAL_PATH ] && mkdir -p $BORG_LOCAL_PATH" > /dev/null 2>&1
		fi
        # check to make sure the VM is running on a standard image, not
        # a snapshot that may be from a backup that previously failed

        # Use borg to backup the VM's disk image(s)
	if [ "$SRC_PATHS" != "" ]
	then
		echo -e "\nUsing borg to backup $SRC_PATHS to $BORG_ARCHIVE_FOLDER" >> $LOG
		# Check to see if the borg repo exists and if not, create it.
		echo -e "\nChecking to see if the borg $BORG_ARCHIVE_FOLDER repository exists using borg info..." >> $LOG
		CMD="borg info $BORG_GLOBAL_OPTIONS $BORG_ARCHIVE_FOLDER >> $LOG  2>&1"
		echo "Command: $CMD" | sed 's/BORG_PASSPHRASE=\S*/BORG_PASSPHRASE=xxxxxxxx/g' >> $LOG
		eval "$CMD"
		if [ "$?" -ne "0" ]
		then
			echo -e "\nBorg Repository does not exist.  Creating $BORG_ARCHIVE_FOLDER" >> $LOG
			CMD="borg init $BORG_GLOBAL_OPTIONS $BORG_INIT_OPTIONS $BORG_ARCHIVE_FOLDER >> $LOG 2>&1"
			echo "Command: $CMD"  | sed 's/BORG_PASSPHRASE=\S*/BORG_PASSPHRASE=xxxxxxxx/g' >> $LOG
			eval "$CMD"
		fi

		# Any acquiescing or live data state capture (e.g. database dump) should be performed here

		# Backup using borg
		NOW=$(date +%Y%m%d_%H%M)
		echo -e "\nBacking up using borg.." >> $LOG
		echo "Create mtime file and wait two seconds." >> $LOG
		#IMAGE_DIR=$(dirname $(echo $IMAGES | awk {'print $1'} | head -1))
		touch $BORG_MTIME_FILE; sleep 2
		CMD="$NICE_OPTIONS borg create $BORG_GLOBAL_OPTIONS $BORG_CREATE_OPTIONS $BORG_EXCLUDE_OPTIONS $BORG_ARCHIVE_FOLDER::${BACKUP_FILENAME}_$NOW ${BORG_MTIME_FILE} $SRC_PATHS >> $LOG 2>&1"
		echo "Command: $CMD" | sed 's/BORG_PASSPHRASE=\S*/BORG_PASSPHRASE=xxxxxxxx/g' >> $LOG
		eval "$CMD"
		if [ "$?" -ne "0" ]
		then
			ERR="$SHCMD: Error!  Borg failed to backup $DOMAIN"
			echo $ERR >> $LOG
			echo "$ERR
Host:     $HOST
Domain:   $DOMAIN
Logfile:  $LOG
Command:  $CMD" | mail -s "$SHCMD borg backup failed" $EMAIL_RECIPIENT
			echo $ERR
		fi
		rm $BORG_MTIME_FILE

		# Summary information about the last backup.
		echo -e "\nShow summary info about the last backup" >> $LOG
		CMD="borg info $BORG_GLOBAL_OPTIONS $BORG_ARCHIVE_FOLDER --last 1 >> $LOG 2>&1"
		echo "Command: $CMD" | sed 's/BORG_PASSPHRASE=\S*/BORG_PASSPHRASE=xxxxxxxx/g' >> $LOG
		eval "$CMD"
                if [ "$?" -ne "0" ]
                then
                        ERR="$SHCMD: Error!  Borg summary failed for $DOMAIN"
                        echo $ERR >> $LOG
                        echo "$ERR
Host:     $HOST
Domain:   $DOMAIN
Logfile:  $LOG
Command:  $CMD" | mail -s "$SHCMD borg summary failed" $EMAIL_RECIPIENT
                        echo $ERR
                fi
		# Create summary temp file if required
		if [ "$EMAIL_SUMMARY" = "yes" -o "$END_SUMMARY" = "yes" ]
		then
			echo "Summary of $DOMAIN" >> $SUMMARY_FILE
			borg info $BORG_GLOBAL_OPTIONS $BORG_ARCHIVE_FOLDER --last 1 >> $SUMMARY_FILE
			echo -e "-----------------------------------------------\n\n" >> $SUMMARY_FILE
		fi

		# Prune borg archives
		echo -e "\nPrune borg archives older than $BORG_PRUNE_OPTIONS days." >> $LOG
		CMD="borg prune $BORG_GLOBAL_OPTIONS $BORG_PRUNE_OPTIONS $BORG_ARCHIVE_FOLDER >> $LOG 2>&1"
		echo "Command: $CMD" | sed 's/BORG_PASSPHRASE=\S*/BORG_PASSPHRASE=xxxxxxxx/g' >> $LOG
		eval "$CMD"
		if [ "$?" -ne "0" ]
                then
                        ERR="$SHCMD: Error!  Failed pruning borg archive for $DOMAIN"
                        echo $ERR >> $LOG
                        echo "$ERR
Host:     $HOST
Domain:   $DOMAIN
Logfile:  $LOG
Command:  $CMD" | mail -s "$SHCMD borg prune failed" $EMAIL_RECIPIENT
                        echo $ERR
                fi
	fi

        echo "---- Backup done $DOMAIN ---- $(date +'%d-%m-%Y %H:%M:%S') ----" >> $LOG
	# Any cleanup (e.g. removal of database backups) should be done here

# Remove old log files
echo "Remove log files older than $KEEP_FILES_FOR days" >> $LOG
find $LOGS_DIR -maxdepth 1 -mtime +$KEEP_FILES_FOR -name "*.log" -exec rm -vf {} \; >> $LOG

echo "$SHCMD: Finished backups at $(date +'%d-%m-%Y %H:%M:%S')
====================" >> $LOG

if [ "$EMAIL_SUMMARY" = "yes" ]
then

	echo -e "Summary of Borg Backup:\n\n
Host:       $HOST
Domains:    ${SRC_PATHS//$'\n'/ }

$(cat $SUMMARY_FILE)" | mail -s "Borg Backup Summary for $HOST" $EMAIL_RECIPIENT
fi

if [ "$END_SUMMARY" = "yes" ]
then
	echo -e "Borg Backup Summary:\n\n
Host:       $HOST
Domains:    ${SRC_PATHS//$'\n'/ }

$(cat $SUMMARY_FILE)\n"
fi

# Remove temp files
rm -f $SUMMARY_FILE $CHECK_RESULTS_FILE

exit $ERRORED

