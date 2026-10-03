#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
# shellcheck source=sources.env
source "${script_dir}/sources.env"

usage() {
    echo "Usage: sudo $0 <FnNAS image> <lubancat-5>" >&2
    exit 2
}

[[ "$#" -eq 2 ]] || usage
image="$1"
board="$2"

case "${board}" in
    lubancat-5)
        fdtfile="rk3588-lubancat-5.dtb"
        expected_model="EmbedFire LubanCat 5"
        expected_compatible="embedfire,lubancat-5 embedfire,lubancat-5-btb rockchip,rk3588"
        ;;
    *) usage ;;
esac

[[ "${EUID}" -eq 0 ]] || {
    echo "Root is required for read-only loop attachment and mounts." >&2
    exit 1
}
[[ -f "${image}" && ! -b "${image}" ]] || {
    echo "Refusing non-regular image path: ${image}" >&2
    exit 1
}
image="$(readlink -e -- "${image}")"

for command_name in awk blkid cmp dd fdtget grep losetup mount mountpoint od parted readlink stat tr umount; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        echo "Missing required command: ${command_name}" >&2
        exit 1
    }
done

armbian_files_dir="${ARMBIAN_FILES_DIR:-${repo_root}/../amlogic-s9xxx-armbian/build-armbian/armbian-files}"
board_resources_dir="${BOARD_RESOURCES_DIR:-${armbian_files_dir}/different-files/${board}}"
platform_dtb_dir="${PLATFORM_DTB_DIR:-${armbian_files_dir}/platform-files/rockchip/bootfs/dtb/rockchip}"
bootloader_dir="${UBOOT_RESOURCES_DIR:-${repo_root}/../u-boot/u-boot/rockchip/${board}}"
idbloader="${bootloader_dir}/idbloader.img"
fit="${bootloader_dir}/uboot.img"
source_dtb="${platform_dtb_dir}/${fdtfile}"
source_bootcmd="${board_resources_dir}/bootfs/boot.cmd"
source_bootscr="${board_resources_dir}/bootfs/boot.scr"
for required_file in "${idbloader}" "${fit}" "${source_dtb}" "${source_bootcmd}" "${source_bootscr}"; do
    [[ -s "${required_file}" ]] || {
        echo "Missing verification input: ${required_file}" >&2
        exit 1
    }
done

[[ "$(od -An -tx1 -N4 "${idbloader}" | tr -d ' \n')" == "524b4e53" ]] || {
    echo "Invalid Rockchip new-IDB header: ${idbloader}" >&2
    exit 1
}
[[ "$(od -An -tx1 -N4 "${fit}" | tr -d ' \n')" == "d00dfeed" ]] || {
    echo "Invalid U-Boot FIT header: ${fit}" >&2
    exit 1
}
idbloader_size="$(stat -c %s "${idbloader}")"
fit_size="$(stat -c %s "${fit}")"
[[ "${idbloader_size}" -le $((16384 * 512 - 64 * 512)) ]] || {
    echo "IDB loader overlaps the FIT write offset." >&2
    exit 1
}
[[ "${fit_size}" -le $((16 * 1024 * 1024 - 16384 * 512)) ]] || {
    echo "FIT overlaps the BOOTFS partition." >&2
    exit 1
}

work_dir="$(mktemp -d)"
boot_mount="${work_dir}/bootfs"
root_mount="${work_dir}/rootfs"
loop_device=""
mkdir -p "${boot_mount}" "${root_mount}"

cleanup() {
    if mountpoint -q "${root_mount}"; then
        umount "${root_mount}" || true
    fi
    if mountpoint -q "${boot_mount}"; then
        umount "${boot_mount}" || true
    fi
    if [[ -n "${loop_device}" ]]; then
        losetup -d "${loop_device}" || true
    fi
    rm -rf -- "${work_dir}"
}
trap cleanup EXIT

