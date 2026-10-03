#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this uninstaller as root." >&2
    exit 1
fi

src_dir=/usr/local/share/lubancat-5-boot
hook=/etc/kernel/postinst.d/zzzz-lubancat-5-restore

rm -f -- "$hook"
rm -f -- \
    "$src_dir/rk3588-lubancat-5.dtb" \
    "$src_dir/armbianEnv.txt" \
    "$src_dir/boot.cmd" \
    "$src_dir/boot.scr"
rmdir "$src_dir" 2>/dev/null || true

echo "Removed the optional LubanCat-5 kernel post-install boot-file guard."
echo "The current /boot files and /var/log/lubancat5-boot-restore.log were preserved."
