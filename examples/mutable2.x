(define x 10)
(define g 
  (lambda (y)
    (lambda (z)
      (+ x y z))))
(define x 5)
(define f 
  (lambda (a)
    (lambda (b)
      (let ((x 2))
        (+ x a b)))))
(define x 3)
(define h
  (lambda ()
    (let ((x 7))
      (f 4))))
(*
  ((g 3) 7)
  ((h) 5)
)
