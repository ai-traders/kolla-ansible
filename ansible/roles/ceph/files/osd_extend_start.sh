#!/bin/bash

if [[ ! -d "/var/log/kolla/ceph" ]]; then
    mkdir -p /var/log/kolla/ceph
fi
if [[ $(stat -c %a /var/log/kolla/ceph) != "755" ]]; then
    chmod 755 /var/log/kolla/ceph
fi

set -x
# NOTE(SamYaple): Static gpt partcodes
CEPH_JOURNAL_TYPE_CODE="45B0969E-9B03-4F30-B4C6-B4B80CEFF106"
CEPH_OSD_TYPE_CODE="4FBD7E29-9D25-41B8-AFD0-062C0CEFF05D"

if [[ "${!KOLLA_MIX_BOOTSTRAP[@]}" ]]; then
  # Wait for ceph quorum before proceeding
  ceph quorum_status
  if [[ "${OSD_FILESYSTEM}" != "bluestore" ]]; then
    echo "OSD filesystem must be bluestore"
    exit 5
  fi

  OSD_DEV_HDD=${OSD_DEV}
  OSD_DEV_SSD=${BLUEDB_DEV}
  sgdisk --zap-all -- "${OSD_DEV_HDD}"
  sgdisk --zap-all -- "${OSD_DEV_SSD}"

  # Partitions for HDD with SSD elements:
  sgdisk --new=4:1M:+100M -- "${OSD_DEV_HDD}"
  # Journal
  sgdisk --new=2:0M:+512M -- "${OSD_DEV_SSD}"

  # Bluestore RocksDB on SSD, with 1% size of HDD
  TOTAL_SIZE=$(parted --script $OSD_DEV_HDD unit GB print | awk 'match($0, /^Disk.* (.*)GB/, a){printf("%.2f", a[1])}')
  KV_SIZE=$(echo "$TOTAL_SIZE * 0.01" | bc -l)
  KV_SIZE=$(LC_ALL=C /usr/bin/printf "%.*f\n" 0 $KV_SIZE)
  if [[ "$KV_SIZE" == "0" ]]; then
    KV_SIZE="1"
  fi
  sgdisk --new=3:0:+${KV_SIZE}G -- "${OSD_DEV_SSD}"

  # Use the rest of HDD drive for main OSD data:
  sgdisk --largest-new=1 -- "${OSD_DEV_HDD}"

  # Partition SSD for second OSD:
  sgdisk --new=4:0:+100M -- "${OSD_DEV_SSD}"
  sgdisk --largest-new=1 -- "${OSD_DEV_SSD}"

  # format the metadata filesystems.
  OSD_PARTITION_HDD="${OSD_DEV_HDD}4"
  OSD_PARTITION_SSD="${OSD_DEV_SSD}4"
  mkfs -t xfs -f -i size=2048 -- ${OSD_PARTITION_HDD}
  mkfs -t xfs -f -i size=2048 -- ${OSD_PARTITION_SSD}

  # Now prepare HDD OSD:
  OSD_ID_HDD=$(ceph osd create)
  OSD_DIR_HDD="/var/lib/ceph/osd/ceph-${OSD_ID_HDD}"
  mkdir -p "${OSD_DIR_HDD}"
  mount "${OSD_PARTITION_HDD}" "${OSD_DIR_HDD}"

  # Prepare OSD metadata, including symlinks to external devices for journal and RocksDB:
  echo "bluestore" > "${OSD_DIR_HDD}/type"
  cd ${OSD_DIR_HDD}
  BLOCK_PARTITION_HDD="${OSD_DEV_HDD}1"
  ln -s "${BLOCK_PARTITION_HDD}" block
  JOURNAL_PARTITION="${OSD_DEV_SSD}2"
  ln -s "${JOURNAL_PARTITION}" block.wal
  KV_DB_PARTITION="${OSD_DEV_SSD}3"
  ln -s "${KV_DB_PARTITION}" block.db

  # If re-using disk which was previously part of ceph OSD, above blocks needs to be cleaned first,
  # so that they don't look like existing ceph store.
  dd if=/dev/zero of=block bs=1M count=15
  dd if=/dev/zero of=block.db bs=1M count=15
  dd if=/dev/zero of=block.wal bs=1M count=15

  # This will throw an error about no key existing. That is normal. It then
  # creates the key in the next step.
  ceph-osd -i "${OSD_ID_HDD}" --mkfs --mkkey -d --no-mon-config

  OSD_INITIAL_WEIGHT=$(parted --script ${BLOCK_PARTITION_HDD} unit TB print | awk 'match($0, /^Disk.* (.*)TB/, a){printf("%.2f", a[1])}')
  ceph auth add "osd.${OSD_ID_HDD}" osd 'allow *' mon 'allow profile osd' -i "${OSD_DIR_HDD}/keyring"
  cd /
  umount "${OSD_PARTITION_HDD}"
  ceph osd crush set-device-class hdd "osd.${OSD_ID_HDD}"

  # Set disk labels so that kolla can pick it up:
  OSD_PARTITION_NUM=1
  JOURNAL_PARTITION_NUM=2
  KV_PARTITION_NUM=3
  META_PARTITION_NUM=4
  sgdisk "--change-name=${META_PARTITION_NUM}:KOLLA_CEPH_DATA_${OSD_ID_HDD}" "--typecode=${META_PARTITION_NUM}:${CEPH_OSD_TYPE_CODE}" -- "${OSD_DEV_HDD}"
  sgdisk "--change-name=${OSD_PARTITION_NUM}:KOLLA_CEPH_DATA_${OSD_ID_HDD}_BLUESTORE" "--typecode=${OSD_PARTITION_NUM}:${CEPH_OSD_TYPE_CODE}" -- "${OSD_DEV_HDD}"
  sgdisk "--change-name=${JOURNAL_PARTITION_NUM}:KOLLA_CEPH_DATA_${OSD_ID_HDD}_J" "--typecode=${JOURNAL_PARTITION_NUM}:${CEPH_JOURNAL_TYPE_CODE}" -- "${OSD_DEV_SSD}"
  sgdisk "--change-name=${KV_PARTITION_NUM}:KOLLA_CEPH_DATA_${OSD_ID_HDD}_BLUEDB" "--typecode=${KV_PARTITION_NUM}:${CEPH_OSD_TYPE_CODE}" -- "${OSD_DEV_SSD}"

  # Then to secure devices not messing up their names, we use above labels in the symlinks:
  mount "${OSD_PARTITION_HDD}" "${OSD_DIR_HDD}"
  cd ${OSD_DIR_HDD}
  BLOCK_PARTITION="/dev/disk/by-partlabel/KOLLA_CEPH_DATA_${OSD_ID_HDD}_BLUESTORE"
  ln -sf "${BLOCK_PARTITION}" block
  JOURNAL_PARTITION="/dev/disk/by-partlabel/KOLLA_CEPH_DATA_${OSD_ID_HDD}_J"
  ln -sf "${JOURNAL_PARTITION}" block.wal
  KV_DB_PARTITION="/dev/disk/by-partlabel/KOLLA_CEPH_DATA_${OSD_ID_HDD}_BLUEDB"
  ln -sf "${KV_DB_PARTITION}" block.db

  cd /
  umount "${OSD_PARTITION_HDD}"
  echo "HDD OSD prepared."

  OSD_ID_SSD=$(ceph osd create)
  OSD_DIR_SSD="/var/lib/ceph/osd/ceph-${OSD_ID_SSD}"
  mkdir -p "${OSD_DIR_SSD}"
  mount "${OSD_PARTITION_SSD}" "${OSD_DIR_SSD}"

  # Prepare OSD metadata, including symlink to block device
  echo "bluestore" > "${OSD_DIR_SSD}/type"
  cd ${OSD_DIR_SSD}
  BLOCK_PARTITION_SSD="${OSD_DEV_SSD}1"
  ln -s "${BLOCK_PARTITION_SSD}" block
  ceph-osd -i "${OSD_ID_SSD}" --mkfs --mkkey -d --no-mon-config

  OSD_INITIAL_WEIGHT=$(parted --script ${BLOCK_PARTITION_SSD} unit TB print | awk 'match($0, /^Disk.* (.*)TB/, a){printf("%.2f", a[1])}')
  ceph auth add "osd.${OSD_ID_SSD}" osd 'allow *' mon 'allow profile osd' -i "${OSD_DIR_SSD}/keyring"
  cd /
  umount "${OSD_PARTITION_SSD}"
  ceph osd crush set-device-class ssd "osd.${OSD_ID_SSD}"

  # Set disk labels so that kolla can pick it up:
  OSD_PARTITION_NUM=1
  META_PARTITION_NUM=4
  sgdisk "--change-name=${META_PARTITION_NUM}:KOLLA_CEPH_DATA_${OSD_ID_SSD}" "--typecode=${META_PARTITION_NUM}:${CEPH_OSD_TYPE_CODE}" -- "${OSD_DEV_SSD}"
  sgdisk "--change-name=${OSD_PARTITION_NUM}:KOLLA_CEPH_DATA_${OSD_ID_SSD}_BLUESTORE" "--typecode=${OSD_PARTITION_NUM}:${CEPH_OSD_TYPE_CODE}" -- "${OSD_DEV_SSD}"

  # secure devices not messing up their names, we use above labels in the symlinks:
  mount "${OSD_PARTITION_SSD}" "${OSD_DIR_SSD}"
  cd ${OSD_DIR_SSD}
  BLOCK_PARTITION="/dev/disk/by-partlabel/KOLLA_CEPH_DATA_${OSD_ID_SSD}_BLUESTORE"
  ln -sf "${BLOCK_PARTITION}" block

  cd /
  umount "${OSD_PARTITION_SSD}"

  exit 0

