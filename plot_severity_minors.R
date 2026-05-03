#!/usr/bin/env Rscript
# plot_severity_minors.R
# ---------------------------------------------------------------
# Visualises, year by year, the severity of adverse events among
# minors (age <= 18) whose age was recovered via LLM extraction.
#
# "Severe" = life_threatening == "yes" OR subject_died == "yes"
#            OR disability == "yes"
#
# Inputs:
#   - data_archive.json          (full archive)
#   - age_from_text_ollama.csv   (layer-1: recovered ages)
#   - outcomes_minors_ollama.csv (layer-2: severity classification)
#
# Outputs:
#   - plots/severity_minors_by_year.png
#   - plots/severity_minors_detail_by_year.png
#   - plots/severity_minors_age_distribution.png
# ---------------------------------------------------------------

library(tidyverse)
library(jsonlite)
library(showtext)
library(scales)
library(patchwork)

# ---- Fonts ----
font_add_google("Open Sans", "opensans")
showtext_auto()

# ---- Paths ----
archive_path    <- "data_archive.json"
ages_csv_path   <- "age_from_text_ollama.csv"
outcomes_path   <- "outcomes_minors_ollama.csv"
output_dir      <- "plots"
if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

# ---- 1. Load archive (for file_year) ----
cat("Loading archive...\n")
archive_raw <- fromJSON(archive_path)
archive_df  <- bind_rows(
  lapply(names(archive_raw), function(id) {
    rec <- archive_raw[[id]]
    tibble(
      vaers_id  = as.integer(id),
      file_year = as.integer(rec$file_year)
    )
  })
)

# ---- 2. Load outcomes ----
outcomes_df <- read_delim(
  outcomes_path,
  delim        = ";",
  col_types    = cols(
    vaers_id         = col_integer(),
    age              = col_character(),
    life_threatening = col_character(),
    subject_died     = col_character(),
    disability       = col_character(),
    status           = col_character(),
    evidence         = col_character()
  ),
  show_col_types = FALSE
)

# Parse age
outcomes_df <- outcomes_df %>%
  mutate(
    age_numeric = ifelse(age == "null" | is.na(age), NA_real_, as.numeric(age))
  )

# Keep only successfully classified rows
outcomes_ok <- outcomes_df %>%
  filter(status == "ok") %>%
  mutate(
    is_life_threatening = life_threatening == "yes",
    is_died             = subject_died == "yes",
    is_disability       = disability == "yes",
    is_severe           = is_life_threatening | is_died | is_disability
  )

cat(sprintf("  Outcomes rows (status=ok): %s\n", format(nrow(outcomes_ok), big.mark = ",")))

# ---- 3. Join file_year ----
outcomes_ok <- outcomes_ok %>%
  left_join(archive_df, by = "vaers_id")

if (any(is.na(outcomes_ok$file_year))) {
  n_na <- sum(is.na(outcomes_ok$file_year))
  warning(sprintf("%d outcomes could not be joined to file_year — dropping them.", n_na))
  outcomes_ok <- outcomes_ok %>% filter(!is.na(file_year))
}

# ---- 4. Also load the total minor reports (from layer-1 ages) for denominator ----
# We need: total reports for minors per year (including those not yet severity-classified)
ages_df <- read_delim(
  ages_csv_path,
  delim     = ";",
  col_types = cols(
    vaers_id = col_integer(),
    age      = col_character(),
    status   = col_character(),
    evidence = col_character()
  ),
  show_col_types = FALSE
) %>%
  mutate(
    age_numeric = ifelse(age == "null" | is.na(age), NA_real_, as.numeric(age))
  ) %>%
  filter(status == "ok", !is.na(age_numeric), age_numeric <= 18) %>%
  left_join(archive_df, by = "vaers_id")

total_minors_by_year <- ages_df %>%
  group_by(file_year) %>%
  summarise(n_total_minors = n(), .groups = "drop")

