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

# 在线音频输出计数：用 wpctl inspect 逐个判定，避免 wpctl status 的两个坑 ——
#   ① Settings 里列的是 WirePlumber「记住的」默认设备，设备不在线也会出现；
#   ② 在线 sink 在 wpctl status 里只显示描述文字，不是 node.name。
# 输出：<有线数> <蓝牙数> <蓝牙档位>
audio_outputs() {
	_ao_wired=0; _ao_bt=0; _ao_prof=""
	_ao_ids=$(wpctl status 2>/dev/null | grep -oE '^[^0-9]*[0-9]+\.' | grep -oE '[0-9]+')
	for _ao_id in $_ao_ids; do
		_ao_info=$(wpctl inspect "$_ao_id" 2>/dev/null) || continue
		case "$_ao_info" in
			*'media.class = "Audio/Sink"'*) ;;
			*) continue ;;
		esac
		case "$_ao_info" in
			*'node.name = "alsa_output.'*) _ao_wired=$((_ao_wired + 1)) ;;
			*'node.name = "bluez_output.'*)
				_ao_bt=$((_ao_bt + 1))
				if [ -z "$_ao_prof" ]; then
					_ao_prof=$(printf '%s\n' "$_ao_info" | grep 'api.bluez5.profile' | head -1 | sed 's/.*= *//; s/"//g')
				fi
				;;
		esac
	done
	printf '%s %s %s\n' "$_ao_wired" "$_ao_bt" "$_ao_prof"
}

head_() { printf '\n%s\n' "$1"; }

# ---- 下面几项检查共用的读取助手 -------------------------------------------

# /proc/meminfo 的 Shmem（普通共享内存 + GPU 侧 system 记账的总和），单位 KiB
shmem_kib() { awk '/^Shmem:/{print $2+0; exit}' /proc/meminfo 2>/dev/null; }

# 一个进程的共享内存占用，单位 KiB。
# 注意：smaps_rollup 里没有裸的 "Shmem:" 字段，共享部分是 Pss_Shmem。
pss_shmem() {  # $1=pid
	v=$(awk '/^Pss_Shmem:/{print $2+0; exit}' "/proc/$1/smaps_rollup" 2>/dev/null)
	printf '%s' "${v:-0}"
}

