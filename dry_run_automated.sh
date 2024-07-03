#!/bin/bash
#Automating dry-run upgrade steps by Alex Silkin
# Modified by Jesse Richardson (jesse.richardson@liquidweb.com)
#6/13/24

set -eu

LOCK_FILE=/tmp/dry-run.lock
LOG=/tmp/dry-run.log
PRE_FLIGHT_LOG=/tmp/lw-preflight-checks.log
EL8_PACKAGES=/tmp/el8_packages.log

#Help utility
print_usage()
{
  echo "This script is used to automate and accelerate the staging dry-run process"
  echo "Syntax: dry-run.sh [-s|--stage -h|--help]"
  echo "Options:"
  echo "-s|--stage        Re-run a specific stage of the dry-run script"
  echo "-h|--help         Print this help message"
}


#Stage 0 is always executed firs as well as during every reboot.
#It checks the last completed stage according to the $LOCK_FILE status and tries to proceed accordingly

stage_0()
{

#Setup log-files
touch $PRE_FLIGHT_LOG
touch $LOCK_FILE
touch $LOG
touch $EL8_PACKAGES

#If LOCK_FILE is empty then update the log, lockfile, and initiate stage_1

if [[ ! -s ${LOCK_FILE} ]]
then
{
 #  bash <(curl -s https://files.liquidweb.com/support/elevate-scripts/elevate_preflight.sh) 2>&1 | tee -a $LOG
  # if [[ $(grep -q "cpanel.lisc missing" "$PRE_FLIGHT_LOG") ]]
  # echo "ERROR: This staging server is missing the cPanel license" 2>&1 | tee -a $LOG
  #  exit 1
  # fi
   echo "Starting a new dry-run test at $(date)"  2>&1 | tee -a $LOG
   echo "$(date) Upgrade paths, lock-file, and log-file have been setup"  2>&1 | tee -a $LOG
   echo "Proceeding with Stage 1"  2>&1 | tee -a $LOG
  #Setting up cron-job so script can run after reboot.
  echo "@reboot /bin/bash /root/dry-run.sh" >> /var/spool/cron/root
  echo "Stage 0 completed" > $LOCK_FILE
  stage_1
}
#If upgrade is already in progress the script will run the next stage depending on $LOCK_FILE status
else
 echo "Upgrade already in progress..." >> /etc/motd
  case $(cat $LOCK_FILE) in
  "Stage 0 completed")
  echo "Proceeding with Stage 1" >> $LOG
  stage_1
  ;;
  "Stage 1 completed")
  echo "Proceeding with Stage 2" >> $LOG
  stage_2
  ;;
  "Stage 2 completed")
  echo "Proceeding with Stage 3 (pre-flight checks)" >> $LOG
  stage_3
  ;;
  "Stage 3 completed")
  echo "Upgrade paused, please manually resolve Stage 3 checks" >> $LOG
  ;;
  "Stage 4 completed")
  echo "Continuing stage 4 after reboot $(date)" >> $LOG
  stage_4
  ;;
  "Stage 5 completed")
  echo "After the final LEAPP reboot check package output in $EL8_PACKAGES"
  count_el8_packages
  ;;
  esac
fi
}
stage_1()
{
#Disable Exim
    echo -e "Disabling Exim...\n"  2>&1 | tee -a $LOG
    whmapi1 configureservice service=exim enabled=0 monitored=0  2>&1 | tee -a $LOG
    echo "Exim Disabled"  2>&1 | tee -a $LOG
#Re-create /boot/grub2/grub.cfg
    echo -e "Rebuilding /boot/grub2/grub.cfg\n"  2>&1 | tee -a $LOG
    grub2-mkconfig -o /boot/grub2/grub.cfg 2>&1 | tee -a $LOG

# Remove System Repos due to EOL
    echo -e "Removing System Repos due to EOL"
    yum-config-manager --disable system-\*

# Download and Setup the new CentOS Base Repo
    echo -e "Setting up Vaulted CentOS7 Repo"
    wget -O /etc/yum.repos.d/CentOS-Base.repo https://files.liquidweb.com/support/elevate-scripts/CentOS-Base.repo
    yum clean all && yum makecache

#Re-install kernel files
    yum -y reinstall kernel kernel-devel kernel-headers kernel-tools kernel-tools-libs  2>&1 | tee -a $LOG
#Mask plymouth-reboot service
    systemctl mask plymouth-reboot.service  2>&1 | tee -a $LOG
    systemctl daemon-reload
    echo "Stage 1 completed" >> /etc/motd
    echo "Stage 1 completed" > $LOCK_FILE
    reboot
 }

