(ns app.core
  "Tree-shake fixture for the ranged jolt.ffi byte transfers.

  The transfer functions are host vars reached only through jolt.ffi, and the
  ranged path now reaches native memory through a scoped interior pointer. A
  self-contained binary must keep all of read-array/read-array!/write-array/
  with-byte-array-pointer, and a --tree-shake build must produce byte-identical
  output — a dropped host var or a scope compiled away shows up here as a diff
  or a crash rather than as a silently degraded FFI.

  Deterministic output only: the addresses are never printed."
  (:require [jolt.ffi :as ffi]))

(def payload
  (byte-array (map #(bit-and (* 37 %) 255) (range 64))))

(def sentinel 249)

(defn- ranged-round-trip
  "Move a source window out to native memory and back into a different
  destination window; return the destination, whose prefix/suffix must still
  hold the sentinel."
  [src-off len dst-off]
  (let [p (ffi/alloc (+ len 4))
        dst (byte-array (repeat 24 -7))]
    (try
      (let [wrote (ffi/write-array (+ p 2) payload src-off len)
            read (ffi/read-array! (+ p 2) len dst dst-off)]
        [wrote read (vec dst)])
      (finally (ffi/free p)))))

(defn- scoped-slice
  "Read back through the public scoped pointer, which is the same scope the
  ranged transfers now use internally."
  [off len]
  (let [p (ffi/alloc len)]
    (try
      (ffi/write-array p payload off len)
      (let [back (ffi/read-array p len)]
        (ffi/with-byte-array-pointer
          back 0 len
          (fn [_ n] [n (vec back)])))
      (finally (ffi/free p)))))

(defn- overlap-case
  "Same-backing overlap: the native pointer aliases the array being written."
  []
  (let [a (byte-array [0 1 2 3 4 5 6 7])]
    (ffi/with-byte-array-pointer
      a 0 8
      (fn [p _] (ffi/read-array! p 5 a 3)))
    (vec a)))

(defn -main [& _]
  (println "zero-length:" (ranged-round-trip 4 0 8))
  (println "ranged:" (ranged-round-trip 8 16 4))
  (println "exact-tail:" (ranged-round-trip 60 4 20))
  (println "whole-array-shaped:" (ranged-round-trip 0 24 0))
  (println "scoped:" (scoped-slice 5 6))
  (println "overlap:" (overlap-case))
  (println "sentinel:" sentinel)
  (println "rejects-null:"
           (try (ffi/read-array! 0 1 (byte-array 2) 0) :no-throw
                (catch NullPointerException _ :threw)))
  (println "rejects-range:"
           (try (ffi/write-array 1 (byte-array 2) 1 2) :no-throw
                (catch IndexOutOfBoundsException _ :threw))))
