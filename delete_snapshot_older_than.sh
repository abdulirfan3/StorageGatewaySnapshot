#!/bin/bash
#
# Author: Abdul Mohammed
# Usage : <Script_name>
# 
# Description: 
# This script will delete storage-gateway snapshot with tag of CreatedBy=AutomatedBackupSG
# Delete snapshot with daily filter greater than 20
# Delete snapshot with Weekly filter greater than 30
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
export DATE=`date +"%Y%m%d"`
export DATETIME=`date +"%Y%m%d_%H%M%S"`

#DATE=`date +%Y_%m_%d-%k_%M`
LOGFILE=${LOGDIR}/delete_gateway_snapshots_${DATETIME}

export SOURCE_RGN=us-east-1
export DR_RGN=us-west-2
export SNAP_LIST_DAILY=${LOGDIR}/del_snap_list_daily_${DATETIME}
export SNAP_LIST_WEEKLY=${LOGDIR}/del_snap_list_weekly_${DATETIME}
> $SNAP_LIST_DAILY
> $SNAP_LIST_WEEKLY


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



delete_snapshots() {

export RGN=$1
export SNAP_LIST_DAILY_MSTR=${LOGDIR}/del_snap_list_daily_mstr_${RGN}_${DATETIME}
export SNAP_LIST_WEEKLY_MSTR=${LOGDIR}/del_snap_list_weekly_mstr_${RGN}_${DATETIME}
> $SNAP_LIST_DAILY_MSTR
> $SNAP_LIST_WEEKLY_MSTR
# Dates
datecheck_20d=`date +%Y-%m-%d --date '20 days ago'`
datecheck_s_20d=`date --date="$datecheck_20d" +%s`

datecheck_30d=`date +%Y-%m-%d --date '30 days ago'`
datecheck_s_30d=`date --date="$datecheck_30d" +%s`


einfo Collecting snapshot information about all snapshot using DAILY filter
einfo Writing snapshot information to $SNAP_LIST_DAILY_MSTR

### ADD DAILY FILTER HERE
aws --region $RGN ec2 describe-snapshots --filters "Name=tag:CreatedBy,Values=AutomatedBackupSG" "Name=tag:BackupType,Values=DAILY" --query Snapshots[].[SnapshotId,StartTime,Description] --output text > $SNAP_LIST_DAILY_MSTR

einfo Collecting snapshot information about all snapshot using WEEKLY filter
einfo Writing snapshot information to $SNAP_LIST_WEEKLY_MSTR
### ADD WEEKLY FILTER HERE
aws --region $RGN ec2 describe-snapshots --filters "Name=tag:CreatedBy,Values=AutomatedBackupSG" "Name=tag:BackupType,Values=WEEKLY" --query Snapshots[].[SnapshotId,StartTime,Description] --output text > $SNAP_LIST_WEEKLY_MSTR

cat $SNAP_LIST_DAILY_MSTR | awk -F '\t' '{print $1}' > $SNAP_LIST_DAILY
cat $SNAP_LIST_WEEKLY_MSTR | awk -F '\t' '{print $1}' > $SNAP_LIST_WEEKLY

einfo "######################################################"
einfo Deleting snapshot using DAILY filter
einfo "######################################################"
for SNAP in $(cat ${SNAP_LIST_DAILY})
do
  datecheck_old=`grep ${SNAP} $SNAP_LIST_DAILY_MSTR | awk -F '\t' '{print $2}' | awk -F "T" '{printf "%s\n", $1}'`
  datecheck_s_old=`date "--date=$datecheck_old" +%s`
  if (( $datecheck_s_old <= $datecheck_s_20d ));
  then
    desc_snap=`grep ${SNAP} $SNAP_LIST_DAILY_MSTR | awk -F '\t' '{print $3}'`
    einfo "Deleting DAILY snapshot: ${SNAP} with Description of ${desc_snap}"
    einfo "Running below command to delete snapshot..."
    einfo "aws --region $RGN ec2 delete-snapshot --snapshot-id ${SNAP}"
    aws --region $RGN ec2 delete-snapshot --snapshot-id ${SNAP}
    EXIT_STATUS=$?
    if [ "$EXIT_STATUS" -eq 0 ] && [ "${RGN}" = "us-east-1" ]
    then
      eok "Successfully started deleting of snapshot: ${SNAP} from Region: ${RGN}"
    elif [ "$EXIT_STATUS" -eq 0 ] && [ "${RGN}" = "us-west-2" ]
    then
      eok "Successfully started deleting of snapshot: ${SNAP} from Region: ${RGN}"
    else
      ewarn "Could not find proper exit status and region for $SNAP"
    fi
    sleep 2
    echo
  fi
done

einfo "######################################################"
einfo Deleting snapshot using WEEKLY filter
einfo "######################################################"
for SNAP in $(cat ${SNAP_LIST_WEEKLY})
do
  datecheck_old=`grep ${SNAP} $SNAP_LIST_WEEKLY_MSTR | awk -F '\t' '{print $2}' | awk -F "T" '{printf "%s\n", $1}'`
  datecheck_s_old=`date "--date=$datecheck_old" +%s`
  if (( $datecheck_s_old <= $datecheck_s_30d ));
  then
    desc_snap=`grep ${SNAP} $SNAP_LIST_WEEKLY_MSTR | awk -F '\t' '{print $3}'`
    einfo "Deleting WEEKLY snapshot: ${SNAP} with Description of ${desc_snap}"
    einfo "Running below command to delete snapshot..."
    einfo "aws --region $RGN ec2 delete-snapshot --snapshot-id ${SNAP}"
    aws --region $RGN ec2 delete-snapshot --snapshot-id ${SNAP}
    EXIT_STATUS=$?
    if [ "$EXIT_STATUS" -eq 0 ] && [ "${RGN}" = "us-east-1" ]
    then
      eok "Successfully started deleting of snapshot: ${SNAP} from Region: ${RGN}"
    elif [ "$EXIT_STATUS" -eq 0 ] && [ "${RGN}" = "us-west-2" ]
    then
      eok "Successfully started deleting of snapshot: ${SNAP} from Region: ${RGN}"
    else
      ewarn "Could not find proper exit status and region for $SNAP"
    fi
    sleep 2
    echo
  fi
done
}


