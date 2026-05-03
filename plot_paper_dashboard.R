#!/usr/bin/env Rscript
# plot_paper_dashboard.R
# ---------------------------------------------------------------
# Produces a combined multi-panel figure suitable for the paper.
# Panel A: Age recovery rates by year
# Panel B: Severity rates by year (minors)
# Panel C: Age distribution of severe AEs
#
# Requires: data_archive.json, age_from_text_ollama.csv,
#           outcomes_minors_ollama.csv
# Output:   plots/figure1_pipeline_overview.png
# ---------------------------------------------------------------

library(tidyverse)
library(jsonlite)
library(showtext)
library(scales)
library(patchwork)

font_add_google("Open Sans", "opensans")
showtext_auto()

# ---- Paths ----
archive_path   <- "data_archive.json"
ages_csv_path  <- "age_from_text_ollama.csv"
outcomes_path  <- "outcomes_minors_ollama.csv"
output_dir     <- "plots"
if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

# ---- Load archive ----
archive_raw <- fromJSON(archive_path)
archive_df  <- bind_rows(
  lapply(names(archive_raw), function(id) {
    tibble(
      vaers_id       = as.integer(id),
      file_year      = as.integer(archive_raw[[id]]$file_year),
      age_group_name = archive_raw[[id]]$age_group_name %||% NA_character_
    )
  })
)

archive_df <- archive_df %>%
  mutate(age_missing = is.na(age_group_name) | age_group_name == "")

# ---- Load layer-1 ----
ages_df <- read_delim(ages_csv_path, delim = ";",
  col_types = cols(.default = col_character())) %>%
  mutate(
    vaers_id    = as.integer(vaers_id),
    age_numeric = ifelse(age == "null" | is.na(age), NA_real_, as.numeric(age)),
    recovered   = status == "ok" & !is.na(age_numeric)
  )

# ---- Load layer-2 ----
outcomes_df <- read_delim(outcomes_path, delim = ";",
  col_types = cols(.default = col_character())) %>%
  mutate(
    vaers_id    = as.integer(vaers_id),
    age_numeric = ifelse(age == "null" | is.na(age), NA_real_, as.numeric(age)),
    is_severe   = (life_threatening == "yes") | (subject_died == "yes") | (disability == "yes")
  ) %>%
  filter(status == "ok") %>%
  left_join(archive_df %>% select(vaers_id, file_year), by = "vaers_id")

# ---- Panel A: Age recovery ----
missing_reports <- archive_df %>% filter(age_missing) %>% select(vaers_id, file_year)
merged_ages <- missing_reports %>%
  left_join(ages_df %>% select(vaers_id, status, recovered), by = "vaers_id") %>%
  mutate(status = replace_na(status, "unprocessed"), recovered = replace_na(recovered, FALSE))

year_recovery <- merged_ages %>%
  group_by(file_year) %>%
  summarise(
    n_missing   = n(),
    n_recovered = sum(recovered),
    pct         = n_recovered / n_missing * 100,
    .groups     = "drop"
  )

pA <- ggplot(year_recovery, aes(x = file_year)) +
  geom_col(aes(y = n_missing), fill = "#CCCCCC", width = 0.6) +
  geom_col(aes(y = n_recovered), fill = "#2E86AB", width = 0.6) +
  geom_text(
    aes(y = n_missing, label = sprintf("%.0f%%", pct)),
    vjust = -0.4, size = 3, colour = "#2E86AB", family = "opensans"
  ) +
  scale_y_continuous(labels = comma) +
  scale_x_continuous(breaks = year_recovery$file_year) +
  labs(
    title = "A — Age Recovery from Symptom Text",
    x     = NULL,
    y     = "Reports missing age"
  ) +
  theme_minimal(base_family = "opensans", base_size = 11) +
  theme(
    plot.title       = element_text(face = "bold", size = 12),
    panel.grid.minor = element_blank(),
    axis.text.x      = element_text(angle = 45, hjust = 1)
  )

# ---- Panel B: Severity rate ----
year_sev <- outcomes_df %>%
  group_by(file_year) %>%
  summarise(
    n_total  = n(),
    n_severe = sum(is_severe),
    n_died   = sum(subject_died == "yes"),
    pct_sev  = n_severe / n_total * 100,
    pct_died = n_died / n_total * 100,
    .groups  = "drop"
  )

pB <- ggplot(year_sev, aes(x = file_year)) +
  geom_col(aes(y = n_total), fill = "#A8DADC", width = 0.6) +
  geom_col(aes(y = n_severe), fill = "#E63946", width = 0.6) +
  geom_text(
    aes(y = n_total, label = sprintf("%.1f%%", pct_sev)),
    vjust = -0.4, size = 3, colour = "#E63946", family = "opensans"
  ) +
  scale_y_continuous(labels = comma) +
  scale_x_continuous(breaks = year_sev$file_year) +
  labs(
    title = "B — Severe AEs Among Minors (≤ 18 yr)",
    x     = NULL,
    y     = "Classified reports"
  ) +
  theme_minimal(base_family = "opensans", base_size = 11) +
  theme(
    plot.title       = element_text(face = "bold", size = 12),
    panel.grid.minor = element_blank(),
    axis.text.x      = element_text(angle = 45, hjust = 1)
  )

# ---- Panel C: Age distribution ----
pC <- ggplot(outcomes_df %>% filter(!is.na(age_numeric)),
             aes(x = age_numeric, fill = is_severe)) +
  geom_histogram(binwidth = 1, position = "stack", colour = "white", linewidth = 0.3) +
  scale_fill_manual(
    values = c("FALSE" = "#A8DADC", "TRUE" = "#E63946"),
    labels = c("Non-severe", "Severe"),
    name   = NULL
  ) +
  scale_x_continuous(breaks = 0:18) +
  labs(
    title = "C — Age Distribution of Minor AE Reports",
    x     = "Patient age (years)",
    y     = "Reports"
  ) +
  theme_minimal(base_family = "opensans", base_size = 11) +
  theme(
    plot.title       = element_text(face = "bold", size = 12),
    legend.position  = "bottom",
    panel.grid.minor = element_blank()
  )

# ---- Combine ----
combined <- (pA | pB) / pC +
  plot_annotation(
    title   = "LLM-Assisted VAERS Analysis Pipeline — Summary",
    caption = "Age extraction and severity classification via Ollama (gemma4:e4b) on VAERS symptom narratives",
    theme   = theme(
      plot.title   = element_text(face = "bold", size = 16, family = "opensans"),
      plot.caption = element_text(colour = "grey50", size = 9, family = "opensans", hjust = 0)
    )
  )

ggsave(file.path(output_dir, "figure1_pipeline_overview.png"), combined,
       width = 14, height = 10, dpi = 300)
cat("Saved: plots/figure1_pipeline_overview.png\n")
