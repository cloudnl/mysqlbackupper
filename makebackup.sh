#/bin/bash

##########
# CONFIG #
##########

REMOTESERVER="10.13.37.6"
REMOTEDIR='/backups'
REMOTEUSER='root'

BACKUPSKEPT=10
INTERVALBETWEENFULL=3

#################
# ACTUAL SCRIPT #
#################


function rmtcmd {
    ssh "${REMOTEUSER}@${REMOTESERVER}" "$@"
}

# Stop the script and clean up when an error occurs
trap "error_occured" ERR

function error_occured {
	echo 'error'
	local lc="${BASH_COMMAND}" rc=$?
	echo "Command [${lc}] failed with exitcode ${rc}" 1>&2

	if [ -n "$(mount | grep "${REMOTESERVER}:${REMOTEDIR}/$(hostname)" 2> /dev/null)" ] ; then
		umount "${localbackupdir}"
	fi

	exit 1
}

function log {
	if [ "${1}" = "-n" ] ; then
		shift
		echo -n "$(date +%Y-%m-%d\ %H:%M:%S): ${@}"
	else
		echo "$(date +%Y-%m-%d\ %H:%M:%S): ${@}"
	fi
}

localbackupdir="/backups/$(hostname)/"

# Create the mountpoint for the external datadirectory, if needed
if [ ! -d "${localbackupdir}" ] ; then
	echo 'Creating the mountpoint'
	mkdir -p "${localbackupdir}"
fi

# mount the external datadirectory
if [ -z "$(mount | grep "${REMOTESERVER}:${REMOTEDIR}/$(hostname)" 2> /dev/null)" ] ; then
	echo 'Mount the backup location'
	mount "${REMOTESERVER}:${REMOTEDIR}/$(hostname)" "${localbackupdir}"
fi

# Make the new backupdir
echo 'Create new backup directory'
mkdir -p "${localbackupdir}new/data" "${localbackupdir}new/conf" "${localbackupdir}new/log"

# Setup the logging
exec > ${localbackupdir}new/log/full.log
exec 2> ${localbackupdir}new/log/error.log

# Determine if this should be an incremental or full backup
lasttocheck=$(($INTERVALBETWEENFULL+1))
dofull=1
log -n 'Checking if the backup needs to be full or incremental, conclusion: '
echo $lasttocheck
for (( rotatedir=1; rotatedir<="${lasttocheck}"; rotatedir++)); do
	echo $rotatedir
	if [ ! -f "${localbackupdir}/${rotatedir}/data/ibdata1.delta" ] ; then
		dofull=0
		break
	fi
done
if [ "${dofull}" = "1" ] ; then
	echo 'full'
else
	echo 'incremental'
fi

# find out what xtrabackup binary should be used
log -n 'Checking what xtrabackup executable needs to be used, conslusion: '
mysqlversion="$(mysql --version | awk '{print $5}')"
mysqlversionmajor="$(echo $mysqlversion | cut -d '.' -f 1)"
mysqlversionminor="$(echo $mysqlversion | cut -d '.' -f 2)"
if [ "${mysqlversionmajor}" = "5" ] ; then
	if [ "${mysqlversionminor}" = "6" ] ; then
		xtrabackupbin='xtrabackup_56'
	elif [ "${mysqlversionminor}" = "5" ] ; then
		xtrabackupbin='xtrabackup_55'
	else
		xtrabackupbin='xtrabackup'
	fi
	echo $xtrabackupbin
elif [ "${mysqlversionmajor}" = "10" ] ; then
	xtrabackupbin='xtrabackup_56'
	echo $xtrabackupbin
else
	echo ''
	echo 'Your MySQL version is not supported by this backupscript' 1>&2
	exit 1
fi

# find out where the MySQL data is stored
# Grep it out of /etc/my.cnf
log -n 'Finding the MySQL datadirectory, conclusion: '
datadir="$(grep datadir /etc/my.cnf | tail -n 1 | cut -d '=' -f 2)"
# Check to see if it is defined now
if [ "${datadir}" = "" ] ; then
	# It is not, see if extra files could be used
	if [ -n "$(grep '!includedir' /etc/my.cnf)" ] ; then
		OLDIFS=$IFS
		IFS=$'\n'
		includeddirs=$(grep '!includedir' /etc/my.cnf)
		for includeline in $includeddirs; do
			# Extra files could be used, extract it from there
			dir=$(echo $includeline | awk '{print $2}')
			for filename in $(echo "${dir}/*"); do
				datadir="$(grep datadir "${filename}" | tail -n 1 | cut -d '=' -f 2)"
			done
		done
		IFS=$OLDIFS
	fi
fi

# datadir is still undefined, then it must be the default setting, assume that
if [ "${datadir}" = "" ] ; then
	datadir='/var/lib/mysql'
fi

echo $datadir

# START OF THE ACTUAL BACKUP

# Run the backup
# Backup the actual data
log 'Starting the actual backup, all the InnoDB files.'
if [ "${dofull}" = 1 ] ; then
	# Run a full backup
	${xtrabackupbin} --backup "--datadir=${datadir}" "--target-dir=${localbackupdir}new/data" 2> "${localbackupdir}new/log/xtrabackup.log"
else
	# Run an incremental backup
	${xtrabackupbin} --backup "--datadir=${datadir}" "--target-dir=${localbackupdir}new/data" "--incremental-basedir=${localbackupdir}2/data" 2> "${localbackupdir}new/log/xtrabackup.log"
fi

# Record at what moment the backup was taken
date > "${localbackupdir}new/data/backup_timestamp"
# Backup the table definitions
log 'backuping up the table definitions'
databases="$(cd "${datadir}" && find -type d | sed -e 's/\.\///g' | grep -v '^mysql$' | grep -v '^performance_schema$' | grep -v '^test$' | grep -v '^\.$' && cd - > /dev/null)"
for database in $databases; do
	cp -r ${datadir}/${database}/*.frm ${localbackupdir}new/data/${database}/
done

# Prepare the backups for the restore, or for applying an incremental backup, only needed with full backups
if [ "${dofull}" = 1 ] ; then
	log 'Preparing the backup for use with an incremental backup'
	rmtcmd ${xtrabackupbin} --prepare "--target-dir=${localbackupdir}new/data" --apply-log-only 2>> "${localbackupdir}new/log/xtrabackup.log"
else
	log 'It is an incremental backup, no prepare needed'
fi

# Rotate the backups
log 'Rotating the backups'
for (( dir="${BACKUPSKEPT}"; dir>=1; dir--)); do
	newdir=$((${dir}+1))
	if [ "${newdir}" -gt "${BACKUPSKEPT}" ] ; then
		rm -rf "${localbackupdir}${dir}"
	else
		mv "${localbackupdir}${dir}" "${localbackupdir}${newdir}"
	fi
done
mv ${localbackupdir}new ${localbackupdir}1

# Unmount the remote datadir
log 'Starting the cleanup'
exec >&-
exec 2>&-
umount "${localbackupdir}"

log 'done'

###########
# LICENSE #
###########

# Copyright 2013, 2014 Cloud.nl.
# Program distributed under the terms of the GNU General Public License
