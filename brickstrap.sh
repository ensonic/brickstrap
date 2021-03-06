#!/bin/bash
#
# brickstrap - create a foreign architecture rootfs using multistrap, proot,
#              and qemu usermode emulation and disk image using libguestfs
#
# Copyright (C) 2014-2015 David Lechner <david@lechnology.com>
# Copyright (C) 2014-2015 Ralph Hempel <rhempel@hempeldesigngroup.com>
#
# Based on polystrap:
# Copyright (C) 2011 by Johannes 'josch' Schauer <j.schauer@email.de>
#
# Template to write better bash scripts.
# More info: http://kvz.io/blog/2013/02/26/introducing-bash3boilerplate/
# Version 0.0.1
#
# Licensed under MIT
# Copyright (c) 2013 Kevin van Zonneveld
# http://twitter.com/kvz
#

### Configuration
#####################################################################

# Environment variables
[ -z "${LOG_LEVEL}" ] && LOG_LEVEL="3" # 4 = debug -> 0 = fail

# Commandline options. This defines the usage page

read -r -d '' usage <<-'EOF'
  usage: brickstrap [-b <board>] [-d <dir>] <command>

Options
-------
-b <board> Directory that contains board definition. (Default: ev3dev-jessie)
-d <dir>   The name of the directory for the rootfs. Note: This is also
           used for the .tar and .img file names.
-f         Force overwriting existing files/directories.
-h         Help. (You are looking at it.)

  Commands
  --------
  create-conf          generate the multistrap.conf file
* simulate-multistrap  run multistrap with the --simulate option (for debugging)
  run-multistrap       run multistrap (creates rootfs and downloads packages)
  copy-root            copy files from board definition folder to the rootfs
  configure-packages   configure the packages in the rootfs
* run-hook <hook>      run a single hook in the board configuration folder
  run-hooks            run all of the hooks in the board configuration folder
  create-tar           create a tar file from the rootfs folder
  create-image         create a disk image file from the tar file

* shell                run a bash shell in the rootfs using qemu
  all                  run all of the above commands (except *) in order

  Environment Variables
  ---------------------
  LOG_LEVEL       Specifies log level verbosity (0-4)
                  0=fail, ... 3=info(default), 4=debug

  DEBIAN_MIRROR   Specifies the debian mirror used by apt
                  default: http://ftp.debian.org/debian
                  (applies to create-conf only)

  EV3DEV_MIRROR   Specifies the ev3dev mirror used by apt
                  default: http://ev3dev.org/debian
                  (applies to create-conf only)

  RASPBIAN_MIRROR Specifies the Raspbian mirror used by apt
                  default: http://archive.raspbian.org/raspbian
                  (applies to create-conf only)
EOF

### Functions
#####################################################################


function _fmt () {
  color_info="\x1b[32m"
  color_warn="\x1b[33m"
  color_error="\x1b[31m"

  color=
  [ "${1}" = "info" ] && color="${color_info}"
  [ "${1}" = "warn" ] && color="${color_warn}"
  [ "${1}" = "error" ] && color="${color_error}"
  [ "${1}" = "fail" ] && color="${color_error}"

  color_reset="\x1b[0m"
  if [ "${TERM}" != "xterm" ] || [ -t 1 ]; then
    # Don't use colors on pipes on non-recognized terminals
    color=""
    color_reset=""
  fi
  echo -e "$(date +"%H:%M:%S") [${color}$(printf "%5s" ${1})${color_reset}]";
}

function fail ()  {                             echo "$(_fmt fail) ${@}"  || true; exit 1; }
function error () { [ "${LOG_LEVEL}" -ge 1 ] && echo "$(_fmt error) ${@}" || true;         }
function warn ()  { [ "${LOG_LEVEL}" -ge 2 ] && echo "$(_fmt warn) ${@}"  || true;         }
function info ()  { [ "${LOG_LEVEL}" -ge 3 ] && echo "$(_fmt info) ${@}"  || true;         }
function debug () { [ "${LOG_LEVEL}" -ge 4 ] && echo "$(_fmt debug) ${@}" || true;         }

function help() {
    echo >&2 "${@}"
    echo >&2 "  ${usage}"
    echo >&2 ""
}

### Parse commandline options - adding the while loop around the
### getopts loop allows commands anywhere in the command line.
###
### Note that cmd gets set to the first non-option string, others
### are simply ignored
#####################################################################

BOARDDIR="ev3-ev3dev-jessie"

while [ $# -gt 0 ] ; do
    while getopts "fb:d:" opt; do
        case "$opt" in
           f) FORCE=true;;
           b) BOARDDIR="$OPTARG";;
           d) ROOTDIR="$OPTARG";;
          \?) # unknown flag
                help
                exit 1
            ;;
        esac
    done

    shift $((OPTIND-1))

    if [ "${cmd}" == "run-hook" ]; then
      run_hook_arg=$1
    fi

    cmd=${cmd:=$1}

    shift 1
    OPTIND=1
done

[ "${cmd}" = "" ] && help && exit 1
[ "${cmd}" = "run-hook" ] && [ "${run_hook_arg}" = "" ] && help && exit 1
debug "cmd: ${cmd}"

