get_inst_admins <- function(language, form, exclude_longitudinal = TRUE,
                            exclude_multilingual = TRUE, db_args = NULL) {
  message(glue("Getting administrations for {language} {form}..."))

  admins <- get_administration_data(language = language,
                                    form = form,
                                    include_language_exposure = TRUE,
                                    db_args = db_args)

  if (exclude_longitudinal) {
    # take earliest administration for any child with multiple administrations
    admins <- admins |>
      group_by(dataset_origin_name, child_id) |>
      slice_min(age, with_ties = FALSE) |>
      ungroup()
  }

  if (exclude_multilingual) {
    # exclude admins which have >=10% exposure to another language
    admins <- admins |>
      mutate(is_multilingual = sapply(language_exposures, \(exp) {
        if (is.null(exp)) return(FALSE)
        if (all(is.na(exp$exposure_proportion))) return(sum(is.na(exp$language)) > 1)
        max(exp$exposure_proportion, na.rm = TRUE) <= 90
      })) |>
      filter(!is_multilingual)
  }

  admins |> select(language, form, form_type, age, data_id)
}

get_inst_words <- function(language, form, db_args = NULL) {
  message(glue("Getting words for {language} {form}..."))
  items <- get_item_data(language = language,
                form = form,
                db_args = db_args) |>
    filter(item_kind == "word") |>
    # # split predicates into adjectives and verbs
    # # REVERTED: Chinese adjectives function like stative verbs, so this division is not cross-linguistically robust
    # mutate(lexical_category = case_when(
    #   str_detect(category, "descriptive_words") ~ "adjectives", # also catches Russian adverbs
    #   category == "action_words" ~ "verbs",
    #   .default = lexical_category
    # )) |>
    select(language, form, item_kind, lexical_category, category,
           uni_lemma, item_definition, item_id)

  # temporary, fix Mandarin (Beijing) WS issue
  if (language == "Mandarin (Beijing)" && form == "WS") {
    items$item_definition[534:537] <- c("球", "书", "小娃娃", "笔")
  }

  # temporary, to rescue failed form definition linking pre-cogsci
  if (nrow(items) == 0) {
    form_path <- here("resources", "temp_wb", glue("[{str_replace_all(language, '[ )(]', '')}_{form}].csv"))
    if (file.exists(form_path)) {
      items <- read_csv(form_path) |>
        filter(type == "word") |>
        mutate(language = language,
               form = form,
               form_type = str_sub(form, 1, 2),
               complexity_category = NA,
               lexical_category = case_when(
                 category %in% c("vehicles", "animals", "body_parts",
                                 "clothing", "toys", "food_drink",
                                 "household", "furniture_rooms", "outside") ~ "nouns",
                 category %in% c("action_words", "descriptive_words") ~ "predicates",
                 category %in% c("pronouns", "quantifiers", "verb_endings",
                                 "locations", "question_words", "quantifiers",
                                 "helping_verbs", "connecting_words", "negation_words") ~ "function_words",
                 category %in% c("sounds", "places", "people", "games_routines", "time_words") ~ "other",
                 .default = NA
               )) |>
        select(item_id = itemID,
               language, form, form_type,
               item_kind = type,
               category,
               item_definition = definition,
               english_gloss = gloss,
               uni_lemma,
               lexical_category,
               complexity_category)
    }
  }
  items
}

get_inst_data <- function(language, form, admins, items, db_args = NULL) {
  message(glue("Getting data for {language} {form}..."))

  # temp solution:
  form_type = admins |> pull(form_type) |> unique() |> na.omit()
  if (length(form_type) != 1) {
    message(glue("form_type failure for {language} {form}"))
    form_type <- "WS" # default to WS if fail
  }
  items <- items |> mutate(form_type = form_type)

  inst_data <- get_instrument_data(language = language,
                                   form = form,
                                   items = items$item_id,
                                   administration_info = admins,
                                   item_info = items,
                                   db_args = db_args) |>
    select(-value) |>
    pivot_longer(names_to = "measure", values_to = "value",
                 cols = c(produces, understands)) |>
    filter(measure == "produces" | form_type == "WG")

  inst_data |>
    filter(!is.na(uni_lemma))
}

