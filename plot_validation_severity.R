#!/usr/bin/env Rscript
# plot_validation_severity.R
# ---------------------------------------------------------------
# Cross-validation figures for the LLM severity classification
# layer (outcomes_minors_ollama.csv vs. severity_reviews.json).
#
# Figures produced (plots/):
#   1. validation_severity_summary.png — combined 4-panel figure
#   2. validation_severity_deaths.png  — death disambiguation detail
#
# Inputs:
#   - outcomes_minors_ollama.csv
#   - severity_reviews.json
#   - data_archive.json
# ---------------------------------------------------------------

library(tidyverse)
library(jsonlite)
library(showtext)
library(scales)
library(patchwork)

font_add_google("Open Sans", "opensans")
showtext_auto()

# ---- Paths ----
outcomes_path <- "outcomes_minors_ollama.csv"
reviews_path  <- "severity_reviews.json"
archive_path  <- "data_archive.json"
output_dir    <- "plots"
if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

# ---- Theme ----
theme_paper <- function(base_size = 11) {
  theme_minimal(base_family = "opensans", base_size = base_size) %+replace%
    theme(
      plot.title       = element_text(face = "bold", size = base_size + 2, margin = margin(b = 6)),
      plot.subtitle    = element_text(colour = "grey40", size = base_size - 1, margin = margin(b = 8)),
      plot.caption     = element_text(colour = "grey50", size = base_size - 3, hjust = 0),
      panel.grid.minor = element_blank(),
      legend.position  = "bottom",
      strip.text       = element_text(face = "bold")
    )
}

decision_colors <- c(
  "Validated" = "#2D6A4F",
  "Corrected" = "#457B9D",
  "Excluded"  = "#6C757D"
)

# ---- 1. Load LLM outcomes ----
outcomes_df <- read_delim(outcomes_path, delim = ";",
                          col_types = cols(.default = col_character())) %>%
  mutate(
    vaers_id    = as.character(vaers_id),
    age_numeric = ifelse(age == "null" | is.na(age), NA_real_, as.numeric(age)),
    llm_lt      = life_threatening == "yes",
    llm_died    = subject_died == "yes",
    llm_disab   = disability == "yes",
    llm_severe  = llm_lt | llm_died | llm_disab
  ) %>%
  filter(status == "ok")

# ---- 2. Load human reviews ----
reviews_raw <- fromJSON(reviews_path)
reviews_df  <- bind_rows(
  lapply(names(reviews_raw), function(vid) {
    r <- reviews_raw[[vid]]
    tibble(
      vaers_id            = vid,
      decision            = r$decision            %||% NA_character_,
      death_type          = r$death_type           %||% NA_character_,
      cause_of_death      = r$cause_of_death       %||% NA_character_,
      lt_override         = r$lt_override          %||% NA_character_,
      disability_override = r$disability_override  %||% NA_character_
    )
  })
)

# ---- 3. Archive (file_year) ----
archive_raw <- fromJSON(archive_path)
year_df     <- bind_rows(
  lapply(names(archive_raw), function(id) {
    tibble(vaers_id = id, file_year = as.integer(archive_raw[[id]]$file_year))
  })
)

# ---- 4. Merge ----
merged <- outcomes_df %>%
  inner_join(reviews_df, by = "vaers_id") %>%
  left_join(year_df,     by = "vaers_id") %>%
  mutate(
    decision = case_when(
      decision == "validated" ~ "Validated",
      decision == "corrected" ~ "Corrected",
      decision == "excluded"  ~ "Excluded",
      TRUE                    ~ decision
    ),
    decision = factor(decision, levels = c("Validated", "Corrected", "Excluded")),
    # Resolved outcomes (after human review)
    resolved_lt = case_when(
      decision == "Excluded"                    ~ FALSE,
      !is.na(lt_override) & lt_override != ""   ~ lt_override == "yes",
      TRUE                                      ~ llm_lt
    ),
    resolved_died = case_when(
      decision == "Excluded"                    ~ FALSE,
      !is.na(death_type) & death_type == "none" ~ FALSE,
      TRUE                                      ~ llm_died
    ),
    resolved_disab = case_when(
      decision == "Excluded"                              ~ FALSE,
      !is.na(disability_override) & disability_override != "" ~ disability_override == "yes",
      TRUE                                                ~ llm_disab
    ),
    resolved_severe = resolved_lt | resolved_died | resolved_disab
  )

