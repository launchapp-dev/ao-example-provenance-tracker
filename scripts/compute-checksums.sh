#!/usr/bin/env bash
# compute-checksums.sh — Compute SHA-256 checksums for all certificate files

set -euo pipefail

CERTS_DIR="output/certificates"
CHECKSUMS_FILE="$CERTS_DIR/checksums.sha256"

if [ ! -d "$CERTS_DIR" ]; then
  echo "No certificates directory found at $CERTS_DIR — skipping"
  exit 0
fi

cert_files=$(find "$CERTS_DIR" -name "*.md" -o -name "*.json" | grep -v checksums | sort)

if [ -z "$cert_files" ]; then
  echo "No certificate files found — skipping"
  exit 0
fi

# Write header
{
  echo "# Provenance Certificate Checksums"
  echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# Algorithm: SHA-256"
  echo "#"
} > "$CHECKSUMS_FILE"

# Compute checksums
count=0
while IFS= read -r file; do
  if command -v shasum &>/dev/null; then
    shasum -a 256 "$file" >> "$CHECKSUMS_FILE"
  else
    sha256sum "$file" >> "$CHECKSUMS_FILE"
  fi
  count=$((count + 1))
done <<< "$cert_files"

echo "Checksums computed for $count files → $CHECKSUMS_FILE"
