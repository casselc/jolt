(ns cpfixture.standard-charsets-provider
  (:require [cpfixture.catalog :as catalog]))

(catalog/note-load! :standard-charsets)

(__register-class-statics!
 "java.nio.charset.StandardCharsets"
 {"US_ASCII" "US-ASCII"
  "UTF_8" "UTF-8"})
