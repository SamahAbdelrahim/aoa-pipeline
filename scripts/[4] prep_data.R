# drop predictors with all NAs
drop_predictors <- function(predictors, data) {
  predictors |> discard(\(p) all(is.na(data[[p]])))
}

# transform any column that starts with "count" by smoothing (add 1),
# normalizing, and log transforming, then rename "count_x" to "freq_x"
transform_counts <- function(childes_metrics, smooth = TRUE, normalize = TRUE,
                             log_transform = TRUE) {
  trans_metrics <- childes_metrics # |> group_by(language)
  trans_funs <- c()
  if (smooth) trans_funs <- c(trans_funs, \(count) count + 1)
  if (normalize) trans_funs <- c(trans_funs, \(count) count / sum(count))
  if (log_transform) trans_funs <- c(trans_funs, \(count) log(count))

  for (fun in trans_funs) {
    trans_metrics <- trans_metrics |> mutate(across(starts_with("count"), fun))
  }
  trans_metrics |> ungroup() |>
    rename_with(\(col) str_replace(col, "count", "freq"), starts_with("count"))
}

residualize_col <- function(target_column, residualizing_column) {
  if (all(is.na(target_column))) return(NA)
  residuals <- lm(target_column ~ residualizing_column,
                  na.action = na.exclude) |>
    residuals()
  return(residuals)
}

# residualize all columns that starts with "freq_" from the column "freq"
residualize_freqs <- function(childes_metrics) {
  childes_metrics |>
    mutate(across(starts_with("freq_"), partial(residualize_col, freq)))
}


residualize_morph <- function(lang, childes_metrics) {
  residualized <- childes_metrics |>
    filter(language == lang,
           !is.na(form_entropy),
           !is.na(n_features)) |>
    mutate(n_features = residualize_col(n_features, form_entropy)) |>
    select(uni_lemma, n_features)

  childes_metrics |>
    filter(language == lang) |>
    select(-n_features) |>
    left_join(residualized, by = "uni_lemma")
}

## Imputation
fit_predictor <- function(pred, d, pred_sources) {
  xs <- pred_sources |> discard(\(s) pred %in% s) |> unlist()
  x_str <- xs |> paste(collapse = " + ")
  lm(as.formula(glue("{pred} ~ {x_str}")), data = d) |>
    broom::augment(newdata = d) |>
    select(uni_lemma, category, lexical_category, .fitted)
}

get_missing_data <- function(lang_data, predictors) {
  missing <- lang_data |>
    pivot_longer(cols = !!predictors, names_to = "predictor",
                 values_to = "value") |>
    mutate(missing = is.na(value) | is.nan(value)) |>
    select(-value) |>
    pivot_wider(names_from = predictor, values_from = missing)
  return(missing)
}

# start with predictors with the fewest NAs
# create a list that can be iterated over
get_predictor_order <- function(lang_data, predictors, max_steps) {
  predictor_order <- lang_data |>
    pivot_longer(cols = !!predictors, names_to = "predictor",
                 values_to = "value") |>
    group_by(predictor) |>
    summarise(num_na = sum(is.na(value))) |>
    filter(num_na != 0) |>
    arrange(num_na) |>
    pull(predictor)

  num_repeats <- max_steps %/% length(predictor_order) + 1
  return(rep(predictor_order, num_repeats)[0:max_steps])
}

get_imputation_seed <- function(lang_data, predictors) {
  imputation_data <- lang_data |>
    mutate(across(all_of(predictors),
                  ~ as.numeric(Hmisc::impute(.x, fun = "random"))))
  return(imputation_data)
}

# takes in a predictor from the list of predictors, pulls the imputation data at
# current status, returns a new imputation data
do_iterate_imputation <- function(pred_sources, imputation_data, missing) {
  prediction_list <- unlist(pred_sources)
  # iterates through the predictor list for that language
  for (pred in prediction_list) {

    imputation_fits <- fit_predictor(pred, imputation_data, pred_sources)
    imputation_data <- missing |>
      select(uni_lemma, lexical_category, category, !!pred) |>
      rename(missing = !!pred) |>
      right_join(imputation_data,
                 by = c("uni_lemma", "lexical_category", "category")) |>
      left_join(imputation_fits,
                by = c("uni_lemma", "lexical_category", "category")) |>
      # if the value is missing, replace it with the new value
      mutate(across(all_of(pred), ~ ifelse(is.na(missing), .fitted, .x))) |>
      select(-.fitted, -missing)
  }
  return(imputation_data)
}

