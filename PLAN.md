# Supply Chain Provenance Tracker — Build Plan

## Overview

Supply chain traceability pipeline — ingests batch records from each supply chain node
(farm/factory, processor, distributor, retailer) as structured JSON files, validates
chain-of-custody completeness at each handoff, detects gaps or anomalies (missing
timestamps, temperature excursions, unauthorized handlers), generates provenance
certificates with full chain-of-custody documentation, creates consumer-facing
traceability summaries, and produces compliance reports for food safety regulations
(FSMA 204).

All batch record parsing uses `jq` command phases. Agent phases handle chain validation,
anomaly detection, certificate generation, and compliance reporting. Memory MCP stores
persistent batch genealogy and supply chain node registry across runs.

---

## Agents (5)

| Agent | Model | Role |
|---|---|---|
| **batch-ingester** | claude-haiku-4-5 | Normalizes raw batch records into canonical format, validates schema |
| **chain-validator** | claude-sonnet-4-6 | Traces full chain-of-custody, identifies gaps in handoff sequence |
| **anomaly-detector** | claude-sonnet-4-6 | Detects temperature excursions, timing violations, unauthorized handlers |
| **certificate-generator** | claude-haiku-4-5 | Produces provenance certificates and consumer-facing summaries |
| **compliance-reporter** | claude-sonnet-4-6 | Generates FSMA 204 compliance reports and recall-readiness assessments |

### MCP Servers Used by Agents

- **filesystem** — all agents read/write JSON/markdown data files
- **memory** — chain-validator and compliance-reporter use for persistent batch genealogy, supply chain node registry, and historical trend data
- **sequential-thinking** — chain-validator and anomaly-detector use for complex multi-hop chain reasoning and anomaly correlation

---

## Data Model

### Batch Record (input: `data/incoming/{node-type}/{batch-id}.json`)

```json
{
  "batch_id": "BATCH-2026-0331-FARM-001",
  "node_type": "farm",
  "node_id": "FARM-CA-042",
  "node_name": "Sunrise Organic Farm",
  "product": "Organic Strawberries",
  "quantity_kg": 500,
  "timestamp_in": "2026-03-28T06:00:00Z",
  "timestamp_out": "2026-03-28T14:00:00Z",
  "handler": "J. Martinez",
  "handler_cert_id": "CERT-FM-2025-042",
  "temperature_log": [
    {"time": "2026-03-28T06:00:00Z", "temp_c": 4.2},
    {"time": "2026-03-28T10:00:00Z", "temp_c": 5.1}
  ],
  "parent_batch_ids": [],
  "notes": "First harvest of season",
  "attachments": ["lot-photo.jpg"]
}
```

### Supply Chain Node Types (in order)

1. **farm** — Origin/source (no parent batches)
2. **processor** — Washing, packaging, transformation (parent = farm batch)
3. **distributor** — Cold storage, logistics (parent = processor batch)
4. **retailer** — Final point of sale (parent = distributor batch)

### Chain-of-Custody Record (generated: `data/chains/{product-id}/{chain-id}.json`)

```json
{
  "chain_id": "CHAIN-2026-0331-001",
  "product": "Organic Strawberries",
  "origin_batch": "BATCH-2026-0331-FARM-001",
  "terminal_batch": "BATCH-2026-0331-RETAIL-001",
  "status": "complete",
  "nodes": [
    {"batch_id": "...", "node_type": "farm", "node_id": "...", "handoff_valid": true},
    {"batch_id": "...", "node_type": "processor", "node_id": "...", "handoff_valid": true},
    {"batch_id": "...", "node_type": "distributor", "node_id": "...", "handoff_valid": true},
    {"batch_id": "...", "node_type": "retailer", "node_id": "...", "handoff_valid": true}
  ],
  "anomalies": [],
  "gap_count": 0,
  "total_transit_hours": 72
}
```

---

## Workflows (3)

### 1. `batch-ingest` (primary — triggered hourly via schedule)

Ingest new batch records, validate chains, detect anomalies, generate certificates.

**Phases:**

1. **scan-incoming** (command)
   - Command: `bash scripts/scan-incoming.sh`
   - Scans `data/incoming/` for new batch record JSON files
   - Uses `jq` to validate each file against the batch record schema
   - Moves valid records to `data/staged/{batch-id}.json`
   - Moves invalid records to `data/rejected/` with error annotation
   - Writes `data/staged/manifest.json` listing all staged batches with metadata
   - Exit 0 even if no new files (empty manifest = no-op for downstream)

