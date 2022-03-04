#!/bin/bash

# Exit immediately on error
set -e

# Write cronjob env to file, fill in sensible defaults, and read them back in
cat <<EOF > env.sh
BACKUP_SOURCES="${BACKUP_SOURCES:-/backup}"
BACKUP_CRON_EXPRESSION="${BACKUP_CRON_EXPRESSION:-@daily}"
AWS_S3_BUCKET_NAME="${AWS_S3_BUCKET_NAME:-}"
AWS_GLACIER_VAULT_NAME="${AWS_GLACIER_VAULT_NAME:-}"
AWS_EXTRA_ARGS="${AWS_EXTRA_ARGS:-}"
PRE_BACKUP_COMMAND="${PRE_BACKUP_COMMAND:-}"
POST_BACKUP_COMMAND="${POST_BACKUP_COMMAND:-}"
SCP_HOST="${SCP_HOST:-}"
SCP_USER="${SCP_USER:-}"
SCP_DIRECTORY="${SCP_DIRECTORY:-}"
PRE_SCP_COMMAND="${PRE_SCP_COMMAND:-}"
POST_SCP_COMMAND="${POST_SCP_COMMAND:-}"
BACKUP_FILENAME=${BACKUP_FILENAME:-"backup-%Y-%m-%dT%H-%M-%S.tar.gz"}
BACKUP_ARCHIVE="${BACKUP_ARCHIVE:-/archive}"
BACKUP_UID=${BACKUP_UID:-0}
BACKUP_GID=${BACKUP_GID:-$BACKUP_UID}
BACKUP_WAIT_SECONDS="${BACKUP_WAIT_SECONDS:-0}"
BACKUP_HOSTNAME="${BACKUP_HOSTNAME:-$(hostname)}"
GPG_PASSPHRASE="${GPG_PASSPHRASE:-}"
INFLUXDB_URL="${INFLUXDB_URL:-}"
INFLUXDB_DB="${INFLUXDB_DB:-}"
INFLUXDB_CREDENTIALS="${INFLUXDB_CREDENTIALS:-}"
INFLUXDB_MEASUREMENT="${INFLUXDB_MEASUREMENT:-docker_volume_backup}"
BACKUP_CUSTOM_LABEL="${BACKUP_CUSTOM_LABEL:-}"
CHECK_HOST="${CHECK_HOST:-"false"}"
LOGS_DIR="${BORG_LOGS_DIR:-/var/log/vm_backups}"
SRC_PATHS="${BACKUP_SOURCES:-}"
BORG_SSH_SERVER="${BORG_SSH_SERVER:-}"
BORG_LOCAL_PATH="${BORG_LOCAL_PATH:-}"
BORG_ARCHIVE_FOLDER=$BORG_REPO/$BACKUP_FILENAME
BORG_RSH="${BORG_RSH:-}"
BORG_FILES_CACHE_TTL="${BORG_FILES_CACHE_TTL:-}"
BORG_GLOBAL_OPTIONS="${BORG_GLOBAL_OPTIONS:-}"
BORG_CREATE_OPTIONS="${BORG_CREATE_OPTIONS:-}"
BORG_EXCLUDE_OPTIONS="${BORG_EXCLUDE_OPTIONS:-}"
BORG_PASSPHRASE="${BORG_PASSPHRASE:-}"
BORG_INIT_OPTIONS="${BORG_INIT_OPTIONS:-}"
BORG_PRUNE_OPTIONS="${BORG_PRUNE_OPTIONS:-}"
EOF
chmod a+x env.sh
source env.sh

# Configure AWS CLI
mkdir -p .aws
cat <<EOF > .aws/credentials
[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
EOF
if [ ! -z "$AWS_DEFAULT_REGION" ]; then
cat <<EOF > .aws/config
[default]
region = ${AWS_DEFAULT_REGION}
EOF
fi

# Add our cron entry, and direct stdout & stderr to Docker commands stdout
echo "Installing cron.d entry: docker-volume-backup"
echo "$BACKUP_CRON_EXPRESSION root /root/backup.sh > /proc/1/fd/1 2>&1" > /etc/cron.d/docker-volume-backup

# Let cron take the wheel
echo "Starting cron in foreground with expression: $BACKUP_CRON_EXPRESSION"
cron -f
