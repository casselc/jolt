(ns windows-shell-boundary-test
  "Focused native-Windows checks for the jolt.host POSIX-shell boundary.")

(def failures (atom 0))

(defn check= [label expected actual]
  (if (= expected actual)
    (println "  ok:" label)
    (do
      (swap! failures inc)
      (binding [*out* *err*]
        (println "FAIL:" label)
        (println "  expected:" (pr-str expected))
        (println "  actual:  " (pr-str actual))))))

(defn -main [& _]
  ;; `sh` and `sh-out` use distinct Chez process APIs. Both must cross the same
  ;; Windows cmd.exe -> selected POSIX-shell boundary.
  (check= "sh returns the selected shell's exit status"
          7 (jolt.host/sh "exit 7"))
  (check= "sh-out captures exact POSIX-shell stdout"
          "shell out ok\n" (jolt.host/sh-out "printf 'shell out ok\\n'"))
  ;; sh-out's longstanding public contract ignores the child status; retain it
  ;; while changing only how Windows reaches the POSIX shell.
  (check= "sh-out preserves captured output from a nonzero command"
          "before exit\n"
          (jolt.host/sh-out "printf 'before exit\\n'; exit 9"))
  ;; Two simultaneous calls prove the script names do not collide and that the
  ;; counter protecting them is shared safely by jolt.host/sh-out callers.
  (let [a (future (jolt.host/sh-out "printf 'left\\n'"))
        b (future (jolt.host/sh-out "printf 'right\\n'"))]
    (check= "concurrent sh-out calls use distinct scripts"
            #{"left\n" "right\n"} #{@a @b}))
  (println "windows shell boundary:" (- 4 @failures) "passed," @failures "failed")
  (flush)
  (System/exit (if (zero? @failures) 0 1)))

;; `jolt run FILE` loads the file; invoke the focused gate explicitly.
(-main)
