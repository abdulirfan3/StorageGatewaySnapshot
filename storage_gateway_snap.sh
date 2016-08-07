#!/bin/bash
#
# Author:       Abdul Mohammed
# Parameter:    <GATEWAY ARN>
# Usage:        <script_name> <GATEWAY ARN>
#
# Description:  Create snapshot for storage gateway volumes
#               Copy to DR region if gateway is PROD, 
#               For DEV gateway, just snapshot and NO copy
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
export DATE=`date +"%Y%m%d"`
export DATETIME=`date +"%Y%m%d_%H%M%S"`

#DATE=`date +%Y_%m_%d-%k_%M`
LOGFILE=${LOGDIR}/snapshots_${DATETIME}
#exec 1>> $LOGFILE.log
#exec 2>> $LOGFILE.err

export BATCH=2      # nb of snap ids in a batch
export BATCH_COUNT=0

export SOURCE_RGN=us-east-1
export TARGET_RGN=us-west-2
export AUTOBACKUP_TAG=AutomatedBackupSG
export BACKUP_TAG=StorageGateway
export SNAP_LIST=${LOGDIR}/snap_list_${DATETIME}
export SNAP_COPY_LIST=${LOGDIR}/snap_copy_list_${DATETIME}
export SNAP_COPY_LIST_RETRY=${LOGDIR}/snap_copy_list_retry_${DATETIME}
export SNAP_LIST_TARGET_RGN=${LOGDIR}/snap_list_target_rgn_${DATETIME}
> $SNAP_LIST
> $SNAP_COPY_LIST
> $SNAP_COPY_LIST_RETRY
> $SNAP_LIST_TARGET_RGN


###########################################
# Check if First parameter(SID) is passed #
###########################################
if [ $1 ];then
  GATEWAYARN=$1;export GATEWAYARN
else
  echo "NO GATEWAY ARN PROVIDED"
  exit 1
fi

# Figure out Backup Type Tags, All SNAP are incremental.  We just create this to get rid of snaps using DAILY/FULL Tags
SNAPTAG=`date +%A`
if [ "$SNAPTAG" = "Sunday" ]
then
  export BACKUPTYPE_TAG=WEEKLY
else
  export BACKUPTYPE_TAG=DAILY
fi


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

function create_snap_n_tag(){

echo
export INPUT=$1
einfo "Starting Gateway snapshot gateway-arn: $1"

for VOL in $(aws storagegateway list-volumes --gateway-arn ${INPUT} --query 'VolumeInfos[*].VolumeARN' --output text)
do
aws --region ${SOURCE_RGN} storagegateway list-tags-for-resource --resource-arn ${VOL} --query 'Tags[].{K:Key,V:Value}' --output text > desc_tags
  VOL_TAG=`grep Name desc_tags | awk -F '\t' '{print $2}'`
  BU_TAG=`grep BU desc_tags | awk -F '\t' '{print $2}'`
  VOL_ID=${VOL}
  VOL_NAME="${VOL_ID##*/}"
  einfo "Running Below Command to Create SNAPSHOT for $VOL"
  einfo "aws --region ${SOURCE_RGN} storagegateway create-snapshot --volume-arn ${VOL} --snapshot-description GatewaySnapSandboxForVolumeName${VOL_NAME}-IscsiName${VOL_TAG} --query SnapshotId"
  aws --region ${SOURCE_RGN} storagegateway create-snapshot --volume-arn ${VOL} --snapshot-description GatewaySnapSandboxForVolumeName${VOL_NAME}-IscsiName${VOL_TAG} --query SnapshotId >> $SNAP_LIST 2>&1
  if [ "$?" -eq 0 ];
  then
    eok "snapshot creation successfully started for vol: ${VOL_TAG} volid: ${VOL_NAME}"
    echo
    # Create tags
    sleep 2
    SNAPID=$(tail -1 $SNAP_LIST)
    einfo "Running below command to create tags for snapshot..."
    einfo "aws --region ${SOURCE_RGN} ec2 create-tags --resources ${SNAPID} --tags Key=Name,Value="${VOL_TAG}" Key=BU,Value="${BU_TAG}" Key=VolumeId,Value=${VOL_NAME} Key=BackupType,Value=${BACKUPTYPE_TAG} Key=CreatedBy,Value=${AUTOBACKUP_TAG} Key=BackupVolume,Value=${BACKUP_TAG}"
    aws --region ${SOURCE_RGN} ec2 create-tags --resources ${SNAPID} --tags Key=Name,Value="${VOL_TAG}" Key=BU,Value="${BU_TAG}" Key=VolumeId,Value=${VOL_NAME} Key=BackupType,Value=${BACKUPTYPE_TAG} Key=CreatedBy,Value=${AUTOBACKUP_TAG} Key=BackupVolume,Value=${BACKUP_TAG}
  else
    eerror "SNAPSHOT creation failed for vol: ${VOL_TAG} volid: ${VOL_TAG}"
    #Log_Close
  fi
done
}


