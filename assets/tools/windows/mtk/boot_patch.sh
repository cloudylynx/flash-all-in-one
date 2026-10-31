#!/bin/sh
KEEPVERITY=false
KEEPFORCEENCRYPT=false
RECOVERYMODE=false

export KEEPVERITY
export KEEPFORCEENCRYPT
BOOTIMAGE=$1
IS64BIT=$2
KEEPVERITY=$3
KEEPFORCEENCRYPT=$4

./magiskboot unpack "$BOOTIMAGE"
case $? in
  0 ) ;;
  1 )
    echo "! Unsupported/Unknown image format"
    ;;
  2 )
    echo "- ChromeOS boot image detected"
	echo "ChromeOS not support on windows"
    CHROMEOS=true
	exit 1
    ;;
  * )
    echo "! Unable to unpack boot image"
	exit 1
    ;;
esac

[ -f recovery_dtbo ] && RECOVERYMODE=true

echo "- Checking ramdisk status"
if [ -e ramdisk.cpio ]; then
  ./magiskboot cpio ramdisk.cpio test
  STATUS=$?
else
  STATUS=0
fi

case $((STATUS & 3)) in
  0 )  # Stock boot
    echo "- Stock boot image detected"
    SHA1=$(./magiskboot sha1 "$BOOTIMAGE" 2>/dev/null)
    cat $BOOTIMAGE > stock_boot.img
    cp -af ramdisk.cpio ramdisk.cpio.orig 2>/dev/null
    ;;
  1 )  # Magisk patched
    echo "- Magisk patched boot image detected"
    [ -z $SHA1 ] && SHA1=$(./magiskboot cpio ramdisk.cpio sha1 2>/dev/null)
    ./magiskboot cpio ramdisk.cpio restore
    cp -af ramdisk.cpio ramdisk.cpio.orig
    rm -f stock_boot.img
    ;;
  2 )  # Unsupported
    echo "! Boot image patched by unsupported programs"
    echo "! Please restore back to stock boot image"
	exit 1
    ;;
esac

echo "- Patching ramdisk"

echo "KEEPVERITY=$KEEPVERITY" > config
echo "KEEPFORCEENCRYPT=$KEEPFORCEENCRYPT" >> config
echo "RECOVERYMODE=$RECOVERYMODE" >> config
[ ! -z $SHA1 ] && echo "SHA1=$SHA1" >> config

$IS64BIT && SKIP64="" || SKIP64="#"

if [ -f "init-ld" ]; then
    ./magiskboot compress=xz init-ld init-ld.xz
    SDL=""
else
    SDL="#"
fi

if [ -f "stub.apk" ]; then
    ./magiskboot compress=xz stub.apk stub.xz
    SDT=""
else
    SDT="#"
fi

if [ -f "magisk32" ]; then
    ./magiskboot compress=xz magisk32 magisk32.xz
    ./magiskboot compress=xz magisk64 magisk64.xz
    SDN="#" && SDO=""
else
    ./magiskboot compress=xz magisk magisk.xz
    SDN="" && SDO="#"
fi

./magiskboot cpio ramdisk.cpio \
"add 0750 init magiskinit" \
"mkdir 0750 overlay.d" \
"mkdir 0750 overlay.d/sbin" \
"$SDN add 0644 overlay.d/sbin/magisk.xz magisk.xz" \
"$SDO add 0644 overlay.d/sbin/magisk32.xz magisk32.xz" \
"$SDO $SKIP64 add 0644 overlay.d/sbin/magisk64.xz magisk64.xz" \
"$SDT add 0644 overlay.d/sbin/stub.xz stub.xz" \
"$SDL add 0644 overlay.d/sbin/init-ld.xz init-ld.xz" \
"patch" \
"backup ramdisk.cpio.orig" \
"mkdir 000 .backup" \
"add 000 .backup/.magisk config"


rm -f ramdisk.cpio.orig config *.xz

for dt in dtb kernel_dtb extra; do
  [ -f $dt ] && ./magiskboot dtb $dt patch && echo "- Patch fstab in $dt"
done

if [ -f kernel ]; then
  ./magiskboot hexpatch kernel \
  49010054011440B93FA00F71E9000054010840B93FA00F7189000054001840B91FA00F7188010054 \
  A1020054011440B93FA00F7140020054010840B93FA00F71E0010054001840B91FA00F7181010054
  ./magiskboot hexpatch kernel 821B8012 E2FF8F12
  ./magiskboot hexpatch kernel \
  70726F63615F636F6E66696700 \
  70726F63615F6D616769736B00
  ./magiskboot hexpatch kernel \
  736B69705F696E697472616D667300 \
  77616E745F696E697472616D667300
fi
echo "- Repacking boot image"
./magiskboot repack "$BOOTIMAGE" || echo "! Unable to repack boot image"

true
