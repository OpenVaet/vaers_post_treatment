#!/usr/bin/env Rscript
# plot_validation_ages_all.R
# ---------------------------------------------------------------
# Cross-validation figures for the full LLM age-extraction layer.
# Compares LLM output (age_from_text_ollama.csv) against human
# manual review (age_reviews.json).
#
# Figures produced (plots/):
#   1. validation_ages_all_by_status.png
#       Stacked bar: human decision breakdown per LLM status category
#   2. validation_ages_all_summary.png
#       Combined panel figure for the paper (A–D)
#
# Inputs:
#   - age_from_text_ollama.csv
#   - age_reviews.json
#   - data_archive.json  (for file_year)
# ---------------------------------------------------------------

library(tidyverse)
library(jsonlite)
library(showtext)
library(scales)
library(patchwork)

font_add_google("Open Sans", "opensans")
showtext_auto()

# ---- Paths ----
ages_csv_path    <- "age_from_text_ollama.csv"
reviews_path     <- "age_reviews.json"
archive_path     <- "data_archive.json"
output_dir       <- "plots"
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
      legend.title     = element_text(size = base_size - 1),
      strip.text       = element_text(face = "bold", size = base_size - 1)
    )
}

# ---- Colour palettes ----
decision_colors <- c(
  "Validated" = "#2D6A4F",
  "Corrected" = "#457B9D",
  "Rejected"  = "#E63946",
  "Pending"   = "#CCC"
)

status_colors <- c(
  "ok"        = "#2E86AB",
  "ambiguous" = "#F6AE2D",
  "missing"   = "#999999",
  "error"     = "#E05263"
)

# ---- 1. Load LLM output ----
ages_df <- read_delim(ages_csv_path, delim = ";",
                      col_types = cols(.default = col_character())) %>%
  mutate(
    vaers_id    = as.character(vaers_id),
    age_numeric = ifelse(age == "null" | is.na(age), NA_real_, as.numeric(age)),
    status      = factor(status, levels = c("ok", "ambiguous", "missing", "error"))
  )

# ---- 2. Load human reviews ----
reviews_raw <- fromJSON(reviews_path)
reviews_df  <- bind_rows(
  lapply(names(reviews_raw), function(vid) {
    r <- reviews_raw[[vid]]
    tibble(
      vaers_id      = vid,
      decision      = r$decision %||% NA_character_,
      corrected_age = as.numeric(r$corrected_age %||% NA_real_),
      reviewed_at   = r$reviewed_at %||% NA_character_
    )
  })
)

# ---- 3. Load archive for file_year ----
archive_raw <- fromJSON(archive_path)
year_df     <- bind_rows(
  lapply(names(archive_raw), function(id) {
    tibble(vaers_id = id, file_year = as.integer(archive_raw[[id]]$file_year))
  })
)

# ---- 4. Merge ----
merged <- ages_df %>%
  left_join(reviews_df, by = "vaers_id") %>%
  left_join(year_df,    by = "vaers_id") %>%
  mutate(
    decision = case_when(
      is.na(decision)       ~ "Pending",
      decision == "validated" ~ "Validated",
      decision == "corrected" ~ "Corrected",
      decision == "rejected"  ~ "Rejected",
      TRUE                    ~ decision
    ),
    decision = factor(decision, levels = c("Validated", "Corrected", "Rejected", "Pending"))
  )

reviewed <- merged %>% filter(decision != "Pending")
cat(sprintf("Total LLM rows   : %d\n", nrow(merged)))
cat(sprintf("Human-reviewed    : %d (%.1f%%)\n",
            nrow(reviewed), nrow(reviewed) / nrow(merged) * 100))

# ================================================================
# PANEL A — Human decision breakdown by LLM status
# ================================================================

status_decision <- reviewed %>%
  count(status, decision) %>%
  group_by(status) %>%
  mutate(pct = n / sum(n) * 100, total = sum(n)) %>%
  ungroup()

# Annotation: total reviewed per status
status_totals <- status_decision %>%
  distinct(status, total)

pA <- ggplot(status_decision, aes(x = status, y = n, fill = decision)) +
  geom_col(width = 0.65) +
  geom_text(
    data = status_totals,
    aes(x = status, y = total, label = paste0("n=", format(total, big.mark = ","))),
    inherit.aes = FALSE,
    vjust = -0.4, size = 3, family = "opensans", colour = "grey30"
  ) +
  scale_fill_manual(values = decision_colors, name = "Human decision") +
  scale_y_continuous(labels = comma, expand = expansion(mult = c(0, 0.12))) +
  labs(
    title = "A — Human review by LLM extraction status",
    x     = "LLM status",
    y     = "Reviewed reports"
  ) +
  theme_paper()

# ================================================================
# PANEL B — Agreement rate per LLM status (% validated)
# ================================================================

agreement_by_status <- reviewed %>%
  group_by(status) %>%
  summarise(
    n_total     = n(),
    n_validated = sum(decision == "Validated"),
    n_corrected = sum(decision == "Corrected"),
    n_rejected  = sum(decision == "Rejected"),
    pct_valid   = n_validated / n_total * 100,
    pct_correct = n_corrected / n_total * 100,
    pct_reject  = n_rejected  / n_total * 100,
    .groups     = "drop"
  )

