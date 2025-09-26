#!/bin/bash
# init_worker.sh  (en cada worker)
set -e
[ "$EUID" -ne 0 ] && { echo "[ERROR] run as root"; exit 1; }

if [ "$#" -lt 2 ]; then
  echo "Uso: $0 <OVS_BRIDGE> <IFACE_DATA_1> [IFACE_DATA_2 ...]"
  exit 1
fi

BR="$1"; shift
ovs-vsctl --may-exist add-br "$BR"

for IFACE in "$@"; do
  echo "[INFO] Agregando $IFACE a $BR"
  ip link set "$IFACE" up
  ovs-vsctl --may-exist add-port "$BR" "$IFACE"
done

ip link set dev "$BR" up
echo "[OK] Worker listo: $BR con puertos: $*"
