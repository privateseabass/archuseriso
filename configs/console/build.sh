#!/bin/bash

set -e -u

iso_name=archuseriso-console
iso_label=AUIO
iso_publisher=
iso_application="Archuseriso Console Live/Rescue medium"
iso_version=$(date +%m%d)
install_dir=arch
work_dir=work
out_dir=out
gpg_key=
comp_type=zstd

verbose=""
script_path=$(readlink -f ${0%/*})

umask 0022

_usage ()
{
    echo "usage ${0} [options]"
    echo
    echo " General options:"
    echo "    -N <iso_name>      Set an iso filename (prefix)"
    echo "                        Default: ${iso_name}"
    echo "    -V <iso_version>   Set an iso version (in filename)"
    echo "                        Default: ${iso_version}"
    echo "    -L <iso_label>     Set an iso label (disk label)"
    echo "                        Default: ${iso_label}"
    echo "    -P <publisher>     Set a publisher for the disk"
    echo "                        Default: '${iso_publisher}'"
    echo "    -A <application>   Set an application name for the disk"
    echo "                        Default: '${iso_application}'"
    echo "    -D <install_dir>   Set an install_dir (directory inside iso)"
    echo "                        Default: ${install_dir}"
    echo "    -w <work_dir>      Set the working directory"
    echo "                        Default: ${work_dir}"
    echo "    -o <out_dir>       Set the output directory"
    echo "                        Default: ${out_dir}"
    echo "    -c <comp_type>     Set SquashFS compression type (gzip, lzma, lzo, xz, zstd)"
    echo "                       Default: ${comp_type}"
    echo "    -v                 Enable verbose output"
    echo "    -h                 This help message"
    exit ${1}
}

# airootfs extra cleanup
_cleanup_airootfs() {
    local _cleanlist=(  ${work_dir}/x86_64/airootfs/root/.cache/
                        ${work_dir}/x86_64/airootfs/root/.gnupg/
                        ${work_dir}/x86_64/airootfs/root/customize_airootfs.sh
                        ${work_dir}/x86_64/airootfs/var/lib/systemd/catalog/database
                     )

    for file_or_dir in "${cleanlist[@]}"; do
      [[ -e "${file_or_dir}" ]] && rm -r "${file_or_dir}"
    done
}

# Helper function to run make_*() only one time per architecture.
run_once() {
    if [[ ! -e ${work_dir}/build.${1} ]]; then
        $1
        touch ${work_dir}/build.${1}
    fi
}

# Setup custom pacman.conf with current cache directories.
make_pacman_conf() {
    local _cache_dirs
    _cache_dirs=($(pacman -v 2>&1 | grep '^Cache Dirs:' | sed 's/Cache Dirs:\s*//g'))
    sed -r "s|^#?\\s*CacheDir.+|CacheDir = $(echo -n ${_cache_dirs[@]})|g" ${script_path}/pacman.conf > ${work_dir}/pacman.conf
}

# Base installation, plus needed packages (airootfs)
make_basefs() {
    mkarchiso ${verbose} -w "${work_dir}/x86_64" -C "${work_dir}/pacman.conf" -D "${install_dir}" init
    mkarchiso ${verbose} -w "${work_dir}/x86_64" -C "${work_dir}/pacman.conf" -D "${install_dir}" -p "haveged intel-ucode amd-ucode memtest86+ mkinitcpio-nfs-utils nbd zsh" install
}

# Additional packages (airootfs)
make_packages() {
    mkarchiso ${verbose} -w "${work_dir}/x86_64" -C "${work_dir}/pacman.conf" -D "${install_dir}" -p "$(grep -Ehv '^#|^$' ${script_path}/packages{,-console}.x86_64 | sed ':a;N;$!ba;s/\n/ /g')" install
}

# airootfs user packages
# installs packages located in path provided directory
make_packages_local() {
    local _pkglocal
    if [[ -n "${AUI_USERPKGDIR:-}" && -d "${AUI_USERPKGDIR:-}" ]]; then
        _pkglocal+=($(find "${AUI_USERPKGDIR}" -maxdepth 1 \( -name "*.pkg.tar.xz" -o -name "*.pkg.tar.zst" \) ))
    fi

    if [[ ${_pkglocal[@]} ]]; then
        mkarchiso ${verbose} -w "${work_dir}/x86_64" -C "${work_dir}/pacman.conf" -D "${install_dir}" -r 'echo "Installing user packages"' run
        echo "      ${_pkglocal[@]##*/}"
        unshare --fork --pid unshare --fork --pid pacman -r "${work_dir}/x86_64/airootfs" -U --noconfirm "${_pkglocal[@]}" > /dev/null 2>&1
    fi
}

# Copy mkinitcpio archiso hooks and build initramfs (airootfs)
make_setup_mkinitcpio() {
    local _hook
    mkdir -p ${work_dir}/x86_64/airootfs/etc/initcpio/hooks
    mkdir -p ${work_dir}/x86_64/airootfs/etc/initcpio/install
    for _hook in archiso archiso_shutdown archiso_pxe_common archiso_pxe_nbd archiso_pxe_http archiso_pxe_nfs archiso_loop_mnt; do
        cp /usr/lib/initcpio/hooks/${_hook} ${work_dir}/x86_64/airootfs/etc/initcpio/hooks
        cp /usr/lib/initcpio/install/${_hook} ${work_dir}/x86_64/airootfs/etc/initcpio/install
    done

    # Set cow_spacesize to 50% ram size
    sed -i 's|\(cow_spacesize=\)"256M"|\1"$(( $(awk \x27/MemTotal:/ { print $2 }\x27 /proc/meminfo) / 2 / 1024 ))M"|' \
        ${work_dir}/x86_64/airootfs/etc/initcpio/hooks/archiso

    sed -i "s|/usr/lib/initcpio/|/etc/initcpio/|g" ${work_dir}/x86_64/airootfs/etc/initcpio/install/archiso_shutdown
    cp /usr/lib/initcpio/install/archiso_kms ${work_dir}/x86_64/airootfs/etc/initcpio/install
    cp /usr/lib/initcpio/archiso_shutdown ${work_dir}/x86_64/airootfs/etc/initcpio
    cp -L ${script_path}/mkinitcpio.conf ${work_dir}/x86_64/airootfs/etc/mkinitcpio-archiso.conf

    # Copy configs airootfs
    # 2 stages copy
    # 1st we dereference soft links (archuseriso template soft links). But real airootfs soft
    # links dereference outputs copy errors.
    # 2nd we copy missing airootfs soft links without derefencing
    cp -afL --no-preserve=ownership ${script_path}/airootfs ${work_dir}/x86_64 2> /dev/null
    cp -afTu --no-preserve=ownership ${script_path}/airootfs ${work_dir}/x86_64

    gnupg_fd=
    if [[ ${gpg_key} ]]; then
      gpg --export ${gpg_key} >${work_dir}/gpgkey
      exec 17<>${work_dir}/gpgkey
    fi
    ARCHISO_GNUPG_FD=${gpg_key:+17} mkarchiso ${verbose} -w "${work_dir}/x86_64" -C "${work_dir}/pacman.conf" -D "${install_dir}" -r 'mkinitcpio -c /etc/mkinitcpio-archiso.conf -k /boot/vmlinuz-linux -g /boot/archiso.img' run
    if [[ ${gpg_key} ]]; then
      exec 17<&-
    fi
}

# Customize installation (airootfs)
make_customize_airootfs() {
    cp -L ${script_path}/pacman.conf ${work_dir}/x86_64/airootfs/etc

    curl -o ${work_dir}/x86_64/airootfs/etc/pacman.d/mirrorlist 'https://www.archlinux.org/mirrorlist/?country=all&protocol=http&use_mirror_status=on'

    lynx -dump -nolist 'https://wiki.archlinux.org/index.php/Installation_Guide?action=render' >> ${work_dir}/x86_64/airootfs/root/install.txt

    mkarchiso ${verbose} -w "${work_dir}/x86_64" -C "${work_dir}/pacman.conf" -D "${install_dir}" -r '/root/customize_airootfs.sh' run

    # airootfs extra cleanup
    _cleanup_airootfs
}

# Prepare kernel/initramfs ${install_dir}/boot/
make_boot() {
    mkdir -p ${work_dir}/iso/${install_dir}/boot/x86_64
    cp ${work_dir}/x86_64/airootfs/boot/archiso.img ${work_dir}/iso/${install_dir}/boot/x86_64/archiso.img
    cp ${work_dir}/x86_64/airootfs/boot/vmlinuz-linux ${work_dir}/iso/${install_dir}/boot/x86_64/vmlinuz
}

# Add other aditional/extra files to ${install_dir}/boot/
make_boot_extra() {
    cp ${work_dir}/x86_64/airootfs/boot/memtest86+/memtest.bin ${work_dir}/iso/${install_dir}/boot/memtest
    cp ${work_dir}/x86_64/airootfs/usr/share/licenses/common/GPL2/license.txt ${work_dir}/iso/${install_dir}/boot/memtest.COPYING
    cp ${work_dir}/x86_64/airootfs/boot/intel-ucode.img ${work_dir}/iso/${install_dir}/boot/intel_ucode.img
    cp ${work_dir}/x86_64/airootfs/usr/share/licenses/intel-ucode/LICENSE ${work_dir}/iso/${install_dir}/boot/intel_ucode.LICENSE
    cp ${work_dir}/x86_64/airootfs/boot/amd-ucode.img ${work_dir}/iso/${install_dir}/boot/amd_ucode.img
    cp ${work_dir}/x86_64/airootfs/usr/share/licenses/amd-ucode/LICENSE ${work_dir}/iso/${install_dir}/boot/amd_ucode.LICENSE
}

# Prepare /${install_dir}/boot/syslinux
make_syslinux() {
    _uname_r=$(file -b ${work_dir}/x86_64/airootfs/boot/vmlinuz-linux| awk 'f{print;f=0} /version/{f=1}' RS=' ')
    mkdir -p ${work_dir}/iso/${install_dir}/boot/syslinux
    for _cfg in ${script_path}/syslinux/*.cfg; do
        sed "s|%ARCHISO_LABEL%|${iso_label}|g;
             s|%INSTALL_DIR%|${install_dir}|g" ${_cfg} > ${work_dir}/iso/${install_dir}/boot/syslinux/${_cfg##*/}
    done
    cp -L ${script_path}/syslinux/splash.png ${work_dir}/iso/${install_dir}/boot/syslinux
    cp ${work_dir}/x86_64/airootfs/usr/lib/syslinux/bios/*.c32 ${work_dir}/iso/${install_dir}/boot/syslinux
    cp ${work_dir}/x86_64/airootfs/usr/lib/syslinux/bios/lpxelinux.0 ${work_dir}/iso/${install_dir}/boot/syslinux
    cp ${work_dir}/x86_64/airootfs/usr/lib/syslinux/bios/memdisk ${work_dir}/iso/${install_dir}/boot/syslinux
    mkdir -p ${work_dir}/iso/${install_dir}/boot/syslinux/hdt
    gzip -c -9 ${work_dir}/x86_64/airootfs/usr/share/hwdata/pci.ids > ${work_dir}/iso/${install_dir}/boot/syslinux/hdt/pciids.gz
    gzip -c -9 ${work_dir}/x86_64/airootfs/usr/lib/modules/${_uname_r}/modules.alias > ${work_dir}/iso/${install_dir}/boot/syslinux/hdt/modalias.gz
}

# Prepare /isolinux
make_isolinux() {
    mkdir -p ${work_dir}/iso/isolinux
    sed "s|%INSTALL_DIR%|${install_dir}|g" ${script_path}/isolinux/isolinux.cfg > ${work_dir}/iso/isolinux/isolinux.cfg
    cp ${work_dir}/x86_64/airootfs/usr/lib/syslinux/bios/isolinux.bin ${work_dir}/iso/isolinux/
    cp ${work_dir}/x86_64/airootfs/usr/lib/syslinux/bios/isohdpfx.bin ${work_dir}/iso/isolinux/
    cp ${work_dir}/x86_64/airootfs/usr/lib/syslinux/bios/ldlinux.c32 ${work_dir}/iso/isolinux/
}

# Prepare /EFI
make_efi() {
    mkdir -p ${work_dir}/iso/EFI/boot ${work_dir}/iso/EFI/live
    cp ${work_dir}/x86_64/airootfs/usr/share/refind/refind_x64.efi ${work_dir}/iso/EFI/boot/bootx64.efi
    cp -a ${work_dir}/x86_64/airootfs/usr/share/refind/{drivers_x64,icons}/ ${work_dir}/iso/EFI/boot/

    cp ${work_dir}/x86_64/airootfs/usr/lib/systemd/boot/efi/systemd-bootx64.efi ${work_dir}/iso/EFI/live/livedisk.efi
    cp ${work_dir}/x86_64/airootfs/usr/share/refind/icons/os_arch.png ${work_dir}/iso/EFI/live/livedisk.png

    cp -L ${script_path}/efiboot/boot/refind-usb.conf ${work_dir}/iso/EFI/boot/refind.conf

    mkdir -p ${work_dir}/iso/loader/entries
    cp -L ${script_path}/efiboot/loader/loader.conf ${work_dir}/iso/loader/
    cp ${script_path}/efiboot/loader/entries/archiso-x86_64-usb.conf ${work_dir}/iso/loader/entries/archiso-x86_64.conf
    cp ${script_path}/efiboot/loader/entries/archiso_3_ram-x86_64-usb.conf ${work_dir}/iso/loader/entries/archiso_3_ram-x86_64.conf

    sed -i "s|%ARCHISO_LABEL%|${iso_label}|g;
            s|%INSTALL_DIR%|${install_dir}|g" \
            ${work_dir}/iso/loader/entries/archiso{,_3_ram}-x86_64.conf

    # edk2-shell based UEFI shell
    # shellx64.efi is picked up automatically when on /
    cp /usr/share/edk2-shell/x64/Shell_Full.efi ${work_dir}/iso/shellx64.efi
}

# Prepare efiboot.img::/EFI for "El Torito" EFI boot mode
make_efiboot() {
    mkdir -p ${work_dir}/iso/EFI/archiso
    truncate -s 80M ${work_dir}/iso/EFI/archiso/efiboot.img
    mkfs.fat -n LIVEMEDIUM ${work_dir}/iso/EFI/archiso/efiboot.img

    mkdir -p ${work_dir}/efiboot
    mount ${work_dir}/iso/EFI/archiso/efiboot.img ${work_dir}/efiboot

    mkdir -p ${work_dir}/efiboot/EFI/archiso
    cp ${work_dir}/iso/${install_dir}/boot/x86_64/vmlinuz ${work_dir}/efiboot/EFI/archiso/vmlinuz.efi
    cp ${work_dir}/iso/${install_dir}/boot/x86_64/archiso.img ${work_dir}/efiboot/EFI/archiso/archiso.img

    cp ${work_dir}/iso/${install_dir}/boot/intel_ucode.img ${work_dir}/efiboot/EFI/archiso/intel_ucode.img
    cp ${work_dir}/iso/${install_dir}/boot/amd_ucode.img ${work_dir}/efiboot/EFI/archiso/amd_ucode.img

    mkdir -p ${work_dir}/efiboot/EFI/boot ${work_dir}/efiboot/EFI/live
    cp ${work_dir}/x86_64/airootfs/usr/share/refind/refind_x64.efi ${work_dir}/efiboot/EFI/boot/bootx64.efi
    cp -a ${work_dir}/x86_64/airootfs/usr/share/refind/{drivers_x64,icons}/ ${work_dir}/efiboot/EFI/boot/

    cp ${work_dir}/x86_64/airootfs/usr/lib/systemd/boot/efi/systemd-bootx64.efi ${work_dir}/efiboot/EFI/live/livedvd.efi
    cp ${work_dir}/x86_64/airootfs/usr/share/refind/icons/os_arch.png ${work_dir}/efiboot/EFI/live/livedvd.png

    cp -L ${script_path}/efiboot/boot/refind-dvd.conf ${work_dir}/efiboot/EFI/boot/refind.conf

    mkdir -p ${work_dir}/efiboot/loader/entries
    cp -L ${script_path}/efiboot/loader/loader.conf ${work_dir}/efiboot/loader/
    cp ${script_path}/efiboot/loader/entries/archiso-x86_64-cd.conf ${work_dir}/efiboot/loader/entries/archiso-x86_64.conf
    cp ${script_path}/efiboot/loader/entries/archiso_3_ram-x86_64-cd.conf ${work_dir}/efiboot/loader/entries/archiso_3_ram-x86_64.conf

    sed -i "s|%ARCHISO_LABEL%|${iso_label}|g;
            s|%INSTALL_DIR%|${install_dir}|g" \
            ${work_dir}/efiboot/loader/entries/archiso{,_3_ram}-x86_64.conf

    # shellx64.efi is picked up automatically when on /
    cp ${work_dir}/iso/shellx64.efi ${work_dir}/efiboot/

    umount -d ${work_dir}/efiboot
}

# Build airootfs filesystem image
make_prepare() {
    cp -a -l -f ${work_dir}/x86_64/airootfs ${work_dir}
    mkarchiso ${verbose} -w "${work_dir}" -D "${install_dir}" pkglist
    mkarchiso ${verbose} -w "${work_dir}" -D "${install_dir}" -c "${comp_type}" ${gpg_key:+-g ${gpg_key}} prepare
    rm -rf ${work_dir}/airootfs
    # rm -rf ${work_dir}/x86_64/airootfs (if low space, this helps)
}

# Build ISO
make_iso() {
    mkarchiso ${verbose} -w "${work_dir}" -D "${install_dir}" -L "${iso_label}" -P "${iso_publisher}" -A "${iso_application}" -o "${out_dir}" iso "${iso_name}-${iso_version}-x64.iso"
    cd "${out_dir}"
    sha512sum -b "${iso_name}-${iso_version}-x64.iso" > "${iso_name}-${iso_version}-x64.iso.sha512"
    if [[ ${gpg_key} ]]; then
        gpg --detach-sign --default-key ${gpg_key} "${iso_name}-${iso_version}-x64.iso"
    fi
    cd ~-
}

while getopts 'N:V:L:P:A:D:w:o:g:vhc:' arg; do
    case "${arg}" in
        N) iso_name="${OPTARG}" ;;
        V) iso_version="${OPTARG}" ;;
        L) iso_label="${OPTARG}" ;;
        P) iso_publisher="${OPTARG}" ;;
        A) iso_application="${OPTARG}" ;;
        D) install_dir="${OPTARG}" ;;
        w) work_dir="${OPTARG}" ;;
        o) out_dir="${OPTARG}" ;;
        g) gpg_key="${OPTARG}" ;;
        v) verbose="-v" ;;
        h) _usage 0 ;;
        c) comp_type="${OPTARG}" ;;
        *)
           echo "Invalid argument '${arg}'"
           _usage 1
           ;;
    esac
done

if [[ ${EUID} -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

mkdir -p ${work_dir}

run_once make_pacman_conf
run_once make_basefs
run_once make_packages
run_once make_packages_local
run_once make_setup_mkinitcpio
run_once make_customize_airootfs
run_once make_boot
run_once make_boot_extra
run_once make_syslinux
run_once make_isolinux
run_once make_efi
run_once make_efiboot
run_once make_prepare
run_once make_iso
