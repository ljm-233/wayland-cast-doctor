# wayland-cast-doctor

一个诊断脚本：**共享 / 截图 / 剪贴板不出画面，问题出在哪**。不绑定合成器（niri、Hyprland、
Sway、GNOME、KDE 都能跑），只读状态、不重启任何东西，**共享进行中跑也安全**。

```
wayland-cast-doctor
```

**退出码**：0 = 没有阻塞性问题，1 = 有。
**颜色**：绿=正常、无色=提示、黄=注意、红=故障；输出到管道或文件时自动不上色。

安装（release 里的包与架构无关）：

```
sudo pacman -U wayland-cast-doctor-<版本>-any.pkg.tar.zst
```

## 它检查什么

| 项 | 查什么 |
|---|---|
| 一 · 会话环境 | 是不是 Wayland，合成器是哪一个 |
| 二 · portal 后端 | 哪些后端在线、谁真的提供 ScreenCast（`gtk` 后端不提供，设成首选共享一定失败） |
| 三 · 合成器能力宣告 | 直接问运行中的合成器：截图、剪贴板、dmabuf 导出这三个协议在不在 |
| 四 · PipeWire 与音频图 | PipeWire 在不在；有线和蓝牙输出同时在线会重建音频图、客户端句柄失效 |
| 五 · 内存与采集流 | 有采集流时：**增长速率**（>100 MB/s 报故障、20–100 报注意）、**谁在占**（进程内 `Pss_Shmem` + GPU 侧 GEM，按 DRM client 去重）、流的基本信息；以及**内存刹车有没有在跑** |
| 六 · 客户端侧 | QQ 的 `linuxqq-wayland-fix` 注入检测；`--use-angle=vulkan` 会让视频画面缩成小图；设了独显变量却实际跑在核显 |

## 最常见的三种结果

- **只有 `xdg-desktop-portal-wlr`（Sway / river / labwc 等）**：只能整屏，**选不了单个窗口** ——
  固有限制，脚本报「提示」不是故障。Hyprland 装 `xdg-desktop-portal-hyprland` 才有窗口可选。
- **第六项报「故障」**：QQ 不是从修复版启动器起来的（最常见的坑），或者收帧进程没被注入。
  完全退出 QQ（含托盘），再从「QQ（Wayland 修复版）」启动。
- **第五项报「故障」（>100 MB/s）**：共享正在把内存吃光，几十秒就出事。先降档：
  `niri-portal-cast-tune saver`。注意 **i915 的 GEM 是 shmem 记账却不进任何进程的 `smaps`**，
  所以「进程 `Pss_Shmem` 很小、Shmem 却在涨」是正常的，别据此说没人在占 —— 脚本会把
  GPU 侧（`drm-total-system`）和进程内共享分开列出。

第六项具体做法：遍历**所有** `qq` 进程，单独标出**收帧的 `--type=ppapi`**，逐一点名缺哪个
`libqq-*.so`，并读 `cmdline` / `environ` 确认是不是从修复版启动器起来的。

## niri 用户

先跑 [niri-portal-cast](https://github.com/ljm-233/niri-portal-cast) 自带的 `niri-portal-doctor`
（它知道 niri 装了什么补丁、帧率有没有真的生效），再跑这个。两者不冲突。

## 已知限制

- 只做**通用项**检查，没有针对 Hyprland / Sway / GNOME / KDE 各自独有机制的专门检查；
  第三项依赖 `wayland-info`（`wayland-utils`），没装就跳过并说明。
- 合成器识别靠 `XDG_CURRENT_DESKTOP` 子串匹配，这个值各家不统一（KDE 可能报 `KDE` 或
  `Plasma`，Ubuntu 上的 GNOME 是 `ubuntu:GNOME`）。
- 注入检测只对**本地安装**的 `linuxqq-wayland-fix` 有效（Flatpak 版路径不同）；它读
  `/proc/<pid>/maps` 和 `environ`，只能看到有权限读的进程。
- 第五项的增长速率要**间隔 2 秒采两次样**，所以**只在检测到活动采集流时**才做（没流时不做，
  脚本仍是 1 秒出头跑完）。宽高 / 帧率只在 `pw-dump` 真给出时才打印，读不到就不打印。
- 「独显变量其实在核显上」这一项需要进程打开过 `/dev/dri/*` 才能判断；NVIDIA 设备打不开时
  （权限、驱动未加载）只能报核显那一侧。

## 许可证

GPL-3.0-or-later。