n_total    <- nrow(outcomes_df)
n_reviewed <- nrow(merged)
cat(sprintf("Total outcomes     : %d\n", n_total))
cat(sprintf("Reviewed           : %d (%.1f%%)\n", n_reviewed, n_reviewed / n_total * 100))

# ================================================================
# PANEL A — Overall decision distribution
# ================================================================

overall <- merged %>%
  count(decision) %>%
  mutate(pct = n / sum(n) * 100)

pA <- ggplot(overall, aes(x = decision, y = n, fill = decision)) +
  geom_col(width = 0.55) +
  geom_text(
    aes(label = sprintf("%s\n%.1f%%", format(n, big.mark = ","), pct)),
    vjust = -0.3, size = 3.3, family = "opensans", lineheight = 0.9
  ) +
  scale_fill_manual(values = decision_colors, guide = "none") +
  scale_y_continuous(labels = comma, expand = expansion(mult = c(0, 0.18))) +
  labs(
    title    = "A — Severity review decisions",
    subtitle = sprintf("n = %s reviewed", format(n_reviewed, big.mark = ",")),
    x        = NULL,
    y        = "Reports"
  ) +
  theme_paper()

# ================================================================
# PANEL B — Per-outcome LLM-human agreement (validated + excluded only)
# ================================================================
# For validated records: LLM was correct.
# For excluded records: LLM was wrong (entire classification rejected).
# For corrected records: check each outcome individually against overrides.

compute_outcome_agreement <- function(df, llm_col, override_col) {
  df %>%
    mutate(
      llm_val  = !!sym(llm_col),
      resolved = !!sym(override_col),
      agree    = llm_val == resolved
    ) %>%
    summarise(
      n       = n(),
      n_agree = sum(agree),
      pct     = n_agree / n * 100,
      # Confusion counts
      tp = sum(llm_val & resolved),
      fp = sum(llm_val & !resolved),
      fn = sum(!llm_val & resolved),
      tn = sum(!llm_val & !resolved),
      .groups = "drop"
    )
}

outcome_names <- c("Life-threatening", "Death", "Disability", "Any severe")
llm_cols      <- c("llm_lt", "llm_died", "llm_disab", "llm_severe")
resolved_cols <- c("resolved_lt", "resolved_died", "resolved_disab", "resolved_severe")

outcome_agreement <- bind_rows(
  lapply(seq_along(outcome_names), function(i) {
    compute_outcome_agreement(merged, llm_cols[i], resolved_cols[i]) %>%
      mutate(outcome = outcome_names[i])
  })
) %>%
  mutate(outcome = factor(outcome, levels = outcome_names))

# Compute Cohen's kappa for each outcome
compute_kappa <- function(tp, fp, fn, tn) {
  n <- tp + fp + fn + tn
  if (n == 0) return(NA_real_)
  po <- (tp + tn) / n
  pe <- ((tp + fp) * (tp + fn) + (tn + fn) * (tn + fp)) / n^2
  if (pe >= 1) return(NA_real_)
  (po - pe) / (1 - pe)
}

outcome_agreement <- outcome_agreement %>%
  rowwise() %>%
  mutate(kappa = compute_kappa(tp, fp, fn, tn)) %>%
  ungroup()

pB <- ggplot(outcome_agreement, aes(x = outcome, y = pct)) +
  geom_col(fill = "#2D6A4F", width = 0.55) +
  geom_text(
    aes(label = sprintf("%.1f%%\n\u03BA=%.2f", pct, kappa)),
    vjust = -0.2, size = 3, family = "opensans", lineheight = 0.85, colour = "#1B4332"
  ) +
  scale_y_continuous(limits = c(0, 108), labels = function(x) paste0(x, "%")) +
  labs(
    title    = "B — Per-outcome LLM–human agreement",
    subtitle = "% raw agreement + Cohen's \u03BA (chance-corrected)",
    x        = NULL,
    y        = "Agreement (%)"
  ) +
  theme_paper()

