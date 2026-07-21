#!/bin/bash

src_dir='/usr/src/macbook12-audio-0.1'
dkms_name='macbook12-audio/0.1'
var_dkms_dir='/var/lib/dkms/macbook12-audio'
cur_dir=$(cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)

# specify uninstall with the -r or -u argument
while getopts :ru arg
do
    case "${arg}" in
        r) dkms_remove=true;;
        u) dkms_remove=true;;
    esac
done

# The patched modules AND /etc/modprobe.d (the cs420x softdep) are both baked
# into the initramfs, and `dkms install` does NOT refresh it: Ubuntu ships no
# REMAKE_INITRD in /etc/dkms/framework.conf, and the default is "no". Without
# this, a rebuild updates /lib/modules only; boot keeps loading whatever was
# frozen into initrd.img by the last kernel package install, so an OLD generic
# links against the NEW cs420x -> "disagrees about version of symbol
# snd_hda_gen_spec_init" (err -22), and the softdep never runs so
# snd_hda_codec_generic wins the codec bind. The symptom is maximally
# confusing: the build self-check passes, a card and PCM device appear, and the
# machine is silent. (A kernel *upgrade* is already safe — the packaged
# postinst runs dkms before initramfs-tools — it is manual rebuilds that drift.)
#
# -k all because DKMS keeps a build for every installed kernel, not just the
# running one. MB81_SKIP_INITRAMFS=1 defers it to the caller (install.sh runs
# its own once, after it has finished touching /etc/modprobe.d).
refresh_initramfs() {
    if [[ ${MB81_SKIP_INITRAMFS:-0} = 1 ]]; then
        echo "deferring initramfs refresh (MB81_SKIP_INITRAMFS=1)"
        return 0
    fi
    if ! command -v update-initramfs > /dev/null; then
        echo "WARNING: no update-initramfs found. Refresh the initramfs by hand,"
        echo "         or the rebuilt modules will NOT be the ones used at boot."
        return 0
    fi
    echo "=== refreshing initramfs (so new modules + softdep reach boot) ==="
    update-initramfs -u -k all
}

if [[ $dkms_remove = true ]]; then
    # ORDER MATTERS. dkms.conf ships replacements for three modules that also
    # exist in-tree, so DKMS *moved* the stock .ko.zst files aside into
    # $var_dkms_dir/original_module/ ("Original modules exist" in `dkms status`).
    # They are no longer under /lib/modules/*/kernel/sound/. Only `dkms remove`
    # puts them back.
    #
    # This block used to `rm -rf $var_dkms_dir` first, which deleted the only
    # surviving copy of the stock drivers while leaving the patched ones in
    # updates/dkms/ — so "removal" left the patched drivers loading AND made
    # reverting impossible without reinstalling the linux-modules package.
    if dkms status 2>/dev/null | grep -q '^macbook12-audio'; then
        echo "=== dkms remove (restores the stock in-tree modules) ==="
        dkms remove -m $dkms_name --all \
            || echo "WARNING: dkms remove failed — stock modules may NOT be restored"
    fi
    [[ -e $var_dkms_dir ]] && rm -rf $var_dkms_dir && echo "removed $var_dkms_dir"
    [[ -e $src_dir ]] && rm -f $src_dir && echo "removed $src_dir"
    # Sweep any patched copies dkms did not account for (e.g. left by an
    # interrupted run, or by the older single-module install.*.driver.sh path).
    rm -f /lib/modules/*/updates/dkms/snd-hda-codec-cs420x.ko* \
          /lib/modules/*/updates/dkms/snd-hda-codec-generic.ko* \
          /lib/modules/*/updates/dkms/snd-hda-intel.ko* 2>/dev/null || true
    depmod -a
    refresh_initramfs
    exit 0
fi

pushd $cur_dir > /dev/null

# Clear any stale DKMS state from a previous install before (re)building.
# `dkms install --force` only forces re-INSTALL, not a re-BUILD: if a build
# already exists for this kernel it reuses it. An earlier single-module build
# (PRE_BUILD=install.cirrus.driver.sh) therefore leaves a module dir with only
# cs420x, and the current 3-module dkms.conf fails with
# "Missing module snd-hda-codec-generic". Nuke the tree so the build is fresh.
[[ -e $var_dkms_dir ]] && rm -rf $var_dkms_dir && echo "cleared stale $var_dkms_dir"
# Always (re)point the DKMS source symlink at THIS tree. A bare `[[ ! -e ]]` guard
# left a stale symlink from a previous checkout pointing elsewhere, so DKMS would
# rebuild old source; -sfn forces replacement and is idempotent.
ln -sfn "$cur_dir" "$src_dir"
dkms install -c dkms.conf --force -m $dkms_name
depmod -a
refresh_initramfs

popd > /dev/null
