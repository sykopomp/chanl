;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10; indent-tabs-mode: nil -*-
;;;;
;;;; Copyright © 2009 Josh Marchan, Adlai Chandrasekhar
;;;;
;;;; Thread Abstraction
;;;;
;;;; The thread pool here is taken directly from Eager Future. See COPYRIGHT for relevant info.
;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(in-package :chanl)

;;;
;;; Thread pool
;;;
(defclass thread-pool ()
  ((threads :accessor pool-threads :initform nil)
   (free-thread-counter :accessor free-thread-counter :initform 0)
   (soft-limit :accessor pool-soft-limit :initform 1000) ; this seems like a sane-ish default
   (lock :reader pool-lock :initform (bt:make-lock "thread pool lock"))
   (leader-lock :reader pool-leader-lock :initform (bt:make-lock "thread leader lock"))
   (leader-notifier :reader pool-leader-notifier :initform (bt:make-condition-variable))
   (tasks :accessor pool-tasks :initform nil)))

(defvar *thread-pool* (make-instance 'thread-pool))

(define-symbol-macro %thread-pool-soft-limit (pool-soft-limit *thread-pool*))

(defun pooled-threads ()
  (pool-threads *thread-pool*))

(defun new-worker-thread (thread-pool &optional task)
  (push (bt:make-thread
         (lambda ()
           (unwind-protect
                (loop (when task (funcall task))
                   (bt:with-lock-held ((pool-lock thread-pool))
                     (if (and (pool-soft-limit thread-pool)
                              (> (length (pool-threads thread-pool))
                                 (pool-soft-limit thread-pool)))
                         (return)
                         (incf (free-thread-counter thread-pool))))
                   (bt:with-lock-held ((pool-leader-lock thread-pool))
                     (bt:with-lock-held ((pool-lock thread-pool))
                       (setf task
                             (loop until (pool-tasks thread-pool)
                                do (bt:condition-wait (pool-leader-notifier thread-pool)
                                                      (pool-lock thread-pool))
                                finally (return (pop (pool-tasks thread-pool)))))
                       (decf (free-thread-counter thread-pool)))))
             (bt:with-lock-held ((pool-lock thread-pool))
               (setf (pool-threads thread-pool)
                     (delete (bt:current-thread) (pool-threads thread-pool))))))
         :name "ChanL Thread Pool Worker")
        (pool-threads thread-pool)))

(defgeneric assign-task (task thread-pool)
  (:method (task (thread-pool thread-pool))
    (bt:with-lock-held ((pool-lock thread-pool))
      (if (= (free-thread-counter thread-pool) (length (pool-tasks thread-pool)))
          (new-worker-thread thread-pool task)
          (setf (pool-tasks thread-pool)
                (nconc (pool-tasks thread-pool) (list task)))))
    (bt:condition-notify (pool-leader-notifier thread-pool))))

;;;
;;; Threads
;;;
;;; - The reason we're basically just wrapping BT functions with the same names is that it might
;;;   be good to eventually get rid of the BT dependency.
(defun current-thread ()
  (bt:current-thread))

(defun thread-alive-p (proc)
  (bt:thread-alive-p proc))

(defun threadp (proc)
  (bt:threadp proc))

(defun thread-name (proc)
  (bt:thread-name proc))

(defun kill (proc)
  (bt:destroy-thread proc))

(defun all-threads ()
  (bt:all-threads))

(defun pcall (function &key (initial-bindings *default-special-bindings*))
  "PCALL -> Parallel Call; calls FUNCTION in a new thread. FUNCTION must be a no-argument function.
INITIAL-BINDINGS, if provided, should be an alist representing dynamic variable bindings that BODY
is to be executed with. The format is: '((*var* value))."
  (let ((fun
          (lambda () (let (vars bindings)
                       (loop for (var binding) in initial-bindings
                          collect var into the-vars
                          collect binding into the-bindings
                          finally (setf vars the-vars bindings the-bindings))
                       (progv vars bindings
                         (funcall function))))))
    (assign-task fun *thread-pool*))
  t)

(defmacro pexec ((&key initial-bindings) &body body)
  "Executes BODY in parallel. INITIAL-BINDINGS, if provided, should be an alist representing
dynamic variable bindings that BODY is to be executed with. The format is: '((*var* value))."
  `(pcall (lambda () ,@body)
          ,@(when initial-bindings `(:initial-bindings ,initial-bindings))))
