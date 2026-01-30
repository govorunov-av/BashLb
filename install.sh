#!/bin/bash
if [ -n "$1" ]; then
chmod +x "$1"
cat << EOF1 > /etc/systemd/system/bash_lb.service
[Unit]
Description=BashLB simple isp load balancer. Home repo: https://github.com/govorunov-av/BashLb
After=network.target

[Service]
Type=simple
ExecStart=$1
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF1
systemctl daemon-reload
echo "Install was completed!"
systemctl enable --now bash_lb.service
echo "Service bash_lb.service was enabled and started"
echo "You can check it by 'systemctl status bash_lb' "
else 
echo "You must run it with $1, ex 'install.sh /root/bash_lb/service.sh'"
fi

