#! /bin/bash

ANDROID_ROOT=$(pwd)
UBOOT_ROOT="$ANDROID_ROOT/u-boot"
KERNEL_ROOT="$ANDROID_ROOT/kernel"

CPU_JOB_NUM=$(grep processor /proc/cpuinfo | awk '{field=$NF};END{print int((field+1)/2)}')


# get variable from config file
config_get()
{
	config_item=$1
	config_data=
	CONFIG_FILE="$ANDROID_ROOT/.build_config"

	[ -e $CONFIG_FILE ] && FIND=`cat $CONFIG_FILE | grep $config_item | wc -l` || FIND=0

	if [ "$FIND" = "1" ]; then
		config_data=`cat $CONFIG_FILE | grep $config_item |\
			awk '{
				for (i=2; i <= NF; i++) {
					if (i==2) {printf $i}
					else {printf " "$i}
				}
			}'`
		ret=0
	elif [ "$FIND" = "0" ]; then
		# Not found, try default value
		if [ "$config_data" = "" ] && [ "$2" != "" ]; then
			config_data=$2
		fi
		ret=1
	else
		ret=2
		echo "[ERROR] $ret"
		exit $ret
	fi

	[ "$config_data" != "" ] && export ${config_item}="${config_data}"
	return $ret
}

check_build()
{
	return
}

check_exit()
{
	RESULT=$?
	if [ $RESULT != 0 ];then
		echo "error exit with $RESULT"
		exit $RESULT
	fi
}

