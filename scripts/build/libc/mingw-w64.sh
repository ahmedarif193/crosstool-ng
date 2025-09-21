# Copyright 2012 Yann Diorcet
# Licensed under the GPL v2. See COPYING in the root of this package

mingw_w64_set_install_prefix()
{
    MINGW_INSTALL_PREFIX=/usr/${CT_TARGET}
    if [[ ${CT_MINGW_W64_VERSION} == 2* ]]; then
        MINGW_INSTALL_PREFIX=/usr
    fi
}

mingw_w64_headers() {
    local -a sdk_opts

    CT_DoStep INFO "Installing C library headers"

    case "${CT_MINGW_DIRECTX}:${CT_MINGW_DDK}" in
        y:y)    sdk_opts+=( "--enable-sdk=all"     );;
        y:)     sdk_opts+=( "--enable-sdk=directx" );;
        :y)     sdk_opts+=( "--enable-sdk=ddk"     );;
        :)      ;;
    esac

    if [ "${CT_MINGW_SECURE_API}" = "y" ]; then
        sdk_opts+=( "--enable-secure-api"  )
    fi

    if [ "${CT_MINGW_DEFAULT_MSVCRT_MSVCRT}" = "y" ]; then
        sdk_opts+=( "--with-default-msvcrt=msvcrt" )
    elif [ "${CT_MINGW_DEFAULT_MSVCRT_UCRT}" = "y" ]; then
        sdk_opts+=( "--with-default-msvcrt=ucrt" )
    elif [ -n "${CT_MINGW_DEFAULT_MSVCRT}" ]; then
        sdk_opts+=( "--with-default-msvcrt=${CT_MINGW_DEFAULT_MSVCRT}" )
    fi

    CT_mkdir_pushd "${CT_BUILD_DIR}/build-mingw-w64-headers"

    CT_DoLog EXTRA "Configuring Headers"

    mingw_w64_set_install_prefix
    CT_DoExecLog CFG        \
    ${CONFIG_SHELL} \
    "${CT_SRC_DIR}/mingw-w64/mingw-w64-headers/configure" \
        --build=${CT_BUILD} \
        --host=${CT_TARGET} \
        --prefix=${MINGW_INSTALL_PREFIX} \
        "${sdk_opts[@]}"

    CT_DoLog EXTRA "Compile Headers"
    CT_DoExecLog ALL make

    CT_DoLog EXTRA "Installing Headers"
    CT_DoExecLog ALL make install DESTDIR=${CT_SYSROOT_DIR}

    CT_Popd

    # It seems mingw is strangely set up to look into /mingw instead of
    # /usr (notably when looking for the headers). This symlink is
    # here to workaround this, and seems to be here to last... :-/
    CT_DoExecLog ALL ln -sv "usr/${CT_TARGET}" "${CT_SYSROOT_DIR}/mingw"

    # Fix ARM64 fabsl function inline assembly issue in installed headers
    if [ "${CT_ARCH}" = "arm" ]; then
        CT_DoLog EXTRA "Applying ARM64 math.h fix for fabsl function in installed headers"
        for math_h in "${CT_SYSROOT_DIR}/usr/${CT_TARGET}/include/math.h" \
                      "${CT_SYSROOT_DIR}/mingw/include/math.h"; do
            if [ -f "${math_h}" ]; then
                sed -i 's@^\(.*__CRT_INLINE long double __cdecl fabsl.*\)@\1@; /^#if __SIZEOF_LONG_DOUBLE__ == __SIZEOF_DOUBLE__$/s@$@ || defined(__x86_64__) || defined(__arm__) || defined(__aarch64__)@' \
                    "${math_h}" || true
            fi
        done
    fi

    CT_EndStep
}

do_check_mingw_vendor_tuple()
{
   CT_DoStep INFO "Checking configured vendor tuple"
   if [ ${CT_TARGET_VENDOR} = "w64" ]; then
       CT_DoLog DEBUG "The tuple is set to '${CT_TARGET_VENDOR}', as recommended by mingw-64 developers."
   else
       CT_DoLog WARN "The tuple vendor is '${CT_TARGET_VENDOR}', not equal to 'w64' and might break the toolchain!"
   fi
   CT_EndStep
}

