#!/bin/sh
# wayland-cast-doctor
#
# 排查「Wayland 下桌面共享 / 截图 / 剪贴板不出画面」，不绑定任何合成器。
#
# 共享链路要同时满足四个条件，任意一个断了都不出画面。这里逐项检查，
# 并在第一个断点处说明原因：
#
#   1. 客户端得走 portal，否则 QQ 根本不会去要屏幕
#   2. portal 后端得提供 ScreenCast 接口，gtk 后端就没有
#   3. 合成器得真的宣告采集能力，niri 原本不宣告，这是它要打补丁的原因
#   4. PipeWire 得能协商出格式并真正出帧
#
# 只读状态，不重启任何东西，通话 / 共享中跑也安全。

have() { command -v "$1" >/dev/null 2>&1; }

BLOCK=0

# 只在终端上色；管道/重定向时保持纯文本
if [ -t 1 ]; then
	R=$(printf '\033[31m'); G=$(printf '\033[32m')
	Y=$(printf '\033[33m'); B=$(printf '\033[0m')
else
	R=""; G=""; Y=""; B=""
fi

ok()   { printf '  %s正常%s  %s\n' "$G" "$B" "$1"; }
info() { printf '  %s提示%s  %s\n' "$B" "$B" "$1"; }
warn() { printf '  %s注意%s  %s\n' "$Y" "$B" "$1"; }
bad()  { printf '  %s故障%s  %s\n' "$R" "$B" "$1"; BLOCK=1; }

head_() { printf '\n%s\n' "$1"; }

# ---------------------------------------------------------------------------
head_ "【一】会话环境"

if [ "${XDG_SESSION_TYPE:-}" != "wayland" ]; then
	bad "当前不是 Wayland 会话（XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-未设置}）"
	printf '       这一套检查只对 Wayland 有意义。X11 下共享走 XGetImage，不经过 portal。\n'
else
	ok "Wayland 会话"
fi

# The value of XDG_CURRENT_DESKTOP is not standardised: KDE reports "KDE" on
# some distributions and "Plasma" on others, Ubuntu prefixes GNOME with the
# distribution name ("ubuntu:GNOME"), and Hyprland is sometimes lowercased.
# Match on substrings rather than equality.
COMPOSITOR="${XDG_CURRENT_DESKTOP:-未设置}"
case "$COMPOSITOR" in
	*niri*)        ok "合成器 niri" ;;
	*[Hh]yprland*) ok "合成器 Hyprland（wlroots 系）" ;;
	*sway*)        ok "合成器 Sway（wlroots 系）" ;;
	*GNOME*|*gnome*) ok "合成器 GNOME（mutter）" ;;
	*KDE*|*Plasma*|*plasma*) ok "合成器 KDE Plasma（KWin）" ;;
	*)             info "合成器 $COMPOSITOR" ;;
esac

# ---------------------------------------------------------------------------
head_ "【二】portal 后端"

# Which backend is preferred decides whether ScreenCast exists at all. The gtk
# backend implements no capture interface, so a session that falls back to it
# has no screen sharing capability whatsoever.
if ! have busctl; then
	warn "没有 busctl，跳过后端检查"
elif ! busctl --user list 2>/dev/null | grep -q org.freedesktop.portal.Desktop; then
	bad "portal 未在会话总线上"
	printf '       装 xdg-desktop-portal 并确认后端已启用。\n'
else
	ok "portal 在会话总线上"

	BACKENDS=$(busctl --user list 2>/dev/null |
		grep -oE 'org\.freedesktop\.impl\.portal\.desktop\.[a-z]+' |
		sed 's/.*\.//' | sort -u | tr '\n' ' ')
	info "可用后端：${BACKENDS:-无}"

	CAST_OK=""
	for b in $BACKENDS; do
		n=$(busctl --user introspect "org.freedesktop.impl.portal.desktop.$b" \
			/org/freedesktop/portal/desktop 2>/dev/null |
			grep -c 'org.freedesktop.impl.portal.ScreenCast')
		if [ "${n:-0}" -gt 0 ]; then
			CAST_OK="$CAST_OK $b"
		fi
	done

	if [ -n "$CAST_OK" ]; then
		ok "提供 ScreenCast 的后端：$CAST_OK"
	else
		bad "没有任何后端提供 ScreenCast 接口"
		printf '       gtk 后端不实现屏幕采集。如果首选里的 default 被设成 gtk，\n'
		printf '       共享一定失败。改 /usr/share/xdg-desktop-portal/portals.conf。\n'
	fi