sign_image()
{
	if [ $# -lt 2 ]; then
		echo "Usage: $0 <PATH> <TYPE>"
		exit -1
	fi

	TARGET_IMG=$1
	TARGET_TYPE=$2
	# TODO
}

build_loader()
{
	echo
	echo "[[[[[[[ Build loader ]]]]]]]"
	echo

	UBOOT_DEFCONFIG="rk3399_evstb_defconfig"

	pushd $UBOOT_ROOT > /dev/null
	make distclean
	make $UBOOT_DEFCONFIG
	make ARCHV=aarch64 -j${CPU_JOB_NUM}
	check_exit
	popd > /dev/null
}

build_kernel()
{
	echo
	echo "[[[[[[[ Build kernel ]]]]]]]"
	echo

	KERNEL_DEFCONFIG="${SDK_BUILD_VENDOR}_defconfig"
	KERNEL_DTS="${SDK_BUILD_VENDOR}_"$(echo $SDK_BUILD_TARGET | tr '[A-Z]' '[a-z]')
	KERNEL_RECOVERY_DTS="${KERNEL_DTS}_recovery"
	DTS_PATH="$KERNEL_ROOT/arch/arm64/boot/dts/rockchip"
	LOGO=`get_build_var TARGET_BOOT_LOGO`
	[ -n "$LOGO" ] && LOGO=$ANDROID_ROOT/$LOGO

	pushd $KERNEL_ROOT > /dev/null
	make distclean
	make ARCH=arm64 $KERNEL_DEFCONFIG
	make ARCH=arm64 ${KERNEL_DTS}.img -j${CPU_JOB_NUM}
	check_exit

	# rebuild resource.img
	scripts/resource_tool --image=${KERNEL_ROOT}/resource.img \
			${DTS_PATH}/${KERNEL_DTS}.dtb $LOGO

	if [ -f "$DTS_PATH/${KERNEL_RECOVERY_DTS}.dts" ];then
		make ARCH=arm64 rockchip/${KERNEL_RECOVERY_DTS}.dtb
		scripts/resource_tool --image=${KERNEL_ROOT}/resource_recovery.img \
				${DTS_PATH}/${KERNEL_RECOVERY_DTS}.dtb $LOGO
	else
		cp resource.img resource_recovery.img
	fi

	check_exit
	popd > /dev/null
}

build_android()
{
	echo
	echo "[[[[[[[ Build android ]]]]]]]"
	echo

	ANDROID_OUT="$ANDROID_ROOT/out/target/product/$SDK_BUILD_TARGET"

	check_build
	make installclean -j${CPU_JOB_NUM}
	make -j${CPU_JOB_NUM}
	check_exit
}

prepare_loader_bin()
{
	OUTPUT_PATH="$ANDROID_ROOT/output/$SDK_BUILD_TARGET"
	IMAGE_PATH="$OUTPUT_PATH/images"

	[ ! -d $IMAGE_PATH ] && mkdir -p $IMAGE_PATH
	cp -a $UBOOT_ROOT/uboot.img $IMAGE_PATH/uboot.img
	cp -a $UBOOT_ROOT/trust.img $IMAGE_PATH/trust.img

	if [ -f $UBOOT_ROOT/*_loader_*.bin ];then
		cp -a $UBOOT_ROOT/*_loader_*.bin $IMAGE_PATH/MiniLoaderAll.bin
	elif [ -f $UBOOT_ROOT/*loader*.bin ]; then
		cp -a $UBOOT_ROOT/*loader*.bin $IMAGE_PATH/MiniLoaderAll.bin
	else
		echo "can not found  loader.bin."
		exit 1
	fi

	sign_image $IMAGE_PATH/MiniLoaderAll.bin loader
	sign_image $IMAGE_PATH/uboot.img boot
	sign_image $IMAGE_PATH/trust.img boot
}

prepare_boot_image()
{
	echo "prepare boot image. "

	OUTPUT_PATH="$ANDROID_ROOT/output/$SDK_BUILD_TARGET"
	ANDROID_OUT="$ANDROID_ROOT/out/target/product/$SDK_BUILD_TARGET"
	IMAGE_PATH="$OUTPUT_PATH/images"
	PLATFORM_VERSION=`get_build_var PLATFORM_VERSION`
	PLATFORM_SECURITY_PATCH=`get_build_var PLATFORM_SECURITY_PATCH`

	[ ! -d $IMAGE_PATH ] && mkdir -p $IMAGE_PATH
	cp $KERNEL_ROOT/arch/arm64/boot/Image $ANDROID_OUT/kernel
	mkbootfs $ANDROID_OUT/root | minigzip > $ANDROID_OUT/ramdisk.img && \
	truncate -s "%4" $ANDROID_OUT/ramdisk.img && \
	mkbootimg --kernel $ANDROID_OUT/kernel --ramdisk $ANDROID_OUT/ramdisk.img \
		--second $KERNEL_ROOT/resource.img --os_version $PLATFORM_VERSION \
		--os_patch_level $PLATFORM_SECURITY_PATCH --cmdline \
		buildvariant=$SDK_BUILD_VARIANT --output $ANDROID_OUT/boot.img

	check_exit
	cp -a $ANDROID_OUT/boot.img $IMAGE_PATH/
	sign_image $IMAGE_PATH/boot.img boot
}

prepare_recovery_image()
{
	echo "prepare recovery image. "

	OUTPUT_PATH="$ANDROID_ROOT/output/$SDK_BUILD_TARGET"
	ANDROID_OUT="$ANDROID_ROOT/out/target/product/$SDK_BUILD_TARGET"
	IMAGE_PATH="$OUTPUT_PATH/images"
	PLATFORM_VERSION=`get_build_var PLATFORM_VERSION`
	PLATFORM_SECURITY_PATCH=`get_build_var PLATFORM_SECURITY_PATCH`

	[ ! -d $IMAGE_PATH ] && mkdir -p $IMAGE_PATH
	mkbootfs $ANDROID_OUT/recovery/root | minigzip > $ANDROID_OUT/ramdisk-recovery.img && \
	truncate -s "%4" $ANDROID_OUT/ramdisk-recovery.img && \
	mkbootimg --kernel $ANDROID_OUT/kernel --ramdisk $ANDROID_OUT/ramdisk-recovery.img \
		--second $KERNEL_ROOT/resource_recovery.img --os_version $PLATFORM_VERSION \
		--os_patch_level $PLATFORM_SECURITY_PATCH --cmdline \
		buildvariant=$SDK_BUILD_VARIANT --output $ANDROID_OUT/recovery.img

	check_exit
	cp -a $ANDROID_OUT/recovery.img $IMAGE_PATH/
	sign_image $IMAGE_PATH/recovery.img boot
}

prepare_images()
{
	echo
	echo '[[[[[[[ Prepare Images ]]]]]]]'
	echo

	OUTPUT_PATH="$ANDROID_ROOT/output/$SDK_BUILD_TARGET"
	ANDROID_OUT="$ANDROID_ROOT/out/target/product/$SDK_BUILD_TARGET"
	IMAGE_PATH="$OUTPUT_PATH/images"

	[ ! -d $IMAGE_PATH ] && mkdir -p $IMAGE_PATH
	if [ ! -d $ANDROID_OUT/root ];then
	        echo "Error: rootfs not present"
	        exit 1
	fi

	prepare_loader_bin
	prepare_boot_image
	prepare_recovery_image

	cp -a $ANDROID_OUT/system.img $IMAGE_PATH/system.img
	cp -a rkst/Image/misc.img $IMAGE_PATH/misc.img
	cp -a rkst/Image/pcba_small_misc.img $IMAGE_PATH/pcba_small_misc.img
	cp -a rkst/Image/pcba_whole_misc.img $IMAGE_PATH/pcba_whole_misc.img
	cp -a $ANDROID_ROOT/vendor/$SDK_BUILD_VENDOR/$SDK_BUILD_TARGET/etc/parameter $IMAGE_PATH/
	cp -a $ANDROID_ROOT/vendor/$SDK_BUILD_VENDOR/$SDK_BUILD_TARGET/etc/package-file $IMAGE_PATH/

	BOARD_HAVE_BASEPARAMETER=$(get_build_var BOARD_BASEPARAMETER_SUPPORT)
	if [ "$BOARD_HAVE_BASEPARAMETER" == "true" ];then
		TARGET_BASE_PARAMETER_IMAGE=$(get_build_var TARGET_BASE_PARAMETER_IMAGE)
		cp -a $TARGET_BASE_PARAMETER_IMAGE $IMAGE_PATH/baseparameter.img
	fi

	chmod a+r -R $IMAGE_PATH/
}

build_update_image()
{
	echo "create update.img.."

	OUTPUT_PATH="$ANDROID_ROOT/output/$SDK_BUILD_TARGET"
	OUT_IMG="$OUTPUT_PATH/${SDK_BUILD_TARGET}-v${SDK_BUILD_VERSION}-${SDK_BUILD_VARIANT}.img"
	IMAGE_PATH="$OUTPUT_PATH/images"
	PACK_TOOL_PATH="$ANDROID_ROOT/RKTools/linux/Linux_Pack_Firmware/rockdev"
	TMP_IMG="$IMAGE_PATH/update.img"

	$PACK_TOOL_PATH/afptool -pack $IMAGE_PATH $TMP_IMG
	$PACK_TOOL_PATH/rkImageMaker -RK330C $IMAGE_PATH/MiniLoaderAll.bin $TMP_IMG $OUT_IMG -os_type:androidos
	check_exit

	rm -rf $TMP_IMG
	sign_image $OUT_IMG fw
	echo "UPDATE IMAGE: $OUT_IMG"

	rm -rf $ANDROID_ROOT/output/target
	rm -rf $OUTPUT_PATH/update.img
	ln -s $(basename $SDK_BUILD_TARGET) $ANDROID_ROOT/output/target
	ln -s $(basename $OUT_IMG) $OUTPUT_PATH/update.img
}

build_otapackage()
{
	echo
	echo '[[[[[[[ Build otapackage ]]]]]]]'
	echo

	PRODUCT_NAME="${SDK_BUILD_VENDOR}_"$(echo $SDK_BUILD_TARGET | tr '[A-Z]' '[a-z]')
	ANDROID_OUT="$ANDROID_ROOT/out/target/product/$SDK_BUILD_TARGET"
	OUTPUT_PATH="$ANDROID_ROOT/output/$SDK_BUILD_TARGET"

	check_build
	make installclean -j${CPU_JOB_NUM}
	make otapackage -j${CPU_JOB_NUM}
	check_exit

	[ ! -d $OUTPUT_PATH ] && mkdir -p $OUTPUT_PATH

	OUT_ZIP="$OUTPUT_PATH/${SDK_BUILD_TARGET}-ota-v${SDK_BUILD_VERSION}-${SDK_BUILD_VARIANT}.zip"
	cp $ANDROID_OUT/${PRODUCT_NAME}-ota-*.$(whoami)*.zip $OUT_ZIP

	echo "OTA PACKAGE: $OUT_ZIP."
}


echo "setup environment..."

config_get SDK_BUILD_TARGET
config_get SDK_BUILD_VARIANT
config_get SDK_BUILD_VERSION
config_get SDK_BUILD_VENDOR

# setup JDK
export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
export PATH=$JAVA_HOME/bin:$PATH
export CLASSPATH=.:$JAVA_HOME/lib:$JAVA_HOME/lib/tools.jar

PRODUCT_NAME="${SDK_BUILD_VENDOR}_"$(echo $SDK_BUILD_TARGET | tr '[A-Z]' '[a-z]')
source build/envsetup.sh
lunch ${PRODUCT_NAME}-${SDK_BUILD_VARIANT}

OPTION=$1
case "$OPTION" in
	loader)
		build_loader
		prepare_loader_bin
		;;
	boot)
		build_kernel
		prepare_boot_image
		;;
	recovery)
		build_kernel
		prepare_recovery_image
		;;
	update)
		build_loader
		build_kernel
		build_android
		prepare_images
		build_update_image
		;;
	ota)
		build_otapackage
		;;
	"")
		build_loader
		build_kernel
		build_android
		prepare_images
		build_update_image
		build_otapackage
		;;
	*)
                echo "Unknown option."
		echo
		echo "usage:"
		echo "$0 [update|ota|loader|boot|recovery]"
		echo
		echo "$0          : build all, include update image and ota package."
		echo "$0 update   : build update.img."
		echo "$0 ota      : build ota package."
		echo "$0 loader   : build loader."
		echo "$0 boot     : build boot.img."
		echo "$0 recovery : build recovery.img."
		;;
esac
