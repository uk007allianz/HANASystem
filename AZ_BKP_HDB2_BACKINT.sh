#!/bin/bash
#########################################################################################
# Programmed to create backups for a HANA 2.0 system
# 
# No guarantee at all. For nothing regarding backup and restore.
# Version 2.0 - Uwe Kaden (uwe.kaden@allianz.com)
# 
#
# Filename: AZ_BKP_HDB2_BACKINT.sh
# Debugging
# set -x
# Define Environment
########################################################################################
#
# Open issues:
# Returncode from subfunction
# Check whether the last backup failed or not
# 
#
#########################################################################################

#########################################################################################
### 							CUSTOMIZING SECTION START 				      	      ###

# Possible values for FULLDAY:
# Mon, Tue, Wed, Thu, Fri, Sat, Sun, ALL
FULLDAY=Mon
SID=BHS
INSTNO=00
# Catalog and file retention days
CATRET=35

### 							CUSTOMIZING SECTION END 				      	     ####
#########################################################################################
#########################################################################################
###																					  ###
### 						!	DO NOT TOUCH VALUES BELOW 	!						  ###
###																					  ###
#########################################################################################
LOWSID=$(echo ${SID} | tr '[:upper:]' '[:lower:]' )
## Sourcing the user profile for using script with cron
. /home/${LOWSID}adm/.profile
## Standard set
DIR_INSTANCE=/usr/sap/${SID}/HDB${INSTNO}
SCRIPT_DIR=${DIR_INSTANCE}/BACKUP
LOG_DIR=${SCRIPT_DIR}/LOGLOG
LOG_NAME=$(date '+%F')_LOGDEL.log
SCRIPTLOG=$(date '+%F')_SCRIPTLOG.log
EXE_DIR=${DIR_INSTANCE}/exe
TMPDIR=/tmp
LOG_NAME=$(date '+%F')_LOGDEL.log
TODAY=$(date '+%a')
DATESTAMP=$(date '+%F')
YESTERDAY=$(date -d "yesterday" '+%a')
DAYSPAST=$(date -d "${CATRET} days ago" '+%F')
MAILRE=MAILRE
BKPDAY=${FULLDAY}
# HANA specific values
USERSTORE_KEY=CVBKP
###
###
###
#########################################################################################
# START
#
# This main functions steers all the sub-functions except cleanup
#
main_call() {
echo "Main routine (main_call) started.  $(date)" >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
# Find all the active databases
cat > ${SCRIPT_DIR}/INFO_DB.sql << EOD
select DATABASE_NAME from m_databases where ACTIVE_STATUS='YES'
EOD
# Loop over the databases and pass the name to the other functions
# Each database will handled by an own call
declare -a databases=(`$EXE_DIR/hdbsql -a -U ${USERSTORE_KEY} -I  ${SCRIPT_DIR}/INFO_DB.sql`)
    for db in `echo "${databases[@]}" | tr -d \"`;do
	    # Reset value for backup day to default before the next loop
	    FULLDAY=${BKPDAY}
        ceck_status ${db}
		create_run ${db}
        run_backup ${db}
        clean_after_run ${db}
		maint_catalog  ${db}
        done
#rm -v ${SCRIPT_DIR}/INFO_DB.sql >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
echo "Main routine (main_call) finished.  $(date)" >> ${LOG_DIR}/${SCRIPTLOG} 2>&1

}
# END
#########################################################################################



