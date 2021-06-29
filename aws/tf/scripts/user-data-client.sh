#!/bin/bash

set -e

exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

printf "\n\nSTARTING AT $(date)\n\n"

OPS_CONFIG_DIR=/ops/shared/config

CONSUL_CONFIG_DIR=/etc/consul.d
NOMAD_CONFIG_DIR=/etc/nomad.d
CONSULTEMPLATE_CONFIG_DIR=/etc/consul-template.d
GLUSTER_MOUNT_DIR=/mnt/gluster
CONSUL_SHARED_DIR=$GLUSTER_MOUNT_DIR/consul-shared
HOME_DIR=ubuntu
NET_IFACE=$(ls /sys/class/net/ | grep -P '(^ens\d$|^eth\d$)' | head -n 1)
AWS_DATA_IP=169.254.169.254

sleep 20 # Wait for network

DOCKER_BRIDGE_IP_ADDRESS=(`ifconfig docker0 2>/dev/null | awk '/inet / {print $2}'`)
RETRY_JOIN="${retry_join}"
CDNS=".node.dc1.consul"


# Get IP address and AZ from metadata service
IP_ADDRESS=$(curl http://$AWS_DATA_IP/latest/meta-data/local-ipv4)
AZ=$(curl http://$AWS_DATA_IP/latest/meta-data/placement/availability-zone/ | grep -o '.$')


# Consul
sed -i "s/IP_ADDRESS/$IP_ADDRESS/g" $OPS_CONFIG_DIR/consul_client.hcl
sed -i "s/RETRY_JOIN/$RETRY_JOIN/g" $OPS_CONFIG_DIR/consul_client.hcl
cp $OPS_CONFIG_DIR/consul_client.hcl $CONSUL_CONFIG_DIR/consul.hcl
cp $OPS_CONFIG_DIR/consul_aws.service /etc/systemd/system/consul.service

systemctl enable consul.service
systemctl start consul.service
sleep 10

DC=$(consul members | grep $(hostname) | awk '{ print $7 }') # Consul datacenter
GLUSTER_NODE_IP=$(consul members | grep hg-s-$AZ | head -n 1 | awk '{ print $2 }' | sed -E 's/:.+$//' )

# Nomad
cp $OPS_CONFIG_DIR/nomad_client.hcl $NOMAD_CONFIG_DIR/nomad.hcl
cp $OPS_CONFIG_DIR/nomad.service /etc/systemd/system/nomad.service

systemctl enable nomad.service
systemctl start nomad.service
sleep 10
export NOMAD_ADDR=http://$IP_ADDRESS:4646


# Consul Template
cp $OPS_CONFIG_DIR/consul-template.hcl $CONSULTEMPLATE_CONFIG_DIR/consul-template.hcl
cp $OPS_CONFIG_DIR/consul-template.service /etc/systemd/system/consul-template.service


# Add hostname to /etc/hosts
echo "127.0.0.1 $(hostname)" | tee --append /etc/hosts


# Add Docker bridge network IP and AWS DNS to /etc/resolv.conf (at the top)
echo "nameserver $DOCKER_BRIDGE_IP_ADDRESS" | tee /etc/resolv.conf.new
echo "nameserver 169.254.169.253" | tee -a /etc/resolv.conf.new
cat /etc/resolv.conf | tee --append /etc/resolv.conf.new
mv /etc/resolv.conf.new /etc/resolv.conf


# Set env vars for tool CLIs
echo "export VAULT_ADDR=http://$IP_ADDRESS:8200" | tee --append /home/$HOME_DIR/.bashrc
echo "export NOMAD_ADDR=http://$IP_ADDRESS:4646" | tee --append /home/$HOME_DIR/.bashrc


# GlusterFS
apt update && apt install -y glusterfs-client
mkdir $GLUSTER_MOUNT_DIR
echo "$GLUSTER_NODE_IP:/gv0 $GLUSTER_MOUNT_DIR glusterfs defaults,_netdev 0 0" >> /etc/fstab
while ! mount -a; do sleep 10; done # Retrying GlusterFS mount forever

# Fix Gluster fs not mounting on clients after reboot (depends on networking)
sed -i "s/NET_IFACE/$NET_IFACE/g" $OPS_CONFIG_DIR/rc.local
cp $OPS_CONFIG_DIR/rc.local /etc/rc.local
chmod 740 /etc/rc.local

# Copy common config for gossip encryption from GlusterFS volume
sleep 5 # in rare ocasions files hadn't been copied to the Gluster volume
cp $CONSUL_SHARED_DIR/consul_gossip_encrypt.hcl $CONSUL_CONFIG_DIR
systemctl restart consul
