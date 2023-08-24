#!/bin/bash
#
#   Copyright (C) 2022, 2023 SUSE LLC
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
#
#   Written by Olaf Kirch <okir@suse.com>

shopt -s expand_aliases

: ${SHAREDIR:=/usr/share/fde}

version=0.6.6

opt_bootloader=grub2
opt_uefi_bootdir=""
opt_ui=shell
opt_keyfile=""
opt_password=""
opt_passfile=""

##################################################################
# Display a usage message.
# We do not document the add-secondary-key command, because it's
# purely for the installer.
##################################################################
function fde_usage {

    cat <<EOF

Usage: fdectl [global-options] command [cmd-options]

Global options:
  --help
	Display this message
  --version
	Print program version 
  --device
	Specify the partition to operate on. Can be a device
	name or a mount point. Defaults to the current root
	device.
  --bootloader
	Specify the boot loader being used [grub2].
  --uefi-boot-dir
	Specify the location of the UEFI ESP [/boot/efi].
  --use-dialog
	Use the dialog(1) utility to interact with the user.
  --keyfile
	Specify the path to a LUKS key for use with tpm-enable.
  --password
	Specify the LUKS recovery password. Should be used by the
	installer only.
  --passfile
	Specify the path to a LUKS recovery password file.

Commands:
  help		display this message
  passwd	change the password protecting the partition
  add-secondary-password	protect partition with a passphrase and use that to unlock on next boot
  remove-secondary-password	remove passphrase installed by add-secondary-password
  regenerate-key		regenerate the random key to replace the old key and seal the new key
  tpm-present	check whether a TPM2 chip is present and working
  tpm-enable	enable TPM protection
  tpm-disable	disable TPM protection
  tpm-wipe      wipe out the keyslot for the sealed key
EOF
}

function fde_bad_option {

    echo "Error: $*" >&2
    fde_usage
    exit 1
}

function fde_bad_argument {

    echo "Error: $*" >&2
    exit 2
}

# Hack to deal with d-installer telling us about the installed system using the
# --device option rather than using chroot.
function fde_maybe_chroot {

    declare -a A
    device=""
    keyfile=""

    while [ $# -gt 0 ]; do
	arg=$1; shift
	if [ "$arg" = "--device" ]; then
	    device=$1; shift 1;
	elif [ "$arg" = "--keyfile" ]; then
	    keyfile=$1; shift 1;
	else
	    A+=("$arg")
	fi
    done

    if [ -n "$device" ]; then
	echo "About to invoke fdectl in system below $device"

	# If a keyfile was given, we need to strip off the /mnt prefix
	if [ -n "$keyfile" ]; then
	    keyfile="${keyfile#$device}"
	    A+=("--keyfile" "$keyfile")
	fi
        exec chroot "$device" fdectl "${A[@]}"
    fi
}

fde_maybe_chroot "$@"

long_options="help,version,bootloader:,device:,use-dialog,keyfile:,uefi-boot-dir:,password:,passfile:"

if ! getopt -Q -n fdectl -l "$long_options" -o h -- "$@"; then
    fde_usage
    exit 1
fi

eval set -- $(getopt -n fdectl -l "$long_options" -o h -- "$@")

command=
while [ $# -gt 0 ]; do
    next="$1"
    shift

    case $next in
    --)
	command=$1; shift; break;;
    -h|--help)
    	fde_usage
	exit 0;;
    --version)
	echo "$version"
	exit 0;;
    --bootloader)
    	opt_bootloader=$1; shift;;
    --device)
	# We should have handled --device in fde_maybe_chroot above
	fde_bad_option "The --device option should never show up at this point"
	shift;;
    --use-dialog)
    	opt_ui=dialog;;
    --keyfile)
	opt_keyfile=$1; shift;;
    --password)
	opt_password=$1; shift;;
    --passfile)
	opt_passfile=$1; shift;;
    --uefi-boot-dir)
	opt_uefi_bootdir=$1; shift;;
    *)
    	fde_bad_option "Unsupported option $next";;
    esac
done

if [ -z "$command" ]; then
    fde_bad_option "Missing subcommand"
fi

if [ "$command" = "help" ]; then
    fde_usage
    exit 0
fi

if [ ! -e "$SHAREDIR/commands/$command" ]; then
    fde_bad_option "Unsupported command \"$command\""
fi


if [ "$opt_bootloader" != "grub2" -a "$opt_bootloader" != "systemd-boot" ]; then
    fde_bad_argument "Unsupported boot loader \"$opt_bootloader\""
fi

trap fde_clean_tempdir 0 1 2 11 15

. "$SHAREDIR/luks"
. "$SHAREDIR/uefi"
if [ -n "$opt_uefi_bootdir" ]; then
    uefi_set_loader "$opt_uefi_bootdir"
fi

FDE_CONFIG_DIR=/etc/fde

. /etc/sysconfig/fde-tools
. "$SHAREDIR/ui/$opt_ui"
. "$SHAREDIR/util"
. "$SHAREDIR/tpm"
. "$SHAREDIR/$opt_bootloader"
. "$SHAREDIR/commands/$command"

if cmd_requires_luks_device; then
    fsdev=$(luks_device_for_path /)
    if [ ! -b "$fsdev" ]; then
	fde_bad_argument "Unable to determine partition to operate on"
    fi

    luks_dev=$(luks_get_volume_for_fsdev "$fsdev")
    if [ -z "$luks_dev" ]; then
	display_errorbox "Cannot find the underlying partition for $fsdev"
	exit 1
    fi

    cmd_perform "$luks_dev"
else
    cmd_perform
fi
