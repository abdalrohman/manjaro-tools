#!/bin/bash
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

kernel_cmdline(){
    for param in $(/bin/cat /proc/cmdline); do
        case "${param}" in
            $1=*) echo "${param##*=}"; return 0 ;;
            $1) return 0 ;;
            *) continue ;;
        esac
    done
    [ -n "${2}" ] && echo "${2}"
    return 1
}

##
#  usage : in_array( $needle, $haystack )
# return : 0 - found
#          1 - not found
##
in_array() {
    local needle=$1; shift
    local item
    for item in "$@"; do
	[[ $item = $needle ]] && return 0 # Found
    done
    return 1 # Not Found
}

# $1: sofile
# $2: soarch
process_sofile() {
    # extract the library name: libfoo.so
    local soname="${1%.so?(+(.+([0-9])))}".so
    # extract the major version: 1
    soversion="${1##*\.so\.}"
    if [[ "$soversion" = "$1" ]] && (($IGNORE_INTERNAL)); then
	continue
    fi
    if ! in_array "${soname}=${soversion}-$2" ${soobjects[@]}; then
	# libfoo.so=1-64
	msg "${soname}=${soversion}-$2"
	soobjects+=("${soname}=${soversion}-$2")
    fi
}

##
#  usage : get_full_version( [$pkgname] )
# return : full version spec, including epoch (if necessary), pkgver, pkgrel
##
get_full_version() {
    # set defaults if they weren't specified in buildfile
    pkgbase=${pkgbase:-${pkgname[0]}}
    epoch=${epoch:-0}
    if [[ -z $1 ]]; then
	if [[ $epoch ]] && (( ! $epoch )); then
	    echo $pkgver-$pkgrel
	else
	    echo $epoch:$pkgver-$pkgrel
	fi
    else
	for i in pkgver pkgrel epoch; do
	    local indirect="${i}_override"
	    eval $(declare -f package_$1 | sed -n "s/\(^[[:space:]]*$i=\)/${i}_override=/p")
	    [[ -z ${!indirect} ]] && eval ${indirect}=\"${!i}\"
	done
	if (( ! $epoch_override )); then
	    echo $pkgver_override-$pkgrel_override
	else
	    echo $epoch_override:$pkgver_override-$pkgrel_override
	fi
    fi
}

##
#  usage: find_cached_package( $pkgname, $pkgver, $arch )
#
#    $pkgver can be supplied with or without a pkgrel appended.
#    If not supplied, any pkgrel will be matched.
##
find_cached_package() {
    local searchdirs=("$PWD" "$PKGDEST") results=()
    local targetname=$1 targetver=$2 targetarch=$3
    local dir pkg pkgbasename pkgparts name ver rel arch size r results

    for dir in "${searchdirs[@]}"; do
	[[ -d $dir ]] || continue

	for pkg in "$dir"/*.pkg.tar.xz; do
	    [[ -f $pkg ]] || continue

	    # avoid adding duplicates of the same inode
	    for r in "${results[@]}"; do
		[[ $r -ef $pkg ]] && continue 2
	    done

	    # split apart package filename into parts
	    pkgbasename=${pkg##*/}
	    pkgbasename=${pkgbasename%.pkg.tar?(.?z)}

	    arch=${pkgbasename##*-}
	    pkgbasename=${pkgbasename%-"$arch"}

	    rel=${pkgbasename##*-}
	    pkgbasename=${pkgbasename%-"$rel"}

	    ver=${pkgbasename##*-}
	    name=${pkgbasename%-"$ver"}

	    if [[ $targetname = "$name" && $targetarch = "$arch" ]] &&
			    pkgver_equal "$targetver" "$ver-$rel"; then
		results+=("$pkg")
	    fi
	done
    done

    case ${#results[*]} in
	    0)
		return 1
	    ;;
	    1)
		printf '%s\n' "$results"
		return 0
	    ;;
	    *)
		error 'Multiple packages found:'
		printf '\t%s\n' "${results[@]}" >&2
		return 1
	    ;;
    esac
}

##
# usage: pkgver_equal( $pkgver1, $pkgver2 )
##
pkgver_equal() {
	local left right

	if [[ $1 = *-* && $2 = *-* ]]; then
		# if both versions have a pkgrel, then they must be an exact match
		[[ $1 = "$2" ]]
	else
		# otherwise, trim any pkgrel and compare the bare version.
		[[ ${1%%-*} = "${2%%-*}" ]]
	fi
}

check_root() {
    (( EUID == 0 )) && return
    if type -P sudo >/dev/null; then
	exec sudo -- "$@"
    else
	exec su root -c "$(printf ' %q' "$@")"
    fi
}

load_vars() {
    local var
    
    [[ -f $1 ]] || return 1

    for var in {SRC,SRCPKG,PKG,LOG}DEST MAKEFLAGS PACKAGER CARCH GPGKEY; do
	    [[ -z ${!var} ]] && eval $(grep "^${var}=" "$1")
    done
    
    return 0
}