#####################################################################
### Set up the variables for the commands

SCRIPT_PATH=$(dirname $(readlink -f "$0"))

debug "SCRIPT_PATH: ${SCRIPT_PATH}"

export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
export LC_ALL=C LANGUAGE=C LANG=C
export PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin

[ -r "${BOARDDIR}" ] || BOARDDIR="${SCRIPT_PATH}/${BOARDDIR}"
[ -r "${BOARDDIR}" ] || fail "cannot find target directory: ${BOARDDIR}"
[ -r "${BOARDDIR}/multistrap.conf" ] \
    || fail "cannot read multistrap config: ${BOARDDIR}/multistrap.conf"

BOARDDIR=$(readlink -f "${BOARDDIR}")

for SYSTEM_KERNEL_IMAGE in /boot/vmlinuz-*; do
    [ -r "${SYSTEM_KERNEL_IMAGE}" ] \
        || fail "Cannot read ${SYSTEM_KERNEL_IMAGE} needed by guestfish." \
        "Set permission with 'sudo chmod +r /boot/vmlinuz-*'."
done

# source board config file
[ -r "${BOARDDIR}/config" ] && . "${BOARDDIR}/config"

# overwrite target options by commandline options
MULTISTRAPCONF="multistrap.conf"
DEFAULT_ROOTDIR=$(readlink -f "$(basename ${BOARDDIR})-$(date +%F)")
ROOTDIR=$(readlink -m ${ROOTDIR:-$DEFAULT_ROOTDIR})
TARBALL=$(pwd)/$(basename ${ROOTDIR}).tar
IMAGE=$(pwd)/$(basename ${ROOTDIR}).img

CHROOTCMD="eval proot -r ${ROOTDIR} -v -1 -0"
QEMU_COMMAND=${QEMU_COMMAND:-qemu-arm}
CHROOTQEMUCMD="${CHROOTCMD} -q \"${QEMU_COMMAND}\""
CHROOTQEMUBINDCMD="${CHROOTQEMUCMD} -b /dev -b /sys -b /proc"

### Runtime
#####################################################################

set -e

# Bash will remember & return the highest exitcode in a chain of pipes.
# This way you can catch the error in case mysqldump fails in `mysqldump |gzip`
set -o pipefail

#####################################################################

