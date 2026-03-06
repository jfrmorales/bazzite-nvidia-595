#!/bin/bash
set -ouex pipefail

NVIDIA_VERSION="595.45.04"
NVIDIA_RUN_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run"

# --- Paso 1: Descubrir y remover paquetes NVIDIA existentes ---
# Listar paquetes nvidia (usando /usr/bin/grep para evitar alias a ripgrep)
NVIDIA_PKGS=$(rpm -qa | /usr/bin/grep -iE '^(nvidia|libnvidia|xorg-x11-nvidia|kernel-nvidia)' | sort || true)
echo "=== Paquetes NVIDIA encontrados ==="
echo "$NVIDIA_PKGS"
echo "==================================="

if [ -n "$NVIDIA_PKGS" ]; then
    # Intentar con dnf5 primero, luego rpm-ostree para paquetes base
    dnf5 remove -y $NVIDIA_PKGS 2>/dev/null || true
    # Algunos paquetes pueden ser parte de la imagen base y necesitan override remove
    REMAINING=$(rpm -qa | /usr/bin/grep -iE '^(nvidia|libnvidia|xorg-x11-nvidia|kernel-nvidia)' || true)
    if [ -n "$REMAINING" ]; then
        echo "=== Removiendo paquetes restantes con rpm-ostree ==="
        echo "$REMAINING"
        rpm-ostree override remove $REMAINING || true
    fi
fi

# También remover libva-nvidia-driver si existe
dnf5 remove -y libva-nvidia-driver 2>/dev/null || true
# Remover nvidia-container-toolkit (se reinstalará si se necesita)
dnf5 remove -y nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1 2>/dev/null || true

# --- Paso 2: Instalar dependencias de compilación ---
dnf5 install -y kernel-devel kernel-headers gcc make libglvnd-devel pkgconfig curl

# --- Paso 3: Descargar e instalar NVIDIA 595 beta ---
curl -Lo /tmp/NVIDIA-installer.run "${NVIDIA_RUN_URL}"
chmod +x /tmp/NVIDIA-installer.run

KERNEL_NAME=$(ls /usr/src/kernels/ | head -1)
echo "Compilando contra kernel: ${KERNEL_NAME}"

# The NVIDIA .run installer checks /proc/modules for loaded nvidia modules
# and aborts in --silent mode if it finds them (host's modules leak into container).
# We use --no-kernel-modules to install only userspace components,
# then compile kernel modules separately from source.

# Step 3a: Install userspace components only (no kernel module compilation)
/tmp/NVIDIA-installer.run \
    --silent \
    --no-questions \
    --no-backup \
    --no-nouveau-check \
    --no-kernel-modules \
    --no-x-check \
    --no-systemd \
    --log-file-name=/tmp/nvidia-installer.log \
    --tmpdir=/tmp \
    || { echo "=== NVIDIA Installer Log ===" ; cat /tmp/nvidia-installer.log ; exit 1 ; }

# Step 3b: Extract and compile kernel modules from the .run file
# Re-download since the first run consumed/deleted the extracted files
curl -Lo /tmp/NVIDIA-installer2.run "${NVIDIA_RUN_URL}"
chmod +x /tmp/NVIDIA-installer2.run

# Extract kernel module source to a fresh directory
/tmp/NVIDIA-installer2.run --extract-only --target /tmp/nvidia-extract
rm -f /tmp/NVIDIA-installer2.run

# Build kernel modules
cd /tmp/nvidia-extract/kernel
make \
    SYSSRC="/usr/src/kernels/${KERNEL_NAME}" \
    SYSOUT="/usr/src/kernels/${KERNEL_NAME}" \
    modules -j$(nproc)

# Install kernel modules
INSTALL_DIR="/lib/modules/${KERNEL_NAME}/extra/nvidia"
mkdir -p "${INSTALL_DIR}"
cp nvidia.ko nvidia-modeset.ko nvidia-uvm.ko nvidia-drm.ko "${INSTALL_DIR}/"

# Run depmod for the target kernel
depmod -a "${KERNEL_NAME}"

cd /
rm -rf /tmp/nvidia-extract

rm -f /tmp/NVIDIA-installer.run

# --- Paso 4: Limpiar dependencias de build ---
dnf5 remove -y kernel-devel kernel-headers gcc make libglvnd-devel cpp || true
dnf5 clean all

# --- Paso 5: Paquetes adicionales del usuario ---
dnf5 install -y tmux

systemctl enable podman.socket
