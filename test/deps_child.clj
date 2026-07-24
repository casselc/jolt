(ns deps-child
  "One-shot child process used by deps-test to exercise the cache lock across
  separate native Jolt processes."
  (:require [jolt.deps]))

(def ensure-git (var jolt.deps/ensure-git))

(let [[start url sha result] *command-line-args*]
  (loop [attempt 0]
    (when-not (jolt.host/file-exists? start)
      (when (>= attempt 600)
        (throw (ex-info "timed out waiting for deps child start barrier"
                        {:start start})))
      (Thread/sleep 50)
      (recur (inc attempt))))
  (spit result (ensure-git 'fixture/interprocess url sha)))
