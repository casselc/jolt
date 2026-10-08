(ns transient-assoc-fixed-arity-test
  (:require [clojure.test :refer [deftest is run-tests]]))

(deftype AssocProbe [calls]
  clojure.lang.ITransientMap
  (assoc [this key value] (swap! calls conj [key value]) this))

(deftest single-pair-preserves-native-collection-contracts
  (let [source {:a 1} t (transient source)]
    (is (identical? t (assoc! t :a 2)))
    (is (= {:a 2 :b 3} (persistent! (assoc! t :b 3))))
    (is (= {:a 1} source)))
  (is (= [2 3] (persistent! (assoc! (assoc! (transient [1]) 0 2) 1 3))))
  (let [t (reduce (fn [out n] (assoc! out n n)) (transient {}) (range 20))]
    (is (= 20 (count (persistent! t))))))

(deftest custom-transient-and-variadic-calls-retain-order
  (let [calls (atom []) t (AssocProbe. calls)]
    (is (identical? t (assoc! t :a 1)))
    (is (= [[:a 1]] @calls))
    (is (identical? t (assoc! t :b 2 :c 3)))
    (is (= [[:a 1] [:b 2] [:c 3]] @calls)))
  (is (= {:a 1 :b nil} (persistent! (assoc! (transient {}) :a 1 :b)))))

(deftest invalid-native-transients-are-not-mutated
  (let [t (transient {}) saved (persistent! (assoc! t :a 1))]
    (is (thrown? IllegalAccessError (assoc! t :a 2)))
    (is (= {:a 1} saved)))
  (is (thrown? ClassCastException (assoc! {} :a 1)))
  (is (thrown? IllegalArgumentException (assoc! (transient {}) :a))))

(defn -main [& _]
  (let [r (run-tests 'transient-assoc-fixed-arity-test)]
    (System/exit (if (zero? (+ (:fail r) (:error r))) 0 1))))
