;; Empty builtin vectors/nil need no transient buffer; custom reducers still run.
(import (chezscheme))
(load "host/chez/gate-boot.ss")
(define total 0)
(define fails 0)
(define (ok label p)
  (set! total (+ total 1))
  (unless p (set! fails (+ fails 1)) (printf "FAIL: ~a\n" label)))
(define (is label source expected)
  (ok label (string=? (jolt-final-str (jolt-compile-eval source "user")) expected)))
(is "unused invalid fn on empty vector" "(mapv 42 [])" "[]")
(is "unused invalid fn on nil" "(mapv 42 nil)" "[]")
(is "empty list retains generic route" "(mapv 42 '())" "[]")
(is "metadata stripped" "(nil? (meta (mapv inc (with-meta [] {:source true}))))" "true")
(is "nonempty vector" "(mapv inc [1 2 3])" "[2 3 4]")
(is "two inputs shortest" "(mapv + [1 2] [10])" "[11]")
(is "three inputs" "(mapv + [1] [2] [3])" "[6]")
(is "four inputs" "(mapv + [1] [2] [3] [4])" "[10]")
(is "empty lazy source still realized"
    "(let [seen (atom 0) source (lazy-seq (swap! seen inc) nil)] [(mapv inc source) @seen])"
    "[[] 1]")
(is "custom reducer must not consult seq or skip reduction"
    "(let [seen (atom 0) source (reify clojure.lang.IReduceInit (reduce [_ rf init] (swap! seen inc) (rf init 7)) clojure.lang.Seqable (seq [_] (throw (ex-info \"seq forbidden\" {}))))] [(mapv inc source) @seen])"
    "[[8] 1]")

;; mapv captures the transient Var, not the raw native procedure binding.
;; Observe that actual public Var only while the precompiled job is running,
;; excluding with-redefs setup/restoration. Calibrate with a nonempty job.
(define (observed source)
  (string-append
    "(let [calls (atom 0) active (atom false) original transient job (fn [] " source ")] "
    "(with-redefs [clojure.core/transient (fn [coll] (when @active (swap! calls inc)) (original coll))] "
    "(reset! active true) (try (job) (finally (reset! active false)))) @calls)"))
(is "observer sees nonempty vector transient" (observed "(mapv inc [1])") "1")
(is "empty vector constructs no transient" (observed "(mapv inc [])") "0")
(is "nil constructs no transient" (observed "(mapv inc nil)") "0")
(is "empty metadata vector constructs no transient"
    (observed "(mapv inc (with-meta [] {:source true}))") "0")
(printf "empty-mapv: ~a checks, ~a failures\n" total fails)
(exit (if (= fails 0) 0 1))
