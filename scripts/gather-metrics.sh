#!/usr/bin/env bash
# gather-metrics.sh — Aggregate daily metrics from data directories

set -euo pipefail

METRICS_DIR="data/metrics"
mkdir -p "$METRICS_DIR"
OUTPUT_FILE="$METRICS_DIR/daily-stats.json"

today=$(date -u +%Y-%m-%d)
generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Count batch files per node type
farm_count=$(find data/incoming/farm -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
processor_count=$(find data/incoming/processor -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
distributor_count=$(find data/incoming/distributor -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
retailer_count=$(find data/incoming/retailer -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
total_incoming=$((farm_count + processor_count + distributor_count + retailer_count))

staged_count=$(find data/staged -name "*.json" ! -name "manifest.json" 2>/dev/null | wc -l | tr -d ' ')
rejected_count=$(find data/rejected -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
normalized_count=$(find data/normalized -name "*.json" ! -name "batch-index.json" 2>/dev/null | wc -l | tr -d ' ')

# Count chains
total_chains=$(find data/chains -name "*.json" 2>/dev/null | wc -l | tr -d ' ')

# Count anomalies by severity from anomaly-report.json
anomaly_report="data/anomalies/anomaly-report.json"
critical_anomalies=0
warning_anomalies=0
info_anomalies=0
total_anomalies=0
if [ -f "$anomaly_report" ]; then
  total_anomalies=$(jq 'length' "$anomaly_report" 2>/dev/null || echo 0)
  critical_anomalies=$(jq '[.[] | select(.severity == "critical")] | length' "$anomaly_report" 2>/dev/null || echo 0)
  warning_anomalies=$(jq '[.[] | select(.severity == "warning")] | length' "$anomaly_report" 2>/dev/null || echo 0)
  info_anomalies=$(jq '[.[] | select(.severity == "info")] | length' "$anomaly_report" 2>/dev/null || echo 0)
fi

# Count recall candidates
recall_candidates="data/anomalies/recall-candidates.json"
recall_candidate_count=0
if [ -f "$recall_candidates" ]; then
  recall_candidate_count=$(jq 'length' "$recall_candidates" 2>/dev/null || echo 0)
fi

# Count generated certificates
cert_count=$(find output/certificates -name "*-provenance.md" 2>/dev/null | wc -l | tr -d ' ')
consumer_summary_count=$(find output/consumer -name "*-summary.md" 2>/dev/null | wc -l | tr -d ' ')

# Read chain status if available
chains_complete=0
chains_gap=0
if [ -f "data/validation/chain-status.json" ]; then
  chains_complete=$(jq '.complete // 0' data/validation/chain-status.json 2>/dev/null || echo 0)
  chains_gap=$(jq '.gap_detected // 0' data/validation/chain-status.json 2>/dev/null || echo 0)
fi

# Write daily stats
jq -n \
  --arg date "$today" \
  --arg generated_at "$generated_at" \
  --argjson total_incoming "$total_incoming" \
  --argjson farm_count "$farm_count" \
  --argjson processor_count "$processor_count" \
  --argjson distributor_count "$distributor_count" \
  --argjson retailer_count "$retailer_count" \
  --argjson staged_count "$staged_count" \
  --argjson rejected_count "$rejected_count" \
  --argjson normalized_count "$normalized_count" \
  --argjson total_chains "$total_chains" \
  --argjson chains_complete "$chains_complete" \
  --argjson chains_gap "$chains_gap" \
  --argjson total_anomalies "$total_anomalies" \
  --argjson critical_anomalies "$critical_anomalies" \
  --argjson warning_anomalies "$warning_anomalies" \
  --argjson info_anomalies "$info_anomalies" \
  --argjson recall_candidate_count "$recall_candidate_count" \
  --argjson cert_count "$cert_count" \
  --argjson consumer_summary_count "$consumer_summary_count" \
  '{
    date: $date,
    generated_at: $generated_at,
    batches: {
      total_incoming: $total_incoming,
      by_node_type: {
        farm: $farm_count,
        processor: $processor_count,
        distributor: $distributor_count,
        retailer: $retailer_count
      },
      staged: $staged_count,
      rejected: $rejected_count,
      normalized: $normalized_count
    },
    chains: {
      total: $total_chains,
      complete: $chains_complete,
      gap_detected: $chains_gap
    },
    anomalies: {
      total: $total_anomalies,
      critical: $critical_anomalies,
      warning: $warning_anomalies,
      info: $info_anomalies,
      recall_candidates: $recall_candidate_count
    },
    outputs: {
      provenance_certificates: $cert_count,
      consumer_summaries: $consumer_summary_count
    }
  }' > "$OUTPUT_FILE"

echo "Daily metrics written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"
