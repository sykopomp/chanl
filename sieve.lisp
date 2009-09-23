;; The infamous parallel prime sieve from newsqueak

(in-package :chanl)

(defun counter (channel)
  (loop for i from 2 do (send channel i)))

(defun filter (prime in out)
  (loop for i = (recv in)
     when (plusp (mod i prime))
     do (send out i)))

(defun sieve ()
  (let* ((c (chan))
         (prime-chan (chan)))
    (spawn (counter c))
    (spawn (loop
              (let* ((prime (recv c))
                     (newc (chan)))
                (send prime-chan prime)
                (let ((c* c))
                  (spawn (filter prime c* newc)))
                (setf c newc))))
    prime-chan))

(defun first-n-primes (n &optional (cleanupp t))
  (let* ((procs (all-procs))
         (prime-chan (sieve)))
    (unwind-protect (loop repeat n collect (recv prime-chan))
      (when cleanupp
        (map nil 'kill (set-difference (all-procs) procs))))))
