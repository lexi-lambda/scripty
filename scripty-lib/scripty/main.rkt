#lang racket/base

;; ---------------------------------------------------------------------------------------------------
;; scripty reader

(module reader racket/base
  (provide (rename-out [scripty:read read]
                       [scripty:read-syntax read-syntax]
                       [racket:get-info get-info]))

  (require racket/require
           (multi-in racket [file format function match path string])
           (multi-in syntax [modread parse readerr])
           (prefix-in racket: (submod racket reader))
           pkg/lib
           setup/setup)
  
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

      ; install provided dependencies (we need to do this at read-time in order to install
      ; dependencies that are needed by custom #langs)
      (syntax-parse preamble-stxs
        #:context '|script prelude|
        [({~or {~once {~seq #:dependencies dependencies:expr}}} ...)
         (when (and (terminal-port? (current-output-port))
                    (terminal-port? (current-input-port)))
           (let* ([ns (make-base-namespace)]
                  [deps-val (eval #'dependencies ns)]
                  [pkg-name (string-replace (path->string (file-name-from-path src-name))
                                            #px"[^a-zA-Z0-9_-]" "-")])
             (perform-installation! #:name pkg-name #:deps deps-val)))])

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

      ; return the body module
      checked-body-stx))

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
