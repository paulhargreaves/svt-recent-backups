#!/usr/bin/env sh
# (C)2016,2017 SimpliVity, by Paul Hargreaves
#
# Unsupported script that collects the latest backups from a federation and
# reports where those backups are.

#set -x
VERSION="1.3"
AGE="48 hours ago"  # Must be in a format suitable for date command

# Cache SSH responses? no = "" , yes = anything else e.g. "yes"
# This in a debug option, so keep blank for production
#SSH_CACHE_RESPONSES="yes"
SSH_CACHE_RESPONSES=""


###### Do not change anything below this line ;-)
if [ "${SSH_CACHE_RESPONSES}" ]; then
    echo "SSH_CACHE_RESPONSES enabled."
fi

CONFIGFILE="$1"
if [ -z "${CONFIGFILE}" ]; then 
    echo >&2 "$0: Usage:   $0 <configfile>"
    echo >&2 "Please read the documentation for format of the <configfile>"
    exit 1
fi

# Read the config file and check it is sane
source "${CONFIGFILE}"
if [ -z "${USERNAME}" -o -z "${SSHPASS}" -o -z "${OVC}" \
    -o -z "${FEDERATIONNAME}" -o -z "${EMAILTO}" ]; then
    echo >&2 "Problem with the config file ${CONFIGFILE}"
    exit 1
fi

# Ensure all variables are used properly
set -o nounset

SSH_CACHE_PATH="sshcache"

OUTPUT="backups.html"
ERROR="err"

# TMP_PATH Will be removed so never /tmp or other dir with other files
TMP_PATH="tmp/tmp$$"  # NEVER ADD A SPACE! Will trap rm on this
rm -rf "${TMP_PATH}"
mkdir -p "${TMP_PATH}"
trap "rm -rf ${TMP_PATH}" EXIT

TMP_BACKUP_LIST="${TMP_PATH}/tmpbackuplistfromstack.tmp"
TMP_VM_LIST="${TMP_PATH}/tmpvmsfromstack.tmp"
TMP_NOT_BKUP="${TMP_PATH}/tmpnotbackedup.tmp"
TMP_BKUP_LOCAL_ONLY="${TMP_PATH}/tmpbackuplocalonly.tmp"
TMP_BKUP_REMOTE_ONLY="${TMP_PATH}/tmpbackupremoteonly.tmp"
TMP_BKUP_BOTH_LOCAL_REMOTE="${TMP_PATH}/tmpbackuplocalremote.tmp"
TMP_SSH="${TMP_PATH}/tmpssh.tmp"

# When sending a command to the OVC, start the connection this wayt
CONNECTION_START="export TERM=xterm; source .profile; "

# DELIM Needs to be a char not used in names of backups etc.
# So avoid obvious thing like ?*!$@,:-A-Z0-9 etc and quotes
DELIM="§"   # Must be single char
if [ "${#DELIM}" -ne 1 ]; then
    echo "Something is wrong with the delmimer. Aborting"
    exit 1
fi

# DETAILLINE Sets a marker for a backup detail line, used internally.
# DO NOT USE DELIM CHAR anywhere in this.
DETAILLINE="zzzzz±zzdetaillinezzzzzzzzzz"

# Request list of backups
# $1 OVC to contact
# $2 date to request backups from
# Return: XML
svtBackupShow() {
    sendSvtCommand "$1" svt-backup-show --since "$2" --max-results 99999999
}


# Request the list of servers
# $1 OVC to contact
# Return: Large amounts of XML...
svtVMShow() {
    sendSvtCommand "$1" svt-vm-show
}

# Runs a generic command
# $1 OVC to contact
# $2 = command (e.g. svt-vm-show)
# $* = rest of parameters, if any
# Return: XML output from the command
sendSvtCommand() {
    local ovc="$1"
    shift

    # Work out what our SSH cached file should look like
    sshCacheCLI="$(echo "${USERNAME}@${ovc} $*" | sed 's/;//g')"
    sshCachePath="${SSH_CACHE_PATH}/${sshCacheCLI}"

    rm -f "${TMP_SSH}"  # Make sure we have a space to work in

    # SSH Cache enabled? Attempt to copy in any existing cached entry
    if [ ! -z "${SSH_CACHE_RESPONSES}" ]; then
        mkdir -p "${SSH_CACHE_PATH}"
        cp 2>/dev/null "${sshCachePath}" "${TMP_SSH}"
    fi

    # No tmp file? Go get it from the server
    if [ ! -e "${TMP_SSH}" ]; then
        sshpass > "${TMP_SSH}" -f -e ssh -n \
            -o "StrictHostKeyChecking no" "${USERNAME}@${ovc}" \
            "${CONNECTION_START} $* --timeout 400 --output xml" 2>>"${ERROR}"

        # SSH cache enabled? Store that response
        if [ ! -z "${SSH_CACHE_RESPONSES}" -a -s "${TMP_SSH}" -a ! \
            -e "${sshCachePath}" ]; then
            cp "${TMP_SSH}" "${sshCachePath}"
        fi
    fi

    # Now return our full response
    if [ ! -s "${TMP_SSH}" ]; then
        echo >&2 "Cannot run command using ${sshCachePath}"
        exit 1
    fi

    # Return the result, filtering out any invalid lines
    cat "${TMP_SSH}" | grep "^ *<"
}

