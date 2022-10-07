#!/bin/bash
# ==============================================================================
# Backup Script v1.0.0
# (c)2022 by Michael Schams | https://schams.net
#
# https://github.com/schams-net/backups
#
# ==============================================================================

# Default path to recursively search for backup.ini files.
SOURCE_PATH="/srv/www/"

# Optional extra pamaters (e.g. "--extended-insert=false") to be passed to
# the MySQL/MariaDB client.
MYSQL_PARAMETERS="--single-transaction --no-tablespaces"

# ------------------------------------------------------------------------------

output(){
	OUTPUT_TIMESTAMP=$(date +"%d/%b/%Y %H:%M:%S %Z")
	echo "[${OUTPUT_TIMESTAMP}] $1"
}

convertsecs(){
	((h=${1}/3600))
	((m=(${1}%3600)/60))
	((s=${1}%60))
	TIME_ELAPSED=$(printf "%02d hrs %02d mins %02d secs" $h $m $s)
}

TIMER_START=$(date +"%s")
BACKUP_SCRIPT_VERSION="1.0.0"
PATH=$PATH:/usr/local/bin
AWS_CLI=$(which aws)
HOSTNAME_SHORT=$(hostname --short)
HOSTNAME_LONG=$(hostname --long)
CURRENT_DATE=$(date +"%Y%m%d")
PROCESS="$$"
RETURN=0
ERRORS=0
WARNINGS=0

while getopts "p:" ARGUMENTS; do
	case ${ARGUMENTS} in
		p)
			TEMP=$(echo "${OPTARG}" | egrep '^[a-z0-9,\-\./]')
			if [ ! "${TEMP}" = "" ]; then
				SOURCE_PATH=${TEMP}
			fi
			;;
		*)
			output "Syntax error in command line parameters"
			;;
	esac
done

output "Backup script version ${BACKUP_SCRIPT_VERSION} on host ${HOSTNAME_LONG}, PID: ${PROCESS}"
output "Searching for backup.ini files in ${SOURCE_PATH}"

# search for backup.ini files
CONFIGURATION_FILES=$(find "${SOURCE_PATH}" -name "backup.ini" -type f)

if [ "${CONFIGURATION_FILES}" = "" ]; then
	output "No backup.ini files found"
	exit 0
fi

