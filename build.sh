#!/usr/bin/env bash
set -euo pipefail

# build.sh — Build & package all DDNS bits for AWS Lambda (custom runtime by default)
# Flags:
#   --runtime {provided.al2023|go1.x}   (default: provided.al2023)
#   --arch    {amd64|arm64}             (default: amd64)
#   --rotator {on|off}                  (default: on)
#
# Outputs:
#   function.zip        (DDNS lambda)
#   authorizer.zip      (Authorizer lambda)
#   rotator.zip         (Rotator lambda; only if --rotator on)
#
# Expected layout:
#   .
#   ├─ main.go
#   ├─ authorizer/main.go
#   └─ rotator/main.go   (optional; only if using rotation)

RUNTIME="provided.al2023"
ARCH="amd64"
ROTATOR="on"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime) RUNTIME="${2:-}"; shift 2 ;;
    --arch)    ARCH="${2:-}";    shift 2 ;;
    --rotator) ROTATOR="${2:-}"; shift 2 ;;
    -h|--help) sed -n '1,60p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

build_go_bootstrap() { # dir outzip arch
  local dir="$1" outzip="$2" arch="$3"
  pushd "$dir" >/dev/null
  GOOS=linux GOARCH="$arch" CGO_ENABLED=0 \
    go build -trimpath -ldflags="-s -w" -o bootstrap .
  chmod +x bootstrap
  zip -9j "$outzip" bootstrap
  popd >/dev/null
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need go; need zip

build_zip() {
  local src_dir="$1" out_zip="$2" binname bootstrap_or_main
  local GOOS=linux GOARCH="$ARCH" CGO_ENABLED=0

  if [[ "$RUNTIME" == "go1.x" ]]; then
    binname="main"
  elif [[ "$RUNTIME" == "provided.al2023" ]]; then
    binname="bootstrap"
  else
    echo "Unsupported runtime: $RUNTIME" >&2; exit 1
  fi

  rm -rf "$src_dir/dist" "$out_zip"
  mkdir -p "$src_dir/dist"
  ( cd "$src_dir" && GOOS="$GOOS" GOARCH="$GOARCH" CGO_ENABLED="$CGO_ENABLED" \
      go build -trimpath -ldflags "-s -w" -o "dist/$binname" ./main.go )
  ( cd "$src_dir/dist" && zip -qr "../../$out_zip" . )
}

build_main_zip() {
  local src_dir="$1" out_zip="$2" binname bootstrap_or_main
  local GOOS=linux GOARCH="$ARCH" CGO_ENABLED=0

  if [[ "$RUNTIME" == "go1.x" ]]; then
    binname="main"
  elif [[ "$RUNTIME" == "provided.al2023" ]]; then
    binname="bootstrap"
  else
    echo "Unsupported runtime: $RUNTIME" >&2; exit 1
  fi

  # Ensure module in SRC_DIR
if [[ ! -f "$src_dir/go.mod" ]]; then
  echo "No go.mod found under --src '$src_dir'." >&2
  exit 1
fi
if [[ ! -f "$src_dir/main.go" ]]; then
  echo "No main.go found under --src '$src_dir'." >&2
  exit 1
fi

  rm -rf "$src_dir/dist" "$out_zip"
  mkdir -p "$src_dir/dist"
  
  echo "==> Building ($RUNTIME, arch=$ARCH) from $src_dir ..."
pushd "$src_dir" >/dev/null

# Build flags
COMMON_FLAGS=(-trimpath -ldflags "-s -w")
export GOOS=linux
export GOARCH="$ARCH"

if [[ "$RUNTIME" == "provided.al2023" ]]; then
  # Statically linked binary recommended for custom runtime
  export CGO_ENABLED=0
  go build "${COMMON_FLAGS[@]}" -o "dist/$binname" ./main.go
else
  # go1.x managed runtime; CGO can be 0 or 1 (keep 0 for portability)
  export CGO_ENABLED=0
  go build "${COMMON_FLAGS[@]}" -o "dist/$binname" ./main.go
fi

# Create zip with binary at root (not nested)
echo "==> Packaging -> $out_zip"
( cd dist && zip -qr "../$(basename "$out_zip")" . )

popd >/dev/null

}

# DDNS function (root main.go)
build_main_zip "." "function.zip"

# Authorizer
build_go_bootstrap "authorizer" "authorizer.zip" "amd64"

# Rotator (optional)
if [[ "$ROTATOR" == "on" ]]; then
  if [[ -f "rotator/main.go" ]]; then
    build_zip "rotator" "rotator.zip"
  else
    echo "warn: rotator/main.go not found; skipping rotator build" >&2
  fi
fi

echo "==> Built:"
ls -lh function.zip authorizer.zip 2>/dev/null || true
[[ -f rotator.zip ]] && ls -lh rotator.zip || true

echo
echo "Lambda settings to match:"
echo "  runtime = \"$RUNTIME\""
echo "  handler = \"$( [[ $RUNTIME == go1.x ]] && echo main || echo bootstrap )\""
echo "  architectures = [\"$( [[ $ARCH == arm64 ]] && echo arm64 || echo x86_64 )\"]  (if you set it in TF)"