collapse_inst_data <- function(inst_data) {
  message(glue("Collapsing data for {unique(inst_data$language)} {unique(inst_data$form)}..."))

  inst_uni_lemmas <- inst_data |>
    distinct(measure, uni_lemma, lexical_category, category, item_id, item_definition) |>
    group_by(uni_lemma) |>
    nest(items = c(lexical_category, category, item_id, item_definition))

  inst_data |>
    filter(!is.na(value)) |>
    # for each child and uni_lemma, collapse across items
    group_by(language, form, measure, uni_lemma, age, data_id) |>
    summarise(uni_value = any(value)) |>
    # for each age and uni_lemma, collapse across children
    group_by(language, form, measure, uni_lemma, age) |>
    summarise(num_true = sum(uni_value), total = n()) |>
    ungroup() |>
    left_join(inst_uni_lemmas, by = c("measure", "uni_lemma"))
}

combine_form_data <- function(inst_summaries) {
  inst_combined <- bind_rows(inst_summaries)
  inst_combined |>
    unnest(items) |>
    nest(items = -c(language, measure, uni_lemma, age, num_true, total)) |>
    group_by(language, measure, uni_lemma, age) |>
    summarise(num_true = sum(num_true), total = sum(total),
              items = list(bind_rows(items))) |>
    ungroup()
}

create_inst_data <- function(language, form, db_args = NULL) {
  inst_admins <- get_inst_admins(language, form, db_args = db_args)
  inst_words <- get_inst_words(language, form, db_args = db_args)
  get_inst_data(language, form, inst_admins, inst_words, db_args = db_args)
}

create_wb_data <- function(language, write = TRUE, db_args = NULL) {
  lang <- language # for filter name scope issues
  insts <- get_instruments(db_args = db_args)
  forms <- insts |>
    filter(language == lang,
           form != "WSOther") |> # hotfix for Arabic (Saudi)
    pull(form)
  if (length(forms) == 0) {
    message(glue("\tNo instruments found for language {lang}, skipping."))
    return()
  }

  lang_datas <- map(forms, partial(create_inst_data,
                                   language = language,
                                   db_args = db_args))
  lang_summaries <- map(lang_datas, collapse_inst_data)
  lang_summary <- combine_form_data(lang_summaries)

  if (write) {
    norm_lang <- normalize_language(language)
    saveRDS(lang_summary, file = here(wb_path, glue("{norm_lang}.rds")))
  }
  return(lang_summary)
}

load_wb_data <- function(languages, cache = TRUE, db_args = NULL) {
  wb_data <- map_df(languages, function(lang) {
    norm_lang <- normalize_language(lang)
    lang_file <- here(wb_path, glue("{norm_lang}.rds"))
    if (file.exists(lang_file)) {
      message(glue("Loading cached Wordbank data for {lang}..."))
      lang_data <- readRDS(lang_file)
    } else {
      if (cache) {
        message(glue("No cached Wordbank data for {lang}, getting and caching data."))
        lang_data <- create_wb_data(lang, db_args = db_args)
      } else {
        message(glue("No cached Wordbank data for {lang}, skipping."))
        lang_data <- tibble()
      }
    }
    return(lang_data)
  })
  return(wb_data)
}

extract_uni_lemmas <- function(lang, wb_data) {
  uni_lemmas <- wb_data |>
    filter(language == lang)|>
    filter(!is.na(uni_lemma)) |>
    distinct(language, uni_lemma, items) |>
    unnest(items) |>
    select(-c(form,item_id)) |>
    distinct() |>
    nest(items = -c(language, uni_lemma))
  uni_lemmas <- uni_lemmas |>
    unnest(items)
  uni_lemmas <- uni_lemmas[colSums(!is.na(uni_lemmas)) > 0]


  if("definition" %in% colnames(uni_lemmas)){
    uni_lemmas <- uni_lemmas |>
      rename(item_definition = definition)
  }
  uni_lemmas |>
    nest(items = -c(language, uni_lemma)) |>
    filter(uni_lemma != "NA")
}
