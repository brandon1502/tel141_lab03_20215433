#!/bin/bash
# vm_create.sh  (en cada worker)
# Uso: vm_create.sh <VMNAME> <OVS_BRIDGE> <VLAN_ID> <VNC_PORT> <WORKER_CODE>
# WORKER_CODE esperado: w2, w3, w4 (puedes ampliar el mapa abajo)
set -e
[ "$EUID" -ne 0 ] && { echo "[ERROR] run as root"; exit 1; }

if [ "$#" -ne 5 ]; then
  echo "Uso: $0 <VMNAME> <OVS_BRIDGE> <VLAN_ID> <VNC_PORT> <WORKER_CODE>"
  exit 1
fi

VM="$1"; BR="$2"; VLAN="$3"; VNC_PORT="$4"; WK="$5"
BASE_IMG="/var/lib/libvirt/images/cirros-0.5.1-x86_64-disk.img"

# Interfaz TAP
TAP="tap_${VM}"
if ! ip link show "$TAP" >/dev/null 2>&1; then
  ip tuntap add mode tap name "$TAP"
fi
ip link set "$TAP" up
ovs-vsctl --may-exist add-port "$BR" "$TAP" tag="$VLAN"

# Display VNC (QEMU usa 5900 + display)
if [ "$VNC_PORT" -ge 5900 ]; then
  DISP=$((VNC_PORT - 5900))
else
  DISP="$VNC_PORT"
fi

# =========================
#   ESQUEMA DE MACs
#   Prefijo fijo 20:21:54:33
#   5º octeto según worker:
#     w2 -> aa, w3 -> bb, w4 -> cc  (extiende el mapa si necesitas)
#   6º octeto según número de VM (vm1->01, vm2->02, vm3->03)
# =========================
PREFIX="20:21:54:33"

case "$WK" in
  w2) WBYTE="aa" ;;
  w3) WBYTE="bb" ;;
  w4) WBYTE="cc" ;;
  *)  WBYTE="dd" ;;  # valor por defecto si llega otro worker
esac

# extrae el PRIMER grupo de dígitos del nombre (vm1_w2 -> 1)
VMNUM=$(echo "$VM" | grep -oE '[0-9]+' | head -n1 || true)
[ -z "$VMNUM" ] && VMNUM=1
LAST=$(printf "%02x" "$VMNUM")

MAC="${PREFIX}:${WBYTE}:${LAST}"

# Lanzar QEMU en background con snapshot (no modifica la base)
nohup qemu-system-x86_64 \
  -enable-kvm \
  -m 1024 -smp 2 \
  -netdev tap,id=net0,ifname="$TAP",script=no,downscript=no \
  -device e1000,netdev=net0,mac="$MAC" \
  -vnc 0.0.0.0:"$DISP" \
  -daemonize \
  -snapshot "$BASE_IMG" \
  >/var/log/qemu-"$VM".log 2>&1

echo "[OK] VM $VM: TAP=$TAP BR=$BR VLAN=$VLAN MAC=$MAC VNC=$VNC_PORT"