# Run the svt-federation-show command
# $1 any one OVC in the federation
svtFederationShow() {
    sendSvtCommand "$1" svt-federation-show
}

# Get the list of all OVCs from the one SVC we know about
# $1 the IP of any OVC in the federation
getAllOVCNodes() {
    svtFederationShow $1 |  \
        xmlstarlet sel -t -m /CommandResult/Node/mgmtIf/ip -v . -n | \
        grep -v "^$"
}

# Request backup data
# $1 OVC to contact
# $2 date to request backups from
# Return: stuffs
returnBackupData() {
    svtBackupShow $* | \
        xmlstarlet sel -t -m /CommandResult/Backup -v hiveId -o "${DELIM}" \
        -v name -o "${DELIM}" -v datacenter -n | grep -v "^$" | sort
}

# Request VM data
# $1 OVC to contact
# Returns: stuffs
returnVMData() {
    svtVMShow $* | \
        xmlstarlet sel -t -m /CommandResult/VM -v id -o "${DELIM}" -v name \
        -o "${DELIM}" -v datacenter -o "${DELIM}" -v policy -n | \
        grep -v "^$" | sort
}

# Generate a single raw entry in the report
# $1 vmSort
# $2 vmName
# $3 vmDC
# $4 vmBackupPolicy
# $5 Output file to send entry to 
# $6 anyBackups
generateRawReportLine() {
    touch "$5" # make sure the output exists

    # Must be local backups only
    echo "$1${DELIM}$2${DELIM}$3${DELIM}$4" >> "$5"
    echo "$6" | while read aBackup; do
    backupDate="$(echo "${aBackup}" | cut -d"${DELIM}" -f2)"
    backupLocation="$(echo "${aBackup}" | cut -d"${DELIM}" -f3)"
    if [ ! -z "${backupLocation}" ]; then
        echo "$1${DELIM}${DETAILLINE}${DELIM}${backupDate}${DELIM}" \
            "${backupLocation}" >> "$5"
    fi
done
}

# Generate report
# $1 file containing VMs
# $2 file containing backups
generateRawReport() {
    cat "$1" | while read aVM; do
    vmID="$(echo "${aVM}" | cut -d"${DELIM}" -f1)"
    vmName="$(echo "${aVM}" | cut -d"${DELIM}" -f2)"
    vmDC="$(echo "${aVM}" | cut -d"${DELIM}" -f3)"
    vmBackupPolicy="$(echo "${aVM}" | cut -d"${DELIM}" -f4)"
    vmSort="${vmName}${vmID}"

    anyBackups="$(grep "${vmID}" "$2")"
    anyLocalBackups="$(echo "${anyBackups}" | cut -d"${DELIM}" -f3 | \
        grep -x "^${vmDC}$")"
    anyRemoteBackups="$(echo "${anyBackups}" | cut -d"${DELIM}" -f3 | \
        grep -x -v "^${vmDC}$")"

    #echo >&2 vmID $vmID vmDC $vmDC remote $anyRemoteBackups local $anyLocalBackups line $anyBackups

    if [ -z "${anyBackups}" ]; then
        # No backups at all
        generateRawReportLine "${vmSort}" "${vmName}" "${vmDC}" \
            "${vmBackupPolicy}" "${TMP_NOT_BKUP}" "${anyBackups}"
    elif [ -z "${anyRemoteBackups}" ]; then
        # Must be local backups only
        generateRawReportLine "${vmSort}" "${vmName}" "${vmDC}" \
            "${vmBackupPolicy}" "${TMP_BKUP_LOCAL_ONLY}" "${anyBackups}"
    elif [ -z "${anyLocalBackups}" ]; then
        # Must be remote backups only
        generateRawReportLine "${vmSort}" "${vmName}" "${vmDC}" \
            "${vmBackupPolicy}" "${TMP_BKUP_REMOTE_ONLY}" "${anyBackups}"
    else
        # VM completely backed up
        generateRawReportLine "${vmSort}" "${vmName}" "${vmDC}" \
            "${vmBackupPolicy}" "${TMP_BKUP_BOTH_LOCAL_REMOTE}" "${anyBackups}"
    fi
done
}


