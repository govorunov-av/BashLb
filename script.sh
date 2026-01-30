#!/bin/bash
source_func () {
base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source $base_dir/env.conf
}
precheck () {
echo "Run prestart checks"
for bin in ip iptables; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR : Required binary not found: $bin"
    exit 1
  fi
done
if ! ip -V 2>/dev/null | grep -qi iproute2; then
  echo "ERROR : iproute2 should be installed"
  exit 1
fi
if [ -z "$net_int" ]; then
  echo "ERROR : net_int not set"
  exit 1
fi
if ! ip link show "$net_int" >/dev/null 2>&1; then
  echo "ERROR : Interface $net_int does not exist"
  exit 1
fi
if [[ ! "$test_method" =~ ^[012]$ ]]; then
  echo "ERROR : test_method must be 0, 1 or 2 (got '$test_method')"
  exit 1
fi
if [[ "$test_method" =~ ^[12]$ ]]; then
  if [ -z "$ping_check_ip" ]; then
    echo "ERROR : ping_check_ip must be set when test_method=$test_method"
    exit 1
  fi
  if [[ ! "$ping_check_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "ERROR : ping_check_ip is not a valid IPv4 address: $ping_check_ip"
    exit 1
  fi
fi
if [ "$test_method" -eq 1 ]; then
  if [ -z "$curl_check_site" ]; then
    echo "ERROR : curl_check_site must be set when test_method=1"
    exit 1
  fi
  if [[ ! "$curl_check_site" =~ ^http:// ]]; then
    echo "ERROR : curl_check_site must start with http:// ($curl_check_site)"
    exit 1
  fi
fi
if [ "$test_method" -eq 2 ]; then
  if [ -z "$wan_ip_check_site" ]; then
    echo "ERROR : wan_ip_check_site must be set when test_method=2"
    exit 1
  fi
  if [[ ! "$wan_ip_check_site" =~ ^http:// ]]; then
    echo "ERROR : wan_ip_check_site must start with http:// ($wan_ip_check_site)"
    exit 1
  fi
fi
gw_found=0
counter=1
while true; do
  gw="gw$counter"
  gw_value="${!gw}"
  [ -z "$gw_value" ] && break
  gw_found=1
  if [[ ! "$gw_value" =~ ^\|[^|]+\|[^|]*\|[^|]*\|$ ]]; then
    echo "ERROR : $gw неверный формат: $gw_value"
    echo "Ожидается: |IP|...|...|"
    exit 1
  fi
  first_part=$(echo "$gw_value" | cut -d'|' -f2)
  if [[ ! "$first_part" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "ERROR : $gw — первый адрес не похож на IP: $first_part"
    exit 1
  fi
  ((counter++))
done
if [ "$gw_found" -eq 0 ]; then
  echo "ERROR : No one gw defined"
  exit 1
fi
echo "OK : All checks passed"
counter=0
}


main_func () {
sysctl net.ipv4.ip_forward=1
sysctl net.ipv4.conf."$net_int".rp_filter=0
iptables -t nat -C POSTROUTING -o "$net_int" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$net_int" -j MASQUERADE
iptables -t mangle -C PREROUTING -m conntrack --ctstate NEW -j CONNMARK --save-mark 2>/dev/null || iptables -t mangle -A PREROUTING -m conntrack --ctstate NEW -j CONNMARK --save-mark
iptables -t mangle -C PREROUTING -j CONNMARK --restore-mark 2>/dev/null ||  iptables -t mangle -I PREROUTING -j CONNMARK --restore-mark
counter=0
check=0
while true; do
  (( counter += 2 ))
  last_gw="gw$counter"
  last_gw_value="${!last_gw}"
  (( counter-- ))
  if [ -n "$counter" ]; then
    gw="gw$counter"
    gw_value="${!gw}"
    table_gateway=$(awk -F "|" '{print$2}' <<< "$gw_value")
    probability=$( awk -F "|" '{print$3}' <<< "$gw_value" )
    
    if [ "$test_method" -ne 0 ]; then
      conn_test

      if [ "$check" -eq 0 ]; then
        rt_num=10$counter
        cat /etc/iproute2/rt_tables | grep -q $rt_num || echo "$rt_num gw$counter" >> /etc/iproute2/rt_tables
        ip rule show | grep -q gw$counter || ip rule add fwmark $counter table gw"$counter"
        ip r show default table gw$counter > /dev/null 2>&1 || ip route add default via "$table_gateway" dev $net_int table gw"$counter"
        if [ -n "$last_gw_value" ]; then
          iptables -t mangle -C PREROUTING -m conntrack --ctstate NEW -m statistic --mode random --probability $probability -j MARK --set-mark $counter 2>/dev/null ||  iptables -t mangle -C PREROUTING -m conntrack --ctstate NEW -j MARK --set-mark $counter || iptables -t mangle -I PREROUTING 2 -m conntrack --ctstate NEW -m statistic --mode random --probability $probability -j MARK --set-mark $counter
        else
#          line_number=$(iptables -t mangle -L PREROUTING --line-numbers -n | grep -c '^[0-9]')
          for ((i=1; i<counter; i++)); do
            iptables -t mangle -C PREROUTING -m conntrack --ctstate NEW -j MARK --set-mark $i 2>/dev/null && iptables -t mangle -D PREROUTING -m conntrack --ctstate NEW -j MARK --set-mark $i
          done 
          line_number=$(iptables -t mangle -L PREROUTING --line-numbers -n | grep -c '^[0-9]')
            iptables -t mangle -C PREROUTING -m conntrack --ctstate NEW -j MARK --set-mark $counter 2>/dev/null || iptables -t mangle -I PREROUTING $line_number -m conntrack --ctstate NEW -j MARK --set-mark $counter
          break
        fi
      else 
        if [ -n "$last_gw_value" ]; then
          iptables -t mangle -C PREROUTING -m conntrack --ctstate NEW -m statistic --mode random --probability $probability -j MARK --set-mark $counter 2>/dev/null && iptables -t mangle -D PREROUTING -m conntrack --ctstate NEW -m statistic --mode random --probability $probability -j MARK --set-mark $counter
          iptables -t mangle -C PREROUTING -m conntrack --ctstate NEW -j MARK --set-mark $counter 2>/dev/null && iptables -t mangle -D PREROUTING -m conntrack --ctstate NEW -j MARK --set-mark $counter
        else
          iptables -t mangle -C PREROUTING -m conntrack --ctstate NEW -j MARK --set-mark $counter 2>/dev/null && iptables -t mangle -D PREROUTING -m conntrack --ctstate NEW -j MARK --set-mark $counter
          prev_counter=$((counter - 1))

          check_gw="check_gw$prev_counter"
          check_gw_value="${!check_gw}"
          if [ "$check_gw_value" == 0 ]; then
          prev_gw="gw$prev_counter"
          prev_gw_value="${!prev_gw}"
            if [ -n "$prev_gw_value" ]; then
              prev_probability=$( awk -F "|" '{print$3}' <<< "$prev_gw_value" )
              for ((i=1; i<prev_counter; i++)); do
                iptables -t mangle -C PREROUTING -m conntrack --ctstate NEW -j MARK --set-mark $i 2>/dev/null && iptables -t mangle -D PREROUTING -m conntrack --ctstate NEW -j MARK --set-mark $i
              done 
              iptables -t mangle -C PREROUTING -m conntrack --ctstate NEW -m statistic --mode random --probability $prev_probability -j MARK --set-mark $prev_counter 2>/dev/null && iptables -t mangle -D PREROUTING -m conntrack --ctstate NEW -m statistic --mode random --probability $prev_probability -j MARK --set-mark $prev_counter
              prev_line_number=$(iptables -t mangle -L PREROUTING --line-numbers -n | grep -c '^[0-9]')
              iptables -t mangle -C PREROUTING -m conntrack --ctstate NEW -j MARK --set-mark $prev_counter 2>/dev/null || iptables -t mangle -I PREROUTING $prev_line_number -m conntrack --ctstate NEW -j MARK --set-mark $prev_counter
              else
                echo "ERROR : Unexpected error 1"
            fi
	  else
            check_counter=$((prev_counter - 1))
	    if [ $check_counter -gt 1 ]; then
              while [ $check_counter -ge 1 ]; do
                c_check_gw="check_gw$check_counter"
                c_check_gw_value="${!c_check_gw}"
                if [ "$c_check_gw_value" = "0" ]; then
                  c_gw="gw$check_counter"
                  c_gw_value="${!c_gw}"
                  if [ -n "$c_gw_value" ]; then
                    c_probability=$( awk -F "|" '{print$3}' <<< "$c_gw_value" )
                    for ((i=1; i<check_counter; i++)); do
                      iptables -t mangle -C PREROUTING -m conntrack --ctstate NEW -j MARK --set-mark $i 2>/dev/null && iptables -t mangle -D PREROUTING -m conntrack --ctstate NEW -j MARK --set-mark $i
                    done 
                    iptables -t mangle -C PREROUTING -m conntrack --ctstate NEW -m statistic --mode random --probability $c_probability -j MARK --set-mark $check_counter 2>/dev/null && iptables -t mangle -D PREROUTING -m conntrack --ctstate NEW -m statistic --mode random --probability $c_probability -j MARK --set-mark $check_counter
                    c_line_number=$(iptables -t mangle -L PREROUTING --line-numbers -n | grep -c '^[0-9]')
                    iptables -t mangle -C PREROUTING -m conntrack --ctstate NEW -j MARK --set-mark $check_counter 2>/dev/null || iptables -t mangle -I PREROUTING $c_line_number -m conntrack --ctstate NEW -j MARK --set-mark $check_counter
		    break
		  fi
	  	fi
	        ((check_counter--))
	      done
            else
	      echo "ALERT : No alived gateways!"
            fi
	  fi
          break
	fi
      fi 
    fi
  fi	  
done
}

conn_test () {
check=0
if [ $test_method -eq 1 ]; then
ip r del default 2>/dev/null
ip r add default via "$table_gateway"
ping_loss=$(ping -i 0.005 -4fqc 3 $ping_check_ip  2>/dev/null | awk -F',' '/packet loss/ {gsub(/[^0-9]/,"",$3); print $3}' | cut -c1-2)
if [ -n "$ping_loss" ]; then
  if [ "$ping_loss" -gt 50 ]; then
    echo "gw$counter : Ping too many losses ($ping_loss%)"
    check=1
  fi
else 
  check=1
fi
fi
sleep 1
if [ $test_method -eq 2 ]; then
  curl -s --max-time 3 $curl_check_site > /dev/null
  if [ $? -ne 0 ]; then
    echo "gw$counter : DNS / HTTP check failed"
    check=1
  fi
fi
if [ "$test_method" -eq 3 ]; then
  ip_state=$(awk -F "|" '{print$4}' <<< "$gw_value")
  ip_now=$(curl -s --max-time 5 $wan_ip_check_site)
  if [ "$ip_now" != "$ip_state" ]; then
    echo "gw$counter : WAN IP check failed"
    check=1
  fi
fi
if [ "$check" -eq 1 ]; then
  declare -g "check_gw$counter=1"   # fail
else
  declare -g "check_gw$counter=0"   # ok
fi
check_gw="check_gw$counter"
check_gw_value="${!check_gw}"
echo "in check func | check of gw$counter = $check_gw_value"
ip r del default
}
hourly_report_func () {
date +%D-%T
iptables -t mangle -L PREROUTING -v -n
}

source_func
precheck
while true; do
source_func
main_func
if [ $hourly_report -eq 1 ]; then
  current_hour=$(date +%H)
  current_minute=$(date +%M)
  if [ "$current_minute" = "00" ] && [ "$last_hour_run" != "$current_hour" ]; then
    last_hour_run="$current_hour"
    hourly_report_func
  fi
fi
sleep 4
done
