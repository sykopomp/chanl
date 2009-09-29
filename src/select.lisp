;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10; indent-tabs-mode: nil -*-
;;;;
;;;; Copyright © 2009 Kat Marchan, Adlai Chandrasekhar
;;;;
;;;; Selection Interface -- Never block!
;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(in-package :chanl)

;;;
;;; Select macro
;;;
(defmacro select (&body body)
  "Non-deterministically select a non-blocking clause to execute.

The syntax is:

   select clause*
   clause ::= (op form*)
   op ::= (recv c &optional variable channel-var) | (send c value &optional channel-var)
          | else | otherwise | t
   c ::= An evaluated form representing a channel, or a sequence of channels.
   variable ::= an unevaluated symbol RECV's return value is to be bound to. Made available to form*.
   value ::= An evaluated form representing a value to send into the channel.
   channel-var ::= An unevaluated symbol that will be bound to the channel the SEND/RECV
                   operation succeeded on.

SELECT will first attempt to find a clause with a non-blocking op, and execute it. Execution of the
check-if-blocks-and-do-it part is atomic, but execution of the clause's body once the SEND/RECV
clause executes is NOT atomic. If all channel clauses would block, and no else clause is provided,
SELECT will block until one of the clauses is available for execution.

SELECT's non-determinism is, in fact, very non-deterministic. Clauses are chosen at random, not
in the order they are written. It's worth noting that SEND/RECV, when used on sequences of
channels, are still linear in the way they go through the sequence -- the random selection is
reserved for individual SELECT clauses."
  `(select-from-clauses
    (list ,@(loop for clause in body
               collect (clause->make-clause-object clause)))))

(defun determine-op (clause)
  (cond ((and (not (listp (car clause)))
              (or (eq t (car clause))
                  (equal "ELSE" (symbol-name (car clause)))
                  (equal "OTHERWISE" (symbol-name (car clause)))))
         :else)
        ((listp (car clause))
         (let ((clause-name (symbol-name (caar clause))))
           (cond ((string= clause-name "SEND") :send)
                 ((string= clause-name "RECV") :recv)
                 (t (error "Invalid clause type ~A" (car clause))))))
        (t (error "Invalid clause type ~A" (car clause)))))

(defstruct (clause (:constructor make-clause (op try-fun body-fun)))
  op try-fun body-fun)

(defun clause->make-clause-object (clause)
  (let ((op (determine-op clause)))
    (multiple-value-bind (try-fun body-fun)
        (parse-clause op clause)
      `(make-clause-object ,op ,try-fun ,body-fun))))

(defun select-from-clauses (clauses)
  ;; todo
  )

(defun try-clause (clause)
  ;; NO IDEA
  (case (clause-op clause)
    (:else
     (clause-body-fun clause))
    (:send
     (let ((chan (funcall (clause-try-fun clause))))
       (when chan
         (funcall (clause-body-fun )))))))

(defun parse-clause (op clause)
  (let (channel attempt-fun body)
    ;; what should these even look like? How do we make send/recv's return values available to
    ;; the clause body even though we don't want to run the body unless we get a sensible value?...
    (case op
      (:else
       (setf body (cdr clause)))
      (:send
       (destructuring-bind (chan value &optional channel-var)
           (cdr clause)
         (setf attempt-fun `(lambda () (send ,chan ,value nil)))
         (setf body (if channel-var
                        `(let ((,channel-var (funcall ,attempt-fun))))))
         )
       (setf channel (cadar clause))
       (setf body clause))
      (:recv
       (setf channel (cadar clause))
       (setf body (if (= 3 (length (car clause)))
                      `((let ((,(third (car clause)) ,(butlast (car clause))))
                          ,@(cdr clause)))
                      clause))))
    (values attempt-fun `(lambda () ,@body))))
