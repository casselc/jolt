;; test/chez/atomic-publish-test.clj — the jolt.publish no-clobber primitive
;; against a real scratch filesystem. Run: bin/jolt run test/chez/atomic-publish-test.clj
;; (smoke.sh greps for "ATOMIC-PUBLISH-TEST OK").
;;
;; WHAT IT PROVES. publish! is atomic and no-clobber:
;;  1. functional — publishing onto an absent target succeeds and consumes the
;;     temp name; publishing onto a present target answers :exists, leaves the
;;     target byte-for-byte intact, and leaves the loser's temp file intact.
;;  2. concurrent race — N writers each publish their own distinct temp file onto
;;     ONE target, all released at once from a barrier: exactly one gets
;;     :published, the other N-1 get :exists (EEXIST), and the target reads as one
;;     WHOLE payload — never a torn mix.
;;  3. pause race — a deterministic interleaving: the loser writes its temp file and
;;     then parks on a latch while the winner publishes; the loser is released only
;;     after the winner is fully in place, and must answer :exists with the target
;;     still holding the winner's content. A paused writer can neither steal the
;;     name nor clobber it.
;;
;; Determinism: the concurrent case uses a ready-latch + go-latch so every writer
;; is poised at its publish call before any publishes, forcing the race rather
;; than relying on the scheduler to interleave them. The pause case schedules the
;; interleaving explicitly, so "loser after winner" is not a timing assumption.
(ns atomic-publish-test
  (:require [jolt.publish :as pub]
            [jolt.fs :as fs])
  (:import [java.util.concurrent CountDownLatch TimeUnit]))

(def failures (atom []))
(defn check [label got want]
  (when-not (= got want)
    (swap! failures conj (str label ": want " (pr-str want) " got " (pr-str got)))))

(def root (str (fs/create-temp-dir {:prefix "jolt-pub-gate-"})))
(defn f [name] (str root "/" name))
(defn write! [name content] (spit (f name) content))

;; ---- 1. functional -----------------------------------------------------------
(write! "src-one" "content-one")
(check "publish onto absent target" (pub/publish! (f "src-one") (f "t1")) :published)
(check "content published" (slurp (f "t1")) "content-one")
(check "temp name consumed on publish" (.exists (java.io.File. (f "src-one"))) false)

(write! "src-two" "content-two")
(check "publish onto present target answers :exists"
       (pub/publish! (f "src-two") (f "t1")) :exists)
(check "present target not clobbered" (slurp (f "t1")) "content-one")
(check "loser temp left intact" (.exists (java.io.File. (f "src-two"))) true)
(check "loser temp still holds its content" (slurp (f "src-two")) "content-two")

;; ---- 2. concurrent race (barrier-released, exactly one winner) ---------------
(def N 12)
(def contended (f "contended"))
(def payloads (mapv (fn [i] (str "payload-" i "-" (apply str (repeat 256 "x"))))
                    (range N)))
(def ready (CountDownLatch. N))
(def go (CountDownLatch. 1))
(def race-results (atom []))

(def contenders
  (mapv (fn [i]
          (Thread. (fn []
                     (let [tmp (f (str "race-tmp-" i))]
                       (spit tmp (nth payloads i))
                       (.countDown ready)
                       (.await go)
                       (swap! race-results conj {:i i :status (pub/publish! tmp contended)})))))
        (range N)))

(doseq [t contenders] (.start t))
(check "all contenders reached the publish call"
       (.await ready 10 TimeUnit/SECONDS) true)
(.countDown go)
(doseq [t contenders] (.join t))

(let [published (filter #(= :published (:status %)) @race-results)
      losers (filter #(= :exists (:status %)) @race-results)]
  (check "exactly one publisher wins" (count published) 1)
  (check "every loser sees EEXIST" (count losers) (dec N))
  (check "target holds exactly one WHOLE payload"
         (contains? (set payloads) (slurp contended)) true))

;; ---- 3. pause race (loser parked until after the winner is in place) ---------
(write! "winner-tmp" "winner-payload")
(def paused-target (f "paused"))
(def allow-losers (CountDownLatch. 1))
(def loser-results (atom []))

(def loser
  (Thread. (fn []
             (write! "loser-tmp" "loser-payload")  ; temp is written BEFORE the pause
             (.await allow-losers)
             (swap! loser-results conj (pub/publish! (f "loser-tmp") paused-target)))))

(.start loser)
;; The winner publishes while the loser is deterministically paused — nothing
;; about this ordering is left to the scheduler.
(check "winner publishes while loser is paused"
       (pub/publish! (f "winner-tmp") paused-target) :published)
(check "winner content in place before the loser is released"
       (slurp paused-target) "winner-payload")

(.countDown allow-losers)
(.join loser)
(check "paused loser loses to the existing target" @loser-results [:exists])
(check "target still holds the winner after the loser's attempt"
       (slurp paused-target) "winner-payload")

;; ---- 4. fallback classification (injected syscall answers, no host mutation) --
;; Exercise the only branch a modern Linux host cannot naturally reach: a kernel
;; that rejects RENAME_NOREPLACE still has a safe link/unlink publication path.
(check "ENOSYS rename falls back to exclusive link publication"
       (with-redefs-fn {#'jolt.publish/c-renameat2 (fn [& _] -1)
                         #'jolt.publish/c-link (fn [& _] 0)
                         #'jolt.publish/c-unlink (fn [& _] 0)
                         #'jolt.publish/errno (fn [] 38)}
         #(pub/publish! (f "unused-fallback-tmp") (f "unused-fallback-target")))
       :published)
(check "EXDEV remains a caller error, not a capability refusal"
       (with-redefs-fn {#'jolt.publish/c-renameat2 (fn [& _] -1)
                         #'jolt.publish/errno (fn [] 18)}
         #(pub/publish! (f "unused-exdev-tmp") (f "unused-exdev-target")))
       :error)

(fs/delete-tree root)

(if (empty? @failures)
  (println "ATOMIC-PUBLISH-TEST OK")
  (do (doseq [x @failures] (println "FAIL:" x))
      (println "ATOMIC-PUBLISH-TEST FAILED:" (count @failures))))
