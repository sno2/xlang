(define sizeRec: (List<num> num -> num)
  (lambda (lst: List<num> cnt: num)
    (if (null? lst) cnt (sizeRec (cdr lst) (+ cnt 1)))
  )
)
(define size: (List<num> -> num) (lambda (lst: List<num>) (sizeRec lst 0)))
(let
  (
    (a: List<num> (list: num 1 2 3 4 5 6 7 8 9 10 11 12 13 14))
    (b: List<num> (list: num 1))
    (c: List<num> (list: num 2 3))
  )
  (+
    (size a)
    (size (cdr b))
    (size (cons 1 c))
    (size (list: num 1))
  )
)
