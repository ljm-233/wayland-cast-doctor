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

ok()   { printf '  正常  %s\n' "$1"; }
info() { printf '  提示  %s\n' "$1"; }
warn() { printf '  注意  %s\n' "$1"; }
bad()  { printf '  故障  %s\n' "$1"; BLOCK=1; }

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
		printf '       gtk 后端不实现屏幕采集。如果首选里default 被设成 gtk，\n'
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
		ok "wlroots 系合成器，ScreenCast 由 wlr-portal 实现"
		;;
	*GNOME*|*gnome*)
		ok "mutter 自己实现 ScreenCast，能力宣告完整"
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
head_ "【六】客户端侧"

# The other half of the problem. A correct compositor is useless if QQ never
# asks it for anything, and that is what happens when QQ was not started from
# the fixed launcher.
if have pgrep; then
	QQPID=$(pgrep -x qq 2>/dev/null | head -1)
	if [ -n "$QQPID" ]; then
		# Do not look for libqq-wl-portal.so specifically. It is LD_PRELOADed
		# into QQ's main process but only dlopen()ed by the zygote child that
		# actually talks to the portal, so it legitimately does not appear in
		# the maps of whatever pgrep happens to return first. Any one of the
		# four is proof enough that the launcher ran.
		INJECTED=$(grep -oE 'libqq-(wl-portal|clipbridge|screenshot|borderfix)\.so' \
			"/proc/$QQPID/maps" 2>/dev/null | sort -u | wc -l)

		if [ "${INJECTED:-0}" -gt 0 ]; then
			ok "QQ（PID $QQPID）已注入 linuxqq-wayland-fix（$INJECTED 个库）"
			if [ "$INJECTED" -lt 4 ]; then
				info "只找到 $INJECTED/4 个，其余可能在 zygote 子进程里"
			fi
		elif grep -qs 'linuxqq-wayland-fix' "/proc/$QQPID/cmdline" 2>/dev/null; then
			ok "QQ（PID $QQPID）从修复版启动器启动"
		else
			warn "QQ（PID $QQPID）没有注入修复库"
			printf '       没注入的话 QQ 只读写 X11 剪贴板，共享走自己的老实现。\n'
			printf '       完全退出 QQ（含托盘）后从「QQ（Wayland修复版）」启动。\n'
		fi
	else
		info "QQ 没在运行"
	fi
fi

# ---------------------------------------------------------------------------
printf '\n'
if [ "$BLOCK" -eq 0 ]; then
	printf '没有阻塞性问题。\n'
	exit 0
fi
printf '有阻塞性问题，先修上面标「故障」的那几项。\n'
exit 1