stage_2()
{
  sleep 25
  echo -e "Adding default MariaDB/MySQL MySQL db data and restarting the service...\n" 2>&1 | tee -a $LOG
#Check for whether system is using MariaDB or MySQL, then setup default MySQL table accordingly
  if [[ $(mysql -V | grep "MariaDB") ]]
  then
      echo "This server uses MariaDB" 2>&1 | tee -a $LOG
      mariadb_pid="$(systemctl status mysqld | \
      grep "Main PID:" | awk '{print $3}')"; kill -9 "$mariadb_pid";
      mysql_install_db --user=mysql  2>&1 | tee -a $LOG
    else
        echo "This server uses MySQL"  2>&1 | tee -a $LOG
        echo -e '[mysqld]\nskip-grant-tables\n' > /etc/my.cnf
        mkdir /var/lib/mysql-files
        chown mysql: /var/lib/mysql-files
        chmod 750 /var/lib/mysql-files
        echo -e "Restarting MariaDB/MySQL...\n"
  fi
#Restarting MySQL/MariaDB
    echo "Restarting MySQL/MariaDB"   2>&1 | tee -a $LOG
    systemctl restart mysqld || systemctl restart mariadb
#Disabling LW-provide repositories
    echo -e "Disabling LW-provided repos...\n" 2>&1 | tee -a $LOG
    for repo in stable-{arch,generic,noarch} system-{base,extras,updates,updates-released}
    do
      yum-config-manager --disable "$repo" | grep -E 'repo:|enabled' 2>&1 | tee -a $LOG
    done
    echo -e "Removing LW-provided centos-release...\n" 2>&1 | tee -a $LOG
    rpm -e --nodeps centos-release
     #Installing CentOS7-provided centos-release and updating packages
    yum -y install http://mirror.centos.org/centos/7/os/x86_64/Packages/centos-release-7-9.2009.0.el7.centos.x86_64.rpm 2>&1 | tee -a $LOG
    yum update -y 2>&1 | tee -a $LOG
#Updating $LOCK_FILE and rebooting so script can move to stage_3, pre-flight checks
    echo "Yum updates completed, moving on to pre-flight checks" >> /etc/motd
    sleep 5 && echo "Stage 2 completed" > $LOCK_FILE
    reboot
}

