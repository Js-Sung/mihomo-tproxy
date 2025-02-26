#!/bin/sh

# 参考：https://mritd.com/2022/02/06/clash-tproxy/
# 代理本机和局域网其他机器
# fake-ip模式下ping等命令不能正确执行

CLASH_DNSPORT=1053
CLASH_RTMARK=6969
CLLASH_TPPROT=7893

for module in ip_set ip_set_bitmap_ip ip_set_bitmap_ipmac ip_set_bitmap_port ip_set_hash_ip ip_set_hash_ipport ip_set_hash_ipportip ip_set_hash_ipportnet ip_set_hash_net ip_set_hash_netport ip_set_list_set xt_set xt_TPROXY
do
	modprobe $module
done 

up(){
	# ROUTE RULES
	ip rule add fwmark 666 lookup 666
	ip route add local 0.0.0.0/0 dev lo table 666

	# clash 链负责处理转发流量 
	iptables -t mangle -N clash

	iptables -t mangle -A clash -d 0.0.0.0/8 -j RETURN
	iptables -t mangle -A clash -d 127.0.0.0/8 -j RETURN
	iptables -t mangle -A clash -d 10.0.0.0/8 -j RETURN
	iptables -t mangle -A clash -d 172.16.0.0/12 -j RETURN
	iptables -t mangle -A clash -d 192.168.0.0/16 -j RETURN
	iptables -t mangle -A clash -d 169.254.0.0/16 -j RETURN
	iptables -t mangle -A clash -d 224.0.0.0/4 -j RETURN
	iptables -t mangle -A clash -d 240.0.0.0/4 -j RETURN

	# 其他所有流量转向到 7893 端口，并打上 mark
	iptables -t mangle -A clash -p tcp -j TPROXY --on-port "$CLLASH_TPPROT" --tproxy-mark 666
	iptables -t mangle -A clash -p udp -j TPROXY --on-port "$CLLASH_TPPROT" --tproxy-mark 666

	# 转发所有 DNS 查询到 1053 端口
	# 此操作会导致所有 DNS 请求全部返回虚假 IP(fake ip 198.18.0.1/16)
	iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to "$CLASH_DNSPORT"
	iptables -t nat -I PREROUTING -p tcp --dport 53 -j REDIRECT --to "$CLASH_DNSPORT"

	# 最后让所有流量通过 clash 链进行处理
	iptables -t mangle -A PREROUTING -p tcp -j clash
	[ -n "$udp_pxy" ] && iptables -t mangle -A PREROUTING -p udp -j clash
}

up_local(){
	# clash_local 链负责处理网关本身发出的流量
	iptables -t mangle -N clash_local

	# 跳过内网流量
	iptables -t mangle -A clash_local -d 0.0.0.0/8 -j RETURN
	iptables -t mangle -A clash_local -d 127.0.0.0/8 -j RETURN
	iptables -t mangle -A clash_local -d 10.0.0.0/8 -j RETURN
	iptables -t mangle -A clash_local -d 172.16.0.0/12 -j RETURN
	iptables -t mangle -A clash_local -d 192.168.0.0/16 -j RETURN
	iptables -t mangle -A clash_local -d 169.254.0.0/16 -j RETURN
	iptables -t mangle -A clash_local -d 224.0.0.0/4 -j RETURN
	iptables -t mangle -A clash_local -d 240.0.0.0/4 -j RETURN

	# 为本机发出的流量打 mark
	iptables -t mangle -A clash_local -p tcp -j MARK --set-mark 666
	iptables -t mangle -A clash_local -p udp -j MARK --set-mark 666

	# 让本机发出的流量跳转到 clash_local(排除mohimo的出站流量)
	iptables -t mangle -A OUTPUT -p tcp -m mark ! --mark "$CLASH_RTMARK" -j clash_local
	[ -n "$udp_pxy" ] && iptables -t mangle -A OUTPUT -p udp -m mark ! --mark "$CLASH_RTMARK" -j clash_local
	
	# 本机的DNS请求重定向
	iptables -t nat -A OUTPUT -m mark ! --mark "$CLASH_RTMARK" -p udp --dport 53 -j REDIRECT --to-ports "$CLASH_DNSPORT"
	iptables -t nat -A OUTPUT -m mark ! --mark "$CLASH_RTMARK" -p tcp --dport 53 -j REDIRECT --to-ports "$CLASH_DNSPORT"
}

down(){
	ip rule del fwmark 666 table 666
	ip route del local 0.0.0.0/0 dev lo table 666

	iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to "$CLASH_DNSPORT"
	iptables -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to "$CLASH_DNSPORT"
	iptables -t mangle -D PREROUTING -p tcp -j clash
	iptables -t mangle -D PREROUTING -p udp -j clash 2>/dev/null
	
	iptables -t mangle -F clash
	iptables -t mangle -X clash
}

down_local(){
	iptables -t mangle -D OUTPUT -p tcp -m mark ! --mark "$CLASH_RTMARK" -j clash_local
	iptables -t mangle -D OUTPUT -p udp -m mark ! --mark "$CLASH_RTMARK" -j clash_local

	iptables -t nat -D OUTPUT -m mark ! --mark "$CLASH_RTMARK" -p udp --dport 53 -j REDIRECT --to-ports "$CLASH_DNSPORT"
	iptables -t nat -D OUTPUT -m mark ! --mark "$CLASH_RTMARK" -p tcp --dport 53 -j REDIRECT --to-ports "$CLASH_DNSPORT"
	
	iptables -t mangle -F clash_local
	iptables -t mangle -X clash_local
}

help() {
    echo -e "usage: $0 [-L] [-U] up|down\n -L: 启用透明代理本机\n -U: 启用代理UDP\n up: 开启透明代理  down: 关闭透明代理">&2
    exit 1
}

############################
udp_pxy=
loc_pxy=

while getopts 'LU' OPT; do
	case $OPT in
		L) loc_pxy=true;;
		U) udp_pxy=true;;
		?) help;;
	esac
done

shift $(($OPTIND - 1))

if [ "$*" = 'up' ]
then
	echo 'up...' >&2
	down 2>/dev/null
	down_local 2>/dev/null
	up
	[ -n "$loc_pxy" ] && up_local
elif [ "$*" = 'down' ]
then
	echo 'down...' >&2
	down
	down_local 2>/dev/null
else
	help
fi

exit 0
