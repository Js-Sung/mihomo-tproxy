#!/bin/bash

CFG_DIR='./cfg'							# mihomo配置目录，相对于此脚本的位置
TMP_DIR='/tmp/rules_and_nodes'			# 存放节点和规则的目录，创建后会链接在CFG_DIR目录下面
BIN="./mihomo-linux-mipsle-hardfloat"	# mihomo本体
LOCKFILE="/tmp/mihomo.lock"				# 进程锁文件

#######################################################
# error msg
log_e(){ echo -e "\x1b[30;41merror:\x1b[0m \x1b[31m${*}\x1b[0m" >&2; }
# info msg
log_i(){ echo -e "\x1b[30;42minfo:\x1b[0m \x1b[32m${*}\x1b[0m" >&2; }
# warn msg
log_w(){ echo -e "\x1b[30;43mwarning:\x1b[0m \x1b[33m${*}\x1b[0m" >&2; }
#######################################################
startClash(){
    local a b
    [ -f "${CFG_DIR}/config.yaml" ] || { log_e "config.yaml is not found"; return 1; }
    [ -d "${TMP_DIR}" ] || { rm -f "${TMP_DIR}"; mkdir "${TMP_DIR}"; } || { log_e "failed to makedir ${TMP_DIR}"; return 2; }
    a=$(basename "${TMP_DIR}")
    b=${CFG_DIR}/${a}
    [ -L "${b}" -a -n "$(ls -l "${b}" 2>/dev/null | grep "${TMP_DIR}")" ] || { rm -rf "${b}"; ln -s "${TMP_DIR}" "${b}"; } || { log_e "failed to make soft link ${b} -> ${TMP_DIR}"; return 3; }
    if killall -0 "${BIN##*/}" &> /dev/null
    then
        log_i "${BIN##*/} is running already."
    else
        # 启动clash
        nohup $BIN -d "$CFG_DIR" &> /dev/null &
        log_i "waiting for $BIN up."
        sleep 2

        if killall -0 "${BIN##*/}" &> /dev/null
        then
            log_i "$BIN started successfully."
        else
            log_e "failed to start $BIN."
            return 4
        fi
    fi
    return 0
}

stopClash(){
    # 杀死clash进程
	killall "${BIN##*/}" &> /dev/null
	sleep 1
	if ! killall -0 "${BIN##*/}" &> /dev/null
	then
		log_i "kill $BIN successfully."
	else
		log_e "failed to kill $BIN."
		return 1
	fi
    return 0
}

##################iptables设置##########################
CLASH_DNSPORT=1053
CLASH_RTMARK=6969
CLLASH_TPPROT=7893

for module in ip_set ip_set_bitmap_ip ip_set_bitmap_ipmac ip_set_bitmap_port ip_set_hash_ip ip_set_hash_ipport ip_set_hash_ipportip ip_set_hash_ipportnet ip_set_hash_net ip_set_hash_netport ip_set_list_set xt_set xt_TPROXY
do
	modprobe $module
done 

up(){
	local udp_pxy
	udp_pxy=$1
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
	iptables -t mangle -C PREROUTING -p tcp -j clash 2>/dev/null || iptables -t mangle -A PREROUTING -p tcp -j clash
	[ -n "$udp_pxy" -a "$udp_pxy" == "1" ] && { iptables -t mangle -C PREROUTING -p udp -j clash 2>/dev/null || iptables -t mangle -A PREROUTING -p udp -j clash; }
}

