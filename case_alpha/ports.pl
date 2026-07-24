#	Ports	Protocol	Source	Action	Description	
1	43630	TCP	0.0.0.0/0	Allow	nodeport 30080	   
2	43629	TCP	185.150.27.254	Allow	port forward 10250 kubelet api	   
3	43641	TCP	91.98.120.43	Allow	my ssh connection	   


sudo ufw allow from 10.10.0.0/24 to any port 6443 proto tcp


ufw status verbose
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), deny (routed)
New profiles: skip

To                         Action      From
--                         ------      ----
8472/udp                   ALLOW IN    10.10.0.0/24
22/tcp                     ALLOW IN    Anywhere
6443/tcp                   ALLOW IN    10.10.0.0/24
443/tcp                    ALLOW IN    Anywhere
51820/udp                  ALLOW IN    Anywhere
22/tcp (v6)                ALLOW IN    Anywhere (v6)
443/tcp (v6)               ALLOW IN    Anywhere (v6)
51820/udp (v6)             ALLOW IN    Anywhere (v6)