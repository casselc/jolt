(ns str-render-order-test
  (:require [clojure.test :refer [deftest is run-tests]]))

(defn- token [id visits failed-id error]
  (reify Object
    (toString [_]
      (swap! visits conj id)
      (if (= id failed-id) (throw error) (name id)))))

(defn- observe [arity failed-id]
  (let [visits (atom []) error (ex-info "original synthetic renderer error" {})
        ids (vec (take arity [:a :b :c :d :e]))
        values (mapv #(token % visits failed-id error) ids)
        operation (case arity
                    2 #(str (nth values 0) (nth values 1))
                    3 #(str (nth values 0) (nth values 1) (nth values 2))
                    5 #(str (nth values 0) (nth values 1) (nth values 2)
                            (nth values 3) (nth values 4)))
        caught (atom nil)
        result (try (operation) (catch Throwable e (reset! caught e) nil))]
    {:result result :visits @visits :error @caught :original error}))

(deftest render-in-reference-order
  (doseq [[arity text ids] [[2 "ab" [:a :b]] [3 "abc" [:a :b :c]]
                           [5 "abcde" [:a :b :c :d :e]]]]
    (let [observed (observe arity nil)]
      (is (= text (:result observed)))
      (is (= ids (:visits observed)))))
  (doseq [arity [2 3 5]]
    (let [observed (observe arity :b)]
      (is (= [:a :b] (:visits observed)))
      (is (identical? (:original observed) (:error observed)))))
  (let [s (str "same" "-string")]
    (is (identical? s (str s)))))

(let [result (run-tests 'str-render-order-test)]
  (System/exit (if (zero? (+ (:fail result) (:error result))) 0 1)))
