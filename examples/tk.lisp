;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10; indent-tabs-mode: nil -*-
;;;;
;;;; Copyright © 2009 Kat Marchan, Adlai Chandrasekhar
;;;;
;;;; A trivial example using channels with the lisp Tk implementation.
;;;; Example adapted from csp's tk example by roger peppe
;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(in-package :chanl.examples)

(use-package '(:ltk))
(export '(ltk-button-demo))

(defparameter *tkc* (make-channel))

(defmacro tkcmd (&rest forms)
  `(let ((reply (make-channel)))
     (send *tkc* (list (lambda () ,@forms) reply))
     (recv reply)))

(defun button (channel msg)
  (tkcmd (pack (make-instance 'button
                              :text msg
                              :master nil
                              :command
                              ;; This lambda is just not getting called by LTK. I don't
                              ;; see why... It doesn't -seem- to be a scoping issue?
                              (lambda () (send channel msg))))))

(defun ltk-button-demo ()
  (let* ((button-channel (make-channel)))
    (pexec ()
      (loop
         for i from 0
         do (let ((title (recv button-channel)))
              (button button-channel (format nil "~a.~d" title i)))))
    (pexec () (button button-channel "hello"))
    (pexec ()
      (with-ltk ()
        (loop (let ((reply (recv *tkc*)))
                (send (cadr reply) (funcall (car reply)))))))))

