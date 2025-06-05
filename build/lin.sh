#!/usr/bin/env bash
set -e

# Environment / working directories
case ${PLATFORM} in
  linux*)
    LINUX=true
    DEPS=/deps
    TARGET=/target
    PACKAGE=/packaging
    ROOT=/root
    VIPS_CPP_DEP=libvips-cpp.so.42
    ;;
  osx*)
    DARWIN=true
    DEPS=$PWD/deps
    TARGET=$PWD/target
    PACKAGE=$PWD
    ROOT=$PWD/platforms/$PLATFORM
    VIPS_CPP_DEP=libvips-cpp.42.dylib
    ;;
esac

mkdir -p ${DEPS}
mkdir -p ${TARGET}

# Default optimisation level is for binary size (-Os)
# Overriden to performance (-O3) for select dependencies that benefit
export FLAGS+=" -Os -fPIC"

# Force "new" C++11 ABI compliance
# Remove async exception unwind/backtrace tables
# Allow linker to remove unused sections
if [ "$LINUX" = true ]; then
  export FLAGS+=" -D_GLIBCXX_USE_CXX11_ABI=1 -fno-asynchronous-unwind-tables -ffunction-sections -fdata-sections"
fi

# Common build paths and flags
export PKG_CONFIG_LIBDIR="${TARGET}/lib/pkgconfig"
export PATH="${PATH}:${TARGET}/bin"
export LD_LIBRARY_PATH="${TARGET}/lib"
export CFLAGS="${FLAGS}"
export CXXFLAGS="${FLAGS}"
export OBJCFLAGS="${FLAGS}"
export OBJCXXFLAGS="${FLAGS}"
export CPPFLAGS="-I${TARGET}/include"
export LDFLAGS="-L${TARGET}/lib"

# On Linux, we need to create a relocatable library
# Note: this is handled for macOS using the `install_name_tool` (see below)
if [ "$LINUX" = true ]; then
  export LDFLAGS+=" -Wl,--gc-sections -Wl,-rpath=\$ORIGIN/"
fi

# The ARMv7 binaries needs to be statically linked against libstdc++, since
# libstdc++.so.6.0.33 (GLIBCXX_3.4.33) provided by GCC 14.2 isn't available on every OS
# Note: this is handled in devtoolset in a much better way, see: https://stackoverflow.com/a/19340023
if [ "$PLATFORM" == "linux-arm" ]; then
  export LDFLAGS+=" -static-libstdc++"
fi

if [ "$DARWIN" = true ]; then
  # Let macOS linker remove unused code
  export LDFLAGS+=" -Wl,-dead_strip"
  # Local rust installation
  export CARGO_HOME="${DEPS}/cargo"
  export RUSTUP_HOME="${DEPS}/rustup"
  mkdir -p $CARGO_HOME
  mkdir -p $RUSTUP_HOME
  export PATH="${CARGO_HOME}/bin:${PATH}"
  if [ "$PLATFORM" == "osx-arm64" ]; then
    export DARWIN_ARM=true
  fi
fi

# Run as many parallel jobs as there are available CPU cores
if [ "$LINUX" = true ]; then
  export MAKEFLAGS="-j$(nproc)"
elif [ "$DARWIN" = true ]; then
  export MAKEFLAGS="-j$(sysctl -n hw.logicalcpu)"
fi

# Optimise Rust code for binary size
export CARGO_PROFILE_RELEASE_DEBUG=false
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
export CARGO_PROFILE_RELEASE_INCREMENTAL=false
export CARGO_PROFILE_RELEASE_LTO=true
export CARGO_PROFILE_RELEASE_OPT_LEVEL=z
export CARGO_PROFILE_RELEASE_PANIC=abort

# Ensure Cargo build path prefixes are removed from the resulting binaries
# https://reproducible-builds.org/docs/build-path/
export RUSTFLAGS+=" --remap-path-prefix=$CARGO_HOME/registry/="

# We don't want to use any native libraries, so unset PKG_CONFIG_PATH
unset PKG_CONFIG_PATH

# Common options for curl
CURL="curl --silent --location --retry 3 --retry-max-time 30"

