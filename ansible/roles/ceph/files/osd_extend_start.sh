#!/bin/bash

if [[ ! -d "/var/log/kolla/ceph" ]]; then
    mkdir -p /var/log/kolla/ceph
fi
if [[ $(stat -c %a /var/log/kolla/ceph) != "755" ]]; then
    chmod 755 /var/log/kolla/ceph
fi

# Bootstrap and exit if KOLLA_BOOTSTRAP variable is set. This catches all cases
# of the KOLLA_BOOTSTRAP variable being set, including empty.
if [[ "${!KOLLA_BOOTSTRAP[@]}" ]]; then
    set -x
    # NOTE(SamYaple): Static gpt partcodes
    CEPH_JOURNAL_TYPE_CODE="45B0969E-9B03-4F30-B4C6-B4B80CEFF106"
    CEPH_OSD_TYPE_CODE="4FBD7E29-9D25-41B8-AFD0-062C0CEFF05D"

    # Wait for ceph quorum before proceeding
    ceph quorum_status

    if [[ "${OSD_FILESYSTEM}" == "bluestore" ]]; then
      # bluestore can use up to 3 dedicated devices for single OSD
      # To keep it consistent with kolla behaviour so far journal will be on part 2, data on part 1
      sgdisk --zap-all -- "${OSD_DEV}"
      # A small data partition, where configuration files, keys and UUIDs reside.
      sgdisk --new=4:1M:+100M -- "${OSD_DEV}"
      # WAL, journal
      sgdisk --new=2:0M:+1024M -- "${JOURNAL_DEV}"
      # RocksDB, By default a partition will be created on the device that is 1% of the main device size.
      TOTAL_SIZE=$(parted --script $OSD_DEV unit GB print | awk 'match($0, /^Disk.* (.*)GB/, a){printf("%.2f", a[1])}')
      # compute 1% and round up
      KV_SIZE=$(echo "$TOTAL_SIZE * 0.01" | bc -l)
      KV_SIZE=$(LC_ALL=C /usr/bin/printf "%.*f\n" 0 $KV_SIZE)
      if [[ "$KV_SIZE" == "0" ]]; then
        KV_SIZE="1"
      fi
      sgdisk --new=3:0:+${KV_SIZE}G -- "${OSD_DEV}"
      # The actual data on the rest of main device
      sgdisk --largest-new=1 -- "${OSD_DEV}"
      partprobe || true
      # format partition for metadata
      OSD_PARTITION="${OSD_DEV}4"
      mkfs -t xfs -f -i size=2048 -- ${OSD_PARTITION}

      OSD_DATA_PARTITION_NUM=1
      JOURNAL_PARTITION_NUM=2
      KV_PARTITION_NUM=3
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
        BLOCK_PARTITION="${OSD_DEV}1"
        JOURNAL_PARTITION="${JOURNAL_DEV}2"
        KV_DB_DEV="${OSD_DEV}3"
        ln -s "${BLOCK_PARTITION}" block
        ln -s "${JOURNAL_PARTITION}" block.wal
        ln -s "${KV_DB_DEV}" block.db

        if [[ "${OSD_INITIAL_WEIGHT}" == "auto" ]]; then
            OSD_INITIAL_WEIGHT=$(parted --script ${BLOCK_PARTITION} unit TB print | awk 'match($0, /^Disk.* (.*)TB/, a){printf("%.2f", a[1])}')
        fi
    fi

    # This will throw an error about no key existing. That is normal. It then
    # creates the key in the next step.
    ceph-osd -i "${OSD_ID}" --mkfs --osd-journal="${JOURNAL_PARTITION}" --mkkey
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
    sgdisk "--change-name=${JOURNAL_PARTITION_NUM}:KOLLA_CEPH_DATA_${OSD_ID}_J" "--typecode=${JOURNAL_PARTITION_NUM}:${CEPH_JOURNAL_TYPE_CODE}" -- "${JOURNAL_DEV}"
    if [[ "${OSD_FILESYSTEM}" == "bluestore" ]]; then
      # In bluestore case, the actual data is really on ${BLOCK_PARTITION}, that it is not a filesystem.
      # Since this information is only for kolla to use for mounting in container's host, we set 'ceph data'
      # label on the 100M partition which is really meant to be mounted and contains neccesary metadata files
      sgdisk "--change-name=${META_PARTITION_NUM}:KOLLA_CEPH_DATA_${OSD_ID}" "--typecode=${META_PARTITION_NUM}:${CEPH_OSD_TYPE_CODE}" -- "${OSD_DEV}"
      # For sake of completeness, we set labels on KV partion and bluestore too:
      sgdisk "--change-name=${OSD_PARTITION_NUM}:KOLLA_CEPH_${OSD_ID}_BLUESTORE" "--typecode=${OSD_PARTITION_NUM}:${CEPH_OSD_TYPE_CODE}" -- "${OSD_DEV}"
      sgdisk "--change-name=${KV_PARTITION_NUM}:KOLLA_CEPH_${OSD_ID}_BLUE_KV" "--typecode=${KV_PARTITION_NUM}:${CEPH_OSD_TYPE_CODE}" -- "${OSD_DEV}"

      if [[ "${OSD_FILESYSTEM}" == "bluestore" ]]; then
          echo "Setting strict links for bluestore components"
          mount "${OSD_PARTITION}" "${OSD_DIR}"
          cd ${OSD_DIR}
          BLOCK_PARTITION="/dev/disk/by-partlabel/KOLLA_CEPH_${OSD_ID}_BLUESTORE"
          JOURNAL_PARTITION="/dev/disk/by-partlabel/KOLLA_CEPH_DATA_${OSD_ID}_J"
          KV_DB_DEV="/dev/disk/by-partlabel/KOLLA_CEPH_${OSD_ID}_BLUE_KV"
          ln -sf "${BLOCK_PARTITION}" block
          ln -sf "${JOURNAL_PARTITION}" block.wal
          ln -sf "${KV_DB_DEV}" block.db
          cd /
          umount "${OSD_PARTITION}"
      fi
    else
      sgdisk "--change-name=${OSD_PARTITION_NUM}:KOLLA_CEPH_DATA_${OSD_ID}" "--typecode=${OSD_PARTITION_NUM}:${CEPH_OSD_TYPE_CODE}" -- "${OSD_DEV}"
    fi

    exit 0
fi

OSD_DIR="/var/lib/ceph/osd/ceph-${OSD_ID}"
ARGS="-i ${OSD_ID} --osd-journal ${JOURNAL_PARTITION} -k ${OSD_DIR}/keyring"