fi

# ---------------------------------------------------------------------------
head_ "【三】合成器能力宣告"

# The step that fails most often and is least obvious. A compositor can
# implement capture fully and still be rejected, because the portal backend
# reads AvailableSourceTypes / AvailableCursorModes off the Mutter ScreenCast
# interface and refuses every SelectSources call when it reads zero.
case "$COMPOSITOR" in
	*niri*)
		if have pacman && pacman -Qo /usr/bin/niri 2>/dev/null | grep -q 'niri-portal-cast'; then
			ok "niri 来自 niri-portal-cast（带能力宣告与限帧率补丁）"
		elif have pacman && pacman -Qo /usr/bin/niri >/dev/null 2>&1; then
			warn "/usr/bin/niri 不是 niri-portal-cast，多半是官方原版"
			printf '       原版 niri 不宣告 AvailableSourceTypes，portal 拒绝所有\n'
			printf '       SelectSources，表现是选择框里只有「整个屏幕」。\n'
		else
			info "无法判断 /usr/bin/niri 来自哪个包"
		fi
		;;
	*[Hh]yprland*|*sway*)
		ok "wlroots 系合成器，采集由 wlr 或 hyprland 后端提供（见下）"
		;;
	*GNOME*|*gnome*)
		ok "mutter 自己实现 ScreenCast，能力宣告完整"
		;;
esac

# wlroots compositors have one problem no other family has: the portal backend
# is a separate project rather than part of the compositor, and there are two
# of them that are not interchangeable.
#
#   xdg-desktop-portal-wlr       whole-screen only
#   xdg-desktop-portal-hyprland  fork of the above, adds window selection
#
# Hyprland ships its own fork because the window picker in the wlr one is too
# limited. Sway and the rest only ever get the wlr backend, so asking them for
# a single window is a dead end -- the portal never offers it, and no
# client-side fixing changes that.
case "$COMPOSITOR" in
	*[Hh]yprland*)
		if busctl --user list 2>/dev/null | grep -q 'portal\.desktop\.hyprland'; then
			ok "装了 xdg-desktop-portal-hyprland（支持选单个窗口）"
		elif busctl --user list 2>/dev/null | grep -q 'portal\.desktop\.wlr'; then
			bad "只装了 xdg-desktop-portal-wlr，共享时选不了单个窗口"
			printf '       Hyprland 有自己的 portal 后端，是 wlr 的 fork，多了窗口级\n'
			printf '       采集。wlr 那个只能共享整个输出。缺了不报错，只是选择框\n'
			printf '       里没有窗口条目。\n'
			printf '       装：sudo pacman -S xdg-desktop-portal-hyprland\n'
		else
			bad "没有 Hyprland 用的 portal 后端"
			printf '       装：sudo pacman -S xdg-desktop-portal-hyprland\n'
		fi
		;;
	*sway*|*river*|*labwc*|*[Ww]ayfire*)
		# No fork exists for these, so only warn when a backend is missing
		# entirely. Do not suggest the hyprland backend here: it hard-depends
		# on Hyprland and will not run on these compositors.
		if busctl --user list 2>/dev/null | grep -qE 'portal\.desktop\.(wlr|hyprland)'; then
			info "wlroots 系只能共享整个屏幕（没有窗口级采集后端）"
			printf '       这是 Sway / river 这类合成器的固有限制，不是配置问题。\n'
		else
			bad "既没有 wlr 后端也没有 hyprland 后端"
			printf '       装：sudo pacman -S xdg-desktop-portal-wlr\n'
		fi
		;;
esac

# Ask the compositor itself which globals it advertises. Checking
# /usr/share/wayland-protocols only proves the protocol definitions are
# installed, which is true on any machine with wayland-protocols and says
# nothing about whether this compositor implements them. wayland-info
# connects to the running compositor and reads its actual global list.
if ! have wayland-info; then
	warn "没装 wayland-info，跳过能力探测（pacman -S wayland-utils）"
elif ! have timeout; then
	warn "没装 timeout，跳过能力探测"
