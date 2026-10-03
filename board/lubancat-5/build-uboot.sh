#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
# shellcheck source=sources.env
source "${script_dir}/sources.env"

cross_compile="${CROSS_COMPILE:-aarch64-linux-gnu-}"
for command_name in git make tar sha256sum od install awk grep sed stat tr fdtget "${cross_compile}gcc"; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        echo "Missing required command: ${command_name}" >&2
        exit 1
    }
done

temporary_root="$(mktemp -d)"
trap 'rm -rf -- "${temporary_root}"' EXIT
uboot_tree="${UBOOT_TREE:-}"
rkbin_tree="${RKBIN_TREE:-}"

fetch_commit() {
    local repository="$1"
    local commit="$2"
    local destination="$3"

    git init -q "${destination}"
    git -C "${destination}" remote add origin "${repository}"
    git -C "${destination}" fetch -q --depth=1 origin "${commit}"
    git -C "${destination}" checkout -q --detach FETCH_HEAD
}

if [[ -z "${uboot_tree}" ]]; then
    uboot_tree="${temporary_root}/u-boot"
    fetch_commit "${UBOOT_REPOSITORY}" "${UBOOT_COMMIT}" "${uboot_tree}"
fi
if [[ -z "${rkbin_tree}" ]]; then
    rkbin_tree="${temporary_root}/rkbin-source"
    fetch_commit "${RKBIN_REPOSITORY}" "${RKBIN_COMMIT}" "${rkbin_tree}"
fi

[[ "$(git -C "${uboot_tree}" rev-parse HEAD)" == "${UBOOT_COMMIT}" ]] || {
    echo "U-Boot tree is not pinned to ${UBOOT_COMMIT}." >&2
    exit 1
}
[[ "$(git -C "${rkbin_tree}" rev-parse HEAD)" == "${RKBIN_COMMIT}" ]] || {
    echo "rkbin tree is not pinned to ${RKBIN_COMMIT}." >&2
    exit 1
}

# Always build from clean archives.  This avoids modifying caller-supplied trees
# and prevents stale objects entering outputs.
uboot_source="${uboot_tree}"
rkbin_source="${rkbin_tree}"
uboot_tree="${temporary_root}/u-boot-build"
rkbin_tree="${temporary_root}/rkbin-build"
mkdir -p "${uboot_tree}" "${rkbin_tree}"
git -C "${uboot_source}" archive "${UBOOT_COMMIT}" | tar -x -C "${uboot_tree}"
git -C "${rkbin_source}" archive "${RKBIN_COMMIT}" | tar -x -C "${rkbin_tree}"

verify_sha256() {
    local expected="$1"
    local file="$2"
    local actual

    [[ -f "${file}" ]] || {
        echo "Missing pinned build input: ${file}" >&2
        exit 1
    }
    actual="$(sha256sum "${file}" | awk '{print $1}')"
    [[ "${actual}" == "${expected}" ]] || {
        echo "Unexpected SHA-256 for ${file}: ${actual}" >&2
        exit 1
    }
}

# Do not infer compatibility from output names.  Pin the exact vendor binary
# inputs selected by RK3588MINIALL.ini/RK3588TRUST.ini and the board defconfig.
verify_sha256 "${RKBIN_DDR_SHA256}" "${rkbin_tree}/${RKBIN_DDR_FILE}"
verify_sha256 "${RKBIN_SPL_SHA256}" "${rkbin_tree}/${RKBIN_SPL_FILE}"
verify_sha256 "${RKBIN_BL31_SHA256}" "${rkbin_tree}/${RKBIN_BL31_FILE}"
verify_sha256 "${RKBIN_BL32_SHA256}" "${rkbin_tree}/${RKBIN_BL32_FILE}"

defconfig="${uboot_tree}/configs/${UBOOT_DEFCONFIG}_defconfig"
grep -Fx 'CONFIG_ROCKCHIP_RK3588=y' "${defconfig}" >/dev/null
grep -Fx 'CONFIG_ROCKCHIP_FIT_IMAGE=y' "${defconfig}" >/dev/null
grep -Fx 'CONFIG_DEFAULT_DEVICE_TREE="rk3588-lubancat-5-pcie"' "${defconfig}" >/dev/null
grep -Fx 'CONFIG_CMD_MMC=y' "${defconfig}" >/dev/null
grep -Fx 'CONFIG_NVME=y' "${defconfig}" >/dev/null
grep -Fx 'CONFIG_PCIE_DW_ROCKCHIP=y' "${defconfig}" >/dev/null

grep -Fx "FlashData=${RKBIN_DDR_FILE}" "${rkbin_tree}/RKBOOT/RK3588MINIALL.ini" >/dev/null
grep -Fx "FlashBoot=${RKBIN_SPL_FILE}" "${rkbin_tree}/RKBOOT/RK3588MINIALL.ini" >/dev/null
grep -Fx "PATH=${RKBIN_BL31_FILE}" "${rkbin_tree}/RKTRUST/RK3588TRUST.ini" >/dev/null
grep -Fx "PATH=${RKBIN_BL32_FILE}" "${rkbin_tree}/RKTRUST/RK3588TRUST.ini" >/dev/null

