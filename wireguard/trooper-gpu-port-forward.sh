#!/bin/bash

# Forwarding 10250 to 46710 since trooper allows only specific range of ports
# Add to trooper firewall "allow tcp 46710 : IP: ${GPU_NODE_IP}"

# Enable IP forwarding if not already
sudo sysctl -w net.ipv4.ip_forward=1

# Forward traffic from port 46710 to 10.10.0.1:10250
sudo iptables -t nat -A PREROUTING -p tcp --dport 46784 -j DNAT --to-destination 10.10.0.1:10250
sudo iptables -t nat -A POSTROUTING -p tcp -d 10.10.0.1 --dport 10250 -j MASQUERADE

# Allow the traffic
sudo iptables -A FORWARD -p tcp -d 10.10.0.1 --dport 10250 -j ACCEPT


# set Internal IP of GPU node
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml <<EOF
node-ip: 10.10.0.2
flannel-iface: wg0
EOF
sudo systemctl restart k3s-agent


#open UFW Flannel VXLAN uses UDP 8472 for pod-to-pod networking across nodes
sudo systemctl start ufw
sudo ufw enable
sudo ufw allow from 10.10.0.0/24 to any port 8472 proto udp
sudo ufw allow 22/tcp


# redirect envoy gateway port 30080 to 43650
sudo iptables -t nat -A PREROUTING -p tcp --dport 43650 -j REDIRECT --to-port 30080
sudo iptables -t nat -L PREROUTING -n | grep 43650


#disable reverse path filtering
sudo sysctl -w net.ipv4.conf.all.rp_filter=1
sudo sysctl -w net.ipv4.conf.wg0.rp_filter=1