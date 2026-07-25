(ns cpfixture.standard-charsets-provider
  (:require [cpfixture.state :as state]))

(state/note-load! :standard-charsets)

(__register-class-statics!
 "java.nio.charset.StandardCharsets"
 {"US_ASCII" "US-ASCII"
  "UTF_8" "UTF-8"})