#########################################################################################
# START
# Check status of the last backup
# Look into m_backup_catalog for the status of the last backup 
# https://help.sap.com/viewer/4fe29514fd584807ac9f2a04f6754767/2.0.03/en-US/20a8437d7519101495a3fa7ad9961cf6.html
#
ceck_status() {
echo "Checking status of the last backup (check_status) for ${1}.  $(date)" >> ${LOG_DIR}/${SCRIPTLOG} 2>&1

cat > ${SCRIPT_DIR}/CHK_YESTERDAYS_BKP_${1}.sql << EOC
select IFNULL((
select count(*) from sys_databases.m_backup_catalog 
where entry_type_name in ('complete data backup', 'incremental data backup')
and to_char(sys_end_time, 'DD.MM.YYYY') = (select  TO_CHAR (ADD_DAYS (CURRENT_DATE, -1), 'DD.MM.YYYY')   FROM DUMMY )
and database_name='${1}'
and state_name not in ('successful')
group by sys_start_time
order by sys_start_time desc),'0') from dummy
EOC

# If the result is NULL, the last backup was successful. 

YESTBKP=$(${EXE_DIR}/hdbsql -m -a -U ${USERSTORE_KEY} -I  ${SCRIPT_DIR}/CHK_YESTERDAYS_BKP_${1}.sql)

   if [ "${YESTBKP}" -ne "0" ]; then
      FULLDAY=ALL
	  echo "Last backup was not successful. Trying to execute fullbackup." >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
   else
         echo "Last backup was successful. Continue with standard settings." >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
   fi	  
rm ${SCRIPT_DIR}/CHK_YESTERDAYS_BKP_${1}.sql
 	  
echo "Checking status of the last backup (check_status) for ${1} finished.  $(date)" >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
}

# END
#########################################################################################



#########################################################################################
# START
# Create backup runs
#
create_run() {
echo "Create backup runs (create_run) for ${1}.  $(date)" >> ${LOG_DIR}/${SCRIPTLOG} 2>&1

 if [ "$TODAY" == "$FULLDAY" ]; then
  echo "BACKUP DATA FOR ${1} USING BACKINT ('BKP_${1}_COMP_${DATESTAMP}')" >> $TMPDIR/BKP_${1}_COMP_${TODAY}.sql
 else
     if [ "$FULLDAY" == "ALL" ]; then
                echo "BACKUP DATA FOR ${1} USING BACKINT ('BKP_${1}_COMP_${DATESTAMP}')" >> $TMPDIR/BKP_${1}_COMP_ALL.sql
         else
                echo "BACKUP DATA INCREMENTAL FOR ${1} USING BACKINT ('BKP_${1}_INCR_${DATESTAMP}')" >> $TMPDIR/BKP_${1}_INCR_${TODAY}.sql
        fi
 fi
 
echo "Creation of backup SQL (create_run) for $1 finished.  $(date)" >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
}
# END
#########################################################################################


#########################################################################################
# START
# run backup
# check for the sql command file first
run_backup() {
echo "Start backup(run_backup) for ${1}.  $(date)" >> ${LOG_DIR}/${SCRIPTLOG} 2>&1

 if [ "$(ls /tmp/BKP_${1}_????_???.sql | wc -l)" -ne "1" ]; then
  echo "Found not only one SQL commandfile for backup" >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
 else
  $EXE_DIR/hdbsql -U ${USERSTORE_KEY} -I $(ls /tmp/BKP_${1}_????_???.sql) -o ${LOG_DIR}/BACKUP_LOG_${1}_${TODAY}.log >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
    declare -i HDBSQL_EXIT=$?
    if  ! [ ${HDBSQL_EXIT} -eq 0 ]; then
      echo "Backup for ${1} failed. Return code of hdbsql: ${HDBSQL_EXIT}" >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
          mail_send ${1} "${SID}: Database ${1} not backed up." "Returncode was ${HDBSQL_EXIT}"
    fi
 fi
echo "Backup(run_backup) finished.  $(date)" >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
}
# END
#########################################################################################



#########################################################################################
# START
# Cleanup after run:
clean_after_run() {
echo "Running cleanup (clean_after_run). Script is starting $(date)" >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
ls /tmp/BKP_${1}_* >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
   if [ "$?" -eq "0" ]; then
     rm -v /tmp/BKP_${1}_* >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
         echo "Cleanup finished. Old files deleted $(date) " >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
   else
     echo "Cleanup finished. Nothing to do. $(date) " >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
   fi
}
# END
#########################################################################################


