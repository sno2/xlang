(define append
  (lambda (lst1 lst2)
    (if (null? lst1)
        lst2
        (cons (car lst1) 
              (append (cdr lst1) lst2)))))
(append (list 1 2 3 4 5 6 7 8) (list 9 10 11 12 13 14 15 16 17 18))
