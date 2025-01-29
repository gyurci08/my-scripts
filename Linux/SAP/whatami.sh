#! /bin/bash


#############################################
#
#  Writer:       Gyorgy Jandzso
#  Version:      1.2.3
#  Date:         2024.07.25
#  Description:  Determines the scope of the system in SAP environment
#
#
#  
#############################################



### --- Start of variables ---


SOURCE=${BASH_SOURCE[0]}
while [ -L "$SOURCE" ]; 
	do # resolve until the file is no longer a symlink
	  SCRIPT_DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )
	  SOURCE=$(readlink "$SOURCE")
	  [[ $SOURCE != /* ]] && SOURCE=$SCRIPT_DIR/$SOURCE # resolv relative symlink
	done
SCRIPT_DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )
SCRIPT_NAME=$(basename "$0")

INFO_LOG="> Info-log"
ERROR_LOG="> Error-log"

DEBUG=0                                            # DEFAULT: 0


SAP_DIR="/usr/sap"
SAP_PFL_DIR="$SAP_DIR/*/SYS/profile"                                                          
SR_DIR="$SAP_DIR/*/saprouter"
ORA_DIR="/oracle"

SAP_CI_PFL_REG="(_ASCS[0-9]{2}_)"
SAP_AP_PFL_REG="(_D[0-9]{2}_|_DVEBMGS[0-9]{2}_)"
JAVA_PFL_REG="(_J[0-9]{2}_)"
WD_PFL_REG="(_W[0-9]{2}_)"
HANA_PFL_REG="(_HDB[0-9]{2}_)"                                  
                        
SR_FILES_REG="(^saprouttab$)"
ORA_FILES_REG="(^oraarch$|^orainstall$|^origlogA$)"

SR_PS_REG="(saprouter)"
JAVA_PS_REG="(jc.sap|jstart)"
WD_PS_REG="(wd.sap)"
HC_PS_REG="(HANACockpit)"
HANA_PS_REG="(hdbxsengine|hdbnameserver|hdbwebdispatcher|hdbrsutil)"
ORA_PS_REG="(tnslsnr LISTENER)"
FT_PS_REG="(sftpd|pure-ftpd)"
SM_PS_REG="(smbd|samba)"
HP_PS_REG="(haproxy)"
ZK_PS_REG="(apache.zookeeper)"
KF_PS_REG="(kafka1|kafka2)"
EM_PS_REG="(Introscope_Enterprise_Manager)"


IS_SR=0                                          # Do not change, DEFAULT: 0
IS_OD=0                                          # Do not change, DEFAULT: 0

### --- End of variables ---


### --- Start of prequisites ---

logger()                                        # Handles console and file logging
{
  if [ $DEBUG = 1 ];
    then
      echo -e "$@"
  fi
}


errorMessage()
  { 
    echo -e "$@" 1>&2;
  }


showHelp()
{
   errorMessage "Usage: $SCRIPT_NAME [-d] [-h]"
   errorMessage "\t-d Debug mode"
   errorMessage "\t-h This help message"
   errorMessage ""
   errorMessage "Output:"
   errorMessage "\t- CI: Central instance"
   errorMessage "\t- AP: Application instance"
   errorMessage "\t- SR: SAP Router"
   errorMessage "\t- JI: Java instance"
   errorMessage "\t- WD: Webdispatcher"
   errorMessage "\t- HC: Hana cockpit"
   errorMessage "\t- HD: Hana database"
   errorMessage "\t- OD: Oracle database"
   errorMessage "\t- GS: General service (SAP products not found)"
   errorMessage "\t- FT: FTP service"
   errorMessage "\t- SM: SAMBA service"
   errorMessage "\t- HP: HaProxy service"
   errorMessage "\t- ZK: Zookeeper service"
   errorMessage "\t- KF: Kafka service"
   errorMessage "\t- EM: SAP Enterprise Manager"
   exit 1  # Exit with error code 1
}


while getopts "d h" opt			                  # Without semicolon argument is not required ( :d:h -- dh )
do
   case "$opt" in
      d ) DEBUG=1                    ;;
      h ) showHelp                   ;;
      ? ) showHelp 		               ;; 			# Print showHelp in case parameter is non-existent
   esac
done


function handle_interrupt {                   # Define a function to handle the keyboard interrupt signal
    errorMessage "\n$ERROR_LOG - Execution interrupted. Exiting...";
    exit 1
}
trap handle_interrupt SIGINT                  # Trap the keyboard interrupt signal and associate it with the handle_interrupt function


### --- End of prequisites ---



### --- Start of functions ---


