Script to create snapshot of storage gateway.  We have 2 gateways, One prod and another one that is Dev.  For PROD gateway we want our snapshot to be copied over to DR region(us-west-2).  For Dev, we only take snapshot in local region.

Following are the list of scripts that can be scheduled in cron

storage_gateway_snap.sh  = Create snapshot of storage gateway volumes.  Change gateway ARN for DEV and PROD accordingly.

delete_snapshot_older_than.sh = Script to delete snapshot older than 30 days for weekly and 20 days for daily filter.  This script goes hand in hand with "storage_gateways_snap.sh".  As we create tags, that have "CreatedBy" and "BACKUPTYPE_TAG" that we use to filter for deleting old snapshot.

Look at "sample_log_file_for_create_gateway_snap.log" for output of storage_gateway_snap.sh in

Additional script not related to Storage Gateway:

snapshot_checking_script.sh = Script to check if any volumes attached to servers don't have recent snapshot(older than 48 hours).  If there are any volumes/servers that do not have recent snapshot we send an email alert.


AWS Policy used by these script should have following allowed: 

storagegateway list-volume
storagegateway list-tags-for-resource
storagegateway create-snapshot
storagegateway list-gateways
ec2 create-tags 
ec2 describe-snapshots
ec2 describe-tags
ec2 copy-snapshot
ec2 delete-snapshot