# 一个进程的 DRM/i915 "system" 对象总量，单位 KiB。
# 同一个 DRM client 会通过多个复制出来的 fd 重复出现（drm-client-id 相同），
# 必须按 client 去重，否则同一块内存会被算好几遍。
drm_sys_kib() {  # $1=pid
	for f in /proc/$1/fdinfo/*; do
		[ -r "$f" ] || continue
		awk '/^drm-client-id:/{id=$2}
		     /^drm-total-system/{if (id != "") print id, $2+0}' "$f" 2>/dev/null
	done | awk '{ if ($2 > m[$1]) m[$1] = $2 } END { s=0; for (i in m) s += m[i]; printf "%d", s+0 }'
}

# 扫一遍所有进程，找出「进程内共享内存 + GPU 侧」最多的那个。
# 只在真的有采集流时调用：这一步要读几百个 /proc 条目，平时不该拖慢脚本。
scan_top() {
	top_res=0; top_pid=""; top_name="?"; top_pss=0; top_gem=0
	for d in /proc/[0-9]*; do
		p=${d#/proc/}
		[ -r "$d/smaps_rollup" ] || continue
		pss=$(pss_shmem "$p")
		gem=0
		# 只有真的打开过 /dev/dri 的进程才可能持有 GPU 对象，先便宜地筛一遍
		for f in "$d"/fd/*; do
			case "$(readlink "$f" 2>/dev/null)" in
				/dev/dri/*) gem=$(drm_sys_kib "$p"); break ;;
			esac
		done
		res=$((pss + gem))
		if [ "$res" -gt "$top_res" ]; then
			top_res=$res; top_pid=$p; top_pss=$pss; top_gem=$gem
			top_name=$(cat "$d/comm" 2>/dev/null)
			[ -n "$top_name" ] || top_name="?"
		fi
	done
}

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

	ao=$(audio_outputs)
	WIRED=$(printf '%s\n' "$ao" | awk '{print $1+0}')
	BT=$(printf '%s\n' "$ao" | awk '{print $2+0}')
	BT_PROF=$(printf '%s\n' "$ao" | awk '{print $3}')

	if [ "$WIRED" -gt 0 ] && [ "$BT" -gt 0 ]; then
		warn "有线和蓝牙音频输出同时在线"
		printf '       WirePlumber 会在两者之间换默认设备，PipeWire 重建整个图，\n'
		printf '       客户端手里的句柄全部失效。表现是选择框弹出、点共享、然后\n'
		printf '       崩掉或者 300 毫秒内退出。解法：只留一种输出。\n'
	elif [ "$WIRED" -eq 0 ] && [ "$BT" -eq 0 ]; then
		warn "没有任何在线音频输出"
		printf '       接上输出设备再跑一次，这条判断才有意义。\n'
	elif [ "$BT" -gt 0 ] && [ -n "$BT_PROF" ]; then
		case "$BT_PROF" in
			*headset*|*hfp*)
				warn "蓝牙输出在通话档（$BT_PROF）"
				printf '       通话/用麦会让蓝牙切档，PipeWire 一样会重建图：共享会突然\n'
				printf '       无画面、通话可能挂不断。解法：通话时别用耳机麦，或只留 a2dp。\n' ;;
			*)
				ok "只有一种音频输出（有线=$WIRED 蓝牙=$BT 蓝牙档位=$BT_PROF）" ;;
		esac
	else
		ok "只有一种音频输出（有线=$WIRED 蓝牙=$BT）"
	fi
fi

# ---------------------------------------------------------------------------
head_ "【五】内存与采集流"

if [ -r /proc/meminfo ]; then
	shmem_gib=$(awk '/^Shmem:/{printf "%.2f", $2/1048576}' /proc/meminfo)
	if [ -n "$shmem_gib" ] && awk "BEGIN{exit !($shmem_gib > 4)}"; then
		warn "Shmem ${shmem_gib} GiB（偏高）"
		printf '       共享时偏高通常意味着帧生产快过客户端消费。niri 用户用\n'
		printf '       screencasting 块限帧率/分辨率；限制值是每次开始共享时读的\n'
		printf '       （niri-portal-cast -10 起），改完重开一次共享即生效。\n'
	else
		ok "Shmem ${shmem_gib} GiB"
	fi
fi

# 有没有活动的采集流。结构化信息用 pw-dump；没有 jq 时退回 wpctl 的粗略判断。
STREAM_LINE=""
STREAM_FMT=""
if have pw-dump && have jq; then
	PWDUMP=$(pw-dump 2>/dev/null)
	STREAM_LINE=$(printf '%s' "$PWDUMP" | jq -r '
		[.[] | select(.info.props["media.class"] == "Stream/Output/Video")] | .[0] |
		if . == null then "" else
			[(.id | tostring),
			 (.info.props["application.name"] // .info.props["application.process.binary"] // "?"),
			 (.info.props["node.name"] // "?")] | @tsv
		end' 2>/dev/null)
	# 宽高 / 帧率只在真的读到时才打印；读不到宁可少一行，也不要猜
	STREAM_FMT=$(printf '%s' "$PWDUMP" | jq -r '
		[.[] | select(.info.props["media.class"] == "Stream/Output/Video")] | .[0] |
		if . == null then "" else
			((.info.params // []) | map(.Format // empty) | map(select(type == "object")) | .[0] // {}) as $f |
			[($f.video.width // $f["video.width"] // .info.props["video.width"] // empty),
			 ($f.video.height // $f["video.height"] // .info.props["video.height"] // empty),
			 ($f.video.framerate // $f["video.framerate"] // .info.props["video.framerate"] // empty)]
			| map(select(. != null and . != "")) | map(tostring) | join(" ")
		end' 2>/dev/null)
fi
# pw-dump/jq 缺失、或 jq 存在但没给出结果时，退回 wpctl 的粗略判断（只知道有没有流）
if [ -z "$STREAM_LINE" ] && have wpctl; then
	wpctl status 2>/dev/null | grep -qiE 'screencast|record' && STREAM_LINE="?	?	?"
fi

if [ -n "$STREAM_LINE" ]; then
	ok "有活动的采集流：id=$(printf '%s' "$STREAM_LINE" | cut -f1)  应用=$(printf '%s' "$STREAM_LINE" | cut -f2)  节点=$(printf '%s' "$STREAM_LINE" | cut -f3)${STREAM_FMT:+  格式=$STREAM_FMT}"

	# 间隔 2 秒采两次，算共享内存的增长速率
	s1=$(shmem_kib)
	sleep 2
	s2=$(shmem_kib)
	rate=$(( (s2 - s1) / 2048 ))    # KiB / 2 秒 → MiB/s
	[ "$rate" -lt 0 ] && rate=0

	scan_top
	if [ -n "$top_pid" ]; then
		info "占用最多：$top_name (PID $top_pid)  进程内共享 $((top_pss / 1024)) MiB + GPU 侧 $((top_gem / 1024)) MiB"
	fi

	if [ "$rate" -gt 100 ]; then
		bad "共享内存正以 ${rate} MB/s 增长，几十秒就会吃光内存"
		printf '       先降档：niri-portal-cast-tune saver   （15fps + 960×600）\n'
	elif [ "$rate" -ge 20 ]; then
		warn "共享内存以 ${rate} MB/s 增长，几分钟后会被刹车掐断（不会冻机）"
		printf '       降一档：niri-portal-cast-tune saver 或 fps 15\n'
	else
		ok "共享内存稳定（2 秒内约 ${rate} MB/s）"
	fi
	if [ "$rate" -ge 20 ]; then
		printf '       判据：i915 的 GEM 是 shmem 记账的，但不进任何进程的 smaps，\n'
		printf '       所以「进程 Pss_Shmem 很小、Shmem 却在涨」是正常的，\n'
		printf '       别据此下「没人在占内存」的结论。\n'
	fi
else
	info "当前没有采集流，共享时再跑一次（那时才能测增长速率与归属）"
fi

# 内存刹车：niri-portal-cast 带的 niri-shm-attrib，超阈值自动掐掉采集流
if have pacman && pacman -Q niri-portal-cast >/dev/null 2>&1; then
	if pgrep -f 'niri-shm-attrib' >/dev/null 2>&1; then
		ok "内存刹车在运行（内存失控时自动掐流，不会冻机）"
	else
		warn "没有刹车在跑：共享内存失控时会一路吃光内存"
		printf '       启用：systemctl --user enable --now niri-shm-attrib\n'
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

	# --use-angle=vulkan 会让**接收**视频的画面缩成小图（内容靠左上、四周黑）。
	# 实测 2026-10-03：加 QQ_WAYLAND_FIX_ANGLE=off 启动即恢复正常。
	main_qq=$(printf '%s\n' "$qqpids" | head -1)
	angle_vk=0
	for pid in $qqpids; do
		case "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" in
			*--use-angle=vulkan*) angle_vk=1 ;;
		esac
	done
	angle_off=0
	tr '\0' '\n' < "/proc/$main_qq/environ" 2>/dev/null |
		grep -qx 'QQ_WAYLAND_FIX_ANGLE=off' && angle_off=1
	if [ "$angle_vk" -eq 1 ] && [ "$angle_off" -eq 1 ]; then
		ok "已关闭 ANGLE/Vulkan（--use-angle=vulkan 会让视频画面缩成小图）"
	elif [ "$angle_vk" -eq 1 ]; then
		warn "QQ 带着 --use-angle=vulkan：接收视频的画面会缩成小图（内容靠左上、四周黑）"
		printf '       解决：完全退出 QQ，用 QQ_WAYLAND_FIX_ANGLE=off linuxqq-wayland-fix 启动（实测 2026-10-03）\n'
	fi

	# 以为在用独显、其实在核显：启动脚本设了 PRIME 变量，但进程只打开了 i915。
	# 实测 2026-10-03：__NV_PRIME_RENDER_OFFLOAD=1 对 Electron/ANGLE 常常无效，
	# nvidia-smi 只用了 13 MiB，而进程里只有 /dev/dri/renderD128（i915）。
	prime_set=0; has_nv=0; has_intel=0
	for pid in $qqpids; do
		tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null |
			grep -qE '^(__NV_PRIME_RENDER_OFFLOAD|DRI_PRIME|__GLX_VENDOR_LIBRARY_NAME)=' && prime_set=1
		for f in /proc/$pid/fd/*; do
			case "$(readlink "$f" 2>/dev/null)" in
				/dev/dri/*) : ;;
				*) continue ;;
			esac
			case "$(awk '/^drm-driver:/{print $2; exit}' "/proc/$pid/fdinfo/$(basename "$f")" 2>/dev/null)" in
				nvidia*) has_nv=1 ;;
				i915|xe) has_intel=1 ;;
			esac
		done
	done
	if [ "$prime_set" -eq 1 ] && [ "$has_nv" -eq 1 ]; then
		ok "独显环境变量已设置，进程也确实打开了 NVIDIA 设备"
	elif [ "$prime_set" -eq 1 ] && [ "$has_intel" -eq 1 ]; then
		warn "设了独显环境变量，但实际只打开了核显（i915）"
		printf '       这些变量对 Electron/ANGLE 常常不生效。渲染在核显上意味着\n'
		printf '       共享占用会记进系统内存（Shmem）而不是显存，等于没绕开。\n'
	fi
fi

printf '\n'
if [ "$BLOCK" -eq 0 ]; then
	printf '没有阻塞性问题。\n'
	exit 0
fi
printf '有阻塞性问题，先修上面标「故障」的那几项。\n'
exit 1
