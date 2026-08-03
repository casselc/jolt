;; Cross-target path classification and project resolution. This is pure string
;; algebra: Windows witnesses need no Windows host or mounted network share.
;;
;; Run:
;;   chez --script test/chez/path-contract-test.ss

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "FAIL: ~a~n" name)))

(define (posix? path) (jolt-path-absolute-for? #f path))
(define (windows? path) (jolt-path-absolute-for? #t path))
(define (posix-rooted? path) (jolt-path-rooted-for? #f path))
(define (windows-rooted? path) (jolt-path-rooted-for? #t path))

(ok "POSIX slash-rooted path" (posix? "/tmp/out"))
(ok "POSIX relative path" (not (posix? "tmp/out")))
(ok "POSIX does not reinterpret a drive-rooted path"
    (not (posix? "C:/tmp/out")))
(ok "Windows slash-rooted path is not Java-absolute"
    (not (windows? "/tmp/out")))
(ok "Windows backslash-rooted path is not Java-absolute"
    (not (windows? "\\tmp\\out")))
(ok "Windows drive with slash" (windows? "C:/tmp/out"))
(ok "Windows drive with backslash" (windows? "d:\\tmp\\out"))
(ok "Windows UNC path" (windows? "\\\\server\\share\\out.exe"))
(ok "Windows slash UNC path" (windows? "//server/share/out.exe"))
(ok "Windows drive-relative path remains relative"
    (not (windows? "C:tmp/out")))
(ok "Windows bare drive remains relative" (not (windows? "C:")))
(ok "drive designator must be ASCII alphabetic"
    (not (windows? "1:/tmp/out")))
(ok "empty path is relative" (not (windows? "")))
(ok "POSIX rooted policy equals POSIX absolute policy"
    (and (posix-rooted? "/tmp/out")
         (not (posix-rooted? "tmp/out"))
         (not (posix-rooted? "C:/tmp/out"))))
(ok "Windows project roots include both drive-less root forms"
    (and (windows-rooted? "/tmp/out")
         (windows-rooted? "\\tmp\\out")
         (windows-rooted? "C:/tmp/out")
         (windows-rooted? "\\\\server\\share\\out.exe")))
(ok "Windows project roots exclude drive-relative paths"
    (and (not (windows-rooted? "C:tmp/out"))
         (not (windows-rooted? "C:"))))
(ok "native predicate uses the running target descriptor"
    (equal? (jolt-path-absolute? "C:/tmp/out")
            (jolt-path-absolute-for? target-windows-paths? "C:/tmp/out")))

(ok "POSIX absolute project path passes through"
    (string=? (jolt-resolve-project-path-for #f "/project" "/out/app")
              "/out/app"))
(ok "POSIX relative project path joins the project"
    (string=? (jolt-resolve-project-path-for #f "/project" "out/app")
              "/project/out/app"))
(ok "an empty project base does not add a dot-slash prefix"
    (string=? (jolt-resolve-project-path-for #f "" "out/app") "out/app"))
(ok "Windows drive-absolute project path passes through"
    (and (string=? (jolt-resolve-project-path-for #t "D:/project" "C:/out/app")
                   "C:/out/app")
         (string=? (jolt-resolve-project-path-for #t "D:\\project" "C:\\out\\app")
                   "C:\\out\\app")))
(ok "Windows UNC project path passes through"
    (string=? (jolt-resolve-project-path-for
                #t "D:\\project" "\\\\server\\share\\app")
              "\\\\server\\share\\app"))
(ok "Windows slash root-relative path inherits the project drive"
    (string=? (jolt-resolve-project-path-for #t "D:/project" "/out/app")
              "D:/out/app"))
(ok "Windows backslash root-relative path inherits the project drive"
    (string=? (jolt-resolve-project-path-for #t "d:\\project" "\\out\\app")
              "d:\\out\\app"))
(ok "Windows ordinary relative path joins the project"
    (string=? (jolt-resolve-project-path-for #t "D:\\project" "out\\app")
              "D:\\project/out\\app"))
(ok "Windows drive-relative project path fails closed"
    (and (not (jolt-resolve-project-path-for #t "D:\\project" "C:out\\app"))
         (not (jolt-resolve-project-path-for #t "D:\\project" "C:"))))
(ok "Windows root-relative path needs a drive-qualified project"
    (not (jolt-resolve-project-path-for
           #t "\\\\server\\share\\project" "\\out\\app")))

(define native-project
  (if target-windows-paths? "D:\\jolt-path-contract" "/jolt-path-contract"))
(define native-absolute
  (if target-windows-paths? "C:\\already\\absolute" "/already/absolute"))
(define native-leaf
  (if target-windows-paths? "D:\\project\\leaf" "/project/leaf"))
(define native-parent
  (if target-windows-paths? "D:\\project" "/project"))
(ok "native File segment parsing recognizes only native separators"
    (and (string=? (path-last-segment native-leaf) "leaf")
         (string=? (jolt-path-parent-string native-leaf) native-parent)
         (or target-windows-paths?
             (string=? (path-last-segment "acme\\tools") "acme\\tools"))))
(ok "native File separator constants use the target descriptor"
    (and (string=? target-file-separator
                   (host-static-ref "java.io.File" "separator"))
         (string=? target-path-separator
                   (host-static-ref "java.io.File" "pathSeparator"))))
(putenv "JOLT_PWD" native-project)
(ok "relative paths still resolve against JOLT_PWD"
    (string=? (project-relative "build/out")
              (string-append native-project "/build/out")))
(ok "empty File absolute path still resolves to JOLT_PWD"
    (string=? (jfile-abs "") native-project))
(ok "absolute File path still bypasses JOLT_PWD"
    (string=? (jfile-abs native-absolute) native-absolute))
(ok "File.isAbsolute classifies drive-relative syntax without resolving it"
    (equal? (jfile-method (make-jfile "C:relative") "isAbsolute" '())
            (list #f)))
(putenv "JOLT_PWD" ".")
(ok "dot user.dir preserves a bare relative path"
    (string=? (project-relative "build/out") "build/out"))

(printf "path-contract-test: ~a/~a passed~n" (- total fails) total)
(exit (if (> fails 0) 1 0))