# ================================================================
# PANEL C — Confusion heatmaps (LLM vs. human for "died")
# ================================================================

died_confusion <- merged %>%
  mutate(
    LLM   = ifelse(llm_died, "LLM: died", "LLM: no death"),
    Human = ifelse(resolved_died, "Human: died", "Human: no death")
  ) %>%
  count(LLM, Human)

pC <- ggplot(died_confusion, aes(x = Human, y = LLM, fill = n)) +
  geom_tile(colour = "white", linewidth = 1.5) +
  geom_text(aes(label = format(n, big.mark = ",")),
            size = 5, family = "opensans", fontface = "bold") +
  scale_fill_gradient(low = "#F1FAEE", high = "#E63946", guide = "none") +
  labs(
    title = "C — Confusion matrix: death classification",
    x     = NULL,
    y     = NULL
  ) +
  theme_paper() +
  theme(
    panel.grid.major = element_blank(),
    axis.text        = element_text(size = 10)
  )

# ================================================================
# PANEL D — Death disambiguation (subject vs child/offspring)
# ================================================================

death_records <- merged %>%
  filter(llm_died | resolved_died) %>%
  mutate(
    death_type = case_when(
      is.na(death_type) | death_type == "" ~ "(not classified)",
      death_type == "subject"              ~ "Vaccinated subject",
      death_type == "child"                ~ "Child / offspring",
      death_type == "none"                 ~ "No death (LLM error)",
      TRUE                                 ~ death_type
    ),
    death_type = factor(death_type, levels = c(
      "Vaccinated subject", "Child / offspring", "No death (LLM error)", "(not classified)"
    ))
  )

death_type_counts <- death_records %>%
  count(death_type) %>%
  mutate(pct = n / sum(n) * 100)

death_type_colors <- c(
  "Vaccinated subject"  = "#1D3557",
  "Child / offspring"   = "#E63946",
  "No death (LLM error)" = "#999",
  "(not classified)"    = "#CCC"
)

pD <- ggplot(death_type_counts, aes(x = death_type, y = n, fill = death_type)) +
  geom_col(width = 0.55) +
  geom_text(
    aes(label = sprintf("%d\n(%.1f%%)", n, pct)),
    vjust = -0.3, size = 3, family = "opensans", lineheight = 0.85
  ) +
  scale_fill_manual(values = death_type_colors, guide = "none") +
  scale_y_continuous(labels = comma, expand = expansion(mult = c(0, 0.18))) +
  labs(
    title    = "D — Death disambiguation",
    subtitle = sprintf("n = %d reports where LLM or human flagged a death", nrow(death_records)),
    x        = NULL,
    y        = "Reports"
  ) +
  theme_paper() +
  theme(axis.text.x = element_text(size = 8.5))

# ================================================================
# COMBINED PANEL FIGURE
# ================================================================

combined <- (pA | pB) / (pC | pD) +
  plot_annotation(
    title    = "Severity Classification — LLM vs. Human Cross-Validation (Minors \u2264 18)",
    subtitle = sprintf("Reviewed: %s / %s classified reports (%.1f%%)",
                       format(n_reviewed, big.mark = ","),
                       format(n_total, big.mark = ","),
                       n_reviewed / n_total * 100),
    caption  = "LLM: Ollama gemma4:e4b. Three binary outcomes classified per report. Human review via web interface with death disambiguation.",
    theme    = theme(
      plot.title    = element_text(face = "bold", size = 16, family = "opensans"),
      plot.subtitle = element_text(colour = "grey40", size = 11, family = "opensans"),
      plot.caption  = element_text(colour = "grey50", size = 9, family = "opensans", hjust = 0)
    )
  )

ggsave(file.path(output_dir, "validation_severity_summary.png"), combined,
       width = 14, height = 10, dpi = 300)
