#!/usr/bin/env bash
# ============================================================
# vm_orchestrator_fase1.sh  (ejecútalo en server1 / headnode)
# - EMBEBE e INYECTA: init_worker.sh, vm_create.sh, init_ofs.sh
# - Inicializa OFS
# - Inicializa server2/server3/server4 como workers
# - Crea 3 VMs por worker: VLANs 100,200,300 (VNC 5901/5902/5903)
# Requisitos en server1: sshpass, openssh-client
# ============================================================

set -euo pipefail

#########################
# ====== CONFIG ========
#########################
USER="ubuntu"
PASS="ubuntuwu"

# IPs de Management (accesibles desde server1)
OFS_IP="10.0.10.5"
W2_IP="10.0.10.2"
W3_IP="10.0.10.3"
W4_IP="10.0.10.4"

# Bridge real del OFS y NICs de Data (ajústalas a tu slice)
OFS_BR="OFS"
OFS_DATA_PORTS=("ens4" "ens5" "ens6" "ens7")

# Bridge de los workers y su NIC “verde” (ajusta si varía)
WORKER_BR="br-int"
W2_DATA_IF="ens4"
W3_DATA_IF="ens4"
W4_DATA_IF="ens4"

# Plan de VMs por worker (3 por worker)
VMNAMES=("vm1" "vm2" "vm3")
VMS_VLANS=(100 200 300)
VMS_VNCS=(5901 5902 5903)

# Ruta remota para colocar scripts (NO usar "~" por sudo)
REMOTE_DIR="/home/ubuntu"

# Ruta de imagen base (en CADA worker)
BASE_IMG="/var/lib/libvirt/images/cirros-0.5.1-x86_64-disk.img"
BASE_URL="https://download.cirros-cloud.net/0.5.1/cirros-0.5.1-x86_64-disk.img"

############################
# ====== HELPERS SSH ======
############################
require() { command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] falta $1"; exit 1; }; }
require sshpass
require ssh
require scp

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=~/.ssh/known_hosts"

# Ejecuta comando remoto como root usando sudo -S (sin TTY) y sin prompt
RSUDO() { # RSUDO <HOST_IP> <COMMAND...>
  local HOST="$1"; shift
  local CMD="$*"
  sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$HOST" \
    "printf '%s\n' '$PASS' | sudo -S -p '' bash -lc \"$CMD\""
}

# Copia archivos al $REMOTE_DIR del usuario remoto
RSCP() { # RSCP <HOST_IP> <FILE1> [FILE2 ...]
  local HOST="$1"; shift
  sshpass -p "$PASS" scp $SSH_OPTS "$@" "$USER@$HOST:$REMOTE_DIR/"
}

#############################
# == SCRIPTS EMBEBIDOS ==
#############################
emit_init_worker() {
cat <<'EOF'
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
EOF
}

emit_vm_create() {
cat <<'EOF'
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
EOF
}

emit_init_ofs() {
cat <<'EOF'
#!/bin/bash
# init_ofs.sh  (en el OFS)
set -e
[ "$EUID" -ne 0 ] && { echo "[ERROR] run as root"; exit 1; }

if [ "$#" -lt 2 ]; then
  echo "Uso: $0 <OVS_BRIDGE> <IFACE_DATA_1> [IFACE_DATA_2 ...]"
  exit 1
fi

BR="$1"; shift
ovs-vsctl --may-exist add-br "$BR"

for IFACE in "$@"; do
  echo "[INFO] Limpiando IP en $IFACE y agregándolo a $BR"
  ip addr flush dev "$IFACE" || true
  ip link set "$IFACE" up
  ovs-vsctl --may-exist add-port "$BR" "$IFACE"
done

ip link set dev "$BR" up
echo "[OK] OFS $BR listo con puertos: $*"
EOF
}

