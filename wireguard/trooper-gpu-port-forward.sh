#!/bin/bash

# Forwarding 10250 to 46710 since trooper allows only specific range of ports
# Add to trooper firewall "allow tcp 46710 : IP: ${GPU_NODE_IP}"

# Enable IP forwarding if not already
sudo sysctl -w net.ipv4.ip_forward=1

# Forward traffic from port 46710 to 10.10.0.1:10250
sudo iptables -t nat -A PREROUTING -p tcp --dport 46710 -j DNAT --to-destination 10.10.0.1:10250
sudo iptables -t nat -A POSTROUTING -p tcp -d 10.10.0.1 --dport 10250 -j MASQUERADE

# Allow the traffic
sudo iptables -A FORWARD -p tcp -d 10.10.0.1 --dport 10250 -j ACCEPT

