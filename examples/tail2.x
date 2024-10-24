(define count
  (lambda (x target)
    (if (< x target)
      (count (+ x 1) target)
      x
    )
  )
)
(count 0 125445)
