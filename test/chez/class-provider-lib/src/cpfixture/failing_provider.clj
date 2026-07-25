(ns cpfixture.failing-provider
  (:require [cpfixture.state :as state]))

(state/note-load! :failing)

;; This registration must never become visible: the provider attempt fails
;; after staging it. Concurrent callers must share this same failed attempt
;; rather than evaluating the namespace a second time.
(__register-class-statics!
 "fixture.PartialRegistration"
 {"VALUE" :must-not-leak})

(Thread/sleep 200)

(throw (ex-info "intentional concurrent provider failure"
                {:type :fixture/provider-failure}))
