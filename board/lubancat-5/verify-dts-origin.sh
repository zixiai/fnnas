#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
# shellcheck source=sources.env
source "${script_dir}/sources.env"

dts_source_tree="${DTS_SOURCE_TREE:-${repo_root}/../linux-6.18.y}"
dts_source_file="${dts_source_tree}/arch/arm64/boot/dts/rockchip/rk3588-lubancat-5.dts"
[[ -f "${dts_source_file}" ]] || {
    echo "Missing LubanCat-5 V1 source: ${dts_source_file}" >&2
    exit 1
}

for command_name in curl sha256sum awk diff; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        echo "Missing required command: ${command_name}" >&2
        exit 1
    }
done

temporary_root="$(mktemp -d)"
trap 'rm -rf -- "${temporary_root}"' EXIT

mainline_url="${MAINLINE_DTS_REPOSITORY}/plain/arch/arm64/boot/dts/rockchip/rk3588-lubancat-5-btb.dtsi?id=${MAINLINE_DTS_COMMIT}"
v1_url="https://raw.githubusercontent.com/LubanCat/kernel/${LUBANCAT_KERNEL_COMMIT}/arch/arm64/boot/dts/rockchip/rk3588-lubancat-5.dts"

curl -fsSL "${mainline_url}" -o "${temporary_root}/mainline.dtsi"
curl -fsSL "${v1_url}" -o "${temporary_root}/vendor-v1.dts"

printf '%s  %s\n' "${MAINLINE_BTB_SHA256}" "${temporary_root}/mainline.dtsi" | sha256sum -c -
printf '%s  %s\n' "${LUBANCAT_V1_DTS_SHA256}" "${temporary_root}/vendor-v1.dts" | sha256sum -c -

awk '
BEGIN { skip = 0 }
/^\tcompatible = "embedfire,lubancat-5-btb"/ { next }
/^&(can[12]|rknn_core_[012]|rknn_mmu_[012]) \{/ { skip = 1; next }
skip && /^};$/ { skip = 0; next }
!skip {
    gsub(/vcc4v0_sys/, "vcc5v0_sys")
    gsub(/vdd_gpu_s0: dcdc-reg1/, "vdd_gpu_s0: vdd_gpu_mem_s0: dcdc-reg1")
    gsub(/vdd_vdenc_s0: dcdc-reg4/, "vdd_vdenc_s0: vdd_vdenc_mem_s0: dcdc-reg4")
    print
}
' "${temporary_root}/mainline.dtsi" | awk '
NF { blank = 0; print; next }
!blank { blank = 1; print }
' > "${temporary_root}/expected.dtsi"

awk '
/^\/ \{$/ { started = 1 }
started { print }
' "${temporary_root}/expected.dtsi" > "${temporary_root}/expected-body.dtsi"

awk '
/^\/\* BEGIN LUBANCAT-5 V1 BTB BACKPORT \*\/$/ { capture = 1; next }
/^\/\* END LUBANCAT-5 V1 BTB BACKPORT \*\/$/ { capture = 0; found = 1; next }
capture && /^\/ \{$/ { started = 1 }
capture && started { print }
END { if (!found) exit 1 }
' "${dts_source_file}" > "${temporary_root}/actual-body.dtsi"

diff -u "${temporary_root}/expected-body.dtsi" \
    "${temporary_root}/actual-body.dtsi"
echo "Pinned upstream sources and the inlined LubanCat-5 V1 BTB backport match."
