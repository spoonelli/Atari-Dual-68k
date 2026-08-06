# Local Quartus build via Docker

Quartus Prime does not run on macOS, so we compile the Cyclone V bitstream inside a
Linux Docker container. On Apple Silicon the container runs under x86 emulation
(`--platform linux/amd64`) — correct, just slower than native.

## Prerequisites
- Docker Desktop running.
- ~40 GB free disk for the image; give Docker a few GB of RAM (Settings → Resources).

## Usage
```bash
./docker/build.sh
```
- **First run**: builds the Quartus Lite 18.1 image (downloads ~3 GB from Intel, installs).
  This is slow under emulation — expect a while. The image is cached for later runs.
- **Every run**: compiles `ap_core` and writes the Pocket bitstream to
  `output/bitstream.rbf_r`.

## Notes
- The image installs Quartus Lite 18.1 + the Cyclone V device (matches `ap_core.qsf`).
- The bit-reverse step (`.rbf` → `.rbf_r`) runs on the host with `support/reverse_bits.py`.
- Same compile command as CI (`.github/workflows/build.yml`); this is the local fallback
  when GitHub-hosted runners are unavailable.
