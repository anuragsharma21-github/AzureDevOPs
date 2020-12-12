#!/bin/bash

usage() {
    echo "Usage: $(basename $0) <new disk>"
}

scan_for_new_disks() {
    # Looks for unpartitioned disks
    declare -a RET
    DEVS=($(ls -1 /dev/sd*|egrep -v "[0-9]$"))
    for DEV in "${DEVS[@]}";
    do
        # Check each device if there is a "1" partition.  If not,
        # "assume" it is not partitioned.
        if [ ! -b ${DEV}1 ];
        then
            RET+="${DEV} "
        fi
    done
    echo "${RET}"
}

get_next_mountpoint() {
    DIRS=($(ls -1d /disk* 2>&1| sort --version-sort))
    if [ -z "${DIRS[0]}" ];
    then
        echo "/disk1"
        return
    else
        IDX=$(echo "${DIRS[${#DIRS[@]}-1]}"|tr -d "[a-zA-Z/]" )
        IDX=$(( ${IDX} + 1 ))
        echo "/disk${IDX}"
    fi
}

add_to_fstab() {
    UUID=${1}
    MOUNTPOINT=${2}
    grep "${UUID}" /etc/fstab >/dev/null 2>&1
    if [ ${?} -eq 0 ];
    then
        echo "Not adding ${UUID} to fstab again (it's already there!)"
    else
        LINE="UUID=\"${UUID}\"\t${MOUNTPOINT}\txfs\tnoatime,nodiratime,nodev,noexec,nosuid\t1 2"
        echo -e "${LINE}" >> /etc/fstab
    fi
}

is_partitioned() {
# Checks if there is a valid partition table on the
# specified disk
    OUTPUT=$(sfdisk -l ${1} 2>&1)
    grep "No partitions found" "${OUTPUT}" >/dev/null 2>&1
    return "${?}"       
}

has_filesystem() {
    DEVICE=${1}
    OUTPUT=$(file -L -s ${DEVICE})
    grep filesystem <<< "${OUTPUT}" > /dev/null 2>&1
    return ${?}
}

do_partition() {
# This function creates one (1) primary partition on the
# disk, using all available space
    DISK=${1}
    (
        echo n
        echo p
        echo 1
        echo
        echo
        echo w
    ) | fdisk "${DISK}" > /dev/null 2>&1

#
# Use the bash-specific $PIPESTATUS to ensure we get the correct exit code
# from fdisk and not from echo
if [ ${PIPESTATUS[1]} -ne 0 ];
then
    echo "An error occurred partitioning ${DISK}" >&2
    echo "I cannot continue" >&2
    exit 2
fi
}

if [ -z "${1}" ];
then
    DISKS=($(scan_for_new_disks))
else
    DISKS=("${@}")
fi
echo "Disks are ${DISKS[@]}"
for DISK in "${DISKS[@]}";
do
    echo "Working on ${DISK}"
    is_partitioned ${DISK}
    if [ ${?} -ne 0 ];
    then
        echo "${DISK} is not partitioned, partitioning"
        do_partition ${DISK}
    fi
    PARTITION=$(fdisk -l ${DISK}|grep -A 1 Device|tail -n 1|awk '{print $1}')
    has_filesystem ${PARTITION}
    if [ ${?} -ne 0 ];
    then
        echo "Creating filesystem on ${PARTITION}."
        #echo "Press Ctrl-C if you don't want to destroy all data on ${PARTITION}"
        #sleep 5
        mkfs.xfs ${PARTITION}
    fi
    MOUNTPOINT=$(get_next_mountpoint)
    echo "Next mount point appears to be ${MOUNTPOINT}"
    [ -d "${MOUNTPOINT}" ] || mkdir "${MOUNTPOINT}"
    read UUID FS_TYPE < <(blkid -u filesystem ${PARTITION}|awk -F "[= ]" '{print $3" "$5}'|tr -d "\"")
    add_to_fstab "${UUID}" "${MOUNTPOINT}"
    echo "Mounting disk ${PARTITION} on ${MOUNTPOINT}"
    mount "${PARTITION}" "${MOUNTPOINT}"
done

#setup DB2 on RHEL8.2
#export USER=root
export INST_NAME=db2inst1
export DB_NAME=demo
export INST_DIR=/disk1/IBM
export DB2OWNER=db2inst1
export DB2FENCUSER=db2fenc1
export GROUPI=db2iadm1
export GROUPF=db2fadm1
export db2_url="https://db2storage.blob.core.windows.net/dbcontainer/v11.5.4_linuxx64_universal_fixpack.tar.gz"

#pre-reqs
yum update -y
yum install -y gcc 
yum install -y gcc-c++ 
yum install -y libstdc++*.i686 
yum install -y numactl 
yum install -y sg3_utils 
yum install -y kernel-devel 
#yum install -y compat-libstdc++-33.i686 
#yum install -y compat-libstdc++-33.x86_64 
yum install -y pam-devel.i686 
yum install -y pam-devel.x86_64

mkdir -p /disk1/$INST_NAME/$DB_NAME/datapath
mkdir -p /disk1/IBM
mkdir -p /disk1/software_dump
mkdir -p /disk2/$INST_NAME/$DB_NAME/plogpath/
mkdir -p /disk3/$INST_NAME/$DB_NAME/rlogpath
mkdir -p /disk4/$INST_NAME/$DB_NAME/db2dump/


#download DB2 11.5 from Azure
wget -nv $db2_url -P /disk1/software_dump

#untar software to directory
tar -zxvf /disk1/software_dump/v11.5.4_linuxx64_universal_fixpack.tar.gz -C /disk1/software_dump/

#install db2 - approx. 10 minutes
/disk1/software_dump/universal/db2_install -b $INST_DIR  -y -n -p SERVER

#open port
firewall-offline-cmd --zone=public --add-port=50000/tcp
systemctl enable firewalld
systemctl restart firewalld

#create user 
groupadd $GROUPI
groupadd $GROUPF 
adduser $DB2OWNER 
adduser $DB2FENCUSER
usermod -aG $GROUPI $DB2OWNER
usermod -aG $GROUPF $DB2FENCUSER

#echo $PASSWD | sudo passwd $USER --stdin

#create instance
$INST_DIR/instance/db2icrt -a SERVER -u $DB2FENCUSER $DB2OWNER

#start instance as user
chmod +x $INST_DIR/adm/db2start
su - $DB2OWNER -c "$INST_DIR/adm/db2start"

#create a database - approx 7 minutes
chown -R $DB2OWNER /disk1/$INST_NAME/$DB_NAME/datapath
su - $DB2OWNER -c "source ~/sqllib/db2profile; db2 create database $DB_NAME on /disk1/$INST_NAME/$DB_NAME/datapath"
