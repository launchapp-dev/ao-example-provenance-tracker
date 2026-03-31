# Supply Chain Provenance Tracker — Agent Context

## What This Project Does

This AO project implements an automated supply chain traceability pipeline for food products.
It ingests batch records from supply chain nodes (farm → processor → distributor → retailer),
validates chain-of-custody completeness, detects food safety anomalies, generates provenance
certificates, and produces FSMA 204 compliance reports.

## Directory Layout

```
provenance-tracker/
├── .ao/workflows/        # AO workflow configuration
├── config/               # Thresholds, authorized handlers, node registry
├── data/
│   ├── incoming/         # Raw batch JSON files — DROP NEW BATCHES HERE
│   │   ├── farm/
│   │   ├── processor/
│   │   ├── distributor/
│   │   └── retailer/
│   ├── staged/           # Validated files awaiting normalization
│   ├── rejected/         # Invalid files with error annotations
│   ├── normalized/       # Canonical normalized batch records
│   ├── chains/           # Chain-of-custody records by product
│   ├── validation/       # Chain validation status files
│   ├── anomalies/        # Anomaly reports and recall candidates
│   └── metrics/          # Daily aggregate statistics
├── output/
│   ├── certificates/     # Provenance certificates (.md)
│   ├── consumer/         # Consumer-facing summaries (.md)
│   ├── compliance/       # FSMA 204 reports
│   └── recalls/          # Emergency recall notices
├── scripts/              # Bash helper scripts
└── templates/            # Document templates
```

## Data Flow

```
data/incoming/{node-type}/*.json
  → scripts/scan-incoming.sh    (validates, moves to staged/)
  → batch-ingester agent        (normalizes, writes to normalized/)
  → chain-validator agent       (traces chains, writes to chains/)
  → anomaly-detector agent      (checks safety, writes to anomalies/)
  → chain-validator decision    (routes based on severity)
  → certificate-generator agent (writes to output/)
  → scripts/compute-checksums.sh (SHA-256 integrity)
```

## Batch Record Schema

Required fields for all batch JSON files in `data/incoming/`:
- `batch_id` — unique ID format: `BATCH-{YYYYMMDD}-{NODE_TYPE}-{NNN}`
- `node_type` — one of: `farm`, `processor`, `distributor`, `retailer`
- `node_id` — must match an entry in `config/supply-chain-nodes.yaml`
- `timestamp_in` / `timestamp_out` — ISO 8601 UTC
- `handler` — human name of responsible party
- `handler_cert_id` — must match `config/authorized-handlers.yaml` for clean validation
- `product` — product name (used for chain grouping)
- `quantity_kg` — numeric
- `parent_batch_ids` — array of upstream batch IDs (empty `[]` for farm origin)
- `temperature_log` — array of `{time, temp_c}` readings

## Chain Validation Rules

A chain is **complete** when all four node types are present in order with valid handoffs.
A handoff is **valid** when:
- timestamp_out(node[n]) ≤ timestamp_in(node[n+1])
- gap between timestamp_out and timestamp_in ≤ `config/thresholds.yaml` transit.max_handoff_gap_hours

A batch is **orphaned** when its `parent_batch_ids` references a batch_id not in the system.

## Anomaly Severity Levels

- **critical** — requires immediate action (recall candidate): temperature > 2°C above threshold,
  handler cert not found, duplicate batch IDs
- **warning** — requires investigation: temperature 1–2°C above threshold, cert expired,
  handoff gap exceeded, quantity discrepancy
- **info** — logged for records: minor timing variations

## Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `batch-ingest` | Hourly (cron) + manual | Full ingestion pipeline |
| `compliance-report` | Daily 6 AM (cron) | FSMA 204 compliance assessment |
| `recall-response` | Manual (on-demand) | Emergency batch trace + notices |

## Running a Recall Response

```bash
ao queue enqueue \
  --title "BATCH-2026-0331-DIST-001" \
  --description "Emergency recall trace for batch_id: BATCH-2026-0331-DIST-001" \
  --workflow-ref recall-response
```

## Agents

| Agent | Model | When It Runs |
|-------|-------|-------------|
| batch-ingester | claude-haiku-4-5 | normalize-batches phase |
| chain-validator | claude-sonnet-4-6 | validate-chains, chain-decision, trace-batch phases |
| anomaly-detector | claude-sonnet-4-6 | detect-anomalies phase |
| certificate-generator | claude-haiku-4-5 | generate-certificates, generate-recall-notice phases |
| compliance-reporter | claude-sonnet-4-6 | generate-compliance, compliance-decision phases |

## Memory MCP Entities

The chain-validator and compliance-reporter agents maintain persistent state via the memory MCP:

- **batch-genealogy** — graph of batch_id → parent/child relationships across all runs
- **compliance-history** — daily compliance metrics for trend analysis

## Key Configs to Customize

- `config/thresholds.yaml` — temperature limits per product category, max transit times
- `config/authorized-handlers.yaml` — approved handler cert IDs per node
- `config/supply-chain-nodes.yaml` — node registry with locations and certifications
