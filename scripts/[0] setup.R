Sys.setenv(DICPATH = here("resources", "dicts"))

wb_path <- here("data", "wordbank")
childes_path <- here("data", "childes")

get_lang_map <- function() {
  googlesheets4::gs4_deauth()
  lang_map <- googlesheets4::read_sheet("1YXanYR8RWbihg4DWSCvMCDbdLRiz1Z8n4afpcO26ZIA") |>
    select("iso_name", "wordbank", "childes",
           "snowball", "hunspell",
           "espeak", "espeak-ng",
           "unimorph", "unimorph segmentation", "unimorph derivation",
           "morph complexity", "udpipe")
  write_csv(lang_map, here("resources", "language_map.csv"))
  lang_map
}

lang_map <- read_csv(here("resources", "language_map.csv"))

convert_lang_childes <- function(lang) {
  lang_map |> filter(wordbank == lang) |> pull(childes)
}

convert_lang_stemmer <- function(lang, method = "snowball") {
  lang_map |> filter(wordbank == lang) |> pull(!!method)
}

convert_lang_espeak <- function(lang, method = "espeak-ng") {
  lang_map |> filter(wordbank == lang) |> pull(!!method)
}

convert_lang_unimorph <- function(lang) {
  lang_map |> filter(wordbank == lang) |> pull(unimorph)
}

convert_lang_morph_complexity <- function(lang) {
  lang_map |> filter(wordbank == lang) |> pull(`morph complexity`)
}

convert_lang_udpipe <- function(lang) {
  lang_map |> filter(wordbank == lang) |> pull(udpipe)
}

normalize_language <- function(language) {
  language |> str_replace(" ", "_") |> str_to_lower()
}
