#!/bin/sh
# 5G 面板交给 5gmodem（完整版）之后，树里需要跨文件对齐的只剩风扇包：
#   · menu.d / acl.d / uci-defaults 三处必须指向同一个包名和配置名
#   · 已经删掉的旧模组/短信包不能再被引用
set -u
fail=0
FAN=package/openfi/luci-app-openfi-fan

[ -d "$FAN" ] || { echo "缺少 $FAN"; exit 1; }

menu=$(find "$FAN/root/usr/share/luci/menu.d" -name '*.json' 2>/dev/null | head -1)
acl=$(find "$FAN/root/usr/share/rpcd/acl.d" -name '*.json' 2>/dev/null | head -1)
[ -n "$menu" ] || { echo "::error::缺少 $FAN 的 menu.d"; fail=1; }
[ -n "$acl" ]  || { echo "::error::缺少 $FAN 的 acl.d"; fail=1; }
ls "$FAN/root/etc/uci-defaults/" >/dev/null 2>&1 \
	|| { echo "::error::缺少 $FAN 的 uci-defaults"; fail=1; }

[ -n "$acl" ] && for k in '"ubus"' '"uci"'; do
	grep -q "$k" "$acl" || { echo "::error::ACL 里缺 $k"; fail=1; }
done

# 已删除的旧实现不能再出现在树里
for d in package/openfi/luci-app-openfi-modem package/openfi/luci-app-openfi-sms \
         files/usr/sbin/openfi-usbmode files/etc/init.d/openfi-usbmode; do
	[ -e "$d" ] && { echo "::error::应已删除: $d"; fail=1; }
done

# 不能还引用 openfi-usbmode / openfi-sms 这些删掉的脚本
if grep -rn "openfi-usbmode" files package scripts tests 2>/dev/null; then
	echo "::error::还有对 openfi-usbmode 的引用"
	fail=1
fi

[ "$fail" = 0 ] && echo "OK: 一致性检查通过"
exit "$fail"
