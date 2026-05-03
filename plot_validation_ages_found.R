#!/usr/bin/env Rscript
# plot_validation_ages_found.R
# ---------------------------------------------------------------
# Cross-validation figures for the "found" age subset only
# (LLM status = ok, i.e. the LLM confidently returned an age).
#
# Focus: how reliable is the LLM when it says it found an age?
#
# Figures produced (plots/):
#   1. validation_ages_found_summary.png — combined 4-panel figure
#
# Inputs:
#   - age_from_text_ollama.csv
#   - age_reviews.json
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
ages_csv_path <- "age_from_text_ollama.csv"
reviews_path  <- "age_reviews.json"
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
  "Rejected"  = "#E63946"
)

# ---- Load & merge ----
ages_df <- read_delim(ages_csv_path, delim = ";",
                      col_types = cols(.default = col_character())) %>%
  mutate(
    vaers_id    = as.character(vaers_id),
    age_numeric = ifelse(age == "null" | is.na(age), NA_real_, as.numeric(age)),
    status      = as.character(status)
  ) %>%
  filter(status == "ok")   # <--- only "found" ages

reviews_raw <- fromJSON(reviews_path)
reviews_df  <- bind_rows(
  lapply(names(reviews_raw), function(vid) {
    r <- reviews_raw[[vid]]
    tibble(
      vaers_id      = vid,
      decision      = r$decision %||% NA_character_,
      corrected_age = as.numeric(r$corrected_age %||% NA_real_)
    )
  })
)

archive_raw <- fromJSON(archive_path)
year_df     <- bind_rows(
  lapply(names(archive_raw), function(id) {
    tibble(vaers_id = id, file_year = as.integer(archive_raw[[id]]$file_year))
  })
)

merged <- ages_df %>%
  inner_join(reviews_df, by = "vaers_id") %>%    # only reviewed records
  left_join(year_df,     by = "vaers_id") %>%
  mutate(
    decision = case_when(
      decision == "validated" ~ "Validated",
      decision == "corrected" ~ "Corrected",
      decision == "rejected"  ~ "Rejected",
      TRUE                    ~ decision
    ),
    decision = factor(decision, levels = c("Validated", "Corrected", "Rejected"))
  )

n_found_total    <- nrow(ages_df)
n_found_reviewed <- nrow(merged)
cat(sprintf("Found (status=ok) : %d\n", n_found_total))
cat(sprintf("Reviewed          : %d (%.1f%%)\n",
            n_found_reviewed, n_found_reviewed / n_found_total * 100))

# ================================================================
# PANEL A — Overall decision breakdown (donut / bar)
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
    title    = "A — Overall decision (ages found)",
    subtitle = sprintf("n = %s reviewed", format(n_found_reviewed, big.mark = ",")),
    x        = NULL,
    y        = "Reports"
  ) +
  theme_paper()

# ================================================================
# PANEL B — Agreement rate by filing year
# ================================================================

year_agree <- merged %>%
  filter(!is.na(file_year)) %>%
  group_by(file_year) %>%
  summarise(
    n       = n(),
    n_valid = sum(decision == "Validated"),
    pct     = n_valid / n * 100,
    .groups = "drop"
  )

pB <- ggplot(year_agree, aes(x = file_year)) +
  geom_col(aes(y = pct), fill = "#2D6A4F", width = 0.6) +
  geom_text(
    aes(y = pct, label = sprintf("%.0f%%\n(n=%d)", pct, n)),
    vjust = -0.2, size = 2.6, family = "opensans", lineheight = 0.85, colour = "#2D6A4F"
  ) +
  scale_y_continuous(limits = c(0, 108), labels = function(x) paste0(x, "%")) +
  scale_x_continuous(breaks = year_agree$file_year) +
  labs(
    title    = "B — Agreement by filing year",
    subtitle = "% of found ages validated by reviewer",
    x        = "VAERS file year",
    y        = "Agreement (%)"
  ) +
  theme_paper() +
  theme(axis.text.x = element_text(angle = 45, hjust = 1))

# ================================================================
# PANEL C — Agreement by age bracket
# ================================================================

merged_brackets <- merged %>%
  filter(!is.na(age_numeric)) %>%
  mutate(
    age_bracket = cut(
      age_numeric,
      breaks = c(-Inf, 1, 5, 12, 18, 40, 65, Inf),
      labels = c("<1", "1–4", "5–11", "12–17", "18–39", "40–64", "65+"),
      right  = FALSE
    )
  )

bracket_agree <- merged_brackets %>%
  group_by(age_bracket) %>%
  summarise(
    n       = n(),
    n_valid = sum(decision == "Validated"),
    pct     = n_valid / n * 100,
    .groups = "drop"
  )

