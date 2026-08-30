(defn outcome [f]
  (try
    [:ok (f)]
    (catch Throwable e
      [:throw (.getName (class e)) (.getMessage e)])))

(defn after-failure [cell f]
  [(outcome f) (.get cell)])

(defn deterministic-cases []
  (let [i-set (java.util.concurrent.atomic.AtomicInteger. 7)
        i-swap (java.util.concurrent.atomic.AtomicInteger. -9)
        i-cas (java.util.concurrent.atomic.AtomicInteger. 11)
        l-set (java.util.concurrent.atomic.AtomicLong. 7)
        l-swap (java.util.concurrent.atomic.AtomicLong. -9)
        l-cas (java.util.concurrent.atomic.AtomicLong. 11)]
    [[:construct
      (outcome #(.get (java.util.concurrent.atomic.AtomicInteger. 2.9)))
      (outcome #(.get (java.util.concurrent.atomic.AtomicInteger. 2147483648)))
      (outcome #(.get (java.util.concurrent.atomic.AtomicLong. 2.9)))
      (outcome #(.get (java.util.concurrent.atomic.AtomicLong. 9223372036854775808N)))]
     [:set
      (do (.set i-set 2.9) (.get i-set))
      (after-failure i-set #(.set i-set 2147483648))
      (do (.set l-set 2.9) (.get l-set))
      (after-failure l-set #(.set l-set 9223372036854775808N))]
     [:get-and-set
      [(.getAndSet i-swap 2.9) (.get i-swap)]
      (after-failure i-swap #(.getAndSet i-swap 2147483648))
      [(.getAndSet l-swap 2.9) (.get l-swap)]
      (after-failure l-swap #(.getAndSet l-swap 9223372036854775808N))]
     [:compare-and-set
      [(.compareAndSet i-cas 11.9 12.9) (.get i-cas)]
      (after-failure i-cas #(.compareAndSet i-cas 12 2147483648))
      [(.compareAndSet l-cas 11.9 12.9) (.get l-cas)]
      (after-failure l-cas #(.compareAndSet l-cas 12 9223372036854775808N))]
     [:integer-wrap
      (.incrementAndGet (java.util.concurrent.atomic.AtomicInteger. 2147483647))
      (.decrementAndGet (java.util.concurrent.atomic.AtomicInteger. -2147483648))
      (let [a (java.util.concurrent.atomic.AtomicInteger. 2147483647)]
        [(.getAndIncrement a) (.get a)])
      (let [a (java.util.concurrent.atomic.AtomicInteger. -2147483648)]
        [(.getAndDecrement a) (.get a)])
      (.addAndGet (java.util.concurrent.atomic.AtomicInteger. 2147483640) 10)
      (let [a (java.util.concurrent.atomic.AtomicInteger. -2147483640)]
        [(.getAndAdd a -10) (.get a)])]
     [:long-wrap
      (.incrementAndGet (java.util.concurrent.atomic.AtomicLong. 9223372036854775807))
      (.decrementAndGet (java.util.concurrent.atomic.AtomicLong. -9223372036854775808))
      (let [a (java.util.concurrent.atomic.AtomicLong. 9223372036854775807)]
        [(.getAndIncrement a) (.get a)])
      (let [a (java.util.concurrent.atomic.AtomicLong. -9223372036854775808)]
        [(.getAndDecrement a) (.get a)])
      (.addAndGet (java.util.concurrent.atomic.AtomicLong. 9223372036854775800) 10)
      (let [a (java.util.concurrent.atomic.AtomicLong. -9223372036854775800)]
        [(.getAndAdd a -10) (.get a)])]
     [:callback-conversion
      (let [a (java.util.concurrent.atomic.AtomicInteger. 1)]
        [(.updateAndGet a (fn [_] 2.9)) (.get a)])
      (let [a (java.util.concurrent.atomic.AtomicInteger. 1)]
        [(.getAndUpdate a (fn [_] 2.9)) (.get a)])
      (let [a (java.util.concurrent.atomic.AtomicLong. 1)]
        [(.updateAndGet a (fn [_] 2.9)) (.get a)])
      (let [a (java.util.concurrent.atomic.AtomicLong. 1)]
        [(.getAndUpdate a (fn [_] 2.9)) (.get a)])]
     [:number-view
      (.intValue (java.util.concurrent.atomic.AtomicLong. 4294967295))
      (.longValue (java.util.concurrent.atomic.AtomicInteger. -2147483648))]]))

;; A reproducible pseudo-random differential property.  The LCG stays in an
;; exact, safely representable range on both hosts; only the atomic operation is
;; responsible for primitive-width overflow.
(defn deltas []
  (->> (iterate #(mod (+ (* % 1103515245) 12345) 4294967296) 20260829)
       rest
       (take 128)
       (mapv #(- (mod % 2000000001) 1000000000))))

(defn random-transcript [cell]
  (let [ds (deltas)]
    [(mapv #(.getAndAdd cell %) ds) (.get cell)]))

(prn
 [(deterministic-cases)
  [:random-integer
   (random-transcript
    (java.util.concurrent.atomic.AtomicInteger. 2147483640))]
  [:random-long
   (random-transcript
    (java.util.concurrent.atomic.AtomicLong. 9223372036854775800))]])
