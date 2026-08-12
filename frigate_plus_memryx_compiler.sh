#!/usr/bin/env bash

set -e

MODEL_ID="${1}"
TARGET_DIR="${2}"
CUSTOM_NAME="${3}"

# ------------------------------------------------------------------------------
# 1. Detect Docker privileges
# ------------------------------------------------------------------------------
if docker info >/dev/null 2>&1; then
  DOCKER_CMD="docker"
else
  echo "Notice: Non-root user cannot access Docker daemon directly. Running via 'sudo docker'..."
  DOCKER_CMD="sudo docker"
fi

# ------------------------------------------------------------------------------
# 2. Detect / Resolve Frigate Container Name
# ------------------------------------------------------------------------------
CONTAINER_NAME="${FRIGATE_CONTAINER_NAME:-frigate}"

if ! ${DOCKER_CMD} ps --format '{{.Names}}' | grep -e "^${CONTAINER_NAME}$" >/dev/null 2>&1; then
  # Find running containers containing 'frigate'
  RUNNING_FRIGATES=$(${DOCKER_CMD} ps --format '{{.Names}}' | grep -i 'frigate' || true)
  COUNT=$(echo "${RUNNING_FRIGATES}" | grep -c . || true)

  if [ "${COUNT}" -eq 1 ] && [ -n "${RUNNING_FRIGATES}" ]; then
    CONTAINER_NAME="${RUNNING_FRIGATES}"
    echo "Notice: Auto-detected running Frigate container named '${CONTAINER_NAME}'."
  else
    read -p "Frigate container '${CONTAINER_NAME}' not found. Enter container name: " INPUT_CONTAINER
    CONTAINER_NAME="${INPUT_CONTAINER:-frigate}"
  fi
fi

# Verify chosen container is active
if ! ${DOCKER_CMD} ps --format '{{.Names}}' | grep -e "^${CONTAINER_NAME}$" >/dev/null 2>&1; then
  echo "Error: Container '${CONTAINER_NAME}' is not running."
  exit 1
fi

# ------------------------------------------------------------------------------
# 3. Locate MemryX Compiler (mx_nc)
# ------------------------------------------------------------------------------
locate_mx_nc() {
  if command -v mx_nc >/dev/null 2>&1; then
    echo "$(command -v mx_nc)"
    return 0
  fi

  if [ -n "${MX_NC_PATH}" ] && [ -x "${MX_NC_PATH}" ]; then
    echo "${MX_NC_PATH}"
    return 0
  fi

  if [ -n "${MX_VENV_PATH}" ] && [ -x "${MX_VENV_PATH}/bin/mx_nc" ]; then
    echo "${MX_VENV_PATH}/bin/mx_nc"
    return 0
  fi

  local SEARCH_PATHS=(
    "${HOME}/mx/bin/mx_nc"
    "${HOME}/.venv/bin/mx_nc"
    "${HOME}/venv/bin/mx_nc"
    "${HOME}/memryx/bin/mx_nc"
    "/opt/memryx/bin/mx_nc"
  )

  for path in "${SEARCH_PATHS[@]}"; do
    if [ -x "${path}" ]; then
      echo "${path}"
      return 0
    fi
  done

  return 1
}

MX_NC_BIN=$(locate_mx_nc || true)

# ------------------------------------------------------------------------------
# 4. Interactive Prompts / Argument Processing
# ------------------------------------------------------------------------------
if [ -z "${MODEL_ID}" ]; then
  read -p "Enter Frigate+ Model ID: " MODEL_ID
fi
MODEL_ID=$(echo "${MODEL_ID}" | tr -d '\r\n ')

if [ -z "${MODEL_ID}" ]; then
  echo "Error: Model ID is required."
  exit 1
fi

DEFAULT_DIR="$(pwd)"
if [ -z "${TARGET_DIR}" ]; then
  read -p "Enter Target Directory on host [default: ${DEFAULT_DIR}]: " INPUT_DIR
  TARGET_DIR="${INPUT_DIR:-$DEFAULT_DIR}"
fi

mkdir -p "${TARGET_DIR}"
HOST_TARGET_DIR=$(cd "${TARGET_DIR}" && pwd)

if [ -z "${CUSTOM_NAME}" ]; then
  read -p "Enter Base Output Filename [default: ${MODEL_ID}]: " INPUT_NAME
  CUSTOM_NAME="${INPUT_NAME:-$MODEL_ID}"
fi

BASE_NAME=$(echo "${CUSTOM_NAME}" | tr -d '\r\n ' | sed -E 's/\.(onnx|json|dfp|zip|txt)$//i')

# ------------------------------------------------------------------------------
# 5. Fetch Download URL & Manifest via Container
# ------------------------------------------------------------------------------
echo ""
echo "Requesting download URL and manifest from Frigate+ via container '${CONTAINER_NAME}'..."

