### AnyKernel3 Ramdisk Mod Script
## sukisu-op15r-nova - OnePlus 15R (CPH2767), GKI boot image (header v4, ramdisk lives in init_boot)

properties() { '
kernel.string=SukiSU Nova kernel for the OnePlus 15R (Linux 6.12.69, GKI android16)
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=OP612DL1
device.name2=CPH2767IN
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
BLOCK=boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

. tools/ak3-core.sh;

ui_print " ";
ui_print "SukiSU Nova kernel for the OnePlus 15R";
ui_print "Linux 6.12.69 - SUSFS, NoMount, Baseband Guard, NTSync";
ui_print "Manager: SukiSU Nova only (com.sukisu.nova)";
ui_print " ";

# the kernel is built into the boot partition; the ramdisk is untouched (it is in init_boot on this device)
split_boot;
flash_boot;
