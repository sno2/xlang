(let
    ((b: num 41))
    ((if #f
        (lambda () (let ((k: num b)) k))
        (lambda () b))))