CONTINUE="false"
for CONFIGURATION_FILE in ${CONFIGURATION_FILES}; do

	if [ -r "${CONFIGURATION_FILE}" ]; then
		output "Found backup.ini file: ${CONFIGURATION_FILE}"
		BACKUP_CONFIGURATION=$(cat "${CONFIGURATION_FILE}")
		VALID_FILE=$(echo -e "${BACKUP_CONFIGURATION}" | head -3 | egrep '^# ID:schams-net/backups$')
		if [ "${VALID_FILE}" = "" ]; then
			output "[WARNING] Ignoring file (does not contain a valid signature)"
			let WARNINGS=WARNINGS+1
		else
			BACKUP_DOMAIN=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^domain[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
			BACKUP_USER=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^user[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
			BACKUP_EMAIL=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^email[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
			BACKUP_EXCLUDE_DIRECTORIES=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^exclude\.directories\.containing\.file[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
			BACKUP_TAR_FOLLOW_SYMLINKS=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^tar\.follow\.symlinks[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')

			FILESYSTEM_BACKUP_ENABLED=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^filesystem\.backup\.enabled[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
			DATABASE_BACKUP_ENABLED=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^database\.backup\.enabled[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
			CLEANUP_LOCAL_ENABLED=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^cleanup\.local\.enabled[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
			REMOTE_AWS_ENABLED=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^remote\.aws\.enabled[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')

			BACKUP_BASEDIRECTORY=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^filesystem\.base\.directory[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
			BACKUP_BASEDIRECTORY=$(echo "${BACKUP_BASEDIRECTORY}" | sed "s/{DOMAIN}/${BACKUP_DOMAIN}/g" | sed "s/{USER}/${BACKUP_USER}/g" | sed "s/{HOSTNAME}/${HOSTNAME_SHORT}/g" | sed "s/{DATE}/${CURRENT_DATE}/g" | sed 's/\/$//')

			DESTINATION_DIRECTORY=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^local\.destination\.directory[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
			DESTINATION_DIRECTORY=$(echo "${DESTINATION_DIRECTORY}" | sed "s/{DOMAIN}/${BACKUP_DOMAIN}/g" | sed "s/{USER}/${BACKUP_USER}/g" | sed "s/{HOSTNAME}/${HOSTNAME_SHORT}/g" | sed "s/{DATE}/${CURRENT_DATE}/g" | sed 's/\/$//')

			INCLUDE_DIRECTORY_LIST=""
			TAR_ADDITIONAL_PARAMETERS=""

			output "Domain: ${BACKUP_DOMAIN}"
			output "User: ${BACKUP_USER}"
			output "Email: ${BACKUP_EMAIL}"
			output "Destination: ${DESTINATION_DIRECTORY}"

			if [ ! -d "${DESTINATION_DIRECTORY}" ]; then
				mkdir --parent "${DESTINATION_DIRECTORY}"
			fi

			if [ "${BACKUP_DOMAIN}" = "" -o "${BACKUP_USER}" = "" -o "${BACKUP_EMAIL}" = "" ]; then
				output "[ERROR] Invalid configuration: check domain, user and email address"
				let ERRORS=ERRORS+1
			elif [ ! -d "${DESTINATION_DIRECTORY}" ]; then
				output "[ERROR] Unable to create destination directory: ${DESTINATION_DIRECTORY}"
				let ERRORS=ERRORS+1
			else

				# --- backup file system ---

				if [ ! "${FILESYSTEM_BACKUP_ENABLED}" = "true" ]; then
					output "Filesystem backup disabled"
				elif [ -d "${BACKUP_BASEDIRECTORY}" ]; then
					output "Base directory: ${BACKUP_BASEDIRECTORY}"

					cd "${BACKUP_BASEDIRECTORY}"

					if [ ! "${BACKUP_EXCLUDE_DIRECTORIES}" = "" ]; then
						BACKUP_EXCLUDE_DIRECTORIES=$(echo "${BACKUP_EXCLUDE_DIRECTORIES}" | egrep '^[a-zA-Z0-9_\.\-]*$')
						if [ "${BACKUP_EXCLUDE_DIRECTORIES}" = "" ]; then
							output "[WARNING] Ignoring invalid configuration \"exclude.directories.containing.file\" (file contains invalid characters)"
							let WARNINGS=WARNINGS+1
						else
							output "Excluding contents of directories containing file \"${BACKUP_EXCLUDE_DIRECTORIES}\""
							TAR_ADDITIONAL_PARAMETERS="${TAR_ADDITIONAL_PARAMETERS} --exclude-tag=${BACKUP_EXCLUDE_DIRECTORIES}"
						fi
					fi

					INCLUDE_DIRECTORY=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^include\.directory[[:space:]]*=' | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
					INCLUDE_DIRECTORY=$(echo "${INCLUDE_DIRECTORY}" | sed "s/{DOMAIN}/${BACKUP_DOMAIN}/g" | sed "s/{USER}/${BACKUP_USER}/g" | sed "s/{HOSTNAME}/${HOSTNAME_SHORT}/g" | sed "s/{DATE}/${CURRENT_DATE}/g" | sed 's/\/$//')
					if [ "${INCLUDE_DIRECTORY}" = "" ]; then
						output "One directory skipped"
						# TODO maybe add ALL directories?
						#INCLUDE_DIRECTORY_LIST="*"
					else
						for DIRECTORY in ${INCLUDE_DIRECTORY} ; do
							if [ ! -d "${DIRECTORY}" ]; then
								output "[WARNING] Directory does not exist: ${DIRECTORY}"
								let WARNINGS=WARNINGS+1
							else
								output "Including directory: ${DIRECTORY}"
								INCLUDE_DIRECTORY_LIST="${INCLUDE_DIRECTORY_LIST} ${DIRECTORY}"

								if [ ! "${BACKUP_EXCLUDE_DIRECTORIES}" = "" ]; then
									EXCLUDED_DIRECTORIES=$(find "${DIRECTORY}" -name "${BACKUP_EXCLUDE_DIRECTORIES}" -type f -printf "%p\n")
									IFS_SAVED=${IFS} ; IFS=$'\n'
									for EXCLUDED_DIRECTORY in ${EXCLUDED_DIRECTORIES}; do
										EXCLUDED_DIRECTORY=$(dirname "${EXCLUDED_DIRECTORY}")
										output "Excluding directory: ${EXCLUDED_DIRECTORY}"
									done
									IFS=${IFS_SAVED}
								fi
							fi
						done

						if [ ! "${INCLUDE_DIRECTORY_LIST}" = "" ]; then
							COUNTER=1
							TAR_GZ_FILENAME="${COUNTER}.${BACKUP_DOMAIN}.tar.gz"

							while [ -e "${DESTINATION_DIRECTORY}/${TAR_GZ_FILENAME}" ]; do
								let COUNTER=COUNTER+1
								TAR_GZ_FILENAME="${COUNTER}.${BACKUP_DOMAIN}.tar.gz"
							done

							TAR_ARGUMENTS=""
							if [ "${BACKUP_TAR_FOLLOW_SYMLINKS}" = "true" ]; then
								TAR_ARGUMENTS="${TAR_ARGUMENTS} --dereference"
							fi

							output "Creating backup file: ${TAR_GZ_FILENAME}"
							tar czf "${DESTINATION_DIRECTORY}/${TAR_GZ_FILENAME}" ${TAR_ADDITIONAL_PARAMETERS} ${TAR_ARGUMENTS} --warning=no-file-changed ${INCLUDE_DIRECTORY_LIST}

							RESULT=$?
							if [ ${RESULT} -eq 0 -a -s "${DESTINATION_DIRECTORY}/${TAR_GZ_FILENAME}" ]; then
								SIZE=$(stat --printf "%s" "${DESTINATION_DIRECTORY}/${TAR_GZ_FILENAME}")
								output "Backup successfully file created (size: ${SIZE} bytes)"
							elif [ ${RESULT} -eq 1 ]; then
								# If tar was given `--create', `--append' or `--update' option, exit code 1 means
								# that some files were changed while being archived and so the resulting archive
								# does not contain the exact copy of the file set.
								if [ -s "${DESTINATION_DIRECTORY}/${TAR_GZ_FILENAME}" ]; then
									SIZE=$(stat --printf "%s" "${DESTINATION_DIRECTORY}/${TAR_GZ_FILENAME}")
									output "[WARNING] One or more files were changed while being archived"
									output "Backup file created regardless (size: ${SIZE} bytes)"
								else
									output "[ERROR] Archiving tool 'tar' failed with error code ${RESULT}"
									#let ERRORS=ERRORS+1 (error counted will be increased below, if no backup file exists)
								fi
							else
								output "[ERROR] Archiving tool 'tar' failed with error code ${RESULT}"
								let ERRORS=ERRORS+1
							fi

							if [ ! -s "${DESTINATION_DIRECTORY}/${TAR_GZ_FILENAME}" ]; then
								output "[ERROR] No backup file created"
								let ERRORS=ERRORS+1
							fi

							DISK_FREE_VERSION=$(df --version | head -1 | sed 's/^[^0-9]*\(.*\)$/\1/g' | cut -c 1-3)
							if [ "${DISK_FREE_VERSION}" = "8.1" ]; then
								output "Skipping disk space check (df version ${DISK_FREE_VERSION})"
							else
								DISK_SPACE=$(df -h --output='target,size,used,avail,pcent' . | tail -1 | sed 's/^[[:space:]]*//g' | sed 's/[[:space:]]\{1,\}/ /g')
								DISK_SPACE_TARGET=$(echo "${DISK_SPACE}" | cut -f 1 -d ' ')
								DISK_SPACE_SIZE=$(echo "${DISK_SPACE}" | cut -f 2 -d ' ')
								DISK_SPACE_USED=$(echo "${DISK_SPACE}" | cut -f 3 -d ' ')
								DISK_SPACE_AVAILABLE=$(echo "${DISK_SPACE}" | cut -f 4 -d ' ')
								DISK_SPACE_PERCENTAGE=$(echo "${DISK_SPACE}" | cut -f 4 -d ' ')
								output "Backup disk space on partition \"${DISK_SPACE_TARGET}\": ${DISK_SPACE_USED} of ${DISK_SPACE_SIZE} used (${DISK_SPACE_PERCENTAGE}), remaining: ${DISK_SPACE_AVAILABLE}"
							fi
						fi
					fi
				else
					output "[ERROR] Configured base directory does not exist: ${BACKUP_BASEDIRECTORY}"
					let ERRORS=ERRORS+1
				fi

				# --- backup database ---

				if [ ! "${DATABASE_BACKUP_ENABLED}" = "true" ]; then
					output "Database backup disabled"
				else
					DATABASE_HOST=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^database\.host[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
					DATABASE_PASSWORD=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^database\.password[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
					DATABASE_USER=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^database\.user[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
					DATABASE_USER=$(echo "${DATABASE_USER}" | sed "s/{DOMAIN}/${BACKUP_DOMAIN}/g" | sed "s/{USER}/${BACKUP_USER}/g" | sed "s/{HOSTNAME}/${HOSTNAME_SHORT}/g" | sed "s/{DATE}/${CURRENT_DATE}/g" | sed 's/\/$//')
					DATABASE_NAME=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^database\.name[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
					DATABASE_NAME=$(echo "${DATABASE_NAME}" | sed "s/{DOMAIN}/${BACKUP_DOMAIN}/g" | sed "s/{USER}/${BACKUP_USER}/g" | sed "s/{HOSTNAME}/${HOSTNAME_SHORT}/g" | sed "s/{DATE}/${CURRENT_DATE}/g" | sed 's/\/$//')

					output "Database host: ${DATABASE_HOST}"
					output "Database user: ${DATABASE_USER}"
					output "Database password: "$(echo "${DATABASE_PASSWORD}" | sed 's/./*/g')
					output "Database: ${DATABASE_NAME}"

					MYSQL_ACCESS_DETAILS=""
					if [ ! "${DATABASE_HOST}" = "" ]; then MYSQL_ACCESS_DETAILS="${MYSQL_ACCESS_DETAILS} --host ${DATABASE_HOST}"; fi
					if [ ! "${DATABASE_USER}" = "" ]; then MYSQL_ACCESS_DETAILS="${MYSQL_ACCESS_DETAILS} --user ${DATABASE_USER}"; fi
					if [ ! "${DATABASE_PASSWORD}" = "" ]; then MYSQL_ACCESS_DETAILS="${MYSQL_ACCESS_DETAILS} -p${DATABASE_PASSWORD}"; fi

					if [ ! "${DATABASE_NAME}" = "" ]; then

						output "Testing access to database \"${DATABASE_NAME}\""

						# ...
						mysql ${MYSQL_ACCESS_DETAILS} ${DATABASE_NAME} -e "SHOW TABLES" 2>&1 > /dev/null

						RESULT=$?
						if [ ${RESULT} -ne 0 ]; then
							output "[ERROR] Database connection failed"
							let ERRORS=ERRORS+1
						else
							COUNTER=1
							MYSQL_GZ_FILENAME="${COUNTER}.${BACKUP_DOMAIN}.sql.gz"

							while [ -e "${DESTINATION_DIRECTORY}/${MYSQL_GZ_FILENAME}" ]; do
								let COUNTER=COUNTER+1
								MYSQL_GZ_FILENAME="${COUNTER}.${BACKUP_DOMAIN}.sql.gz"
							done

							output "Creating backup file: ${MYSQL_GZ_FILENAME}"

							mysqldump ${MYSQL_PARAMETERS} ${MYSQL_ACCESS_DETAILS} ${DATABASE_NAME} | gzip -9 --stdout > "${DESTINATION_DIRECTORY}/${MYSQL_GZ_FILENAME}"

							# @TODO: $RESULT is always '0'
							RESULT=$?
							if [ ${RESULT} -ne 0 ]; then
								output "[ERROR] 'mysqldump' failed with error code ${RESULT}"
								let ERRORS=ERRORS+1
							else
								SIZE=$(stat --printf "%s" "${DESTINATION_DIRECTORY}/${MYSQL_GZ_FILENAME}")
								output "Database backup file created (size: ${SIZE} bytes)"
							fi
						fi
					fi
				fi

				# ------------------------------------------------------------------------------
				# Delete local files older than x days

				if [ ! "${CLEANUP_LOCAL_ENABLED}" = "true" ]; then
					output "Local cleanup is disabled"
				else
					CONTINUE_ON_ERRORS=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^cleanup\.continue_on_errors[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')

# @TODO this seems to be wrong!
# ${ERRORS} is a global variable, so if instances A, B and C are processed,
# backup of A fails (ERRORS=1), instance B is affected, too (not cleaned up).
# This check should be limited to the instance, which failed, not to all
# instances.

					CONTINUE="true"
					if [ ! "${ERRORS}" = "0" ]; then
						if [ ! "${CONTINUE_ON_ERRORS}" = "true" ]; then
							output "Cleanup procedures disabled due to errors"
							CONTINUE="false"
						fi
					fi

					if [ "${CONTINUE}" = "true" ]; then

						KEEP_BACKUPS_FOR_X_DAYS=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^cleanup\.local\.keep_x_days[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g' | egrep '^[0-9]*$')

						if [ ! "${KEEP_BACKUPS_FOR_X_DAYS}" = "" -a ! "${KEEP_BACKUPS_FOR_X_DAYS}" = "0" ]; then

							output "Deleting backups older than ${KEEP_BACKUPS_FOR_X_DAYS} days"

							CLEANUP_LOCAL_DIRECTORY=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^cleanup\.local_directory[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
							CLEANUP_LOCAL_DIRECTORY=$(echo "${CLEANUP_LOCAL_DIRECTORY}" | sed "s/{DOMAIN}/${BACKUP_DOMAIN}/g" | sed "s/{USER}/${BACKUP_USER}/g" | sed "s/{HOSTNAME}/${HOSTNAME_SHORT}/g" | sed "s/{DATE}/${CURRENT_DATE}/g" | sed 's/\/$//')

							if [ ! -d "${CLEANUP_LOCAL_DIRECTORY}" ]; then
								output "[WARNING] Configured local backup directory does not exist: ${CLEANUP_LOCAL_DIRECTORY}"
								let WARNINGS=WARNINGS+1
							else
								output "Local backup directory: ${CLEANUP_LOCAL_DIRECTORY}"

								cd ${CLEANUP_LOCAL_DIRECTORY}/

								BACKUPS_DELETED=0
								for FILE in $(find . -maxdepth 1 -type d -printf "%f\n" | egrep '^20[0-9]{6}$' | sort); do
									DATE_FILE=$(echo "${FILE}" | cut -f 1 -d '.')
									AGE=$(( ($(date --date="${DATE_TODAY}" +%s) - $(date --date="${DATE_FILE}" +%s) )/(60*60*24) ))

									if [ ${AGE} -ge ${KEEP_BACKUPS_FOR_X_DAYS} ]; then
										output "Backup from ${FILE} (${AGE} days) -> *delete*"

										rm -r "${FILE}"

										if [ $? -ne 0 ]; then
											output "Warning: unable to delete directory"
											let WARNINGS=WARNINGS+1
										else
											let BACKUPS_DELETED=${BACKUPS_DELETED}+1
										fi
#									else
#										output "Backup from ${FILE} (${AGE} days)"
									fi
								done
								output "Backups deleted: ${BACKUPS_DELETED}"
							fi
						fi

					fi
				fi

				# ------------------------------------------------------------------------------
				# Synchronise backups to AWS S3 Bucket

				if [ ! "${REMOTE_AWS_ENABLED}" = "true" ]; then
					output "Synchronizing backups with AWS S3 bucket is disabled"
				else

					output "Synchronizing backups with AWS S3 bucket"

					if [ "${AWS_CLI}" = "" ]; then
						output "[ERROR] AWS CLI not found."
						let WARNINGS=WARNINGS+1
					else

						OUTPUT_FILE="/tmp/aws-s3.${PROCESS}.txt"

						AWS_LOCAL_DIRECTORY=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^remote\.aws\.local_directory[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
						AWS_LOCAL_DIRECTORY=$(echo "${AWS_LOCAL_DIRECTORY}" | sed "s/{DOMAIN}/${BACKUP_DOMAIN}/g" | sed "s/{USER}/${BACKUP_USER}/g" | sed "s/{HOSTNAME}/${HOSTNAME_SHORT}/g" | sed "s/{DATE}/${CURRENT_DATE}/g" | sed 's/\/$//')
						AWS_S3_BUCKETNAME=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^remote\.aws\.s3_bucket[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
						AWS_S3_BUCKETNAME=$(echo "${AWS_S3_BUCKETNAME}" | sed "s/{DOMAIN}/${BACKUP_DOMAIN}/g" | sed "s/{USER}/${BACKUP_USER}/g" | sed "s/{HOSTNAME}/${HOSTNAME_SHORT}/g" | sed "s/{DATE}/${CURRENT_DATE}/g" | sed 's/\/$//')
						AWS_S3_PATH=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^remote\.aws\.s3_path[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
						AWS_S3_PATH=$(echo "${AWS_S3_PATH}" | sed "s/{DOMAIN}/${BACKUP_DOMAIN}/g" | sed "s/{USER}/${BACKUP_USER}/g" | sed "s/{HOSTNAME}/${HOSTNAME_SHORT}/g" | sed "s/{DATE}/${CURRENT_DATE}/g" | sed 's/\/$//')

						AWS_S3_PROFILE=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^remote\.aws\.profile[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
						if [ ! "${AWS_S3_PROFILE}" = "" ]; then output "AWS S3 profile: ${AWS_S3_PROFILE}" ; AWS_S3_PROFILE="--profile ${AWS_S3_PROFILE}" ; fi
						AWS_S3_REGION=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^remote\.aws\.region[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
						if [ ! "${AWS_S3_REGION}" = "" ]; then output "AWS S3 region: ${AWS_S3_REGION}" ; AWS_S3_REGION="--region ${AWS_S3_REGION}" ; fi
						AWS_S3_OUTPUT=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^remote\.aws\.output[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
						if [ ! "${AWS_S3_OUTPUT}" = "" ]; then output "AWS S3 output: ${AWS_S3_OUTPUT}" ; AWS_S3_OUTPUT="--output ${AWS_S3_OUTPUT}" ; fi
						AWS_S3_DELETE=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^remote\.aws\.delete[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
						if [ ! "${AWS_S3_DELETE}" = "true" ]; then AWS_S3_DELETE="" ; else output "AWS S3 delete: ${AWS_S3_DELETE}" ; AWS_S3_DELETE="--delete" ; fi
						AWS_S3_DRYRUN=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^remote\.aws\.dryrun[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
						if [ ! "${AWS_S3_DRYRUN}" = "true" ]; then AWS_S3_DRYRUN="" ; else output "AWS S3 dryrun: ${AWS_S3_DRYRUN}" ; AWS_S3_DRYRUN="--dryrun" ; fi
						AWS_S3_STORAGE_CLASS=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^remote\.aws\.s3_storage_class[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')
						if [ ! "${AWS_S3_STORAGE_CLASS}" = "" ]; then
							if [ "${AWS_S3_STORAGE_CLASS}" = "STANDARD" ]; then AWS_S3_STORAGE_CLASS="--storage-class ${AWS_S3_STORAGE_CLASS}" ;
							elif [ "${AWS_S3_STORAGE_CLASS}" = "REDUCED_REDUNDANCY" ]; then AWS_S3_STORAGE_CLASS="--storage-class ${AWS_S3_STORAGE_CLASS}" ;
							elif [ "${AWS_S3_STORAGE_CLASS}" = "STANDARD_IA" ]; then AWS_S3_STORAGE_CLASS="--storage-class ${AWS_S3_STORAGE_CLASS}" ;
							elif [ "${AWS_S3_STORAGE_CLASS}" = "ONEZONE_IA" ]; then AWS_S3_STORAGE_CLASS="--storage-class ${AWS_S3_STORAGE_CLASS}" ;
							elif [ "${AWS_S3_STORAGE_CLASS}" = "INTELLIGENT_TIERING" ]; then AWS_S3_STORAGE_CLASS="--storage-class ${AWS_S3_STORAGE_CLASS}" ;
							elif [ "${AWS_S3_STORAGE_CLASS}" = "GLACIER" ]; then AWS_S3_STORAGE_CLASS="--storage-class ${AWS_S3_STORAGE_CLASS}" ;
							elif [ "${AWS_S3_STORAGE_CLASS}" = "DEEP_ARCHIVE" ]; then AWS_S3_STORAGE_CLASS="--storage-class ${AWS_S3_STORAGE_CLASS}" ;
							else
								AWS_S3_STORAGE_CLASS=""
							fi
						fi

						output "AWS S3 bucket: \"${AWS_S3_BUCKETNAME}\""
						output "AWS S3 path: \"${AWS_S3_PATH}\""

						if [ ! "${AWS_S3_STORAGE_CLASS}" = "" ]; then
							TEMP=$(echo "${AWS_S3_STORAGE_CLASS}" | cut -f 2 -d ' ')
							output "AWS S3 storage class: \"${TEMP}\""
						fi

						output "Local directory: \"${AWS_LOCAL_DIRECTORY}\""
						cd "${AWS_LOCAL_DIRECTORY}"

						output "Try to determine location of AWS S3 bucket \"${AWS_S3_BUCKETNAME}\""
						AWS_S3_BUCKET_LOCATION=$(${AWS_CLI} ${AWS_S3_PROFILE} ${AWS_S3_REGION} ${AWS_S3_OUTPUT} s3api get-bucket-location --bucket ${AWS_S3_BUCKETNAME})
						if [ $? -eq 0 ]; then
							if [ "${AWS_S3_BUCKET_LOCATION}" = "None" ]; then
								# "None" is in fact "us-east-1"
								AWS_S3_BUCKET_LOCATION="us-east-1"
							fi
							output "AWS S3 bucket location: \"${AWS_S3_BUCKET_LOCATION}\""
						fi

						AWS_CLI_OUTPUT=$(${AWS_CLI} ${AWS_S3_PROFILE} ${AWS_S3_REGION} ${AWS_S3_OUTPUT} s3 ${AWS_S3_DRYRUN} sync ${AWS_S3_STORAGE_CLASS} ${AWS_S3_DELETE} . s3://${AWS_S3_BUCKETNAME}/${AWS_S3_PATH}/)

						if [ $? -ne 0 ]; then
							output ">>> Warning: \"aws-cli\" reported errors"
							output "${AWS_CLI_OUTPUT}"
							let WARNINGS=WARNINGS+1
						else
							output "Synchronization successfully finished"
							#echo -e "${AWS_CLI_OUTPUT}" | sed "s/\(file(s) remaining\)\([[:space:]]\)/\1\n/g" | egrep -v '^Completed .* remaining$' > "${OUTPUT_FILE}"
							#output "Output file: \"${OUTPUT_FILE}\""
						fi
					fi
				fi

				# ------------------------------------------------------------------------------
				# Delete files older than x days from AWS S3 bucket

				REMOTE_AWS_KEEP_BACKUPS_FOR_X_DAYS=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^remote\.aws\.cleanup\.keep_x_days[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g' | egrep '^[0-9]*$')

				if [ "${REMOTE_AWS_KEEP_BACKUPS_FOR_X_DAYS}" = "0" -o "${REMOTE_AWS_KEEP_BACKUPS_FOR_X_DAYS}" = "" ]; then
					output "Cleanup files from AWS S3 bucket is disabled"
				else
					REMOTE_AWS_CONTINUE_ON_ERRORS=$(echo -e "${BACKUP_CONFIGURATION}" | egrep '^remote\.aws\.cleanup\.continue_on_errors[[:space:]]*=' | head -1 | sed 's/^\([^=]*\)=[[:space:]]*\(.*\)$/\2/g')

# @TODO this seems to be wrong!
# ${ERRORS} is a global variable, so if instances A, B and C are processed,
# backup of A fails (ERRORS=1), instance B is affected, too (not cleaned up).
# This check should be limited to the instance, which failed, not to all
# instances.

					CONTINUE="true"
					if [ ! "${ERRORS}" = "0" ]; then
						if [ ! "${REMOTE_AWS_CONTINUE_ON_ERRORS}" = "true" ]; then
							output "Cleanup procedures disabled due to errors"
							CONTINUE="false"
						fi
					fi

					if [ "${CONTINUE}" = "true" ]; then

						output "Deleting backups from AWS S3 bucket, which are older than ${REMOTE_AWS_KEEP_BACKUPS_FOR_X_DAYS} days"
						output "*** not activated yet ***"

						# ...
						AWS_CLI_OUTPUT=$(${AWS_CLI} ${AWS_S3_PROFILE} ${AWS_S3_REGION} s3 ${AWS_S3_DRYRUN} ls s3://${AWS_S3_BUCKETNAME}/${AWS_S3_PATH}/ 2>&1)
						RESULT=$?

						if [ ${RESULT} -ne 0 ]; then
							output ">>> Warning: \"aws-cli\" reported errors"
							output "${AWS_CLI_OUTPUT}"
							let WARNINGS=WARNINGS+1
						else
							DATES=$(echo -e "${AWS_CLI_OUTPUT}" | sed 's/^[[:space:]]*PRE \([0-9]\{8\}\).*/\1/g' | egrep '^[0-9]{8}$' | sort --numeric)

							BACKUPS_DELETED=0
							BACKUPS_NOT_DELETED=0
							for DATE in ${DATES}; do
								AGE=$(( ($(date --date="${DATE_TODAY}" +%s) - $(date --date="${DATE}" +%s) )/(60*60*24) ))
								DAY_OF_MONTH_OF_BACKUP=$(echo "${DATE}" | cut -c 7,8)

								if [ ${AGE} -le ${REMOTE_AWS_KEEP_BACKUPS_FOR_X_DAYS} ]; then
									#output "Backup from ${DATE} (${AGE} days) -> retain (too young)"
									let BACKUPS_NOT_DELETED=BACKUPS_NOT_DELETED+1
								elif [ "${DAY_OF_MONTH_OF_BACKUP}" = "01" ]; then
									#output "Backup from ${DATE} (${AGE} days) -> retain (first of the month)"
									let BACKUPS_NOT_DELETED=BACKUPS_NOT_DELETED+1
								else
									output "Backup from ${DATE} (${AGE} days) -> *delete*"
									AWS_CLI_OUTPUT=$(${AWS_CLI} ${AWS_S3_PROFILE} ${AWS_S3_REGION} ${AWS_S3_OUTPUT} s3 ${AWS_S3_DRYRUN} rm --recursive s3://${AWS_S3_BUCKETNAME}/${AWS_S3_PATH}/${DATE})
									RESULT=$?
									if [ ${RESULT} -ne 0 ]; then
										output "Warning: unable to delete directory"
										output "${AWS_CLI_OUTPUT}"
										let WARNINGS=WARNINGS+1
									else
										let BACKUPS_DELETED=BACKUPS_DELETED+1
									fi
								fi
							done
							output "Backups deleted: ${BACKUPS_DELETED}"
							output "Backups kept: ${BACKUPS_NOT_DELETED}"
						fi

					fi
				fi
				# ------------------------------------------------------------------------------
			fi
		fi

	else
		output "[WARNING] Ignoring backup.ini file ${BACKUP_CONFIGURATION_FILE} (not readable)"
		let WARNINGS=WARNINGS+1
	fi
done

# ------------------------------------------------------------------------------

TIMER_STOP=$(date +"%s")
let TIME_ELAPSED=TIMER_STOP-TIMER_START
convertsecs ${TIME_ELAPSED}
output "Errors: ${ERRORS}"
output "Warnings: ${WARNINGS}"
output "Backup script finished (time elapsed: ${TIME_ELAPSED})"

# ==============================================================================
exit ${RETURN}
