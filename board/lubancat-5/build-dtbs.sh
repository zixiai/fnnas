#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
# shellcheck source=sources.env
source "${script_dir}/sources.env"

for command_name in git cpp dtc fdtget sha256sum install awk sed; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        echo "Missing required command: ${command_name}" >&2
        exit 1
    }
done

temporary_root=""
kernel_tree="${KERNEL_TREE:-}"
if [[ -z "${kernel_tree}" ]]; then
    temporary_root="$(mktemp -d)"
    trap 'rm -rf -- "${temporary_root}"' EXIT
    kernel_tree="${temporary_root}/linux"
    git init -q "${kernel_tree}"
    git -C "${kernel_tree}" remote add origin "${KERNEL_REPOSITORY}"
    git -C "${kernel_tree}" fetch -q --depth=1 origin "${KERNEL_COMMIT}"
    git -C "${kernel_tree}" checkout -q --detach FETCH_HEAD
fi

dts_source_tree="${DTS_SOURCE_TREE:-${repo_root}/../linux-6.18.y}"
dts_source_dir="${dts_source_tree}/arch/arm64/boot/dts/rockchip"
source_files=(
    rk3588-lubancat-5.dts
    rk3588s-ip.dtsi
    rk3588s-ip-supply.dtsi
    rk3588s-vpu.dtsi
    rk3588s-gpu.dtsi
    rk3588s-npu.dtsi
    rk3588s-crypto.dtsi
)
for source_file in "${source_files[@]}"; do
    [[ -f "${dts_source_dir}/${source_file}" ]] || {
        echo "Missing LubanCat-5 source ${dts_source_dir}/${source_file}." >&2
        echo "Set DTS_SOURCE_TREE to the linux-6.18.y Fork containing the board DTS." >&2
        exit 1
    }
done

vpu_dtsi_sha256="$(sha256sum "${dts_source_dir}/rk3588s-vpu.dtsi" | awk '{ print $1 }')"
[[ "${vpu_dtsi_sha256}" == "${ROCKCHIP_BSP_VPU_DTSI_SHA256}" ]] || {
    echo "rk3588s-vpu.dtsi does not match ${ROCKCHIP_BSP_DTSI_COMMIT}." >&2
    exit 1
}
gpu_dtsi_sha256="$(sha256sum "${dts_source_dir}/rk3588s-gpu.dtsi" | awk '{ print $1 }')"
[[ "${gpu_dtsi_sha256}" == "${ROCKCHIP_BSP_GPU_DTSI_SHA256}" ]] || {
    echo "rk3588s-gpu.dtsi does not match ${ROCKCHIP_BSP_DTSI_COMMIT}." >&2
    exit 1
}
npu_dtsi_sha256="$(sha256sum "${dts_source_dir}/rk3588s-npu.dtsi" | awk '{ print $1 }')"
[[ "${npu_dtsi_sha256}" == "${ROCKCHIP_BSP_NPU_DTSI_SHA256}" ]] || {
    echo "rk3588s-npu.dtsi does not match ${ROCKCHIP_BSP_DTSI_COMMIT}." >&2
    exit 1
}

actual_kernel_commit="$(git -C "${kernel_tree}" rev-parse HEAD)"
[[ "${actual_kernel_commit}" == "${KERNEL_COMMIT}" ]] || {
    echo "Kernel tree commit ${actual_kernel_commit} does not match ${KERNEL_COMMIT}." >&2
    exit 1
}

dts_dir="${kernel_tree}/arch/arm64/boot/dts/rockchip"
include_dir="${kernel_tree}/scripts/dtc/include-prefixes"
[[ -d "${dts_dir}" && -d "${include_dir}" ]] || {
    echo "The kernel tree is incomplete: ${kernel_tree}" >&2
    exit 1
}

build_dir="${BUILD_DIR:-${temporary_root:-${repo_root}/out/lubancat-5}/dtb-build}"
output_dir="${DTB_OUTPUT_DIR:-${repo_root}/out/lubancat-5/dtb}"
source_staging_dir="${build_dir}/source"
mkdir -p "${source_staging_dir}"
for source_file in "${source_files[@]}"; do
    install -m 0644 "${dts_source_dir}/${source_file}" \
        "${source_staging_dir}/${source_file}"
done

