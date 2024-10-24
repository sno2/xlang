(define f (lambda (a b)
    (lambda (x y) (+ (+ a x) (+ y b)))
))
((f 2 9) 5 3)