API_DATA=$(${DOCKER_CMD} exec -i "${CONTAINER_NAME}" python3 -c "
import json
from frigate.plus import PlusApi

model_id = '${MODEL_ID}'
api = PlusApi()

url = api.get_model_download_url(model_id)
info = api.get_model_info(model_id)

print(json.dumps({'url': url, 'info': info}))
")

SIGNED_URL=$(echo "${API_DATA}" | jq -r '.url // empty')
MANIFEST_JSON=$(echo "${API_DATA}" | jq '.info')

if [ -z "${SIGNED_URL}" ]; then
  echo "Error: Failed to retrieve download URL from Frigate container."
  exit 1
fi

# ------------------------------------------------------------------------------
# 6. Download ONNX & Write Manifest + Labels
# ------------------------------------------------------------------------------
echo "Downloading ${BASE_NAME}.onnx to ${HOST_TARGET_DIR}..."
curl -# -o "${HOST_TARGET_DIR}/${BASE_NAME}.onnx" "${SIGNED_URL}"

echo "Saving ${BASE_NAME}.json manifest..."
echo "${MANIFEST_JSON}" > "${HOST_TARGET_DIR}/${BASE_NAME}.json"

echo "Extracting label map to ${BASE_NAME}_labels.txt..."
python3 -c "
import json

json_path = '${HOST_TARGET_DIR}/${BASE_NAME}.json'
txt_path = '${HOST_TARGET_DIR}/${BASE_NAME}_labels.txt'

with open(json_path, 'r') as f:
    data = json.load(f)

label_map = data.get('labelMap', {})
sorted_labels = [v for k, v in sorted(label_map.items(), key=lambda item: int(item[0]))]

with open(txt_path, 'w') as f:
    f.write('\n'.join(sorted_labels) + '\n')
"

# ------------------------------------------------------------------------------
# 7. MemryX Compilation, Packaging & Automatic Cleanup
# ------------------------------------------------------------------------------
echo ""
if [ -n "${MX_NC_BIN}" ]; then
  echo "Found MemryX Compiler at: ${MX_NC_BIN}"
  echo "Compiling ${BASE_NAME}.onnx to .dfp..."

  cd "${HOST_TARGET_DIR}"

  # Set compiler effort flag with environment variable override (lazy, normal, hard)
  MX_EFFORT="${MX_EFFORT:-normal}"

  MX_CMD=(
    "${MX_NC_BIN}"
    -m "${BASE_NAME}.onnx"
    -c 4
    --effort "${MX_EFFORT}"
    --autocrop
    -v
    --dfp_fname "${BASE_NAME}.dfp"
  )

  # Append optional input format if explicitly defined in environment (e.g. MX_INPUT_FORMAT=BF16)
  if [ -n "${MX_INPUT_FORMAT}" ]; then
    MX_CMD+=("--input_format" "${MX_INPUT_FORMAT}")
  fi

  "${MX_CMD[@]}"

  echo "Packaging output files into ${BASE_NAME}.zip..."

  ZIP_FILES=("${BASE_NAME}.dfp")
  [ -f "${BASE_NAME}_post.onnx" ] && ZIP_FILES+=("${BASE_NAME}_post.onnx")
  [ -f "${BASE_NAME}_crop.onnx" ] && ZIP_FILES+=("${BASE_NAME}_crop.onnx")

  zip -j -q -u "${BASE_NAME}.zip" "${ZIP_FILES[@]}"

  if [ -f "${BASE_NAME}.zip" ]; then
    echo "Cleaning up intermediate build artifacts..."
    rm -f "${BASE_NAME}.dfp" \
          "${BASE_NAME}.onnx" \
          "${BASE_NAME}_crop.onnx" \
          "${BASE_NAME}_post.onnx" \
          "${BASE_NAME}_pre.onnx" \
          "memryx.neural_compiler.log"
  fi

  echo ""
  echo "Successfully compiled, packaged, and cleaned up!"
  echo "Final production artifacts in ${HOST_TARGET_DIR}:"
  echo "  ├── ${BASE_NAME}.zip          <-- Point model.path here in config.yml"
  echo "  ├── ${BASE_NAME}_labels.txt   <-- Point model.labelmap_path here"
  echo "  └── ${BASE_NAME}.json         <-- Model manifest metadata"
else
  echo "Notice: MemryX Compiler (mx_nc) was not detected on this system."
  echo "Base files downloaded successfully to ${HOST_TARGET_DIR}:"
  echo "  ├── ${BASE_NAME}.onnx"
  echo "  ├── ${BASE_NAME}.json"
  echo "  └── ${BASE_NAME}_labels.txt"
fi
