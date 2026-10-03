# 野火 LubanCat-5（RK3588）FnNAS 适配说明

## 1. 当前结论

本适配面向普通版 LubanCat-5 V1，复用 FnNAS 的 Rockchip `6.18.18` 内核四件套，不下载野火完整 SDK，也不以野火 BSP 内核替换 FnNAS 内核。型号代号为 `lubancat-5`，设置为 `BUILD=no`，只支持显式执行 `-b lubancat-5`；未经验证的 V2 不注册。

最终候选镜像已在 V1 eMMC 上完成断电冷启动、重启、fnOS 初始化和官方 Web OTA 回归。以下“通过”仅表示表中写明的验证范围，不代表所有接口、所有负载或长期稳定性均已验证。

| 项目 | 当前结论 | 验证边界 |
| --- | --- | --- |
| Rockchip 启动链 | 通过 | `RKNS` IDB 位于 LBA 64，U-Boot FIT 位于 LBA 16384；eMMC 断电冷启动及重启通过 |
| BOOTFS / ROOTFS | 通过 | GPT、ext4 `BOOT`、Btrfs `ROOTFS`、内核、initramfs、DTB 和模块目录通过离线检查 |
| eMMC / TF | 通过 | eMMC 运行系统；TF 卡可作为外接设备或存储空间使用 |
| 双千兆网口 | 基础功能通过 | 两个 GMAC 均绑定；第二网口完成 1 Gbit/s 全双工链路和网络访问，未做双口并发压力测试 |
| M.2 M-Key NVMe | 通过 | 2 TB NVMe SSD 以 PCIe 8.0 GT/s x4 工作，fnOS 存储池、重启恢复和文件读写通过 |
| USB | 仅基础枚举 | 六组 root hub 和板载 Hub 可枚举，未覆盖所有端口和外设类型 |
| PWM 风扇 | 基础功能通过 | 档位、thermal governor 和最终 DTB 的自动起转路径通过；未做长期温控压力测试 |
| ES8388 音频 | 耳机输出通过 | 外接耳机播放通过；麦克风输入未验证，板卡没有板载扬声器或可直接拾音的板载麦克风 |
| HDMI | 驱动枚举通过 | 两个 DRM connector 和 HDMI 声卡已注册，未验证实际显示器图像与 HDMI 音频 |
| USB Type-C | 驱动枚举通过 | FUSB302、TCPM、port/partner、role/orientation 注册；DP Alt Mode 未实现 |
| RKMPP / RGA | 通过 | 命令行编码、解码、缩放，以及 fnOS 影视“非原画”服务端转码通过 |
| RKNPU | 应用路径通过 | 官方 RK3588 AI 引擎加载 RKNN 人脸检测/识别模型，并在一套测试图中完成人物聚类 |
| Mali CSF GPU | 仅内核侧通过 | 驱动、OPP/devfreq 和 `/dev/mali0` 正常；缺少配套用户态栈，未验证真实 3D/OpenCL/Vulkan 负载 |
| 官方 OTA | 单次回归通过 | 从 `6.18.18-trim #491` 更新到 `6.18.18.c1090-trim #1090`，重启和已测硬件功能正常 |
| V2 / 摄像头 / Mini-PCIe / M.2 E-Key | 未验证 | 不登记 V2；这些接口不标记为可用 |

本适配不修改 GitHub Actions 发布工作流，也不会自动写入实体磁盘、TF 卡、eMMC、SPI 或 NVMe。构建和校验脚本只生成或读取普通镜像文件；介质烧录必须由使用者另外执行并人工确认目标设备。

## 2. 仓库职责与文件布局

适配按上游现有职责分到四个同级仓库：

```text
fnnas/
  board/lubancat-5/
    ota/
  docs/lubancat-5.md
  make-fnnas/fnnas-files/common-files/etc/model_database.conf

linux-6.18.y/
  arch/arm64/boot/dts/rockchip/rk3588-lubancat-5.dts
  arch/arm64/boot/dts/rockchip/rk3588s-{ip,ip-supply,vpu,gpu,npu,crypto}.dtsi
  arch/arm64/boot/dts/rockchip/Makefile
  Documentation/devicetree/bindings/arm/rockchip.yaml

amlogic-s9xxx-armbian/
  build-armbian/armbian-files/different-files/lubancat-5/bootfs/
    armbianEnv.txt
    boot.cmd
    boot.scr
  build-armbian/armbian-files/platform-files/rockchip/bootfs/dtb/rockchip/
    rk3588-lubancat-5.dtb

u-boot/
  u-boot/rockchip/lubancat-5/
    rk3588_spl_loader_v1.18.113.bin
    idbloader.img
    uboot.img
```

FnNAS 仓库保存型号注册、固定来源、构建和校验入口；Linux 仓库保存单文件 V1 板级 DTS和可复用的 Rockchip IP DTSI；`amlogic-s9xxx-armbian` 保存板卡启动配置和过渡 DTB；U-Boot 资源仓库保存实际引导文件。完整 SDK、基础镜像、输出镜像、缓存和临时日志都不应提交。

通用 `renas` 流程和公共 `.gitignore` 不因本板适配而修改。构建主机应提供当前 `renas` 所需的 GNU coreutils 行为；发行版兼容问题应在构建环境中解决，不把本机专用包装器提交到上游公共流程。

## 3. 型号注册与内核约束

`model_database.conf` 中的 V1 记录为：

