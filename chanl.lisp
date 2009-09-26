;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10; indent-tabs-mode: nil -*-
;;;;
;;;; Copyright © 2009 Kat Marchan
;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defpackage :chanl
  (:use :common-lisp)
  (:import-from :bordeaux-threads :*default-special-bindings*)
  (:export
   ;; processes
   #:pcall #:pexec #:kill #:current-proc
   #:proc-alive-p #:procp #:proc-name
   #:*default-special-bindings* #:all-procs
   ;; channels
   #:make-channel #:send #:recv
   #:channel #:send-blocks-p #:recv-blocks-p
   ;; selecting!
   #:select #:send-select #:recv-select))

(in-package :chanl)

;;;
;;; Utils
;;;
(defmacro fun (&body body)
  "This macro puts the FUN back in FUNCTION."
  `(lambda (&optional _) (declare (ignorable _)) ,@body))

;;; Queue
(defstruct (queue (:predicate queuep)
                  (:constructor make-queue (size)))
  head tail size)

(defun queue-peek (queue)
  (car (queue-head queue)))

(defun queue-empty-p (queue)
  (null (queue-head queue)))

(defun queue-full-p (queue)
  (= (length (queue-head queue))
     (queue-size queue)))

(defun queue-count (queue)
  (length (queue-head queue)))

(defun enqueue (object queue)
  (let ((tail-cons (list object)))
    (setf (queue-head queue)
          (nconc (queue-head queue) tail-cons))
    (setf (queue-tail queue) tail-cons)
    object))

(defun dequeue (queue)
  (prog1
      (pop (queue-head queue))
    (when (null (queue-head queue))
      (setf (queue-tail queue) nil))))

;;;
;;; Threads
;;;
(defun current-proc ()
  (bt:current-thread))

(defun proc-alive-p (proc)
  (bt:thread-alive-p proc))

(defun procp (proc)
  (bt:threadp proc))

(defun proc-name (proc)
  (bt:thread-name proc))

(defun kill (proc)
  (bt:destroy-thread proc))

(defun pcall (function &key name (initial-bindings *default-special-bindings*))
  "PCALL -> Parallel Call; calls FUNCTION in a new thread. FUNCTION must be a no-argument
function. Providing NAME will set the thread's name. Refer to Bordeaux-threads documentation
for how INITIAL-BINDINGS works."
  (bt:make-thread function :name name :initial-bindings initial-bindings))

(defmacro pexec ((&key name initial-bindings) &body body)
  "Executes BODY in parallel (a new thread). NAME sets new thread's name. Refer to
Bordeaux-Threads documentation for more information on INITIAL-BINDINGS."
  `(pcall (lambda () ,@body)
          ,@(when name `(:name ,name))
          ,@(when initial-bindings `(:initial-bindings ,initial-bindings))))

(defun all-procs ()
  (bt:all-threads))

;;;
;;; Channels
;;;
(defstruct (channel (:constructor make-channel (&optional buffer-size))
                    (:predicate channelp)
                    (:print-object
                     (lambda (channel stream)
                       (print-unreadable-object (channel stream :type t :identity t)
                         (if (zerop (channel-buffer-size channel))
                             (format stream "[Unbuffered, ~:[input available~;no input~]]"
                                     (recv-blocks-p channel))
                             (format stream "[Buffered: ~A/~A]"
                                     (queue-count (channel-buffer channel))
                                     (channel-buffer-size channel)))))))
  (buffer (make-queue))
  ;; In order to enforce this at the queue level, we need to get rid of some
  ;; cheating ChanL does in order to get SEND/RECV to cooperate.
  ;; During the blocking SEND/RECV process, channels temporarily have one more
  ;; item in them than buffer-size would usually allow.
  (buffer-size 0 :read-only t)
  (being-read-p nil :type (member t nil))
  (lock (bt:make-lock) :read-only t)
  (send-ok (bt:make-condition-variable) :read-only t)
  (recv-ok (bt:make-condition-variable) :read-only t))

(defun channel-full-p (channel)
  (if (zerop (channel-buffer-size channel))
      t
      (<= (channel-buffer-size channel)
          (queue-count (channel-buffer channel)))))

(defun channel-empty-p (channel)
  (queue-empty-p (channel-buffer channel)))

(defun send-blocks-p (channel)
  "True if trying to send something into the channel would block."
  (bt:with-lock-held ((channel-lock channel))
    (and (channel-full-p channel) (not (channel-being-read-p channel)))))

(defun recv-blocks-p (channel)
  "True if trying to recv from the channel would block."
  (bt:with-lock-held ((channel-lock channel))
    (channel-empty-p channel)))

(defun send (channel obj)
  (with-accessors ((buffer channel-buffer)
                   (chan-full-p channel-full-p)
                   (being-read-p channel-being-read-p)
                   (lock channel-lock)
                   (send-ok channel-send-ok)
                   (recv-ok channel-recv-ok))
      channel
    (bt:with-lock-held (lock)
      (loop
         while (and chan-full-p (not being-read-p))
         do (bt:condition-wait send-ok lock)
         finally (enqueue obj buffer))
      (bt:condition-notify recv-ok)
      obj)))

(defmacro with-read-state ((channel) &body body)
  `(unwind-protect
        (progn (setf (channel-being-read ,channel) t)
               ,@body)
     (setf (channel-being-read ,channel) nil)))

(defun recv (channel)
  (with-accessors ((buffer channel-buffer)
                   (chan-empty-p channel-empty-p)
                   (being-read-p channel-being-read-p)
                   (lock channel-lock)
                   (send-ok channel-send-ok)
                   (recv-ok channel-recv-ok))
      channel
    (bt:with-lock-held (lock)
      (with-read-state (channel)
        (bt:condition-notify send-ok)
        (prog1 (loop
                  while chan-empty-p
                  do (bt:condition-wait recv-ok lock)
                  finally (return (dequeue buffer))))))))

;;;
;;; Selecting channels
;;;
(defun recv-select (channels &optional (else-value nil else-value-p))
  "Selects a single channel from CHANNELS (a sequence) with input available and returns the result
of calling RECV on it. If no channels have available input, blocks until it can RECV from one of
them. If ELSE-VALUE is provided, RECV-SELECT returns that value immediately if no channels are
ready."
  (loop for ready-channel = (find-if-not #'recv-blocks-p channels)
     if ready-channel
     return (recv ready-channel)
     else if else-value-p
     return else-value))

(defun send-select (value channels &optional (else-value nil else-value-p))
  "Selects a single channel from CHANNELS (a sequence) that is ready for input and sends VALUE into it.
If no channels are ready for input, blocks until it can SEND to one of them. If ELSE-VALUE is
provided, SEND-SELECT returns that value immediately if no channels are ready."
  (loop for ready-channel = (find-if-not #'send-blocks-p channels)
     if ready-channel
     return (send ready-channel value)
     else if else-value-p
     return else-value))

;;; Select macro
(defmacro select (&body body)
  "Non-deterministically select a non-blocking clause to execute.

The syntax is:

   select clause*
   clause ::= (op form*)
   op ::= (recv chan variable) | (send chan value)
          | (seq-send (list chan*) value) | (seq-recv (list chan*) variable)
          | else | otherwise | t
   chan ::= An evaluated form representing a channel
   variable ::= an unevaluated symbol RECV's return value is to be bound to. Made available to form*.
   value ::= An evaluated form representing a value to send into the channel.

SELECT will first attempt to find a non-blocking channel clause. If all channel clauses would block,
and no else clause is provided, SELECT will block until one of the clauses is available for
execution."
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
                 ((string= clause-name "SEQ-SEND") :seq-send)
                 ((string= clause-name "SEQ-RECV") :seq-recv)
                 (t (error "Invalid clause type ~A" (car clause))))))
        (t (error "Invalid clause type ~A" (car clause)))))

(defun clause->make-clause-object (clause)
  (let ((op (determine-op clause)))
    (multiple-value-bind (channel body)
        (parse-clause op clause)
      `(make-clause-object ,op ,channel ,body))))

