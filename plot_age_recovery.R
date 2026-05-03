#!/usr/bin/env Rscript
# plot_age_recovery.R
# ---------------------------------------------------------------
# Visualises, year by year, the rate of age recovery from VAERS
# reports that were originally missing an age field.
#
# Inputs:
#   - data_archive.json  (full archive, keyed by vaers_id)
#   - age_from_text_ollama.csv  (layer-1 output: vaers_id;age;status;evidence)
#
# Output:
#   - plots/age_recovery_by_year.png
# ---------------------------------------------------------------

library(tidyverse)
library(jsonlite)
library(showtext)
library(scales)

# ---- Fonts ----
font_add_google("Open Sans", "opensans")
showtext_auto()

# ---- Paths (adjust as needed) ----
archive_path   <- "data_archive.json"
ages_csv_path  <- "age_from_text_ollama.csv"
output_dir     <- "plots"
if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

# ---- 1. Load archive ----
cat("Loading archive...\n")
archive_raw <- fromJSON(archive_path)

# archive_raw is a named list; convert to a data.frame
archive_df <- bind_rows(
  lapply(names(archive_raw), function(id) {
    rec <- archive_raw[[id]]
    tibble(
      vaers_id       = as.integer(id),
      file_year      = as.integer(rec$file_year),
      age_group_name = rec$age_group_name %||% NA_character_,
      age_years      = as.numeric(rec$age_years %||% NA_real_)
    )
  })
)

# Flag: originally missing age
archive_df <- archive_df %>%
  mutate(age_missing = is.na(age_group_name) | age_group_name == "")

cat(sprintf("  Total reports         : %s\n", format(nrow(archive_df), big.mark = ",")))
cat(sprintf("  Missing age_group_name: %s\n", format(sum(archive_df$age_missing), big.mark = ",")))

# ---- 2. Load layer-1 results ----
ages_df <- read_delim(
  ages_csv_path,
  delim        = ";",
  col_types    = cols(
    vaers_id = col_integer(),
    age      = col_character(),   # may be "null"
    status   = col_character(),
    evidence = col_character()
  ),
  show_col_types = FALSE
)

ages_df <- ages_df %>%
  mutate(
    age_numeric = ifelse(age == "null" | is.na(age), NA_real_, as.numeric(age)),
    recovered   = status == "ok" & !is.na(age_numeric)
  )

cat(sprintf("  Layer-1 rows          : %s\n", format(nrow(ages_df), big.mark = ",")))
cat(sprintf("  Recovered (status=ok) : %s\n", format(sum(ages_df$recovered), big.mark = ",")))

# ---- 3. Merge & compute year-level stats ----
missing_reports <- archive_df %>%
  filter(age_missing) %>%
  select(vaers_id, file_year)

merged <- missing_reports %>%
  left_join(
    ages_df %>% select(vaers_id, status, recovered),
    by = "vaers_id"
  ) %>%
  mutate(
    # If the vaers_id wasn't processed at all (not in ages_df), mark as unprocessed
    status    = replace_na(status, "unprocessed"),
    recovered = replace_na(recovered, FALSE)
  )

year_stats <- merged %>%
  group_by(file_year) %>%
  summarise(
    n_missing     = n(),
    n_recovered   = sum(recovered),
    n_ambiguous   = sum(status == "ambiguous"),
    n_still_miss  = sum(status == "missing"),
    n_error       = sum(status == "error"),
    n_unprocessed = sum(status == "unprocessed"),
    pct_recovered = n_recovered / n_missing * 100,
    .groups = "drop"
  ) %>%
  arrange(file_year)

cat("\nYear-level summary:\n")
print(as.data.frame(year_stats), row.names = FALSE)

# ---- 4. Plot: stacked bar of recovery status + % recovery line ----

# Reshape for stacked bar
year_long <- year_stats %>%
  select(file_year, n_recovered, n_ambiguous, n_still_miss, n_error, n_unprocessed) %>%
  pivot_longer(
    cols      = -file_year,
    names_to  = "category",
    values_to = "count"
  ) %>%
  mutate(
    category = factor(category,
      levels = c("n_recovered", "n_ambiguous", "n_still_miss", "n_error", "n_unprocessed"),
      labels = c("Recovered (ok)", "Ambiguous", "Still missing", "Error", "Unprocessed")
    )
  )

# Colour palette
cat_colors <- c(
  "Recovered (ok)" = "#2E86AB",
  "Ambiguous"      = "#F6AE2D",
  "Still missing"  = "#E05263",
  "Error"          = "#999999",
  "Unprocessed"    = "#CCCCCC"
)

# Dual-axis: bar = counts, line = % recovered
max_count <- year_stats %>% pull(n_missing) %>% max()
scale_factor <- max_count / 100   # maps 0-100% to 0-max_count

p <- ggplot() +
  # Stacked bar
  geom_col(
    data    = year_long,
    aes(x = file_year, y = count, fill = category),
    width   = 0.7
  ) +
  # % recovery line (rescaled to bar axis)
  geom_line(
    data    = year_stats,
    aes(x = file_year, y = pct_recovered * scale_factor),
    colour  = "#1B4332",
    linewidth = 1.1
  ) +
  geom_point(
    data    = year_stats,
    aes(x = file_year, y = pct_recovered * scale_factor),
    colour  = "#1B4332",
    size    = 2.5
  ) +
  geom_text(
    data    = year_stats,
    aes(x = file_year, y = pct_recovered * scale_factor,
        label = sprintf("%.1f%%", pct_recovered)),
    vjust   = -1.2,
    size    = 3.2,
    colour  = "#1B4332",
    family  = "opensans"
  ) +
  scale_fill_manual(values = cat_colors, name = "Extraction status") +
  scale_y_continuous(
    name   = "Number of reports (missing age)",
    labels = comma,
    sec.axis = sec_axis(
      ~ . / scale_factor,
      name   = "% ages recovered",
      labels = function(x) paste0(x, "%")
    )
  ) +
  scale_x_continuous(breaks = year_stats$file_year) +
  labs(
    title    = "VAERS Age Recovery from Symptom Text (Ollama / gemma4:e4b)",
    subtitle = "Reports originally missing age_group_name — extraction status by filing year",
    x        = "VAERS file year",
    caption  = paste0(
      "Total missing-age reports: ", format(sum(year_stats$n_missing), big.mark = ","),
      " | Recovered: ", format(sum(year_stats$n_recovered), big.mark = ","),
      " (", sprintf("%.1f%%", sum(year_stats$n_recovered) / sum(year_stats$n_missing) * 100), ")"
    )
  ) +
  theme_minimal(base_family = "opensans", base_size = 13) +
  theme(
    plot.title       = element_text(face = "bold", size = 15),
    plot.subtitle    = element_text(colour = "grey40", size = 11),
    plot.caption     = element_text(colour = "grey50", size = 9, hjust = 0),
    axis.title.y.right = element_text(colour = "#1B4332"),
    axis.text.y.right  = element_text(colour = "#1B4332"),
    legend.position  = "bottom",
    panel.grid.minor = element_blank()
  )

out_file <- file.path(output_dir, "age_recovery_by_year.png")
ggsave(out_file, p, width = 12, height = 6.5, dpi = 300)
cat(sprintf("\nSaved: %s\n", out_file))
