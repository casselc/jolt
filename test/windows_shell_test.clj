(ns windows-shell-test
  (:require [clojure.string :as str]))

(def failures (atom []))

(defn check [label ok]
  (when-not ok
    (swap! failures conj label)))

;; This test runs in both source-mode Windows CI and the packaged x86-64 job.
;; Chez routes system and open-process-ports through cmd.exe there, so it
;; exercises the jolt.host boundary rather than merely proving that a
;; surrounding workflow shell can run POSIX commands.
(check "sh preserves zero exit" (= 0 (jolt.host/sh "exit 0")))
(check "sh preserves nonzero exit" (= 7 (jolt.host/sh "exit 7")))
(check "sh-out captures exact POSIX output"
       (= "JOLT SHELL % & | < > OK"
          (jolt.host/sh-out
            "printf '%s' 'JOLT SHELL % & | < > OK'")))
(check "sh-out runs compound POSIX syntax"
       (= "alpha beta"
          (str/trim
            (jolt.host/sh-out
              "x=alpha; printf '%s %s\\n' \"$x\" beta"))))

(if (seq @failures)
  (throw (ex-info "Windows shell boundary failed" {:failures @failures}))
  (println "WINDOWS-SHELL OK"))
