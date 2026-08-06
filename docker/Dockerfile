# Quartus Prime Lite 18.1 (Cyclone V) for compiling the core locally.
# Quartus is x86_64 Linux software, so on Apple Silicon this image runs under
# emulation (build/run with --platform linux/amd64). It is large and the first
# build is slow; the resulting image is cached and reused.
FROM --platform=linux/amd64 ubuntu:20.04

ARG DEBIAN_FRONTEND=noninteractive
# 32-bit + X libraries Quartus 18.1 needs, plus curl for the installer download.
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates \
        libc6:i386 libncurses6:i386 libstdc++6:i386 \
        libx11-6 libxext6 libxft2 libxtst6 libxi6 \
        libfontconfig1 libsm6 \
    && rm -rf /var/lib/apt/lists/*

# Download + unattended-install Quartus Lite 18.1 and the Cyclone V device.
# The .qdz sitting next to the installer is picked up during the unattended install.
WORKDIR /tmp/qinstall
RUN BASE="https://downloads.intel.com/akdlm/software/acdsinst/18.1std/625/ib_installers" \
 && curl -fL "$BASE/QuartusLiteSetup-18.1.0.625-linux.run" -o quartus.run \
 && curl -fL "$BASE/cyclonev-18.1.0.625.qdz" -o cyclonev-18.1.0.625.qdz \
 && chmod +x quartus.run \
 && ./quartus.run --mode unattended --unattendedmodeui none \
        --installdir /opt/intelFPGA_lite/18.1 \
        --accept_eula 1 \
        --disable-components quartus_help,quartus_update \
 && rm -rf /tmp/qinstall

ENV PATH="/opt/intelFPGA_lite/18.1/quartus/bin:${PATH}"
WORKDIR /work
CMD ["quartus_sh", "--version"]