else
	# Some compositors answer slowly or not at all; never hang the script.
	WL_GLOBALS=$(timeout 15 wayland-info 2>/dev/null | grep -oE "^interface: '[^']+'" | sed "s/interface: '//; s/'//")

	if [ -z "$WL_GLOBALS" ]; then
		warn "wayland-info 没拿到全局接口列表"
		printf '       合成器可能没响应，或者不是 Wayland 会话。\n'
	else
		info "合成器宣告了 $(printf '%s\n' "$WL_GLOBALS" | wc -l) 个全局接口"

		# wlr-screencopy or ext-image-copy-capture: QQ screenshots need one of
		# them, otherwise the capture path yields a black image.
		if printf '%s\n' "$WL_GLOBALS" | grep -qE '^(zwlr_screencopy_manager_v1|ext_image_(copy_capture|blit_capture)_manager_v1)$'; then
			ok "截图协议可用"
		else
			warn "合成器不宣告 wlr-screencopy / ext-image-copy-capture"
			printf '       QQ 截图在 Wayland 下靠 wlr-screencopy，缺了只能给黑图。\n'
			printf '       GNOME 和部分合成器不支持，这是已知限制。\n'
		fi

		# data-control: without it QQ can only touch the X11 clipboard, so the
		# Wayland clipboard bridge has nothing to talk to.
		if printf '%s\n' "$WL_GLOBALS" | grep -qE '^(zwlr_data_control_manager_v1|ext_data_control_manager_v1)$'; then
			ok "data-control 可用（剪贴板桥接可用）"
		else
			warn "合成器不宣告 data-control"
			printf '       QQ 的剪贴板修复不可用，它只读写 X11 剪贴板。\n'
			printf '       GNOME 是已知不支持的合成器。\n'
		fi

		# DMA-BUF export matters for anything that wants zero-copy capture.
		if printf '%s\n' "$WL_GLOBALS" | grep -qE '^zwlr_export_dmabuf_manager_v1$'; then
			ok "支持 DMA-BUF 导出（可零拷贝采集）"
		else
			info "不宣告 DMA-BUF 导出，采集只能走 SHM 拷贝"
		fi
	fi
fi

# ---------------------------------------------------------------------------
head_ "【四】PipeWire 与音频图"

if ! have wpctl; then
	warn "没有 wpctl，跳过音频检查"
elif ! wpctl status 2>/dev/null | grep -q 'PipeWire'; then
	bad "PipeWire 没在运行"
	printf '       共享音频和视频都走 PipeWire，它不在就没有共享。\n'
else
	ok "PipeWire 在运行"

	WIRED=$(wpctl status 2>/dev/null | grep -c 'analog-stereo\|analog-output')
	BT=$(wpctl status 2>/dev/null | grep -c 'bluez_output')

	if [ "${WIRED:-0}" -gt 0 ] && [ "${BT:-0}" -gt 0 ]; then
		warn "有线和蓝牙音频输出同时在线"
		printf '       WirePlumber 会在两者之间换默认设备，PipeWire 重建整个图，\n'
		printf '       客户端手里的句柄全部失效。表现是选择框弹出、点共享、然后\n'
		printf '       崩掉或者 300 毫秒内退出。解法：只留一种输出。\n'
	else
		ok "只有一种音频输出（有线=${WIRED:-0} 蓝牙=${BT:-0}）"
	fi
fi

# ---------------------------------------------------------------------------
head_ "【五】内存与采集流"

if [ -r /proc/meminfo ]; then
	shmem=$(awk '/^Shmem:/{printf "%.2f", $2/1048576}' /proc/meminfo)
	if [ -n "$shmem" ]; then
		if awk "BEGIN{exit !($shmem > 4)}"; then
			warn "Shmem ${shmem} GiB"
			printf '       共享时超过 4 GiB 通常意味着帧生产快过消费：niri 宣告\n'
			printf '       VideoFramerate 0/1 会被理解成不限速，软件编码器来不及\n'
			printf '       消费，裸帧堆在共享内存里。niri 用户加 screencasting 块限帧率。\n'
			printf '       注意限制值是每次开始共享时读的（niri-portal-cast -10 起）：改完
'
			printf '       config.kdl 重开一次共享就生效，不用重启 niri。真实协商值看
'
			printf '       journal 里的 framerate: spa_fraction，不看配置文件。\n'
		else
			ok "Shmem ${shmem} GiB"
		fi
	fi