pC <- ggplot(bracket_agree, aes(x = age_bracket, y = pct)) +
  geom_col(fill = "#457B9D", width = 0.55) +
  geom_text(
    aes(label = sprintf("%.0f%%\n(n=%d)", pct, n)),
    vjust = -0.2, size = 2.8, family = "opensans", lineheight = 0.85
  ) +
  scale_y_continuous(limits = c(0, 108), labels = function(x) paste0(x, "%")) +
  labs(
    title    = "C — Agreement by age bracket",
    subtitle = "LLM-extracted age grouped into standard brackets",
    x        = "Age bracket (years)",
    y        = "Agreement (%)"
  ) +
  theme_paper()

# ================================================================
# PANEL D — Scatter: LLM age vs. corrected age (when corrected)
# ================================================================

corrections <- merged %>%
  filter(decision == "Corrected", !is.na(corrected_age), !is.na(age_numeric))

if (nrow(corrections) >= 3) {
  pD <- ggplot(corrections, aes(x = age_numeric, y = corrected_age)) +
    geom_abline(slope = 1, intercept = 0, linetype = "dashed", colour = "grey60") +
    geom_point(colour = "#E63946", alpha = 0.6, size = 1.8) +
    coord_equal(xlim = c(0, max(c(corrections$age_numeric, corrections$corrected_age), na.rm = TRUE) + 2),
                ylim = c(0, max(c(corrections$age_numeric, corrections$corrected_age), na.rm = TRUE) + 2)) +
    labs(
      title    = "D — LLM age vs. human-corrected age",
      subtitle = sprintf("n = %d corrections; points on dashed line = perfect agreement", nrow(corrections)),
      x        = "LLM-extracted age (years)",
      y        = "Human-corrected age (years)"
    ) +
    theme_paper()
} else {
  pD <- ggplot() +
    annotate("text", x = 0.5, y = 0.5,
             label = sprintf("Too few corrections (n=%d)\nto plot scatter", nrow(corrections)),
             size = 4, family = "opensans", colour = "grey50") +
    labs(title = "D — LLM age vs. corrected age") +
    theme_void(base_family = "opensans") +
    theme(plot.title = element_text(face = "bold", size = 13))
}

# ================================================================
# COMBINED
# ================================================================

combined <- (pA | pB) / (pC | pD) +
  plot_annotation(
    title    = "Ages Found (status=ok) — LLM vs. Human Cross-Validation",
    subtitle = sprintf("Reviewed: %s / %s found ages (%.1f%%).  Overall agreement: %.1f%%",
                       format(n_found_reviewed, big.mark = ","),
                       format(n_found_total, big.mark = ","),
                       n_found_reviewed / n_found_total * 100,
                       sum(merged$decision == "Validated") / nrow(merged) * 100),
    caption  = "LLM: Ollama gemma4:e4b. Ages extracted from VAERS symptom narratives for reports missing the age field.",
    theme    = theme(
      plot.title    = element_text(face = "bold", size = 16, family = "opensans"),
      plot.subtitle = element_text(colour = "grey40", size = 11, family = "opensans"),
      plot.caption  = element_text(colour = "grey50", size = 9, family = "opensans", hjust = 0)
    )
  )

ggsave(file.path(output_dir, "validation_ages_found_summary.png"), combined,
       width = 14, height = 10, dpi = 300)
cat("Saved: plots/validation_ages_found_summary.png\n")

# ================================================================
# CONSOLE SUMMARY
# ================================================================

cat("\n======== Ages Found — Summary ========\n")
cat(sprintf("Total found (status=ok)     : %d\n", n_found_total))
cat(sprintf("Reviewed                    : %d (%.1f%%)\n", n_found_reviewed, n_found_reviewed / n_found_total * 100))
cat(sprintf("  Validated                 : %d (%.1f%%)\n",
            sum(merged$decision == "Validated"),
            sum(merged$decision == "Validated") / nrow(merged) * 100))
cat(sprintf("  Corrected                 : %d (%.1f%%)\n",
            sum(merged$decision == "Corrected"),
            sum(merged$decision == "Corrected") / nrow(merged) * 100))
cat(sprintf("  Rejected                  : %d (%.1f%%)\n",
            sum(merged$decision == "Rejected"),
            sum(merged$decision == "Rejected") / nrow(merged) * 100))

if (nrow(corrections) > 0) {
  cat(sprintf("\nCorrection stats (n=%d):\n", nrow(corrections)))
  cat(sprintf("  Median delta              : %.1f years\n", median(corrections$corrected_age - corrections$age_numeric)))
  cat(sprintf("  Mean absolute delta       : %.1f years\n", mean(abs(corrections$corrected_age - corrections$age_numeric))))
}

cat("\nDone.\n")
