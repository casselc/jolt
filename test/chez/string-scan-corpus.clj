;; Deterministic JVM/jolt differential corpus for String.indexOf. Keep
;; generated strings inside jolt's documented scalar-value
;; string model: JVM UTF-16 unit indexes intentionally differ after astral code
;; points, while all BMP Unicode values below have the same index on both hosts.

(defn hinted-index-of [^String s needle from]
  (.indexOf s needle (int from)))

(defn generic-index-of [s needle from]
  (.indexOf s needle from))

(defn char-index-of [^String s code from]
  (.indexOf s (int code) (int from)))

(defn step [x]
  (mod (+ (* x 1103515245) 12345) 2147483648))

(def alphabet
  [\a \b \c \" \\ \/ \newline \tab \u00e9 \u03bb \u65e5])

(defn generated-string [seed n]
  (loop [x seed, i 0, out []]
    (if (= i n)
      [(apply str out) x]
      (let [x' (step x)]
        (recur x' (inc i) (conj out (nth alphabet (mod x' (count alphabet)))))))))

(defn generated-row [seed]
  (let [[hay x1] (generated-string seed (+ 8 (mod seed 48)))
        [raw-needle x2] (generated-string x1 (+ 1 (mod x1 5)))
        needle (if (zero? (mod x2 7)) "" raw-needle)
        froms [Integer/MIN_VALUE -7 0 1 (count hay) (+ (count hay) 9) Integer/MAX_VALUE]
        from (nth froms (mod x2 (count froms)))
        code (int (nth alphabet (mod (step x2) (count alphabet))))]
    [[hay needle from]
     (hinted-index-of hay needle from)
     (generic-index-of hay needle from)
     (char-index-of hay code from)
     (.contains ^String hay needle)]))

(def named
  {:empty-needle
   [(.indexOf "abc" "")
    (.indexOf "abc" "" -1)
    (.indexOf "abc" "" 3)
    (.indexOf "abc" "" 99)
    (.indexOf "" "" Integer/MAX_VALUE)]
   :starts
   [(.indexOf "abcabc" "bc" Integer/MIN_VALUE)
    (.indexOf "abcabc" "bc" -1)
    (.indexOf "abcabc" "bc" 2)
    (.indexOf "abcabc" "bc" 6)
    (.indexOf "abcabc" "bc" Integer/MAX_VALUE)]
   :char-overload
   [(.indexOf "aλbλ" (int \u03bb))
    (.indexOf "aλbλ" (int \u03bb) 2)
    (.indexOf "aλbλ" (int \u03bb) Integer/MIN_VALUE)
    (.indexOf "aλbλ" (int \u03bb) Integer/MAX_VALUE)
    ;; Supplementary scalar values are one Jolt string position but two JVM
    ;; UTF-16 units. These cases deliberately use a shared prefix index where
    ;; both models have the same observable answer.
    (.indexOf "a😀b" 128512)
    (.indexOf "a😀b" 128512 2)
    (.indexOf "abc" -1)
    ;; Jolt strings cannot contain UTF-16 surrogate halves, so the shared
    ;; observable result is a miss rather than an invalid scalar conversion.
    (.indexOf "abc" 55296)
    (.indexOf "abc" 1114112)]
   :unicode-scalar-values
   [(.indexOf "éλ日" "λ")
    (.indexOf "😀λ" "😀")
    (.contains "a😀b" "😀")]
   :evaluation-order
   (let [seen (atom [])
         result (.indexOf ^String (do (swap! seen conj :receiver) "abc")
                                     (do (swap! seen conj :needle) "b")
                                     (do (swap! seen conj :from) 0))]
     [@seen result])
   :hinted-and-generic
   [(hinted-index-of "abcabc" "bc" 2)
    (generic-index-of "abcabc" "bc" 2)]})

(let [rows (loop [i 0, seed 2463534242, out []]
             (if (= i 1024)
               out
               (let [seed' (step seed)]
                 (recur (inc i) seed' (conj out (generated-row seed'))))))]
  (prn {:named named :generated rows}))