elif [[ "${!KOLLA_BOOTSTRAP[@]}" ]]; then
    # Wait for ceph quorum before proceeding
    ceph quorum_status

    if [[ "${OSD_FILESYSTEM}" == "bluestore" ]]; then
      # bluestore can use up to 3 dedicated devices for single OSD
      # To keep it consistent with kolla behaviour so far journal will be on part 2, data on part 1
      sgdisk --zap-all -- "${OSD_DEV}"
      # A small data partition, where configuration files, keys and UUIDs reside.
      sgdisk --new=4:1M:+100M -- "${OSD_DEV}"
      # The actual data on the rest of main device
      sgdisk --largest-new=1 -- "${OSD_DEV}"
      partprobe || true
      # format partition for metadata
      OSD_PARTITION="${OSD_DEV}4"
      mkfs -t xfs -f -i size=2048 -- ${OSD_PARTITION}

      META_PARTITION_NUM=4
    else
      if [[ "${USE_EXTERNAL_JOURNAL}" == "False" ]]; then
          # Formatting disk for ceph
          sgdisk --zap-all -- "${OSD_DEV}"
          sgdisk --new=2:1M:5G -- "${JOURNAL_DEV}"
          sgdisk --largest-new=1 -- "${OSD_DEV}"
          # NOTE(SamYaple): This command may throw errors that we can safely ignore
          partprobe || true
      fi
    fi

    OSD_ID=$(ceph osd create)
    OSD_DIR="/var/lib/ceph/osd/ceph-${OSD_ID}"
    mkdir -p "${OSD_DIR}"

    if [[ "${OSD_FILESYSTEM}" == "btrfs" ]]; then
        mkfs.btrfs -f "${OSD_PARTITION}"
    elif [[ "${OSD_FILESYSTEM}" == "ext4" ]]; then
        mkfs.ext4 "${OSD_PARTITION}"
    elif [[ "${OSD_FILESYSTEM}" == "bluestore" ]]; then
        # already prepared partition for metadata, and we do not format others
        echo "Using bluestore, no filesystem will be formated"
    else
        mkfs.xfs -f "${OSD_PARTITION}"
    fi
    mount "${OSD_PARTITION}" "${OSD_DIR}"

    if [[ "${OSD_FILESYSTEM}" == "bluestore" ]]; then
        echo "bluestore" > "${OSD_DIR}/type"
        cd ${OSD_DIR}
        # block symlink is the only one required.
        BLOCK_PARTITION="${OSD_DEV}1"
        ln -s "${BLOCK_PARTITION}" block

        if [[ "${USE_EXTERNAL_JOURNAL}" == "True" ]]; then
          #JOURNAL_PARTITION="${JOURNAL_DEV}2"
          ln -s "${JOURNAL_PARTITION}" block.wal
        fi

        if [[ "${USE_EXTERNAL_BLUEDB}" == "True" ]]; then
          #KV_DB_PARTITION="${BLUE_DEV}3"
          ln -s "${KV_DB_PARTITION}" block.db
        fi

        if [[ "${OSD_INITIAL_WEIGHT}" == "auto" ]]; then
            OSD_INITIAL_WEIGHT=$(parted --script ${BLOCK_PARTITION} unit TB print | awk 'match($0, /^Disk.* (.*)TB/, a){printf("%.2f", a[1])}')
        fi

        ceph-osd -i "${OSD_ID}" --mkfs --mkkey
    else
        ceph-osd -i "${OSD_ID}" --mkfs --osd-journal="${JOURNAL_PARTITION}" --mkkey
    fi

    ceph auth add "osd.${OSD_ID}" osd 'allow *' mon 'allow profile osd' -i "${OSD_DIR}/keyring"
    cd /
    umount "${OSD_PARTITION}"

    if [[ "${OSD_INITIAL_WEIGHT}" == "auto" ]]; then
        OSD_INITIAL_WEIGHT=$(parted --script ${OSD_PARTITION} unit TB print | awk 'match($0, /^Disk.* (.*)TB/, a){printf("%.2f", a[1])}')
    fi

    if [[ "${!CEPH_ROOT_SSD[@]}" ]]; then
        ceph osd crush set-device-class ssd "osd.${OSD_ID}"
    fi

    # Setting partition name based on ${OSD_ID}
    if [[ "${OSD_FILESYSTEM}" == "bluestore" ]]; then
      # In bluestore case, the actual data is really on ${BLOCK_PARTITION}, that it is not a filesystem.
      # Since this information is only for kolla to use for mounting in container's host, we set 'ceph data'
      # label on the 100M partition which is really meant to be mounted and contains neccesary metadata files
      sgdisk "--change-name=${META_PARTITION_NUM}:KOLLA_CEPH_DATA_${OSD_ID}" "--typecode=${META_PARTITION_NUM}:${CEPH_OSD_TYPE_CODE}" -- "${OSD_DEV}"
      # For sake of completeness, we set labels on KV partion and bluestore too:
      sgdisk "--change-name=${OSD_PARTITION_NUM}:KOLLA_CEPH_DATA_${OSD_ID}_BLUESTORE" "--typecode=${OSD_PARTITION_NUM}:${CEPH_OSD_TYPE_CODE}" -- "${OSD_DEV}"

      echo "Setting strict links for bluestore components"
      mount "${OSD_PARTITION}" "${OSD_DIR}"
      cd ${OSD_DIR}
      BLOCK_PARTITION="/dev/disk/by-partlabel/KOLLA_CEPH_DATA_${OSD_ID}_BLUESTORE"
      ln -sf "${BLOCK_PARTITION}" block

      if [[ "${USE_EXTERNAL_JOURNAL}" == "True" ]]; then
        sgdisk "--change-name=${JOURNAL_PARTITION_NUM}:KOLLA_CEPH_DATA_${OSD_ID}_J" "--typecode=${JOURNAL_PARTITION_NUM}:${CEPH_JOURNAL_TYPE_CODE}" -- "${JOURNAL_DEV}"
        JOURNAL_PARTITION="/dev/disk/by-partlabel/KOLLA_CEPH_DATA_${OSD_ID}_J"
        ln -sf "${JOURNAL_PARTITION}" block.wal
      fi

      if [[ "${USE_EXTERNAL_BLUEDB}" == "True" ]]; then
        sgdisk "--change-name=${KV_PARTITION_NUM}:KOLLA_CEPH_DATA_${OSD_ID}_BLUEDB" "--typecode=${KV_PARTITION_NUM}:${CEPH_OSD_TYPE_CODE}" -- "${BLUE_DEV}"
        KV_DB_PARTITION="/dev/disk/by-partlabel/KOLLA_CEPH_DATA_${OSD_ID}_BLUEDB"
        ln -sf "${KV_DB_PARTITION}" block.db
      fi

      cd /
      umount "${OSD_PARTITION}"
    else
      sgdisk "--change-name=${JOURNAL_PARTITION_NUM}:KOLLA_CEPH_DATA_${OSD_ID}_J" "--typecode=${JOURNAL_PARTITION_NUM}:${CEPH_JOURNAL_TYPE_CODE}" -- "${JOURNAL_DEV}"
      sgdisk "--change-name=${OSD_PARTITION_NUM}:KOLLA_CEPH_DATA_${OSD_ID}" "--typecode=${OSD_PARTITION_NUM}:${CEPH_OSD_TYPE_CODE}" -- "${OSD_DEV}"
    fi

    exit 0
fi

OSD_DIR="/var/lib/ceph/osd/ceph-${OSD_ID}"
if [[ "${OSD_FILESYSTEM}" == "bluestore" ]]; then
  # do not use osd-journal param because it sets
  ARGS="-i ${OSD_ID} -k ${OSD_DIR}/keyring"
else
  ARGS="-i ${OSD_ID} --osd-journal ${JOURNAL_PARTITION} -k ${OSD_DIR}/keyring"
fi
