(import (chezscheme))
(load "host/chez/static-analysis-debt.ss")

(define failures 0)
(define checks 0)
(define (check label value)
  (set! checks (+ checks 1))
  (unless value
    (set! failures (+ failures 1))
    (printf "FAIL: ~a\n" label)))

(define prefix "issue=example/ledger#")
(define kinds '("dispatch" "guard"))
(define valid-lines
  '("a.ss alpha dispatch invoke 1 issue=example/ledger#7"
    "b.ss beta guard catch 2 issue=example/ledger#8"))
(define valid (analysis-validate-debt-lines valid-lines kinds prefix))

(check "generic self-test" (analysis-debt-self-test kinds prefix))
(check "two kinds accepted" (= 2 (length (car valid))))
(check "valid rows have no errors" (null? (cdr valid)))
(check "kind parsed" (string=? "guard" (analysis-finding-kind "b.ss beta guard catch 2")))
(check "key excludes count"
       (string=? "b.ss beta guard catch"
                 (analysis-finding-key "b.ss beta guard catch 2")))
(check "count parsed" (= 2 (analysis-finding-count "b.ss beta guard catch 2")))
(check "exact findings clear debt"
       (null? (analysis-debt-problems
                '("a.ss alpha dispatch invoke 1" "b.ss beta guard catch 2") valid)))
(check "new finding fails"
       (pair? (analysis-debt-problems
                '("a.ss alpha dispatch invoke 1"
                  "b.ss beta guard catch 2"
                  "c.ss gamma guard catch 1")
                valid)))
(check "increased finding fails"
       (pair? (analysis-debt-problems
                '("a.ss alpha dispatch invoke 2" "b.ss beta guard catch 2") valid)))
(check "decreased finding fails"
       (pair? (analysis-debt-problems
                '("a.ss alpha dispatch invoke 1" "b.ss beta guard catch 1") valid)))
(check "dropped finding fails"
       (pair? (analysis-debt-problems '("a.ss alpha dispatch invoke 1") valid)))
(check "unknown kind malformed"
       (pair? (cdr (analysis-validate-debt-lines
                     '("a.ss alpha other invoke 1 issue=example/ledger#7") kinds prefix))))
(check "wrong issue prefix malformed"
       (pair? (cdr (analysis-validate-debt-lines
                     '("a.ss alpha dispatch invoke 1 issue=wrong/repo#7") kinds prefix))))
(check "zero issue malformed"
       (pair? (cdr (analysis-validate-debt-lines
                     '("a.ss alpha dispatch invoke 1 issue=example/ledger#0") kinds prefix))))
(check "zero count malformed"
       (pair? (cdr (analysis-validate-debt-lines
                     '("a.ss alpha dispatch invoke 0 issue=example/ledger#7") kinds prefix))))
(check "duplicate key malformed"
       (pair? (cdr (analysis-validate-debt-lines
                     '("a.ss alpha dispatch invoke 1 issue=example/ledger#7"
                       "a.ss alpha dispatch invoke 1 issue=example/ledger#8")
                     kinds prefix))))

(if (= failures 0)
    (begin (printf "STATIC-ANALYSIS-DEBT-TEST OK (~a checks)\n" checks) (exit 0))
    (begin (printf "STATIC-ANALYSIS-DEBT-TEST FAILED (~a/~a)\n" failures checks)
           (exit 1)))