do_mingw_tools()
{
    local f

    for f in "${CT_MINGW_TOOL_LIST_ARRAY[@]}"; do
        CT_mkdir_pushd "${f}"
        if [ ! -d "${CT_SRC_DIR}/mingw-w64/mingw-w64-tools/${f}" ]; then
            CT_DoLog WARN "Skipping ${f}: not found"
            CT_Popd
            continue
        fi

        CT_DoLog EXTRA "Configuring ${f}"
        CT_DoExecLog CFG        \
            ${CONFIG_SHELL} \
            "${CT_SRC_DIR}/mingw-w64/mingw-w64-tools/${f}/configure" \
            --build=${CT_BUILD} \
            --host=${CT_HOST} \
            --target=${CT_TARGET} \
            --program-prefix=${CT_TARGET}- \
            --prefix="${CT_PREFIX_DIR}"

        # mingw-w64 has issues with parallel builds, see mingw_w64_main
        CT_DoLog EXTRA "Building ${f}"
        CT_DoExecLog ALL make
        CT_DoLog EXTRA "Installing ${f}"
        CT_DoExecLog ALL make install
        CT_Popd
    done
}

do_mingw_pthreads()
{
    local multi_flags multi_dir multi_os_dir multi_root multi_index multi_count multi_target
    local libprefix
    local rcflags dlltoolflags

    for arg in "$@"; do
        eval "${arg// /\\ }"
    done

    CT_DoStep INFO "Building for multilib ${multi_index}/${multi_count}: '${multi_flags}'"

    libprefix="${MINGW_INSTALL_PREFIX}/lib/${multi_os_dir}"
    CT_SanitizeVarDir libprefix

    CT_SymlinkToolsMultilib

    # DLLTOOLFLAGS does not appear to be currently used by winpthread package, but
    # the master package uses this variable and describes this as one of the changes
    # needed for i686 in mingw-w64-doc/howto-build/mingw-w64-howto-build-adv.txt
    CT_DoLog DEBUG "multi_target value is: '${multi_target}'"
    case "${multi_target}" in
        i[3456]86-*)
            rcflags="-F pe-i386"
            dlltoolflags="-m i386"
            ;;
        x86_64-*)
            rcflags="-F pe-x86-64"
            dlltoolflags="-m i386:x86_64"
            ;;
        aarch64-*)
            CT_DoLog DEBUG "Matched aarch64-* pattern"
            rcflags="-F pe-aarch64-little"
            dlltoolflags="-m arm64"
            ;;
        *)
            CT_Abort "Tuple ${multi_target} is not supported by mingw-w64"
            ;;
    esac

    CT_DoLog EXTRA "Configuring mingw-w64-winpthreads"

    # For aarch64, we need to provide libgcc atomics or use Windows Interlocked functions
    local extra_ldflags=""
    case "${multi_target}" in
        aarch64-*)
            # Link with libgcc for atomic intrinsics on ARM64
            extra_ldflags="-lgcc -lkernel32"
            ;;
    esac

    CT_DoExecLog CFG \
    CFLAGS="${multi_flags}" \
    CXXFLAGS="${multi_flags}" \
    LDFLAGS="${extra_ldflags}" \
    RCFLAGS="${rcflags}" \
    DLLTOOLFLAGS="${dlltoolflags}" \
    ${CONFIG_SHELL} \
    "${CT_SRC_DIR}/mingw-w64/mingw-w64-libraries/winpthreads/configure" \
        --with-sysroot=${CT_SYSROOT_DIR} \
        --prefix=${MINGW_INSTALL_PREFIX} \
        --libdir=${libprefix} \
        --build=${CT_BUILD} \
        --host=${multi_target}

    # mingw-w64 has issues with parallel builds, see mingw_w64_main
    CT_DoLog EXTRA "Building mingw-w64-winpthreads"
    CT_DoExecLog ALL make

    CT_DoLog EXTRA "Installing mingw-w64-winpthreads"
    CT_DoExecLog ALL make install DESTDIR=${CT_SYSROOT_DIR}

    # Post-install hackery: all libwinpthread-1.dll end up being installed
    # into /bin, which is broken on multilib install. Hence, stash it back
    # into /lib - and after iterating over multilibs, copy the default one
    # back into /bin.
    if [ "${multi_index}" != 1 -o "${multi_count}" != 1 ]; then
        CT_DoExecLog ALL mv "${CT_SYSROOT_DIR}${MINGW_INSTALL_PREFIX}/bin/libwinpthread-1.dll" \
                            "${CT_SYSROOT_DIR}${libprefix}/libwinpthread-1.dll"
        if [ "${multi_index}" = 1 ]; then
            default_libprefix="${libprefix}"
        elif [ "${multi_index}" = "${multi_count}" ]; then
            CT_DoExecLog ALL cp "${CT_SYSROOT_DIR}${default_libprefix}/libwinpthread-1.dll" \
                                "${CT_SYSROOT_DIR}${MINGW_INSTALL_PREFIX}/bin/libwinpthread-1.dll"
        fi
    fi

    CT_EndStep
}