2. **normalize-batches** (agent: batch-ingester)
   - Reads `data/staged/manifest.json` and all staged batch files
   - Normalizes field names, timestamps to ISO 8601, units to metric
   - Validates handler cert IDs against `config/authorized-handlers.yaml`
   - Flags unauthorized handlers but does not reject (flagged for anomaly-detector)
   - Computes `shasum` integrity hash for each batch record
   - Writes normalized records to `data/normalized/{batch-id}.json`
   - Writes `data/normalized/batch-index.json` with batch-id → product → node-type mapping

3. **validate-chains** (agent: chain-validator)
   - Reads `data/normalized/batch-index.json` and all normalized batches
   - Uses memory MCP to load existing chain state (`batch-genealogy`)
   - For each batch, traces `parent_batch_ids` backward to find or extend chains
   - Checks handoff completeness: each node must have matching timestamp_out → next timestamp_in
   - Identifies gaps: missing intermediate nodes, time discontinuities > threshold
   - Writes/updates chain records in `data/chains/{product}/{chain-id}.json`
   - Updates memory MCP `batch-genealogy` with new chain links
   - Writes `data/validation/chain-status.json`:
     ```json
     {
       "chains_validated": 12,
       "complete": 8,
       "gap_detected": 3,
       "anomaly_flagged": 1,
       "new_chains_started": 2
     }
     ```

4. **detect-anomalies** (agent: anomaly-detector)
   - Reads `data/validation/chain-status.json` and all chain records
   - Reads `config/thresholds.yaml` for temperature limits, max transit times, etc.
   - Checks:
     - **Temperature excursions**: any reading outside product-specific safe range
     - **Timing violations**: handoff gaps > configured maximum hours
     - **Unauthorized handlers**: handler_cert_id not in authorized-handlers.yaml
     - **Quantity discrepancies**: sum of child batch quantities > parent (split loss threshold)
     - **Duplicate batch IDs**: same batch_id appearing from different nodes
   - Writes `data/anomalies/anomaly-report.json` with severity (critical/warning/info)
   - Writes `data/anomalies/recall-candidates.json` for batches with critical anomalies

5. **chain-decision** (agent: chain-validator)
   - Reads `data/validation/chain-status.json` and `data/anomalies/anomaly-report.json`
   - Decision contract:
     - `verdict`: `complete` | `gap-detected` | `anomaly-flagged` | `recall-triggered`
     - `reasoning`: explanation of chain status
     - `critical_anomaly_count`: number
     - `affected_batch_ids`: list
   - Routes:
     - `complete` → proceed to generate-certificates
     - `gap-detected` → proceed to generate-certificates (certificates note gaps)
     - `anomaly-flagged` → proceed to generate-certificates (certificates flag anomalies)
     - `recall-triggered` → proceed to generate-certificates (certificates marked RECALL)

6. **generate-certificates** (agent: certificate-generator)
   - Reads chain records from `data/chains/`
   - Reads anomaly report from `data/anomalies/`
   - For each complete or near-complete chain, generates:
     - `output/certificates/{chain-id}-provenance.md` — formal provenance certificate
       - Full chain-of-custody with timestamps, handlers, locations
       - Integrity hashes for each batch record
       - Any anomalies or gaps noted
       - QR code placeholder for consumer lookup
     - `output/consumer/{chain-id}-summary.md` — consumer-facing summary
       - Origin (farm name, location)
       - Journey highlights (processing, distribution)
       - Food safety status
       - "Scan to verify" section
   - Writes `output/certificates/index.json` listing all generated certificates

7. **compute-checksums** (command)
   - Command: `bash scripts/compute-checksums.sh`
   - Runs `shasum -a 256` on every certificate file
   - Writes `output/certificates/checksums.sha256`
   - Provides tamper-detection for issued certificates

### 2. `compliance-report` (scheduled daily)

Generates FSMA 204 compliance reports and recall-readiness assessments.

**Phases:**

1. **gather-metrics** (command)
   - Command: `bash scripts/gather-metrics.sh`
   - Counts files in each data directory using `find` and `wc`
   - Computes aggregate stats with `jq`: total batches, chains, anomalies by type
   - Writes `data/metrics/daily-stats.json`

