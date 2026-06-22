# syntax=docker/dockerfile:1
#
# Kodi HTPC as a bootc image.
# Target hardware: AMD Ryzen 5 5600G (Cezanne / Vega iGPU), x86_64.
# Boots directly into Kodi (GBM, no desktop, no display manager).

ARG FEDORA_VERSION=44
FROM quay.io/fedora/fedora-bootc:${FEDORA_VERSION}

# --- Freshness ------------------------------------------------------------
# Pull the latest version of everything in the base. Combined with the nightly
# CI rebuild, this means a fix released today ships tonight, instead of waiting
# for Fedora to republish the base image tag.
RUN dnf -y --refresh upgrade && \
    dnf clean all && \
    rm -rf /var/cache/* /var/log/* /tmp/* /var/tmp/*

# --- Media / driver stack -------------------------------------------------
# RPMFusion (free) provides Kodi and the unstripped Mesa VA-API drivers that
# enable real hardware video decode (H.264/HEVC/VP9/AV1) on the Vega iGPU.
RUN dnf -y install \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" && \
    # --allowerasing lets the RPMFusion freeworld drivers (real HW codecs)
    # replace Fedora's codec-stripped Mesa drivers in one transaction.
    dnf -y install --allowerasing --setopt=install_weak_deps=False \
        mesa-va-drivers-freeworld \
        kodi \
        kodi-inputstream-adaptive \
        kodi-peripheral-joystick \
        libva-utils \
        libcec \
        alsa-utils \
        && \
    # Drop multi-arch container emulation the base pulled in as a weak dep;
    # a Kodi appliance never runs foreign-arch containers.
    dnf -y remove "qemu-user-static*" && \
    dnf clean all && \
    rm -rf /var/cache/* /var/log/* /tmp/* /var/tmp/*

# --- System config (user, service, polkit, tmpfiles, tailscale repo) ------
# Everything under files/ mirrors the target rootfs layout.
COPY files/ /

# --- Remote access --------------------------------------------------------
# Tailscale only. `tailscaled` serves SSH itself (tailnet ACL auth), so no
# openssh and nothing listening on port 22 — the only way in is the tailnet.
# Run `tailscale up --ssh` once from the local console; state persists in /var.
RUN dnf -y install --setopt=install_weak_deps=False tailscale && \
    dnf clean all && \
    rm -rf /var/cache/* /var/log/* /tmp/* /var/tmp/* /run/dnf

# --- Debloat ---------------------------------------------------------------
# Strip ~400 MB the fedora-bootc base ships that a Kodi appliance never uses.
# Verified safe: bootc still requires podman/skopeo (kept); kernel/network/Kodi
# untouched. Firmware for the actual hardware is deliberately left in place.
#   nvidia/intel GPU firmware -> this box is AMD
#   python3-boto3 (AWS SDK)   -> no cloud
#   kdump/kexec/sos/stalld    -> appliance, no crash-dump tooling
#   toolbox/criu/WALinuxAgent -> unused dev/cloud bits
RUN dnf -y remove \
        toolbox \
        criu \
        criu-libs \
        \
        nvidia-gpu-firmware \
        intel-gpu-firmware \
        \
        WALinuxAgent-udev \
        sos \
        kdump-utils \
        kexec-tools \
        makedumpfile \
        stalld \
        \
        python3-boto3 \
        python3-botocore \
        python3-s3transfer && \
    dnf clean all && \
    rm -rf /var/cache/* /var/log/* /tmp/* /var/tmp/* /run/dnf

# Boot to console multi-user (no display manager) and let kodi.service own the
# screen. Enable bootc auto-updates so the box pulls new images on a timer.
RUN systemctl set-default multi-user.target && \
    systemctl enable kodi.service && \
    systemctl enable bootc-fetch-apply-updates.timer && \
    systemctl enable tailscaled.service && \
    # The base image enables openssh; mask it so the tailnet is the only way in.
    systemctl mask sshd.service

# Catch image-construction mistakes at build time.
RUN bootc container lint
