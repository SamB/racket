#lang racket/base
(require racket/list
         syntax/stx
         unstable/struct
         "minimatch.rkt"
         (except-in syntax/parse/private/residual
                    syntax-patterns-fail)
         "kws.rkt")
(provide syntax-patterns-fail
         current-failure-handler
         maximal-failures

         exn:syntax-parse?
         exn:syntax-parse-info

         invert-ps
         ps->stx+index
         )

#|
TODO: given (expect:thing _ D _ R) and (expect:thing _ D _ #f),
  simplify to (expect:thing _ D _ #f)
  thus, "expected D" rather than "expected D or D for R" (?)
|#

#|
Note: there is a cyclic dependence between residual.rkt and this module,
broken by a lazy-require of this module into residual.rkt
|#

(define ((syntax-patterns-fail stx0) fs)
  (call-with-values (lambda () ((current-failure-handler) stx0 fs))
    (lambda vals
      (error 'current-failure-handler
             "current-failure-handler: did not escape, produced ~e"
             (case (length vals)
               ((1) (car vals))
               (else (cons 'values vals)))))))

(define (default-failure-handler stx0 fs)
  (report-failureset stx0 fs))

(define current-failure-handler
  (make-parameter default-failure-handler))

;; Hack: alternative to new (primitive) phase-crossing exn type is to
;; store extra information in exn continuation marks.

(define (exn:syntax-parse? x)
  (and (exn:fail:syntax? x)
       (pair? (continuation-mark-set-first
               (exn-continuation-marks x)
               'exn:syntax-parse))))

;; exn:syntax-parse-info : exn:syntax-parse -> (cons syntax failureset)
(define (exn:syntax-parse-info x)
  (continuation-mark-set-first (exn-continuation-marks x) 'exn:syntax-parse))

#|
Reporting
---------

First, failures with maximal (normalized) progresses are selected and
grouped into equivalence classes. In principle, each failure in an
equivalence class complains about the same term, but in practice,
special handling of failures like "unexpected term" make things more
complicated.
|#

;; report-failureset : stx FailureSet -> escapes
(define (report-failureset stx0 fs)
  (let* ([classes (maximal-failures fs)]
         [reports (apply append (map report/class classes))])
    (with-continuation-mark 'exn:syntax-parse (cons stx0 fs)
      (raise-syntax-error/reports stx0 reports))))

;; A Report is
;;   - (report string stx)
(define-struct report (message stx) #:prefab)

;; report/class : (non-empty-listof Failure) -> (listof Report)
(define (report/class fs)
  (let* ([ess (map failure-expectstack fs)]
         [ess (map normalize-expectstack ess)]
         [ess (remove-duplicates ess)]
         [ess (simplify-common-expectstacks ess)])
    (let-values ([(stx index) (ps->stx+index (failure-progress (car fs)))])
      (for/list ([es (in-list ess)])
        (report/expectstack es stx index)))))

;; report/expectstack : ExpectStack syntax nat -> Report
(define (report/expectstack es stx index)
  (let ([frame-expect (and (pair? es) (car es))])
    (cond [(not frame-expect)
           (report "bad syntax" #f)]
          [else
           (let ([frame-stx
                  (let-values ([(x cx) (stx-list-drop/cx stx stx index)])
                    (datum->syntax cx x cx))])
             (cond [(equal? frame-expect (expect:atom '() #f))
                    (syntax-case frame-stx ()
                      [(one . more)
                       (report "unexpected term" #'one)]
                      [_
                       (report/expects (list frame-expect) frame-stx)])]
                   [(expect:disj? frame-expect)
                    (report/expects (expect:disj-expects frame-expect) frame-stx)]
                   [else
                    (report/expects (list frame-expect) frame-stx)]))])))

;; report/expects : (listof Expect) syntax -> Report
;; FIXME: partition by role first?
(define (report/expects expects frame-stx)
  (report (join-sep (for/list ([expect expects])
                      (prose-for-expect expect))
                    ";" "or")
          frame-stx))

;; prose-for-expect : Expect -> string
(define (prose-for-expect e)
  (match e
    [(expect:thing stx+index description transparent? role _)
     (if role
         (format "expected ~a for ~a" description role)
         (format "expected ~a" description))]
    [(expect:atom atom _)
     (format "expected the literal ~a~s~a"
             (if (symbol? atom) "symbol `" "")
             atom
             (if (symbol? atom) "'" ""))]
    [(expect:literal literal _)
     (format "expected the identifier `~s'" (syntax-e literal))]
    [(expect:message message _)
     (format "~a" message)]))

;; == Do Report ==

(define (raise-syntax-error/reports stx0 reports)
  (cond [(= (length reports) 1)
         (raise-syntax-error/report stx0 (car reports))]
        [else
         (raise-syntax-error/report* stx0 (car reports))]))

(define (raise-syntax-error/report stx0 report)
  (raise-syntax-error #f (report-message report) stx0 (report-stx report)))

(define (raise-syntax-error/report* stx0 report)
  (let ([message
         (string-append
          "There were multiple syntax errors. The first error follows:\n"
          (report-message report))])
    (raise-syntax-error #f message stx0 (report-stx report))))

;; ====

(define (comma-list items)
  (join-sep items "," "or"))

(define (improper-stx->list stx)
  (syntax-case stx ()
    [(a . b) (cons #'a (improper-stx->list #'b))]
    [() null]
    [rest (list #'rest)]))


;; ==== Failure analysis ====

;; == Failure simplification ==

;; maximal-failures : FailureSet -> (listof (listof Failure))
(define (maximal-failures fs)
  (define ann-failures
    (for/list ([f (in-list (flatten fs))])
      (cons f (invert-ps (failure-progress f)))))
  (maximal/progress ann-failures))

;; == Expectation simplification ==

;; normalize-expectstack : ExpectStack(parsing) -> ExpectStack(reporting)
;; Converts internal-chaining to list, converts expect:thing term rep,
;; and truncates expectstack after opaque (ie, transparent=#f) frames.
(define (normalize-expectstack es [truncate-opaque? #t])
  (define (convert-ps ps)
    (let-values ([(stx index) (ps->stx+index ps)])
      (cons stx index)))
  (let/ec return
    (let loop ([es es])
      (match es
        ['#f '()]
        [(expect:thing ps desc tr? role rest-es)
         (cond [(and truncate-opaque? (not tr?))
                ;; Tricky! If multiple opaque frames, multiple 'return' calls,
                ;; but innermost one called first, so jumps past the rest.
                ;; Also, flip opaque to transparent for sake of equality.
                (return
                 (cons (expect:thing (convert-ps ps) desc #t role #f) (loop rest-es)))]
               [else
                (cons (expect:thing (convert-ps ps) desc tr? role #f) (loop rest-es))])]
        [(expect:message message rest-es)
         (cons (expect:message message #f) (loop rest-es))]
        [(expect:atom atom rest-es)
         (cons (expect:atom atom #f) (loop rest-es))]
        [(expect:literal literal rest-es)
         (cons (expect:literal literal #f) (loop rest-es))]))))

#|
Simplification dilemma

What if we have (e1 e2) and (e2)? How do we report that?
Options:
  1) consider them separate
  2) simplify to (e2), drop e1

Big problem with Option 1:
  eg (x:id ...) matching #'1 yields
  (union (failure #:progress () #:expectstack ())
         (failure #:progress () #:expectstack (#s(expect:atom ()))))
but we don't want to see "expected ()"

So we go with option 2.
|#

;; simplify-common-expectstacks : (listof ExpectStack) -> (listof ExpectStack)
(define (simplify-common-expectstacks ess)
  ;; simplify : (listof ReversedExpectStack) -> (listof ReversedExpectStack)
  (define (simplify ress)
    (let ([ress-partitions (partition/car ress)])
      (if ress-partitions
          (apply append
                 (for/list ([ress-partition (in-list ress-partitions)])
                   (let ([proto-frame (car (car ress-partition))]
                         [cdr-ress (map cdr ress-partition)])
                     (map (lambda (res) (cons proto-frame res))
                          (simplify/check-leafs cdr-ress)))))
          (list null))))
  ;; simplify/check-leafs : (listof ReversedExpectStack) -> (listof ReversedExpectStack)
  (define (simplify/check-leafs ress)
    (let ([ress (simplify ress)])
      (cond [(andmap singleton? ress)
             (let* ([frames (map car ress)])
               (list (list (if (singleton? frames)
                               (car frames)
                               (expect:disj frames #f)))))]
            [else ress])))
  ;; singleton? : list -> boolean
  (define (singleton? res)
    (and (pair? res) (null? (cdr res))))
  (map reverse (simplify/check-leafs (map reverse ess))))

;; partition/car : (listof list) -> (listof (listof list))/#f
;; Returns #f if any of lists is empty.
(define (partition/car lists)
  (and (andmap pair? lists)
       (partition/equal? lists car)))

(define (partition/equal? items key)
  (let ([r-keys null] ;; mutated
        [key-t (make-hash)])
    (for ([item (in-list items)])
      (let ([k (key item)])
        (let ([entry (hash-ref key-t k null)])
          (when (null? entry)
            (set! r-keys (cons k r-keys)))
          (hash-set! key-t k (cons item entry)))))
    (let loop ([r-keys r-keys] [acc null])
      (cond [(null? r-keys) acc]
            [else
             (loop (cdr r-keys)
                   (cons (reverse (hash-ref key-t (car r-keys)))
                         acc))]))))


;; ==== Progress

#|
Progress ordering
-----------------

Lexicographic generalization of partial order on frames
  CAR < CDR < POST, stx incomparable except to self

Progress equality
-----------------

If ps1 = ps2 then both must "blame" the same term,
ie (ps->stx+index ps1) = (ps->stx+index ps2).
|#

;; An Inverted PS (IPS) is a PS inverted for easy comparison.
;; An IPS may not contain any 'opaque frames.

;; invert-ps : PS -> IPS
(define (invert-ps ps)
  (reverse (ps-truncate-opaque ps)))

;; ps-truncate-opaque : PS -> PS
(define (ps-truncate-opaque ps)
  (let/ec return
    (let loop ([ps ps])
      (cond [(null? ps)
             null]
            [(eq? (car ps) 'opaque)
             ;; Tricky! We only jump after loop returns,
             ;; so jump closest to end wins.
             (return (loop (cdr ps)))]
            [else
             ;; Either (loop _) jumps, or it is identity
             (loop (cdr ps))
             ps]))))

;; maximal/progress : (listof (cons A IPS)) -> (listof (listof A))
;; Returns a list of equivalence sets.
(define (maximal/progress items)
  (cond [(null? items)
         null]
        [(null? (cdr items))
         (list (list (car (car items))))]
        [else
         (let-values ([(rNULL rCAR rCDR rPOST rSTX leastCDR)
                       (partition/pf items)])
           (append (maximal/pf rNULL rCAR rCDR rPOST leastCDR)
                   (if (pair? rSTX)
                       (maximal/stx rSTX)
                       null)))]))

;; partition/pf : (listof (cons A IPS)) -> (listof (cons A IPS))^5 & nat/+inf.0
(define (partition/pf items)
  (let ([rNULL null]
        [rCAR null]
        [rCDR null]
        [rPOST null]
        [rSTX null]
        [leastCDR #f])
    (for ([a+ips (in-list items)])
      (let ([ips (cdr a+ips)])
        (cond [(null? ips)
               (set! rNULL (cons a+ips rNULL))]
              [(eq? (car ips) 'car)
               (set! rCAR (cons a+ips rCAR))]
              [(exact-positive-integer? (car ips))
               (set! rCDR (cons a+ips rCDR))
               (set! leastCDR
                     (if leastCDR
                         (min leastCDR (car ips))
                         (car ips)))]
              [(eq? (car ips) 'post)
               (set! rPOST (cons a+ips rPOST))]
              [(syntax? (car ips))
               (set! rSTX (cons a+ips rSTX))]
              [else
               (error 'syntax-parse "INTERNAL ERROR in partition/pf: ~e" ips)])))
    (values rNULL rCAR rCDR rPOST rSTX leastCDR)))

;; maximal/pf : (listof (cons A IPS))^4 & nat/+inf.0-> (listof (listof A))
(define (maximal/pf rNULL rCAR rCDR rPOST leastCDR)
  (cond [(pair? rPOST)
         (maximal/progress (rmap pop-item-ips rPOST))]
        [(pair? rCDR)
         (maximal/progress
          (rmap (lambda (a+ips)
                  (let ([a (car a+ips)] [ips (cdr a+ips)])
                    (cond [(= (car ips) leastCDR)
                           (cons a (cdr ips))]
                          [else
                           (cons a (cons (- (car ips) leastCDR) (cdr ips)))])))
                rCDR))]
        [(pair? rCAR)
         (maximal/progress (rmap pop-item-ips rCAR))]
        [(pair? rNULL)
         (list (map car rNULL))]
        [else
         null]))

;; maximal/stx : (listof (cons A IPS)) -> (listof (listof A))
(define (maximal/stx rSTX)
  (let ([stxs null]
        [table (make-hasheq)])
    (for ([a+ips (in-list rSTX)])
      (let* ([ips (cdr a+ips)]
             [entry (hash-ref table (car ips) null)])
        (when (null? entry)
          (set! stxs (cons (car ips) stxs)))
        (hash-set! table (car ips) (cons a+ips entry))))
    (apply append
           (map (lambda (key)
                  (maximal/progress (map pop-item-ips (hash-ref table key))))
                stxs))))

;; pop-item-ips : (cons A IPS) -> (cons A IPS)
(define (pop-item-ips a+ips)
  (let ([a (car a+ips)]
        [ips (cdr a+ips)])
    (cons a (cdr ips))))

;; ps->stx+index : Progress -> (values stx nat)
;; Gets the innermost stx that should have a real srcloc, and the offset
;; (number of cdrs) within that where the progress ends.
(define (ps->stx+index ps)
  (define (interp ps)
    (match ps
      [(cons (? syntax? stx) _) stx]
      [(cons 'car parent)
       (let* ([d (interp parent)]
              [d (if (syntax? d) (syntax-e d) d)])
         (cond [(pair? d) (car d)]
               [(vector? d) (vector->list d)]
               [(box? d) (unbox d)]
               [(prefab-struct-key d) (struct->list d)]
               [else (error 'ps->stx+index "INTERNAL ERROR: unexpected: ~e" d)]))]
      [(cons (? exact-positive-integer? n) parent)
       (for/fold ([stx (interp parent)]) ([i (in-range n)])
         (stx-cdr stx))]
      [(cons 'post parent)
       (interp parent)]))
  (let ([ps (ps-truncate-opaque ps)])
    (match ps
      [(cons (? syntax? stx) _)
       (values stx 0)]
      [(cons 'car parent)
       (values (interp ps) 0)]
      [(cons (? exact-positive-integer? n) parent)
       (values (interp parent) n)]
      [(cons 'post parent)
       (ps->stx+index parent)])))

(define (rmap f xs)
  (let rmaploop ([xs xs] [accum null])
    (cond [(pair? xs)
           (rmaploop (cdr xs) (cons (f (car xs)) accum))]
          [else
           accum])))


;; ==== Debugging

(provide failureset->sexpr
         failure->sexpr
         expectstack->sexpr
         expect->sexpr)

(define (failureset->sexpr fs)
  (let ([fs (flatten fs)])
    (case (length fs)
      ((1) (failure->sexpr (car fs)))
      (else `(union ,@(map failure->sexpr fs))))))

(define (failure->sexpr f)
  (match f
    [(failure progress expectstack)
     `(failure ,(progress->sexpr progress)
               #:expected ,(expectstack->sexpr expectstack))]))

(define (expectstack->sexpr es)
  (map expect->sexpr (normalize-expectstack es #f)))

(define (expect->sexpr e)
  (match e
    [(expect:thing stx+index description transparent? role _)
     (expect:thing '<Term> description transparent? role '_)]
    [else e]))

(define (progress->sexpr ps)
  (for/list ([pf (in-list (reverse ps))])
    (match pf
      [(? syntax? stx) 'stx]
      ['car 'car]
      ['post 'post]
      [(? exact-positive-integer? n) n]
      ['opaque 'opaque])))