parted_output="$(parted -ms "${image}" unit B print)"
printf '%s\n' "${parted_output}"
grep -Fx 'BYT;' <<<"${parted_output}" >/dev/null
awk -F: '$1 != "BYT;" && $1 !~ /^[0-9]+$/ && $6 == "gpt" { found=1 } END { exit !found }' <<<"${parted_output}" || {
    echo "Image does not contain a GPT partition table." >&2
    exit 1
}
awk -F: '$1 == 1 && $2 == "16777216B" && $6 == "BOOT" { found=1 } END { exit !found }' <<<"${parted_output}" || {
    echo "Partition 1 is not the expected GPT BOOT partition at 16 MiB." >&2
    exit 1
}
awk -F: '$1 == 2 && $2 == "553648128B" && $6 == "ROOTFS" { found=1 } END { exit !found }' <<<"${parted_output}" || {
    echo "Partition 2 is not the expected GPT ROOTFS partition at 528 MiB." >&2
    exit 1
}

dd if="${image}" of="${work_dir}/idbloader.from-image" iflag=skip_bytes,count_bytes \
    skip=$((64 * 512)) count="${idbloader_size}" status=none
dd if="${image}" of="${work_dir}/fit.from-image" iflag=skip_bytes,count_bytes \
    skip=$((16384 * 512)) count="${fit_size}" status=none
cmp "${idbloader}" "${work_dir}/idbloader.from-image"
cmp "${fit}" "${work_dir}/fit.from-image"

loop_device="$(losetup --read-only --partscan --find --show "${image}")"
[[ -b "${loop_device}p1" && -b "${loop_device}p2" ]] || {
    echo "Loop partitions were not created for ${image}." >&2
    exit 1
}
[[ "$(blkid -s TYPE -o value "${loop_device}p1")" == "ext4" ]] || {
    echo "BOOTFS is not ext4." >&2
    exit 1
}
[[ "$(blkid -s LABEL -o value "${loop_device}p1")" == "BOOT" ]] || {
    echo "BOOTFS label is not BOOT." >&2
    exit 1
}
[[ "$(blkid -s TYPE -o value "${loop_device}p2")" == "btrfs" ]] || {
    echo "ROOTFS is not Btrfs." >&2
    exit 1
}
[[ "$(blkid -s LABEL -o value "${loop_device}p2")" == "ROOTFS" ]] || {
    echo "ROOTFS label is not ROOTFS." >&2
    exit 1
}

mount -t ext4 -o ro,noload "${loop_device}p1" "${boot_mount}"
mount -t btrfs -o ro "${loop_device}p2" "${root_mount}"

armbian_env="${boot_mount}/armbianEnv.txt"
image_dtb="${boot_mount}/dtb/rockchip/${fdtfile}"
image_bootcmd="${boot_mount}/boot.cmd"
image_bootscr="${boot_mount}/boot.scr"
[[ -s "${armbian_env}" && -s "${image_dtb}" && -s "${image_bootcmd}" && -s "${image_bootscr}" ]] || {
    echo "BOOTFS is missing armbianEnv.txt, ${fdtfile}, boot.cmd, or boot.scr." >&2
    exit 1
}
grep -Fx "fdtfile=rockchip/${fdtfile}" "${armbian_env}" >/dev/null
grep -Eq '^rootdev=UUID=[0-9a-fA-F-]+$' "${armbian_env}" >/dev/null
grep -Fx 'rootfstype=btrfs' "${armbian_env}" >/dev/null
grep -Fx 'overlay_prefix=rk3588' "${armbian_env}" >/dev/null
cmp "${source_dtb}" "${image_dtb}"
cmp "${source_bootcmd}" "${image_bootcmd}"
cmp "${source_bootscr}" "${image_bootscr}"
[[ "$(od -An -tx1 -N4 "${image_bootscr}" | tr -d ' \n')" == "27051956" ]]
[[ "$(od -An -tx1 -N4 -j68 "${image_bootscr}" | tr -d ' \n')" == "00000000" ]]
dd if="${image_bootscr}" bs=1 skip=72 status=none | cmp - "${image_bootcmd}"
for expected_setting in \
    'setenv load_addr "0x01000000"' \
    'setenv kernel_addr_r "0x02080000"' \
    'setenv fdt_addr_r "0x08300000"' \
    'setenv ramdisk_addr_r "0x0a200000"' \
    'mw.l 0xfd58c318 0x00010000'; do
    grep -Fx "${expected_setting}" "${image_bootcmd}" >/dev/null
