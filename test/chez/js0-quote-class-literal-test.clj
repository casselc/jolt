;; Regression gate: a Class object embedded in quoted data is a quoted Class
;; literal (the JVM stores the Class itself in var meta, and quoting it
;; evaluates to the Class — so a macro that quotes a var's resolved :tag, like
;; sci.impl.copy-vars/ensure-quote, splices a live Class into a (quote …)
;; form). The emitter must rebuild it through the runtime class interner
;; (jolt-class-for, the same emit as the analyzer's :class leaf), not die with
;; "emit-quoted: unsupported quoted form java.lang.String".
;; Run: bin/jolt run test/chez/js0-quote-class-literal-test.clj
(ns js0-quote-class-literal-test)

(def failures (atom []))
(defn chk [label ok] (when-not ok (swap! failures conj label)))

;; --- a quoted Class value evaluates to the Class ---------------------------
;; (list 'quote <class>) is the ensure-quote shape: the class VALUE rides
;; inside the raw quote form through analysis into emit-quoted.
(let [q (eval (list 'quote java.lang.String))]
  (chk "quoted class value evaluates to the class" (= java.lang.String q))
  ;; jolt-class-for interns by name, so the quoted literal is identity-stable
  ;; against a class-token reference, like the analyzer's :class leaf.
  (chk "quoted class value is interner-stable" (identical? java.lang.String q)))

;; --- a Class value nested inside quoted collections -------------------------
(chk "class value nested in a quoted vector"
     (= [java.lang.String] (eval (list 'quote [java.lang.String]))))
(chk "class value nested in a quoted map"
     (= {:tag java.lang.String} (eval (list 'quote {:tag java.lang.String}))))
(chk "class value nested in a quoted list"
     (= (list java.lang.String 'x) (eval (list 'quote (list java.lang.String 'x)))))

;; --- the ensure-quote call site: quoting a var's resolved :tag meta ---------
(require 'clojure.string)
(let [tag (:tag (meta #'clojure.string/trim))]
  (chk "a resolved :tag is a Class value" (= java.lang.Class (class tag)))
  (chk "quoted :tag meta round-trips" (= java.lang.String (eval (list 'quote tag)))))

;; --- regression guards -------------------------------------------------------
;; a quoted class-NAME symbol is still just a symbol (reader form path).
(chk "quoted class-name symbol stays a symbol"
     (and (symbol? (quote java.lang.String))
          (= 'java.lang.String (quote java.lang.String))))
;; a genuinely unsupported embedded value still fails loudly (the :else arm —
;; the class check must not swallow other host values, e.g. an atom).
(let [e (try (eval (list 'quote (atom 1))) nil
             (catch :default e e))]
  (chk "unsupported quoted value still throws"
       (and (some? e)
            (some? (re-find #"unsupported quoted form" (ex-message e))))))

(if (empty? @failures)
  (println "JS0-QUOTE OK")
  (doseq [f @failures] (println "FAIL:" f)))