load_config(){

    [[ -f $1 ]] || return 1
    
    manjaro_tools_conf="$1"

    [[ -r ${manjaro_tools_conf} ]] && source ${manjaro_tools_conf}
    
    ######################
    # common
    ######################
    
    if [[ -z ${branch} ]];then
	branch='stable'
    fi
    
    if [[ -z ${arch} ]]; then
	arch=$(uname -m)
    fi
    
    if [[ -z ${cache_dir} ]];then
	cache_dir='/var/cache/manjaro-tools'
    fi
    
    ###################
    # buildtree
    ###################
    
    if [[ -z ${repo_tree} ]];then
	repo_tree=(core extra community multilib openrc)
    fi
    
    if [[ -z ${host_tree} ]];then
	host_tree='https://github.com/manjaro'
    fi   
    
    if [[ -z ${host_tree_abs} ]];then
	host_tree_abs='https://projects.archlinux.org/git/svntogit/packages'
    fi   
    
    ###################
    # buildpkg
    ###################
    
    if [[ -z ${chroots_pkg} ]];then
	chroots_pkg='/opt/buildpkg'
    fi
        
    if [[ -z ${sets_dir_pkg} ]];then
	sets_dir_pkg="${SYSCONFDIR}/sets/pkg"
    fi
    
    if [[ -z ${buildset_pkg} ]];then
	buildset_pkg='default'
    fi

    if [[ -z ${build_mirror} ]];then
	build_mirror='http://mirror.netzspielplatz.de/manjaro/packages'
    fi

    if [[ -z ${blacklist_trigger[@]} ]];then
	blacklist_trigger=('eudev' 'upower-pm-utils' 'eudev-systemdcompat')
    fi
    
    if [[ -z ${blacklist[@]} ]];then
	blacklist=('libsystemd')
    fi
    
    ###################
    # buildiso
    ###################
    
    if [[ -z ${chroots_iso} ]];then
	chroots_iso='/opt/buildiso'
    fi
        
    if [[ -z ${sets_dir_iso} ]];then
	sets_dir_iso="${SYSCONFDIR}/sets/iso"
    fi
    
    if [[ -z ${buildset_iso} ]];then
	buildset_iso='default'
    fi
    
    if [[ -z ${iso_label} ]];then
	source /etc/lsb-release
	iso_label="MJRO${DISTRIB_RELEASE//.}"
    fi

    if [[ -z ${iso_version} ]];then	
	source /etc/lsb-release
	iso_version=${DISTRIB_RELEASE}
    fi

    if [[ -z ${manjaro_kernel} ]];then
	manjaro_kernel="linux318"
    fi

    manjaro_kernel_ver=${manjaro_kernel#*linux}
    
    if [[ -z ${manjaro_version} ]];then
	manjaro_version=$(date +%Y.%m)
    fi
    
    if [[ -z ${manjaroiso} ]];then
	manjaroiso="manjaroiso"
    fi
    
    if [[ -z ${code_name} ]];then
	source /etc/lsb-release
	code_name="${DISTRIB_CODENAME}"
    fi
    
    if [[ -z ${img_name} ]];then
	img_name=manjaro
    fi
    
    if [[ -z ${hostname} ]];then
	hostname="manjaro"
    fi
    
    if [[ -z ${username} ]];then
	username="manjaro"
    fi
    
    if [[ -z ${install_dir} ]];then
	install_dir=manjaro
    fi
    
    if [[ -z ${plymouth_theme} ]];then
	plymouth_theme=manjaro-elegant
    fi
    
    if [[ -z ${compression} ]];then
	compression=xz
    fi
    
    if [[ -z ${password} ]];then
	password="manjaro"
    fi
    
    if [[ -z ${addgroups} ]];then
	addgroups="video,audio,power,disk,storage,optical,network,lp,scanner"
    fi

    if [[ -z ${start_systemd} ]];then
	start_systemd=('cronie' 'org.cups.cupsd' 'tlp' 'tlp-sleep')
    fi
    
    if [[ -z ${start_openrc} ]];then
	start_openrc=('cronie' 'cupsd' 'metalog' 'dbus' 'consolekit' 'acpid')
    fi
    
    if [[ -z ${start_systemd_live} ]];then
	start_systemd_live=('bluez' 'NetworkManager' 'ModemManager')
    fi
    
    if [[ -z ${start_openrc_live} ]];then
	start_openrc_live=('bluetooth' 'NetworkManager')
    fi
    
    if [[ -z ${checksum_mode} ]];then
        checksum_mode='md5'
    fi
    
    return 0
}

# $1: sets_dir
load_sets(){
    local prof temp
    for item in $(ls $1/*.set); do
	temp=${item##*/}
	prof=${prof:-}${prof:+|}${temp%.set}
    done
    echo $prof
}

# $1: buildset
# $2: sets_dir
eval_buildset(){
    eval "case $1 in
	    $(load_sets $2)) is_buildset=true ;;
	    *) is_buildset=false ;;
	esac"
}

load_user_info(){
    OWNER=${SUDO_USER:-$USER}

    if [[ -n $SUDO_USER ]]; then
	eval "USER_HOME=~$SUDO_USER"
    else
	USER_HOME=$HOME
    fi
    
    USER_CONFIG="$USER_HOME/.config"
}
