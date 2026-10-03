#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this installer as root." >&2
    exit 1
fi

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
boot_root="${BOOT_ROOT:-/boot}"
src_dir=/usr/local/share/lubancat-5-boot
hook=/etc/kernel/postinst.d/zzzz-lubancat-5-restore

require_file()
{
    [ -s "$1" ] || {
        echo "Missing required boot file: $1" >&2
        exit 1
    }
}

require_file "$boot_root/dtb/rockchip/rk3588-lubancat-5.dtb"
require_file "$boot_root/armbianEnv.txt"
require_file "$boot_root/boot.cmd"
require_file "$boot_root/boot.scr"
require_file "$script_dir/zzzz-lubancat-5-restore"

install -d -m 0755 "$src_dir" /etc/kernel/postinst.d
install -m 0644 \
    "$boot_root/dtb/rockchip/rk3588-lubancat-5.dtb" \
    "$src_dir/rk3588-lubancat-5.dtb"
install -m 0644 "$boot_root/armbianEnv.txt" "$src_dir/armbianEnv.txt"
install -m 0644 "$boot_root/boot.cmd" "$src_dir/boot.cmd"
install -m 0644 "$boot_root/boot.scr" "$src_dir/boot.scr"
install -m 0755 "$script_dir/zzzz-lubancat-5-restore" "$hook"

"$hook" manual-install

echo "Installed the optional LubanCat-5 kernel post-install boot-file guard."
echo "Protected copies: $src_dir"
echo "Hook: $hook"
echo "Log: /var/log/lubancat5-boot-restore.log"
sha256sum "$src_dir"/*