2. **generate-compliance** (agent: compliance-reporter)
   - Reads `data/metrics/daily-stats.json`
   - Reads all chain records from `data/chains/`
   - Reads anomaly history from `data/anomalies/`
   - Uses memory MCP to load historical compliance data (`compliance-history`)
   - Generates:
     - `output/compliance/fsma-204-report.md` — FSMA 204 traceability compliance
       - Critical Tracking Events (CTEs) documented
       - Key Data Elements (KDEs) completeness rate
       - Gap analysis
     - `output/compliance/recall-readiness.md` — recall simulation results
       - "Can we trace batch X within 24 hours?" assessment
       - Affected downstream batches for any given source batch
     - `output/compliance/executive-summary.md` — one-page status for leadership
   - Updates memory MCP `compliance-history` with today's metrics

3. **compliance-decision** (agent: compliance-reporter)
   - Decision contract:
     - `verdict`: `compliant` | `documentation-gap` | `violation`
     - `reasoning`: explanation
     - `kde_completeness_pct`: number (0-100)
     - `recall_ready`: boolean
   - Routes:
     - `compliant` → done (post-success)
     - `documentation-gap` → rework to gather-metrics (triggers re-ingestion investigation)
     - `violation` → rework to gather-metrics (with violation details for targeted fix)
   - Max rework attempts: 2

### 3. `recall-response` (on-demand — triggered manually when recall needed)

Emergency recall tracing: given a batch ID, trace all downstream batches immediately.

**Phases:**

1. **trace-batch** (agent: chain-validator)
   - Reads batch ID from task description
   - Uses memory MCP `batch-genealogy` to find all chains containing this batch
   - Traces forward through all child batches (fan-out)
   - Writes `output/recalls/{batch-id}/affected-batches.json`
   - Writes `output/recalls/{batch-id}/distribution-map.md` — where the product went

2. **generate-recall-notice** (agent: certificate-generator)
   - Reads `output/recalls/{batch-id}/affected-batches.json`
   - Generates `output/recalls/{batch-id}/recall-notice.md`:
     - Affected product, batch range, date range
     - Distribution points reached
     - Consumer action required
     - Retailer action required
   - Generates `output/recalls/{batch-id}/regulatory-filing.md`:
     - FDA/USDA formatted recall notification
     - Complete chain-of-custody evidence

---

## Schedules

| Schedule | Cron | Workflow | Purpose |
|---|---|---|---|
| `hourly-ingest` | `0 * * * *` | batch-ingest | Ingest new batch records every hour |
| `daily-compliance` | `0 6 * * *` | compliance-report | Daily compliance report at 6 AM |

---

## Config Files

### `config/thresholds.yaml`
```yaml
temperature:
  dairy:
    min_c: 0
    max_c: 4
  produce:
    min_c: 1
    max_c: 7
  meat:
    min_c: -2
    max_c: 4
  ambient:
    min_c: 10
    max_c: 25

transit:
  max_handoff_gap_hours: 4
  max_total_transit_hours: 120
  max_single_node_hours: 48

quantity:
  max_loss_pct: 5
```

### `config/authorized-handlers.yaml`
```yaml
handlers:
  - cert_id: "CERT-FM-2025-042"
    name: "J. Martinez"
    node_ids: ["FARM-CA-042"]
    valid_until: "2026-12-31"
  - cert_id: "CERT-PR-2025-101"
    name: "A. Chen"
    node_ids: ["PROC-CA-010", "PROC-CA-011"]
    valid_until: "2026-12-31"
  - cert_id: "CERT-DS-2025-201"
    name: "Regional Cold Chain LLC"
    node_ids: ["DIST-CA-001", "DIST-CA-002"]
    valid_until: "2027-06-30"
  - cert_id: "CERT-RT-2025-301"
    name: "FreshMart Receiving"
    node_ids: ["RETAIL-CA-050"]
    valid_until: "2026-12-31"
```

### `config/supply-chain-nodes.yaml`
```yaml
nodes:
  - id: "FARM-CA-042"
    type: farm
    name: "Sunrise Organic Farm"
    location: "Salinas, CA"
    certifications: ["USDA Organic", "GAP"]
  - id: "PROC-CA-010"
    type: processor
    name: "Valley Fresh Processing"
    location: "Watsonville, CA"
    certifications: ["SQF Level 3", "FSMA"]
  - id: "DIST-CA-001"
    type: distributor
    name: "Pacific Cold Chain"
    location: "San Jose, CA"
    certifications: ["FSMA", "COOL"]
  - id: "RETAIL-CA-050"
    type: retailer
    name: "FreshMart #50"
    location: "San Francisco, CA"
    certifications: ["FDA Retail"]
```

