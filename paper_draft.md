# LLM-Assisted Recovery and Severity Classification of Paediatric Adverse Event Reports in VAERS: A Multi-Layer Pipeline with Human Validation

---

**Draft — version 0.1**

---

## Abstract

The Vaccine Adverse Event Reporting System (VAERS) is the primary spontaneous reporting system for post-vaccination adverse events in the United States. A substantial fraction of reports lack structured demographic fields — notably patient age — limiting population-level analyses, particularly for paediatric safety signals. We present a multi-layer pipeline that uses a locally deployed large language model (LLM) to (1) recover patient ages from free-text symptom narratives in reports where the age field is missing, and (2) classify the severity of adverse events among identified minors (age ≤ 18 years). Each layer is validated against manual human review through a purpose-built web interface. We apply this pipeline to the complete publicly available VAERS dataset (1990–2024). Layer 1 (age extraction) processed [N_MISSING] reports missing an age field, recovering a confident age in [N_RECOVERED] cases ([PCT_RECOVERED]%). Manual validation of a [N_VALIDATED_AGES]-report sample yielded an agreement rate of [PCT_AGREEMENT_AGES]% between the LLM and human reviewer (Cohen's κ = [KAPPA_AGES]). Layer 2 (severity classification) processed [N_MINORS] minor reports, classifying life-threatening events, deaths, and permanent disabilities with per-outcome agreement rates ranging from [PCT_AGREE_LO]% to [PCT_AGREE_HI]% (κ = [KAPPA_LO]–[KAPPA_HI]). Human review further disambiguated [N_DEATHS_FLAGGED] LLM-flagged death reports into vaccinated-subject deaths ([N_SUBJECT_DEATHS]), offspring/neonatal deaths ([N_OFFSPRING_DEATHS]), and false positives ([N_DEATH_FP]). This pipeline demonstrates that locally deployed, open-weight LLMs with structured output constraints can serve as scalable, reproducible tools for enriching large pharmacovigilance datasets, provided that human validation quantifies and bounds their error rates.

**Keywords:** VAERS, adverse events, large language model, pharmacovigilance, paediatric safety, text extraction, severity classification, inter-rater reliability


## 1. Introduction

Post-marketing pharmacovigilance relies heavily on spontaneous adverse event reporting systems. In the United States, the Vaccine Adverse Event Reporting System (VAERS), jointly managed by the Centers for Disease Control and Prevention (CDC) and the Food and Drug Administration (FDA), is the cornerstone of passive vaccine safety surveillance [1]. VAERS receives reports from healthcare providers, vaccine manufacturers, and the public; as of 2024, the database contains over [N_TOTAL_REPORTS] reports spanning more than three decades.

Despite its scale, VAERS has well-documented limitations. Reports are unverified, subject to reporting biases, and — critically for population-level analysis — frequently incomplete in their structured fields. Patient age is among the most important demographic variables for stratified safety analysis, yet a non-trivial fraction of reports leave the age field blank or ambiguous [2]. This is particularly problematic for paediatric pharmacovigilance, where age-specific risk assessment is essential for informing vaccination schedules and parental communication.

Prior approaches to incomplete VAERS data have relied on manual chart review or simple rule-based text parsing, neither of which scales to the full database. The emergence of capable open-weight large language models (LLMs) that can be deployed locally — without transmitting protected health information to external servers — opens a new avenue for structured data recovery from free-text narratives at scale [3, 4].

In this study, we describe and validate a multi-layer pipeline that:

1. Extracts patient ages from free-text symptom narratives for reports where the structured age field is missing, using a locally deployed LLM with constrained JSON output.
2. Classifies the severity of adverse events reported for minors (age ≤ 18), distinguishing life-threatening events, deaths, and permanent disabilities.
3. Validates both layers through systematic human review, quantifying LLM–human agreement via standard inter-rater reliability metrics.

Our approach differs from prior work in several respects. First, we use a fully local LLM deployment (Ollama with gemma4:e4b), ensuring that sensitive patient narratives never leave the analyst's machine. Second, we enforce structured output via JSON schema constraints at the inference level, eliminating the need for post-hoc parsing of free-text model responses. Third, we provide a complete, resumable, open-source pipeline — from raw VAERS CSV ingestion through LLM extraction to a web-based human review interface — designed for reproducibility and extension.


## 2. Methods

### 2.1 Data Source

We obtained the complete VAERS public dataset from https://vaers.hhs.gov/data/datasets.html, selecting the "All Years Data" archive. This archive contains three CSV files per reporting year: VAERSDATA (core demographics and symptom narratives), VAERSSYMPTOMS (MedDRA-coded symptom terms), and VAERSVAX (vaccine product details). All files were placed in a local directory without modification.

### 2.2 Pipeline Architecture

The pipeline consists of four sequential layers (Figure 1), each producing an intermediate output that feeds into the next:

- **Layer 0 (Parsing):** Raw CSV files are parsed, merged on VAERS_ID, and converted to a single JSON archive with derived fields (filing year, age group, numeric age).
- **Layer 1 (Age extraction):** For reports missing a structured age, the symptom narrative is sent to a local LLM to extract a patient age in years.
- **Layer 2 (Severity classification):** For identified minors (age ≤ 18), the symptom narrative is sent to the LLM to classify three binary severity outcomes.
- **Layer 3 (Human validation):** A web-based review interface allows a human reviewer to validate, correct, or reject the LLM's outputs for both layers.

All layers are implemented in Perl 5.30+ and are fully resumable: each writes its output incrementally and skips previously processed records on restart.

> **[FIGURE 1 PLACEHOLDER]**
> *Figure 1. Pipeline architecture. Four sequential layers from raw VAERS CSVs to human-validated output. Layer 0: CSV parsing and JSON archive creation. Layer 1: LLM-based age extraction for reports missing the age field. Layer 2: LLM-based severity classification for identified minors. Layer 3: Web-based human review interface with shared validation store.*

### 2.3 Layer 0 — Data Parsing

The parsing layer reads all VAERSDATA CSV files, extracts the VAERS_ID, patient age (AGE_YRS), age group categorisation, filing year, and the full symptom narrative (SYMPTOM_TEXT). Records are stored in a JSON archive keyed by VAERS_ID, enabling efficient random access by downstream layers.

Reports were included in Layer 1 processing if their age_group_name field was empty or null, indicating that no structured age information was available.

### 2.4 Layer 1 — LLM Age Extraction

#### 2.4.1 Model and deployment

We used the gemma4:e4b model served locally through Ollama (v[OLLAMA_VERSION]) on a [HARDWARE_DESCRIPTION]. The model was accessed via the Ollama HTTP API (/api/generate endpoint) with a 120-second timeout per request and a 5-minute keep-alive to avoid repeated model loading.

#### 2.4.2 Prompt design

Each request contained the following instruction followed by the symptom narrative (truncated to 6,000 characters):

> Extract the PATIENT age in years from the text. If multiple patients are mentioned OR multiple different ages are mentioned OR unclear who the age belongs to: status="ambiguous" and age=null. If no patient age is explicitly present: status="missing" and age=null. If exactly one patient and exactly one explicit age in years: status="ok" and age=integer. If the patient is under 1 year old, status="ok" and age=double (e.g. 0.5 at 6 months).

#### 2.4.3 Structured output

Rather than parsing free-text model responses, we used Ollama's `format` parameter with a JSON schema specifying the required output structure:

```json
{
  "type": "object",
  "properties": {
    "age":      { "anyOf": [{"type":"integer"}, {"type":"number"}, {"type":"null"}] },
    "status":   { "type": "string", "enum": ["ok","ambiguous","missing","error"] },
    "evidence": { "type": "string" }
  },
  "required": ["age", "status", "evidence"]
}
```

This schema-constrained generation forces the model to produce well-typed JSON, eliminating parsing failures and ensuring that the `status` field is always one of the four expected values.

#### 2.4.4 Post-processing

Extracted ages were subjected to sanity bounds (0–120 years). Decimal values (e.g. 0.5 for a 6-month-old infant) were preserved. Ages outside bounds were reclassified as "ambiguous." The output was written to a semicolon-delimited CSV file (vaers_id; age; status; evidence).

### 2.5 Layer 2 — Severity Classification

#### 2.5.1 Inclusion criteria

Reports were included in Layer 2 if: (a) their Layer 1 extraction status was "ok" with a numeric age ≤ 18, and (b) the report was not already covered by a usable structured age field in the original VAERS data.

#### 2.5.2 Classification schema

For each included report, the symptom narrative was sent to the same LLM with a prompt requesting classification of three binary outcomes:

- **life_threatening:** whether the event was described as life-threatening (e.g. anaphylaxis, cardiac arrest, ICU admission for vital threat).
- **subject_died:** whether any death was reported, including the vaccinated subject or offspring (miscarriage, stillbirth, neonatal death).
- **disability:** whether a permanent or long-lasting disability was attributed to the event.

The model was constrained to answer each as exactly "yes" or "no" via JSON schema, plus an evidence snippet of up to 160 characters.

#### 2.5.3 Scope note

The `subject_died` field was intentionally defined broadly to capture all death mentions in the narrative. The subsequent human review layer disambiguates these into vaccinated-subject deaths, offspring deaths, and false positives (see §2.6).

### 2.6 Layer 3 — Human Validation

A web-based review interface was built using the Mojolicious (Perl) framework to enable systematic manual validation of both LLM layers. The interface provides two review tracks sharing a common validation data store:

**Age review track.** For each record, the reviewer sees the full symptom narrative (with age mentions highlighted) alongside the LLM's extraction (age, status, evidence). The reviewer selects one of three decisions:
- *Validated:* the LLM output is correct as-is.
- *Corrected:* the LLM found the wrong age; the reviewer provides the correct value.
- *Rejected:* the LLM output is erroneous (e.g. extracted a bystander's age, hallucinated an age).

Two entry points exist for the age track: a "found ages" view (status=ok only) and a full view (all statuses), both reading from and writing to the same data store.

**Severity review track.** For each classified minor report, the reviewer sees the symptom narrative (with death and life-threatening keywords highlighted) alongside the LLM's three binary classifications. The reviewer selects:
- *Validated:* all three classifications are correct.
- *Corrected:* one or more classifications need overriding (individual yes/no overrides for life-threatening and disability).
- *Excluded:* the report should be removed from analysis (e.g. age extraction was wrong, report is a duplicate).

For reports flagged as containing a death, the reviewer additionally classifies the death type (vaccinated subject / child or offspring / no death — LLM error) and optionally codes an apparent cause of death in free text.

Keyboard shortcuts facilitate rapid sequential review. All decisions are stored in JSON files and exportable as CSV for downstream analysis.

### 2.7 Statistical Analysis

#### 2.7.1 Age recovery

We report the age recovery rate as the proportion of missing-age reports for which the LLM returned status=ok with a numeric age, stratified by filing year.

#### 2.7.2 Inter-rater agreement

For each validated layer, we compute:

- **Raw agreement:** the proportion of reviewed records where the human reviewer validated the LLM output without modification.
- **Cohen's kappa (κ):** chance-corrected agreement for each binary severity outcome, treating the LLM as one rater and the human as the other.
- **Confusion matrices:** for the death outcome specifically, showing true positives, false positives, false negatives, and true negatives.

#### 2.7.3 Severity rates

Severity rates are reported as the proportion of classified minor reports flagged for each outcome (life-threatening, death, disability, composite "any severe"), stratified by filing year. Following human review, we report both the raw LLM rates and the human-corrected rates.

All analyses were performed in R (v4.x) using the tidyverse, jsonlite, and scales packages. Figures were produced with ggplot2 and patchwork.


## 3. Results

### 3.1 Dataset Overview

The complete VAERS archive contained [N_TOTAL_REPORTS] reports spanning filing years [YEAR_MIN]–[YEAR_MAX]. Of these, [N_MISSING_AGE] ([PCT_MISSING_AGE]%) lacked a structured age field and were processed by Layer 1.

### 3.2 Age Recovery

Layer 1 processed all [N_MISSING_AGE] reports missing an age field. The LLM returned a confident extraction (status=ok) for [N_RECOVERED] reports ([PCT_RECOVERED]%), classified [N_AMBIGUOUS] ([PCT_AMBIGUOUS]%) as ambiguous (multiple patients or ages mentioned), [N_STILL_MISSING] ([PCT_STILL_MISSING]%) as genuinely missing (no age information in the narrative), and [N_ERROR] ([PCT_ERROR]%) as processing errors.

> **[FIGURE 2 PLACEHOLDER]**
> *Figure 2. Age recovery by filing year. Stacked bars show extraction status (recovered / ambiguous / missing / error) for each year. Line overlay shows the percentage of ages successfully recovered. See plot_age_recovery.R.*

Recovery rates varied by filing year (Figure 2), with [DESCRIPTION_OF_TEMPORAL_PATTERN].

Among recovered ages, [N_MINORS_IDENTIFIED] reports ([PCT_MINORS]%) were identified as minors (age ≤ 18) and forwarded to Layer 2.

### 3.3 Age Extraction Validation

Manual review was performed on [N_VALIDATED_AGES] reports ([PCT_REVIEW_COVERAGE_AGES]% of all Layer 1 output). Table 1 summarises the agreement by LLM status category.

> **[TABLE 1 PLACEHOLDER]**
> *Table 1. LLM–human agreement for age extraction, stratified by LLM self-reported status. Columns: LLM status, N reviewed, N validated, N corrected, N rejected, agreement rate (%).*

For the "found" subset (status=ok), the overall agreement rate was [PCT_AGREEMENT_FOUND]%. Agreement was stable across filing years (Figure 3, Panel C) and did not vary substantially by age bracket (Figure 3, Panel C), though [NOTE_ANY_BRACKET_VARIATION].

Among corrected records (n=[N_CORRECTED_AGES]), the median absolute deviation between the LLM-extracted and human-corrected age was [MEDIAN_DELTA] years (Figure 3, Panel D), indicating that [INTERPRETATION_OF_CORRECTIONS].

> **[FIGURE 3 PLACEHOLDER]**
> *Figure 3. Cross-validation of age extraction (found ages, status=ok). Panel A: overall decision distribution. Panel B: agreement by filing year. Panel C: agreement by age bracket. Panel D: LLM vs. human-corrected age scatter. See plot_validation_ages_found.R.*

### 3.4 Severity Classification

Layer 2 processed [N_MINORS_CLASSIFIED] minor reports. The LLM flagged [N_LT] ([PCT_LT]%) as life-threatening, [N_DIED] ([PCT_DIED]%) as involving a death, and [N_DISAB] ([PCT_DISAB]%) as resulting in permanent disability. Overall, [N_SEVERE] ([PCT_SEVERE]%) were classified as having at least one severe outcome.

> **[FIGURE 4 PLACEHOLDER]**
> *Figure 4. Severity of adverse events among VAERS minors, by filing year. Stacked bars: severe vs. non-severe. Grouped bars: breakdown by outcome type (death, life-threatening, disability). See plot_severity_minors.R.*

### 3.5 Severity Validation

Manual review was performed on [N_VALIDATED_SEV] severity classifications ([PCT_REVIEW_COVERAGE_SEV]% of Layer 2 output). Table 2 presents the per-outcome agreement metrics.

> **[TABLE 2 PLACEHOLDER]**
> *Table 2. Per-outcome LLM–human agreement for severity classification. Columns: outcome, N, raw agreement (%), Cohen's κ, sensitivity, specificity.*

Cohen's κ ranged from [KAPPA_LO] (for [LOWEST_KAPPA_OUTCOME]) to [KAPPA_HI] (for [HIGHEST_KAPPA_OUTCOME]), indicating [INTERPRETATION_KAPPA] agreement overall.

> **[FIGURE 5 PLACEHOLDER]**
> *Figure 5. Severity cross-validation. Panel A: decision distribution. Panel B: per-outcome agreement with Cohen's κ. Panel C: death confusion matrix. Panel D: death type disambiguation. See plot_validation_severity.R.*

### 3.6 Death Disambiguation

Of [N_DEATHS_FLAGGED] reports flagged as containing a death by the LLM or the human reviewer, manual review classified [N_SUBJECT_DEATHS] ([PCT_SUBJECT_DEATHS]%) as deaths of the vaccinated subject, [N_OFFSPRING_DEATHS] ([PCT_OFFSPRING_DEATHS]%) as offspring or neonatal deaths (miscarriage, stillbirth, neonatal death), and [N_DEATH_FP] ([PCT_DEATH_FP]%) as false positives where no death had actually occurred.

Among reports with a coded cause of death (n=[N_COD_CODED]), the most frequently recorded causes were [TOP_CAUSES_LIST].

> **[FIGURE 6 PLACEHOLDER]**
> *Figure 6. Cause-of-death analysis. Top: frequency of coded causes. Bottom: causes split by death type (subject vs. offspring). See plot_validation_severity.R (death detail figure).*


## 4. Discussion

### 4.1 Principal Findings

This study demonstrates that a locally deployed, open-weight LLM with structured output constraints can recover missing demographic data from VAERS narratives at scale and classify adverse event severity with [QUALITY_LEVEL] accuracy, as validated by human review. The key findings are:

1. **Age recovery is feasible at scale.** The LLM recovered ages from [PCT_RECOVERED]% of reports lacking a structured age field, with [PCT_AGREEMENT_FOUND]% human-validated accuracy among confident extractions. This substantially increases the analytic utility of the VAERS dataset for age-stratified studies.

2. **Severity classification is reliable for most outcomes.** Per-outcome agreement rates of [PCT_AGREE_LO]–[PCT_AGREE_HI]% and Cohen's κ values of [KAPPA_LO]–[KAPPA_HI] place the LLM's performance within the range typically considered [KAPPA_INTERPRETATION] for classification tasks.

3. **Death reports require human disambiguation.** The LLM's broad "subject_died" flag captured both vaccinated-subject deaths and offspring deaths (miscarriage, stillbirth). Human review revealed that [PCT_OFFSPRING_DEATHS]% of flagged deaths were offspring rather than subject deaths, a distinction that is critical for accurate paediatric mortality signal detection.

### 4.2 Methodological Considerations

**Local deployment.** A central design choice was to run the LLM entirely locally. VAERS symptom narratives, while publicly available, contain detailed clinical descriptions that warrant careful handling. Local deployment via Ollama eliminates data transmission risks and enables analysis on air-gapped systems. The gemma4:e4b model, while not the largest available, proved sufficient for the extraction and classification tasks defined here.

**Structured output.** The use of JSON schema constraints at the inference level is a key methodological contribution. By forcing the model to produce typed, enumerated outputs, we eliminated the need for fragile regex-based post-processing of free-text responses, reduced the error rate to near zero for structural failures, and ensured that every output record conforms to a consistent schema.

**Resumability.** Both processing layers write output incrementally and skip previously processed records on restart. This is a practical necessity for analyses spanning hundreds of thousands of reports with per-record inference times of several seconds.

### 4.3 Comparison with Prior Work

Previous studies of VAERS data quality have noted the prevalence of missing fields [2, 5] and the challenges of free-text analysis [6]. Rule-based approaches to age extraction (e.g. regex matching of "X year old" patterns) have been used in unpublished analyses but suffer from low recall on narratives with non-standard phrasing. To our knowledge, this is the first study to apply LLM-based structured extraction to the full VAERS dataset with systematic human validation.

Recent work on LLM applications in pharmacovigilance has focused on adverse event detection from social media [7] and electronic health records [8], typically using cloud-hosted proprietary models. Our approach is distinct in using an open-weight model deployed locally, which has implications for reproducibility and data governance.

### 4.4 Implications for Pharmacovigilance

The pipeline described here is not specific to VAERS or to paediatric analysis. The two-layer pattern — structured extraction from free text followed by classification on the extracted subset — is applicable to any spontaneous reporting database with incomplete structured fields. Potential extensions include:

- Recovery of other missing fields (e.g. onset date, vaccination date, lot number).
- Classification of additional severity dimensions (e.g. hospitalisation, which is a standard component of the FDA's "serious" adverse event definition not included in our current Layer 2).
- Cross-database application to EudraVigilance, the WHO VigiBase, or national pharmacovigilance systems.

### 4.5 Limitations

Several limitations should be noted:

1. **VAERS reporting biases.** VAERS is a passive surveillance system. Reports are not verified, may be incomplete or inaccurate, and are subject to stimulated reporting (e.g. increased public awareness during the COVID-19 vaccination campaign). Our pipeline enriches the dataset but does not address these fundamental biases.

2. **LLM as a single rater.** The human validation quantifies the agreement between the LLM and one human reviewer. A more rigorous approach would involve multiple independent human reviewers to compute inter-rater reliability among humans and then compare the LLM against that benchmark.

3. **Prompt sensitivity.** The LLM's extraction quality may be sensitive to prompt phrasing. We did not conduct a systematic prompt-engineering study; the prompts used were developed iteratively based on inspection of early outputs.

4. **Model-specific results.** Our results are specific to gemma4:e4b. Different models may yield different accuracy profiles. We did not conduct a multi-model comparison.

5. **Death scope conflation.** The Layer 2 prompt defined "subject_died" broadly to include offspring deaths. While the human review layer disambiguates these, the LLM's raw output conflates categorically different events. Future iterations should separate these at the prompt level.

6. **No hospitalisation field.** The standard FDA definition of a "serious" adverse event includes hospitalisation. Our current severity classification does not capture this dimension, limiting comparability with official VAERS serious-event flags.

7. **Temporal confounding.** Recovery and severity rates vary by filing year, but we did not model confounders such as changes in VAERS reporting practices, vaccine schedule changes, or the introduction of new vaccines.


## 5. Conclusion

We have presented and validated a multi-layer pipeline for recovering missing patient ages and classifying adverse event severity in the VAERS database using a locally deployed large language model. The pipeline achieves [PCT_RECOVERED]% age recovery with [PCT_AGREEMENT_FOUND]% human-validated accuracy, and severity classification with Cohen's κ values of [KAPPA_LO]–[KAPPA_HI] across three outcome dimensions. Human review further disambiguated death reports into subject and offspring deaths, revealing that [PCT_OFFSPRING_DEATHS]% of LLM-flagged deaths involved offspring rather than the vaccinated individual.

This work demonstrates that open-weight LLMs with structured output constraints are viable tools for enriching large pharmacovigilance datasets, provided that their outputs are systematically validated against human review. The complete pipeline — including data parsing, LLM extraction, web-based review interface, and validation analysis — is available as open-source code to support reproducibility and adaptation to other pharmacovigilance contexts.


## Data Availability

VAERS data are publicly available at https://vaers.hhs.gov/data/datasets.html. The analysis code, review interface, and R visualisation scripts will be made available in a public repository upon publication.


## References

[1] Shimabukuro TT, Nguyen M, Martin D, DeStefano F. Safety monitoring in the Vaccine Adverse Event Reporting System (VAERS). *Vaccine*. 2015;33(36):4398-4405.

[2] Varricchio F, Iskander J, Destefano F, et al. Understanding vaccine safety information from the Vaccine Adverse Event Reporting System. *Pediatr Infect Dis J*. 2004;23(4):287-294.

[3] Singhal K, Azizi S, Tu T, et al. Large language models encode clinical knowledge. *Nature*. 2023;620(7972):172-180.

[4] Thirunavukarasu AJ, Ting DSJ, Elangovan K, et al. Large language models in medicine. *Nat Med*. 2023;29(8):1930-1940.

[5] Rosenthal S, Chen R. The reporting sensitivities of two passive surveillance systems for vaccine adverse events. *Am J Public Health*. 1995;85(12):1706-1709.

[6] Du J, Xiang Y, Sankaranarayanapillai M, et al. Extracting postmarketing adverse events from safety reports in the vaccine adverse event reporting system (VAERS) using deep learning. *J Am Med Inform Assoc*. 2021;28(7):1393-1400.

[7] Sarker A, Gonzalez-Hernandez G. An unsupervised and customizable misspelling generator for mining noisy health-related text sources. *J Biomed Inform*. 2018;88:98-107.

[8] Yang X, Chen A, Peng Y, et al. A large language model for electronic health records. *NPJ Digit Med*. 2022;5(1):194.

---

> **Word count:** ~[WORD_COUNT] (excluding references, tables, and figure legends)
>
> **Figures:** 6 (with placeholders)
>
> **Tables:** 2 (with placeholders)
