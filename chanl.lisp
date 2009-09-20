;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10; indent-tabs-mode: nil -*-
;;;;
;;;; Copyright © 2009 Kat Marchan
;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defpackage :chanl
  (:use :common-lisp)
  (:import-from
   :bordeaux-threads
   #:make-thread
   #:make-lock
   #:with-lock-held
   #:make-condition-variable
   #:condition-wait
   #:condition-notify
   #:current-thread)
  (:export
   ;; processes
   #:spawn #:kill #:all-procs
   ;; channels
   #:chan #:send #:recv
   #:channel #:channel-empty-p #:channel-full-p
   #:send-blocks-p #:recv-blocks-p))

(in-package :chanl)

;;;
;;; Utils
;;;
(defmacro fun (&body body)
  "This macro puts the FUN back in FUNCTION."
  `(lambda (&optional _) (declare (ignorable _)) ,@body))

(defun random-elt (sequence)
  "Returns a random element from SEQUENCE."
  (elt sequence (random (length sequence))))

;;;
;;; Threads
;;;
(defun kill (thread)
  (bt:destroy-thread thread))

(defmacro spawn (&body body)
  "Spawn a new process to run each form in sequence. If the first item in the macro body
is a string, and there's more forms to execute, the first item in BODY is used as the
new thread's name."
  (let* ((thread-name (when (and (stringp (car body)) (cdr body)) (car body)))
         (forms (if thread-name (cdr body) body)))
    `(bt:make-thread (lambda () ,@forms)
                     ,@(when thread-name `(:name ,thread-name)))))

(defun all-procs ()
  (bt:all-threads))

;;;
;;; Channels
;;;
(defstruct channel
  (buffer nil)
  (buffer-size 0)
  (lock (bt:make-lock))
  (send-ok-condition (bt:make-condition-variable))
  (recv-ok-condition (bt:make-condition-variable)))

(defun send-ok-condition (channel)
  (channel-send-ok-condition channel))
(defun recv-ok-condition (channel)
  (channel-recv-ok-condition channel))

(defun channel-empty-p (channel)
  (null (channel-buffer channel)))

(defun channel-full-p (channel)
  (if (zerop (channel-buffer-size channel))
      (< 0 (length (channel-buffer channel)))
      (<= (channel-buffer-size channel)
          (length (channel-buffer channel)))))

(defun send-blocks-p (channel)
  (channel-full-p channel))

(defun recv-blocks-p (channel)
  (channel-empty-p channel))

(defun send (channel obj)
  (with-accessors ((buffer channel-buffer)
                   (chan-full-p channel-full-p)
                   (lock channel-lock)
                   (send-ok send-ok-condition)
                   (recv-ok recv-ok-condition))
      channel
    (bt:with-lock-held (lock)
      (when chan-full-p
        (bt:condition-wait send-ok lock))
      (setf buffer (nconc buffer (list obj)))
      (bt:condition-notify recv-ok)
      obj)))

(defun recv (channel)
  (with-accessors ((buffer channel-buffer)
                   (chan-empty-p channel-empty-p)
                   (lock channel-lock)
                   (send-ok send-ok-condition)
                   (recv-ok recv-ok-condition))
      channel
    (bt:with-lock-held (lock)
      (when chan-empty-p
        (bt:condition-wait recv-ok lock))
      (prog1 (pop buffer)
        (bt:condition-notify send-ok)))))

(defmethod print-object ((channel channel) stream)
  (print-unreadable-object (channel stream :type t :identity t)
    (format stream "~A/~A" (length (channel-buffer channel)) (channel-buffer-size channel))))

(defun chan (&optional (buffer-size 0))
  "Create a new channel. The optional argument gives the size
   of the channel's buffer (default 0)"
  (make-channel :buffer-size buffer-size))

;;;
;;; muxing macro
;;;
(defmacro mux (&body body)
  (let ((sends (remove-if-not 'send-clause-p body))
        (recvs (remove-if-not 'recv-clause-p body))
        (else (remove-if-not 'else-clause-p body)))
    ))

(defun send-clause-p (clause)
  (eq 'send (caar clause)))
(defun recv-clause-p (clause)
  (eq 'recv (caar clause)))
(defun else-clause-p (clause)
  (eq t (car clause)))

