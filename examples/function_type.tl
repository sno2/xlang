(define add: (num num -> num) (lambda (a: num b: num) (+ a b)))
(let ((b: (num num -> num) add)) (b 2 3))