############################################
# ====== DEPLOY: emitir + ejecutar ========
############################################
prepare_worker_base() {
  # instala deps y asegura imagen base disponible (una sola vez por worker)
  local HOST="$1"
  echo "== [Worker $HOST] preparando paquetes e imagen base"
  RSUDO "$HOST" "apt-get update -y >/dev/null 2>&1 || true; \
                 DEBIAN_FRONTEND=noninteractive apt-get install -y openvswitch-switch qemu-system-x86 qemu-kvm wget >/dev/null 2>&1 || true; \
                 mkdir -p \"$(dirname "$BASE_IMG")\"; \
                 if [ ! -f \"$BASE_IMG\" ]; then wget -O \"$BASE_IMG\" -c \"$BASE_URL\"; fi"
}

deploy_ofs() {
  local HOST="$1"
  echo "== [OFS $HOST] copiando scripts…"
  tmpdir=$(mktemp -d)
  emit_init_ofs > "$tmpdir/init_ofs.sh"
  chmod +x "$tmpdir/init_ofs.sh"
  RSCP "$HOST" "$tmpdir/init_ofs.sh"
  rm -rf "$tmpdir"

  echo "== [OFS $HOST] instalando Open vSwitch y ejecutando init_ofs"
  RSUDO "$HOST" "apt-get update -y >/dev/null 2>&1 || true; \
                 DEBIAN_FRONTEND=noninteractive apt-get install -y openvswitch-switch >/dev/null 2>&1 || true"
  RSUDO "$HOST" "chmod +x $REMOTE_DIR/init_ofs.sh && $REMOTE_DIR/init_ofs.sh $OFS_BR ${OFS_DATA_PORTS[*]}"
}

deploy_worker() {
  local HOST="$1"; local DATA_IF="$2"; local SUFFIX="$3"

  echo "== [Worker $HOST] copiando scripts…"
  tmpdir=$(mktemp -d)
  emit_init_worker > "$tmpdir/init_worker.sh"
  emit_vm_create  > "$tmpdir/vm_create.sh"
  chmod +x "$tmpdir/"*.sh
  RSCP "$HOST" "$tmpdir/init_worker.sh" "$tmpdir/vm_create.sh"
  rm -rf "$tmpdir"

  prepare_worker_base "$HOST"

  echo "== [Worker $HOST] init_worker ($WORKER_BR, $DATA_IF)"
  RSUDO "$HOST" "chmod +x $REMOTE_DIR/init_worker.sh $REMOTE_DIR/vm_create.sh; \
                 $REMOTE_DIR/init_worker.sh $WORKER_BR $DATA_IF"

  echo "== [Worker $HOST] creando 3 VMs"
  for i in "${!VMNAMES[@]}"; do
    local name="${VMNAMES[$i]}_${SUFFIX}"   # vm1_w2, vm2_w2, vm3_w2 …
    local vlan="${VMS_VLANS[$i]}"
    local vnc="${VMS_VNCS[$i]}"
    echo "   -> $name  VLAN=$vlan  VNC=$vnc"

    # Pasamos el código de worker como 5º parámetro a vm_create.sh
    if ! RSUDO "$HOST" "$REMOTE_DIR/vm_create.sh $name $WORKER_BR $vlan $vnc $SUFFIX"; then
      echo "[WARN] Falló la creación de $name en $HOST"
      RSUDO "$HOST" "tail -n 80 /var/log/qemu-$name.log || true" || true
      # Seguimos con las otras VMs
    fi
  done
}

############################################
# ================= MAIN ===================
############################################
echo ">>> Orquestador Fase 1 – inicio"

# 1) OFS
deploy_ofs "$OFS_IP"

# 2) Workers: server2, server3, server4
deploy_worker "$W2_IP" "$W2_DATA_IF" "w2"
deploy_worker "$W3_IP" "$W3_DATA_IF" "w3"
deploy_worker "$W4_IP" "$W4_DATA_IF" "w4"

echo ">>> Fase 1 COMPLETADA ✅"
echo "Verifica en cada host con: 'sudo ovs-vsctl show'"
echo "VNC por host:"
echo "  server2 ($W2_IP): 5901 / 5902 / 5903"
echo "  server3 ($W3_IP): 5901 / 5902 / 5903"
echo "  server4 ($W4_IP): 5901 / 5902 / 5903"
