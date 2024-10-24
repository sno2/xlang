(define pair2
    (lambda (a b)
        (lambda (op)
            (if (= op 0)
                a
                b
            )
        )
    )
)
(define x (pair2 5 5))
(define y (pair2 1 1))
(+ (x 0) (y 0))
