(define a (ref 23))
(define b (deref a))
(define ignoreFirst (lambda (a b) b))
(ignoreFirst (free a) b)