---

## Sample Data Files

### `data/incoming/farm/BATCH-2026-0331-FARM-001.json`
Farm-origin batch for organic strawberries — the starting point of a chain.

### `data/incoming/processor/BATCH-2026-0331-PROC-001.json`
Processor batch linked to farm batch — washing, grading, packaging.

### `data/incoming/distributor/BATCH-2026-0331-DIST-001.json`
Distributor batch — cold chain transport with temperature logging.

### `data/incoming/retailer/BATCH-2026-0331-RETAIL-001.json`
Retailer receiving — final node in chain, includes receiving inspection.

Provide a complete chain of 4 batches (farm → processor → distributor → retailer) for a single product, plus:
- One batch with a temperature excursion (distributor, temp spike to 12°C for produce)
- One batch with an unauthorized handler (processor, unknown cert_id)
- One orphan batch with no parent chain (to test gap detection)

---

## Scripts

### `scripts/scan-incoming.sh`
- Scans `data/incoming/` subdirectories for `.json` files
- Validates each with `jq` (checks required fields: batch_id, node_type, node_id, timestamp_in)
- Moves valid to `data/staged/`, invalid to `data/rejected/`
- Writes `data/staged/manifest.json`

### `scripts/compute-checksums.sh`
- Runs `shasum -a 256` on all files in `output/certificates/`
- Writes checksums file

### `scripts/gather-metrics.sh`
- Counts batches, chains, anomalies
- Aggregates with `jq`
- Writes daily stats JSON

---

## Directory Structure

```
provenance-tracker/
├── .ao/workflows/
│   ├── agents.yaml
│   ├── phases.yaml
│   ├── workflows.yaml
│   ├── mcp-servers.yaml
│   └── schedules.yaml
├── config/
│   ├── thresholds.yaml
│   ├── authorized-handlers.yaml
│   └── supply-chain-nodes.yaml
├── data/
│   ├── incoming/
│   │   ├── farm/
│   │   ├── processor/
│   │   ├── distributor/
│   │   └── retailer/
│   ├── staged/
│   ├── rejected/
│   ├── normalized/
│   ├── chains/
│   ├── validation/
│   ├── anomalies/
│   └── metrics/
├── scripts/
│   ├── scan-incoming.sh
│   ├── compute-checksums.sh
│   └── gather-metrics.sh
├── output/
│   ├── certificates/
│   ├── consumer/
│   ├── compliance/
│   └── recalls/
├── templates/
│   ├── provenance-certificate.md
│   ├── consumer-summary.md
│   ├── recall-notice.md
│   └── fsma-204-report.md
├── CLAUDE.md
└── README.md
```

---

## README Outline

1. **Header** — Supply Chain Provenance Tracker
2. **What It Does** — One paragraph: ingests supply chain batch records, validates chains, detects anomalies, generates provenance certificates
3. **Quick Start** — `ao daemon start`, drop batch JSONs into `data/incoming/`
4. **Architecture Diagram** — ASCII: incoming → scan → normalize → validate → detect → certify → report
5. **Workflows** — Table of 3 workflows with descriptions
6. **Agents** — Table of 5 agents
7. **Configuration** — How to set up thresholds, handlers, nodes
8. **Sample Data** — Description of included sample batches
9. **Output** — What gets generated and where
10. **FSMA 204 Compliance** — How this maps to regulatory requirements
11. **Recall Response** — How to trigger emergency recall tracing

---

## Key AO Features Demonstrated

- **Scheduled workflows** — hourly batch ingestion, daily compliance
- **Multi-agent pipeline** — 5 specialized agents with clear handoffs
- **Command phases** — jq validation, shasum integrity, bash file management
- **Decision contracts** — chain-status and compliance-status routing
- **Memory MCP** — persistent batch genealogy across runs
- **On-demand workflows** — recall-response triggered manually
- **Rework loops** — compliance workflow loops back on documentation gaps
- **Model variety** — haiku for fast normalization/generation, sonnet for reasoning
