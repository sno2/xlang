(define a (ref 349))
(define leak
    (lambda (lst x)
        (if (> x 100000)
            #t
            (leak (cons 2 lst) (+ x 1))
        )
    )
)
(define _ (leak (list) 0))
(deref a)