```text
ID=r128
BOARD=lubancat-5
FAMILY=rk3588
PLATFORM=rockchip
FDTFILE=rk3588-lubancat-5.dtb
UBOOT_OVERLOAD=NA
MAINLINE_UBOOT=uboot.img
BOOTLOADER_IMG=idbloader.img
KERNEL_TAGS=rockchip/6.18.y
BUILD=no
```

`KERNEL_TAGS=rockchip/6.18.y` 允许 `renas` 选择 FnNAS 发布的 `6.18.*-rockchip` 内核包，与仓库其他板卡使用的系列选择机制一致；没有设置为 `rockchip/all`，因为后者还会包含未经适配的 6.12 系列。该字段只定义可选内核系列，不是把 Linux 内核编进 DTS，也不表示所有未来 6.18.x 都已经过实机验证。

当前过渡 DTB 的可复现编译基线和完整实机验证版本仍是 `6.18.18`。使用新的 6.18.x 内核包时，必须重新执行 DTB 结构检查、离线镜像校验和实机启动/驱动回归；如果基础树节点或专用模块绑定发生变化，还需要针对对应内核源码重新编译或调整 DTB，不能只沿用旧二进制并宣称兼容。

已检查 `6.18.18-rockchip` 内核包。其 `boot`、`dtb`、`header`、`modules` 四个压缩包均通过发布的 `sha256sums`；DTB 包含 LubanCat-1/2/3/4，但不包含 `rk3588-lubancat-5.dtb` 或 `rk3588-lubancat-5-v2.dtb`，所以本适配需要提供同版本过渡 DTB。

## 4. 固定源码与来源

所有固定版本均记录在 `board/lubancat-5/sources.env`：

