#!/bin/bash
#
# Author:       Abdul Mohammed
# Parameter:    None
# Usage:        <script_name>
#
# Description:  Script to check if there is a recent(less than 2 days) snapshot in place for each volume
#               except for servers in exception list
#
#

### verbosity levels
silent_lvl=0
crt_lvl=1
err_lvl=2
wrn_lvl=3
ntf_lvl=4
inf_lvl=5
dbg_lvl=6
verbosity=6

export LOGDIR=/tmp/logs
export DATETIME=`date +"%Y%m%d_%H%M%S"`

# Volumes must have a snapshot that is under $DAYS_MIN days old
export DAYS_MIN=2

# $DAY_MIN converted into seconds
export DAYS_MIN_SEC=$(date +%s --date "${DAYS_MIN} days ago")


LOGFILE=${LOGDIR}/snapshots_checking_${DATETIME}
SERVER_NO_SNAP_LIST=${LOGDIR}/server_no_snap_${DATETIME}
> $SERVER_NO_SNAP_LIST

export SOURCE_RGN=us-east-1

ScriptName=`basename $0`
Job=`basename $0 .sh`"_output"

### Different logging level
## esilent prints output even in silent mode
function esilent () { verb_lvl=$silent_lvl elog "$@" ;}
function enotify () { verb_lvl=$ntf_lvl elog "$@" ;}
function eok ()    { verb_lvl=$ntf_lvl elog "SUCCESS - $@" ;}
function ewarn ()  { verb_lvl=$wrn_lvl elog "WARNING - $@" ;}
function einfo ()  { verb_lvl=$inf_lvl elog "INFO ---- $@" ;}
function edebug () { verb_lvl=$dbg_lvl elog "DEBUG --- $@" ;}
function eerror () { verb_lvl=$err_lvl elog "ERROR --- $@" ;}
function ecrit ()  { verb_lvl=$crt_lvl elog "FATAL --- $@" ;}
function edumpvar () { for var in $@ ; do edebug "$var=${!var}" ; done }

function elog() {
if [ $verbosity -ge $verb_lvl ]; then
  datestring=`date +"%Y-%m-%d %H:%M:%S"`
  echo -e "$datestring - $@"
fi
}

#############################################
## START of output to a logfile using pipes
#############################################
function Log_Open() {
if [ $NO_JOB_LOGGING ] ; then
  einfo "Not logging to a logfile because -Z option specified." #(*)
else
  [[ -d $LOGDIR ]] || mkdir -p $LOGDIR
  Pipe=${LOGDIR}/${Job}_${DATETIME}.pipe
  mkfifo -m 700 $Pipe
  LOGFILE=${LOGDIR}/${Job}_${DATETIME}.log
  exec 3>&1
  tee ${LOGFILE} <$Pipe >&3 &
  teepid=$!
  exec 1>$Pipe
  PIPE_OPENED=1
  enotify Logging to $LOGFILE
fi
}

function Log_Close() {
if [ ${PIPE_OPENED} ] ; then
  exec 1<&3
  sleep 0.2
  ps --pid $teepid >/dev/null
  if [ $? -eq 0 ] ; then
    # a wait $teepid whould be better but some
    # commands leave file descriptors open
    sleep 1
    kill  $teepid
  fi
  rm $Pipe
  unset PIPE_OPENED
fi
}

Log_Open

# Look at exception list
grep -oP 'i-\w+' exception > ${LOGDIR}/tmp_exception

# Create FLAG file ...
# Function to create daily snapshots
for SERVER in `aws --region ${SOURCE_RGN} ec2 describe-instances --query 'Reservations[*].Instances[*].[InstanceId]' --output text`
do
  sleep 1
  echo "=========================================================================================="
  # Grab NAME and BU Values
  aws --region ${SOURCE_RGN} ec2 describe-tags --filters Name=resource-id,Values=$SERVER --query 'Tags[].{K:Key,V:Value}' --output text > ${LOGDIR}/desc_tags
  INST_TAG=`grep Name ${LOGDIR}/desc_tags | awk -F '\t' '{print $2}'`

  einfo "Processing server $SERVER - ${INST_TAG}"

  EX_SERVER=$(grep ${SERVER} ${LOGDIR}/tmp_exception)

  # for EX_SERVER in `grep ${EX_SERVER} ${LOGDIR}/tmp_exception`
  # do
    if [ "$SERVER" = "$EX_SERVER" ]
    then
      export SKIP=TRUE
    else
      export SKIP=FALSE
    fi
  # done

if [ "$SKIP" = "TRUE" ]
then
  echo "################################################################################################################"
  ewarn "skipping server $SERVER - ${INST_TAG} as it is in our EXCLUDE list"
  echo "################################################################################################################"
  echo
  ewarn "Volumes NOT being checked for recent snap(attached to this instance)"
  aws --region ${SOURCE_RGN} ec2 describe-volumes --filters Name=attachment.instance-id,Values=${SERVER} --query 'Volumes[*].{ID:VolumeId}' --output text
  echo
else
  volume_list=$(aws --region ${SOURCE_RGN} ec2 describe-volumes --filters Name=attachment.instance-id,Values=${SERVER} --query Volumes[].VolumeId --output text)
  for volume in ${volume_list};
  do
    # Grab all snapshot associated with this particular volume, and find the most recent snapshot time
    last_snap=$(aws ec2 describe-snapshots --region ${SOURCE_RGN} --output=text --filters "Name=volume-id,Values=${volume}" --query Snapshots[].[StartTime] | sed 's/T.*$//' | sort -u | tail -n1)
    sleep 0.5
    if [[ -z ${last_snap} ]]
    then
        ecrit "NO Snapshot found for volume: ${volume} -AWS InstId: ${SERVER} - ${INST_TAG}"
        ecrit "NO Snapshot found for volume: ${volume} -AWS InstId: ${SERVER} - ${INST_TAG}" >> ${SERVER_NO_SNAP_LIST}
    else
      last_snap_sec=$(date "--date=${last_snap}" +%s)

      # If the latest snapshot is older than $DAYS_MIN, send an alert.
      if [[ ${last_snap_sec} < ${DAYS_MIN_SEC} ]]; then
        ecrit "No recent Snapshot found for volume: ${volume} -AWS InstId: ${SERVER} - ${INST_TAG} - Last Snapshot: ${last_snap}"
        ecrit "No recent Snapshot found for volume: ${volume} -AWS InstId: ${SERVER} - ${INST_TAG} - Last Snapshot: ${last_snap}" >> ${SERVER_NO_SNAP_LIST}
      else
        eok "Last Snapshot for volume: ${volume} -AWS InstId: ${SERVER} - ${INST_TAG} was taken on ${last_snap}"
      fi
    fi
  done
fi
export SKIP=FALSE
done

Log_Close
# Report FATAL errors

if grep -wqE 'FATAL' ${SERVER_NO_SNAP_LIST}
then
  mailx -s "AWS Volumes found with No Recent Snapshot" -r "Storage_Snapshot_Admin" email@domain.com < ${SERVER_NO_SNAP_LIST}
  exit 1
  # Do not delete any log files for debug
else
  rm ${SERVER_NO_SNAP_LIST} >/dev/null 2>&1
  rm $Pipe >/dev/null 2>&1
fi