done
if grep -Eq '^[[:space:]]*kaslrseed([[:space:]]|$)' "${image_bootcmd}"; then
    echo "BOOTFS boot.cmd uses kaslrseed, but the bundled vendor U-Boot does not provide that command." >&2
    exit 1
fi
[[ "$(fdtget -t s "${image_dtb}" / model)" == "${expected_model}" ]]
dtb_compatible="$(fdtget -t s "${image_dtb}" / compatible)"
[[ "${dtb_compatible}" == "${expected_compatible}" ]]
for symbol_name in es8388 gmac0 gmac1 hdmi0 hdmi1 hdptxphy0 hdptxphy1 \
    i2s0_8ch i2s5_8ch i2s6_8ch pcie2x1l0 pcie2x1l2 pcie3x4 pwm4 \
    sdhci sdmmc usbdp_phy0 usb_host0_xhci usb_host1_xhci vop; do
    node_path="$(fdtget -t s "${image_dtb}" /__symbols__ "${symbol_name}")"
    node_status="$(fdtget -t s "${image_dtb}" "${node_path}" status 2>/dev/null || true)"
    [[ -z "${node_status}" || "${node_status}" == "okay" ]]
done

usbc_path="$(fdtget -t s "${image_dtb}" /__symbols__ usbc0)"
connector_path="${usbc_path}/connector"
[[ "$(fdtget -t s "${image_dtb}" "${usbc_path}" compatible)" == "fcs,fusb302" &&
   "$(fdtget -t s "${image_dtb}" "${connector_path}" compatible)" == "usb-c-connector" &&
   "$(fdtget -t s "${image_dtb}" "${connector_path}" data-role)" == "dual" &&
   "$(fdtget -t s "${image_dtb}" "${connector_path}" power-role)" == "dual" ]]
[[ "$(fdtget -t s "${image_dtb}" /sound compatible)" == "simple-audio-card" &&
   "$(fdtget -t s "${image_dtb}" /adc-keys compatible)" == "adc-keys" ]]
[[ "$(fdtget -t s "${image_dtb}" /hdmi0-con compatible)" == "hdmi-connector" &&
   "$(fdtget -t s "${image_dtb}" /hdmi1-con compatible)" == "hdmi-connector" ]]
for symbol_name in hdmi0 hdmi1; do
    node_path="$(fdtget -t s "${image_dtb}" /__symbols__ "${symbol_name}")"
    fdtget -t u "${image_dtb}" "${node_path}" frl-enable-gpios >/dev/null
done
for symbol_name in pcie2x1l0 pcie2x1l2; do
    node_path="$(fdtget -t s "${image_dtb}" /__symbols__ "${symbol_name}")"
    fdtget -t u "${image_dtb}" "${node_path}" reset-gpios >/dev/null
    fdtget -t u "${image_dtb}" "${node_path}" vpcie3v3-supply >/dev/null
done

