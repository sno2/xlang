(define a: bool #t)
(define a: (-> num) (lambda () (if (< 99 0) (a) 0)))
(a)