fi

if have wpctl; then
	if wpctl status 2>/dev/null | grep -qiE 'screencast|record'; then
		ok "有活动的采集流"
	else
		info "当前没有采集流，共享时再跑一次"
	fi
fi

# ---------------------------------------------------------------------------
head_ "【六】客户端侧：linuxqq-wayland-fix 注入检测"

LIBS="libqq-wl-portal.so libqq-clipbridge.so libqq-screenshot.so libqq-borderfix.so"
qqfix_ver=$(pacman -Q linuxqq-wayland-fix 2>/dev/null | awk '{print $2}')
if [ -n "$qqfix_ver" ]; then
	ok "已安装 linuxqq-wayland-fix $qqfix_ver"
elif [ -d /usr/lib/linuxqq-wayland-fix ]; then
	info "有 /usr/lib/linuxqq-wayland-fix，但 pacman 查不到包名（其它发行版的包？）"
else
	warn "没装 linuxqq-wayland-fix"
	printf '       QQ 不会去走 portal 选源，共享/剪贴板/截图都退回它自己的老实现。\n'
	printf '       装它：paru -S linuxqq-wayland-native-screenshare-fix-git\n'
fi

qqpids=$(pgrep -x qq 2>/dev/null)
if [ -z "$qqpids" ]; then
	info "QQ 没在运行（共享前请从「QQ（Wayland 修复版）」启动）"
else
	# 收帧的是 --type=ppapi 那个进程，它没被注入就等于没修
	ppapi=""
	for pid in $qqpids; do
		case "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" in
			*--type=ppapi*) ppapi="$pid" ;;
		esac
	done

	launcher=0
	for pid in $qqpids; do
		grep -qs 'linuxqq-wayland-fix' "/proc/$pid/cmdline" 2>/dev/null && launcher=1
		grep -qs 'linuxqq-wayland-fix' "/proc/$pid/environ" 2>/dev/null && launcher=1
	done
	if [ "$launcher" -eq 1 ]; then
		ok "QQ 是从修复版启动器起来的"
	else
		bad "QQ 不是从修复版启动器起来的（cmdline/environ 里都没有它）"
		printf '       完全退出 QQ（含托盘）后，从「QQ（Wayland 修复版）」启动。\n'
	fi

	check_pid() {  # $1=pid $2=标签
		local pid="$1" label="$2" got missing="" l n
		got=$(grep -ohE 'libqq-[a-z-]+\.so' "/proc/$pid/maps" 2>/dev/null | sort -u)
		n=$(printf '%s\n' "$got" | grep -c .)
		for l in $LIBS; do
			printf '%s\n' "$got" | grep -qx "$l" || missing="$missing $l"
		done
		if [ "$n" -eq 0 ]; then
			bad "$label（PID $pid）没有任何注入库"
			printf '       没注入的话它走的是 QQ 自己的老实现。\n'
		elif [ -n "$missing" ]; then
			warn "$label（PID $pid）只注入了 $n/4 个库"
			printf '       缺：%s\n' "$missing"
		else
			ok "$label（PID $pid）四个库齐全"
		fi
	}

	if [ -n "$ppapi" ]; then
		check_pid "$ppapi" "收帧进程 ppapi"
	else
		warn "没找到 --type=ppapi 进程（还没开始过共享？）"
	fi
	others=0; others_ok=0
	for pid in $qqpids; do
		[ "$pid" = "$ppapi" ] && continue
		grep -qs 'libqq-' "/proc/$pid/maps" 2>/dev/null || continue
		others=$((others + 1))
		n=$(grep -ohE 'libqq-[a-z-]+\.so' "/proc/$pid/maps" 2>/dev/null | sort -u | grep -c .)
		if [ "$n" -eq 4 ]; then
			others_ok=$((others_ok + 1))
		else
			check_pid "$pid" "QQ 子进程"
		fi
	done
	[ "$others" -gt 0 ] && ok "另外 $others 个 QQ 子进程：$others_ok 个四个库齐全（异常才逐条列出）"
fi

printf '\n'
if [ "$BLOCK" -eq 0 ]; then
	printf '没有阻塞性问题。\n'
	exit 0
fi
printf '有阻塞性问题，先修上面标「故障」的那几项。\n'
exit 1
