#!/bin/bash
#####################
# Author: RahulReddy
# Description:
#  This script encrypts all attached drives except the first drive.  It was tested in AWS but for other environments
#  you may need to modify num_extra_drives and dev_label variables to make sure it gets the right variables
#  NB: This script will erase all contents of your drive! To prevent this touch ${encrypted_disks_log}/<drive name>
#####################

set -e


specific_disk=$1

set -u


num_extra_drives=$((` lsblk | awk ' $0 ~ "^[a-z]" { print $1 } '  | cut -c -4 | sort | uniq | wc -l `-1))
dev_label=`lsblk | awk ' $0 ~ "^[a-z]" { print $1 } ' | cut -c -3 | sort | uniq`

encrypted_disks_log=/root/encrypted_disk
letters=( $(echo {a..z}) )
encrypt_key=/root/disk_encrypt_key

yum -y install pv cryptsetup
mount_point_prefix=/data/vol

# Generate encryption key
if [ ! -e ${encrypt_key} ]; then
  if [ ! -e "${encrypt_key}.bak" ]; then
    echo "-> Creating Encryption Key"
    openssl rand -base64 32 > ${encrypt_key}
    cp ${encrypt_key} ${encrypt_key}.bak
  else
    echo "-> Backup Encryption key exists! Please copy back to ${encrypt_key}"
  fi
fi

# Check for formated disk directory
if [ ! -d $encrypted_disks_log ]; then
  echo "-> Creating Encrypted Disk log directory"
  mkdir -p $encrypted_disks_log
fi


function encrypt_disk(){
  local disk=$1
  local count=$2

  local device=/dev/${disk}
  echo "*-> Working on ${device}"
  sleep 3
  #if [ ! -e ${device} ]; then
    #echo " !- Device - ${device} does not exist"
    #return 0
  #fi

  # Check if drive has been formatted
  if [ -e "${encrypted_disks_log}/${disk}" ]; then
    echo "  -> Drive has been encrypted. Skipping! To force format remove ${encrypted_disks_log}/${disk}"
  else

    if mount | grep "${mount_point_prefix}${count} " > /dev/null; then
      echo "  -> Unmounting ${mount_point_prefix}${count}"
      umount ${mount_point_prefix}${count}
    fi
    echo "  -> Removing ${device} from fstab"
    sed_var="${mount_point_prefix}${count} "
    sed -i -e "\|$sed_var|d" /etc/fstab

    echo "  -> Closing Encryted the drive"
    set +e
    cryptsetup luksClose vol${count}
    set -e

    echo "  -> Performing Cryptsetup format"
    cryptsetup --verbose -yrq --key-file=${encrypt_key} luksFormat $device

    echo "  -> Mapping from dev to volume"
    cryptsetup --key-file=${encrypt_key} luksOpen $device vol${count}

    echo "  -> Creating Filesystem - ext4"
    mkfs.ext4  /dev/mapper/vol${count}

    echo "  -> Adding new entry to fstab"
    # Make sure you use the UUID of the mapped drive
    mapped_uuid=`blkid /dev/mapper/vol${count} | awk ' { line=$2;  gsub(/"/,"",line); print line } '`

    # Sample fstab entry
    # UUID=e7faba57-b88f-46f8-a4b8-9fd4fa0a2e4b /data/vol4 ext4 defaults 0 0
    echo "${mapped_uuid} ${mount_point_prefix}${count} ext4 defaults 0 0" >> /etc/fstab
    mkdir -p ${mount_point_prefix}${count}

    echo "  -> Removing old crypttab entry"
    sed_var="vol${count} "
    sed -i  -e "\|${sed_var}|d" /etc/crypttab

    echo "  -> Adding entry to crypttab - ${device}"
    device_uuid=`blkid ${device} | awk ' { line=$2; sub(/UUID=/,"",line); gsub(/"/,"",line); print line } '`
    echo "vol${count} /dev/disk/by-uuid/${device_uuid} ${encrypt_key} luks" >> /etc/crypttab
    touch ${encrypted_disks_log}/${disk}
  fi


}
date

if [ -z $specific_disk ]; then
  d_count=1
  ( pids=""

    for disk in `lsblk | awk ' $0 ~ "^[a-z]" { print $1 } '  | cut -c -4 | sort | uniq | awk ' NR >1' `; do
      encrypt_disk $disk $d_count &
      pids="$pids $!"
      d_count=$((d_count+1))
    done


  echo "-> Waiting for Children to finish"
  wait $pids )
else
  encrypt_disk $specific_disk 1
fi

echo "-> All Children are back - Mounting FSTAB"
mount -a

