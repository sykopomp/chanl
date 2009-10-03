;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10; indent-tabs-mode: nil -*-
;;;;
;;;; Copyright © 2009 Kat Marchan, Adlai Chandrasekhar
;;;;
;;;; Channel Definition
;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(in-package :chanl)

(defvar *secret-unbound-value* (gensym "SECRETLY-UNBOUND-")
  "This value is used as a sentinel in channels.")

;;;
;;; Channel objects
;;;

;;; unbuffered
(defclass channel ()
  ((value :initform *secret-unbound-value* :accessor channel-value)
   (readers :initform 0 :accessor channel-readers)
   (writers :initform 0 :accessor channel-writers)
   (lock :initform (bt:make-recursive-lock) :accessor channel-lock)
   (send-ok :initform (bt:make-condition-variable) :accessor channel-send-ok)
   (recv-ok :initform (bt:make-condition-variable) :accessor channel-recv-ok)))

(defgeneric channelp (channel)
  (:method ((anything-else t)) nil)
  (:method ((channel channel)) t))

;;; buffered
(defconstant +maximum-buffer-size+ (- array-total-size-limit 2)
  "The exclusive upper bound on the size of a channel's buffer.")

(defclass buffered-channel (channel) ())

(defmethod initialize-instance :after ((channel buffered-channel) &key size)
  (assert (typep size `(integer 1 ,(1- +maximum-buffer-size+))) (size)
          "Buffer size must be a non-negative fixnum..")
  (setf (channel-value channel) (make-queue size)))

(defgeneric channel-buffered-p (channel)
  (:method ((anything-else t)) nil)
  (:method ((channel buffered-channel)) t))

(defmethod print-object ((channel buffered-channel) stream)
  (print-unreadable-object (channel stream :type t :identity t)
    (let ((buffer (channel-value channel)))
      (format stream "[~A/~A]" (queue-count buffer) (queue-length buffer)))))

;;;
;;; Messaging
;;;

;;; Sending
(defmacro with-write-state ((channel) &body body)
  `(unwind-protect
        (progn (incf (channel-writers ,channel))
               ,@body)
     (decf (channel-writers ,channel))))

(defgeneric send (chan value &optional blockp)
  (:method ((channel channel) value &optional (blockp t))
    (with-accessors ((lock channel-lock)
                     (recv-ok channel-recv-ok))
        channel
      (bt:with-recursive-lock-held (lock)
        (with-write-state (channel)
          (loop while (send-blocks-p channel)
             if blockp
             do (bt:condition-wait (channel-send-ok channel) lock)
             else do (return-from send nil)))
        (bt:condition-notify recv-ok)
        (channel-insert-value channel value) ; wake up a sleeping reader
        channel)))
  (:method ((channels sequence) value &optional (blockp t))
    (loop do (mapc (fun (when (send _ value nil) (return _)))
                   channels)
       unless blockp return nil))
  (:documentation "Tries to send VALUE into CHAN-OR-CHANS. If a sequence of channels is provided
instead of a single channel, SEND will send the value into the first channel that doesn't block.  If
BLOCKP is true, SEND will continue to block until it's able to actually send a value. If BLOCKP is
NIL, SEND will immediately return NIL instead of blocking, if there's no channel available to send
input into. When SEND succeeds, it returns the channel the value was sent into."))

;;; unbuffered
(defgeneric channel-insert-value (channel value)
  (:method ((channel channel) value)
    (setf (channel-value channel) value)))

(defgeneric send-blocks-p (channel)
  (:method ((channel channel))
    (not (and (plusp (channel-readers channel))
              (eq (channel-value channel)
                  *secret-unbound-value*))))
  (:documentation "Returns T if trying to SEND to CHANNEL would block. Note that this is not an
atomic operation, and should not be relied on in production. It's mostly meant for
interactive/debugging purposes."))

;;; buffered
(defmethod send-blocks-p ((channel buffered-channel))
  (and (not (plusp (channel-readers channel)))
       (queue-full-p (channel-value channel))))

(defmethod channel-insert-value ((channel buffered-channel value))
  (enqueue value (channel-value channel)))

;;; Receiving
(defmacro with-read-state ((channel) &body body)
  `(unwind-protect
        (progn (incf (channel-readers ,channel))
               ,@body)
     (decf (channel-readers ,channel))))

(defgeneric recv (chan &optional blockp)
  (:method ((channel channel) &optional (blockp t))
    (with-accessors ((lock channel-lock)
                     (send-ok channel-send-ok))
        channel
      (bt:with-recursive-lock-held (lock)
        (with-read-state (channel)
          ;; we're ready to grab something! Notify the others that we want some lovin'
          (bt:condition-notify send-ok)
          (loop while (recv-blocks-p channel)
             do (if (or blockp (plusp (channel-writers channel)))
                    (bt:condition-wait (channel-recv-ok channel) lock)
                    (return-from recv (values nil nil))))
          (values (channel-grab-value channel) channel)))))
  (:method ((channels sequence) &optional (blockp t))
    (loop do (map nil (fun (multiple-value-bind (return-val succeeded) (recv _ nil)
                             (when succeeded (return (values return-val _)))))
                  channels)
       unless blockp
       return (values nil nil)))
  (:documentation "Tries to receive from either a single channel, or a sequence of channels.  If
BLOCKP is true, RECV will block until it's possible to receive something.  Returns two values: The
first is the actual value received through the channel.  The second is the channel the value was
received from. When BLOCKP is NIL, RECV will immediately return (values NIL NIL) instead of
blocking (if it would block)"))

;;; unbuffered
(defgeneric recv-blocks-p (channel)
  (:method ((channel channel))
    (eq *secret-unbound-value* (channel-value channel))))

(defgeneric channel-grab-value (channel)
  (:method ((channel channel))
    (prog1 (channel-value channel)
      (setf (channel-value channel) *secret-unbound-value*))))

;;; buffered
(defmethod recv-blocks-p ((channel buffered-channel))
  (queue-empty-p (channel-value channel)))

(defmethod channel-grab-value ((channel buffered-channel))
  (dequeue (channel-value channel)))