clock_header="${include_dir}/dt-bindings/clock/rockchip,rk3588-cru.h"
grep -Fq 'I2S0_8CH_MCLKOUT_TO_IO' \
    "${source_staging_dir}/rk3588-lubancat-5.dts" || {
    echo "The formal LubanCat-5 DTS does not use the RK3588 MCLK-to-IO gate." >&2
    exit 1
}
# The locked FnNAS 6.18.18 packages predate the RK3588 SYS_GRF MCLK-to-IO
# clock gates.  Compile their transition DTB with the older internal clock ID;
# the board-specific boot script opens SYS_GRF_SOC_CON6[0] before Linux starts.
if ! grep -Eq '^#define[[:space:]]+I2S0_8CH_MCLKOUT_TO_IO[[:space:]]' "${clock_header}"; then
    sed -i 's/I2S0_8CH_MCLKOUT_TO_IO/I2S0_8CH_MCLKOUT/g' \
        "${source_staging_dir}/rk3588-lubancat-5.dts"
fi

compile_dtb() {
    local source_file="$1"
    local output_file="$2"

    cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
        -I "${source_staging_dir}" \
        -I "${dts_dir}" \
        -I "${include_dir}" \
        "${source_staging_dir}/${source_file}" "${build_dir}/${source_file%.dts}.preprocessed.dts"
    dtc -@ -I dts -O dtb -o "${build_dir}/${output_file}" \
        "${build_dir}/${source_file%.dts}.preprocessed.dts"
}

compile_dtb rk3588-lubancat-5.dts rk3588-lubancat-5.dtb

