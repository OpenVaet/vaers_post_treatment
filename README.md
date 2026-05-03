# VAERS Minors Adverse Events — LLM-Assisted Analysis Pipeline

## Overview

This project applies a multi-layer, LLM-assisted pipeline to the U.S. [Vaccine Adverse Event Reporting System (VAERS)](https://vaers.hhs.gov/) data in order to:

1. **Recover missing patient ages** from free-text symptom narratives using a local LLM.
2. **Classify severity** of adverse events reported for minors (age ≤ 18) — specifically deaths, life-threatening events, and permanent disabilities.
3. **Manually validate** the LLM's extractions through a web-based review interface, producing a human-audited dataset suitable for scientific publication.

The goal is to produce a peer-reviewed analysis of paediatric adverse event severity in VAERS, with transparent methodology showing both automated extraction performance and manual review statistics.

---

## Data Source

**VAERS** — Vaccine Adverse Event Reporting System, co-managed by the CDC and FDA.

- Download page: <https://vaers.hhs.gov/data/datasets.html>
- Select **"All Years Data"** and download the ZIP archive.
- Unzip the archive. It contains three CSV files per year batch:
  - `VAERSDATA.csv` — core report data (VAERS_ID, age, sex, dates, symptom text, etc.)
  - `VAERSSYMPTOMS.csv` — MedDRA-coded symptom terms per report
  - `VAERSVAX.csv` — vaccine product details per report
- Place **all unzipped `.csv` files** into the `data/` folder at the project root.

The raw VAERS data is public domain and freely redistributable. The dataset used in this project covers all available years (1990–present).

---

## Pipeline Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  VAERS raw CSVs (data/)                                             │
│  VAERSDATA.csv + VAERSSYMPTOMS.csv + VAERSVAX.csv                   │
└────────────────────┬─────────────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Layer 0 — parse_data.pl                                            │
│  Parses raw CSVs, merges per VAERS_ID, adds derived fields          │
│  (file_year, age_group_name, age_years), writes JSON archive.       │
│  Output: data_archive.json                                          │
└────────────────────┬─────────────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Layer 1 — verify_ages.pl                                           │
│  For reports where age_group_name is missing/empty:                  │
│  sends symptom_text to Ollama (gemma4:e4b) with structured JSON     │
│  schema output, extracting patient age in years (or decimal for     │
│  infants, e.g. 0.5 = 6 months).                                    │
│  Output: age_from_text_ollama.csv                                   │
│  Columns: vaers_id ; age ; status ; evidence                       │
│  Status ∈ {ok, ambiguous, missing, error}                           │
└────────────────────┬─────────────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Layer 2 — verify_severity.pl                                       │
│  For minors (age ≤ 18) identified in Layer 1:                       │
│  sends symptom_text to Ollama, classifying three binary outcomes:   │
│    • life_threatening (yes/no)                                      │
│    • subject_died (yes/no) — includes offspring deaths              │
│    • disability (yes/no)                                            │
│  Output: outcomes_minors_ollama.csv                                 │
│  Columns: vaers_id ; age ; life_threatening ; subject_died ;        │
│           disability ; status ; evidence                            │
│  ⚠ Layer 2 processing is still ongoing.                             │
└────────────────────┬─────────────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Manual Review — reviewer.pl (Mojolicious web UI)                   │
│  Two review tracks:                                                 │
│    1. Age review: validate / correct / reject LLM age extractions   │
│    2. Severity review: validate / correct / exclude, plus:          │
│       - death classification (subject vs. child/offspring vs. none) │
│       - apparent cause of death coding (free text, optional)        │
│  Stores: age_reviews.json, severity_reviews.json                    │
│  Exports: CSV via /api/export/ages and /api/export/severity         │
└────────────────────┬─────────────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Visualisation — R scripts                                          │
│    • plot_age_recovery.R      — age recovery rates by year          │
│    • plot_severity_minors.R   — severity breakdown by year          │
│    • plot_paper_dashboard.R   — combined multi-panel figure         │
│  Output: plots/ directory (PNG, 300 dpi)                            │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Project Status

| Component | Status | Notes |
|---|---|---|
| Layer 0 — `parse_data.pl` | ✅ Complete | Archive JSON built from all available VAERS years |
| Layer 1 — `verify_ages.pl` | ✅ Complete | All missing-age reports processed. Results in `age_from_text_ollama.csv` |
| Layer 2 — `verify_severity.pl` | 🔄 In progress | Severity classification of minors is still running against Ollama |
| Manual review — `reviewer.pl` | ✅ Ready | Web interface built, not yet started (waiting for Layer 2 completion) |
| Visualisation — R scripts | ✅ Ready | Scripts written, pending data finalisation for rendering |
| Scientific paper | 📝 Not started | Dependent on manual review completion and validation statistics |

### Known Limitations and Open Issues

- **`subject_died` scope**: The Layer 2 prompt currently treats offspring deaths (miscarriage, stillbirth, neonatal death) the same as the vaccinated subject dying. The reviewer interface allows disambiguating these manually (death_type = `subject` vs. `child`), but the LLM output itself does not distinguish them.
- **No hospitalisation field**: The standard VAERS/FDA "serious AE" definition includes hospitalisation. The current pipeline only captures life-threatening, death, and disability. A future layer or prompt revision could add this.
- **`file_year` absent from Layer 2 output**: The outcomes CSV does not include `file_year`; the R scripts join back to the archive for this. A minor improvement would be to write `file_year` directly into the CSV.
- **Validation sample not yet built**: For the paper, a random stratified sample (target: 200–500 reports per layer) will need manual expert review to compute inter-rater agreement (Cohen's κ) against the LLM.

---

## Directory Structure

```
project-root/
├── data/                          # Raw VAERS CSVs (not committed)
│   ├── VAERSDATA.csv
│   ├── VAERSSYMPTOMS.csv
│   └── VAERSVAX.csv
│
├── parse_data.pl                  # Layer 0: CSV → JSON archive
├── data_archive.json              # Layer 0 output (not committed, large)
│
├── verify_ages.pl                 # Layer 1: LLM age extraction
├── age_from_text_ollama.csv       # Layer 1 output
│
├── verify_severity.pl             # Layer 2: LLM severity classification
├── outcomes_minors_ollama.csv     # Layer 2 output (growing)
│
├── reviewer.pl                    # Mojolicious review web interface
├── age_reviews.json               # Manual age review decisions
├── severity_reviews.json          # Manual severity review decisions
│
├── plot_age_recovery.R            # Visualisation: age recovery rates
├── plot_severity_minors.R         # Visualisation: severity breakdown
├── plot_paper_dashboard.R         # Visualisation: combined paper figure
├── plots/                         # Generated PNG figures
│
└── README.md                      # This file
```

---

## Requirements

### System

- **Perl** ≥ 5.30
- **R** ≥ 4.1
- **Ollama** running locally with the `gemma4:e4b` model pulled

### Perl Modules

```bash
cpanm Mojolicious JSON Text::CSV Data::Printer Math::Round \
      Date::DayOfWeek Date::WeekNumber HTTP::Tiny File::Slurp \
      Scalar::Util Time::HiRes
```

The `autovivification` pragma is used but not critical; remove the `no autovivification;` line if unavailable.

### R Packages

```r
install.packages(c("tidyverse", "jsonlite", "showtext", "scales", "patchwork"))
```

### Ollama

```bash
# Install: https://ollama.com/download
ollama pull gemma4:e4b
ollama serve   # must be running on port 11434 before Layer 1/2
```

---

## Usage

### Step 0 — Parse the raw data

```bash
# Ensure data/*.csv files are in place
perl parse_data.pl
# Produces: data_archive.json
```

### Step 1 — Extract missing ages

```bash
# Ollama must be running
perl verify_ages.pl
# Produces: age_from_text_ollama.csv (resumable — safe to interrupt and restart)
```

### Step 2 — Classify severity for minors

```bash
perl verify_severity.pl
# Produces: outcomes_minors_ollama.csv (resumable)
```

### Step 3 — Manual review

```bash
morbo reviewer.pl
# Open http://localhost:3000 in a browser
```

The review interface provides:

- **Age review** (`/ages`): validate, correct, or reject each LLM age extraction. Keyboard shortcuts: `1` validate, `2` correct, `3` reject, `Enter` save and advance.
- **Severity review** (`/severity`): validate, correct, or exclude each severity classification. Additional fields for death type (`S` subject, `C` child/offspring, `N` no death) and optional cause of death coding.
- **Dashboard** (`/`): live progress statistics for both review tracks.
- **CSV export**: `/api/export/ages` and `/api/export/severity`.

### Step 4 — Generate figures

```bash
Rscript plot_age_recovery.R
Rscript plot_severity_minors.R
Rscript plot_paper_dashboard.R
# Outputs in plots/
```

---

## Output File Formats

### `age_from_text_ollama.csv`

Semicolon-delimited. One row per VAERS report that was originally missing an age field.

| Column | Type | Description |
|---|---|---|
| `vaers_id` | integer | VAERS report identifier |
| `age` | number or `null` | Extracted age in years (decimal for infants, e.g. `0.5`) |
| `status` | string | `ok` = confident extraction, `ambiguous` = multiple patients/ages, `missing` = no age found, `error` = LLM failure |
| `evidence` | string | Short text snippet (≤ 140 chars) supporting the extraction |

### `outcomes_minors_ollama.csv`

Semicolon-delimited. One row per minor (age ≤ 18) with LLM severity classification.

| Column | Type | Description |
|---|---|---|
| `vaers_id` | integer | VAERS report identifier |
| `age` | number or `null` | Patient age in years |
| `life_threatening` | `yes` / `no` | Life-threatening event |
| `subject_died` | `yes` / `no` | Any death reported (subject or offspring) |
| `disability` | `yes` / `no` | Permanent disability |
| `status` | string | `ok` or `error` |
| `evidence` | string | Supporting snippet (≤ 180 chars) |

### `age_reviews.json` / `severity_reviews.json`

JSON objects keyed by `vaers_id`. Each entry records the reviewer's decision, any corrections, timestamps, and free-text notes. Exported to CSV via the web interface API endpoints.

---

## LLM Configuration

Both Layer 1 and Layer 2 use **Ollama** with the `gemma4:e4b` model. Key design choices:

- **Structured output**: Ollama's `format` parameter with a JSON schema forces the model to return well-typed JSON, eliminating most parsing failures.
- **Prompt truncation**: Symptom texts longer than 6,000 characters are truncated to keep inference fast and within context limits.
- **Resumability**: Both scripts track processed VAERS IDs in the output CSV and skip them on restart, making the pipeline safe to interrupt.
- **Timeout**: HTTP requests to Ollama have a 120-second timeout to avoid infinite hangs.
- **Keep-alive**: Models stay loaded for 5 minutes between requests to avoid reload overhead.

To change the model, edit the `$ollama_model` variable at the top of `verify_ages.pl` and `verify_severity.pl`.

---

## Citation / Licence

VAERS data is in the public domain. Licence and citation guidance will be added upon manuscript submission.
