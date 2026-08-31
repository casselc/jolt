;; Executable RED acceptance histories for issue #21.
;;
;; Run with:
;;   tools/jolt-with-chez-10.4.1 bin/jolt run \
;;     test/chez/core-async-reducer-history-test.clj
;;
;; These tests deliberately describe the reserve -> compute outside the counted
;; channel lock -> validate/commit design.  The current runtime invokes xrf,
;; ex-handler, and completion code while holding that lock, so this file is red
;; until the P4 runtime slice lands.  Every parked callback has an explicit
;; release and every observation is bounded; a failure cannot strand the gate.
;;
;; This is deliberately not a parity claim against org.clojure/core.async
;; 1.9.865.  Public close progress while an admitted reducer invocation is
;; parked, and exactly-once completion after admitted work resolves, are Jolt's
;; intended correctness/conformance contract.  The reduced-tail rule exercised
;; below (acknowledge already-admitted B once, never step it) does match upstream.

(ns core-async-reducer-history-test
  (:require [clojure.core.async :as a]
            [clojure.test :refer [deftest is run-tests testing]]
            [jolt.scheme :as scheme]))

(def ^:private wait-ms 750)
(def ^:private drain-ms 2000)
(def ^:private park-failsafe-ms 10000)
(def ^:private timed-out ::timed-out)

;; jolt-locks-held is intentionally an internal runtime binding rather than a
;; public host proc.  Install one test-local zero-argument companion so ordinary
;; observations can use scheme/call rather than evaluating source each time.
(scheme/eval-string
 "(define (core-async-reducer-test-locks-held) (jolt-locks-held))")

(defn- locks-held []
  ;; Native companion observation.  This is intentionally the only non-public
  ;; channel seam in the test: callback scheduling and values use core.async's
  ;; public API, while the carrier's counted-lock register has no Clojure API.
  (scheme/call "core-async-reducer-test-locks-held"))

(defn- await [x]
  (deref x wait-ms timed-out))

(defn- record! [journal event]
  (swap! journal conj event)
  event)

