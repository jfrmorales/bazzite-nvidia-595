# Build scripts stage
FROM scratch AS ctx
COPY build_files /

# Base: Bazzite KDE Plasma with NVIDIA drivers
FROM ghcr.io/ublue-os/bazzite-nvidia:stable

# Replace NVIDIA drivers and apply customizations via build.sh
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

# Verify final image
RUN bootc container lint
