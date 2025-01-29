#! /bin/bash


#############################################
#
#  Writer:       Gyorgy Jandzso
#  Version:      1.0.7
#  Date:         2024.07.25
#  Description:  A template script, which checks if the current system is affected by "TARGET"
#                NEEDS whatami.sh!
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

DEBUG=0                                       # DEFAULT: 0

HOST_CHECK_SCRIPT="$SCRIPT_DIR/whatami.sh"    # Edit the host type check script here




# Possible targets: CI, AP, JI, HD, DB, SR, WD, GS;  GS will be executed on: FT, SM, HP, KF, ZK; Case sensitive!;
# Edit the script's target type here; Multiple values separated by '|'; Ex: "CI|AP"
##################################
TARGET="CI|AP"                                             
##################################




IGNORE_TARGET=0                               # CAUTION! Host checking will be skipped!; DEFAULT: 0

### --- End of variables ---




### --- Start of prequisites ---


logger()                                      # Handles console and file logging
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
   exit 1                                     # Exit with error code 1
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


checkTarget()
  {
      if [ -f $HOST_CHECK_SCRIPT ]; 
  		  then
            if ( $HOST_CHECK_SCRIPT | grep -qE "$TARGET");
              then
                  logger "$INFO_LOG - This is a target system!"
              else
                  logger "$INFO_LOG - Not a target system!"
                  exit 1
            fi
        else
            errorMessage "$ERROR_LOG - File not found: $HOST_CHECK_SCRIPT"
            exit 1
      fi	
  }

if [ $IGNORE_TARGET = 0 ];                    # This checks if the host is affected
    then
        logger "$INFO_LOG - Checking target"
        checkTarget;
    else
        logger "$INFO_LOG - Target checking ignored" 
fi 
                    

### --- End of prequisites ---







### --- Start of functions ---

# Write your functions here





### --- End of functions ---








### --- Start of script ---

# Write your code here
echo "Hello World!"                             





exit 0
### --- End of script ---
