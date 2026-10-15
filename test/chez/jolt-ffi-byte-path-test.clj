(ns jolt-ffi-byte-path-test
  (:require [jolt.ffi :as ffi]))

;; Public wrappers, not raw host entries. Run with source bin/jolt or the exact
;; built candidate. Every allocation is released; no access follows free/close.
(def checks (atom 0))
(def failures (atom []))
(defn check-eq [label got expected]
  (swap! checks inc)
  (when-not (= got expected)
    (swap! failures conj {:label label :got got :expected expected})))
(defn thrown-data [f]
  (try (f) :no-throw
       (catch clojure.lang.ExceptionInfo e (ex-data e))
       (catch Throwable _ :other-throw)))
(defn with-native [n f]
  (let [p (ffi/alloc n)]
    (try (f p) (finally (ffi/free p)))))
(defn fill-sentinel! [p]
  (dotimes [i 16] (ffi/write p :uint8 85 i)))
(defn bytes-at [p n] (vec (ffi/read-array p n)))
(def input (byte-array [-128 -1 0 127 42]))

(defn write-case [label f at expected]
  (with-native 16
    (fn [p]
      (fill-sentinel! p)
      (check-eq (str label " count") (f p) (count expected))
      (check-eq (str label " exact bytes and both sentinels") (bytes-at p 16)
                (vec (concat (repeat at 85) expected
                             (repeat (- 16 at (count expected)) 85)))))))