# ---- 5. Year-level severity stats ----
year_severity <- outcomes_ok %>%
  group_by(file_year) %>%
  summarise(
    n_classified       = n(),
    n_life_threatening = sum(is_life_threatening),
    n_died             = sum(is_died),
    n_disability       = sum(is_disability),
    n_severe           = sum(is_severe),
    n_non_severe       = n() - sum(is_severe),
    .groups = "drop"
  ) %>%
  left_join(total_minors_by_year, by = "file_year") %>%
  mutate(
    pct_severe         = n_severe / n_classified * 100,
    pct_died           = n_died / n_classified * 100,
    pct_life_threat    = n_life_threatening / n_classified * 100,
    pct_disability     = n_disability / n_classified * 100,
    # Coverage: what fraction of known minors have been severity-classified?
    pct_coverage       = ifelse(!is.na(n_total_minors) & n_total_minors > 0,
                                n_classified / n_total_minors * 100, NA_real_)
  ) %>%
  arrange(file_year)

cat("\nYear-level severity summary:\n")
print(as.data.frame(year_severity), row.names = FALSE)

# ============================================================
# PLOT 1: Severe vs non-severe (stacked bar) + % severe line
# ============================================================

year_sev_long <- year_severity %>%
  select(file_year, n_severe, n_non_severe) %>%
  pivot_longer(-file_year, names_to = "category", values_to = "count") %>%
  mutate(
    category = factor(category,
      levels = c("n_non_severe", "n_severe"),
      labels = c("Non-severe", "Severe (death / life-threatening / disability)")
    )
  )

max_count    <- year_severity %>% summarise(m = max(n_classified)) %>% pull(m)
scale_factor <- max_count / max(year_severity$pct_severe, na.rm = TRUE)

p1 <- ggplot() +
  geom_col(
    data  = year_sev_long,
    aes(x = file_year, y = count, fill = category),
    width = 0.7
  ) +
  geom_line(
    data      = year_severity,
    aes(x = file_year, y = pct_severe * scale_factor),
    colour    = "#9B2335",
    linewidth = 1.1
  ) +
  geom_point(
    data   = year_severity,
    aes(x = file_year, y = pct_severe * scale_factor),
    colour = "#9B2335", size = 2.5
  ) +
  geom_text(
    data   = year_severity,
    aes(x = file_year, y = pct_severe * scale_factor,
        label = sprintf("%.1f%%", pct_severe)),
    vjust  = -1.2, size = 3.2, colour = "#9B2335", family = "opensans"
  ) +
  scale_fill_manual(
    values = c("Non-severe" = "#A8DADC", "Severe (death / life-threatening / disability)" = "#E63946"),
    name   = NULL
  ) +
  scale_y_continuous(
    name   = "Classified reports (minors, age ≤ 18)",
    labels = comma,
    sec.axis = sec_axis(
      ~ . / scale_factor,
      name   = "% severe",
      labels = function(x) paste0(x, "%")
    )
  ) +
  scale_x_continuous(breaks = year_severity$file_year) +
  labs(
    title    = "Severity of Adverse Events — VAERS Minors (age ≤ 18)",
    subtitle = "Reports with age recovered from symptom text — LLM severity classification",
    x        = "VAERS file year",
    caption  = paste0(
      "Total classified: ", format(sum(year_severity$n_classified), big.mark = ","),
      " | Severe: ", format(sum(year_severity$n_severe), big.mark = ","),
      " | Deaths: ", format(sum(year_severity$n_died), big.mark = ",")
    )
  ) +
  theme_minimal(base_family = "opensans", base_size = 13) +
  theme(
    plot.title         = element_text(face = "bold", size = 15),
    plot.subtitle      = element_text(colour = "grey40", size = 11),
    plot.caption       = element_text(colour = "grey50", size = 9, hjust = 0),
    axis.title.y.right = element_text(colour = "#9B2335"),
    axis.text.y.right  = element_text(colour = "#9B2335"),
    legend.position    = "bottom",
    panel.grid.minor   = element_blank()
  )

ggsave(file.path(output_dir, "severity_minors_by_year.png"), p1,
       width = 12, height = 6.5, dpi = 300)
cat("Saved: plots/severity_minors_by_year.png\n")

# ============================================================
# PLOT 2: Detailed breakdown — deaths / life-threatening / disability
# ============================================================

year_detail <- year_severity %>%
  select(file_year, n_life_threatening, n_died, n_disability) %>%
  pivot_longer(-file_year, names_to = "outcome", values_to = "count") %>%
  mutate(
    outcome = factor(outcome,
      levels = c("n_died", "n_life_threatening", "n_disability"),
      labels = c("Death", "Life-threatening", "Disability")
    )
  )