(defn- callback-events [events]
  (mapv :event (filter #(= :xrf (:kind %)) events)))

(defn- callback-depths [events]
  (mapv :locks (filter #(= :xrf (:kind %)) events)))

(defn- fiber-flags-for [events event-names]
  (mapv :fiber?
        (filter #(and (= :xrf (:kind %))
                      (contains? event-names (:event %)))
                events)))

(defn- harness-events [events]
  (mapv :event (filter #(= :harness (:kind %)) events)))

(defn- ack-values [events id]
  (mapv :value
        (filter #(and (= :ack (:kind %)) (= id (:event %))) events)))

(defn- note-xrf! [journal event]
  (record! journal {:kind :xrf :event event :locks (locks-held)
                    :fiber? (jolt.host/fiber?)}))

(defn- take-with-timeout [ch]
  (let [[value port] (a/alts!! [ch (a/timeout drain-ms)] :priority true)]
    (if (= port ch) value timed-out)))

(defn- drain-n [ch n]
  (loop [left n values []]
    (if (zero? left)
      values
      (let [value (take-with-timeout ch)]
        (if (= timed-out value)
          (conj values value)
          (recur (dec left) (conj values value)))))))

;; This executable is its own process.  Pin its first and only fiber pool to one
;; carrier so sibling progress proves the parked callback yielded that carrier.
(alter-var-root #'a/*fiber-carrier-count* (constantly 1))

(deftest cap-one-park-close-publish-history
  (testing "parked A, pending B, close, ordered A1/A2/B/C publication, then EOF"
    (let [events (atom [])
          entered (promise)
          release (promise)
          sibling (promise)
          xf (fn [rf]
               (fn
                 ([] (rf))
                 ([result]
                  (note-xrf! events :complete-start)
                  (let [next (rf result :C)]
                    (note-xrf! events :complete-end)
                    next))
                 ([result input]
                  (note-xrf! events (if (= input :A) :A-start :B-start))
                  (when (= input :A)
                    (deliver entered true)
                    (when (= timed-out (deref release park-failsafe-ms timed-out))
                      (record! events {:kind :harness :event :A-release-timeout})))
                  (let [next (if (= input :A)
                               (rf (rf result :A1) :A2)
                               (rf result :B))]
                    (note-xrf! events (if (= input :A) :A-end :B-end))
                    next))))
          ch (a/chan 1 xf)
          ack-a-count (atom 0)
          ack-b-count (atom 0)
          ack-a (promise)
          ack-b (promise)
          put-a (future
                  (a/put! ch :A
                          #(do (swap! ack-a-count inc)
                               (record! events {:kind :ack :event :A :value %})
                               (deliver ack-a %))))]
      (is (= true (await entered)) "A entered its reducer step")
      (let [put-b (future
                    (a/put! ch :B
                            #(do (swap! ack-b-count inc)
                                 (record! events {:kind :ack :event :B :value %})
                                 (deliver ack-b %))))
            b-call-before-release (await put-b)
            close-call (future (a/close! ch) :closed)
            sibling-call (future
                           (record! events {:kind :sibling :event :progress})
                           (deliver sibling true)
                           true)
            close-before-release (await close-call)
            sibling-before-release (await sibling-call)
            pre-release-poll (future
                               (a/alts!! [ch] :default :not-ready :priority true))
            poll-before-release (await pre-release-poll)]
        ;; Always release A before asserting.  On the old runtime, put-b, close,
        ;; and the poll are blocked on the channel mutex that A's xrf still owns.
        (deliver release true)
        (let [put-a-result (await put-a)
              put-b-result (if (= timed-out b-call-before-release) (await put-b)
                               b-call-before-release)
              close-result (if (= timed-out close-before-release) (await close-call)
                               close-before-release)
              poll-result (if (= timed-out poll-before-release) (await pre-release-poll)
                              poll-before-release)
              poll-value (when (and (vector? poll-result)
                                    (= ch (second poll-result)))
                           (first poll-result))
              values (if (= timed-out poll-before-release)
                       (into [poll-value] (drain-n ch 4))
                       (drain-n ch 5))
              a-ack (await ack-a)
              b-ack (await ack-b)
              history @events]
          (is (= true b-call-before-release)
              "B registers while A is parked outside the channel lock")
          (is (= :closed close-before-release)
              "public close returns while reserved A is parked")
          (is (= true sibling-before-release)
              "an unrelated sibling progresses while A is parked")
          (is (= [:not-ready :default] poll-before-release)
              "close is not observable as EOF while reserved work remains")
          (is (= [true true :closed]
                 [put-a-result put-b-result close-result])
              "all bounded workers finish after A resumes")
          (is (= [true true] [a-ack b-ack])
              "both admitted inputs are acknowledged")
          (is (= [1 1] [@ack-a-count @ack-b-count])
              "A and B callbacks each run exactly once")
          (is (= [[true] [true]]
                 [(ack-values history :A) (ack-values history :B)])
              "the callback journal contains exactly one successful A and B event")
          (is (= [:A1 :A2 :B :C nil] values)
              "A's batch, pending B, and completion C publish before EOF")
          (is (= [:A-start :A-end :B-start :B-end
                  :complete-start :complete-end]
                 (callback-events history))
              "reducer and completion callbacks have one deterministic order")
          (let [depths (callback-depths history)]
            (is (= (mapv (fn [_] 0) depths) depths)
                "xrf step and completion callbacks run with zero counted locks"))
          (is (= [] (harness-events history))
              "the A parking failsafe never self-heals the history"))))))

(deftest reduced-input-acknowledges-pending-tail-without-stepping-it
  (testing "reduced A accepts pending B exactly once but never invokes xrf for B"
    (let [events (atom [])
          xf (fn [rf]
               (fn
                 ([] (rf))
                 ([result]
                  (note-xrf! events :complete)
                  (rf result :C))
                 ([result input]
                  (note-xrf! events (keyword (str "step-" (name input))))
                  (if (= input :A)
                    (reduced (rf result :A))
                    (rf result input)))))
          ch (a/chan 1 xf)
          ack-a-count (atom 0)
          ack-b-count (atom 0)
          ack-a (promise)
          ack-b (promise)]
      (is (= true (a/>!! ch :seed)))
      (is (= true (a/put! ch :A #(do (swap! ack-a-count inc)
                                      (record! events {:kind :ack :event :A :value %})
                                      (deliver ack-a %)))))
      (is (= true (a/put! ch :B #(do (swap! ack-b-count inc)
                                      (record! events {:kind :ack :event :B :value %})
                                      (deliver ack-b %)))))
      (is (= [0 0] [@ack-a-count @ack-b-count])
          "both tail inputs are pending before capacity opens")
      (let [values [(take-with-timeout ch)
                    (take-with-timeout ch)
                    (take-with-timeout ch)
                    (take-with-timeout ch)]
            a-result (await ack-a)
            b-result (await ack-b)
            history @events]
        (is (= [:seed :A :C nil] values)
            "reduced A and completion output drain before EOF")
        (is (= [true true] [a-result b-result])
            "A and the already-admitted B are acknowledged")
        (is (= [1 1] [@ack-a-count @ack-b-count])
            "B is acknowledged exactly once")
        (is (= [[true] [true]]
               [(ack-values history :A) (ack-values history :B)])
            "the reduced history has exactly one successful callback per input")
        (is (= [:step-seed :step-A :complete] (callback-events history))
            "B is never stepped after A reduces")
        (let [depths (callback-depths history)]
          (is (= (mapv (fn [_] 0) depths) depths)
              "reduced step and completion run with zero counted locks"))))))

(deftest fiber-reducer-step-really-parks
  (testing "a reducer reached through fiber go/>! parks without pinning its carrier"
    (let [events (atom [])
          entered (promise)
          release (promise)
          xf (fn [rf]
               (fn
                 ([] (rf))
                 ([result]
                  (note-xrf! events :complete)
                  result)
                 ([result _]
                  (note-xrf! events :fiber-step-start)
                  (deliver entered true)
                  (when (= timed-out (deref release park-failsafe-ms timed-out))
                    (record! events {:kind :harness
                                     :event :fiber-step-release-timeout}))
                  (note-xrf! events :fiber-step-end)
                  (rf result :A1))))
          ch (a/chan 1 xf)
          writer (binding [a/*go-backend* :fiber]
                   (a/go (a/>! ch :A)))]
      (is (= true (await entered)) "fiber reducer callback entered")
      (let [sibling (binding [a/*go-backend* :fiber]
                      (a/go
                        (record! events {:kind :sibling :event :fiber-progress})
                        :sibling))
            sibling-result (take-with-timeout sibling)
            writer-before-release (take-with-timeout writer)]
        (deliver release true)
        (let [writer-result (if (= timed-out writer-before-release)
                              (take-with-timeout writer)
                              writer-before-release)
              _ (a/close! ch)
              values (drain-n ch 2)
              history @events]
          (is (= :sibling sibling-result)
              "the single carrier runs a sibling while the reducer is parked")
          (is (= timed-out writer-before-release)
              "fiber >! remains parked until the reducer is explicitly released")
          (is (= true writer-result) "fiber >! completes after reducer resume")
          (is (= [:A1 nil] values) "fiber reducer output drains before EOF")
          (is (= [:fiber-step-start :fiber-step-end :complete]
                 (callback-events history))
              "fiber reducer resume and completion retain order")
          (is (= [true true]
                 (fiber-flags-for history #{:fiber-step-start :fiber-step-end}))
              "the reducer park and resume actually execute in a fiber")
          (let [depths (callback-depths history)]
            (is (= (mapv (fn [_] 0) depths) depths)
                "fiber reducer and completion run with zero counted locks"))
          (is (= [] (harness-events history))
              "the fiber reducer failsafe never self-heals the history"))))))

(deftest fiber-ex-handler-really-parks
  (testing "an ex-handler reached through fiber go/>! parks and recovers"
    (let [events (atom [])
          entered (promise)
          release (promise)
          xf (fn [rf]
               (fn
                 ([] (rf))
                 ([result]
                  (note-xrf! events :complete)
                  result)
                 ([result _]
                  (note-xrf! events :throw)
                  (throw (ex-info "expected fiber xrf failure" {})))))
          exh (fn [_]
                (note-xrf! events :fiber-ex-start)
                (deliver entered true)
                (when (= timed-out (deref release park-failsafe-ms timed-out))
                  (record! events {:kind :harness
                                   :event :fiber-ex-release-timeout}))
                (note-xrf! events :fiber-ex-end)
                :recovery)
          ch (a/chan 1 xf exh)
          writer (binding [a/*go-backend* :fiber]
                   (a/go (a/>! ch :A)))]
      (is (= true (await entered)) "fiber exception handler entered")
      (let [sibling (binding [a/*go-backend* :fiber]
                      (a/go
                        (record! events {:kind :sibling :event :fiber-progress})
                        :sibling))
            sibling-result (take-with-timeout sibling)
            writer-before-release (take-with-timeout writer)]
        (deliver release true)
        (let [writer-result (if (= timed-out writer-before-release)
                              (take-with-timeout writer)
                              writer-before-release)
              _ (a/close! ch)
              values (drain-n ch 2)
              history @events]
          (is (= :sibling sibling-result)
              "the single carrier runs a sibling while the ex-handler is parked")
          (is (= timed-out writer-before-release)
              "fiber >! remains parked until the handler is explicitly released")
          (is (= true writer-result) "fiber >! completes after handler recovery")
          (is (= [:recovery nil] values)
              "fiber handler recovery output drains before EOF")
          (is (= [:throw :fiber-ex-start :fiber-ex-end :complete]
                 (callback-events history))
              "fiber throw, handler resume, and completion retain order")
          (is (= [true true true]
                 (fiber-flags-for history
                                  #{:throw :fiber-ex-start :fiber-ex-end}))
              "xrf and the handler park/resume actually execute in a fiber")
          (let [depths (callback-depths history)]
            (is (= (mapv (fn [_] 0) depths) depths)
                "fiber xrf, ex-handler, and completion run with zero counted locks"))
          (is (= [] (harness-events history))
              "the fiber ex-handler failsafe never self-heals the history"))))))

(deftest parking-ex-handler-publishes-recovery
  (testing "a parking exception handler releases the channel lock and recovers"
    (let [events (atom [])
          entered (promise)
          release (promise)
          sibling (promise)
          xf (fn [rf]
               (fn
                 ([] (rf))
                 ([result]
                  (note-xrf! events :complete)
                  result)
                 ([result _]
                  (note-xrf! events :throw)
                  (throw (ex-info "expected xrf failure" {})))))
          exh (fn [_]
                (note-xrf! events :ex-start)
                (deliver entered true)
                (when (= timed-out (deref release park-failsafe-ms timed-out))
                  (record! events {:kind :harness :event :ex-release-timeout}))
                (note-xrf! events :ex-end)
                :recovery)
          ch (a/chan 1 xf exh)
          put-call (future (a/>!! ch :A))]
      (is (= true (await entered)) "exception handler entered")
      (let [close-call (future (a/close! ch) :closed)
            sibling-call (future
                           (record! events {:kind :sibling :event :progress})
                           (deliver sibling true)
                           true)
            close-before-release (await close-call)
            sibling-before-release (await sibling-call)
            pre-release-poll (future
                               (a/alts!! [ch] :default :not-ready :priority true))
            poll-before-release (await pre-release-poll)]
        (deliver release true)
        (let [put-result (await put-call)
              close-result (if (= timed-out close-before-release) (await close-call)
                               close-before-release)
              poll-result (if (= timed-out poll-before-release) (await pre-release-poll)
                              poll-before-release)
              poll-value (when (and (vector? poll-result)
                                    (= ch (second poll-result)))
                           (first poll-result))
              values (if (= timed-out poll-before-release)
                       (into [poll-value] (drain-n ch 1))
                       (drain-n ch 2))
              history @events]
          (is (= :closed close-before-release)
              "close returns while the ex-handler is parked")
          (is (= true sibling-before-release)
              "a sibling progresses while the ex-handler is parked")
          (is (= [:not-ready :default] poll-before-release)
              "close does not expose EOF ahead of recovery publication")
          (is (= [true :closed]
                 [put-result close-result])
              "all bounded workers finish after the handler resumes")
          (is (= [:recovery nil] values)
              "the handler recovery output publishes before EOF")
          (is (= [:throw :ex-start :ex-end :complete]
                 (callback-events history))
              "throw, handler, and completion callbacks retain order")
          (let [depths (callback-depths history)]
            (is (= (mapv (fn [_] 0) depths) depths)
                "xrf, ex-handler, and completion run with zero counted locks"))
          (is (= [] (harness-events history))
              "the ex-handler parking failsafe never self-heals the history"))))))

(let [result (run-tests 'core-async-reducer-history-test)]
  (System/exit (if (zero? (+ (:fail result) (:error result))) 0 1)))