(write-case "raw whole" #(ffi/write-array (+ % 2) input) 2 [-128 -1 0 127 42])
(write-case "raw explicit whole" #(ffi/write-array (+ % 2) input 0 5)
            2 [-128 -1 0 127 42])
(write-case "raw slice" #(ffi/write-array (+ % 2) input 1 3) 2 [-1 0 127])
(write-case "raw empty" #(ffi/write-array (+ % 2) (byte-array 0)) 2 [])
(write-case "raw zero at end" #(ffi/write-array (+ % 2) input 5 0) 2 [])
(doseq [t [:int8 :i8 :uint8 :u8 :byte :char :bool]]
  (write-case (str "typed whole " t) #(ffi/write-array (+ % 2) t input)
              2 [-128 -1 0 127 42]))
(write-case "typed destination offset" #(ffi/write-array % :uint8 input 3)
            3 [-128 -1 0 127 42])
(write-case "typed distinct byte offset and source index"
            #(ffi/write-array % :uint8 input 3 1 3) 3 [-1 0 127])
(write-case "typed explicit whole" #(ffi/write-array % :uint8 input 3 0 5)
            3 [-128 -1 0 127 42])
(write-case "typed empty" #(ffi/write-array % :uint8 (byte-array 0) 3) 3 [])
(write-case "typed zero at end" #(ffi/write-array % :uint8 input 3 5 0) 3 [])
(write-case "write-bytes array" #(ffi/write-bytes (+ % 2) input)
            2 [-128 -1 0 127 42])
(write-case "write-bytes empty" #(ffi/write-bytes (+ % 2) (byte-array 0)) 2 [])
(write-case "write-bytes text retains UTF-8 route" #(ffi/write-bytes (+ % 2) "é")
            2 [-61 -87])

;; Every refusal is checked against the *whole* destination. Raw byte ranges
;; use :offset; public typed ranges use :index. Do not conflate those contracts.
(doseq [[index n] [[-1 1] [0 -1] [4 2] [6 0]]]
  (with-native 16
    (fn [p]
      (fill-sentinel! p)
      (check-eq "raw range error data"
                (thrown-data #(ffi/write-array p input index n))
                {:offset index :length n :capacity 5})
      (check-eq "raw refusal writes nothing" (bytes-at p 16) (vec (repeat 16 85)))
      (check-eq "typed range error data"
                (thrown-data #(ffi/write-array p :uint8 input 3 index n))
                {:index index :length n :capacity 5})
      (check-eq "typed refusal writes nothing" (bytes-at p 16) (vec (repeat 16 85))))))
(doseq [[f expected] [[#(ffi/write-array % :string input) {:type :string}]
                      [#(ffi/write-array % "not-a-type" input) {:second "not-a-type"}]
                      [#(ffi/write-array % 12 input 0 0 1) {:second 12}]]]
  (with-native 16
    (fn [p]
      (fill-sentinel! p)
      (check-eq "invalid typed form preserves error data" (thrown-data #(f p)) expected)
      (check-eq "invalid typed form writes nothing" (bytes-at p 16) (vec (repeat 16 85))))))

(with-native 16
  (fn [p]
    (fill-sentinel! p)
    (check-eq "nil write-bytes rejects"
              (not= :no-throw (thrown-data #(ffi/write-bytes p nil))) true)
    (check-eq "nil write-bytes writes nothing" (bytes-at p 16) (vec (repeat 16 85)))
    (let [a (byte-array [-128 -1 0 127])]
      (ffi/write-array (+ p 2) a)
      (aset a 0 66)
      (check-eq "source mutation cannot change completed native copy"
                (bytes-at (+ p 2) 4) [-128 -1 0 127])
      (ffi/write p :uint8 99 3)
      (check-eq "native mutation cannot change source array" (vec a) [66 -1 0 127]))))

(defn zeroed? [p n] (every? zero? (seq (ffi/read-array p n))))
(defn poison! [p n]
  (when (pos? n)
    (ffi/write p :uint8 255 0)
    (ffi/write p :uint8 254 (dec n))))

;; Repeat across the template boundary and poison before release. Count actual
;; delegated frees, including over-aligned arena raw blocks, without accessing
;; a released pointer. Exception paths still close/free in finally.
(doseq [n [0 -1]]
  (let [allocate ffi/__calloc free ffi/__free allocations (atom 0) frees (atom 0)
        arena (ffi/confined-arena)]
    (try
      (with-redefs [ffi/__calloc (fn [size] (swap! allocations inc) (allocate size))
                    ffi/__free (fn [p] (swap! frees inc) (free p))]
        (check-eq "manual nonpositive size data" (thrown-data #(ffi/alloc n)) {:size n})
        (check-eq "arena nonpositive size data" (thrown-data #(ffi/alloc arena n)) {:size n})
        (check-eq "size refusal precedes native allocation" @allocations 0)
        (check-eq "size refusal does not free anything" @frees 0)
        (check-eq "size refusal leaves arena open" (ffi/arena-open? arena) true)
        (let [p (ffi/alloc arena 1)]
          (check-eq "arena remains usable after refused size" (zeroed? p 1) true)
          (check-eq "one subsequent valid native allocation" @allocations 1))
        (ffi/close-arena arena)
        (check-eq "valid allocation still released after prior refusal" @frees 1))
      (finally (ffi/close-arena arena)))))
(doseq [n [1 65535 65536 65537] round [0 1]]
  (let [free ffi/__free frees (atom 0)]
    (with-redefs [ffi/__free (fn [p] (swap! frees inc) (free p))]
      (with-native n
        (fn [p]
          (check-eq (str "manual zeroed allocation " n " round " round) (zeroed? p n) true)
          (poison! p n)))
      (check-eq "manual ownership frees exactly once" @frees 1)))
  (let [free ffi/__free frees (atom 0) arena (ffi/confined-arena) held (atom nil)]
    (with-redefs [ffi/__free (fn [p] (swap! frees inc) (free p))]
      (try
        (let [p (ffi/alloc arena n 64)]
          (reset! held p)
          (check-eq "arena allocation alignment" (mod p 64) 0)
          (check-eq (str "arena zeroed allocation " n " round " round) (zeroed? p n) true)
          (check-eq "arena records usable size" (ffi/size p) n)
          (poison! p n))
        (finally (ffi/close-arena arena)))
      (check-eq "arena ownership frees exactly once" @frees 1)
      (check-eq "arena is closed" (ffi/arena-open? arena) false)
      (check-eq "arena removes size metadata" (ffi/size @held) 0)
      (ffi/close-arena arena)
      (check-eq "repeat close does not double-free" @frees 1)
      (check-eq "closed arena refuses allocation"
                (not= :no-throw (thrown-data #(ffi/alloc arena 1))) true)
      (check-eq "refused allocation does not free another block" @frees 1))))

(if (empty? @failures)
  (println "JOLT-FFI-BYTE-PATH-TEST OK" @checks "checks")
  (do (doseq [failure @failures] (println "FAIL" (pr-str failure)))
      (println "JOLT-FFI-BYTE-PATH-TEST FAILED" (count @failures) "of" @checks)
      (System/exit 1)))