p2 <- ggplot(year_detail, aes(x = file_year, y = count, fill = outcome)) +
  geom_col(position = "dodge", width = 0.7) +
  scale_fill_manual(
    values = c("Death" = "#1D3557", "Life-threatening" = "#E63946", "Disability" = "#F4A261"),
    name   = "Outcome"
  ) +
  geom_text(
    aes(label = count),
    position = position_dodge(width = 0.7),
    vjust    = -0.5,
    size     = 3,
    family   = "opensans"
  ) +
  scale_y_continuous(labels = comma, expand = expansion(mult = c(0, 0.15))) +
  scale_x_continuous(breaks = year_severity$file_year) +
  labs(
    title    = "Severe AE Breakdown — VAERS Minors (age ≤ 18)",
    subtitle = "Counts by outcome category and filing year",
    x        = "VAERS file year",
    y        = "Number of reports"
  ) +
  theme_minimal(base_family = "opensans", base_size = 13) +
  theme(
    plot.title       = element_text(face = "bold", size = 15),
    plot.subtitle    = element_text(colour = "grey40", size = 11),
    legend.position  = "bottom",
    panel.grid.minor = element_blank()
  )

ggsave(file.path(output_dir, "severity_minors_detail_by_year.png"), p2,
       width = 12, height = 6.5, dpi = 300)
cat("Saved: plots/severity_minors_detail_by_year.png\n")

# ============================================================
# PLOT 3: Age distribution of severe vs non-severe
# ============================================================

p3 <- ggplot(outcomes_ok %>% filter(!is.na(age_numeric)),
             aes(x = age_numeric, fill = is_severe)) +
  geom_histogram(
    binwidth = 1,
    position = "identity",
    alpha    = 0.65,
    colour   = "white",
    linewidth = 0.3
  ) +
  scale_fill_manual(
    values = c("FALSE" = "#A8DADC", "TRUE" = "#E63946"),
    labels = c("Non-severe", "Severe"),
    name   = NULL
  ) +
  scale_x_continuous(breaks = 0:18) +
  scale_y_continuous(labels = comma) +
  labs(
    title    = "Age Distribution of AE Reports — VAERS Minors",
    subtitle = "Severe = death, life-threatening, or permanent disability",
    x        = "Patient age (years)",
    y        = "Number of reports"
  ) +
  theme_minimal(base_family = "opensans", base_size = 13) +
  theme(
    plot.title       = element_text(face = "bold", size = 15),
    plot.subtitle    = element_text(colour = "grey40", size = 11),
    legend.position  = "bottom",
    panel.grid.minor = element_blank()
  )

ggsave(file.path(output_dir, "severity_minors_age_distribution.png"), p3,
       width = 10, height = 6, dpi = 300)
cat("Saved: plots/severity_minors_age_distribution.png\n")

# ============================================================
# PLOT 4: Coverage — % of known minors severity-classified
# ============================================================

if (any(!is.na(year_severity$pct_coverage))) {
  p4 <- ggplot(year_severity %>% filter(!is.na(pct_coverage)),
               aes(x = file_year, y = pct_coverage)) +
    geom_col(fill = "#457B9D", width = 0.6) +
    geom_text(
      aes(label = sprintf("%.0f%%", pct_coverage)),
      vjust  = -0.5, size = 3.5, family = "opensans"
    ) +
    scale_y_continuous(
      limits = c(0, 105),
      labels = function(x) paste0(x, "%")
    ) +
    scale_x_continuous(breaks = year_severity$file_year) +
    labs(
      title    = "Layer-2 Classification Coverage — Minors",
      subtitle = "% of LLM-identified minors that have been severity-classified",
      x        = "VAERS file year",
      y        = "Coverage (%)"
    ) +
    theme_minimal(base_family = "opensans", base_size = 13) +
    theme(
      plot.title       = element_text(face = "bold", size = 15),
      plot.subtitle    = element_text(colour = "grey40", size = 11),
      panel.grid.minor = element_blank()
    )

  ggsave(file.path(output_dir, "severity_minors_coverage.png"), p4,
         width = 10, height = 5.5, dpi = 300)
  cat("Saved: plots/severity_minors_coverage.png\n")
}

cat("\nDone.\n")
