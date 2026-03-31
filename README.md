# Supply Chain Provenance Tracker

Automated supply chain traceability pipeline — ingests batch records from each node (farm, processor, distributor, retailer), validates chain-of-custody, detects food safety anomalies, generates provenance certificates, and produces FSMA 204 compliance reports.

---

## Quick Start

```bash
cd examples/provenance-tracker
ao daemon start

# Drop batch records into the incoming directory
cp my-farm-batch.json data/incoming/farm/
cp my-processor-batch.json data/incoming/processor/

# Trigger a manual run (or wait for the hourly schedule)
ao queue enqueue \
  --title "batch-run-$(date +%Y%m%d-%H%M)" \
  --description "Manual batch ingestion run" \
  --workflow-ref batch-ingest

# Watch it run
ao daemon stream --pretty

# Trigger a compliance report
ao queue enqueue \
  --title "compliance-$(date +%Y%m%d)" \
  --description "Daily FSMA 204 compliance report" \
  --workflow-ref compliance-report

# Emergency recall trace
ao queue enqueue \
  --title "BATCH-2026-0331-DIST-001" \
  --description "Emergency recall trace for batch_id: BATCH-2026-0331-DIST-001" \
  --workflow-ref recall-response
```

---

## Architecture

```
data/incoming/{node-type}/
  BATCH-*.json files dropped here (farm, processor, distributor, retailer)
        |
        v
  [scan-incoming] bash
  Validates JSON schema, required fields, node types
  Moves valid → data/staged/   Invalid → data/rejected/
  Writes data/staged/manifest.json
        |
        v
  [normalize-batches] batch-ingester (haiku-4-5)
  Normalizes timestamps, units, field names
  Validates handler certs vs config/authorized-handlers.yaml
  Computes SHA-256 integrity hash per record
  Writes → data/normalized/{batch-id}.json
        |
        v
  [validate-chains] chain-validator (sonnet-4-6) + memory MCP
  Traces parent_batch_ids to build chain-of-custody
  Validates handoff timestamps and gaps
  Detects missing nodes and chain breaks
  Writes → data/chains/{product}/{chain-id}.json
  Updates memory: batch-genealogy
        |
        v
  [detect-anomalies] anomaly-detector (sonnet-4-6)
  Checks temperature logs vs thresholds.yaml
  Checks timing violations, unauthorized handlers
  Checks quantity discrepancies, duplicate batch IDs
  Writes → data/anomalies/anomaly-report.json
        |
        v
  [chain-decision] chain-validator (decision contract)
  ┌─────────────────────────────────────────────┐
  │  complete → generate-certificates           │
  │  gap-detected → generate-certificates       │
  │  anomaly-flagged → generate-certificates    │
  │  recall-triggered → generate-certificates   │
  └─────────────────────────────────────────────┘
        |
        v
  [generate-certificates] certificate-generator (haiku-4-5)
  Provenance certificates with full chain-of-custody
  Consumer-facing summaries with journey narrative
  Writes → output/certificates/{chain-id}-provenance.md
  Writes → output/consumer/{chain-id}-summary.md
        |
        v
  [compute-checksums] bash
  SHA-256 checksums for tamper detection
  Writes → output/certificates/checksums.sha256


COMPLIANCE WORKFLOW (daily at 6 AM):
  [gather-metrics] bash → data/metrics/daily-stats.json
        |
        v
  [generate-compliance] compliance-reporter (sonnet-4-6) + memory MCP
  FSMA 204 CTE/KDE completeness analysis
  Recall simulation (trace batch in <24h)
  Writes → output/compliance/
        |
        v
  [compliance-decision] compliance-reporter (decision)
  compliant → done
  documentation-gap → rework (max 2 attempts)
  violation → rework (max 2 attempts)


RECALL WORKFLOW (on-demand):
  [trace-batch] chain-validator + memory MCP
  Forward-traces from source batch through all descendants
        |
        v
  [generate-recall-notice] certificate-generator (haiku-4-5)
  Consumer recall notice + FDA regulatory filing
```

---

## Workflows

| Workflow | Trigger | Description |
|----------|---------|-------------|
| `batch-ingest` | Hourly (cron) + manual | Full ingestion pipeline: scan → normalize → validate → detect → certify |
| `compliance-report` | Daily 6 AM (cron) | FSMA 204 compliance assessment with rework loop |
| `recall-response` | Manual (on-demand) | Emergency batch trace and recall notice generation |

---

## Agents

