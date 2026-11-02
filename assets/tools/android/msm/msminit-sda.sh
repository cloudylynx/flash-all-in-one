#!/busybox ash
/busybox mkdir -p /dev /proc /sys /root /configfs
/busybox mountpoint -q /dev||/busybox mount -t devtmpfs devfs /dev
/busybox mountpoint -q /dev||/busybox mount -t tmpfs devfs /dev
/busybox mountpoint -q /sys||/busybox mount -t sysfs sysfs /sys
/busybox mountpoint -q /proc||/busybox mount -t proc proc /proc
/busybox mountpoint -q /configfs||/busybox mount -t configfs configfs /configfs
/busybox mdev -s
cd /configfs/usb_gadget
/busybox mkdir g0
cd g0
echo 0x05F9 > idVendor
echo 0x1234 > idProduct
echo 0x0200 > bcdUSB
/busybox mkdir configs/a.1 strings/0x409
echo 1234567890 > strings/0x409/serialnumber
echo USB > strings/0x409/manufacturer
echo MassStorage > strings/0x409/product
echo 1 > os_desc/use
echo 0x1 > os_desc/b_vendor_code
echo MSFT100 > os_desc/qw_sign
ln -s configs/a.1 os_desc/a.1
/busybox mkdir configs/a.1/strings/0x409
b=0
for i in /dev/sda
do	b=$((b+1))
	/busybox mkdir functions/mass_storage.blk$b
	/busybox echo $i > functions/mass_storage.blk$b/lun.0/file
	/busybox ln -s functions/mass_storage.blk$b configs/a.1/blk$b
done
for i in /sys/class/udc/*
do	/busybox basename $i > UDC
	break
done
while true
do /busybox 3600
done
