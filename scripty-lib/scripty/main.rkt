#lang racket/base

;; ---------------------------------------------------------------------------------------------------
;; scripty reader

(module reader syntax/module-reader scripty
  #:read                scripty:read
  #:read-syntax         scripty:read-syntax
  #:whole-body-readers? #t

  (require racket/format
           racket/function
           racket/string
           syntax/modread
           syntax/readerr)
  
  (define (scripty:read in)
    (map syntax->datum (scripty:read-syntax #f in)))

  (define (scripty:read-syntax src-name in)
    (let*-values ([(line col pos) (port-next-location in)]
                  ; read lines until the --- preamble divider
                  [(preamble-str) (let loop ()
                                    (let ([line (read-line in)])
                                      (cond [(eof-object? line)
                                             (define-values [line col pos] (port-next-location in))
                                             (raise-read-error
                                              (~a "script preamble: expected an end to the preamble, "
                                                  "marked by a line made up of three or more "
                                                  "consecutive hyphens")
                                              src-name line col pos 1)]
                                            [(regexp-match? #px"^-{3,}$" line) '()]
                                            [else (cons line (loop))])))]
                  [(preamble-in) (open-input-string (string-join preamble-str "\n"))])
      ; read the preamble using the Racket reader
      (port-count-lines! preamble-in)
      (set-port-next-location! preamble-in line col pos)
      (define preamble-stxs
        (let loop ()
          (let ([result (read-syntax src-name preamble-in)])
            (if (eof-object? result) '()
                (cons result (loop))))))

      ; defer to the rest of the module to figure out how to read it properly
      (define body-stx
        (with-module-reading-parameterization
          (thunk (read-syntax src-name in))))
      (define checked-body-stx (check-module-form body-stx 'ignored #f))
      ; ensure what we get back is actually a module
      (unless checked-body-stx
        (raise-syntax-error '|script body|
                            (~a "only a module declaration is allowed, either #lang <language-name> "
                                " or (module <name> <language> ...)")
                            body-stx))

      ; return the preamble and body module
      (list preamble-stxs checked-body-stx))))

;; ---------------------------------------------------------------------------------------------------
;; scripty module language

(require racket/require)

(require (for-syntax (multi-in racket [base file format function match path string])
                     pkg/lib
                     setup/setup)
         syntax/parse/define)

(provide (for-syntax (all-from-out racket/base))
         (rename-out [scripty:#%module-begin #%module-begin])
         (except-out (all-from-out racket/base) #%module-begin))

(define-syntax-parser scripty:#%module-begin
  [(_ ({~or {~once {~seq #:dependencies dependencies:expr}}} ...)
      {~and script-module ({~datum module} _ mod-language . mod-body)})
   #:do [(define source-path (syntax-source #'script-module))]
   #:with pkg-name (string-replace (path->string (file-name-from-path source-path))
                                   #px"[^a-zA-Z0-9_-]" "-")
   #'(#%module-begin
      (begin-for-syntax
        (when (and (terminal-port? (current-output-port))
                   (terminal-port? (current-input-port)))
          (perform-installation! #:name 'pkg-name #:deps dependencies)))
      (module main mod-language . mod-body))])

(begin-for-syntax
  (define (create-tmp-pkg name #:deps deps)
    (let ([pkg-dir (make-temporary-file (~a name "~a") 'directory)])
      (parameterize ([current-directory pkg-dir])
        (with-output-to-file "info.rkt"
          (thunk (displayln "#lang info")
                 (writeln `(define deps ',deps)))))
      pkg-dir))

  (define (perform-installation! #:name name #:deps deps)
    (parameterize ([current-pkg-scope (default-pkg-scope)])
      (with-pkg-lock
          (let* ([tmp-pkg-dir (create-tmp-pkg name #:deps deps)]
                 [install-result (pkg-install (list (pkg-desc (path->string tmp-pkg-dir)
                                                              'link name #f #t))
                                              #:dep-behavior 'search-ask)]
                 [remove-result (pkg-remove (list name) #:quiet? #t)]
                 [collections (match* (install-result remove-result)
                                [(#f #f) #f]
                                [({or {and 'skip {app (const '()) collects-a}} collects-a}
                                  {or {and 'skip {app (const '()) collects-b}} collects-b})
                                 (filter
                                  (λ (x) (not (equal? x (list name))))
                                  (append (map (λ (x) (if (list? x) x (list x))) collects-a)
                                          (map (λ (x) (if (list? x) x (list x))) collects-b)))])])
            (unless (null? collections)
              (setup #:fail-fast? #t
                     #:collections collections)
              (newline)))))))
