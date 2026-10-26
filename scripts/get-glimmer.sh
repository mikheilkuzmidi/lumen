#!/bin/bash
set -euo pipefail

model_dir="${LUMEN_GLIMMER_DIR:-$HOME/Library/Application Support/Lumen/Models/muse-glimmer}"
if [[ -z "${model_dir//[[:space:]]/}" ]]; then
    model_dir="$HOME/Library/Application Support/Lumen/Models/muse-glimmer"
fi
case "$model_dir" in
    '~') model_dir="$HOME" ;;
    '~/'*) model_dir="$HOME/${model_dir:2}" ;;
esac

printf 'Muse Glimmer license: Apache-2.0\n'
printf 'Download size: approximately 18.2 GB (16.8 GB model + 1.4 GB vision projector).\n'
printf 'Destination: %s\n' "$model_dir"
printf 'At least 25 GB of free disk space is required before downloading.\n'

mkdir -p "$model_dir"
available_kb=$(df -Pk "$model_dir" | awk 'END {print $4}')
if ! [[ "$available_kb" =~ ^[0-9]+$ ]]; then
    printf 'Could not determine free disk space at %s.\n' "$model_dir" >&2
    exit 1
fi
if (( available_kb < 25 * 1024 * 1024 )); then
    printf 'Not enough disk space. Free at least 25 GB on the destination volume, then run scripts/get-glimmer.sh again.\n' >&2
    exit 1
fi

base_url='https://huggingface.co/meta-models/Muse-Glimmer-30B-GGUF/resolve/main'
# SHA-256 of each file as published by the repository (October 26, 2026). An interrupted transfer stays as
# .part and resumes on the next run; one that finished damaged is deleted so the next run starts it again.
checksum() {
    case "$1" in
        Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf) echo 4cc57c0f51040a226e5a72cc47b7613f7772950e460a665f7083de89f183f60e ;;
        mmproj-Muse-Glimmer-30B-Q4_K_M.gguf) echo f48b452316f9b213758e8659444029b961a24a07f99a1abb2a9f88b06f7c00c6 ;;
    esac
}
for model_file in Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf mmproj-Muse-Glimmer-30B-Q4_K_M.gguf; do
    destination="$model_dir/$model_file"
    if [[ -f "$destination" ]]; then
        printf 'Already downloaded: %s\n' "$model_file"
        continue
    fi
    printf 'Downloading %s\n' "$model_file"
    curl --fail --location --retry 3 -C - --output "$destination.part" "$base_url/$model_file"
    printf 'Checking %s\n' "$model_file"
    actual=$(shasum -a 256 "$destination.part" | cut -d' ' -f1)
    if [[ "$actual" != "$(checksum "$model_file")" ]]; then
        rm -f "$destination.part"
        printf 'The download of %s was damaged and has been deleted. Run scripts/get-glimmer.sh again.\n' "$model_file" >&2
        exit 1
    fi
    mv "$destination.part" "$destination"
done
printf 'Muse Glimmer model files are ready in %s.\n' "$model_dir"
