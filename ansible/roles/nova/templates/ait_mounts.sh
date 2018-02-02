#!/bin/bash

# This script is used by nova_compute and nova_libvirt containers to setup mount points for nova guests.
# Script is mounted with :ro into both containers.

set -e

function check_mounted {
  dir=$1
  if ! mountpoint -q -- "$dir" ; then
     echo "$dir is not mounted. Most recent logs:"
     tail /var/log/glusterfs/*.log
     exit 2
  fi
}

echo "nova-compute type=$AIT_NOVA_COMPUTE_TYPE"
if [ -z "$AIT_NOVA_COMPUTE_TYPE" ];
  then echo "AIT_NOVA_COMPUTE_TYPE is not set";
  exit 5
fi
if [ $AIT_NOVA_COMPUTE_TYPE == "p" ]; then
    if [ -z "$AIT_NOVA_INSTANCES_MOUNT_OPTS" ];
      then echo "AIT_NOVA_INSTANCES_MOUNT_OPTS is not set";
      exit 5
    elif [ -z "$AIT_NOVA_INSTANCES_BASE_MOUNT_OPTS" ];
      then echo "AIT_NOVA_INSTANCES_BASE_MOUNT_OPTS is not set";
      exit 5
    else
      mkdir -p /var/lib/nova/instances
      mount -t glusterfs $AIT_NOVA_INSTANCES_MOUNT_OPTS /var/lib/nova/instances
      mkdir -p /var/lib/nova/instances/_base
      mount -t glusterfs $AIT_NOVA_INSTANCES_BASE_MOUNT_OPTS /var/lib/nova/instances/_base
      chown nova:nova /var/lib/nova/instances /var/lib/nova/instances/_base

      check_mounted "/var/lib/nova/instances"
      check_mounted "/var/lib/nova/instances/_base"
    fi
elif [ $AIT_NOVA_COMPUTE_TYPE == "w" ]; then
  echo "Nova compute worker type, expecting LVM group to be present"
  if [ -z "$AIT_NOVA_INSTANCES_BASE_MOUNT_OPTS" ];
    then echo "AIT_NOVA_INSTANCES_BASE_MOUNT_OPTS is not set";
    exit 5
  else
    mkdir -p /var/lib/nova/instances/_base
    mount -t glusterfs $AIT_NOVA_INSTANCES_BASE_MOUNT_OPTS /var/lib/nova/instances/_base
    chown nova:nova /var/lib/nova/instances/_base
    
    check_mounted "/var/lib/nova/instances/_base"
  fi
else
  echo "AIT_NOVA_COMPUTE_TYPE must be set to p,w or v. Got $AIT_NOVA_COMPUTE_TYPE"
  exit 4
fi
