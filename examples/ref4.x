(let ((a (ref 1)))
    ((lambda (a b) b) (set! a 2) (deref a))
)