checkCiProcess()    { logger "$INFO_LOG - Checking CI ps";  (ps -ef | grep -v "grep" |    grep -q -P "$SAP_CI_PFL_REG")     2> /dev/null && (logger "$INFO_LOG - Success"; return 0) || return 1 ; }
checkApProcess()    { logger "$INFO_LOG - Checking AP ps";  (ps -ef | grep -v "grep" |    grep -q -P "$SAP_AP_PFL_REG")     2> /dev/null && (logger "$INFO_LOG - Success"; return 0) || return 1 ; }
checkSrProcess()    { logger "$INFO_LOG - Checking SR ps";  (ps -ef | grep -v "grep" |       grep -q -P   "$SR_PS_REG")     2> /dev/null && (logger "$INFO_LOG - Success"; return 0) || return 1 ; }
checkJavaProcess()  { logger "$INFO_LOG - Checking JI ps";  (ps -ef | grep -v "grep" |       grep -q -P "$JAVA_PS_REG")     2> /dev/null && (logger "$INFO_LOG - Success"; return 0) || return 1 ; }
checkWdProcess()    { logger "$INFO_LOG - Checking WD ps";  (ps -ef | grep -v "grep" |       grep -q -P   "$WD_PS_REG")     2> /dev/null && (logger "$INFO_LOG - Success"; return 0) || return 1 ; }
checkHcProcess()    { logger "$INFO_LOG - Checking HC ps";  (ps -ef | grep -v "grep" |        grep -q -P  "$HC_PS_REG")     2> /dev/null && (logger "$INFO_LOG - Success"; return 0) || return 1 ; }
checkHanaProcess()  { logger "$INFO_LOG - Checking HD ps";  (ps -ef | grep -v "grep" |       grep -q -P "$HANA_PS_REG")     2> /dev/null && (logger "$INFO_LOG - Success"; return 0) || return 1 ; }
checkOraProcess()   { logger "$INFO_LOG - Checking OD ps";  (ps -ef | grep -v "grep" |       grep -q -P  "$ORA_PS_REG")     2> /dev/null && (logger "$INFO_LOG - Success"; return 0) || return 1 ; }
checkFtProcess()    { logger "$INFO_LOG - Checking FT ps";  (ps -ef | grep -v "grep" |        grep -q -P  "$FT_PS_REG")     2> /dev/null && (logger "$INFO_LOG - Success"; return 0) || return 1 ; }
checkSmProcess()    { logger "$INFO_LOG - Checking SM ps";  (ps -ef | grep -v "grep" |        grep -q -P  "$SM_PS_REG")     2> /dev/null && (logger "$INFO_LOG - Success"; return 0) || return 1 ; }
checkHpProcess()    { logger "$INFO_LOG - Checking HP ps";  (ps -ef | grep -v "grep" |        grep -q -P  "$HP_PS_REG")     2> /dev/null && (logger "$INFO_LOG - Success"; return 0) || return 1 ; }
checkZkProcess()    { logger "$INFO_LOG - Checking ZK ps";  (ps -ef | grep -v "grep" |        grep -q -P  "$ZK_PS_REG")     2> /dev/null && (logger "$INFO_LOG - Success"; return 0) || return 1 ; }
checkKfProcess()    { logger "$INFO_LOG - Checking KF ps";  (ps -ef | grep -v "grep" |        grep -q -P  "$KF_PS_REG")     2> /dev/null && (logger "$INFO_LOG - Success"; return 0) || return 1 ; }
checkEmProcess()    { logger "$INFO_LOG - Checking EM ps";  (ps -ef | grep -v "grep" |        grep -q -P  "$EM_PS_REG")     2> /dev/null && (logger "$INFO_LOG - Success"; return 0) || return 1 ; }