# Dependency version numbers
VERSION_ZLIB_NG=2.2.4
VERSION_FFI=3.4.7
VERSION_GLIB=2.85.0
VERSION_XML2=2.13.6
VERSION_EXIF=0.6.25
VERSION_LCMS2=2.17
VERSION_PNG16=1.6.47
VERSION_SPNG=0.7.4
VERSION_IMAGEQUANT=2.4.1
VERSION_WEBP=1.5.0
VERSION_HWY=1.2.0
VERSION_PROXY_LIBINTL=0.4
VERSION_FREETYPE=2.13.3
VERSION_EXPAT=2.6.4
VERSION_FONTCONFIG=2.16.0
VERSION_HARFBUZZ=10.4.0
VERSION_PIXMAN=0.44.2
VERSION_CAIRO=1.18.4
VERSION_FRIBIDI=1.0.16
VERSION_PANGO=1.56.2
VERSION_RESVG=0.45.1
VERSION_PDFIUM=7212

# Remove patch version component
without_patch() {
  echo "${1%.[[:digit:]]*}"
}
# Remove prerelease suffix
without_prerelease() {
  echo "${1%-[[:alnum:]]*}"
}

# Download and build dependencies from source

if [ "${PLATFORM%-*}" == "linux-musl" ] || [ "$DARWIN" = true ]; then
  # musl and macOS requires the standalone intl support library of gettext, since it's not provided by libc (like GNU).
  # We use a stub version of gettext instead, since we don't need any of the i18n features.
  mkdir ${DEPS}/proxy-libintl
  $CURL https://github.com/frida/proxy-libintl/archive/${VERSION_PROXY_LIBINTL}.tar.gz | tar xzC ${DEPS}/proxy-libintl --strip-components=1
  cd ${DEPS}/proxy-libintl
  meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON}
  meson install -C _build --tag devel
fi

sudo chown -R runner:admin /usr/local/share/

mkdir -p ${DEPS}/hwy
$CURL https://github.com/google/highway/archive/${VERSION_HWY}.tar.gz | tar xzC ${DEPS}/hwy --strip-components=1