Log_Open


einfo "#######################################"
einfo START OF SCRIPT
einfo "#######################################"

einfo "######################################################"
einfo Deleting snapshot in $SOURCE_RGN
einfo "######################################################"
delete_snapshots $SOURCE_RGN

einfo "######################################################"
einfo Deleting snapshot in $DR_RGN
einfo "######################################################"
delete_snapshots $DR_RGN

echo
einfo "#######################################"
einfo END OF SCRIPT
einfo "#######################################"

Log_Close

# uncomment below to send logs to an S3 bukkcet 
#aws s3 cp ${LOGFILE} s3://BUCKET-NAME/StorageGateway/ --sse

if grep -wqE 'ERROR|WARNING' ${LOGFILE}
then
  mailx -s "Errors for Storage Gateway Delete Snapshot" -r "Storage_Gateway_Admin" email@domain.com < ${LOGFILE}
  exit 1
else
  rm $SNAP_LIST_DAILY >/dev/null 2>&1
  rm $SNAP_LIST_WEEKLY >/dev/null 2>&1
  rm $SNAP_LIST_DAILY_MSTR >/dev/null 2>&1
  rm $SNAP_LIST_WEEKLY_MSTR >/dev/null 2>&1
  rm ${LOGDIR}/del_snap_list_daily_mstr_${SOURCE_RGN}_${DATETIME} >/dev/null 2>&1
  rm ${LOGDIR}/del_snap_list_weekly_mstr_${SOURCE_RGN}_${DATETIME} >/dev/null 2>&1
  rm ${LOGDIR}/del_snap_list_daily_mstr_${DR_RGN}_${DATETIME} >/dev/null 2>&1
  rm ${LOGDIR}/del_snap_list_weekly_mstr_${DR_RGN}_${DATETIME} >/dev/null 2>&1
fi



#clean() {
##rm $SNAP_LIST_DAILY >/dev/null 2>&1
#rm $SNAP_LIST_WEEKLY >/dev/null 2>&1
#}

# Trap to run clean function on EXIT of script
#trap clean EXIT

find $LOGDIR -type f -name "*.log" -mtime +40 -exec rm {} \; 2>/dev/null