# Process a single federation
# $1 IP address of a single OVC in the federation
processFed() {
    rm -f "${TMP_VM_LIST}"
    touch "${TMP_VM_LIST}"
    rm -f "${TMP_BACKUP_LIST}"
    touch "${TMP_BACKUP_LIST}"

    earlier="$(date 2>/dev/null --date="${AGE}" +"%Y%m%d%H%M" || date -v -1d)"
    if [ -z "${earlier}" ]; then
        echo >&2 Date problem.
        exit 1
    fi

    allOVCNodes="$(getAllOVCNodes "$1")"
    singleNode="$(echo "${allOVCNodes}" | head -n 1)"

    # Only need the VM list once, federation wide
    #echo "Processing VMs ${singleNode}"
    returnVMData "${singleNode}" >> "${TMP_VM_LIST}"

    # Only need the backup data once, federation wide
    #echo "Processing backup ${singleNode}"
    returnBackupData "${singleNode}" "${earlier}" >> "${TMP_BACKUP_LIST}"

    generateRawReport "${TMP_VM_LIST}" "${TMP_BACKUP_LIST}"
}

# Populates a table in HTML format.
# $1 - header for the table
# $2 - the source file that contains entries to process
generateHTMLTableOfBackups() {
    local header="$1"
    local fileToProcess="$2"

    echo '<table style="width:100%">'
    echo "<caption><h2>${header}</h2></caption>"
    echo '<tr><th>VM</th><th>DC</th><th>Backup policy</th><th>Backup name</tr>'

    touch "${fileToProcess}"
    sort "${fileToProcess}" | while read aLine; do
        vmName="$(echo "${aLine}" | cut -d"${DELIM}" -f2)"
        f3="$(echo "${aLine}" | cut -d"${DELIM}" -f3)"
        f4="$(echo "${aLine}" | cut -d"${DELIM}" -f4)"
        f5="$(echo "${aLine}" | cut -d"${DELIM}" -f5)"

        # Output for a detail line?
        if [ "${vmName}" == "${DETAILLINE}" ]; then
            # Output for the detail line
            tdLine='<td>'
            vmName=""
            vmPolicy=""
            vmDC="${f4}"
            vmBkupName="${f3}"
        else
            # Output for a header line
            tdLine='<td class="line">'
            vmPolicy="${f4}"
            vmDC="${f3}"
            vmBkupName="&emsp;"
        fi
        echo "${tdLine}${vmName}</td>${tdLine}${vmDC}</td>${tdLine}" \
            "${vmPolicy}</td>${tdLine}${vmBkupName}</td></tr>"
    done
    echo '</table>'
    echo ''
    echo ''
}


# Generate full html output for a collection of inputs
# $1 - name of federation
# $2 - tmp file with vms not backed up
# $3 - tmp file with local only VMs
# $4 - tmp file with remote only VMs
# $5 - tmp file with local/remote backups for VMs
generateHTMLOutput() {
    local federationName="$1"
    local notBackedUp="$2"
    local localOnly="$3"
    local remoteOnly="$4"
    local bothLocalRemote="$5"

    echo '<!DOCTYPE html>'
    echo '<html lang="en">'
    echo '<head>'
    echo '<meta charset="utf-8"/>'
    echo '<title>Federation backup report</title>'
    echo '<style>'
    echo '.line { border-top: 1px dashed black; }'
    echo 'th { text-align: left; }'
    echo '</style>'
    echo '</head>'
    echo '<body>'
    echo "<h1>Report for federation ${federationName}</h1>"

    generateHTMLTableOfBackups "VMs wthout backups" "${notBackedUp}"
    generateHTMLTableOfBackups "VMs with local only backups" "${localOnly}"
    generateHTMLTableOfBackups "VMs with remote only backups" "${remoteOnly}"
    generateHTMLTableOfBackups "VMs with local and remote backups" \
        "${bothLocalRemote}"

    echo '**** End of report' "Version: ${VERSION}"
    echo '</body>'
    echo '</html>'
}

# Checks a command exists, reports if missing
# $1 - command that is needed
needsCmd() {
    if [ -z "$(which "$1")" ]; then
        echo >&2 "Missing vital command $1"
        exit 1
    fi
}


#################################################################
rm -f "${ERROR}"
rm -f "${OUTPUT}"

# Check for packages xmlstarlet, sshpass, mutt
if [ -z "${SSH_CACHE_RESPONSES}" ]; then
    needsCmd "sshpass"
fi
needsCmd "xmlstarlet"
needsCmd "mutt"

# Examine the federation, producing output files
processFed "${OVC}"

# Reformat the output
generateHTMLOutput > "${OUTPUT}" "${FEDERATIONNAME}" "${TMP_NOT_BKUP}" \
    "${TMP_BKUP_LOCAL_ONLY}"  \
    "${TMP_BKUP_REMOTE_ONLY}" "${TMP_BKUP_BOTH_LOCAL_REMOTE}"

# Does not attempt to remove the TMP files. If that is needed, add a trap
# at the beginning of the code.

# Send the mail 
if [ ! -z "${SSH_CACHE_RESPONSES}" ]; then
  echo "Not mailing, in debug mode. File is ${OUTPUT}"
  exit 1
fi

mutt -e "set content_type=text/html" "${EMAILTO}" \
    -s "SimpliVity ${FEDERATIONNAME} backup report" < "${OUTPUT}"


# End
