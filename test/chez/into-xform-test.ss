;; Transduced into: semantics and an observed accumulation-path control.
(import (chezscheme))
(load "host/chez/gate-boot.ss")

;; Restore the old algorithm to prove the path observation fails even when
;; ordinary transformed values remain correct. No elapsed-time threshold.
(when (equal? (getenv "JOLT_TEST_OLD_INTO_XFORM") "1")
  (set! into-xform
    (lambda (to xform from)
      (let* ((rf (lambda a (if (= (length a) 1) (car a)
                              (jolt-conj1 (if (jolt-nil? (car a)) jolt-empty-list (car a)) (cadr a)))))
             (xrf (jolt-invoke xform rf))
             (result (into-fold xrf to from)))
        (jolt-invoke xrf result)))))

(define total 0)
(define fails 0)
(define (ok label p)
  (set! total (+ total 1))
  (unless p (set! fails (+ fails 1)) (printf "FAIL: ~a\n" label)))
(define (ev s) (jolt-final-str (jolt-compile-eval s "user")))
(define (is label s expected) (ok label (string=? (ev s) expected)))

(is "vector map/filter" "(into [99] (comp (map inc) (filter even?)) (range 5))" "[99 2 4]")
(is "map duplicate and nil keys" "(= {:a 2 nil 3} (into {} (map identity) [[:a 1] [:a 2] [nil 3]]))" "true")
(is "set deduplicates" "(= #{:kept 2 3} (into #{:kept} (map inc) [1 1 2]))" "true")
(is "nil target" "(into nil (map inc) [1 2])" "(3 2)")
(is "empty nil target" "(nil? (into nil (map inc) []))" "true")
(is "list target" "(into '(0) (map inc) [1 2])" "(3 2 0)")
(is "sorted target" "(keys (into (sorted-map :b 1) (map identity) [[:a 2]]))" "(:a :b)")
(is "metadata" "(meta (into (with-meta [:kept] {:source true}) (map inc) [1]))" "{:source true}")
(is "empty metadata" "(meta (into (with-meta {} {:source true}) (map identity) []))" "{:source true}")
(is "source target immutable" "(let [source {:kept 1} result (into source (map (fn [i] [i i])) (range 32))] [(get source :kept) (count source) (count result)])" "[1 1 33]")
(is "array map promotion" "(type (into {} (map (fn [i] [(keyword (str i)) i])) (range 9)))" "clojure.lang.PersistentHashMap")
(is "reduced stops callbacks" "(let [seen (atom []) result (into [] (comp (map (fn [x] (swap! seen conj x) x)) (take 2)) (range 10))] [result @seen])" "[[0 1] [0 1]]")
(is "completion once" "(let [n (atom 0) xf (fn [rf] (fn ([r] (swap! n inc) (rf r)) ([r x] (rf r x)))) result (into [] xf [1 2])] [result @n])" "[[1 2] 1]")
(is "IReduceInit source" "(let [n (atom 0) source (reify clojure.lang.IReduceInit (reduce [_ rf init] (swap! n inc) (rf init 7))) result (into [] (map inc) source)] [result @n])" "[[8] 1]")
(is "exception identity and stop order" "(let [seen (atom []) error (ex-info \"stop\" {})] (try (into [] (map (fn [x] (swap! seen conj x) (if (= x 2) (throw error) x))) (range 10)) (catch clojure.lang.ExceptionInfo got [(identical? error got) @seen])))" "[true [0 1 2]]")

;; Compile before installing the observation, so compiler collection building
;; cannot be counted as the operation under test.
(define jobs
  (map (lambda (s) (jolt-compile-eval s "user"))
       '("(fn [] (into [] (map inc) (range 64)))"
         "(fn [] (into {} (map (fn [i] [i i])) (range 64)))"
         "(fn [] (into #{} (map inc) (range 64)))")))
(define persistent-target-steps 0)
(define previous-conj1 jolt-conj1)
(dynamic-wind
  (lambda ()
    (set! jolt-conj1
      (lambda (target item)
        (when (or (pvec? target) (pmap? target) (pset? target))
          (set! persistent-target-steps (+ persistent-target-steps 1)))
        (previous-conj1 target item))))
  (lambda () (for-each (lambda (job) (jolt-invoke job)) jobs))
  (lambda () (set! jolt-conj1 previous-conj1)))
(ok "editable targets never step through persistent conj" (= persistent-target-steps 0))
(printf "into-xform: ~a checks, ~a failures; persistent-target-steps ~a\n" total fails persistent-target-steps)
(exit (if (= fails 0) 0 1))
