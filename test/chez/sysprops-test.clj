;; System-properties gate (epic jolt-of08.4) — the JVM-standard keys a library
;; can reasonably sniff. os.arch answers in the JVM's spelling (aarch64/amd64),
;; user.name from the environment, os.version from the kernel. java.version
;; stays nil deliberately (jolt has no JDK to report — known divergence);
;; unknown keys answer nil exactly as the JVM's do.
;; Run: bin/jolt run test/chez/sysprops-test.clj (smoke.sh greps for
;; "SYSPROPS-TEST OK").
(ns sysprops-test
  (:require [jolt.fibers :as fib]
            [jolt.scheme :as scheme]))

(def failures (atom []))

(defmacro check-eq [label got want]
  `(do
     (print (str "  .. " ~label "\n"))
     (flush)
     (let [g# ~got w# ~want]
       (when-not (= g# w#)
         (swap! failures conj (str ~label ": want " (pr-str w#) " got " (pr-str g#)))))))

;; os.arch: the JVM's spelling for the machine we are on
(check-eq "os.arch is the JVM spelling"
          (contains? #{"aarch64" "amd64"} (System/getProperty "os.arch"))
          true)

;; user.name: the login name, as the JVM reports
(check-eq "user.name matches the environment"
          (System/getProperty "user.name")
          (or (System/getenv "USER") (System/getenv "LOGNAME") (System/getenv "USERNAME")))

;; os.version: non-empty version string (Windows has no uname/sw_vers — nil there)
(check-eq "os.version is non-empty"
          (if (= "Windows" (System/getProperty "os.name"))
            true
            (pos? (count (or (System/getProperty "os.version") ""))))
          true)

;; the properties map carries the same keys with the same values
(let [m (System/getProperties)]
  (check-eq "getProperties has os.arch" (get m "os.arch") (System/getProperty "os.arch"))
  (check-eq "getProperties has user.name" (get m "user.name") (System/getProperty "user.name"))
  (check-eq "getProperties has os.version" (get m "os.version") (System/getProperty "os.version")))

;; a set property still wins over the built-in answer, and clearing restores it
(let [orig (System/getProperty "os.arch")]
  (System/setProperty "os.arch" "vax")
  (check-eq "setProperty wins over the builtin" (System/getProperty "os.arch") "vax")
  (System/clearProperty "os.arch")
  (check-eq "clearProperty restores the builtin" (System/getProperty "os.arch") orig))

;; deliberate nils stay nil (documented divergence, not an accident)
(check-eq "java.version is nil" (System/getProperty "java.version") nil)
(check-eq "an unknown key is nil" (System/getProperty "no.such.property") nil)
(check-eq "an unknown key takes the default"
          (System/getProperty "no.such.property" "fallback")
          "fallback")

;; A non-string value is normalized through its toString method. That is
;; arbitrary user code and may park a fiber, so it must run before sys-prop-mu's
;; counted critical section. The barriers make the race deterministic:
;;
;;   1. the slow setter enters toString and parks on release;
;;   2. a thread replaces "initial" with "racer" while rendering is suspended;
;;   3. the slow setter resumes, atomically replaces "racer", and returns it.
;;
;; Restoring rendering beneath sys-prop-mu has several independent teeth: the
;; renderer observes one counted lock, its promise deref is rejected instead of
;; parking, and the previous-value chain/final value differ. The body catches that
;; failure so the negative mutation terminates instead of wedging the test.
(deftype ParkingPropertyValue [entered release locks-seen calls]
  Object
  (toString [_]
    (swap! calls inc)
    (deliver entered true)
    (swap! locks-seen conj (scheme/call "jolt-locks-held"))
    @release
    "slow-rendered"))

(let [key "jolt.sysprops.render-lock-test"
      _ (System/clearProperty key)
      _ (System/setProperty key "initial")
      entered (promise)
      release (promise)
      locks-seen (atom [])
      calls (atom 0)
      value (ParkingPropertyValue. entered release locks-seen calls)
      slow (fib/spawn
             (fn []
               (try
                 {:prev (System/setProperty key value)}
                 (catch Throwable e
                   {:error [(.getName (class e)) (ex-message e)]}))))
      entered-result (deref entered 2000 ::not-entered)
      state-before-race
      (loop [n 100000]
        (let [s (fib/state slow)]
          (if (or (= s :parked) (not (pos? n)))
            s
            (do (Thread/yield) (recur (dec n))))))
      racer-started (promise)
      racer-done (promise)
      _ (future
          (deliver racer-started true)
          (deliver racer-done (System/setProperty key "racer")))
      racer-started-result (deref racer-started 2000 ::not-started)
      racer-before-release (deref racer-done 2000 ::blocked)
      _ (deliver release true)
      slow-result (fib/join slow 2000 ::timed-out)
      racer-result (if (= ::blocked racer-before-release)
                     (deref racer-done 2000 ::timed-out)
                     racer-before-release)
      final-value (System/getProperty key)]
  (check-eq "setProperty renders user values outside its counted lock and preserves atomic replacement"
            [entered-result state-before-race @locks-seen @calls racer-started-result
             racer-before-release racer-result slow-result final-value]
            [true :parked [0] 1 true "initial" "initial"
             {:prev "racer"} "slow-rendered"])
  (System/clearProperty key))

(if (empty? @failures)
  (println "SYSPROPS-TEST OK")
  (do (doseq [f @failures] (println "FAIL:" f))
      (println "SYSPROPS-TEST FAILED:" (count @failures))))
