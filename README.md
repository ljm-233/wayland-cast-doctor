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
| 五 · 内存与采集流 | Shmem 占用（> 4 GiB 报警）、当前有没有活动采集流 |
| 六 · 客户端侧 | QQ 的 `linuxqq-wayland-fix` 注入检测 |

## 最常见的三种结果

- **只有 `xdg-desktop-portal-wlr`（Sway / river / labwc 等）**：只能整屏，**选不了单个窗口** ——
  固有限制，脚本报「提示」不是故障。Hyprland 装 `xdg-desktop-portal-hyprland` 才有窗口可选。
- **第六项报「故障」**：QQ 不是从修复版启动器起来的（最常见的坑），或者收帧进程没被注入。
  完全退出 QQ（含托盘），再从「QQ（Wayland 修复版）」启动。
- **第五项只能告诉你 Shmem 总量**：分不出是哪个进程在涨。要按进程归属（含 GPU 侧的 GEM、
  dmabuf）用 [niri-portal-cast](https://github.com/ljm-233/niri-portal-cast) 里的 `niri-shm-attrib`。

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

## 许可证

GPL-3.0-or-later。
