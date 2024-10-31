(define a: num 23)
(define b: (-> num) (lambda () a))
(define a: bool #t)
(if a (b) 0)
