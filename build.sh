#!/bin/bash

# Clean up from previous run
rm -rf build/ || true

# Install build dependencies

sudo apt-get -y install git autoconf libtool make gcc libtool libfuse-dev liblzma-dev libglib2.0-dev
# libtool-bin might be required in newer distributions but is not available in precise

# Patch squashfuse_ll to be a library rather than an executable

cd squashfuse
patch -p1 < ../squashfuse.patch

# Build libsquashfuse_ll library

libtoolize --force
aclocal
autoheader
automake --force-missing --add-missing
autoconf

./configure --with-xz=/usr/lib/

sed -i -e 's|-O2|-Os|g' Makefile # Optimize for size

make

cd ..

mkdir build
cd build

# Compile runtime but do not link

cc -D_FILE_OFFSET_BITS=64 -g -Os -c ../runtime.c

# Prepare 1024 bytes of space for updateinformation
printf '\0%.0s' {0..1023} > updateinformation

objcopy --add-section .upd_info=updateinformation \
          --set-section-flags .upd_info=noload,readonly runtime.o runtime2.o

# Now statically link against libsquashfuse_ll, libsquashfuse and liblzma
# and embed updateinformation section

cc ../elf.c runtime2.o ../squashfuse/.libs/libsquashfuse_ll.a ../squashfuse/.libs/libsquashfuse.a ../squashfuse/.libs/libfuseprivate.a -Wl,-Bdynamic -lfuse -lpthread -lz -Wl,-Bstatic -llzma -Wl,-Bdynamic -o runtime
strip runtime

# Test if we can read it back
readelf -x .upd_info runtime # hexdump
readelf -p .upd_info runtime || true # string

# The raw updateinformation data can be read out manually like this:
HEXOFFSET=$(objdump -h runtime | grep .upd_info | awk '{print $6}')
HEXLENGTH=$(objdump -h runtime | grep .upd_info | awk '{print $3}')
dd bs=1 if=runtime skip=$(($(echo 0x$HEXOFFSET)+0)) count=$(($(echo 0x$HEXLENGTH)+0)) | xxd

# Insert AppImage magic bytes

printf '\x41\x49\x02' | dd of=runtime bs=1 seek=8 count=3 conv=notrunc

# Convert runtime into a data object that can be embedded into appimagetool

ld -r -b binary -o data.o runtime

# Compile appimagetool but do not link - glib version

cc -D_FILE_OFFSET_BITS=64 -I ../squashfuse $(pkg-config --cflags glib-2.0) -I/usr/lib/x86_64-linux-gnu/glib-2.0/include -g -Os -c ../appimagetool.c

# Now statically link against libsquashfuse and liblzma - glib version

cc data.o appimagetool.o ../elf.c -DENABLE_BINRELOC ../binreloc.c ../squashfuse/.libs/libsquashfuse.a ../squashfuse/.libs/libfuseprivate.a -Wl,-Bdynamic -lfuse -lpthread  $(pkg-config --libs glib-2.0) -lz -Wl,-Bstatic -llzma -Wl,-Bdynamic -o appimagetool

# Version without glib
# cc -D_FILE_OFFSET_BITS=64 -I ../squashfuse -I/usr/lib/x86_64-linux-gnu/glib-2.0/include -g -Os -c ../appimagetoolnoglib.c
# cc data.o appimagetoolnoglib.o -DENABLE_BINRELOC ../binreloc.c ../squashfuse/.libs/libsquashfuse.a ../squashfuse/.libs/libfuseprivate.a -Wl,-Bdynamic -lfuse -lpthread -lz -Wl,-Bstatic -llzma -Wl,-Bdynamic -o appimagetoolnoglib

cd ..

# Reset squashfuse to its original state

cd squashfuse
git reset --hard
cd -

# Strip and check size and dependencies

strip build/appimage*
ldd build/appimagetool
ls -l build/*