cat("Saved: plots/validation_severity_summary.png\n")

# ================================================================
# DEATH DETAIL FIGURE — cause of death coding
# ================================================================

cod_records <- death_records %>%
  filter(!is.na(cause_of_death) & cause_of_death != "" & death_type != "No death (LLM error)")

if (nrow(cod_records) >= 3) {
  cod_counts <- cod_records %>%
    mutate(cause_of_death = str_to_title(str_trim(cause_of_death))) %>%
    count(cause_of_death, sort = TRUE) %>%
    slice_head(n = 20)

  p_cod <- ggplot(cod_counts, aes(x = reorder(cause_of_death, n), y = n)) +
    geom_col(fill = "#1D3557", width = 0.6) +
    geom_text(aes(label = n), hjust = -0.3, size = 3, family = "opensans") +
    coord_flip() +
    scale_y_continuous(expand = expansion(mult = c(0, 0.15))) +
    labs(
      title    = "Apparent Cause of Death — Coded by Reviewer",
      subtitle = sprintf("n = %d death reports with cause coded (top %d shown)",
                         nrow(cod_records), min(nrow(cod_counts), 20)),
      x        = NULL,
      y        = "Reports",
      caption  = "Free-text cause of death entries, manually coded during severity review."
    ) +
    theme_paper()

  # Death type + cause combined
  cod_by_type <- cod_records %>%
    mutate(cause_of_death = str_to_title(str_trim(cause_of_death))) %>%
    count(death_type, cause_of_death, sort = TRUE) %>%
    group_by(death_type) %>%
    slice_head(n = 10) %>%
    ungroup()

  p_cod_type <- ggplot(cod_by_type,
                       aes(x = reorder(cause_of_death, n), y = n, fill = death_type)) +
    geom_col(width = 0.6) +
    geom_text(aes(label = n), hjust = -0.3, size = 2.8, family = "opensans") +
    coord_flip() +
    facet_wrap(~death_type, scales = "free_y") +
    scale_fill_manual(values = death_type_colors, guide = "none") +
    scale_y_continuous(expand = expansion(mult = c(0, 0.2))) +
    labs(
      title    = "Cause of Death by Death Type",
      subtitle = "Top causes, split by vaccinated subject vs. child/offspring",
      x        = NULL,
      y        = "Reports"
    ) +
    theme_paper()

  death_combined <- p_cod / p_cod_type +
    plot_annotation(
      title = "Death Reports — Cause-of-Death Analysis",
      theme = theme(
        plot.title = element_text(face = "bold", size = 16, family = "opensans")
      )
    )

  ggsave(file.path(output_dir, "validation_severity_deaths.png"), death_combined,
         width = 12, height = 12, dpi = 300)
  cat("Saved: plots/validation_severity_deaths.png\n")
} else {
  cat("Not enough cause-of-death entries to produce death detail figure.\n")
}

# ================================================================
# CONSOLE SUMMARY
# ================================================================

cat("\n======== Severity Validation Summary ========\n")
cat(sprintf("%-20s  %6s  %6s  %8s  %6s\n",
            "Outcome", "n", "Agree", "Agree%", "Kappa"))
for (i in seq_len(nrow(outcome_agreement))) {
  r <- outcome_agreement[i, ]
  cat(sprintf("%-20s  %6d  %6d  %7.1f%%  %6.3f\n",
              as.character(r$outcome), r$n, r$n_agree, r$pct, r$kappa))
}

cat("\nDecision breakdown:\n")
for (i in seq_len(nrow(overall))) {
  cat(sprintf("  %-12s : %6d (%5.1f%%)\n",
              as.character(overall$decision[i]), overall$n[i], overall$pct[i]))
}

if (nrow(death_type_counts) > 0) {
  cat("\nDeath type disambiguation:\n")
  for (i in seq_len(nrow(death_type_counts))) {
    cat(sprintf("  %-25s : %4d (%5.1f%%)\n",
                as.character(death_type_counts$death_type[i]),
                death_type_counts$n[i], death_type_counts$pct[i]))
  }
}

cat("\nDone.\n")
