# wayland-cast-doctor

排查「Wayland 下桌面共享 / 截图 / 剪贴板不出画面」。**不绑定任何合成器** ——
niri、Hyprland、Sway、GNOME、KDE 都能跑。

只读状态，不重启任何东西，通话或共享进行中跑也安全：

```
wayland-cast-doctor
```

退出码 0 表示没有阻塞性问题，1 表示有。

输出上色：**绿=正常、无色=提示、黄=注意、红=故障**，只在终端上色（`[ -t 1 ]`），管道或
重定向时保持纯文本。脚本是 `#!/bin/sh`，取色用 `printf '\033[32m'` 而非 bash 的 `$'...'`。

## 共享链路要同时满足四件事

任意一件断了都不出画面，而症状都是「点了共享没反应」，只能逐项排除：

1. **客户端得走 portal。** QQ 不走 portal 就不会去要屏幕。
2. **portal 后端得提供 ScreenCast 接口。** `gtk` 后端根本不实现屏幕采集，首选里把
   `default` 设成 gtk，共享一定失败（改 `/usr/share/xdg-desktop-portal/portals.conf`）。
3. **合成器得真的宣告采集能力。** 这一步最容易坏、最难看出来：合成器采集功能可能写全了，
   但 portal 从 `org.gnome.Mutter.ScreenCast` 读到的 `AvailableSourceTypes` 是零，于是拒绝
   所有 `SelectSources`。**niri 原版就是这样**，所以 niri 用户需要
   [niri-portal-cast](https://github.com/ljm-233/niri-portal-cast)。
4. **PipeWire 得能协商出格式并真正出帧。**

再加一条不在链路上但极常见的原因：**有线和蓝牙输出同时在线**时，WirePlumber 换默认设备、
PipeWire 重建整个图，客户端手里的句柄全部失效 —— 点共享后崩掉或 300 毫秒内退出。**解法：只留一种输出。**

## 检查项

| 项 | 查什么 |
|---|---|
| 一 · 会话环境 | 是不是 Wayland，合成器是哪一个 |
| 二 · portal 后端 | 哪些后端在线，`introspect` 出谁真的提供 ScreenCast |
| 三 · 合成器能力宣告 | 直接问运行中的合成器宣告了哪些全局接口 |
| 四 · PipeWire 与音频图 | PipeWire 在不在，有线和蓝牙是否同时在线 |
| 五 · 内存与采集流 | Shmem 占用（超 4 GiB 报警），有没有活动采集流 |
| 六 · 客户端侧 | `linuxqq-wayland-fix` 注入检测，逐进程点名 |

第三项是**直接问合成器本人**，不是查 `/usr/share/wayland-protocols` 目录 —— 那个目录只证明
协议定义装了（任何装了 `wayland-protocols` 的机器都成立），跟合成器是否实现无关。具体看三个：

- `zwlr_screencopy_manager_v1` 或 `ext_image_copy_capture_manager_v1` —— 截图需要，缺了只能给黑图
- `zwlr_data_control_manager_v1` 或 `ext_data_control_manager_v1` —— 剪贴板桥接需要，缺了
  QQ 只读写 X11 剪贴板
- `zwlr_export_dmabuf_manager_v1` —— 有的话采集可以零拷贝，没有就只走 SHM 拷贝

### 第六项：注入检测

「装了 linuxqq-wayland-fix」和「它真的在生效」是两件事，这一项查后者：

- 遍历**所有** `qq` 进程，并单独标出**收帧的 `--type=ppapi` 进程** —— 它没被注入就等于没修，
  别的进程再漂亮也没用
- **逐库点名**：`libqq-wl-portal.so`（走 portal 选源）、`clipbridge`（剪贴板）、`screenshot`
  （截图）、`borderfix`（分享边框与提示条）缺哪个报哪个，不再只说「N 个库」
- 查 QQ 是不是从**修复版启动器**起来的：读 `cmdline` 和 `environ` 找 `linuxqq-wayland-fix`。
  「装了但正常启动」是最常见的坑 —— 必须完全退出 QQ（含托盘）再从「QQ（Wayland 修复版）」启动
- 报已安装的包版本、没装时给安装命令；其余子进程**汇总一行**，只有异常才逐条列出

## Hyprland 和 Sway 的区别（最容易被误诊的一项）

wlroots 系合成器的采集**不由合成器自己提供**，靠独立的 portal 后端，Arch 上有两个且不能互换：

| 后端 | 能选单个窗口 |
|---|---|
| `xdg-desktop-portal-wlr` | 否，只能整个输出 |
| `xdg-desktop-portal-hyprland` | **是** |

Hyprland 之所以 fork 一个，是因为 wlr 那个的窗口选择太受限。它的
`src/portals/Screencopy.cpp` 里宣告的能力位是：

```cpp
registerProperty("AvailableSourceTypes").withGetter([]() { return uint32_t{VIRTUAL | MONITOR | WINDOW}; }),
registerProperty("AvailableCursorModes").withGetter([]() { return uint32_t{HIDDEN | EMBEDDED}; }),
```

含 `WINDOW`，所以选得到窗口。**Sway / river / labwc / Wayfire 只有 wlr 后端可用，选单个窗口
做不到** —— 这是固有限制，不是配置问题，脚本照实**提示**而不是报故障。

反过来，**Hyprland 只装了 wlr 后端时共享仍然成功**，只是选择框里没有窗口条目，很容易被当成
「窗口共享有 bug」查错方向 —— 所以脚本把这种情况报成**故障**并给出安装命令。

## 相关的另外两个包

- **niri-portal-cast** —— niri 用户专用，补上能力宣告、帧率上限、采集分辨率上限（mutter 和
  wlroots 自己就有完整实现，别的合成器不需要）。它自带的 `niri-portal-doctor` 比这个脚本多知道
  两件事：`/usr/bin/niri` 是不是来自那个包、配置里的帧率有没有真的生效。**niri 用户先跑那个**，
  再跑这个，两者不冲突；内存一路涨的实测数据与两个可动的杠杆都在它的 README 里。
- **linuxqq-wayland-fix**（[SHORiN-KiWATA 的项目](https://github.com/SHORiN-KiWATA/linuxqq-wayland-fix)）——
  客户端那一半，让 QQ 去走 portal 选源。它自己也有 `--doctor`：那个偏「QQ 内部实现与注入状态」，
  这个偏「合成器与 portal 链路」，两边一起跑定位更准。第六项就是为它写的。

## 已知局限

- 只识别合成器类型并做**通用项**检查，**没有针对 Hyprland / Sway / GNOME / KDE 各自独有机制
  做专门检查**；能力探测依赖 `wayland-info`（`wayland-utils`），没有就跳过第三项并说明。
- 合成器识别靠 `XDG_CURRENT_DESKTOP` 子串匹配，这个值各家不统一：KDE 可能报 `KDE` 或
  `Plasma`，Ubuntu 上 GNOME 是 `ubuntu:GNOME`，Hyprland 有时是小写。
- 注入检测只对**本地安装**的 `linuxqq-wayland-fix` 有效；Flatpak 版路径不同，可能识别不到。
  它读的是 `/proc/<pid>/maps` 与 `environ`，只能看到自己有权限读的进程。
- 内存那一项只看 Shmem 总量，分不出是哪个进程在涨。要按进程归属（含 GPU 侧的 GEM、dmabuf）用
  `niri-portal-cast` 里的 `niri-shm-attrib`。

**如果你在别的桌面上发现它漏了什么，或者报错了，来提 issue。**

## 安装

Release 里是现成的包（`any`，与架构无关）：

```
sudo pacman -U wayland-cast-doctor-<版本>-any.pkg.tar.zst
```

或者从源码：

```
git clone https://github.com/ljm-233/wayland-cast-doctor
cd wayland-cast-doctor
makepkg -si
```

依赖 `wayland-utils`、`pipewire`、`wireplumber`、`dbus`；可选依赖 `niri-portal-cast` 与 `linuxqq-wayland-fix`（装了才查得出对应项）。

## 许可证

GPL-3.0-or-later。