#########################################################################################
# START
# Maintain the catalog
maint_catalog() {
echo "Maintaining backup catalog  (maint_catalog).  $(date)" >> ${LOG_DIR}/${SCRIPTLOG} 2>&1

cat > ${SCRIPT_DIR}/BKPID_DEL_${1}.sql << EOK
select  top 1 BACKUP_ID from "SYS_DATABASES"."M_BACKUP_CATALOG" where to_char(sys_end_time, 'DD.MM.YYYY') = (select  TO_CHAR (ADD_DAYS (CURRENT_DATE, -${CATRET}), 'DD.MM.YYYY')   FROM DUMMY ) AND ENTRY_TYPE_NAME LIKE 'complete%data%backup' AND DATABASE_NAME='${1}' AND STATE_NAME='successful'
EOK

BKPID=$(${EXE_DIR}/hdbsql -a -U ${USERSTORE_KEY} -I  ${SCRIPT_DIR}/BKPID_DEL_${1}.sql)

      if [[ -n "${BKPID}" ]]; then
        echo "Obsolete backup with ID "${BKPID}" for "${1}" found" >> ${LOG_DIR}/${SCRIPTLOG}
      
# Create and execute deletion from filesystem and catalog
cat > ${SCRIPT_DIR}/CLEAN_CAT_${1}.sql << EOC
BACKUP CATALOG DELETE FOR ${1} ALL BEFORE BACKUP_ID ${BKPID} COMPLETE
EOC
            ${EXE_DIR}/hdbsql -a -U ${USERSTORE_KEY} -I  ${SCRIPT_DIR}/CLEAN_CAT_${1}.sql -o ${LOG_DIR}/CLEAN_CAT_${1}.log
            declare -i HDBSQL_CAT_EXIT=$?
                if  [ ${HDBSQL_CAT_EXIT} -eq 0 ]; then
                   mail_send ${1} "${SID}: Backup catalog for ${1} cleaned." "Backup ID was ${BKPID}"
                   rm -v ${SCRIPT_DIR}/CLEAN_CAT_${1}.sql >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
                else
                      mail_send ${1} "${SID}: Backup catalog for ${1} clean failed." "Backup ID was ${BKPID}. Error# was ${HDBSQL_CAT_EXIT}"
                fi
      else
         echo "No obsolete backups matching retention days "${CATRET}" for "${1}" found."   >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
      fi
echo "Maintaining backup catalog finished (maint_catalog).  `date`" >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
}
# END
#########################################################################################



#########################################################################################
# START
mail_send() {
 echo ""${1}" Additional information: "${3}"" | mail -r sap-hana@allianz.com -s "${2}" $(cat ${SCRIPT_DIR}/${MAILRE})
}
# END
#########################################################################################



#########################################################################################
# START
cleanup() {
echo "Run cleanup files (cleanup).  $(date)" >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
#delete all FILES
rm -v ${SCRIPT_DIR}/*.sql >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
echo "Cleanup files done.  $(date)" >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
}
# END
#########################################################################################



#########################################################################################
# START
own_logs() {
echo "Cleanup own log files (own_logs).  $(date)" >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
#delete all own log files older than catalog retention time.
find ${LOG_DIR}/*.log -mtime +${CATRET} -type f -delete -print >> ${LOG_DIR}/CLEAN_LOGS.log  2>&1

echo "Cleanup files done.  $(date)" >> ${LOG_DIR}/${SCRIPTLOG} 2>&1
}
# END
#########################################################################################


#########################################################################################
################                                                         ################
#############                                                                 ###########
#########                                                                       #########
####                                  MAIN                                           ####
#########                                                                       #########
############                                                                 ############
###############                                                           ###############
#########################################################################################
##
## Start and run functions:
##
echo "############################### Welcome folks $(date) ###############################" >> ${LOG_DIR}/${SCRIPTLOG}
echo "Scriptversion 2.0 HANA 2.0.........." >> ${LOG_DIR}/${SCRIPTLOG}
echo "Flight Recorder is starting........." >> ${LOG_DIR}/${SCRIPTLOG}
echo "Backup Catalog will be cleaned after "${CATRET}" days" >> ${LOG_DIR}/${SCRIPTLOG}
echo "" >> ${LOG_DIR}/${SCRIPTLOG}

## call functions defined
main_call
cleanup
own_logs

echo "" >> ${LOG_DIR}/${SCRIPTLOG}
echo "############################### Good bye folks $(date) ###############################" >> ${LOG_DIR}/${SCRIPTLOG}

:<< COMMENT
History:
07/17/2018 Introducing new version for using backint and catalog maintenance.
07/22/2018 Handling own logs added.
09/24/2018 introducing the new check for the last executed backup
COMMENT


