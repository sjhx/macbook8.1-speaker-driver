#!/bin/bash
# dkms_build.sh — DKMS PRE_BUILD helper. Builds all three MacBook8,1 modules
# for kernel $1 into the build/ tree, in BUILD_ONLY mode so DKMS performs the
# install (modules land once under updates/dkms, not double-copied to updates/).
#
# Order matters: install.cirrus.driver.sh downloads + extracts the kernel hda
# source tree (and wipes build/hda) that the generic and azx builds reuse.
set -eu

kver="${1:-$(uname -r)}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

export BUILD_ONLY=1

echo "=== dkms_build: cs420x (codec) for $kver ==="
bash install.cirrus.driver.sh -k "$kver"

echo "=== dkms_build: generic (codec, CS4208 clock-latch skip) for $kver ==="
bash install.generic.driver.sh -k "$kver"

echo "=== dkms_build: snd-hda-intel (no-reset attach) for $kver ==="
bash install.azx.driver.sh -k "$kver"

# CRITICAL: cs420x imports snd_hda_gen_* symbols FROM our patched
# snd-hda-codec-generic. The cirrus build above ran first and linked cs420x
# against the *stock* kernel Module.symvers, baking in the stock CRC for
# snd_hda_gen_spec_init (0x48587078). But the patched generic is compiled in its
# own isolated tree and genksyms emits a DIFFERENT CRC (e.g. 0x4c) for the same
# symbol. At load time the kernel sees the mismatch, refuses cs420x
# ("disagrees about version of symbol snd_hda_gen_spec_init", err -22), and the
# always-present snd_hda_codec_generic silently binds the CS4208 as "Cirrus Logic
# Generic" — no MacBook8,1 speaker fixup -> dead speakers on every boot.
#
# Relink cs420x against the patched generic's Module.symvers so its imported CRCs
# match what that generic actually exports. `clean` first because Kbuild won't
# re-run modpost on an up-to-date .ko just because KBUILD_EXTRA_SYMBOLS changed.
gen_symvers="$here/build/hda/genmod/Module.symvers"
cs_ko="$here/build/hda/codecs/cirrus/snd-hda-codec-cs420x.ko"
[[ -f "$gen_symvers" ]] || { echo "FATAL: $gen_symvers missing — generic build failed?" >&2; exit 1; }
echo "=== dkms_build: relink cs420x against patched generic Module.symvers ==="
make -f Makefile_cs420x KERNELRELEASE="$kver" clean
KBUILD_EXTRA_SYMBOLS="$gen_symvers" make -f Makefile_cs420x KERNELRELEASE="$kver"

# Self-check: every symbol cs420x imports that the patched generic exports MUST
# carry the same modversion CRC, or the kernel refuses to link cs420x at load and
# the generic parser silently steals the CS4208 -> dead speakers. Fail the build
# LOUDLY here (apt/DKMS shows the error on a kernel update) instead of shipping a
# module that only reveals itself as silence after the next reboot.
echo "=== dkms_build: verify cs420x/generic modversions agree ==="
mismatch=0
while read -r crc sym; do
    gen_crc=$(awk -v s="$sym" '$2==s {print $1}' "$gen_symvers")
    [[ -n "$gen_crc" ]] || continue          # symbol not from our generic — skip
    if (( crc != gen_crc )); then
        printf 'MODVERSION MISMATCH: %s cs420x=%s generic=%s\n' "$sym" "$crc" "$gen_crc" >&2
        mismatch=1
    fi
done < <(modprobe --dump-modversions "$cs_ko")
(( mismatch == 0 )) || { echo "FATAL: cs420x will not load against patched generic — failing build" >&2; exit 1; }
echo "=== dkms_build: modversions OK — cs420x links against patched generic ==="

echo "=== dkms_build: all three modules built ==="
