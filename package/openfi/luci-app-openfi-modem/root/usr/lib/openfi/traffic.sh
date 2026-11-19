#!/bin/sh
#
# OpenFi 5G 流量统计 —— 在路由器侧定时采样,按天累计
#
# 【为什么在路由器侧记,而不是模组侧】
#   · 模组根文件系统只读,加不了自启动项,也没 crond
#   · 模组的 AT+QGDCNT 是【本次会话】的计数,模组一重启就归零
#   · 路由器有 flash、有 cron,记在这里断电也不丢
#
# 【模组重启怎么处理】
#   下次读到的值比上次小,说明模组重启过(或 PDN 重连),
#   这时不能用 "新 - 旧"(会得到负数),而应把新值全部当作增量。
#
# 存储:
#   /etc/openfi-traffic/state      上次的原始计数 + 当日累计
#   /etc/openfi-traffic/YYYY-MM    当月每天一行,便于画图和回溯

DIR=/etc/openfi-traffic
STATE=$DIR/state
AT_BIN=/usr/sbin/openfi-modem

mkdir -p "$DIR"

# 读模组计数,输出 "tx rx";失败输出空
read_counter() {
	"$AT_BIN" at 'AT+QGDCNT?' 2>/dev/null \
		| awk '/^\+QGDCNT:/ {
			sub(/^\+QGDCNT: */, "");
			split($0, a, ",");
			gsub(/[^0-9]/, "", a[1]);
			gsub(/[^0-9]/, "", a[2]);
			if (a[1] != "" && a[2] != "")
				print a[1], a[2];
			exit;
		}'
}

now_date() { date +%Y-%m-%d; }
now_month() { date +%Y-%m; }
now_epoch() { date +%s; }

load_state() {
	TX_LAST=0; RX_LAST=0; TOTAL_TX=0; TOTAL_RX=0; UPDATED=0
	[ -f "$STATE" ] || return 0
	# shellcheck disable=SC1090  # 状态文件路径是可变的(测试时会覆盖)
	. "$STATE" 2>/dev/null || true
}

save_state() {
	cat > "$STATE.tmp" <<EOF
TX_LAST=$TX_LAST
RX_LAST=$RX_LAST
TOTAL_TX=$TOTAL_TX
TOTAL_RX=$TOTAL_RX
UPDATED=$UPDATED
EOF
	mv "$STATE.tmp" "$STATE"
}

# 把今天的增量写进月文件(每天一行)
record_day() {
	d=$(now_date); m=$(now_month)
	f="$DIR/$m"
	line="$(awk -v d="$d" '$1==d {print; exit}' "$f" 2>/dev/null)"
	if [ -n "$line" ]; then
		grep -v "^$d " "$f" > "$f.tmp" 2>/dev/null
		mv "$f.tmp" "$f"
	fi
	echo "$d $DAY_RX $DAY_TX" >> "$f"
}

case "$1" in
read)
	COUNTER=$(read_counter)
	if [ -z "$COUNTER" ]; then
		echo '{"ok":false,"error":"读不到 AT+QGDCNT"}'
		exit 1
	fi
	TX=$(echo "$COUNTER" | awk '{print $1}')
	RX=$(echo "$COUNTER" | awk '{print $2}')

	load_state

	# ★ 模组重启过(计数变小)→ 本次开机以来的全部算作增量
	if [ "$TX" -lt "$TX_LAST" ] 2>/dev/null; then
		DTX=$TX
		DRX=$RX
		olog="计数变小,判定模组重启,以当前值为增量"
	else
		DTX=$((TX - TX_LAST))
		DRX=$((RX - RX_LAST))
		olog=""
	fi

	TOTAL_TX=$((TOTAL_TX + DTX))
	TOTAL_RX=$((TOTAL_RX + DRX))
	TX_LAST=$TX
	RX_LAST=$RX
	UPDATED=$(now_epoch)

	# 当日累计:从月文件里当天那行取
	d=$(now_date); m=$(now_month)
	DAY_RX=$(awk -v d="$d" '$1==d {print $2; exit}' "$DIR/$m" 2>/dev/null)
	DAY_TX=$(awk -v d="$d" '$1==d {print $3; exit}' "$DIR/$m" 2>/dev/null)
	[ -z "$DAY_RX" ] && DAY_RX=0
	[ -z "$DAY_TX" ] && DAY_TX=0
	DAY_RX=$((DAY_RX + DRX))
	DAY_TX=$((DAY_TX + DTX))

	save_state
	record_day

	printf '{"ok":true,"rx_delta":%d,"tx_delta":%d,"total_rx":%d,"total_tx":%d,"day_rx":%d,"day_tx":%d' \
		"$DRX" "$DTX" "$TOTAL_RX" "$TOTAL_TX" "$DAY_RX" "$DAY_TX"
	if [ -n "$olog" ]; then
		printf ',"note":"%s"' "$olog"
	fi
	printf '}\n' 
	;;

show)
	load_state
	d=$(now_date); m=$(now_month)
	DAY_RX=$(awk -v d="$d" '$1==d {print $2; exit}' "$DIR/$m" 2>/dev/null)
	DAY_TX=$(awk -v d="$d" '$1==d {print $3; exit}' "$DIR/$m" 2>/dev/null)
	[ -z "$DAY_RX" ] && DAY_RX=0
	[ -z "$DAY_TX" ] && DAY_TX=0
	# 本月合计
	MON_RX=$(awk '{s+=$2} END{print s+0}' "$DIR/$m" 2>/dev/null)
	MON_TX=$(awk '{s+=$3} END{print s+0}' "$DIR/$m" 2>/dev/null)
	DAYS=$(wc -l < "$DIR/$m" 2>/dev/null || echo 0)
	printf '{"ok":true,"day":"%s","day_rx":%d,"day_tx":%d,"month":"%s","month_rx":%d,"month_tx":%d,"days":%d,"total_rx":%d,"total_tx":%d,"updated":%d}\n' \
		"$d" "$DAY_RX" "$DAY_TX" "$m" "$MON_RX" "$MON_TX" "$DAYS" \
		"${TOTAL_RX:-0}" "${TOTAL_TX:-0}" "${UPDATED:-0}"
	;;

reset)
	load_state
	TOTAL_TX=0; TOTAL_RX=0; UPDATED=$(now_epoch)
	save_state
	echo '{"ok":true,"note":"累计已清零(模组计数保持不动)"}'
	;;

*)
	echo "用法: $0 {read|show|reset}"
	echo "  read   采样一次(给 cron 用)"
	echo "  show   看今日/本月/总计"
	echo "  reset  清零累计"
	exit 1
	;;
esac