| Agent | Model | Role |
|-------|-------|------|
| **batch-ingester** | claude-haiku-4-5 | Normalizes raw batch records, validates schema, computes integrity hashes |
| **chain-validator** | claude-sonnet-4-6 | Traces chain-of-custody, validates handoffs, issues routing decisions |
| **anomaly-detector** | claude-sonnet-4-6 | Detects temperature excursions, timing violations, unauthorized handlers |
| **certificate-generator** | claude-haiku-4-5 | Generates provenance certificates and consumer summaries |
| **compliance-reporter** | claude-sonnet-4-6 | FSMA 204 compliance analysis, recall simulations, executive reports |

---

## AO Features Demonstrated

| Feature | Where |
|---------|-------|
| **Scheduled workflows** | Hourly batch ingestion + daily compliance cron |
| **Multi-agent pipeline** | 5 specialized agents with clear handoffs |
| **Command phases** | jq validation, shasum integrity, bash file management |
| **Decision contracts** | chain-status routing (4 verdict paths) and compliance routing |
| **Memory MCP** | Persistent batch genealogy and compliance history across runs |
| **Rework loops** | Compliance workflow loops back on documentation gaps (max 2) |
| **On-demand workflows** | recall-response triggered manually via queue |
| **Model variety** | haiku-4-5 for fast normalization/generation, sonnet-4-6 for reasoning |

---

## Requirements

### Tools Required
- `jq` — JSON processing in command phases
- `shasum` or `sha256sum` — integrity checksums
- `find`, `wc` — metrics gathering

Install on macOS: `brew install jq`
Install on Ubuntu: `apt install jq`

### MCP Servers (auto-installed via npx)
- `@modelcontextprotocol/server-filesystem` — file read/write
- `@modelcontextprotocol/server-memory` — persistent batch genealogy
- `@modelcontextprotocol/server-sequential-thinking` — complex chain reasoning

No API keys required for any MCP server.

---

## Sample Data

The `data/incoming/` directory contains 6 sample batch records demonstrating:

| File | Scenario |
|------|---------|
| `farm/BATCH-2026-0331-FARM-001.json` | Clean farm origin batch (organic strawberries) |
| `processor/BATCH-2026-0331-PROC-001.json` | Clean processor batch — washing and packaging |
| `distributor/BATCH-2026-0331-DIST-001.json` | **Temperature excursion** — spike to 12.3°C (produce limit: 7°C) |
| `retailer/BATCH-2026-0331-RETAIL-001.json` | Clean retailer receiving |
| `processor/BATCH-2026-0331-PROC-002.json` | **Unauthorized handler** — cert ID not in authorized-handlers.yaml |
| `distributor/BATCH-2026-0331-DIST-ORPHAN.json` | **Orphan batch** — parent batch ID missing from system |

These samples exercise all anomaly detection paths and the gap detection logic.

---

## Output Structure

After a successful run:

```
output/
├── certificates/
│   ├── CHAIN-20260331-001-provenance.md    # Formal provenance certificate
│   ├── checksums.sha256                     # Tamper-detection checksums
│   └── index.json                           # Certificate index
├── consumer/
│   └── CHAIN-20260331-001-summary.md        # Consumer-facing journey summary
├── compliance/
│   ├── fsma-204-report.md                   # Full FSMA 204 compliance report
│   ├── recall-readiness.md                  # Recall simulation results
│   └── executive-summary.md                 # One-page leadership dashboard
└── recalls/
    └── {batch-id}/                          # (created on demand)
        ├── affected-batches.json
        ├── distribution-map.md
        ├── recall-notice.md
        └── regulatory-filing.md
```

---

## FSMA 204 Compliance

This pipeline maps directly to FDA FSMA Section 204 (Food Safety Modernization Act —
Requirements for Additional Traceability Records for Certain Foods):

| FSMA 204 Requirement | Implementation |
|---------------------|----------------|
| Critical Tracking Events (CTEs) | Each supply chain node = one CTE |
| Key Data Elements (KDEs) | Validated per batch: lot code, quantity, location, date, source lot |
| 24-hour trace capability | Recall simulation in compliance-report workflow |
| 2-year record retention | All records written to disk; certificates checksummed |
| Traceability lot codes | `batch_id` + `lot_code` fields in batch records |

---

## Configuration

### `config/thresholds.yaml`
Set temperature limits per product category (produce, dairy, meat, ambient) and
maximum transit times between handoffs.

### `config/authorized-handlers.yaml`
List of approved handlers with their cert IDs, authorized node IDs, and cert expiry dates.
Any handler not in this file triggers an `unauthorized_handler` anomaly.

### `config/supply-chain-nodes.yaml`
Registry of all supply chain nodes with IDs, types, locations, and certifications.
