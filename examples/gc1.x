(define a (cons 2 (list)))
(define waste
    (lambda (lst x y)
        (if (= y 0)
            lst
            (if (> x 5)
                (waste (list) 0 (- y 1))
                (waste (cons x lst) (+ 1 x) y)
            )
        )
    )
)
(waste (list) 0 500000)