mkdir -p ${DEPS}/libjxl
cd ${DEPS}/libjxl
git clone https://github.com/libjxl/libjxl.git --recursive .
rm -fr third_party/highway
cp -r ${DEPS}/hwy third_party/highway
sed -i'.bak' 's@ AND NOT APPLE AND NOT WIN32 AND NOT EMSCRIPTEN@@g' lib/jpegli.cmake
sed -i'.bak' "/set_property(TARGET jpeg APPEND_STRING PROPERTY/{N;d;}" lib/jpegli.cmake
sed -i'.bak' 's@JPEGLI_ERROR("DHT marker: no Huffman table found")@return@g' lib/jpegli/decode_marker.cc
cat lib/jpegli/decode_marker.cc
CFLAGS="${CFLAGS} -O3" CXXFLAGS="${CXXFLAGS} -O3" cmake -B_build -DCMAKE_TOOLCHAIN_FILE=${ROOT}/Toolchain.cmake -DBUILD_SHARED_LIBS=0 -DJPEGXL_ENABLE_JPEGLI=1 -DCMAKE_BUILD_TYPE=Release  -DJPEGXL_ENABLE_FUZZERS=0 -DJPEGXL_ENABLE_DEVTOOLS=0 -DJPEGXL_ENABLE_TOOLS=0 -DJPEGXL_ENABLE_JPEGLI_LIBJPEG=1 -DJPEGXL_ENABLE_DOXYGEN=0 -DJPEGXL_ENABLE_MANPAGES=0 -DJPEGXL_ENABLE_BENCHMARK=0 -DJPEGXL_BUNDLE_LIBPNG=0 -DJPEGXL_ENABLE_JNI=0 -DJPEGXL_ENABLE_SJPEG=0 -DJPEGXL_ENABLE_OPENEXR=0 -DJPEGXL_ENABLE_SKCMS=1 -DJPEGXL_ENABLE_TCMALLOC=0 -DJPEGXL_ENABLE_COVERAGE=0 -DJPEGXL_ENABLE_WASM_THREADS=0 -DBUILD_TESTING=0 -DCMAKE_INSTALL_PREFIX=target/
make -C _build
#combine libjpeg_wrapper.o into libjpegli-static.a
ar rcs _build/lib/libjpegli-static.a _build/lib/CMakeFiles/jpegli-libjpeg-obj.dir/jpegli/libjpeg_wrapper.cc.o
mkdir -p ${TARGET}/lib/
cp _build/lib/libjpegli-static.a ${TARGET}/lib/libjpeg.a
mkdir -p ${TARGET}/include/
cp _build/lib/include/jpegli/*h ${TARGET}/include/
cp third_party/libjpeg-turbo/jerror.h ${TARGET}/include/
mkdir -p ${TARGET}/lib/pkgconfig/
cat > ${TARGET}/lib/pkgconfig/libjpeg.pc << EOF
prefix=${TARGET}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include
Name: libjpeg
Description: libjpeg
Version: 1.0
Requires:
Libs: -L\${libdir} -ljpeg
Cflags: -I\${includedir}
EOF

cd ${DEPS}/hwy
CFLAGS="${CFLAGS} -O3" CXXFLAGS="${CXXFLAGS} -O3" cmake -G"Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE=${ROOT}/Toolchain.cmake -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=FALSE -DBUILD_TESTING=0 -DHWY_ENABLE_CONTRIB=0 -DHWY_ENABLE_EXAMPLES=0 -DHWY_ENABLE_TESTS=0
make install/strip

mkdir -p ${DEPS}/resvg
curl -Ls https://github.com/linebender/resvg/releases/download/v$VERSION_RESVG/resvg-$VERSION_RESVG.tar.xz | tar xJC ${DEPS}/resvg --strip-components=1
cd ${DEPS}/resvg
# We don't want to build the shared library
sed -i'.bak' '/^crate-type =/s/"cdylib", //' crates/c-api/Cargo.toml
cargo build --manifest-path=crates/c-api/Cargo.toml --release --target aarch64-apple-darwin
ls -la target/release/
ls -la target/aarch64-apple-darwin/release/
cp target/aarch64-apple-darwin/release/libresvg* ${TARGET}/lib/
cp crates/c-api/resvg.h ${TARGET}/include/

mkdir ${DEPS}/pdfium
$CURL https://github.com/gemini133/pdfium-lib/releases/download/${VERSION_PDFIUM}/macos.tgz | tar xzC ${TARGET} --strip-components 1
mkdir -p ${TARGET}/lib/pkgconfig
ls -la ${TARGET} ${TARGET}/lib ${TARGET}/include ${TARGET}/lib/pkgconfig
cat > ${TARGET}/lib/pkgconfig/pdfium.pc << EOF
prefix=${TARGET}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include
Name: pdfium
Description: pdfium
Version: ${VERSION_PDFIUM}
Requires:
Libs: -L\${libdir} -lpdfium
Cflags: -I\${includedir}
EOF


mkdir ${DEPS}/zlib-ng
$CURL https://github.com/zlib-ng/zlib-ng/archive/${VERSION_ZLIB_NG}.tar.gz | tar xzC ${DEPS}/zlib-ng --strip-components=1
cd ${DEPS}/zlib-ng
CFLAGS="${CFLAGS} -O3" cmake -G"Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE=${ROOT}/Toolchain.cmake -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=FALSE -DZLIB_COMPAT=TRUE -DWITH_ARMV6=FALSE
make install/strip

mkdir ${DEPS}/ffi
$CURL https://github.com/libffi/libffi/releases/download/v${VERSION_FFI}/libffi-${VERSION_FFI}.tar.gz | tar xzC ${DEPS}/ffi --strip-components=1
cd ${DEPS}/ffi
./configure --host=${CHOST} --prefix=${TARGET} --enable-static --disable-shared --disable-dependency-tracking \
  --disable-builddir --disable-multi-os-directory --disable-raw-api --disable-structs --disable-docs
make install-strip

mkdir ${DEPS}/glib
$CURL https://download.gnome.org/sources/glib/$(without_patch $VERSION_GLIB)/glib-${VERSION_GLIB}.tar.xz | tar xJC ${DEPS}/glib --strip-components=1
cd ${DEPS}/glib
$CURL https://gist.github.com/kleisauke/284d685efa00908da99ea6afbaaf39ae/raw/936a6b8013d07d358c6944cc5b5f0e27db707ace/glib-without-gregex.patch | patch -p1
meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
  --force-fallback-for=gvdb -Dintrospection=disabled -Dnls=disabled -Dlibmount=disabled -Dsysprof=disabled -Dlibelf=disabled \
  -Dtests=false -Dglib_assert=false -Dglib_checks=false -Dglib_debug=disabled ${DARWIN:+-Dbsymbolic_functions=false}
# bin-devel is needed for glib-compile-resources
meson install -C _build --tag bin-devel,devel


mkdir ${DEPS}/xml2
$CURL https://download.gnome.org/sources/libxml2/$(without_patch $VERSION_XML2)/libxml2-${VERSION_XML2}.tar.xz | tar xJC ${DEPS}/xml2 --strip-components=1
cd ${DEPS}/xml2
meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
  -Dminimum=true
meson install -C _build --tag devel

mkdir ${DEPS}/exif
$CURL https://github.com/libexif/libexif/releases/download/v${VERSION_EXIF}/libexif-${VERSION_EXIF}.tar.xz | tar xJC ${DEPS}/exif --strip-components=1
cd ${DEPS}/exif
./configure --host=${CHOST} --prefix=${TARGET} --enable-static --disable-shared --disable-dependency-tracking \
  --disable-nls --without-libiconv-prefix --without-libintl-prefix \
  CPPFLAGS="${CPPFLAGS} -DNO_VERBOSE_TAG_DATA"
make install-strip doc_DATA=

mkdir ${DEPS}/lcms2
$CURL https://github.com/mm2/Little-CMS/releases/download/lcms${VERSION_LCMS2}/lcms2-${VERSION_LCMS2}.tar.gz | tar xzC ${DEPS}/lcms2 --strip-components=1
cd ${DEPS}/lcms2
CFLAGS="${CFLAGS} -O3" meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
  -Dtests=disabled
meson install -C _build --tag devel


mkdir ${DEPS}/png16
$CURL https://downloads.sourceforge.net/project/libpng/libpng16/${VERSION_PNG16}/libpng-${VERSION_PNG16}.tar.xz | tar xJC ${DEPS}/png16 --strip-components=1
cd ${DEPS}/png16
./configure --host=${CHOST} --prefix=${TARGET} --enable-static --disable-shared --disable-dependency-tracking \
  --disable-tools --without-binconfigs --disable-unversioned-libpng-config
make install-strip dist_man_MANS=

mkdir ${DEPS}/spng
$CURL https://github.com/randy408/libspng/archive/v${VERSION_SPNG}.tar.gz | tar xzC ${DEPS}/spng --strip-components=1
cd ${DEPS}/spng
CFLAGS="${CFLAGS} -O3 -DSPNG_SSE=4" meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
  -Dstatic_zlib=true -Dbuild_examples=false
meson install -C _build --tag devel

mkdir ${DEPS}/imagequant
$CURL https://github.com/lovell/libimagequant/archive/v${VERSION_IMAGEQUANT}.tar.gz | tar xzC ${DEPS}/imagequant --strip-components=1
cd ${DEPS}/imagequant
CFLAGS="${CFLAGS} -O3" meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON}
meson install -C _build --tag devel

mkdir ${DEPS}/webp
$CURL https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${VERSION_WEBP}.tar.gz | tar xzC ${DEPS}/webp --strip-components=1
cd ${DEPS}/webp
./configure --host=${CHOST} --prefix=${TARGET} --enable-static --disable-shared --disable-dependency-tracking \
  --enable-libwebpmux --enable-libwebpdemux
make install-strip bin_PROGRAMS= noinst_PROGRAMS= man_MANS=

build_freetype() {
  rm -rf ${DEPS}/freetype
  mkdir ${DEPS}/freetype
  $CURL https://github.com/freetype/freetype/archive/VER-${VERSION_FREETYPE//./-}.tar.gz | tar xzC ${DEPS}/freetype --strip-components=1
  cd ${DEPS}/freetype
  meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
    -Dzlib=enabled -Dpng=enabled -Dbrotli=disabled -Dbzip2=disabled "$@"
  meson install -C _build --tag devel
}
build_freetype -Dharfbuzz=disabled

mkdir ${DEPS}/expat
$CURL https://github.com/libexpat/libexpat/releases/download/R_${VERSION_EXPAT//./_}/expat-${VERSION_EXPAT}.tar.xz | tar xJC ${DEPS}/expat --strip-components=1
cd ${DEPS}/expat
./configure --host=${CHOST} --prefix=${TARGET} --enable-static --disable-shared \
  --disable-dependency-tracking --without-xmlwf --without-docbook --without-getrandom --without-sys-getrandom \
  --without-libbsd --without-examples --without-tests
make install-strip dist_cmake_DATA= nodist_cmake_DATA=


mkdir ${DEPS}/fontconfig
$CURL https://www.freedesktop.org/software/fontconfig/release/fontconfig-${VERSION_FONTCONFIG}.tar.xz | tar xJC ${DEPS}/fontconfig --strip-components=1
cd ${DEPS}/fontconfig
meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
  -Dcache-build=disabled -Ddoc=disabled -Dnls=disabled -Dtests=disabled -Dtools=disabled
meson install -C _build --tag devel

mkdir ${DEPS}/harfbuzz
$CURL https://github.com/harfbuzz/harfbuzz/archive/${VERSION_HARFBUZZ}.tar.gz | tar xzC ${DEPS}/harfbuzz --strip-components=1
cd ${DEPS}/harfbuzz
# Disable utils
sed -i'.bak' "/subdir('util')/d" meson.build
meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
  -Dgobject=disabled -Dicu=disabled -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled -Dbenchmark=disabled ${DARWIN:+-Dcoretext=enabled}
meson install -C _build --tag devel

# pkg-config provided by Amazon Linux 2 doesn't support circular `Requires` dependencies.
# https://bugs.freedesktop.org/show_bug.cgi?id=7331
# https://gitlab.freedesktop.org/pkg-config/pkg-config/-/commit/6d6dd43e75e2bc82cfe6544f8631b1bef6e1cf45
# TODO(kleisauke): Remove when Amazon Linux 2 reaches EOL.
sed -i'.bak' "/^Requires:/s/ freetype2.*,//" ${TARGET}/lib/pkgconfig/harfbuzz.pc
sed -i'.bak' "/^Libs:/s/$/ -lfreetype/" ${TARGET}/lib/pkgconfig/harfbuzz.pc

build_freetype -Dharfbuzz=enabled

mkdir ${DEPS}/pixman
$CURL https://cairographics.org/releases/pixman-${VERSION_PIXMAN}.tar.gz | tar xzC ${DEPS}/pixman --strip-components=1
cd ${DEPS}/pixman
meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
  -Dlibpng=disabled -Dgtk=disabled -Dopenmp=disabled -Dtests=disabled -Ddemos=disabled \
  ${WITHOUT_NEON:+-Da64-neon=disabled}
meson install -C _build --tag devel

mkdir ${DEPS}/cairo
$CURL https://cairographics.org/releases/cairo-${VERSION_CAIRO}.tar.xz | tar xJC ${DEPS}/cairo --strip-components=1
cd ${DEPS}/cairo
meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
  ${LINUX:+-Dquartz=disabled} ${DARWIN:+-Dquartz=enabled} -Dfreetype=enabled -Dfontconfig=enabled -Dtee=disabled -Dxcb=disabled -Dxlib=disabled -Dzlib=disabled \
  -Dtests=disabled -Dspectre=disabled -Dsymbol-lookup=disabled
meson install -C _build --tag devel

mkdir ${DEPS}/fribidi
$CURL https://github.com/fribidi/fribidi/releases/download/v${VERSION_FRIBIDI}/fribidi-${VERSION_FRIBIDI}.tar.xz | tar xJC ${DEPS}/fribidi --strip-components=1
cd ${DEPS}/fribidi
meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
  -Ddocs=false -Dbin=false -Dtests=false
meson install -C _build --tag devel

mkdir ${DEPS}/pango
$CURL https://download.gnome.org/sources/pango/$(without_patch $VERSION_PANGO)/pango-${VERSION_PANGO}.tar.xz | tar xJC ${DEPS}/pango --strip-components=1
cd ${DEPS}/pango
# Disable utils and tools
sed -i'.bak' "/subdir('utils')/{N;d;}" meson.build
meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
  -Ddocumentation=false -Dbuild-testsuite=false -Dbuild-examples=false -Dintrospection=disabled -Dfontconfig=enabled
meson install -C _build --tag devel

# mkdir ${DEPS}/rsvg
# $CURL https://download.gnome.org/sources/librsvg/$(without_patch $VERSION_RSVG)/librsvg-${VERSION_RSVG}.tar.xz | tar xJC ${DEPS}/rsvg --strip-components=1
# cd ${DEPS}/rsvg
# # Disallow GIF and WebP embedded in SVG images
# sed -i'.bak' "/image = /s/, \"gif\", \"webp\"//" rsvg/Cargo.toml
# # We build Cairo with `-Dzlib=disabled`, which implicitly disables the PDF/PostScript surface backends
# sed -i'.bak' "/cairo-rs = /s/, \"pdf\", \"ps\"//" {librsvg-c,rsvg}/Cargo.toml
# # Skip build of rsvg-convert
# sed -i'.bak' "/subdir('rsvg_convert')/d" meson.build
# # https://gitlab.gnome.org/GNOME/librsvg/-/merge_requests/1066#note_2356762
# sed -i'.bak' "/^if host_system in \['windows'/s/, 'linux'//" meson.build
# # Regenerate the lockfile after making the above changes
# cargo update --workspace
# # Remove the --static flag from the PKG_CONFIG env since Rust does not
# # parse that correctly.
# PKG_CONFIG=${PKG_CONFIG/ --static/} meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
#   -Dintrospection=disabled -Dpixbuf{,-loader}=disabled -Ddocs=disabled -Dvala=disabled -Dtests=false \
#   ${RUST_TARGET:+-Dtriplet=$RUST_TARGET}
# meson install -C _build --tag devel


mkdir ${DEPS}/vips
git clone https://github.com/gemini133/libvips -b resvg vips
cd ${DEPS}/vips

if [ "$LINUX" = true ]; then
  # Ensure symbols from external libs (except for libglib-2.0.a and libgobject-2.0.a) are not exposed
  EXCLUDE_LIBS=$(find ${TARGET}/lib -maxdepth 1 -name '*.a' ! -name 'libglib-2.0.a' ! -name 'libgobject-2.0.a' -printf "-Wl,--exclude-libs=%f ")
  EXCLUDE_LIBS=${EXCLUDE_LIBS%?}
  # Localize the g_param_spec_types symbol to avoid collisions with shared libraries
  # See: https://github.com/lovell/sharp/issues/2535#issuecomment-766400693
  printf "{local:g_param_spec_types;};" > vips.map
fi
sed -i'.bak' "/subdir('man')/{N;N;N;N;d;}" meson.build
echo "subdir('tools')" >> meson.build
CFLAGS="${CFLAGS} -O3" CXXFLAGS="${CXXFLAGS} -O3" meson setup _build --default-library=shared --buildtype=release --strip --prefix=${TARGET} ${MESON} \
  -Ddeprecated=false -Dexamples=false -Dintrospection=disabled -Dmodules=disabled -Dcfitsio=disabled -Dfftw=disabled -Djpeg-xl=disabled \
  -Dmagick=disabled -Dmatio=disabled -Dnifti=disabled -Dopenexr=disabled -Dopenjpeg=disabled -Dopenslide=disabled \
  -Dpdfium=enabled -Dpoppler=disabled -Dquantizr=disabled \
  -Dppm=false -Danalyze=false -Dheif=disabled -Dradiance=false -Dtiff=disabled -Dcgif=disabled -Dnsgif=false -Darchive=disabled -Dresvg=enabled  \
  ${LINUX:+-Dcpp_link_args="$LDFLAGS -Wl,-Bsymbolic-functions -Wl,--version-script=$DEPS/vips/vips.map $EXCLUDE_LIBS"}
meson install -C _build

# Cleanup
rm -rf ${TARGET}/lib/{pkgconfig,.libs,*.la,cmake}

mkdir ${TARGET}/lib-filtered
mv ${TARGET}/lib/glib-2.0 ${TARGET}/lib-filtered

# Pack only the relevant libraries
# Note: we can't use ldd on Linux, since that can only be executed on the target machine
# Note 2: we modify all dylib dependencies to use relative paths on macOS
function copydeps {
  local base=$1
  local dest_dir=$2

  cp -L $base $dest_dir/$base
  chmod 644 $dest_dir/$base

  if [ "$LINUX" = true ]; then
    local dependencies=$(readelf -d $base | grep NEEDED | awk '{ print $5 }' | tr -d '[]')
  elif [ "$DARWIN" = true ]; then
    local dependencies=$(otool -LX $base | awk '{print $1}' | grep $TARGET)

    install_name_tool -id @loader_path/$base $dest_dir/$base
  fi

  for dep in $dependencies; do
    base_dep=$(basename $dep)

    if [ "$DARWIN" = true ]; then
      # dylib names can have extra versioning in ...
      # libgobject-2.0.0.dylib -> libgobject-2.0.dylib
      base_dep=$(echo $base_dep | sed -E "s/(\.[0-9])\.[0-9]./\1./")
    fi

    [ ! -e "$PWD/$base_dep" ] && echo "$base_dep does not exist in $PWD" && continue
    echo "$base depends on $base_dep"

    if [ ! -f "$dest_dir/$base_dep" ]; then
      if [ "$DARWIN" = true ]; then
        install_name_tool -change $dep @loader_path/$base_dep $dest_dir/$base
      fi

      # Call this function (recursive) on each dependency of this library
      copydeps $base_dep $dest_dir
    fi
  done;
}

cd ${TARGET}/lib
if [ "$LINUX" = true ]; then
  # Check that we really linked with -z nodelete
  readelf -Wd libvips.so.42 | grep -qF NODELETE || (echo "libvips.so.42 was not linked with -z nodelete" && exit 1)
fi
if [ "$PLATFORM" == "linux-arm" ]; then
  # Check that we really didn't link libstdc++ dynamically
  readelf -Wd ${VIPS_CPP_DEP} | grep -qF libstdc && echo "$VIPS_CPP_DEP is dynamically linked against libstdc++" && exit 1
fi
if [ "${PLATFORM%-*}" == "linux-musl" ]; then
  # Check that we really compiled with -D_GLIBCXX_USE_CXX11_ABI=1
  # This won't work on RHEL/CentOS 7: https://stackoverflow.com/a/52611576
  readelf -Ws ${VIPS_CPP_DEP} | c++filt | grep -qF "::__cxx11::" || (echo "$VIPS_CPP_DEP mistakenly uses the C++03 ABI" && exit 1)
fi
copydeps ${VIPS_CPP_DEP} ${TARGET}/lib-filtered

# Create JSON file of version numbers
cd ${TARGET}
printf "{\n\
  \"cairo\": \"${VERSION_CAIRO}\",\n\
  \"exif\": \"${VERSION_EXIF}\",\n\
  \"expat\": \"${VERSION_EXPAT}\",\n\
  \"ffi\": \"${VERSION_FFI}\",\n\
  \"fontconfig\": \"${VERSION_FONTCONFIG}\",\n\
  \"freetype\": \"${VERSION_FREETYPE}\",\n\
  \"fribidi\": \"${VERSION_FRIBIDI}\",\n\
  \"glib\": \"${VERSION_GLIB}\",\n\
  \"harfbuzz\": \"${VERSION_HARFBUZZ}\",\n\
  \"highway\": \"${VERSION_HWY}\",\n\
  \"imagequant\": \"${VERSION_IMAGEQUANT}\",\n\
  \"lcms\": \"${VERSION_LCMS2}\",\n\
  \"pango\": \"${VERSION_PANGO}\",\n\
  \"pixman\": \"${VERSION_PIXMAN}\",\n\
  \"png\": \"${VERSION_PNG16}\",\n\
  \"proxy-libintl\": \"${VERSION_PROXY_LIBINTL}\",\n\
  \"spng\": \"${VERSION_SPNG}\",\n\
  \"vips\": \"${VERSION_VIPS}\",\n\
  \"webp\": \"${VERSION_WEBP}\",\n\
  \"xml\": \"${VERSION_XML2}\",\n\
  \"resvg\": \"${VERSION_RESVG}\",\n\
  \"pdfium\": \"${VERSION_PDFIUM}\",\n\
  \"zlib-ng\": \"${VERSION_ZLIB_NG}\"\n\
}" >versions.json

# Add third-party notices
$CURL -O https://raw.githubusercontent.com/kleisauke/libvips-packaging/main/THIRD-PARTY-NOTICES.md

# Create the tarball
ls -al lib
rm -rf lib
mv lib-filtered lib
tar chzf ${PACKAGE}/libvips-${VERSION_VIPS}-${PLATFORM}.tar.gz \
  include \
  lib \
  versions.json \
  THIRD-PARTY-NOTICES.md

# Allow tarballs to be read outside container
chmod 644 ${PACKAGE}/libvips-${VERSION_VIPS}-${PLATFORM}.tar.gz
