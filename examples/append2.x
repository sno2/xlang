(define appendRec
  (lambda (lst1 lst2 acc)
    (if (null? lst1)
        (appendAcc acc lst2) 
        (appendRec (cdr lst1) lst2 (cons (car lst1) acc))))) 
(define appendAcc
  (lambda (acc lst2)
    (if (null? acc)
        lst2
        (appendAcc (cdr acc) (cons (car acc) lst2)))))  
(define append
  (lambda (lst1 lst2)
    (appendRec lst1 lst2 (list))))  
(append (list 1 2 3 4 5 6 7 8) (list 9 10 11 12 13 14 15 16 17 18))