check_snap_staus() {

echo
einfo Start of checking snapshot state so it can be added to copy list
  export INPUT=$1
  > $SNAP_COPY_LIST
  > $SNAP_COPY_LIST_RETRY
  for SNAP in `cat $INPUT`
  do
    END=$((SECONDS+3600))
    SNAP_STATE=$(aws --region ${SOURCE_RGN} ec2 describe-snapshots --snapshot-ids ${SNAP} --query Snapshots[].State --output text)
    einfo "Checking SNAPSHOT state for: ${SNAP}"
    while [ $SECONDS -lt $END ]; do
    # Do what you want.
      if [ "${SNAP_STATE}" = "completed" ]
      then
        # Break out of loop and capture SNAP-ID so we can start copy using this SNAP-ID
        einfo "SNAPSHOT: ${SNAP} is in completed state, adding to copy list.."
        #echo ----------------------------------------------------------------
        echo ${SNAP} >> $SNAP_COPY_LIST
        export SNAP_STATE_CHECK=TRUE
        break
      else
        einfo "SNAPSHOT: ${SNAP} is still NOT in completed state, current state: ${SNAP_STATE}"
        sleep 10
        SNAP_STATE=$(aws --region ${SOURCE_RGN} ec2 describe-snapshots --snapshot-ids ${SNAP} --query Snapshots[].State --output text)
        export SNAP_STATE_CHECK=FALSE
      fi
    done

    # PUT BAD/RETRY SNAP-ID here after timeout of 3600 seconds
    # This is done, so we can at least start the initial copy and can come back to the ones taking long time
    if [ "${SNAP_STATE_CHECK}" = "TRUE" ]
    then
      :  # DO NOTHING
    else
      einfo "SNAPSHOT: ${SNAP} is still not in COMPLETED state after 3600 seconds"
      einfo "Adding the above snapshot to retry list"
      echo ${SNAP} >> $SNAP_COPY_LIST_RETRY
    fi
    # put a flag file, if things fail 3rd time as well
  done
einfo End of checking snapshot state
}


