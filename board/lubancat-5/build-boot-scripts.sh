#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
# shellcheck source=sources.env
source "${script_dir}/sources.env"
export SOURCE_DATE_EPOCH="${UBOOT_SOURCE_DATE_EPOCH}"
mkimage="${MKIMAGE:-}"
for command_name in cmp dd install mktemp od python3 stat tr; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        echo "Missing required command: ${command_name}" >&2
        exit 1
    }
done


if [[ -z "${mkimage}" ]]; then
    mkimage="$(command -v mkimage || true)"
fi
[[ -n "${mkimage}" && -x "${mkimage}" ]] || {
    echo "Missing mkimage. Install u-boot-tools or set MKIMAGE=/path/to/mkimage." >&2
    exit 1
}

for board in lubancat-5; do
    bootfs="${BOOTFS_OUTPUT_DIR:-${repo_root}/out/lubancat-5/bootfs}"
    mkdir -p "${bootfs}"
    source_script="${script_dir}/boot.cmd"
    target_command="${bootfs}/boot.cmd"
    target_script="${bootfs}/boot.scr"
    install -m 0644 "${source_script}" "${target_command}"
    temporary_script="$(mktemp)"

    trap 'rm -f -- "${temporary_script}"' EXIT
    "${mkimage}" -C none -A arm -T script -d "${source_script}" "${temporary_script}" >/dev/null
    # Rockchip's vendor host mkimage writes 0xffffffff after the script
    # length, while the matching board-side source() still scans for a zero
    # terminator. Normalize that one word and refresh both legacy CRC32s.
    python3 - "${temporary_script}" "${source_script}" <<'PY'
import binascii
from pathlib import Path
import struct
import sys

image_path = Path(sys.argv[1])
source_path = Path(sys.argv[2])
image = bytearray(image_path.read_bytes())
source = source_path.read_bytes()

if len(image) != 72 + len(source):
    raise SystemExit("unexpected U-Boot script image size")
if image[:4] != b"\x27\x05\x19\x56":
    raise SystemExit("unexpected U-Boot legacy image magic")
if struct.unpack_from(">I", image, 64)[0] != len(source):
    raise SystemExit("unexpected U-Boot script length")
if image[68:72] not in (b"\x00" * 4, b"\xff" * 4):
    raise SystemExit("unexpected U-Boot script length-table terminator")
if image[72:] != source:
    raise SystemExit("U-Boot script payload differs from boot.cmd")

image[68:72] = b"\x00" * 4
struct.pack_into(">I", image, 24, binascii.crc32(image[64:]) & 0xffffffff)
struct.pack_into(">I", image, 4, 0)
struct.pack_into(">I", image, 4, binascii.crc32(image[:64]) & 0xffffffff)
image_path.write_bytes(image)
PY
    # Legacy script images use the 64-byte image header followed by an
    # 8-byte zero-terminated script-length table before the script payload.
    [[ "$(stat -c %s "${temporary_script}")" -eq $((72 + $(stat -c %s "${source_script}"))) ]] || {
        echo "Unexpected U-Boot script size for ${board}." >&2
        exit 1
    }
    [[ "$(od -An -tx1 -N4 -j68 "${temporary_script}" | tr -d ' \n')" == "00000000" ]] || {
        echo "U-Boot script length table is not zero-terminated for ${board}." >&2
        exit 1
    }
    dd if="${temporary_script}" bs=1 skip=72 status=none | cmp - "${source_script}"
    install -m 0644 "${temporary_script}" "${target_script}"
    rm -f -- "${temporary_script}"
    trap - EXIT
    echo "Generated ${target_script}"
done