pB <- ggplot(agreement_by_status, aes(x = status, y = pct_valid)) +
  geom_col(fill = "#2D6A4F", width = 0.55) +
  geom_text(
    aes(label = sprintf("%.1f%%\n(%d/%d)", pct_valid, n_validated, n_total)),
    vjust = -0.2, size = 3, family = "opensans", lineheight = 0.9
  ) +
  scale_y_continuous(
    limits = c(0, 105),
    labels = function(x) paste0(x, "%")
  ) +
  labs(
    title = "B — LLM–human agreement rate",
    subtitle = "% of reviewed reports where the human validated the LLM output as-is",
    x     = "LLM status",
    y     = "Agreement (%)"
  ) +
  theme_paper()

# ================================================================
# PANEL C — Agreement rate by filing year (status=ok only)
# ================================================================

year_agreement <- reviewed %>%
  filter(status == "ok") %>%
  group_by(file_year) %>%
  summarise(
    n_total     = n(),
    n_validated = sum(decision == "Validated"),
    pct_valid   = n_validated / n_total * 100,
    .groups     = "drop"
  ) %>%
  filter(!is.na(file_year))

pC <- ggplot(year_agreement, aes(x = file_year, y = pct_valid)) +
  geom_line(colour = "#2D6A4F", linewidth = 0.9) +
  geom_point(colour = "#2D6A4F", size = 2.2) +
  geom_text(
    aes(label = sprintf("%.0f%%", pct_valid)),
    vjust = -1, size = 2.8, family = "opensans", colour = "#2D6A4F"
  ) +
  geom_col(
    aes(y = n_total / max(n_total) * max(pct_valid)),
    fill = "#2D6A4F", alpha = 0.12, width = 0.6
  ) +
  scale_y_continuous(limits = c(0, 105), labels = function(x) paste0(x, "%")) +
  scale_x_continuous(breaks = year_agreement$file_year) +
  labs(
    title    = "C — Agreement by filing year (status=ok)",
    subtitle = "% validated among reviewed reports where LLM found an age",
    x        = "VAERS file year",
    y        = "Agreement (%)"
  ) +
  theme_paper() +
  theme(axis.text.x = element_text(angle = 45, hjust = 1))

# ================================================================
# PANEL D — Correction magnitude (when human corrected status=ok)
# ================================================================

corrections <- reviewed %>%
  filter(status == "ok", decision == "Corrected", !is.na(corrected_age), !is.na(age_numeric)) %>%
  mutate(delta = corrected_age - age_numeric)

if (nrow(corrections) >= 5) {
  pD <- ggplot(corrections, aes(x = delta)) +
    geom_histogram(binwidth = 1, fill = "#457B9D", colour = "white", linewidth = 0.3) +
    geom_vline(xintercept = 0, linetype = "dashed", colour = "grey40") +
    labs(
      title    = "D — Correction magnitude (status=ok, corrected)",
      subtitle = sprintf("n = %d corrections; median delta = %.1f years",
                         nrow(corrections), median(corrections$delta)),
      x        = "Corrected age − LLM age (years)",
      y        = "Count"
    ) +
    theme_paper()
} else {
  pD <- ggplot() +
    annotate("text", x = 0.5, y = 0.5,
             label = sprintf("Too few corrections (n=%d)\nto plot distribution", nrow(corrections)),
             size = 4, family = "opensans", colour = "grey50") +
    labs(title = "D — Correction magnitude") +
    theme_void(base_family = "opensans") +
    theme(plot.title = element_text(face = "bold", size = 13))
}

# ================================================================
# SAVE — individual
# ================================================================

ggsave(file.path(output_dir, "validation_ages_all_by_status.png"), pA,
       width = 9, height = 6, dpi = 300)
cat("Saved: plots/validation_ages_all_by_status.png\n")

# ================================================================
# SAVE — combined panel figure
# ================================================================

combined <- (pA | pB) / (pC | pD) +
  plot_annotation(
    title   = "Age Extraction — LLM vs. Human Review Cross-Validation",
    subtitle = sprintf("Reviewed: %s / %s reports (%.1f%%)",
                       format(nrow(reviewed), big.mark = ","),
                       format(nrow(merged), big.mark = ","),
                       nrow(reviewed) / nrow(merged) * 100),
    caption = "LLM: Ollama gemma4:e4b with structured JSON schema output. Human review via web interface.",
    theme   = theme(
      plot.title    = element_text(face = "bold", size = 16, family = "opensans"),
      plot.subtitle = element_text(colour = "grey40", size = 11, family = "opensans"),
      plot.caption  = element_text(colour = "grey50", size = 9, family = "opensans", hjust = 0)
    )
  )

ggsave(file.path(output_dir, "validation_ages_all_summary.png"), combined,
       width = 14, height = 10, dpi = 300)
cat("Saved: plots/validation_ages_all_summary.png\n")

# ================================================================
# SUMMARY TABLE — print to console
# ================================================================

cat("\n======== Summary Table ========\n")
cat(sprintf("%-12s  %6s  %6s  %6s  %6s  %8s\n",
            "LLM Status", "Total", "Valid", "Corr", "Reject", "Agree%"))
for (i in seq_len(nrow(agreement_by_status))) {
  r <- agreement_by_status[i, ]
  cat(sprintf("%-12s  %6d  %6d  %6d  %6d  %7.1f%%\n",
              as.character(r$status), r$n_total, r$n_validated,
              r$n_corrected, r$n_rejected, r$pct_valid))
}

overall_agree <- sum(agreement_by_status$n_validated) / sum(agreement_by_status$n_total) * 100
cat(sprintf("%-12s  %6d  %6d  %6d  %6d  %7.1f%%\n",
            "OVERALL",
            sum(agreement_by_status$n_total),
            sum(agreement_by_status$n_validated),
            sum(agreement_by_status$n_corrected),
            sum(agreement_by_status$n_rejected),
            overall_agree))

cat("\nDone.\n")