# Rockchip's FIT helper calls gzip without -n.  Suppress gzip's input mtime and
# filename fields so the FIT component payloads are stable.  The proprietary
# Rockchip loader packer still stamps its output; see docs/lubancat-5.md.
sed -i 's/COMPRESS_CMD="gzip -kf9"/COMPRESS_CMD="gzip -n -kf9"/' \
    "${uboot_tree}/arch/arm/mach-rockchip/fit_nodes.sh"

# The vendor make.sh still invokes python2 for scripts that are Python 3 compatible.
tool_bin="${temporary_root}/tools"
mkdir -p "${tool_bin}"
if ! command -v python2 >/dev/null 2>&1; then
    command -v python3 >/dev/null 2>&1 || {
        echo "Missing required command: python3" >&2
        exit 1
    }
    ln -sf "$(command -v python3)" "${tool_bin}/python2"
fi

export PATH="${tool_bin}:${PATH}"
export SOURCE_DATE_EPOCH="${UBOOT_SOURCE_DATE_EPOCH}"
export KBUILD_BUILD_TIMESTAMP="@${UBOOT_SOURCE_DATE_EPOCH}"
export KBUILD_BUILD_USER="fnnas"
export KBUILD_BUILD_HOST="reproducible"

(
    cd "${uboot_tree}"
    ./make.sh "${UBOOT_DEFCONFIG}" CROSS_COMPILE="${cross_compile}"
)

loader="${uboot_tree}/rk3588_spl_loader_v1.18.113.bin"
idbloader="${uboot_tree}/idbloader.img"
fit="${uboot_tree}/uboot.img"
uboot_dtb="${uboot_tree}/u-boot.dtb"
[[ -s "${loader}" && -s "${fit}" ]] || {
    echo "The official build did not produce the expected loader and FIT." >&2
    exit 1
}

# RK3588MINIALL.ini produces an LDR download container.  rkdeveloptool's `ul`
# command converts the FlashHead/FlashData/FlashBoot entries in that container
# to a new-format IDB before writing sector 64.  A raw disk image must contain
# that converted IDB, not the LDR container itself.
boot_merger="${rkbin_tree}/tools/boot_merger"
[[ -x "${boot_merger}" ]] || {
    echo "Missing executable Rockchip boot_merger: ${boot_merger}" >&2
    exit 1
}
"${boot_merger}" idb -n -l "${loader}" -o "${idbloader}"
[[ -s "${idbloader}" ]] || {
    echo "Rockchip boot_merger did not produce idbloader.img." >&2
    exit 1
}
[[ "$(od -An -tx1 -N4 "${loader}" | tr -d ' \n')" == "4c445220" ]] || {
    echo "Unexpected Rockchip download-loader header." >&2
    exit 1
}
[[ "$(od -An -tx1 -N4 "${idbloader}" | tr -d ' \n')" == "524b4e53" ]] || {
    echo "Unexpected Rockchip new-IDB header." >&2
    exit 1
}
[[ "$(od -An -tx1 -N4 "${fit}" | tr -d ' \n')" == "d00dfeed" ]] || {
    echo "Unexpected U-Boot FIT header." >&2
    exit 1
}
[[ "$(stat -c %s "${idbloader}")" -le $((16384 * 512 - 64 * 512)) ]] || {
    echo "IDB loader overlaps the FIT offset used by renas." >&2
    exit 1
}
[[ "$(stat -c %s "${fit}")" -le $((16 * 1024 * 1024 - 16384 * 512)) ]] || {
    echo "FIT overlaps the BOOTFS partition used by renas." >&2
    exit 1
}
[[ -s "${uboot_dtb}" ]] || {
    echo "The official build did not produce u-boot.dtb." >&2
    exit 1
}
[[ "$(fdtget -t s "${uboot_dtb}" / model)" == "Embedfire LubanCat-5" ]] || {
    echo "Unexpected model in the built U-Boot DTB." >&2
    exit 1
}
uboot_compatible="$(fdtget -t s "${uboot_dtb}" / compatible)"
[[ " ${uboot_compatible} " == *" rockchip,rk3588-lubancat-5 "* ]] || {
    echo "The built U-Boot DTB is not compatible with LubanCat-5." >&2
    exit 1
}

fit_listing="$("${uboot_tree}/tools/mkimage" -l "${fit}")"
for expected_line in \
    "FIT description: FIT Image with ATF/OP-TEE/U-Boot/MCU" \
    " Image 0 (uboot)" \
    " Image 1 (atf-1)" \
    " Image 4 (optee)" \
    " Image 5 (fdt)" \
    " Default Configuration: 'conf'" \
    " Configuration 0 (conf)" \
    "  Description:  rk3588-lubancat-5-pcie"; do
    grep -Fx "${expected_line}" <<<"${fit_listing}" >/dev/null || {
        echo "Missing expected FIT structure: ${expected_line}" >&2
        exit 1
    }
done

destination="${UBOOT_OUTPUT_DIR:-${repo_root}/out/lubancat-5/u-boot}"
mkdir -p "${destination}"
install -m 0644 "${loader}" "${destination}/rk3588_spl_loader_v1.18.113.bin"
install -m 0644 "${idbloader}" "${destination}/idbloader.img"
install -m 0644 "${fit}" "${destination}/uboot.img"
(
    cd "${destination}"
    sha256sum rk3588_spl_loader_v1.18.113.bin idbloader.img uboot.img
)
