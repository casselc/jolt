(ns checkpoint-ir-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is run-tests testing]]
            [jolt.backend-scheme :as backend]
            [jolt.checkpoints :as checkpoints]
            [jolt.ir :as ir]
            [jolt.passes.effects :as effects]
            [jolt.passes.types :as types]))

(def checkpoint-decl
  {:op :checkpoint-decl
   :id :test.poller/after-reserve-unlock
   :dispositions #{:continue :yield}})

(defn attempt [f]
  (try
    {:value (f)}
    (catch :default e {:error e})))

(defn summary [report fqn]
  (some #(when (= fqn (get-in % [:subject :fqn])) %) (:summaries report)))

(deftest public-macro-has-a-qualified-private-expansion
  (is (= '(jolt.checkpoints/__checkpoint
            :test.poller/after-reserve-unlock
            #{:continue})
         (macroexpand-1
           '(checkpoints/checkpoint!
              :test.poller/after-reserve-unlock
              #{:continue})))))

(deftest lowering-is-explicit-total-and-idempotent
  (let [plain (types/new-unit)
        controlled (types/new-unit)
        _ (checkpoints/configure-unit! controlled :controlled)
        tree (ir/do-node [checkpoint-decl] (ir/const :answer))
        plain-result (checkpoints/lower plain tree)
        controlled-result (checkpoints/lower controlled tree)]
    (is (= (ir/const :answer) plain-result))
    (is (= plain-result (checkpoints/lower plain plain-result)))
    (is (= :checkpoint (get-in controlled-result [:statements 0 :op])))
    (is (= (:dispositions checkpoint-decl)
           (get-in controlled-result [:statements 0 :dispositions])))
    (is (= controlled-result (checkpoints/lower controlled controlled-result)))
    (is (empty? (ir/tree-problems controlled-result))))
  (is (:error (attempt #(checkpoints/configure-unit! (types/new-unit) :surprise)))))

(deftest checkpoint-profile-freezes-at-first-lowering
  (let [unit (types/new-unit)
        _ (checkpoints/configure-unit! unit :controlled)
        controlled (checkpoints/lower unit checkpoint-decl)]
    (is (= :checkpoint (:op controlled)))
    (is (:error (attempt #(checkpoints/configure-unit! unit :plain))))
    (is (= :controlled (checkpoints/unit-profile unit)))
    ;; A controlled leaf crossing into a separate production unit is erased,
    ;; rather than inheriting its origin unit's profile.
    (is (= (ir/const nil)
           (checkpoints/lower (types/new-unit) controlled)))))

(deftest plain-emission-is-identical-to-the-source-without-a-checkpoint
  (let [unit (types/new-unit)
        without (ir/const :answer)
        with (ir/do-node [checkpoint-decl] without)
        lowered (checkpoints/lower unit with)]
    (backend/set-emit-unit! unit)
    (is (= without lowered))
    (is (= (backend/emit without) (backend/emit lowered)))
    (is (not (str/includes? (backend/emit lowered) "checkpoint")))))

(deftest backend-rejects-declarations-and-renders-controlled-structure
  (let [unit (types/new-unit)
        _ (checkpoints/configure-unit! unit :controlled)
        controlled (checkpoints/lower unit checkpoint-decl)]
    (backend/set-emit-unit! unit)
    (is (:error (attempt #(backend/emit checkpoint-decl))))
    (is (= "(jolt-checkpoint! \"test.poller/after-reserve-unlock\" '(continue yield))"
           (backend/emit controlled)))
    (is (= "(jolt-checkpoint-continue! \"test.poller/record-only\")"
           (backend/emit
            (assoc controlled
                   :id :test.poller/record-only
                   :dispositions #{:continue}))))))

(deftest controlled-emission-fails-closed-on-unsupported-targets
  (let [unit (types/new-unit)
        _ (checkpoints/configure-unit! unit :controlled)
        controlled (checkpoints/lower unit checkpoint-decl)]
    (backend/set-emit-unit! unit)
    (backend/set-target! :gambit)
    (try
      (let [failure (:error (attempt #(backend/emit controlled)))]
        (is failure)
        (is (= :gambit (:target (ex-data failure))))
        (is (= (:id checkpoint-decl) (:id (ex-data failure)))))
      (finally
        (backend/set-target! :chez)))
    ;; The failed target attempt must not poison later Chez emission.
    (is (= "(jolt-checkpoint! \"test.poller/after-reserve-unlock\" '(continue yield))"
           (backend/emit controlled)))))

(deftest effect-evidence-distinguishes-erased-and-controlled-profiles
  (let [unit (types/new-unit)
        plain-node (ir/def-node "app" "plain" checkpoint-decl)
        controlled-node
        (ir/def-node "app" "controlled"
                     (assoc checkpoint-decl :op :checkpoint))]
    (effects/record-phase! unit :plain plain-node)
    (effects/record-phase! unit :woven controlled-node)
    (effects/record-phase! unit :optimized controlled-node)
    (let [plain (summary (effects/finalize-phase! unit :plain) "app/plain")
          woven (summary (effects/finalize-phase! unit :woven) "app/controlled")]
      (is (empty? (get-in plain [:direct :effects])))
      (is (empty? (get-in plain [:direct :checkpoint-sites])))
      (is (= #{:jolt.effect/checkpoint :jolt.effect/schedule}
             (get-in woven [:direct :effects])))
      (is (= #{{:id :test.poller/after-reserve-unlock
                :dispositions #{:continue :yield}}}
             (get-in woven [:direct :checkpoint-sites]))))
    (is (empty? (effects/verify-transition! unit :woven :optimized)))))

(deftest optimization-cannot-drop-or-strengthen-a-checkpoint-site
  (let [unit (types/new-unit)
        before (ir/def-node "app" "run" (assoc checkpoint-decl :op :checkpoint))
        dropped (ir/def-node "app" "run" (ir/const nil))
        strengthened
        (ir/def-node "app" "run"
                     {:op :checkpoint :id (:id checkpoint-decl)
                      :dispositions #{:continue :yield :barrier}})]
    ;; bad: dropping the node loses its site evidence.
    (effects/record-phase! unit :woven before)
    (effects/record-phase! unit :optimized dropped)
    (is (some #(= :jolt.rule/checkpoint-sites-preserved (:rule %))
              (effects/verify-transition! unit :woven :optimized)))
    ;; bad: retaining the ID while silently widening dispositions is also a
    ;; changed site, not a controller decision that may strengthen effects.
    (let [unit (types/new-unit)]
      (effects/record-phase! unit :woven before)
      (effects/record-phase! unit :optimized strengthened)
      (is (some #(= :jolt.rule/checkpoint-sites-preserved (:rule %))
                (effects/verify-transition! unit :woven :optimized))))
    ;; fixed: byte-for-byte disposition preservation passes the transition.
    (let [unit (types/new-unit)]
      (effects/record-phase! unit :woven before)
      (effects/record-phase! unit :optimized before)
      (is (empty? (effects/verify-transition! unit :woven :optimized))))))

(let [{:keys [fail error]} (run-tests)]
  (when (pos? (+ fail error)) (System/exit 1)))