mingw_w64_main()
{
    # Used when iterating over libwinpthread
    local default_libprefix
    local -a crt_opts

    do_check_mingw_vendor_tuple

    CT_DoStep INFO "Building mingw-w64"

    CT_DoLog EXTRA "Configuring mingw-w64-crt"

    CT_mkdir_pushd "${CT_BUILD_DIR}/build-mingw-w64-crt"

    if [ "${CT_MINGW_DEFAULT_MSVCRT_MSVCRT}" = "y" ]; then
        crt_opts+=( "--with-default-msvcrt=msvcrt" )
    elif [ "${CT_MINGW_DEFAULT_MSVCRT_UCRT}" = "y" ]; then
        crt_opts+=( "--with-default-msvcrt=ucrt" )
    elif [ -n "${CT_MINGW_DEFAULT_MSVCRT}" ]; then
        crt_opts+=( "--with-default-msvcrt=${CT_MINGW_DEFAULT_MSVCRT}"  )
    fi

    mingw_w64_set_install_prefix
    CT_DoExecLog CFG \
    ${CONFIG_SHELL} \
    "${CT_SRC_DIR}/mingw-w64/mingw-w64-crt/configure" \
        --with-sysroot=${CT_SYSROOT_DIR} \
        --prefix=${MINGW_INSTALL_PREFIX} \
        --build=${CT_BUILD} \
        --host=${CT_TARGET} \
        --enable-wildcard \
        "${crt_opts[@]}"

    # Fix ARM64 fabsl function inline assembly issue
    if [ "${CT_ARCH}" = "arm" ]; then
        CT_DoLog EXTRA "Applying ARM64 math.h fix for fabsl function"
        sed -i 's@^#if __SIZEOF_LONG_DOUBLE__ == __SIZEOF_DOUBLE__$@#if __SIZEOF_LONG_DOUBLE__ == __SIZEOF_DOUBLE__ || defined(__x86_64__) || defined(__arm__) || defined(__aarch64__)@' \
            "${CT_SYSROOT_DIR}/mingw/include/math.h" || true
    fi

    # mingw-w64-crt has a missing dependency occasionally breaking the
    # parallel build. See https://github.com/crosstool-ng/crosstool-ng/issues/246
    # Do not pass ${CT_JOBSFLAGS} - build serially.
    CT_DoLog EXTRA "Building mingw-w64-crt"
    CT_DoExecLog ALL make

    CT_DoLog EXTRA "Installing mingw-w64-crt"
    CT_DoExecLog ALL make install DESTDIR=${CT_SYSROOT_DIR}
    CT_EndStep

    if [ "${CT_THREADS}" = "posix" ]; then
        CT_DoStep INFO "Building mingw-w64-winpthreads"
        CT_mkdir_pushd "${CT_BUILD_DIR}/build-mingw-w64-winpthreads"
        CT_IterateMultilibs do_mingw_pthreads pthreads-multilib
        CT_Popd
        CT_EndStep
    fi

    if [ "${CT_MINGW_TOOLS}" = "y" ]; then
        CT_DoStep INFO "Installing mingw-w64 companion tools"
        CT_mkdir_pushd "${CT_BUILD_DIR}/build-mingw-w64-tools"
        do_mingw_tools
        CT_Popd
        CT_EndStep
    fi
}