(defun parse-clause (op clause)
  (let (channel body)
    (case op
      (:else
       (setf body (cdr clause)))
      (:send
       (setf channel (cadar clause))
       (setf body clause))
      (:recv
       (setf channel (cadar clause))
       (setf body (if (= 3 (length (car clause)))
                      `((let ((,(third (car clause)) ,(butlast (car clause))))
                          ,@(cdr clause)))
                      clause)))
      (:seq-send
       (setf channel (cadar clause))
       (setf body `((chanl::send-select ,(third (car clause)) ,(cadar clause))
                    ,@(cdr clause))))
      (:seq-recv
       (setf channel (cadar clause))
       (setf body (if (= 3 (length (car clause)))
                      `((let ((,(third (car clause)) (chanl::recv-select ,(cadar clause))))
                          ,@(cdr clause)))
                      `((chanl::recv-select (cadar clause)) ,@(cdr clause))))))
    (values channel `(lambda () ,@body))))

;;; Functional stuff
(defun select-from-clauses (clauses)
  ;; TODO - This will cause serious CPU thrashing if there's no else clause in SELECT.
  ;;        Perhaps there's a way to alleviate that using condition-vars? Or even channels?
  (let ((send/recv (remove-if-not (fun (not (eq :else (clause-object-op _))))
                                  clauses))
        (else-clause (find-if (fun (eq :else (clause-object-op _))) clauses)))
    (loop
       for ready-clause = (find-if-not #'clause-blocks-p send/recv)
       if ready-clause
       return (funcall (clause-object-function ready-clause))
       else if else-clause
       return (funcall (clause-object-function else-clause)))))

(defstruct (clause-object (:constructor make-clause-object (op channel function)))
  op channel function)

(defun clause-blocks-p (clause)
  (case (clause-object-op clause)
    ;; This is problematic. There's no guarantee that the clause will be non-blocking by the time
    ;; it actually executes...
    (:send (send-blocks-p (clause-object-channel clause)))
    (:recv (recv-blocks-p (clause-object-channel clause)))
    (:seq-send (find-if #'send-blocks-p (clause-object-channel clause)))
    (:seq-recv (find-if #'recv-blocks-p (clause-object-channel clause)))
    (:else nil)
    (otherwise (error "Invalid clause op."))))

