#!/bin/bash

set -e

# Remastering TinyCore for Packer Usage
#
# This script will create a TinyCore ISO that is ready to be used in Packer. It is
# an automated version of the guide at:
#
#   http://wiki.tinycorelinux.net/wiki:remastering
#
# You need to run this on a system that has following commands available:
#   * unsquashfs (squashfs-tools)
#   * advdef (advancecomp)
#   * mkisofs (mkisofs)
#
# Additional customizations can be added to the customize function.
#
# Feel free to include additional extension by adding them to the following array:

readonly EXTENSIONS=(bash openssh acpid)

# Global variables
readonly MIRROR_URL=http://distro.ibiblio.org/tinycorelinux/7.x/x86
readonly DIST=./dist
readonly BUILD=./build
readonly DOWNLOADS=./downloads

main() {
  prepare
  explode_iso
  download_extensions
  unpack_extensions
  customize_vagrant
  customize_acpid
  repack_core
  remaster_iso
  calculate_checksum
}

prepare() {
  rm -rf $DIST
  rm -rf $BUILD
  mkdir -p $DIST
  mkdir -p $BUILD

  [[ ! -d "$DOWNLOADS" ]] && mkdir -p $DOWNLOADS

  return 0
}

download() {
  local url=$1
  local file=$DOWNLOADS/${url##*/}

  if [[ ! -f "$file" ]]; then
    wget -q -P $DOWNLOADS $url
  fi
}

download_tcz() {
  local tcz=$1
  local baseurl="$MIRROR_URL/tcz"
  local extension="$baseurl/$tcz"

  download "$extension"
  download "$extension.dep" || true

  if [[ -f "$DOWNLOADS/$tcz.dep" ]]; then
    for dep in $(cat $DOWNLOADS/$tcz.dep)
    do
      download_tcz $dep
    done
  fi
}

explode_iso() {
  local url=$MIRROR_URL/release/Core-current.iso
  local iso=$DOWNLOADS/${url##*/}
  local source=/mnt/tmp

  download $url

  [[ ! -d "$source" ]] && mkdir -p $source

  mount $iso $source -o loop,ro
  cp -a $source/boot $DIST
  zcat $DIST/boot/core.gz | (cd $BUILD && cpio -i -H newc -d)
  umount $source
}

download_extensions() {
  for extension in "${EXTENSIONS[@]}"
  do
    download_tcz "$extension.tcz"
  done
}

unpack_extensions() {
  for extension in $DOWNLOADS/*.tcz
  do
    unsquashfs -f -d $BUILD $extension
  done
}

repack_core() {
  ldconfig -r $BUILD
  (cd $BUILD && find | cpio -o -H newc | gzip -2 > ../core.gz)
  advdef -z4 core.gz
}

remaster_iso() {
  mv core.gz $DIST/boot
  mkisofs -l -J -R -V TC-custom -no-emul-boot -boot-load-size 4 \
    -boot-info-table -b boot/isolinux/isolinux.bin \
    -c boot/isolinux/boot.cat -o tinycore-vagrant.iso $DIST
}

calculate_checksum() {
  local md5=($(md5sum tinycore-vagrant.iso))

  echo "Remastering done. The md5 checksum of the new iso is: ${md5}"
}

customize_vagrant() {
  ( cd $BUILD/usr/local/etc/ssh \
      && mv sshd_config.example sshd_config \
      && sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' sshd_config
  )

  echo "vagrant:x:1002:50::/home/vagrant:/bin/sh" >> $BUILD/etc/passwd
  echo 'vagrant:$6$zaJNfMJj$X/Rz7jgVcgYc7pP6UpfjZxGE1xgFIF2etlIAKSITix7F8u4zBvGazVW/Y25/EbbJzlqFCBAzh/nL2tNyBqA7i.:16240:0:999999:7:::' >> $BUILD/etc/shadow
  mkdir -p $BUILD/home/vagrant
  chown 1002:50 $BUILD/home/vagrant
  echo "vagrant	ALL=NOPASSWD: ALL" >> $BUILD/etc/sudoers
  sed -i 's/tty1::respawn:\/sbin\/getty -nl \/sbin\/autologin 38400 tty1/tty1::respawn:\/sbin\/getty 38400 tty1/' $BUILD/etc/inittab
  echo "/usr/local/etc/init.d/openssh start" >> $BUILD/opt/bootlocal.sh
}

customize_acpid() {
  mkdir -p $BUILD/usr/local/etc/acpi/events/
  mkdir -p $BUILD/home/tc/.acpi/
  echo "event=.*" >> $BUILD/usr/local/etc/acpi/events/all
  echo 'action=/home/tc/.acpi/gen.sh "%e"' >> $BUILD/usr/local/etc/acpi/events/all
  cat <<'EOF' > $BUILD/home/tc/.acpi/gen.sh
#!/bin/sh
case $1 in
    button/power*)
       exitcheck.sh shutdown;; #power button code, with backup
    button/sleep*)
        echo -n "mem" > /sys/power/state;; # sleep button code
    "hotkey ATKD 0000001a"*) # special key #1 extra assigned sleep button
	 echo -n "mem" > /sys/power/state;;
    "hotkey ATKD 0000001d"*)
         exitcheck.sh reboot;; # special key #4 reboot with backup
    # *)
    # popup $1;;
esac
EOF
  chown -R 1001 $BUILD/home/tc/.acpi
  chmod 755 $BUILD/home/tc/.acpi/gen.sh

  echo "acpid" >> $BUILD/opt/bootlocal.sh
}

main
