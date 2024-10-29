(define append
  (lambda (lst1 lst2)
    (if (null? lst1)
        lst2
        (cons (car lst1) 
              (append (cdr lst1) lst2)))))
(define fibonacci
  (lambda (n)
    (fibonacciRec 0 1 n (list))))
(define fibonacciRec
      (lambda (a b count result)
        (if (= count 0)
            result
            (fibonacciRec b (+ a b) (- count 1) (append result (list a))))))
(fibonacci 36)