function create-conf() {
    info "Creating multistrap configuration file..."
    debug "BOARDDIR: ${BOARDDIR}"
    for f in ${BOARDDIR}/packages/*; do
        while read line; do PACKAGES="${PACKAGES} $line"; done < "$f"
    done

    multistrapconf_aptpreferences=false
    multistrapconf_cleanup=false;

    debug "creating ${MULTISTRAPCONF}"
    echo -n > "${MULTISTRAPCONF}"
    while read line; do
        eval echo $line >> "$MULTISTRAPCONF"
        if echo $line | grep -E -q "^aptpreferences="
        then
                multistrapconf_aptpreferences=true
        fi
        if echo $line | grep -E -q "^cleanup=true"
        then
               multistrapconf_cleanup=true
        fi
    done < $BOARDDIR/multistrap.conf
}

function simulate-multistrap() {
    MSTRAP_SIM="--simulate"
    run-multistrap
}

function run-multistrap() {
    info "running multistrap..."
    [ -z ${FORCE} ] && [ -d "${ROOTDIR}" ] && \
        fail "${ROOTDIR} already exists. Use -f option to overwrite."
    debug "MULTISTRAPCONF: ${MULTISTRAPCONF}"
    debug "ROOTDIR: ${ROOTDIR}"
    if [ ! -z ${FORCE} ] && [ -d "${ROOTDIR}" ]; then
        warn "Removing existing rootfs ${ROOTDIR}"
        rm -rf ${ROOTDIR}
    fi
    proot -0 multistrap ${MSTRAP_SIM} --file "${MULTISTRAPCONF}" --no-auth
}

function copy-root() {
    info "Copying root files from BOARDDIR definition..."
    debug "BOARDDIR: ${BOARDDIR}"
    debug "ROOTDIR: ${ROOTDIR}"
    [ ! -d "${ROOTDIR}" ] && fail "${ROOTDIR} does not exist."
    # copy initial directory tree - dereference symlinks
    if [ -r "${BOARDDIR}/root" ]; then
        cp --recursive --dereference "${BOARDDIR}/root/"* "${ROOTDIR}/"
    fi
}

function configure-packages () {
    info "Configuring packages..."
    [ ! -d "${ROOTDIR}" ] && fail "${ROOTDIR} does not exist."

    # preseed debconf
    info "preseed debconf"
    if [ -r "${BOARDDIR}/debconfseed.txt" ]; then
        cp "${BOARDDIR}/debconfseed.txt" "${ROOTDIR}/tmp/"
        ${CHROOTQEMUCMD} debconf-set-selections /tmp/debconfseed.txt
        rm "${ROOTDIR}/tmp/debconfseed.txt"
    fi

    # run preinst scripts
    info "running preinst scripts..."
    script_dir="${ROOTDIR}/var/lib/dpkg/info"
    for script in ${script_dir}/*.preinst; do
        blacklisted="false"
        if [ -r "${BOARDDIR}/preinst.blacklist" ]; then
            while read line; do
                if [ "${script##$script_dir}" = "/${line}.preinst" ]; then
                    blacklisted="true"
                    info "skipping ${script##$script_dir} (blacklisted)"
                    break
                fi
            done < "${BOARDDIR}/preinst.blacklist"
        fi
        [ "${blacklisted}" = "true" ] && continue
        info "running ${script##$script_dir}"
        DPKG_MAINTSCRIPT_NAME=preinst \
        DPKG_MAINTSCRIPT_PACKAGE="`basename ${script} .preinst`" \
            ${CHROOTQEMUBINDCMD} ${script##$ROOTDIR} install
    done

    # run dpkg `--configure -a` twice because of errors during the first run
    info "configuring packages..."
    ${CHROOTQEMUBINDCMD} /usr/bin/dpkg --configure -a || \
    ${CHROOTQEMUBINDCMD} /usr/bin/dpkg --configure -a || true
}

function run-hook() {
  info "running hook ${1##${BOARDDIR}/hooks/}"
  . ${1}
}

function run-hooks() {
    info "Running hooks..."
    [ ! -d "${ROOTDIR}" ] && fail "${ROOTDIR} does not exist."

    # source hooks
    if [ -r "${BOARDDIR}/hooks" ]; then
        for f in "${BOARDDIR}"/hooks/*; do
            run-hook ${f}
        done
    fi
}

function create-tar() {
    info "Creating tar of rootfs"
    debug "ROOTDIR: ${ROOTDIR}"
    debug "TARBALL: ${TARBALL}"
    [ ! -d "${ROOTDIR}" ] && fail "${ROOTDIR} does not exist."
    [ -z ${FORCE} ] && [ -f "${TARBALL}" ] \
	    && fail "${TARBALL} exists. Use -f option to overwrite."
    # need to generate tar inside fakechroot so that absolute symlinks are correct
    info "creating tarball ${TARBALL}"
    EXCLUDE_LIST=/host-rootfs/${BOARDDIR}/tar-exclude
    info "Excluding files:
$(${CHROOTQEMUCMD} cat ${EXCLUDE_LIST})"
    ${CHROOTQEMUCMD} tar cpf /host-rootfs/${TARBALL} \
        --exclude=host-rootfs --exclude=tar-only --exclude-from=${EXCLUDE_LIST} .
    if [ -d "${BOARDDIR}/tar-only" ]; then
      cp -r "${BOARDDIR}/tar-only/." "${ROOTDIR}/tar-only/"
    fi
    if [ -d "${ROOTDIR}/tar-only" ]; then
      info "Adding tar-only files:"
      ${CHROOTQEMUCMD} tar rvpf /host-rootfs/${TARBALL} -C /tar-only .
    fi
}


function create-image() {
    info "Creating image file..."
    debug "TARBALL: ${TARBALL}"
    debug "IMAGE: ${IMAGE}"
    debug "IMAGE_FILE_SIZE: ${IMAGE_FILE_SIZE}"
    [ ! -f ${TARBALL} ] && fail "Could not find ${TARBALL}"
    [ -z ${FORCE} ] && [ -f ${IMAGE} ] && \
        fail "${IMAGE} already exists. Use -f option to overwrite."

    guestfish -N bootroot:vfat:ext4:${IMAGE_FILE_SIZE}:48M:mbr \
         part-set-mbr-id /dev/sda 1 0x0b : \
         set-label /dev/sda2 EV3_FILESYS : \
         mount /dev/sda2 / : \
         tar-in ${TARBALL} / : \
         mkdir-p /media/mmc_p1 : \
         mount /dev/sda1 /media/mmc_p1 : \
         glob mv /boot/flash/* /media/mmc_p1/ : \

    # Hack to set the volume label on the vfat partition since guestfish does
    # not know how to do that. Must be null padded to exactly 11 bytes.
    echo -e -n "EV3_BOOT\0\0\0" | \
        dd of=test1.img bs=1 seek=32811 count=11 conv=notrunc >/dev/null 2>&1

    mv test1.img ${IMAGE}
}

function run-shell() {
    [ ! -d "${ROOTDIR}" ] && fail "${ROOTDIR} does not exist."
    debian_chroot="brickstrap" PROMPT_COMMAND= HOME=/root ${CHROOTQEMUBINDCMD} bash
}

case "${cmd}" in
    create-conf)         create-conf;;
    simulate-multistrap) simulate-multistrap;;
    run-multistrap)      run-multistrap;;
    copy-root)           copy-root;;
    configure-packages)  configure-packages;;
    run-hook)            run-hook ${BOARDDIR}/hooks/${run_hook_arg};;
    run-hooks)           run-hooks;;
    create-tar)          create-tar;;
    create-image)        create-image;;

    shell) run-shell;;

    all) create-conf
         run-multistrap
         copy-root
         configure-packages
         run-hooks
         create-tar
         create-image
    ;;

    *) fail "Unknown command. See brickstrap -h for list of commands.";;
esac
