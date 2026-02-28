#!/usr/bin/env bash
set -euo pipefail

DIR="/etc/tetragon/tetragon.tp.d"
shopt -s nullglob

files=( "${DIR}"/tb-*.yaml )

if (( ${#files[@]} == 0 )); then
  echo "No files matched: ${DIR}/tb-*.yaml" >&2
  exit 0
fi

for f in "${files[@]}"; do
  echo "================================================================"
  echo "FILE: ${f}"
  echo "----------------------------------------------------------------"
  cat -- "${f}"
  echo
done