| 用途 | 来源 | 固定 commit |
| --- | --- | --- |
| FnNAS 6.18.18 编译基线 | [unifreq/linux-6.18.y](https://github.com/unifreq/linux-6.18.y) | `d601855da0c1130fe17d8f2d8c86eea407ff9492` |
| Rockchip 公共 IP DTSI | [ophub/linux-6.18.y](https://github.com/ophub/linux-6.18.y) | `6bff5ea09ee9a3dd26f86a999ed272e2da5c6ad8` |
| 主线 LubanCat-5 BTB DTSI | [linux-rockchip](https://git.kernel.org/pub/scm/linux/kernel/git/mmind/linux-rockchip.git) | `23d8f49fcae5d72b77744c7f349c12462c3bb748` |
| 野火 V1 BSP DTS 参考 | [LubanCat/kernel](https://github.com/LubanCat/kernel/tree/lbc-develop-6.1) | `1bc19c520831b6d0ca7d7afb4639189a2064e9bc` |
| 野火 U-Boot | [LubanCat/u-boot](https://github.com/LubanCat/u-boot) | `ce67cf027de25347c5c790c3087f6e663f4f3d56` |
| 野火 rkbin | [LubanCat/rkbin](https://github.com/LubanCat/rkbin) | `58a39b47f77a26a1e110fa1a1ce80bcfcb0b3505` |

U-Boot 使用野火 `lubancat-5-rk3588-pcie_defconfig`。rkbin 输入固定为：

| 组件 | 文件 | SHA-256 |
| --- | --- | --- |
| DDR | `rk3588_ddr_lp4_1848MHz_lp5_2400MHz_v1.18.bin` | `96e7b795f6ae09dcda6df848bafe7b8a524d32869b5de136c5d2fb4762a16517` |
| SPL | `rk3588_spl_v1.13.bin` | `2134bffc64b9a9434fbeeb6bbbbc8218bd8933ee7765fc7a05be5603d8437480` |
| BL31 | `rk3588_bl31_v1.48.elf` | `ff717807d873ce95e5463ac29e0b5f081f8c5956d57f40376a1a3fe0fb93accf` |
| BL32 / OP-TEE | `rk3588_bl32_v1.19.bin` | `3e0a1f56edf8afcb5a92d2a06401afa88181b97ee185cecbf28cf63c9ba4ffce` |

校验参考文件来源及合并到 V1 DTS中的 BTB回移片段：

```bash
./board/lubancat-5/verify-dts-origin.sh
```

该命令需要网络；它会重新下载固定 commit 的参考文件、校验摘要，再比较可审查的转换结果。

直接审查入口：

- [野火 V1 `rk3588-lubancat-5.dts`](https://github.com/LubanCat/kernel/blob/1bc19c520831b6d0ca7d7afb4639189a2064e9bc/arch/arm64/boot/dts/rockchip/rk3588-lubancat-5.dts)
- [野火 `lubancat-5-rk3588-pcie_defconfig`](https://github.com/LubanCat/u-boot/blob/ce67cf027de25347c5c790c3087f6e663f4f3d56/configs/lubancat-5-rk3588-pcie_defconfig)
- [主线 `rk3588-lubancat-5-btb.dtsi`](https://git.kernel.org/pub/scm/linux/kernel/git/mmind/linux-rockchip.git/plain/arch/arm64/boot/dts/rockchip/rk3588-lubancat-5-btb.dtsi?id=23d8f49fcae5d72b77744c7f349c12462c3bb748)

## 5. 设备树移植设计

### 5.1 为什么不能直接使用 BSP DTB

野火 6.1 BSP DTS 依赖 `rk3588-linux.dtsi`、供应商音频卡、摄像头图、红外遥控、私有 PHY/PCIe/温控属性及不同的控制器节点命名。FnNAS `6.18.18` 使用另一套基础 DTS 和驱动绑定。把 BSP DTB 政名为 `rk3588-lubancat-5.dtb` 不能使这些绑定自动兼容，反而可能造成供电、MMC、PCIe、USB 或多媒体驱动无法探测。

当前实现采用“单文件 V1 板级 DTS + 范围受控的 Rockchip 专用 IP层”：

1. `rk3588-lubancat-5.dts` 直接描述普通 V1。其带有来源标记的内联段基于主线 BTB文件，描述 RK806、CPU/GPU/NPU供电和 eMMC；其余部分描述 TF、双网口、USB、三组 PCIe、HDMI、Type-C、ES8388、UART、LED和风扇。
2. `rk3588s-ip.dtsi` 及 supply/VPU/GPU/NPU/crypto 子文件用于匹配 FnNAS 内核四件套内的 Rockchip MPP、RGA、RKNPU 和 Mali CSF 模块；它不是野火完整 `rk3588-linux.dtsi`。

### 5.2 内联 BTB 回移片段的可审查修改

为与仓库中 LubanCat-1/2/3/4的单文件板级描述保持一致，V1不再保存一份改名含义容易与 5IO混淆的 `rk3588-lubancat-5-btb.dtsi`。固定主线参考的主体被原位合并到 `rk3588-lubancat-5.dts`，并由 `BEGIN/END LUBANCAT-5 V1 BTB BACKPORT` 标记限定。相对固定的主线 `rk3588-lubancat-5-btb.dtsi`，该内联片段只有五类实质修改：

1. 删除公共文件里的板卡 `compatible`，由顶层 V1 DTS 提供；
2. 删除目标 `6.18.18` 树中不存在的 CAN1/CAN2 assigned-clock 覆盖；
3. 将面向 5IO/BTB 底板的 `vcc4v0_sys` 输入改为普通 LubanCat-5 V1 实际使用的 `vcc5v0_sys`。
4. 删除与公共 `rk3588s-npu.dtsi` 驱动模型冲突的三组上游 NPU core/IOMMU启用片段，由 FnNAS匹配的 RKNPU公共层统一描述；
5. 为 GPU和 VENC的同一实体稳压器补充 memory-supply别名，供 `rk3588s-ip-supply.dtsi`引用。

`verify-dts-origin.sh` 会机械重建这五项转换，从合并后的 DTS中抽取标记区间并进行 `diff`，避免二进制 DTB成为唯一来源。未来适配 5IO时可以直接引入主线原名的 `rk3588-lubancat-5-btb.dtsi` 和独立的 `rk3588-lubancat-5io.dts`，不会与当前 V1源码发生同名冲突。

### 5.3 主 DTS 的主要绑定转换

| 硬件 | BSP 参考 | 当前实现 |
| --- | --- | --- |
| 双 GMAC | 私有 PHY reset/LED 属性 | 标准 C22 PHY、`reset-gpios`、标准 reset 时间和 `rgmii-rxid` |
| 三组 PCIe | BSP `disable-gpios` 等属性 | 标准 reset、3.3 V supply 和 PCIe lane 描述 |
| ES8388 | `rockchip,multicodecs-card` | `simple-audio-card` + `simple-audio-amplifier`，SoC I2S 提供 BCLK/LRCLK |
| HDMI | BSP 图和私有 GPIO 语义 | 标准 connector/VOP/HDMI codec 图；修复 HDMI1 DDC 与 Type-C VBUS 的引脚冲突 |
| Type-C | BSP DP/mux 扩展 | FUSB302/TCPM、USB role switch 和 orientation switch；暂不接 DP Alt Mode |
| USB | BSP 旧节点名 | 目标内核的 XHCI/EHCI/OHCI 与 PHY 节点 |
| 风扇 | BSP 私有温控属性 | 标准 `pwm-fan` 和 thermal cooling-map |
| 加速器 | 板级强制启用 BSP 节点 | 复用仓库公共 RK3588 IP 层，并按本内核模块兼容表校验 |

公共 IP 层与锁定基础树同时存在时曾产生重复 RKVDEC SRAM 描述。最终 DTS 删除公共层新增的重复 SRAM 子池，让 RKVDEC 复用基础树的 `vdec0_sram`/`vdec1_sram`；当前模块不支持的 `rockchip,rk3588-crypto` 被禁用，可工作的 RNG 保留。VENC1 IOMMU 的 `lock-names` 拼写也在板级 DTS 覆盖为 `clock-names`。

以下 BSP 功能有意不标记为已支持：

- RKCIF/RKISP 摄像头图及多种互斥传感器；
- MIPI DSI/eDP 外接屏、背光和面板供电；
- HDMI RX 及其 256 MiB CMA 预留；
- Type-C DisplayPort Alt Mode；
- `rockchip,remotectl-pwm` 红外遥控；
- 耳机线控按键；
- Mini-PCIe 和 M.2 E-Key 的实体设备功能。

### 5.4 最终 DTB 的结构检查

`build-dtbs.sh` 不只检查文件名。它会验证 model/compatible、双 GMAC、eMMC/TF、三组 PCIe、USB/Type-C、ES8388、双 HDMI、PWM4、风扇 thermal map、MPP/RGA/RKNPU、Mali CSF、RNG、禁用的 crypto，以及 RKVDEC 对基础 SRAM 的引用。

最终候选 DTB：

```text
c348c226998ee475a418307bf2af14f42c40f5cbbff42794e3886b93c210971d  rk3588-lubancat-5.dtb
model: EmbedFire LubanCat 5
compatible: embedfire,lubancat-5 embedfire,lubancat-5-btb rockchip,rk3588
```

`dtc` 仍会报告公共 IP 层中若干 VPU/JPEG/VDEC 同地址警告，以及基础树 GPIO interrupt provider 的既有警告；重复 SRAM 警告已经消失。当前仓库的 binding 基础文件也会影响全树 `dtbs_check`，因此本文不宣称 schema 检查零警告。

## 6. 引导链设计

### 6.1 Loader、IDB 与 FIT

`RK3588MINIALL.ini` 的 `NEWIDB=true` 表示下载容器内使用 new-IDB 所需的数据格式，不代表 `PATH` 输出本身就是可以写入磁盘的 IDB。`boot_merger` 生成的 `rk3588_spl_loader_v1.18.113.bin` 以 `LDR ` 开头，是供 `rkdeveloptool ul` 使用的下载 Loader。

`rkdeveloptool ul` 会解析其中的 FlashHead/FlashData/FlashBoot，在内存中生成 new-IDB 后写入 LBA 64；`rkdeveloptool wl 0x40 idbloader.img` 则要求输入已经转换好的 IDB。RAW 镜像必须采用后者的磁盘格式：

```bash
boot_merger idb -n -l rk3588_spl_loader_v1.18.113.bin -o idbloader.img
```

最终布局为：

| 区域 | 偏移 | 内容 | 头部 |
| --- | ---: | --- | --- |
| Rockchip IDB | LBA 64 / 32 KiB | `idbloader.img` | `RKNS` / `52 4b 4e 53` |
| U-Boot proper | LBA 16384 / 8 MiB | `uboot.img` FIT | `d00dfeed` |
| BOOTFS | 16 MiB | ext4 `BOOT` | 文件系统 |

锁定构建得到的引导工件为：

```text
de13b34ac5bf9999fc21e7989ab3c49a75576c6a6786f8b06416640419417268  rk3588_spl_loader_v1.18.113.bin
3ddeaa1da26a4ebd7b4a75904e849bee9562ce58a7a59b5d283792a40f6b7ca0  idbloader.img
6126b728798dd68e0cb5c83685f7e5c8ec15ea11a868d68e4fda6f0b23979c95  uboot.img
```

下载 Loader 和 FIT 容器含供应商工具产生的非确定元数据，不能假设跨机器永久逐字一致。每次构建仍必须重新检查固定 rkbin 输入、LDR/IDB/FIT 类型、FIT 内容和尺寸边界。`verify-image.sh` 会把镜像 LBA 64/16384 的完整内容与本地资源逐字比较，不能只凭文件名或四字节魔数判定兼容。

### 6.2 板卡启动脚本

板卡专用 `boot.cmd` 使用以下加载地址：

```text
scriptaddr     0x00500000  (U-Boot 环境)
load_addr      0x01000000
kernel_addr_r  0x02080000
fdt_addr_r     0x08300000
OP-TEE 保留区  0x08400000-0x09400000
ramdisk_addr_r 0x0a200000
```

这些地址避开 U-Boot 脚本、内核、FDT 扩容空间和 U-Boot FIT 中 OP-TEE 的内存保留区。脚本不使用供应商 U-Boot 未实现的 `kaslrseed` 命令；`armbianEnv.txt` 使用 `console=both`，由模板生成串口和本地显示控制台参数，避免重复的 `console=ttyS2,1500000`。

当前已发布的 `6.18.18-trim #491` 和 OTA 后的 `6.18.18.c1090-trim #1090` 均未暴露 `i2s0_8ch_mclkout_to_io` clock。为使 ES8388 获得外部 MCLK，`boot.cmd` 在进入 Linux 前执行：

```text
mw.l 0xfd58c318 0x00010000
```

这是针对当前 FnNAS 内核包的兼容初始化。开发树已经有原生 MCLK-to-IO gate，但不能反推已发布内核也包含它；将来切换到确认具备该 gate 的内核后，应重新验证并删除这个兼容写入。

`build-boot-scripts.sh` 还会把供应商 `mkimage` 生成的 legacy script 长度表终止字规范为该 U-Boot 可识别的零值，并重新计算 CRC。不要直接用另一版本 `mkimage` 生成文件后跳过校验。

## 7. 风扇配置

普通 V1 的两线 5 V、40 mm 风扇实测不适合 BSP 的 200 kHz PWM：低档几乎无差异，PWM 255 还会停转。最终配置采用 20 kHz、约 PWM 200/200 ms 的起转序列和下列档位：

```text
cooling-levels = <0 130 160 190 200>
fan-stop-to-start-percent = <79>
fan-stop-to-start-us      = <200000>
温度阈值       = 40 / 50 / 60 / 70 °C
hysteresis      = 3 °C
```

这些档位来自 V1 上两线风扇的起转和转速测试；100 档视觉上转动不稳，因此最低连续档提高到 130，190 与 200 的风量/噪声差异可重复分辨。直接使用 130 无法可靠冷起转；手工执行 `0 → 200（200 ms）→ 130` 连续 20 次均成功，因此用整数百分比 79% 近似 PWM 200。安装最终 DTB 后，仅写入 130、由驱动自动执行起转脉冲的路径也连续 20 次成功。当前驱动会把 `200000` 作为 `usleep_range()` 下限，实际等待可能约为 200–400 ms。不同厂商、批次的兼容风扇仍可能具有不同响应，同时避免使用实测会停转的 255。

系统启动后可通过标准 hwmon 接口临时手动调节：

```bash
fan_hwmon="$(dirname "$(grep -l '^pwmfan$' /sys/class/hwmon/hwmon*/name | head -n1)")"
echo 130 | sudo tee "$fan_hwmon/pwm1"
```

手工测试前应临时停用 thermal zone，测试结束后恢复；否则 thermal governor 会覆盖手工值。风扇不是建议热插拔的部件，应关机断电后再更换。

## 8. 构建环境

完整镜像构建需要 Linux root 权限、loop、mount、ext4 和 Btrfs 内核支持，以及 `parted`、`e2fsprogs`、`btrfs-progs` 等用户态工具。WSL2 只有在当前内核确实提供这些文件系统和 loop 能力时才适用；缺少 root 权限、内核模块或用户态工具时，应先修复构建环境，不能以空白镜像或跳过挂载检查代替。

构建前可用下列命令做最小预检：

```bash
sudo -v
command -v losetup mount parted mkfs.ext4 btrfs
grep -wE 'ext4|btrfs' /proc/filesystems
```

Ubuntu 24.04 可按项目依赖清单安装；只构建 DTB/U-Boot 时使用精简依赖即可：

```bash
sudo apt-get update
sudo apt-get install -y git make gcc-aarch64-linux-gnu device-tree-compiler \
  u-boot-tools bison flex libssl-dev bc python3
sudo apt-get install -y $(cat make-fnnas/scripts/ubuntu2404-make-fnnas-depends)
```

不要把 Ubuntu 24.04 的包清单未经检查地强装到其他发行版。构建脚本只拉取固定的 Linux、U-Boot 和 rkbin commit，不下载野火完整 SDK。

## 9. 可复现构建

以下命令假设四个仓库位于同一父目录。

### 9.1 编译 DTB

```bash
DTS_SOURCE_TREE="$PWD/../linux-6.18.y" \
DTB_OUTPUT_DIR="$PWD/../amlogic-s9xxx-armbian/build-armbian/armbian-files/platform-files/rockchip/bootfs/dtb/rockchip" \
  ./board/lubancat-5/build-dtbs.sh
```

脚本默认在临时目录下载固定的 FnNAS 内核 commit，只从 Linux Fork取单文件板级 DTS及锁定摘要的 Rockchip IP DTSI。如果已有精确内核树，可设置 `KERNEL_TREE=/path/to/tree`；其 Git HEAD必须与 `sources.env`中的 commit完全一致。

### 9.2 编译 U-Boot

```bash
UBOOT_OUTPUT_DIR="$PWD/../u-boot/u-boot/rockchip/lubancat-5" \
  ./board/lubancat-5/build-uboot.sh
```

也可设置 `UBOOT_TREE`、`RKBIN_TREE` 和 `CROSS_COMPILE` 复用已检出的固定工作树。脚本从 Git archive 构建，不修改传入工作树，并输出下载 Loader、裸 IDB 和 U-Boot FIT。

### 9.3 生成 boot.scr

```bash
BOOTFS_OUTPUT_DIR="$PWD/../amlogic-s9xxx-armbian/build-armbian/armbian-files/different-files/lubancat-5/bootfs" \
  ./board/lubancat-5/build-boot-scripts.sh
```

需要安装 `u-boot-tools`，或通过 `MKIMAGE=/path/to/mkimage` 指定匹配的工具。

### 9.4 使用同级资源仓库进行本地构建

当 Linux、Armbian 资源和 U-Boot 资源尚未进入 `renas` 默认下载来源时，应把同级仓库的构建结果复制到 FnNAS 已忽略的本地缓存：

```bash
mkdir -p \
  make-fnnas/fnnas-files/different-files \
  make-fnnas/fnnas-files/platform-files/rockchip/bootfs/dtb/rockchip \
  make-fnnas/u-boot/rockchip

cp -a \
  ../amlogic-s9xxx-armbian/build-armbian/armbian-files/different-files/lubancat-5 \
  make-fnnas/fnnas-files/different-files/
cp -a \
  ../amlogic-s9xxx-armbian/build-armbian/armbian-files/platform-files/rockchip/bootfs/dtb/rockchip/rk3588-lubancat-5.dtb \
  make-fnnas/fnnas-files/platform-files/rockchip/bootfs/dtb/rockchip/
cp -a \
  ../u-boot/u-boot/rockchip/lubancat-5 \
  make-fnnas/u-boot/rockchip/
```

这些目录是本地构建输入，不应在 FnNAS 仓库中强制跟踪。

### 9.5 放置基础镜像

从 [FnNAS `fnnas_base_image` release](https://github.com/ophub/fnnas/releases/tag/fnnas_base_image) 下载真实 Rockchip ARM64 基础镜像：

```text
fnnas-official-arm64-image_rockchip_1253.img.xz
size: 1838854224 bytes
sha256: 0453f9b98cf1cdc8b710fc7f1b040c73160d10d5f66b131cfaf722226c877066
```

校验后解压并把 `.img` 放入 `fnnas-arm64/`；`renas` 不直接匹配 `.img.xz`。不得用空白或伪造镜像代替。

```bash
sha256sum fnnas-official-arm64-image_rockchip_1253.img.xz
xz -dk fnnas-official-arm64-image_rockchip_1253.img.xz
mv fnnas-official-arm64-image_rockchip_1253.img fnnas-arm64/
```

### 9.6 打包镜像

```bash
sudo ./renas -b lubancat-5 -k 6.18.18 -a false
```

输出位于 `fnnas/out/`。该命令构建普通镜像文件，不写实体介质。

### 9.7 全新工作目录复现情况

`build-dtbs.sh` 已从固定 commit 创建干净的 detached 内核工作树并生成当前 `c348c2...` DTB；来源校验和结构断言通过。`build-uboot.sh` 已从固定 U-Boot/rkbin commit 生成 LDR、IDB 和 FIT，并通过固定 rkbin 摘要、U-Boot DTB、FIT 内容和尺寸边界检查。脚本将 rkbin 源码归档与解包后的构建目录分离，避免默认临时目录发生源/目标重名。`build-boot-scripts.sh` 已独立生成与资源仓库一致的 `boot.cmd`/`boot.scr`。

这证明构建入口可在新工作目录中复现其结构和固定输入检查；由于供应商封装工具会写入非确定元数据，不能把 LDR/FIT 的跨机器 SHA-256 完全一致作为唯一验收条件。

## 10. 离线镜像验证

压缩包先执行完整性测试并解压到普通文件：

```bash
gzip -t fnnas/out/fnnas_rockchip_lubancat-5_k6.18.18_YYYY.MM.DD.img.gz
gzip -dc fnnas/out/fnnas_rockchip_lubancat-5_k6.18.18_YYYY.MM.DD.img.gz \
  > /tmp/fnnas_rockchip_lubancat-5_k6.18.18_YYYY.MM.DD.img

sudo ./board/lubancat-5/verify-image.sh \
  /tmp/fnnas_rockchip_lubancat-5_k6.18.18_YYYY.MM.DD.img \
  lubancat-5
```

脚本只接受普通文件并以只读 loop/mount 工作；它明确拒绝块设备。检查内容包括：

- GPT，BOOTFS 从 16 MiB 开始，ROOTFS 从 528 MiB 开始；
- ext4 `BOOT` 和 Btrfs `ROOTFS`；
- LBA 64 的完整 IDB 和 LBA 16384 的完整 FIT 与资源逐字一致；
- `armbianEnv.txt`、`boot.cmd`、`boot.scr`、实际 DTB 及关键节点；
- 风扇 PWM 周期、档位、79%/200 ms 起转参数及 thermal map；
- `Image`、`uInitrd`、加载地址及 OP-TEE 避让；
- `/usr/lib/modules/6.18.18-trim` 存在。

下列摘要对应已经完成离线检查、实机启动和 OTA 回归的镜像修订版；该镜像仍包含调整前的 `a9104c...` DTB。当前源码生成的 DTB 调整了风扇档位和起转参数，已经通过 DTB 结构检查、手工 PWM 序列和安装后驱动自动起转测试，但尚未随完整镜像重新执行离线回归，不能用下列旧镜像结果替代该验证。

```text
raw image size:   4848615424 bytes
raw image SHA-256: 2f9e3758cc4331a1d38dd348f74188ec83c3daecd9f03c099e31c262e1674c78
gzip SHA-256:      8926c4e17604efe314f8094c74d132dfb7873eac7840eeaed84e9a9eb7450c71
```

离线脚本已返回：

```text
PASS: lubancat-5 image layout and offline contents match the locked 6.18.18 inputs.
Hardware boot has not been tested by this script.
```

最终镜像 BOOTFS 的关键摘要：

```text
a9104ce61180393dbaf546535a8184813b798de2cb3537c67789e85004c1c66f  dtb/rockchip/rk3588-lubancat-5.dtb
58d44bf9dcab49b48182d254958f26bba869b9ab8c7ba44b632d8a9fd6d1ec81  boot.cmd
3cdc9d9ea43173516265bbab8b2a11d630cfa5a8bb9d42c42245332efbc5183e  boot.scr
53f406829be54c274ad65bc7c4a5e7aa24d72107645d9a64465b4fa1a2c6f67f  vmlinuz-6.18.18-trim
bf70a1a443f1e8b1f23c55fc1e305f215b627424bdfc193bc6abf822a293830f  initrd.img-6.18.18-trim
dfdf89ff8ca03e8a9bc7a1f2030c8d799d303182236e0e63f640ea0fdac5aa16  uInitrd-6.18.18-trim
```

离线 PASS 不能替代实体板冷启动验证。

## 11. 实机测试流程

优先使用一张可完全覆盖的独立 TF 卡，保留原厂介质和数据：

1. 核对 V1 板卡、镜像文件名和 SHA-256；
2. 使用图形化镜像工具烧录；如使用 `dd`，先人工核对整张 TF 设备，本文不提供可直接复制的设备路径；
3. 连接 3.3 V UART，TX/RX 交叉，参数 `1500000 8N1`；
4. 断电插卡，保存从 BootROM 开始的完整日志；
5. 首次只验证 TF 启动，不运行 eMMC/SPI/NVMe 安装或更新命令。

启动后建议检查：

```bash
uname -a
cat /proc/device-tree/model; echo
tr '\0' '\n' </proc/device-tree/compatible
sha256sum /boot/dtb/rockchip/rk3588-lubancat-5.dtb
ip -br link
lspci -nnk
lsusb -t
cat /proc/asound/cards
ls -l /sys/class/drm /sys/class/typec
grep -H . /sys/class/hwmon/hwmon*/name
sudo cat /sys/kernel/debug/devices_deferred
sudo dmesg -T | grep -Ei 'error|fail|timeout|fault|mpp|rga|mali|rknpu|nvme|gmac|mmc'
```

## 12. 实机验证记录

### 12.1 启动、存储和网络

最终完整镜像已写入 V1 eMMC 并从断电状态启动到 fnOS。初始内核为 `6.18.18-trim #491`，BOOTFS 为 ext4、ROOTFS 为 Btrfs，`/lib/modules/6.18.18-trim` 存在。镜像内 DTB、boot script、内核和 initramfs 摘要与运行系统 `/boot` 一致，因此结果不是在旧系统上只替换 DTB 得到的。

内置 M.2 插入 2 TB NVMe SSD 后，设备状态为 `live`，链路为 8.0 GT/s x4。fnOS 成功创建单成员 MD RAID1、LVM PV/VG/LV 和 Btrfs `/vol1`。多 GiB 文件传输和 1 GiB `fdatasync` 写入、SHA-256 读取校验均通过；重启后 MD 保持 `[1/1] [U]`，LVM 和 Btrfs 自动恢复挂载。这是功能验证，不是存储性能基准。

两个 GMAC 均绑定 `rk_gmac-dwmac`。第二网口已完成 1 Gbit/s 全双工链路及基础网络访问；尚未进行双口并发和长时间吞吐测试。

### 12.2 音视频和加速器

MPP/RGA 实际完成 H.264 RKMPP 编码、RKMPP 解码，以及 1920x1080 到 1280x720 的 RGA 缩放再编码；退出码为 0，输出帧数和尺寸正确。fnOS 影视使用“非原画”也完成播放和服务端转码。界面中的 Media Render 约 60% 反映媒体/VPU/RGA 路径活动，不是 Mali 3D GPU 利用率证明。

`rkgpu_bifrost_csf` 已绑定 `fb000000.gpu`，生成 `/dev/mali0`；GPU OPP/devfreq 为 300 MHz 到 1 GHz，空闲 runtime PM 可进入 suspended。仍有 leakage 读取失败、DDK 将硬件 status 5 回退到 r0p0 status 0 等提示，但未阻止驱动探测和 devfreq 建立。系统缺少匹配的 `libmali`/OpenCL ICD，`clinfo` 没有 Mali 平台，Vulkan 只见软件设备，因此不能宣称 3D、OpenCL 或 Vulkan 可用。

安装官方“飞牛 AI 引擎(rk3588)”后，`ai_manager` 以 `model_format:RKNN` 加载 `face_det.rk3588.rknn` 和 `face_rec.rk3588.rknn`，RKNN Toolkit Lite 2 版本为 2.3.2。一套测试图已完成检测、特征提取和人物聚类，确认 fnOS AI 相册的人脸识别应用路径可以调用 RKNPU；这仍不是对超大相册、持续增量索引或所有图像格式的压力验证。`imgTxtRec` 语义检索模型未完成验证，属于另一项能力。

### 12.3 显示、Type-C、音频与风扇

两个 HDMI 控制器、DRM card/connectors、两张 HDMI 声卡、FUSB302 Type-C port/partner 和 ES8388 声卡均已注册。早期 HDMI1 DDC 误用 GPIO2_B5，曾与 Type-C VBUS regulator 冲突；修正 pinctrl 后冲突消失，deferred 列表为空。尚未验证真实显示器图像、HDMI 音频和 Type-C DP Alt Mode。

ES8388 首次播放出现 `-EIO`，原因包括音频主从关系和 MCLK-to-IO 未打开。DTS 改为 SoC I2S 提供 BCLK/LRCLK，启动脚本打开 SYS_GRF MCLK 后，外接耳机可播放测试音。普通 LubanCat-5 没有板载扬声器；capture 节点只代表 codec 具备录音通道，不等于板上有麦克风。

风扇已验证停止、低速、中速、高速以及 thermal governor 根据 package 温度选择 cooling state。最低连续档从 100 提高到 130；`0 → 200（200 ms）→ 130` 的手工序列和最终 DTB 的自动起转路径分别连续 20 次成功，因此当前源码采用 79%/200 ms 起转参数。这组新配置尚未随完整镜像执行离线回归，也未进行长期高温负载和不同批次风扇测试。

### 12.4 OTA 回归

通过 fnOS Web OTA 从 `6.18.18-trim #491` 更新到 `6.18.18.c1090-trim #1090`。更新后的 `/boot/Image` 和 `/boot/uInitrd` 指向新内核，`/lib/modules/6.18.18.c1090-trim` 存在。系统重启成功，NVMe 存储池恢复，MPP/RGA/RKNPU/Mali、双网口、Type-C、HDMI 和三张 ALSA 声卡仍可枚举；`adc-keys` 在新内核中完成绑定。

可选 OTA 保护 hook 记录更新后下列四个板卡文件均为 `action=preserved`，说明这一次 OTA 没有改写它们，而不是“被覆盖后再恢复”：

```text
a9104ce61180393dbaf546535a8184813b798de2cb3537c67789e85004c1c66f  rk3588-lubancat-5.dtb
e563a1d9a21986dbfe3b4099ae1c6de31966c62c0c28821cb6209b349639c0b1  armbianEnv.txt
58d44bf9dcab49b48182d254958f26bba869b9ab8c7ba44b632d8a9fd6d1ec81  boot.cmd
3cdc9d9ea43173516265bbab8b2a11d630cfa5a8bb9d42c42245332efbc5183e  boot.scr
```

这只证明本次版本更新的行为，不能保证未来 OTA 永不覆盖 DTB 或启动文件。每次 OTA 前仍应备份 `/boot` 并记录摘要，更新后重新核对。

### 12.5 可选 OTA 启动文件保护

可审查源码和显式安装/卸载工具保存在 `board/lubancat-5/ota/`。它用于已安装内核的 DTB 包尚未原生提供 LubanCat-5 启动文件时的本地保护，不由 `renas` 调用，也不会自动注入生成的镜像。

安装前必须确认当前系统可以正常冷启动，并确认 `/boot` 中以下四个文件就是准备长期保留的版本：

- `dtb/rockchip/rk3588-lubancat-5.dtb`
- `armbianEnv.txt`
- `boot.cmd`
- `boot.scr`

安装程序把这四个文件复制到 `/usr/local/share/lubancat-5-boot/`，并把 `zzzz-lubancat-5-restore` 安装到 `/etc/kernel/postinst.d/`。Debian 内核包安装完成后会通过 `run-parts` 调用该 hook；它逐个比较摘要，只恢复缺失或内容发生变化的文件，并把结果写入权限为 `0600` 的审计日志：

```bash
cd board/lubancat-5/ota
sudo ./install.sh
sudo tail -n 20 /var/log/lubancat5-boot-restore.log
```

主动更新 DTB 或启动脚本后，必须重新执行 `install.sh` 刷新保护副本；否则后续内核更新可能恢复旧文件。要移除保护，可执行：

```bash
cd board/lubancat-5/ota
sudo ./uninstall.sh
```

卸载程序不修改当前 `/boot`，也保留 `/var/log/lubancat5-boot-restore.log`。该工具不保护 RAW 区域中的 IDB/FIT，不负责回滚内核或模块，也不能代替可恢复的完整系统备份。上游内核/DTB 包原生提供并维护 LubanCat-5 启动文件后，应移除此过渡保护。

## 13. 已知限制

- 仅 V1 有实机验证；V2 不注册、不提供构建入口。
- Mali 仅完成内核驱动、OPP/devfreq 和节点验证，未完成真实 3D/OpenCL/Vulkan 用户态负载。
- HDMI 只验证驱动和 connector 枚举；未验证实际图像、HDMI 音频、FRL 或 HDMI RX。
- Type-C 只验证 FUSB302/TCPM 和 partner 枚举；DP Alt Mode 未实现。
- 摄像头、MIPI DSI/eDP、红外遥控、耳机线控、Mini-PCIe、M.2 E-Key 未验证。
- AI 相册 RKNN 人脸检测、识别和人物聚类已在一套测试图中通过；大规模相册和持续增量索引未验证，`imgTxtRec` 语义检索也未完成验证。
- NVMe、第二网口、媒体转码和 OTA 均是短期功能测试，不等同于长期稳定性、掉电恢复和多路压力测试。
- 型号允许选择 `rockchip/6.18.y`，但当前只完整验证了 `6.18.18`；其他 6.18.x 必须重新检查 DTB、模块绑定、离线镜像和实机启动，不能把可构建等同于已兼容。
- 下载 Loader/FIT 受供应商工具元数据影响，不保证跨机器 bit-for-bit 复现；固定输入和结构检查仍必须通过。
- 不提供自动 eMMC 安装、SPI 启动或 NVMe 启动流程，不开启 GitHub Actions 自动发布。

## 14. 故障排查

- **冷启动无 UART、仍进 MASKROM**：读取 RAW 镜像 LBA 64。若头部为 `LDR `，说明误写了 USB 下载 Loader；正确内容应是 `RKNS` IDB。FIT 仍应位于 LBA 16384。
- **进入 U-Boot 但不自动启动**：确认 BOOTFS 含 `boot.scr`、`armbianEnv.txt`、`Image`、`uInitrd` 和 DTB；检查 legacy script 长度表偏移 68 处为零终止字。
- **内核或 initramfs 加载后停住**：核对 `kernel_addr_r`、`fdt_addr_r`、`ramdisk_addr_r` 和 OP-TEE 保留区；不要恢复会发生重叠的通用默认地址。
- **找不到 ROOTFS**：比较 `armbianEnv.txt` 中的 `rootdev=UUID=...`、`rootfstype=btrfs` 与实际 GPT/文件系统。
- **UART 无输出**：确认 3.3 V 电平、GND、TX/RX 交叉和 1500000 波特率；检查 `console=both` 是否生成 `console=ttyS2,1500000 console=tty1`。
- **耳机无声**：先检查 mixer、ES8388 和 I2S 驱动，再查看 `clk_summary` 是否存在原生 MCLK-to-IO gate；当前发布内核仍依赖 `boot.cmd` 中的 SYS_GRF 兼容写入。
- **风扇手工值自动变化**：thermal governor 正在接管 PWM。临时测试时先停用对应 thermal zone，结束后恢复；不要长期关闭温控保护。
- **看到 `FAILED` systemd unit**：先用 `systemctl status` 和 `journalctl -b -u` 区分 fnOS 用户空间配置问题与内核设备探测失败；不要仅凭红字判定设备树错误。

## 15. 提交前检查

```bash
bash -n board/lubancat-5/*.sh
sh -n board/lubancat-5/ota/*
run-parts --test board/lubancat-5/ota
./board/lubancat-5/verify-dts-origin.sh
git status --short --untracked-files=all
git diff --check
git diff -- docs/lubancat-5.md
```

完整镜像还应重新运行 `verify-image.sh`。提交时按四个仓库分别暂存所需文件，不使用 `git add .` 或 `git add -A`，也不提交基础镜像、输出镜像、完整 SDK、临时日志或本机兼容缓存。