# At this point it is assumed that snapshot are in completed state
copy_snap_to_target_region() {

echo
einfo Start of copy snapshot to $TARGET_RGN region
export INPUT=$1
#> $SNAP_LIST_TARGET_RGN
  for SNAPCOPYID in `cat $INPUT`
  do
    DR_MSG="Copy from ${SOURCE_RGN} for DR --- "
    SNAP_DESC=$(aws --region ${SOURCE_RGN} ec2 describe-snapshots --snapshot-ids ${SNAPCOPYID} --query Snapshots[].Description --output text)
    FINAL_DESC=${DR_MSG}${SNAP_DESC}

    # Get all tags so it can be copied over
    aws --region ${SOURCE_RGN} ec2 describe-tags --filters Name=resource-id,Values=${SNAPCOPYID} --query 'Tags[].{K:Key,V:Value}' --output text > desc_tags
    BU_TAG=`grep BU desc_tags | awk -F '\t' '{print $2}'`
    BackupType_TAG=`grep BackupType desc_tags | awk -F '\t' '{print $2}'`
    Name_TAG=`grep Name desc_tags | awk -F '\t' '{print $2}'`
    VolumeId_TAG=`grep VolumeId desc_tags | awk -F '\t' '{print $2}'`

    # Copy snapshot to target region
    einfo "Running Below Command to copy SNAPSHOT for ${SNAPCOPYID}"
    einfo "aws --region $TARGET_RGN ec2 copy-snapshot --source-region $SOURCE_RGN --source-snapshot-id $SNAPCOPYID --description "\"""${FINAL_DESC}""\"" --output text"

    aws --region $TARGET_RGN ec2 copy-snapshot --source-region $SOURCE_RGN --source-snapshot-id $SNAPCOPYID --description "${FINAL_DESC}" --output text >> $SNAP_LIST_TARGET_RGN 2>&1
    # If creation started successfully then start tagging
    if [ "$?" -eq 0 ]
    then
      eok "Copy SNAPSHOT: $SNAPCOPYID started successfully..."
      echo
      einfo "Tagging copy SNAPSHOT using below syntax"
      TARGET_SNAPID=$(tail -1 $SNAP_LIST_TARGET_RGN)
      # Only adding successful to list
      list="${list} ${TARGET_SNAPID}"
      sleep 1
      einfo "aws --region $TARGET_RGN ec2 create-tags --resources ${TARGET_SNAPID} --tags Key=Name,Value="${Name_TAG}" Key=BU,Value="${BU_TAG}" Key=BackupType,Value=${BACKUPTYPE_TAG} Key=CreatedBy,Value=${AUTOBACKUP_TAG} Key=Org_VolumeId,Value=${VolumeId_TAG} Key=BackupVolume,Value=${BACKUP_TAG}"
      aws --region $TARGET_RGN ec2 create-tags --resources ${TARGET_SNAPID} --tags Key=Name,Value="${Name_TAG}" Key=BU,Value="${BU_TAG}" Key=BackupType,Value=${BACKUPTYPE_TAG} Key=CreatedBy,Value=${AUTOBACKUP_TAG} Key=Org_VolumeId,Value=${VolumeId_TAG} Key=BackupVolume,Value=${BACKUP_TAG}
    else
      eerror "Looks like copy-snapshot failed for source snapshot: ${SNAPCOPYID}"
      #Log_Close
    fi

    BATCH_COUNT=$(( ${BATCH_COUNT} + 1 ))

    if [ ${BATCH_COUNT} -eq ${BATCH} ]; then
    # Wait for completion
      einfo "waiting for batch to complete"
      einfo "Current batch snapshot list for DR region is: ${list}"
      einfo "Running below command to check for status of current batch.."
      einfo "aws --region $TARGET_RGN ec2 describe-snapshots --snapshot-ids ${list} --query Snapshots[].State --output text"
      einfo "Sleeping for 15 seconds in a loop until snapshot-copy finishes or we hit a timeout of 3600 seconds, whichever comes first..."
      einfo "######################### Start of 15 second sleep loop  #########################"
      waitbatch
      einfo
      einfo "#######################################################################"
      einfo "########################## BATCH COMPLETE #############################"
      einfo "#######################################################################"
      einfo
      einfo "Starting next batch"
      BATCH_COUNT=0
      list=""
    fi
  done

einfo
einfo End of copy snapshot to $TARGET_RGN region
einfo

}

waitbatch() {
TIMEOUT=$((SECONDS+3600))

if [ ${BATCH_COUNT} -gt 0 ]; then
  while [ `aws --region $TARGET_RGN ec2 describe-snapshots --snapshot-ids ${list} --query Snapshots[].State --output text | grep -o 'completed' | wc -w` -lt ${BATCH} ]; do

  einfo "Waiting for snapshot copy to complete: ${list}"
  sleep 15
  # Give up if TIMEOUT is reached, also see what can be done about retries incase some reach time out..
  # Maybe delete the copy from target region...
  if [ $SECONDS -gt ${TIMEOUT} ]
  then
    echo
    ewarn "Timeout reached for copy to $TARGET_RGN: ${list}"
    ewarn "Deleting snapshot copy of ${list}"
    ewarn "Running below command to delete the snapshot copy..."
    ewarn "aws --region $TARGET_RGN ec2 delete-snapshot --snapshot-id ${list}"
    echo
    aws --region $TARGET_RGN ec2 delete-snapshot --snapshot-id ${list}
    sleep 15
    break
  fi
  done
fi
}


# Main Logic
Log_Open

# We set parameter GATEWAY_TYPE to either dev or prod.  Dev will only do snapshot, prod will
# do snapshot plus copy to DR region...

einfo "List of Gateway's attached to this AWS account"
echo
aws storagegateway list-gateways --output table
echo
# CHANGE BELOW TO YOUR STORAGE GATEWAY ARN
# DEV system do not copy snapshot to DR region
# CHANGE_THIS  -- ACCOUNT-ID, STORAGE-GATEWAY-ID
if [[ ${GATEWAYARN} = "arn:aws:storagegateway:us-east-1:111111111111:gateway/sgw-XXXXXXX" ]]
then
  export GATEWAY_TYPE=DEV
  einfo "Gateway type is ${GATEWAY_TYPE}"
  einfo "Gateway ARN: ${GATEWAYARN}"
  if [ -e lock_file_gateway_snap_dev ]
  then
    eerror "Lock file already present, that mean either gateway snapshot is still running"
    eerror "or lock file was not cleaned up...exiting script...Lock file: ${PWD}/lock_file_gateway_snap_dev"
    Log_Close
    mailx -s "Errors for Storage Gateway Snapshot" -r "Storage_Gateway_Admin" email@domain.com < ${LOGFILE}
    exit 1
  fi
# CHANGE BELOW TO YOUR STORAGE GATEWAY ARN
# PROD system do copy snapshot to DR region  
# CHANGE_THIS  -- ACCOUNT-ID, STORAGE-GATEWAY-ID
elif [[ ${GATEWAYARN} = "arn:aws:storagegateway:us-east-1:111111111111:gateway/sgw-XXXXXXX" ]]
then
  export GATEWAY_TYPE=PROD
  einfo "Gateway type is ${GATEWAY_TYPE}"
  einfo "Gateway ARN: ${GATEWAYARN}"
  if [ -e lock_file_gateway_snap_prod ]
  then
    eerror "Lock file already present, that mean either gateway snapshot is still running"
    eerror "or lock file was not cleaned up...exiting script...Lock file: ${PWD}/lock_file_gateway_snap_prod"
    Log_Close
    mailx -s "Errors for Storage Gateway Snapshot" -r "Storage_Gateway_Admin" email@domain.com < ${LOGFILE}
    exit 1
  fi
else
  eerror "Gateway Provided is not the one from current environment, it needs to be either one of the below"
  eerror "arn:aws:storagegateway:us-east-1:111111111111:gateway/sgw-XXXXXXX"
  eerror "arn:aws:storagegateway:us-east-1:111111111111:gateway/sgw-XXXXXXX"
  Log_Close
  exit 1
fi

# Run all the function accordingly.
# For dev only create snapshot and tag it, no need to copy
# For Prod create snapshot, tag it, copy over to DR region..
if [[ "${GATEWAY_TYPE}" = "DEV" ]]; then
  create_snap_n_tag ${GATEWAYARN}
  check_snap_staus $SNAP_LIST
  check_snap_staus $SNAP_COPY_LIST_RETRY
  rm lock_file_gateway_snap_dev
elif [[ "${GATEWAY_TYPE}" = "PROD" ]]; then
  create_snap_n_tag ${GATEWAYARN}
  check_snap_staus $SNAP_LIST
  copy_snap_to_target_region $SNAP_COPY_LIST
  einfo "****************************************************************************************************"
  einfo "****************************************************************************************************"
  einfo "Start of checking snapshot state and copy snapshot to $TARGET_RGN region again"
  einfo "Will only run if snapshots where not in completed state previously and were added to retry list"
  einfo "****************************************************************************************************"
  einfo "****************************************************************************************************"
  check_snap_staus $SNAP_COPY_LIST_RETRY
  copy_snap_to_target_region $SNAP_COPY_LIST
  rm lock_file_gateway_snap_prod
fi

Log_Close

# If you want to copy logs to an S3 bucket
#aws s3 cp ${LOGFILE} s3://BUCKET-NAME/StorageGateway/ --sse

if grep -wqE 'ERROR|WARNING' ${LOGFILE}
then
  mailx -s "Errors for Storage Gateway Snapshot" -r "Storage_Gateway_Admin" email@domain.com < ${LOGFILE}
  exit 1
  # Do not delete any log files for debug
else
  rm desc_tags >/dev/null 2>&1
  rm $SNAP_LIST >/dev/null 2>&1
  rm $SNAP_COPY_LIST >/dev/null 2>&1
  rm $SNAP_COPY_LIST_RETRY >/dev/null 2>&1
  rm $SNAP_LIST_TARGET_RGN >/dev/null 2>&1
  rm $Pipe >/dev/null 2>&1
fi

