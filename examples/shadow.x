(let ((a 2))
    (+ a (let ((a 4))
        (+ a (let ((a 6))
            a
        ))
    ))
)
