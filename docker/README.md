# Local Quartus build via Docker

Quartus Prime does not run on macOS, so we compile the Cyclone V bitstream inside a
Linux Docker container using the community image **`theypsilon/quartus-lite-c5:18.1`**
(Quartus Lite 18.1 + Cyclone V, purpose-built for Analogue Pocket cores).

## Usage
```bash
./docker/build.sh
```
Compiles `ap_core` and writes the Pocket bitstream to `output/bitstream.rbf_r`.

## Apple Silicon note
On an ARM Mac the container runs under x86 emulation, which can crash `quartus_map`
during synthesis. The **reliable** build is CI — `.github/workflows/build.yml` runs this
same image on a native-x86 GitHub runner (no emulation) and uploads `bitstream.rbf_r`
as an artifact. Use this script only on a native-x86 host, or to experiment.

## History
An earlier approach installed Quartus from Intel's `.run` + `.qdz` files in a custom
Dockerfile. That install was subtly incomplete — `quartus_map` crashed during synthesis
even on native x86 — so we switched to the prebuilt image above.