do_lang_imputation <- function(lang, data, pred_sources, max_steps) {
  pred_sources <- lapply(pred_sources, \(x) drop_predictors(x, data))
  # if all the predictors are from one source, fix the pred_sources
  if (length(pred_sources) == 1) pred_sources <- unlist(pred_sources)
  data <- data |> distinct()
  predictors <- unlist(pred_sources)

  print(glue("Imputing {lang} with {max_steps} steps..."))
  predictor_list <- get_predictor_order(data, predictors, max_steps)
  missing_data <- get_missing_data(data, predictors)
  imputed_data <- get_imputation_seed(data, predictors)
  imputed_data <- do_iterate_imputation(pred_sources, imputed_data,
                                        missing_data)
  scaled_data <- do_scaling(imputed_data, predictors)
  return(scaled_data)
}

do_full_imputation <- function(model_data, predictor_sources, max_steps) {
  # restrict to the sources in pred_sources
  # catch cases where a predictor in the predictor set isn't in the data
  nested_data <- model_data |>
    select(language, uni_lemma, lexical_category, category,
           all_of(!!unlist(predictor_sources))) |>
    distinct() |>
    group_by(language) |>
    nest()

  imputed_data <- nested_data |>
    mutate(imputed = purrr::map2(language, data, function(lang, dat) {
      do_lang_imputation(lang, dat, predictor_sources, max_steps)
    }))

  imputed_data <- imputed_data |>
    ungroup() |>
    select(language, imputed) |>
    unnest(imputed) |>
    distinct()

  return(imputed_data)
}


# scaling predictors
do_scaling <- function(model_data, predictors) {
  model_data |>
    #group_by(language) |>
    mutate(across(all_of(predictors), \(x) as.numeric(scale(x))))
}


prep_lexcat <- function(predictor_data, uni_lemmas, ref_cat) {
  uni_lemmas_items <- uni_lemmas |>
    unnest(items)

  # ad-hoc lexical categories for English (British)
  if ("English (British)" %in% uni_lemmas$language) {
    en_gb_cats <- read_csv(here("data", "predictors", "english_british_categories.csv"))
    uni_lemmas_items <- uni_lemmas_items |>
      left_join(en_gb_cats |>
                  select(language, item_definition, lexical_category) |>
                  distinct(),
                by = c("language", "item_definition")) |>
      mutate(lexical_category = coalesce(lexical_category.y, lexical_category.x),
             lexical_category = ifelse(lexical_category %in% c("verbs", "adjectives"),
                                       "predicates", lexical_category)) |>
      select(language, uni_lemma, lexical_category, category, item_definition)
  }

  lexical_categories <- uni_lemmas_items |>
    distinct() |>
    filter(!lexical_category == "other") # loss of 407 items

  # uni_lemmas with items in multiple categories are discarded
  lc_count <- lexical_categories |>
    group_by(language, uni_lemma) |>
    summarise(n_lexcat = n_distinct(lexical_category)) |>
    filter(n_lexcat == 1) # loss of 331 items

  lexical_categories <- lexical_categories |>
    left_join(lc_count, by = c("language", "uni_lemma")) |>
    filter(!is.na(n_lexcat)) |>
    select(-n_lexcat) |>
    mutate(lexical_category = lexical_category |> as_factor() |>
             fct_relevel("nouns", "predicates", "function_words") |>
             fct_relevel(ref_cat, after = Inf) |>
             `contrasts<-`(value = contr.sum))

  predictor_data |>
    left_join(lexical_categories) |>
    filter(!is.na(uni_lemma))  |>
    filter(!is.na(lexical_category)) |>
    distinct()
}