stage_3()
{
#Running the LW upgrade pre-flight checks
    echo -e "Downloading and running LW and cPanel pre-flight checks:\n" 2>&1 | tee -a $LOG
    bash <(curl -s https://files.liquidweb.com/support/elevate-scripts/elevate_preflight.sh) 2>&1 | tee -a $PRE_FLIGHT_LOG
#Running cPanel preflight-checks:
    wget -q -O /scripts/elevate-cpanel https://raw.githubusercontent.com/cpanel/elevate/release/elevate-cpanel >> $LOG
    chmod 700 /scripts/elevate-cpanel
    echo -e "Disabling /var/cpanel/elevate-noc-recommendations" 2>&1 | tee -a $LOG
    mv /var/cpanel/elevate-noc-recommendations{,.disabled} 2>&1 | tee -a $LOG
    echo -e "Running cPanel Pre-flight check...\n" 2>&1 | tee -a $LOG
    /scripts/elevate-cpanel --check 2>&1 | tee -a $PRE_FLIGHT_LOG
    echo -e "\nPlease manualy address the upgrade blockers in $PRE_FLIGHT_LOG" 2>&1 | tee -a $LOG
    echo "Stage 3 completed" > $LOCK_FILE
}

#stage_4 also runs with each script run
#This way it automatically triggers stage_5 after 180 seconds which gives elevate-cpanel enough time to finish
stage_4()
{

#Checks whether pre-flight scripts have already run and proceeds with elevate-cpanel
#This assumes the user has already manually addressed LW Preflight and cPanel Preflight warnings & errors
#If preflight errors have not been addressed the elevate-cpanel script will error out

if [[ "$(cat $LOCK_FILE)" == "Stage 3 completed" ]]
then
 {
  echo "Installing Liquid Web post-leapp scripts..."
  bash <(curl -s https://files.liquidweb.com/support/elevate-scripts/install_post_leapp.sh)
 } >> $LOG

echo "Stage 4 completed" > $LOCK_FILE; /scripts/elevate-cpanel --start --non-interactive --no-leapp

elif [[ "$(cat $LOCK_FILE)" == "Stage 4 completed" ]]
then
  sleep 150
  stage_5
else
echo "Stage 4 should not be running yet" >> $LOG
echo "Exiting" >> $LOG
exit 1
fi

}

#Runs after cPanel elevate-cpanel script
stage_5()
{

#Setting up Alma8 elevate repo + leapp upgrades packages
if ! [[ "$(cat $LOCK_FILE)" == "Stage 4 completed" ]]
then
  echo "Error: '/scripts/elevate-cpanel --start --non-interactive --no-leapp' has not run yet"
  echo "Exiting..."
  exit 1
else
  echo "Beginnig Stage 5 of the dry-run test" 2>&1 | tee -a $LOG
  echo "Installing AlmaLinux8 elevate repo:" 2>&1 | tee -a $LOG
  yum install -y https://repo.almalinux.org/elevate/elevate-release-latest-el7.noarch.rpm 2>&1 | tee -a $LOG
  echo "Installing leapp-upgrade and leapp-data-almalinux" 2>&1 | tee -a $LOG
  yum install -y leapp-upgrade leapp-data-almalinux 2>&1 | tee -a $LOG

#Setting up Leapp Answer file and logs
  echo "Setting up /var/log/leapp and Leapp Answerfile" 2>&1 | tee -a $LOG
  mkdir -pv /var/log/leapp 2>&1 | tee -a $LOG
  touch /var/log/leapp/answerfile

  echo '[remove_pam_pkcs11_module_check]' >> /var/log/leapp/answerfile
  leapp answer --section remove_pam_pkcs11_module_check.confirm=True 2>&1 | tee -a $LOG

#Removing kernel-devel packages
  rpm -q kernel-devel &>/dev/null && rpm -q kernel-devel | xargs rpm -e --nodeps


#Setting LEAPP_OVL_SIZE=3000 and running Leapp upgrade. Updating $LOCK_FILE
  echo "Setting LEAPP_OVL_SIZE=3000"
  export LEAPP_OVL_SIZE=3000

  echo "Beginning LEAPP Upgrade at $(date)": 2>&1 | tee -a $LOG
  echo "Stage 5 completed" > $LOCK_FILE; leapp upgrade --reboot
fi
}


#This function is expected to run during/after LEAPP upgrade reboots
count_el8_packages()
{

  rpm -qa | grep -v cpanel | grep -Po 'el[78]' \
  | sort | uniq -c | sort -rn;echo;rpm -qa | grep -v cpanel \
  | grep 'el7' | sort | uniq | sort -rn | nl > $EL8_PACKAGES

}

#Check whether any options were passed to the script
while getopts ":hs:-:" opt; do
  case $opt in
    h)
      print_usage
      exit;;
    s) #Select a specific stage of the script
        case "${OPTARG}" in
            0)
              echo Executing stage0
              stage_0
              ;;
            1)
              echo Executing stage1
              stage_1
              ;;
            2)
              echo Executing stage2
              stage_2
              ;;
            3)
              echo Executing stage3
              stage_3
              ;;
            4)
              echo Executing stage4
              stage_4
              ;;
            5)
              echo Executing stage5
              stage_5
              ;;
            *)
              echo "Error: Invalid option: --$OPTARG"
              exit;;
        esac;;
    -)
        case "${OPTARG}" in
            help)
                print_usage
                exit 0
                ;;
            stage)
                echo "Stage"
                case "${OPTARG}" in
                    1)
                    echo stage1
                    ;;
                    2)
                    echo stage2
                    ;;
                    3)
                    echo stage3
                    ;;
                    *)
                    echo "Error: Invalid option: --$OPTARG"
                    ;;
                esac;;

        *)
          echo "Error: Invalid option: --$OPTARG"
          exit 1
          ;;
    esac;;
    \?)
      echo "Invalid option: -$OPTARG"
      exit 1
      ;;
  esac
done

#Stage 0 runs first to initiate Stage 1
stage_0
