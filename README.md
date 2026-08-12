# Frigate+ MemryX Model Downloader & Compiler

> **⚠️ Disclaimer:** This script and repository were generated with the assistance of AI. The author is not a professional software developer. While this script has been tested and confirmed working, please review the code carefully and use it with caution in your own environment.

A Bash automation script that fetches base or fine-tuned models directly from Frigate+, extracts the label map, compiles the `.onnx` file to a MemryX `.dfp` binary using `mx_nc`, and packages everything into a `.zip` archive ready for Frigate NVR.

---

## Features

- **Automated Authentication:** Uses your running Frigate Docker container to handle token generation and presigned S3 URL retrieval from Frigate+.
- **Smart Container Resolution:** Auto-detects running Frigate containers even if named differently (e.g., `frigate-ptz` or `frigate-beta`), with an environment variable override option.
- **Host-Native Output:** Writes files directly to your host filesystem without messing with Docker volume paths or permissions.
- **Label Map Extraction:** Automatically parses the model's JSON manifest and creates a numerical, line-separated `_labels.txt` file for Frigate.
- **MemryX Compiler Auto-Detection:** Automatically locates `mx_nc` in system `$PATH`, custom virtual environments (e.g., `~/mx/`), or via the `$MX_VENV_PATH` environment variable.
- **Automated Packaging & Cleanup:** Bundles `.dfp` and post-processing ONNX graphs (`_post.onnx`, `_crop.onnx`) into a `.zip` archive and deletes intermediate build artifacts upon success.
- **Custom & Base Model Support:** Works identically for universal Frigate+ base models and custom fine-tuned models.

---

## Prerequisites

### 1. Host Dependencies
Ensure the following utilities are installed on your host system:
- `curl`
- `jq`
- `zip`
- `python3`

On Debian/Ubuntu:
```bash
sudo apt update && sudo apt install -y curl jq zip python3
```

### 2. Docker & Frigate NVR
- A running Frigate container with a valid `PLUS_API_KEY` configured in your environment or secrets.
- Non-root Docker access (the script automatically falls back to `sudo docker` if required).
- *Container Name:* Defaults to `frigate`. If your container uses a different name, set `FRIGATE_CONTAINER_NAME` prior to running:
  ```bash
  export FRIGATE_CONTAINER_NAME="my_custom_frigate"
  ```

### 3. MemryX SDK 2.1
The MemryX Neural Compiler (`mx_nc`) should be installed on your host machine. The script auto-detects `mx_nc` in:
- System `$PATH`
- `~/mx/bin/mx_nc`
- `~/.venv/bin/mx_nc`
- `~/venv/bin/mx_nc`
- `~/memryx/bin/mx_nc`
- Custom path set via `export MX_VENV_PATH="/path/to/venv"` in your `~/.bashrc`

---

## Installation

### Option 1: Quick Download (Script Only)
Download the standalone script directly without cloning the repository:

```bash
curl -sSL https://raw.githubusercontent.com/michaelhrunyon/frigate-plus-memryx-compiler/main/frigate_plus_memryx_compiler.sh -o frigate_plus_memryx_compiler.sh && chmod +x frigate_plus_memryx_compiler.sh
```

### Option 2: Clone the Repository
Clone the full repository onto your host machine:

```bash
git clone https://github.com/michaelhrunyon/frigate-plus-memryx-compiler.git
cd frigate-plus-memryx-compiler
chmod +x frigate_plus_memryx_compiler.sh
```

---

## Usage

### Option 1: Interactive Mode
Run the script without arguments to be prompted for the Model ID, Target Directory, and Base Filename:

```bash
./frigate_plus_memryx_compiler.sh
```

### Option 2: Command-Line Arguments
Pass the parameters directly for non-interactive execution or automated workflows:

```bash
./frigate_plus_memryx_compiler.sh <MODEL_ID> <TARGET_DIR> <BASE_NAME>
```

#### Example:
```bash
./frigate_plus_memryx_compiler.sh f078cbd40c60564a3b091fccd228b439 /docker/appdata/frigate/config/model_cache/frigate_plus_models yolonas_320
```

---

## Generated Files

Upon successful compilation, the target directory will contain:

| File | Description |
| :--- | :--- |
| `<BASE_NAME>.zip` | Production archive containing `.dfp` and post-processing ONNX files. |
| `<BASE_NAME>_labels.txt` | Line-separated label map for Frigate. |
| `<BASE_NAME>.json` | Original Frigate+ manifest metadata. |

*Note: Intermediate `.onnx`, `.dfp`, and log files are automatically removed after the archive is created.*

---

## Frigate `config.yml` Example

Add the compiled model to your Frigate configuration:

```yaml
detectors:
  memx0:
    type: memryx
    device: PCIe:0

model:
  model_type: yolo-generic  # Set to 'yolonas' for YOLO-NAS models
  path: /config/model_cache/frigate_plus_models/yolonas_320.zip
  labelmap_path: /config/model_cache/frigate_plus_models/yolonas_320_labels.txt
  width: 320
  height: 320
  input_tensor: nchw
  input_dtype: float
```

---

## License

MIT License. Feel free to modify and distribute.
