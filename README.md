# wayland-cast-doctor

排查「Wayland 下桌面共享 / 截图 / 剪贴板不出画面」。**不绑定任何合成器**，
niri、Hyprland、Sway、GNOME、KDE 都能跑。

只读状态，不重启任何东西，通话或共享进行中跑也安全。

```
wayland-cast-doctor
```

退出码 0 表示没有阻塞性问题，1 表示有。

## 共享链路要同时满足四件事

任意一件断了都不出画面，而且症状都是「点了共享没反应」，只能逐项排除：

1. **客户端得走 portal。** QQ 不走 portal 就不会去要屏幕。
2. **portal 后端得提供 ScreenCast 接口。** `gtk` 后端根本不实现屏幕采集，
   首选里如果把 `default` 设成 gtk，共享一定失败。
3. **合成器得真的宣告采集能力。** 这一步最容易坏而且最难看出来——
   合成器可能采集功能写全了，但 portal 从 `org.gnome.Mutter.ScreenCast`
   上读到的 `AvailableSourceTypes` 是零，于是拒绝所有 `SelectSources`。
   **niri 就是这样**，所以 niri 用户需要
   [niri-portal-cast](https://github.com/ljm-233/niri-portal-cast)。
4. **PipeWire 得能协商出格式并真正出帧。**

再加一条不在链路上但极常见的原因：**有线和蓝牙音频输出同时在线**时，
WirePlumber 换默认设备、PipeWire 重建整个图，客户端手里的句柄全部失效。
表现是选择框弹出、点共享、然后崩掉或者 300 毫秒内退出。

## 检查项

| 项 | 查什么 |
|---|---|
| 一 · 会话环境 | 是不是 Wayland，合成器是哪一个 |
| 二 · portal 后端 | 哪些后端在线，谁提供 ScreenCast |
| 三 · 能力宣告 | 直接问合成器宣告了哪些全局接口 |
| 四 · PipeWire 与音频图 | PipeWire 在不在，两种输出是否同时在线 |
| 五 · 内存与采集流 | Shmem 占用，有没有活动采集流 |
| 六 · 客户端侧 | QQ 有没有注入 `linuxqq-wayland-fix` |

第三项是直接问合成器本人，不是查 `/usr/share/wayland-protocols` 目录。
那个目录只证明协议定义装了，在任何装了 `wayland-protocols` 的机器上都成立，
跟合成器是否实现无关。`wayland-info` 连的是运行中的合成器，读它真实的全局列表。

具体查三个：

- `zwlr_screencopy_manager_v1` 或 `ext_image_copy_capture_manager_v1` ——
  QQ 截图需要，缺了只能给黑图
- `zwlr_data_control_manager_v1` 或 `ext_data_control_manager_v1` ——
  剪贴板桥接需要，缺了 QQ 只读写 X11 剪贴板
- `zwlr_export_dmabuf_manager_v1` —— 有的话采集可以零拷贝，没有就只走 SHM 拷贝

## Hyprland 和 Sway 的区别（这一项最容易被误诊）

wlroots 系合成器的采集**不由合成器自己提供**，靠的是一个独立的 portal 后端。
Arch 上有两个，不能互换：

| 后端 | 能选单个窗口 |
|---|---|
| `xdg-desktop-portal-wlr` | 否，只能整个输出 |
| `xdg-desktop-portal-hyprland` | **是** |

Hyprland 之所以要 fork 一个，是因为 wlr 那个的窗口选择太受限。它的
`src/portals/Screencopy.cpp` 里宣告的能力位是：

```cpp
registerProperty("AvailableSourceTypes").withGetter([]() { return uint32_t{VIRTUAL | MONITOR | WINDOW}; }),
registerProperty("AvailableCursorModes").withGetter([]() { return uint32_t{HIDDEN | EMBEDDED}; }),
```

含 `WINDOW`，所以选得到窗口。**Sway 和 river 只有 wlr 后端可用，选单个窗口做不到**，
这不是配置问题，脚本会照实提示而不是报故障。

Hyprland 只装了 wlr 后端时，共享**仍然成功**，只是选择框里没有窗口条目——客户端
不会给任何提示，很容易被当成「窗口共享有 bug」去查错方向。脚本把这种情况报成
故障，因为对「我要共享某个窗口」这个需求来说它就是没达到。

## 相关的另外两个包

- **niri-portal-cast** —— niri 用户专用，补上能力宣告和帧率上限。别的合成器
  不需要，mutter 和 wlroots 自己就有完整的 ScreenCast 实现。它自带一个
  `niri-portal-doctor`，比这个脚本多知道两件事：`/usr/bin/niri` 是不是来自那个包，
  以及配置里的帧率上限是多少。**niri 用户先跑那个，再跑这个。**
- **linuxqq-wayland-fix**（[SHORiN-KiWATA 的项目](https://github.com/SHORiN-KiWATA/linuxqq-wayland-fix)）——
  客户端那一半。它自己也有 `--doctor`，两边一起跑能定位得更准：
  它的检查偏「QQ 内部实现和注入状态」，这个偏「合成器和 portal 链路」。

## 已知局限

- 只能识别合成器类型并检查通用项，**没有针对 Hyprland / Sway / GNOME / KDE
  各自的独有机制做专门检查**。
- 合成器类型的识别靠 `XDG_CURRENT_DESKTOP` 子串匹配。这个值各家不统一，
  KDE 会报 `KDE` 或 `Plasma`，Ubuntu 上 GNOME 是 `ubuntu:GNOME`。
- QQ 注入检测逐进程读 `/proc/PID/maps`、`/proc/PID/environ` 和 `cmdline`，覆盖**所有**
  `qq` 进程（重点看收帧的 `--type=ppapi`），并单独报告 `libqq-wl-portal/clipbridge/
  screenshot/borderfix` 四个库各缺哪个、以及是不是从修复版启动器起来的。只对本地安装的
  `linuxqq-wayland-fix` 有效；Flatpak 版路径不同，可能识别不到。

**如果你在别的桌面上发现它漏了什么，或者报错了，来提issue。**

## 安装

```
sudo pacman -U wayland-cast-doctor-2026.10.3-2-any.pkg.tar.zst
```

或者从源码：

```
git clone https://github.com/ljm-233/wayland-cast-doctor
cd wayland-cast-doctor
makepkg -si
```

## 许可证

GPL-3.0-or-later。