up_local(){
	local udp_pxy
	udp_pxy=$1
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
	iptables -t mangle -C OUTPUT -p tcp -m mark ! --mark "$CLASH_RTMARK" -j clash_local 2>/dev/null || iptables -t mangle -A OUTPUT -p tcp -m mark ! --mark "$CLASH_RTMARK" -j clash_local
	[ -n "$udp_pxy" -a "$udp_pxy" == "1" ] && { iptables -t mangle -C OUTPUT -p udp -m mark ! --mark "$CLASH_RTMARK" -j clash_local 2>/dev/null || iptables -t mangle -A OUTPUT -p udp -m mark ! --mark "$CLASH_RTMARK" -j clash_local; }
	
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

check(){
	local loc_en udp_en t0 t1 t2 t3 t4

	# 判断路由信息
	ip rule show | grep -q 'fwmark 0x29a lookup 666' && ip route show table 666 | grep -q 'local default dev lo' || return 1
	
	# 判断基本透明代理规则
	iptables -t mangle -C clash -p tcp -j TPROXY --on-port "$CLLASH_TPPROT" --tproxy-mark 666 &>/dev/null && \
	iptables -t mangle -C clash -p udp -j TPROXY --on-port "$CLLASH_TPPROT" --tproxy-mark 666 &>/dev/null && \
	iptables -t nat -C PREROUTING -p udp --dport 53 -j REDIRECT --to "$CLASH_DNSPORT" &>/dev/null && \
	iptables -t nat -C PREROUTING -p tcp --dport 53 -j REDIRECT --to "$CLASH_DNSPORT" &>/dev/null && \
	iptables -t mangle -C PREROUTING -p tcp -j clash &>/dev/null || return 2
	
	[ "$1" != "1" ] && loc_en=1 || loc_en=0
	[ "$2" != "1" ] && udp_en=1 || udp_en=0
	
	# 判断udp_en的配置
	iptables -t mangle -C PREROUTING -p udp -j clash &>/dev/null
	t0=$?
	[ "$udp_en" = "$t0" ] || return 3
	
	# 判断loc_en的配置
	iptables -t mangle -C OUTPUT -p tcp -m mark ! --mark "$CLASH_RTMARK" -j clash_local &>/dev/null
	t0=$?
	iptables -t nat -C OUTPUT -m mark ! --mark "$CLASH_RTMARK" -p udp --dport 53 -j REDIRECT --to-ports "$CLASH_DNSPORT" &>/dev/null
	t1=$?
	iptables -t nat -C OUTPUT -m mark ! --mark "$CLASH_RTMARK" -p tcp --dport 53 -j REDIRECT --to-ports "$CLASH_DNSPORT" &>/dev/null
	t2=$?
	iptables -t mangle -C clash_local -p tcp -j MARK --set-mark 666 &>/dev/null
	t3=$?
	iptables -t mangle -C clash_local -p udp -j MARK --set-mark 666 &>/dev/null
	t4=$?
	[ "$loc_en" = "$t0" -a "$loc_en" = "$t1" -a "$loc_en" = "$t2"  -a "$loc_en" = "$t3"  -a "$loc_en" = "$t4" ] || return 4
	
	# 启用本机代理时，判断udp_en的配置
	iptables -t mangle -C OUTPUT -p udp -m mark ! --mark "$CLASH_RTMARK" -j clash_local &>/dev/null
	t0=$?
	[ "$loc_en" = "0" -a "$t0" = "$udp_en" -o "$loc_en" = "1"  -a "$t0" != "0" ] || return 5
	
	# 检查正常返回
	return 0
}

#######################################################
start(){
	local loc_en udp_en a b
	loc_en=$1
	udp_en=$2

	killall -0 "${BIN##*/}" &>/dev/null
	a=$?
	
	if [ "$a" != '0' ]		# clash未启动
	then
		down &>/dev/null
		down_local &>/dev/null
		if ! startClash
		then
			logger -t "【mihomo】" "❌启动失败"
			return 1
		fi
		up "$udp_en"
		[ "$loc_en" == '1' ] && up_local "$udp_en"
		logger -t "【mihomo】" "✔️启动完成(本地代理:${loc_en}, UDP代理:${udp_en})"
	else
		check "$loc_en" "$udp_en"
		b=$?
		if [ "$b" != '0' ]
		then
			logger -t "【mihomo】" "⚠透明代理规则检查返回:${b}，正在重新启用(本地代理:${loc_en}, UDP代理:${udp_en})"
			log_w "透明代理规则检查返回:${b}，正在重新启用(本地代理:${loc_en}, UDP代理:${udp_en})"
			down &>/dev/null
			down_local &>/dev/null
			up "$udp_en"
			[ "$loc_en" == '1' ] && up_local "$udp_en"
		else
			log_i "已经在运行，无需操作"
		fi
	fi
	return 0
}

stop(){
	logger -t "【mihomo】" "👿关闭mihomo和透明代理"
	down &>/dev/null
	down_local &>/dev/null
	stopClash
	return $?
}

#######################################################
# 进入脚本所在目录
cd $(dirname "$0")
{
	flock -n 198
	[ "$?" != "0" ] && { log_e "failed to get lock file. Is '$0' runing already?"; exit 55; }
	
	case "$1" in
		start) start "$2" "$3" ;;
		stop) stop ;;
		*) echo "$0 [start|stop] [local_en] [udp_en]" ;;
	esac
	
	flock -u 198
} 198<>"$LOCKFILE"

rm -f "$LOCKFILE"

exit 0
