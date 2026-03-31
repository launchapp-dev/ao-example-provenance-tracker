#!/usr/bin/env bash
# scan-incoming.sh — Scan data/incoming/ for new batch records, validate schema, stage valid files

set -euo pipefail

INCOMING_DIR="data/incoming"
STAGED_DIR="data/staged"
REJECTED_DIR="data/rejected"
MANIFEST="$STAGED_DIR/manifest.json"

mkdir -p "$STAGED_DIR" "$REJECTED_DIR"

valid_count=0
invalid_count=0
staged_entries="[]"

REQUIRED_FIELDS=("batch_id" "node_type" "node_id" "timestamp_in" "timestamp_out" "handler" "product" "quantity_kg")
VALID_NODE_TYPES=("farm" "processor" "distributor" "retailer")

for json_file in "$INCOMING_DIR"/**/*.json "$INCOMING_DIR"/*.json; do
  [ -f "$json_file" ] || continue

  batch_id=""
  valid=true
  errors=()

  # Check file is valid JSON
  if ! jq empty "$json_file" 2>/dev/null; then
    errors+=("invalid JSON syntax")
    valid=false
  else
    # Check required fields
    for field in "${REQUIRED_FIELDS[@]}"; do
      value=$(jq -r ".$field // empty" "$json_file" 2>/dev/null)
      if [ -z "$value" ]; then
        errors+=("missing required field: $field")
        valid=false
      fi
    done

    # Check node_type is valid
    node_type=$(jq -r '.node_type // empty' "$json_file")
    if [ -n "$node_type" ]; then
      is_valid_type=false
      for valid_type in "${VALID_NODE_TYPES[@]}"; do
        if [ "$node_type" = "$valid_type" ]; then
          is_valid_type=true
          break
        fi
      done
      if [ "$is_valid_type" = false ]; then
        errors+=("invalid node_type: $node_type")
        valid=false
      fi
    fi

    # Check timestamps are parseable ISO 8601
    ts_in=$(jq -r '.timestamp_in // empty' "$json_file")
    ts_out=$(jq -r '.timestamp_out // empty' "$json_file")
    if [ -n "$ts_in" ] && ! date -d "$ts_in" &>/dev/null 2>&1 && ! date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts_in" +%s &>/dev/null 2>&1; then
      errors+=("invalid timestamp_in format: $ts_in")
    fi

    batch_id=$(jq -r '.batch_id // empty' "$json_file")
  fi

  if [ "$valid" = true ] && [ -n "$batch_id" ]; then
    # Stage the file
    cp "$json_file" "$STAGED_DIR/${batch_id}.json"

    # Collect metadata for manifest
    product=$(jq -r '.product // ""' "$json_file")
    node_type=$(jq -r '.node_type // ""' "$json_file")
    node_id=$(jq -r '.node_id // ""' "$json_file")
    timestamp_in=$(jq -r '.timestamp_in // ""' "$json_file")
    parent_batch_ids=$(jq -c '.parent_batch_ids // []' "$json_file")

    entry=$(jq -n \
      --arg batch_id "$batch_id" \
      --arg product "$product" \
      --arg node_type "$node_type" \
      --arg node_id "$node_id" \
      --arg timestamp_in "$timestamp_in" \
      --arg source_file "$json_file" \
      --argjson parent_batch_ids "$parent_batch_ids" \
      '{batch_id: $batch_id, product: $product, node_type: $node_type, node_id: $node_id,
        timestamp_in: $timestamp_in, parent_batch_ids: $parent_batch_ids, source_file: $source_file}')

    staged_entries=$(echo "$staged_entries" | jq --argjson entry "$entry" '. + [$entry]')
    valid_count=$((valid_count + 1))
    echo "  STAGED: $batch_id ($node_type)"
  else
    # Reject with error annotation
    error_msg=$(IFS='; '; echo "${errors[*]}")
    rejected_file="$REJECTED_DIR/$(basename "$json_file" .json)-$(date +%s).json"
    jq --arg errors "$error_msg" --arg rejected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '. + {_rejection_errors: $errors, _rejected_at: $rejected_at}' \
      "$json_file" > "$rejected_file" 2>/dev/null || \
      echo "{\"_source\": \"$(basename "$json_file")\", \"_rejection_errors\": \"$error_msg\", \"_rejected_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$rejected_file"
    invalid_count=$((invalid_count + 1))
    echo "  REJECTED: $(basename "$json_file") — $error_msg"
  fi
done

# Write manifest
scanned_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "$staged_entries" | jq \
  --arg scanned_at "$scanned_at" \
  --argjson valid_count "$valid_count" \
  --argjson invalid_count "$invalid_count" \
  '{scanned_at: $scanned_at, staged_count: $valid_count, rejected_count: $invalid_count, batches: .}' \
  > "$MANIFEST"

echo ""
echo "Scan complete: $valid_count staged, $invalid_count rejected"
echo "Manifest written to $MANIFEST"