validate_dtb() {
    local dtb="$1"
    local expected_model="$2"
    local expected_compatible="$3"
    local model compatible

    model="$(fdtget -t s "${dtb}" / model)"
    compatible="$(fdtget -t s "${dtb}" / compatible)"
    [[ "${model}" == "${expected_model}" ]] || {
        echo "Unexpected model in ${dtb}: ${model}" >&2
        exit 1
    }
    [[ "${compatible}" == "${expected_compatible}" ]] || {
        echo "Unexpected compatible list in ${dtb}: ${compatible}" >&2
        exit 1
    }

    for alias_name in ethernet0 ethernet1 mmc0 mmc1 serial2; do
        fdtget -t s "${dtb}" /aliases "${alias_name}" >/dev/null
    done

    for symbol_name in es8388 gmac0 gmac1 hdmi0 hdmi1 hdptxphy0 hdptxphy1 \
        i2s0_8ch i2s5_8ch i2s6_8ch pcie2x1l0 pcie2x1l2 pcie3x4 pwm4 \
        sdhci sdmmc usbdp_phy0 usb_host0_xhci usb_host1_xhci vop; do
        local node_path node_status
        node_path="$(fdtget -t s "${dtb}" /__symbols__ "${symbol_name}")"
        node_status="$(fdtget -t s "${dtb}" "${node_path}" status 2>/dev/null || true)"
        [[ -z "${node_status}" || "${node_status}" == "okay" ]] || {
            echo "${symbol_name} is not enabled in ${dtb}." >&2
            exit 1
        }
    done

    local usbc_path connector_path pcie_path
    usbc_path="$(fdtget -t s "${dtb}" /__symbols__ usbc0)"
    connector_path="${usbc_path}/connector"
    [[ "$(fdtget -t s "${dtb}" "${usbc_path}" compatible)" == "fcs,fusb302" &&
       "$(fdtget -t s "${dtb}" "${connector_path}" compatible)" == "usb-c-connector" &&
       "$(fdtget -t s "${dtb}" "${connector_path}" data-role)" == "dual" &&
       "$(fdtget -t s "${dtb}" "${connector_path}" power-role)" == "dual" ]] || {
        echo "Unexpected LubanCat-5 USB Type-C description in ${dtb}." >&2
        exit 1
    }
    [[ "$(fdtget -t s "${dtb}" /sound compatible)" == "simple-audio-card" &&
       "$(fdtget -t s "${dtb}" /adc-keys compatible)" == "adc-keys" ]] || {
        echo "Unexpected LubanCat-5 audio or recovery-key description in ${dtb}." >&2
        exit 1
    }

    local cru_path cru_phandle expected_mclk_id property_name
    local -a codec_clocks codec_assigned_clocks
    expected_mclk_id="$(awk '$1 == "#define" && $2 == "I2S0_8CH_MCLKOUT" { print $3 }' "${clock_header}")"
    cru_path="$(fdtget -t s "${dtb}" /__symbols__ cru)"
    cru_phandle="$(fdtget -t u "${dtb}" "${cru_path}" phandle)"
    node_path="$(fdtget -t s "${dtb}" /__symbols__ es8388)"
    read -r -a codec_clocks <<<"$(fdtget -t u "${dtb}" "${node_path}" clocks)"
    read -r -a codec_assigned_clocks <<<"$(fdtget -t u "${dtb}" "${node_path}" assigned-clocks)"
    [[ "${codec_clocks[*]}" == "${cru_phandle} ${expected_mclk_id}" &&
       "${codec_assigned_clocks[*]}" == "${cru_phandle} ${expected_mclk_id}" ]] || {
        echo "Unexpected LubanCat-5 ES8388 MCLK routing in ${dtb}." >&2
        exit 1
    }
    for property_name in simple-audio-card,bitclock-master simple-audio-card,frame-master; do
        if fdtget -t u "${dtb}" /sound "${property_name}" >/dev/null 2>&1; then
            echo "Unexpected codec clock-provider property ${property_name} in ${dtb}." >&2
            exit 1
        fi
    done
    [[ "$(fdtget -t s "${dtb}" /hdmi0-con compatible)" == "hdmi-connector" &&
       "$(fdtget -t s "${dtb}" /hdmi1-con compatible)" == "hdmi-connector" ]] || {
        echo "Unexpected LubanCat-5 HDMI connector description in ${dtb}." >&2
        exit 1
    }
    for symbol_name in hdmi0 hdmi1; do
        node_path="$(fdtget -t s "${dtb}" /__symbols__ "${symbol_name}")"
        fdtget -t u "${dtb}" "${node_path}" frl-enable-gpios >/dev/null
    done

    local hdmi1_path pin_path index
    local -a hdmi1_pinctrl expected_hdmi1_pinctrl=(
        hdmim2_tx1_cec
        hdmim0_tx1_hpd
        hdmim1_tx1_scl
        hdmim1_tx1_sda
    )
    hdmi1_path="$(fdtget -t s "${dtb}" /__symbols__ hdmi1)"
    read -r -a hdmi1_pinctrl <<<"$(fdtget -t u "${dtb}" "${hdmi1_path}" pinctrl-0)"
    [[ "${#hdmi1_pinctrl[@]}" -eq "${#expected_hdmi1_pinctrl[@]}" ]] || {
        echo "Unexpected LubanCat-5 HDMI1 pinctrl entry count in ${dtb}." >&2
        exit 1
    }
    for index in "${!expected_hdmi1_pinctrl[@]}"; do
        pin_path="$(fdtget -t s "${dtb}" /__symbols__ "${expected_hdmi1_pinctrl[index]}")"
        [[ "${hdmi1_pinctrl[index]}" == "$(fdtget -t u "${dtb}" "${pin_path}" phandle)" ]] || {
            echo "Unexpected LubanCat-5 HDMI1 pinctrl entry ${index} in ${dtb}." >&2
            exit 1
        }
    done
    for symbol_name in pcie2x1l0 pcie2x1l2; do
        pcie_path="$(fdtget -t s "${dtb}" /__symbols__ "${symbol_name}")"
        fdtget -t u "${dtb}" "${pcie_path}" reset-gpios >/dev/null
        fdtget -t u "${dtb}" "${pcie_path}" vpcie3v3-supply >/dev/null
    done

    local expected_node_compatible expected_vendor_compatible
    local -a vendor_nodes=(
        'mpp_srv:rockchip,mpp-service'
        'rga3_core0:rockchip,rga3_core0'
        'rga3_core1:rockchip,rga3_core1'
        'rga2:rockchip,rga2_core0'
        'rkvdec0:rockchip,rkv-decoder-v2'
        'rkvdec1:rockchip,rkv-decoder-v2'
        'rkvenc0:rockchip,rkv-encoder-v2-core'
        'rkvenc1:rockchip,rkv-encoder-v2-core'
        'rknpu:rockchip,rk3588-rknpu'
    )
    for expected_node_compatible in "${vendor_nodes[@]}"; do
        symbol_name="${expected_node_compatible%%:*}"
        expected_vendor_compatible="${expected_node_compatible#*:}"
        node_path="$(fdtget -t s "${dtb}" /__symbols__ "${symbol_name}")"
        [[ "$(fdtget -t s "${dtb}" "${node_path}" compatible)" == "${expected_vendor_compatible}" &&
           "$(fdtget -t s "${dtb}" "${node_path}" status)" == "okay" ]] || {
            echo "Unexpected ${symbol_name} BSP binding in ${dtb}." >&2
            exit 1
        }
    done

    local gpu_path gpu_supply_path gpu_supply_phandle
    local gpu_mem_supply_path gpu_mem_supply_phandle gpu_opp_path gpu_opp_phandle
    gpu_path="$(fdtget -t s "${dtb}" /__symbols__ gpu)"
    gpu_supply_path="$(fdtget -t s "${dtb}" /__symbols__ vdd_gpu_s0)"
    gpu_supply_phandle="$(fdtget -t u "${dtb}" "${gpu_supply_path}" phandle)"
    gpu_mem_supply_path="$(fdtget -t s "${dtb}" /__symbols__ vdd_gpu_mem_s0)"
    gpu_mem_supply_phandle="$(fdtget -t u "${dtb}" "${gpu_mem_supply_path}" phandle)"
    gpu_opp_path="$(fdtget -t s "${dtb}" /__symbols__ gpu_opp_table_panthor)"
    gpu_opp_phandle="$(fdtget -t u "${dtb}" "${gpu_opp_path}" phandle)"
    [[ "$(fdtget -t s "${dtb}" "${gpu_path}" compatible)" == \
           "rockchip,rk3588-mali-csf arm,mali-valhall" &&
       "$(fdtget -t s "${dtb}" "${gpu_path}" status)" == "okay" &&
       "$(fdtget -t s "${dtb}" "${gpu_path}" clock-names)" == \
           "clk_mali clk_gpu_coregroup clk_gpu_stacks clk_gpu" &&
       "$(fdtget -t s "${dtb}" "${gpu_path}" interrupt-names)" == \
           "GPU MMU JOB" &&
       "${gpu_mem_supply_path}" == "${gpu_supply_path}" &&
       "$(fdtget -t u "${dtb}" "${gpu_path}" mali-supply)" == "${gpu_supply_phandle}" &&
       "$(fdtget -t u "${dtb}" "${gpu_path}" mem-supply)" == "${gpu_mem_supply_phandle}" &&
       "$(fdtget -t u "${dtb}" "${gpu_path}" upthreshold)" == "60" &&
       "$(fdtget -t u "${dtb}" "${gpu_path}" downdifferential)" == "30" &&
       "$(fdtget -t u "${dtb}" "${gpu_path}" operating-points-v2)" == "${gpu_opp_phandle}" ]] || {
        echo "Unexpected RK3588 Mali CSF binding in ${dtb}." >&2
        exit 1
    }

    local -a vendor_support_nodes=(
        rknpu_mmu
        rga3_0_mmu rga3_1_mmu
        vdpu vdpu_mmu
        jpegd jpegd_mmu jpege_ccu
        jpege0 jpege0_mmu jpege1 jpege1_mmu
        jpege2 jpege2_mmu jpege3 jpege3_mmu
        rkvenc_ccu rkvenc0_mmu rkvenc1_mmu
        rkvdec_ccu rkvdec0_mmu rkvdec1_mmu
        av1d av1d_mmu
    )
    for symbol_name in "${vendor_support_nodes[@]}"; do
        node_path="$(fdtget -t s "${dtb}" /__symbols__ "${symbol_name}")"
        [[ "$(fdtget -t s "${dtb}" "${node_path}" status)" == "okay" ]] || {
            echo "Rockchip BSP support node ${symbol_name} is not enabled in ${dtb}." >&2
            exit 1
        }
    done

    node_path="$(fdtget -t s "${dtb}" /__symbols__ crypto)"
    [[ "$(fdtget -t s "${dtb}" "${node_path}" status)" == "disabled" ]] || {
        echo "Unsupported RK3588 crypto node is not disabled in ${dtb}." >&2
        exit 1
    }
    node_path="$(fdtget -t s "${dtb}" /__symbols__ rng)"
    [[ "$(fdtget -t s "${dtb}" "${node_path}" status)" == "okay" ]] || {
        echo "Rockchip RNG node is not enabled in ${dtb}." >&2
        exit 1
    }

    node_path="$(fdtget -t s "${dtb}" /__symbols__ rkvenc1_mmu)"
    [[ "$(fdtget -t s "${dtb}" "${node_path}" clock-names)" == "aclk iface" ]] || {
        echo "Unexpected RK3588 VENC1 IOMMU clock names in ${dtb}." >&2
        exit 1
    }
    if fdtget -t s "${dtb}" "${node_path}" lock-names >/dev/null 2>&1; then
        echo "Invalid lock-names property remains on RK3588 VENC1 IOMMU." >&2
        exit 1
    fi

    local system_sram_path codec_sram_path codec_sram_phandle decoder_path index
    system_sram_path="$(fdtget -t s "${dtb}" /__symbols__ system_sram2)"
    if fdtget -l "${dtb}" "${system_sram_path}" | grep -Eq '^rkvdec-sram@'; then
        echo "Overlapping BSP RKVDEC SRAM pools remain in ${dtb}." >&2
        exit 1
    fi
    for index in 0 1; do
        decoder_path="$(fdtget -t s "${dtb}" /__symbols__ "rkvdec${index}")"
        codec_sram_path="$(fdtget -t s "${dtb}" /__symbols__ "vdec${index}_sram")"
        codec_sram_phandle="$(fdtget -t u "${dtb}" "${codec_sram_path}" phandle)"
        [[ "$(fdtget -t u "${dtb}" "${decoder_path}" rockchip,sram)" == \
               "${codec_sram_phandle}" ]] || {
            echo "RKVDEC${index} does not reuse the base codec SRAM pool in ${dtb}." >&2
            exit 1
        }
    done

    local fan_path fan_phandle pwm4_path pwm4_phandle
    local -a cooling_levels pwm_specifier
    fan_path="$(fdtget -t s "${dtb}" /__symbols__ fan)"
    pwm4_path="$(fdtget -t s "${dtb}" /__symbols__ pwm4)"
    fan_phandle="$(fdtget -t u "${dtb}" "${fan_path}" phandle)"
    pwm4_phandle="$(fdtget -t u "${dtb}" "${pwm4_path}" phandle)"
    [[ "$(fdtget -t s "${dtb}" "${fan_path}" compatible)" == "pwm-fan" ]] || {
        echo "LubanCat-5 fan is not bound to pwm-fan in ${dtb}." >&2
        exit 1
    }
    read -r -a cooling_levels <<<"$(fdtget -t u "${dtb}" "${fan_path}" cooling-levels)"
    [[ "${cooling_levels[*]}" == "0 130 160 190 200" ]] || {
        echo "Unexpected LubanCat-5 fan cooling levels in ${dtb}." >&2
        exit 1
    }
    [[ "$(fdtget -t u "${dtb}" "${fan_path}" fan-stop-to-start-percent)" == "79" &&
       "$(fdtget -t u "${dtb}" "${fan_path}" fan-stop-to-start-us)" == "200000" ]] || {
        echo "Unexpected LubanCat-5 fan start pulse in ${dtb}." >&2
        exit 1
    }
    read -r -a pwm_specifier <<<"$(fdtget -t u "${dtb}" "${fan_path}" pwms)"
    [[ "${#pwm_specifier[@]}" -eq 4 &&
       "${pwm_specifier[0]}" == "${pwm4_phandle}" &&
       "${pwm_specifier[1]}" == "0" &&
       "${pwm_specifier[2]}" == "50000" &&
       "${pwm_specifier[3]}" == "0" ]] || {
        echo "Unexpected LubanCat-5 PWM4 fan specifier in ${dtb}." >&2
        exit 1
    }

    local trip_path map_path trip_phandle
    local -a expected_temperatures=(40000 50000 60000 70000)
    for index in 0 1 2 3; do
        trip_path="/thermal-zones/package-thermal/trips/package-fan${index}"
        map_path="/thermal-zones/package-thermal/cooling-maps/map${index}"
        trip_phandle="$(fdtget -t u "${dtb}" "${trip_path}" phandle)"
        [[ "$(fdtget -t u "${dtb}" "${trip_path}" temperature)" == "${expected_temperatures[index]}" &&
           "$(fdtget -t u "${dtb}" "${trip_path}" hysteresis)" == "3000" &&
           "$(fdtget -t s "${dtb}" "${trip_path}" type)" == "active" &&
           "$(fdtget -t u "${dtb}" "${map_path}" trip)" == "${trip_phandle}" &&
           "$(fdtget -t u "${dtb}" "${map_path}" cooling-device)" == "${fan_phandle} $((index + 1)) $((index + 1))" ]] || {
            echo "Unexpected LubanCat-5 fan thermal map ${index} in ${dtb}." >&2
            exit 1
        }
    done
}

validate_dtb "${build_dir}/rk3588-lubancat-5.dtb" \
    "EmbedFire LubanCat 5" \
    "embedfire,lubancat-5 embedfire,lubancat-5-btb rockchip,rk3588"

mkdir -p "${output_dir}"
install -m 0644 "${build_dir}/rk3588-lubancat-5.dtb" "${output_dir}/rk3588-lubancat-5.dtb"

sha256sum "${output_dir}/rk3588-lubancat-5.dtb"
