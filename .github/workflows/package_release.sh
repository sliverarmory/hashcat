#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob
export TZ=UTC

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <platform> <architecture> <output.zip>"
  exit 1
fi

platform="$1"
architecture="$2"
output="$3"
platform_arch="${platform}_${architecture}"

case "$platform_arch" in
  darwin_arm64)  expected_runner_arch="arm64"  ;;
  linux_amd64)   expected_runner_arch="x86_64" ;;
  windows_amd64) expected_runner_arch="x86_64" ;;
  *)
    echo "! unsupported release target: $platform_arch"
    exit 1
    ;;
esac

runner_arch="$(uname -m)"

if [ "$runner_arch" != "$expected_runner_arch" ]; then
  echo "! $platform_arch must be packaged on $expected_runner_arch, this runner is $runner_arch"
  exit 1
fi

case "$output" in
  /*) output_path="$output" ;;
  *)  output_path="$PWD/$output" ;;
esac

if [ -e "$output_path" ]; then
  echo "! output archive already exists: $output_path"
  exit 1
fi

stage_root="$(mktemp -d)"
stage="$stage_root/$platform_arch"

trap 'rm -rf "$stage_root"' EXIT

mkdir -p "$stage"

for directory in bridges charsets docs extra feeds layouts masks modules OpenCL pcfg rules tunings; do
  if [ ! -d "$directory" ]; then
    echo "! required release directory is missing: $directory"
    exit 1
  fi

  cp -R "$directory" "$stage/"
done

for file in hashcat.hcstat2 example.dict; do
  if [ ! -f "$file" ]; then
    echo "! required release file is missing: $file"
    exit 1
  fi

  cp "$file" "$stage/"
done

command_examples=(example[0-9]*.cmd)
hash_examples=(example[0-9]*.hash)
shell_examples=(example[0-9]*.sh)

if [ "${#command_examples[@]}" -eq 0 ] || [ "${#hash_examples[@]}" -eq 0 ] || [ "${#shell_examples[@]}" -eq 0 ]; then
  echo "! one or more numbered example file classes are missing"
  exit 1
fi

cp "${command_examples[@]}" "${hash_examples[@]}" "${shell_examples[@]}" "$stage/"

mkdir -p \
  "$stage/Python" \
  "$stage/Rust/hashcat-sys" \
  "$stage/Rust/bridges/generic_hash" \
  "$stage/Rust/bridges/dynamic_hash" \
  "$stage/tools"

python_files=(Python/*.py)
perl_tool_files=(tools/*hashcat.pl)
python_tool_files=(tools/*hashcat.py)

if [ "${#python_files[@]}" -eq 0 ] || [ "${#perl_tool_files[@]}" -eq 0 ] || [ "${#python_tool_files[@]}" -eq 0 ]; then
  echo "! one or more release Python or tool file classes are missing"
  exit 1
fi

cp "${python_files[@]}" "$stage/Python/"
cp "${perl_tool_files[@]}" "${python_tool_files[@]}" "$stage/tools/"
chmod 755 "$stage/tools/"*hashcat.pl "$stage/tools/"*hashcat.py

copy_rust_crate ()
{
  source_crate="$1"
  destination_crate="$2"
  cargo_files=("$source_crate"/Cargo.*)

  if [ ! -d "$source_crate/src" ] || [ ! -f "$source_crate/build.rs" ] || [ "${#cargo_files[@]}" -eq 0 ]; then
    echo "! required Rust crate files are missing: $source_crate"
    exit 1
  fi

  cp -R "$source_crate/src" "$destination_crate/"
  cp "$source_crate/build.rs" "${cargo_files[@]}" "$destination_crate/"
}

copy_rust_crate Rust/hashcat-sys "$stage/Rust/hashcat-sys"
copy_rust_crate Rust/bridges/generic_hash "$stage/Rust/bridges/generic_hash"
copy_rust_crate Rust/bridges/dynamic_hash "$stage/Rust/bridges/dynamic_hash"

case "$platform_arch" in
  darwin_arm64)
    test -x hashcat
    cores=(libhashcat.*.dylib)
    test "${#cores[@]}" -eq 1
    file hashcat | tee "$stage_root/binary-format.txt"
    grep -q 'Mach-O 64-bit executable arm64' "$stage_root/binary-format.txt"
    cp hashcat "${cores[0]}" "$stage/"
    rm "$stage"/example[0-9]*.cmd
    binary="$stage/hashcat"
    plugin_suffix="so"
    ;;
  linux_amd64)
    test -x hashcat.bin
    cores=(libhashcat.so.*)
    test "${#cores[@]}" -eq 1
    file hashcat.bin | tee "$stage_root/binary-format.txt"
    grep -q 'ELF 64-bit.*x86-64' "$stage_root/binary-format.txt"
    cp hashcat.bin "${cores[0]}" "$stage/"
    find "$stage/modules" "$stage/bridges" "$stage/feeds" -type f -name '*.dll' -delete
    rm "$stage"/example[0-9]*.cmd

    for example in "$stage"/example[0-9]*.sh; do
      sed 's!\./hashcat !./hashcat.bin !' "$example" > "$example.tmp"
      mv "$example.tmp" "$example"
      chmod 755 "$example"
    done

    binary="$stage/hashcat.bin"
    plugin_suffix="so"
    ;;
  windows_amd64)
    test -f hashcat.exe
    test -f hashcat.dll
    file hashcat.exe | tee "$stage_root/binary-format.txt"
    grep -q 'PE32+ executable.*x86-64' "$stage_root/binary-format.txt"
    cp hashcat.exe hashcat.dll "$stage/"
    find "$stage/modules" "$stage/bridges" "$stage/feeds" -type f -name '*.so' -delete
    rm "$stage"/example[0-9]*.sh

    if [ -z "${WIN_DLL_DIR:-}" ]; then
      echo "! WIN_DLL_DIR must name the directory containing the release compression DLLs"
      exit 1
    fi

    for file in liblzma.dll zlib1.dll libzstd.dll; do
      if [ ! -f "$WIN_DLL_DIR/$file" ]; then
        echo "! required Windows runtime is missing: $WIN_DLL_DIR/$file"
        exit 1
      fi

      cp "$WIN_DLL_DIR/$file" "$stage/"
    done

    binary="$stage/hashcat.exe"
    plugin_suffix="dll"
    ;;
esac

module_count="$(find "$stage/modules" -type f -name "module_*.$plugin_suffix" | wc -l | tr -d '[:space:]')"

if [ "$module_count" -eq 0 ]; then
  echo "! no $plugin_suffix modules were packaged for $platform_arch"
  exit 1
fi

if [ "$platform" = "windows" ]; then
  if [ -z "${EXPECTED_VERSION:-}" ]; then
    echo "! EXPECTED_VERSION is required when packaging a cross-compiled Windows binary"
    exit 1
  fi

  if ! strings "$binary" | tr -d '\r' | grep -Fqx "$EXPECTED_VERSION"; then
    echo "! the Windows binary does not contain the expected version: $EXPECTED_VERSION"
    exit 1
  fi

  binary_version="$EXPECTED_VERSION"
else
  binary_version="$("$binary" --version)"
fi

case "$binary_version" in
  v[0-9]*) ;;
  *)
    echo "! packaged binary did not report a version: $binary_version"
    exit 1
    ;;
esac

if [ -n "${EXPECTED_VERSION:-}" ] && [ "$binary_version" != "$EXPECTED_VERSION" ]; then
  echo "! packaged binary version $binary_version does not match $EXPECTED_VERSION"
  exit 1
fi

if [ -z "${SOURCE_DATE_EPOCH:-}" ] || [ "$SOURCE_DATE_EPOCH" -le 0 ]; then
  echo "! SOURCE_DATE_EPOCH must be the positive timestamp of the source commit"
  exit 1
fi

find "$stage" -type f -name '*.debug' -delete

python3 - "$stage" "$SOURCE_DATE_EPOCH" <<'PY'
import os
import sys

root = sys.argv[1]
timestamp = int(sys.argv[2])

for current, directories, files in os.walk(root, topdown=False):
    for name in files:
        os.utime(os.path.join(current, name), (timestamp, timestamp), follow_symlinks=False)
    for name in directories:
        os.utime(os.path.join(current, name), (timestamp, timestamp), follow_symlinks=False)

os.utime(root, (timestamp, timestamp), follow_symlinks=False)
PY

mkdir -p "$(dirname "$output_path")"

(
  cd "$stage"
  find . -mindepth 1 -print | LC_ALL=C sort | zip -q -X -9 "$output_path" -@
)

zip -T "$output_path"

printf '%s (%s, %s modules, %s bytes)\n' \
  "$output_path" \
  "$binary_version" \
  "$module_count" \
  "$(wc -c < "$output_path" | tr -d '[:space:]')"