fan_path="$(fdtget -t s "${image_dtb}" /__symbols__ fan)"
pwm4_path="$(fdtget -t s "${image_dtb}" /__symbols__ pwm4)"
fan_phandle="$(fdtget -t u "${image_dtb}" "${fan_path}" phandle)"
pwm4_phandle="$(fdtget -t u "${image_dtb}" "${pwm4_path}" phandle)"
[[ "$(fdtget -t s "${image_dtb}" "${fan_path}" compatible)" == "pwm-fan" ]] || {
    echo "LubanCat-5 fan is not bound to pwm-fan in the image DTB." >&2
    exit 1
}
read -r -a cooling_levels <<<"$(fdtget -t u "${image_dtb}" "${fan_path}" cooling-levels)"
[[ "${cooling_levels[*]}" == "0 130 160 190 200" ]] || {
    echo "Unexpected LubanCat-5 fan cooling levels in the image DTB." >&2
    exit 1
}
[[ "$(fdtget -t u "${image_dtb}" "${fan_path}" fan-stop-to-start-percent)" == "79" &&
   "$(fdtget -t u "${image_dtb}" "${fan_path}" fan-stop-to-start-us)" == "200000" ]] || {
    echo "Unexpected LubanCat-5 fan start pulse in the image DTB." >&2
    exit 1
}
read -r -a pwm_specifier <<<"$(fdtget -t u "${image_dtb}" "${fan_path}" pwms)"
[[ "${#pwm_specifier[@]}" -eq 4 &&
   "${pwm_specifier[0]}" == "${pwm4_phandle}" &&
   "${pwm_specifier[1]}" == "0" &&
   "${pwm_specifier[2]}" == "50000" &&
   "${pwm_specifier[3]}" == "0" ]] || {
    echo "Unexpected LubanCat-5 PWM4 fan specifier in the image DTB." >&2
    exit 1
}

expected_temperatures=(40000 50000 60000 70000)
for index in 0 1 2 3; do
    trip_path="/thermal-zones/package-thermal/trips/package-fan${index}"
    map_path="/thermal-zones/package-thermal/cooling-maps/map${index}"
    trip_phandle="$(fdtget -t u "${image_dtb}" "${trip_path}" phandle)"
    [[ "$(fdtget -t u "${image_dtb}" "${trip_path}" temperature)" == "${expected_temperatures[index]}" &&
       "$(fdtget -t u "${image_dtb}" "${trip_path}" hysteresis)" == "3000" &&
       "$(fdtget -t s "${image_dtb}" "${trip_path}" type)" == "active" &&
       "$(fdtget -t u "${image_dtb}" "${map_path}" trip)" == "${trip_phandle}" &&
       "$(fdtget -t u "${image_dtb}" "${map_path}" cooling-device)" == "${fan_phandle} $((index + 1)) $((index + 1))" ]] || {
        echo "Unexpected LubanCat-5 fan thermal map ${index} in the image DTB." >&2
        exit 1
    }
done
kernel_name="${KERNEL_VERSION}-trim"
[[ -L "${boot_mount}/Image" && "$(readlink "${boot_mount}/Image")" == "vmlinuz-${kernel_name}" ]]
[[ -L "${boot_mount}/uInitrd" && "$(readlink "${boot_mount}/uInitrd")" == "uInitrd-${kernel_name}" ]]
[[ -s "${boot_mount}/vmlinuz-${kernel_name}" && -s "${boot_mount}/uInitrd-${kernel_name}" ]]
script_addr=$((0x00500000))
load_addr=$((0x01000000))
kernel_addr=$((0x02080000))
fdt_addr=$((0x08300000))
optee_start=$((0x08400000))
optee_end=$((0x09400000))
ramdisk_addr=$((0x0a200000))
[[ $((script_addr + $(stat -c %s "${image_bootscr}"))) -lt ${load_addr} ]] || {
    echo "boot.scr overlaps the temporary load address." >&2
    exit 1
}
[[ $((kernel_addr + $(stat -c %s "${boot_mount}/vmlinuz-${kernel_name}"))) -lt ${fdt_addr} ]] || {
    echo "Kernel overlaps the FDT address." >&2
    exit 1
}
[[ $((fdt_addr + $(stat -c %s "${image_dtb}") + 65536)) -le ${optee_start} ]] || {
    echo "FDT plus resize headroom overlaps the OP-TEE reservation." >&2
    exit 1
}
[[ ${optee_end} -le ${ramdisk_addr} ]] || {
    echo "Ramdisk address overlaps the OP-TEE reservation." >&2
    exit 1
}
[[ -d "${root_mount}/usr/lib/modules/${kernel_name}" ]] || {
    echo "Missing module directory /usr/lib/modules/${kernel_name}." >&2
    exit 1
}

echo "PASS: ${board} image layout and offline contents match the locked ${KERNEL_VERSION} inputs."
echo "Hardware boot has not been tested by this script."