checkSrFiles()   { logger "$INFO_LOG - Checking SR dir/files"; (ls $SR_DIR |          grep -q -P "$SR_FILES_REG")   2> /dev/null  && (logger "$INFO_LOG - Success"; return 0) || return 1 ; }
checkGsFiles()   { logger "$INFO_LOG - Checking GS dir/files"; (! ls $SAP_PFL_DIR      1> /dev/null 2> /dev/null)                 && (logger "$INFO_LOG - Success"; return 0) || return 1 ; }
checkOraFiles()  { logger "$INFO_LOG - Checking ORA dir/files"; (ls $ORA_DIR/* |       grep -q -P "$ORA_FILES_REG")  2> /dev/null && (logger "$INFO_LOG - Success"; return 0) || return 1 ; }




checkSapProfileConf()                        # checkSapProfileConf <PFL_NAME_REGEX> <PARAMETER_TO_BE_CHECKED>
  {
    logger "$INFO_LOG - Looking for matching file pattern $1"
    for PFL in $SAP_PFL_DIR/*;
    	do
    		if $(echo $PFL | awk -F'_' '{if (NF-1 <= 2 && !/\./) print}' | grep -q -P "$1");
    			then
            logger "$INFO_LOG - Matching: $PFL"
            
            logger "$INFO_LOG - SAPLOCALHOST ping"
    				SAP_CONF_IP=$(ping -c 1 -w 1 $(grep -P "(^SAPLOCALHOST )" $PFL | awk '{print $3}') 2> /dev/null | grep -P 'PING' | awk '{print $3}' | tr -d '(|)')
    				while IFS= read -r SAP_HOST_IP
    						do
                  logger "$INFO_LOG - Comparing host ip"
    							if [ "$SAP_HOST_IP" = "$SAP_CONF_IP" ]
    								then
                        logger "$INFO_LOG - Checking parameter: $2"
                        if grep -q -P "$2" "$PFL";
                            then
                                logger "$INFO_LOG - Success"
                                #NR=$(echo $PFL | grep -o -P '(_*[0-9]{2})')
                                return 0
                        fi
    									  
    							fi;
    						done < <(ip a | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d '/' -f 1)
    		fi;
    	done
     return 1
  }



checkSapRelated()
  {
      if [ -d $SAP_DIR ]; 
  		then
  			return 0
      fi
      return 1
  }


checkSapCi() 
  {
    if checkCiProcess ||\
       checkSapProfileConf "$SAP_CI_PFL_REG" "(^SAPLOCALHOST )";
      then
          echo -e "CI"
          return 0
    fi
    return 1
  }


checkSapAp() 
  {
    if checkApProcess ||\
       checkSapProfileConf "$SAP_AP_PFL_REG" "(^SAPLOCALHOST )";
      then
          echo -e "AP"
          return 0
    fi
    return 1
  }
  
  
checkSr()
  {
      if checkSrProcess ||\
         checkSrFiles;
  		then
        IS_SR=1
        echo -e "SR"
  			return 0
      fi
      return 1
  }

checkJava() 
  {
      if checkJavaProcess ||\
         checkSapProfileConf "$JAVA_PFL_REG" "(^SAPLOCALHOST )";
  		then
        echo -e "JI"
  			return 0
      fi
      return 1
  }

checkWd()
  {
      if checkWdProcess ||\
         checkSapProfileConf "$WD_PFL_REG" "(^_WD = )";
  		then
        echo -e "WD"
  			return 0
      fi
      return 1
  }

checkHanaCocpit()
  {
      if checkHcProcess;
  		then
        echo -e "HC"
  			return 0
      fi
      return 1
  }

checkHana() 
  {
      if checkHanaProcess ||\
         checkSapProfileConf "$HANA_PFL_REG" "(^SAPLOCALHOST )";
  		then
        echo -e "HD"
  			return 0
      fi
      return 1
  }

checkOra()
  {
      if checkOraProcess ||\
         checkOraFiles;
  		then
        IS_OD=1
        echo -e "OD"
  			return 0
      fi
      return 1
  }
  
  
checkFt() 
  {
      if checkFtProcess;
  		then
        echo -e "FT"
  			return 0
      fi
      return 1
  }
  
checkSm() 
  {
      if checkSmProcess;
  		then
        echo -e "SM"
  			return 0
      fi
      return 1
  }
  
checkHp() 
  {
      if checkHpProcess;
  		then
        echo -e "HP"
  			return 0
      fi
      return 1
  }
  
checkZk() 
  {
      if checkZkProcess;
  		then
        echo -e "ZK"
  			return 0
      fi
      return 1
  }
  
checkKf() 
  {
      if checkKfProcess;
  		then
        echo -e "KF"
  			return 0
      fi
      return 1
  }
  
checkEm() 
  {
      if checkEmProcess;
  		then
        echo -e "EM"
  			return 0
      fi
      return 1
  }
  
checkGs()
  {
      if checkGsFiles  &&\
         [ $IS_SR = 0 ]  &&\
         [ $IS_OD = 0 ];
  		then
        echo -e "GS"
  			return 0
      fi
      return 1
  }
  


### --- End of functions ---


### --- Start of script ---

if checkSapRelated;
	then
  		checkSapCi;
  		checkSapAp;
  		checkSr;
  		checkJava;
  		checkWd;
   		checkHanaCocpit;
  		checkHana;
      checkOra;
      checkFt;
      checkSm;
      checkHp;
      checkZk;
      checkKf;
   		checkEm;
  		checkGs;                                           # Should be the latest check
  else
    errorMessage "$ERROR_LOG - Not a sap related system!"
    exit 1										
fi



exit 0                    # Exit without error code
### --- End of script ---