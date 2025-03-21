;;; ---------------------------------------------------------------------------
;;;   License: LGPL-2.1+ (See file 'Copyright' for details).
;;; ---------------------------------------------------------------------------
;;;
;;;  (c) copyright 1998,1999,2000,2001,2003 Michael McDonald <mikemac@mikemac.com>
;;;  (c) copyright 2000-2003,2009-2016 Robert Strandh <robert.strandh@gmail.com>
;;;  (c) copyright 2001 Arnaud Rouanet <rouanet@emi.u-bordeaux.fr>
;;;  (c) copyright 2001 Lionel Salabartan <salabart@emi.u-bordeaux.fr>
;;;  (c) copyright 2001,2002 Alexey Dejneka <adejneka@comail.ru>
;;;  (c) copyright 2002,2003,2004 Timothy Moore <tmoore@common-lisp.net>
;;;  (c) copyright 2002,2003,2004,2005 Gilbert Baumann <unk6@rz.uni-karlsruhe.de>
;;;  (c) copyright 2003-2008 Andy Hefner <ahefner@common-lisp.net>
;;;  (c) copyright 2005,2006 Christophe Rhodes <crhodes@common-lisp.net>
;;;  (c) copyright 2006 Andreas Fuchs <afuchs@common-lisp.net>
;;;  (c) copyright 2007 David Lichteblau <dlichteblau@common-lisp.net>
;;;  (c) copyright 2007 Robert Goldman <rgoldman@common-lisp.net>
;;;  (c) copyright 2017 Cyrus Harmon <cyrus@bobobeach.com>
;;;  (c) copyright 2018 Elias Martenson <lokedhs@gmail.com>
;;;  (c) copyright 2018-2021 Jan Moringen <jmoringe@techfak.uni-bielefeld.de>
;;;  (c) copyright 2016-2022 Daniel Kochmański <daniel@turtleware.eu>
;;;
;;; ---------------------------------------------------------------------------
;;;
;;; Machinery for creating, querying and modifying output records.
;;;

;;; TODO:
;;;
;;; - Scrolling does not work correctly. Region is given in "window"
;;;   coordinates, without bounding-rectangle-position transformation.
;;;   (Is it still valid?)
;;;
;;; - Redo setf*-output-record-position, extent recomputation for
;;;   compound records
;;;
;;; - When DRAWING-P is NIL, should stream cursor move?
;;;
;;; - :{X,Y}-OFFSET.
;;;
;;; - (SETF OUTPUT-RECORD-START-CURSOR-POSITION) does not affect the
;;;   bounding rectangle. What does it affect?
;;;
;;; - How should (SETF OUTPUT-RECORD-POSITION) affect the bounding
;;;   rectangle of the parent? Now its bounding rectangle is
;;;   accurately recomputed, but it is very inefficient for table
;;;   formatting. It seems that CLIM is supposed to keep a "large
;;;   enough" rectangle and to shrink it to the correct size only when
;;;   the layout is complete by calling TREE-RECOMPUTE-EXTENT.
;;;
;;; - Computation of the bounding rectangle of lines/polygons ignores
;;;   LINE-STYLE-CAP-SHAPE.
;;;
;;; - Rounding of coordinates.
;;;
;;; - Document carefully the interface of STANDARD-OUTPUT-RECORDING-STREAM.
;;;
;;; - Some GFs are defined to have "a default method on CLIM's
;;;   standard output record class". What does it mean? What is
;;;   "CLIM's standard output record class"? Is it OUTPUT-RECORD or
;;;   BASIC-OUTPUT-RECORD?  Now they are defined on OUTPUT-RECORD.

(in-package #:clim-internals)

;;; Forward definition
(defclass stream-output-history-mixin ()
  ((stream :initarg :stream :reader output-history-stream)))

;;; These generic functions need to be implemented for all the basic
;;; displayed-output-records, so they are defined in this file.
;;;
;;; MATCH-OUTPUT-RECORDS and FIND-CHILD-OUTPUT-RECORD, as defined in
;;; the CLIM spec, are pretty silly.  How does incremental redisplay
;;; know what keyword arguments to supply to FIND-CHILD-OUTPUT-RECORD?
;;; Through a gf specialized on the type of the record it needs to
;;; match... why not define the search function and the predicate on
;;; two records then!
;;;
;;; These gf's use :MOST-SPECIFIC-LAST because one of the least
;;; specific methods will check the bounding boxes of the records,
;;; which should cause an early out most of the time.
;;;
;;; We'll implement MATCH-OUTPUT-RECORDS and FIND-CHILD-OUTPUT-RECORD,
;;; but we won't actually use them.  Instead, output-record-equal will
;;; match two records, and find-child-record-equal will search for the
;;; equivalent record.

(defgeneric match-output-records-1 (record &key)
  (:method-combination and :most-specific-last))

(defgeneric output-record-equal (record1 record2)
  (:method-combination and :most-specific-last))

(defmethod output-record-equal :around (record1 record2)
  (cond ((eq record1 record2)
         ;; Some unusual record -- like a Goatee screen line -- might
         ;; exist in two trees at once
         t)
        ((eq (class-of record1) (class-of record2))
         (let ((result (call-next-method)))
           (if (eq result 'maybe)
               nil
               result)))
        (t nil)))

;;; A fallback method so that something's always applicable.

(defmethod output-record-equal and (record1 record2)
  (declare (ignore record1 record2))
  'maybe)

;;; The code for MATCH-OUTPUT-RECORDS-1 and OUTPUT-RECORD-EQUAL
;;; methods are very similar, hence this macro.  In order to exploit
;;; the similarities, it's necessary to treat the slots of the second
;;; record like variables, so for convenience the macro will use
;;; WITH-SLOTS on the second record.
(defmacro defrecord-predicate (record-type slots &body body)
  "Each element of SLOTS is either a symbol naming a slot
or (SLOT-NAME SLOT-P)."
  (multiple-value-bind (slot-names key-args key-arg-alist)
      (loop for slot-spec in slots
            for (name slot-p) = (if (atom slot-spec)
                                    (list slot-spec t)
                                    slot-spec)
            for suppliedp = (gensym (format nil "~A-~A" name '#:p))
            when slot-p collect name into slot-names
            collect `(,name nil ,suppliedp) into key-args
            collect (cons name suppliedp) into key-arg-alist
            finally (return (values slot-names key-args key-arg-alist)))
    `(progn
       (defmethod output-record-equal and ((record ,record-type)
                                           (record2 ,record-type))
         (macrolet ((if-supplied ((var &optional (type t)) &body supplied-body)
                      (declare (ignore type))
                      (when (find var ',slot-names :test #'eq)
                        `(progn ,@supplied-body))))
           (with-slots ,slot-names record2
             ,@body)))
       (defmethod match-output-records-1 and ((record ,record-type)
                                              &key ,@key-args)
         (macrolet ((if-supplied ((var &optional (type t)) &body supplied-body)
                      (let ((supplied-var (or (cdr (assoc var ',key-arg-alist))
                                              (error "Unknown argument ~S" var))))
                        `(or (null ,supplied-var)
                             ,(if (eq type t)
                                  `(progn ,@supplied-body)
                                  `(if (typep ,var ',type)
                                       (progn ,@supplied-body)
                                       (error 'type-error
                                              :datum ,var
                                              :expected-type ',type)))))))
           ,@body)))))

(defmacro with-output-recording-options ((stream
                                          &key (record nil record-supplied-p)
                                               (draw nil draw-supplied-p))
                                         &body body)
  (with-stream-designator (stream '*standard-output*)
    (with-gensyms (continuation)
      `(flet ((,continuation  (,stream)
                ,(declare-ignorable-form* stream)
                ,@body))
         (declare (dynamic-extent #',continuation))
         (with-drawing-options (,stream)
           (invoke-with-output-recording-options
            ,stream #',continuation
            ,(if record-supplied-p record `(stream-recording-p ,stream))
            ,(if draw-supplied-p draw `(stream-drawing-p ,stream))))))))

;;; Macro masturbation...

(defmacro define-invoke-with (macro-name func-name record-type doc-string)
  `(defmacro ,macro-name ((stream
                           &optional
                           (record-type '',record-type)
                           (record (gensym))
                           &rest initargs)
                          &body body)
     ,doc-string
     (with-stream-designator (stream '*standard-output*)
       (with-gensyms (continuation)
         (multiple-value-bind (bindings m-i-args)
             (rebind-arguments initargs)
           `(let ,bindings
              (flet ((,continuation (,stream ,record)
                       ,(declare-ignorable-form* stream record)
                       ,@body))
                (declare (dynamic-extent #',continuation))
                (,',func-name ,stream #',continuation ,record-type ,@m-i-args))))))))

(define-invoke-with with-new-output-record invoke-with-new-output-record
  standard-sequence-output-record
  "Creates a new output record of type RECORD-TYPE and then captures
the output of BODY into the new output record, and inserts the new
record into the current \"open\" output record assotiated with STREAM.
    If RECORD is supplied, it is the name of a variable that will be
lexically bound to the new output record inside the body. INITARGS are
CLOS initargs that are passed to MAKE-INSTANCE when the new output
record is created.
    It returns the created output record.
    The STREAM argument is a symbol that is bound to an output
recording stream. If it is T, *STANDARD-OUTPUT* is used.")

(define-invoke-with with-output-to-output-record
    invoke-with-output-to-output-record
  standard-sequence-output-record
  "Creates a new output record of type RECORD-TYPE and then captures
the output of BODY into the new output record. The cursor position of
STREAM is initially bound to (0,0)
    If RECORD is supplied, it is the name of a variable that will be
lexically bound to the new output record inside the body. INITARGS are
CLOS initargs that are passed to MAKE-INSTANCE when the new output
record is created.
    It returns the created output record.
    The STREAM argument is a symbol that is bound to an output
recording stream. If it is T, *STANDARD-OUTPUT* is used.")


;;;; Implementation

(defclass basic-output-record (standard-bounding-rectangle output-record)
  ((parent :initform nil
           :accessor output-record-parent)) ; XXX
  (:documentation "Implementation class for the Basic Output Record Protocol."))

(defmethod initialize-instance :after ((record basic-output-record)
                                       &key (x-position 0.0d0 x-position-p)
                                            (y-position 0.0d0 y-position-p)
                                            (parent nil))
  (when (or x-position-p y-position-p)
    (setf (rectangle-edges* record)
          (values x-position y-position x-position y-position)))
  (when parent
    (add-output-record record parent)))

;;; We need to remember initial record position (hence x,y slots) in case when
;;; we add children expanding record in top-left direction and then call
;;; clear-output-record. We want to reposition output record then at its initial
;;; position. That's why this is not redundant with the bounding-rectangle.
(defclass compound-output-record (basic-output-record)
  ((x :initarg :x-position
      :initform 0.0d0
      :documentation "X-position of the empty record.")
   (y :initarg :y-position
      :initform 0.0d0
      :documentation "Y-position of the empty record.")
   (in-moving-p :initform nil
                :documentation "Is set while changing the position."))
  (:documentation "Implementation class for output records with children."))

;;; 16.2.1. The Basic Output Record Protocol
(defmethod output-record-position ((record basic-output-record))
  (bounding-rectangle-position record))

(defmethod* (setf output-record-position) (nx ny (record basic-output-record))
  (with-standard-rectangle* (x1 y1 x2 y2) record
    (let ((dx (- nx x1))
          (dy (- ny y1)))
      (setf (rectangle-edges* record)
            (values nx ny (+ x2 dx) (+ y2 dy)))))
  (values nx ny))

(defmethod* (setf output-record-position) :around
            (nx ny (record basic-output-record))
  (with-bounding-rectangle* (min-x min-y max-x max-y) record
    (call-next-method)
    (when-let ((parent (output-record-parent record)))
      (unless (and (typep parent 'compound-output-record)
                   (slot-value parent 'in-moving-p)) ; XXX
        (recompute-extent-for-changed-child parent record
                                            min-x min-y max-x max-y)))
    (values nx ny)))

(defmethod* (setf output-record-position)
  :before (nx ny (record compound-output-record))
  (with-standard-rectangle* (x1 y1) record
    (letf (((slot-value record 'in-moving-p) t))
      (let ((dx (- nx x1))
            (dy (- ny y1)))
        (map-over-output-records
         (lambda (child)
           (multiple-value-bind (x y) (output-record-position child)
             (setf (output-record-position child)
                   (values (+ x dx) (+ y dy)))))
         record)))))

(defmethod output-record-start-cursor-position ((record basic-output-record))
  (values nil nil))

(defmethod* (setf output-record-start-cursor-position)
    (x y (record basic-output-record))
  (values x y))

(defmethod output-record-end-cursor-position ((record basic-output-record))
  (values nil nil))

(defmethod* (setf output-record-end-cursor-position)
    (x y (record basic-output-record))
  (values x y))

(defun replay (record stream &optional region)
  (when (typep stream 'encapsulating-stream)
    (return-from replay (replay record (encapsulating-stream-stream stream) region)))
  (unless region
    (setf region (sheet-visible-region stream)))
  (stream-close-text-output-record stream)
  (when (stream-drawing-p stream)
    (with-output-recording-options (stream :record nil)
      (with-sheet-medium (medium stream)
        (letf (((cursor-visibility (stream-text-cursor stream)) nil) ;; FIXME?
               ((stream-cursor-position stream) (values 0 0))
               ;; Is there a better value to bind to baseline?
               ((slot-value stream 'baseline) (slot-value stream 'baseline))
               ((medium-transformation medium) +identity-transformation+))
          (replay-output-record record stream region))))))

(defmethod replay-output-record ((record compound-output-record) (stream encapsulating-stream)
                                 &optional region (x-offset 0) (y-offset 0))
  (replay-output-record record (encapsulating-stream-stream stream)
                        region x-offset y-offset))

(defmethod replay-output-record ((record compound-output-record) stream
                                 &optional region (x-offset 0) (y-offset 0))
  (unless region
    (setf region (sheet-visible-region stream)))
  (with-drawing-options (stream :clipping-region region)
    (map-over-output-records-overlapping-region
     #'replay-output-record record region x-offset y-offset
     stream region x-offset y-offset)))

(defmethod output-record-hit-detection-rectangle* ((record output-record))
  ;; XXX DC
  (bounding-rectangle* record))

(defmethod output-record-refined-position-test
    ((record basic-output-record) x y)
  (declare (ignore x y))
  t)

(defun highlight-output-record-rectangle (record stream state)
  (with-identity-transformation (stream)
    (ecase state
      (:highlight
       ;; We can't "just" draw-rectangle :filled nil because the path lines
       ;; rounding may get outside the bounding rectangle. -- jd 2019-02-01
       (multiple-value-bind (x1 y1 x2 y2) (bounding-rectangle* record)
         (draw-design (sheet-medium stream)
                      (if (or (> (1+ x1) (1- x2))
                              (> (1+ y1) (1- y2)))
                          (bounding-rectangle record)
                          (region-difference (bounding-rectangle record)
                                             (make-rectangle* (1+ x1) (1+ y1) (1- x2) (1- y2))))
                      :ink +foreground-ink+)))
      (:unhighlight
       (dispatch-repaint stream (bounding-rectangle record))))))

;;; XXX Should this only be defined on recording streams?
(defmethod highlight-output-record ((record output-record) stream state)
  ;; XXX DC
  ;; XXX Disable recording?
  (highlight-output-record-rectangle record stream state))

;;; 16.2.2. The Output Record "Database" Protocol

(defmethod note-output-record-lost-sheet ((record output-record) sheet)
  (declare (ignore record sheet))
  (values))

(defmethod note-output-record-lost-sheet :after
    ((record compound-output-record) sheet)
  (map-over-output-records #'note-output-record-lost-sheet record 0 0 sheet))

(defmethod note-output-record-got-sheet ((record output-record) sheet)
  (declare (ignore record sheet))
  (values))

(defmethod note-output-record-got-sheet :after
    ((record compound-output-record) sheet)
  (map-over-output-records #'note-output-record-got-sheet record 0 0 sheet))

(defun find-output-record-sheet (record)
  "Walks up the parents of RECORD, searching for an output history from which
the associated sheet can be determined."
  (typecase record
    (stream-output-history-mixin
     (output-history-stream record))
    (basic-output-record
     (find-output-record-sheet (output-record-parent record)))))

(defmethod output-record-children ((record basic-output-record))
  nil)

(defmethod add-output-record (child (record basic-output-record))
  (declare (ignore child))
  (error "Cannot add a child to ~S." record))

(defmethod add-output-record :before (child (record compound-output-record))
  (let ((parent (output-record-parent child)))
    (cond (parent
           (restart-case
               (error "~S already has a parent ~S." child parent)
             (delete ()
               :report "Delete from the old parent."
               (delete-output-record child parent))))
          ((eq record child)
           (error "~S is being added to itself." record))
          ((eq (output-record-parent record) child)
           (error "child ~S is being added to its own child ~S."
                  child record)))))

(defmethod add-output-record :after (child (record compound-output-record))
  (recompute-extent-for-new-child record child)
  (when (eq record (output-record-parent child))
    (when-let ((sheet (find-output-record-sheet record)))
      (note-output-record-got-sheet child sheet))))

(defmethod delete-output-record :before (child (record basic-output-record)
                                         &optional (errorp t))
  (declare (ignore errorp))
  (when-let ((sheet (find-output-record-sheet record)))
    (note-output-record-lost-sheet child sheet)))

(defmethod delete-output-record (child (record basic-output-record)
                                 &optional (errorp t))
  (declare (ignore child))
  (when errorp (error "Cannot delete a child from ~S." record)))

(defmethod delete-output-record :after (child (record compound-output-record)
                                        &optional (errorp t))
  (declare (ignore errorp))
  (with-bounding-rectangle* (x1 y1 x2 y2) child
    (recompute-extent-for-changed-child record child x1 y1 x2 y2)))

(defmethod clear-output-record ((record basic-output-record))
  (error "Cannot clear ~S." record))

(defmethod clear-output-record :before ((record compound-output-record))
  (when-let ((sheet (find-output-record-sheet record)))
    (map-over-output-records #'note-output-record-lost-sheet record 0 0 sheet)))

(defmethod clear-output-record :around ((record compound-output-record))
  (multiple-value-bind (x1 y1 x2 y2) (bounding-rectangle* record)
    (call-next-method)
    (assert (null-bounding-rectangle-p record))
    (when-let ((parent (output-record-parent record)))
      (recompute-extent-for-changed-child parent record x1 y1 x2 y2))))

(defmethod clear-output-record :after ((record compound-output-record))
  (with-slots (x y) record
    (setf (rectangle-edges* record) (values x y x y))))

(defmethod output-record-count ((record displayed-output-record))
  0)

(defmethod map-over-output-records-1
    (function (record displayed-output-record) function-args)
  (declare (ignore function function-args))
  nil)

;;; This needs to work in "most recently added last" order. Is this
;;; implementation right? -- APD, 2002-06-13
#+(or)
(defmethod map-over-output-records
    (function (record compound-output-record)
     &optional (x-offset 0) (y-offset 0)
     &rest function-args)
  (declare (ignore x-offset y-offset))
  (map nil (lambda (child) (apply function child function-args))
       (output-record-children record)))

(defmethod map-over-output-records-containing-position
    (function (record displayed-output-record) x y
     &optional (x-offset 0) (y-offset 0)
     &rest function-args)
  (declare (ignore function x y x-offset y-offset function-args))
  nil)

;;; This needs to work in "most recently added first" order. Is this
;;; implementation right? -- APD, 2002-06-13
#+(or)
(defmethod map-over-output-records-containing-position
    (function (record compound-output-record) x y
     &optional (x-offset 0) (y-offset 0)
     &rest function-args)
  (declare (ignore x-offset y-offset))
  (map nil
       (lambda (child)
         (when (and (multiple-value-bind (min-x min-y max-x max-y)
                        (output-record-hit-detection-rectangle* child)
                      (and (<= min-x x max-x) (<= min-y y max-y)))
                    (output-record-refined-position-test child x y))
           (apply function child function-args)))
       (output-record-children record)))

(defmethod map-over-output-records-overlapping-region
    (function (record displayed-output-record) region
     &optional (x-offset 0) (y-offset 0)
     &rest function-args)
  (declare (ignore function region x-offset y-offset function-args))
  nil)

;;; This needs to work in "most recently added last" order. Is this
;;; implementation right? -- APD, 2002-06-13
#+(or)
(defmethod map-over-output-records-overlapping-region
    (function (record compound-output-record) region
     &optional (x-offset 0) (y-offset 0)
     &rest function-args)
  (declare (ignore x-offset y-offset))
  (map nil
       (lambda (child) (when (region-intersects-region-p region child)
                         (apply function child function-args)))
       (output-record-children record)))

;;; XXX Dunno about this definition... -- moore
;;;
;;; Your apprehension is justified, but we lack a better means by which to
;;; distinguish "empty" compound records (roots of trees of compound records,
;;; containing no non-compound records). Such subtrees should not affect
;;; bounding rectangles.  -- Hefner
(defun null-bounding-rectangle-p (bbox)
  (with-bounding-rectangle* (x1 y1 x2 y2) bbox
    (and (= x1 x2)
         (= y1 y2)
         t)))

;;; 16.2.3. Output Record Change Notification Protocol
(defmethod recompute-extent-for-new-child
    ((record compound-output-record) child)
  (unless (null-bounding-rectangle-p child)
    (with-bounding-rectangle* (old-x1 old-y1 old-x2 old-y2) record
      (cond
        ((null-bounding-rectangle-p record)
         (setf (rectangle-edges* record) (bounding-rectangle* child)))
        ((not (null-bounding-rectangle-p child))
         (assert (not (null-bounding-rectangle-p record))) ; important.
         (with-bounding-rectangle* (x1-child y1-child x2-child y2-child)
             child
           (setf (rectangle-edges* record)
                 (values (min old-x1 x1-child) (min old-y1 y1-child)
                         (max old-x2 x2-child) (max old-y2 y2-child))))))
      (when-let ((parent (output-record-parent record)))
        (recompute-extent-for-changed-child
         parent record old-x1 old-y1 old-x2 old-y2))))
  record)

(defun %tree-recompute-extent* (record)
  (check-type record compound-output-record)
  ;; Internal helper function
  (if (zerop (output-record-count record)) ; no children
      (with-slots (x y) record
        (values x y x y))
      (let ((new-x1 0)
            (new-y1 0)
            (new-x2 0)
            (new-y2 0)
            (first-time t))
        (flet ((do-child (child)
                 (cond ((null-bounding-rectangle-p child))
                       (first-time
                        (multiple-value-setq (new-x1 new-y1 new-x2 new-y2)
                          (bounding-rectangle* child))
                        (setq first-time nil))
                       (t
                        (with-bounding-rectangle* (cx1 cy1 cx2 cy2) child
                          (minf new-x1 cx1)
                          (minf new-y1 cy1)
                          (maxf new-x2 cx2)
                          (maxf new-y2 cy2))))))
          (declare (dynamic-extent #'do-child))
          (map-over-output-records #'do-child record))
        (values new-x1 new-y1 new-x2 new-y2))))

(defmethod recompute-extent-for-changed-child
    ((record compound-output-record) changed-child
     old-min-x old-min-y old-max-x old-max-y)
  (with-bounding-rectangle* (ox1 oy1 ox2 oy2) record
    (with-bounding-rectangle* (cx1 cy1 cx2 cy2) changed-child
      ;; If record is currently empty, use the child's bbox directly. Else..
      ;; Does the new rectangle of the child contain the original rectangle?  If
      ;; so, we can use min/max to grow record's current rectangle.  If not, the
      ;; child has shrunk, and we need to fully recompute.
      (multiple-value-bind (nx1 ny1 nx2 ny2)
          (cond
            ;; The child has been deleted; who knows what the new bounding box
            ;; might be. This case shouldn't be really necessary.
            ((not (output-record-parent changed-child))
             (%tree-recompute-extent* record))
            ;; 1) Only one child of record, and we already have the bounds.
            ;; 2) Our record occupied no space so the new child is the rectangle.
            ((or (eql (output-record-count record) 1)
                 (null-bounding-rectangle-p record))
             (values cx1 cy1 cx2 cy2))
            ;; In the following cases, we can grow the new bounding rectangle
            ;; from its previous state:
            ((or
              ;; If the child was originally empty, it could not have affected
              ;; previous computation of our bounding rectangle.  This is
              ;; hackish for reasons similar to the above.
              (and (= old-min-x old-max-x) (= old-min-y old-max-y))
              ;; For each edge of the original child bounds, if it was within
              ;; its respective edge of the old parent bounding rectangle, or if
              ;; it has not changed:
              (and (or (> old-min-x ox1) (= old-min-x cx1))
                   (or (> old-min-y oy1) (= old-min-y cy1))
                   (or (< old-max-x ox2) (= old-max-x cx2))
                   (or (< old-max-y oy2) (= old-max-y cy2)))
              ;; New child bounds contain old child bounds, so use min/max to
              ;; extend the already-calculated rectangle.
              (and (<= cx1 old-min-x) (<= cy1 old-min-y)
                   (>= cx2 old-max-x) (>= cy2 old-max-y)))
             (values (min cx1 ox1) (min cy1 oy1)
                     (max cx2 ox2) (max cy2 oy2)))
            ;; No shortcuts - we must compute a new bounding box from those of
            ;; all our children. We want to avoid this - in worst cases, such as
            ;; a toplevel output history, there may exist thousands of children.
            ;; Without the above optimizations, construction becomes O(N^2) due
            ;; to the bounding rectangle calculation.
            (t
             (%tree-recompute-extent* record)))
        (with-slots (x y) record
          (setf x nx1 y ny1)
          (setf (rectangle-edges* record) (values nx1 ny1 nx2 ny2))
          (when-let ((parent (output-record-parent record)))
            (unless (and (= nx1 ox1) (= ny1 oy1)
                         (= nx2 ox2) (= ny2 oy2))
              (recompute-extent-for-changed-child parent record
                                                  ox1 oy1 ox2 oy2)))))))
  record)

(defun tree-recompute-extent-aux (record &aux new-x1 new-y1 new-x2 new-y2 changedp)
  (when (or (null (typep record 'compound-output-record))
            (zerop (output-record-count record)))
    (return-from tree-recompute-extent-aux
      (bounding-rectangle* record)))
  (flet ((do-child (child)
           (if (null changedp)
               (progn
                 (multiple-value-setq (new-x1 new-y1 new-x2 new-y2)
                   (tree-recompute-extent-aux child))
                 (setq changedp t))
               (multiple-value-bind (cx1 cy1 cx2 cy2)
                   (tree-recompute-extent-aux child)
                 (minf new-x1 cx1) (minf new-y1 cy1)
                 (maxf new-x2 cx2) (maxf new-y2 cy2)))))
    (declare (dynamic-extent #'do-child))
    (map-over-output-records #'do-child record))
  (with-slots (x y) record
    (setf x new-x1 y new-y1)
    (setf (rectangle-edges* record)
          (values new-x1 new-y1 new-x2 new-y2))))

(defmethod tree-recompute-extent ((record compound-output-record))
  (tree-recompute-extent-aux record)
  record)

(defmethod tree-recompute-extent :around ((record compound-output-record))
  (with-bounding-rectangle* (old-x1 old-y1 old-x2 old-y2) record
    (call-next-method)
    (with-bounding-rectangle* (x1 y1 x2 y2) record
      (when-let ((parent (output-record-parent record)))
        (unless (and (= old-x1 x1) (= old-y1 y1)
                     (= old-x2 x2) (= old-y2 y2))
          (recompute-extent-for-changed-child parent record
                                              old-x1 old-y1
                                              old-x2 old-y2)))))
  record)

;;; 16.3.1. Standard output record classes

(defclass standard-sequence-output-record (compound-output-record)
  ((children :initform (make-array 8 :adjustable t :fill-pointer 0)
             :reader output-record-children)))

(defmethod add-output-record (child (record standard-sequence-output-record))
  (vector-push-extend child (output-record-children record))
  (setf (output-record-parent child) record))

(defmethod delete-output-record (child (record standard-sequence-output-record)
                                 &optional (errorp t))
  (with-slots (children) record
    (if-let ((pos (position child children :test #'eq)))
      (progn
        (setq children (replace children children
                                :start1 pos
                                :start2 (1+ pos)))
        (decf (fill-pointer children))
        (setf (output-record-parent child) nil))
      (when errorp
        (error "~S is not a child of ~S" child record)))))

(defmethod clear-output-record ((record standard-sequence-output-record))
  (let ((children (output-record-children record)))
    (map 'nil (lambda (child) (setf (output-record-parent child) nil))
         children)
    (fill children nil)
    (setf (fill-pointer children) 0)))

(defmethod output-record-count ((record standard-sequence-output-record))
  (length (output-record-children record)))

(defmethod map-over-output-records-1
    (function (record standard-sequence-output-record) function-args)
  "Applies FUNCTION to all children in the order they were added."
  (let ((function (alexandria:ensure-function function)))
    (if function-args
        (loop for child across (output-record-children record)
              do (apply function child function-args))
        (loop for child across (output-record-children record)
              do (funcall function child)))))

(defmethod map-over-output-records-containing-position
    (function (record standard-sequence-output-record) x y
     &optional (x-offset 0) (y-offset 0)
     &rest function-args)
  "Applies FUNCTION to children, containing (X,Y), in the reversed
order they were added."
  (declare (ignore x-offset y-offset))
  (let ((function (alexandria:ensure-function function)))
    (loop with children = (output-record-children record)
          for i from (1- (length children)) downto 0
          for child = (aref children i)
          when (and (multiple-value-bind (min-x min-y max-x max-y)
                        (output-record-hit-detection-rectangle* child)
                      (and (<= min-x x max-x) (<= min-y y max-y)))
                    (output-record-refined-position-test child x y))
          do (apply function child function-args))))

(defmethod map-over-output-records-overlapping-region
    (function (record standard-sequence-output-record) region
     &optional (x-offset 0) (y-offset 0)
     &rest function-args)
  "Applies FUNCTION to children, overlapping REGION, in the order they
were added."
  (declare (ignore x-offset y-offset))
  (let ((function (alexandria:ensure-function function)))
    (loop with children = (output-record-children record)
          for child across children
          when (region-intersects-region-p region child)
          do (apply function child function-args))))

;;; tree output recording

(defclass tree-output-record-entry ()
     ((record :initarg :record :reader tree-output-record-entry-record)
      (cached-rectangle :initform nil
                        :accessor tree-output-record-entry-cached-rectangle)
      (inserted-nr :initarg :inserted-nr
                   :accessor tree-output-record-entry-inserted-nr)))

(defvar %infinite-rectangle%
  (rectangles:make-rectangle)
  "This constant should be used to map over all tree output records.")

(defun make-tree-output-record-entry (record inserted-nr)
  (make-instance 'tree-output-record-entry
                 :record record
                 :inserted-nr inserted-nr))

(defun %record-to-spatial-tree-rectangle (record)
  (with-bounding-rectangle* (x1 y1 x2 y2) record
    (rectangles:make-rectangle :lows `(,x1 ,y1) :highs `(,x2 ,y2))))

(defun %output-record-entry-to-spatial-tree-rectangle (r)
  (when (null (tree-output-record-entry-cached-rectangle r))
    (let* ((record (tree-output-record-entry-record r)))
      (setf (tree-output-record-entry-cached-rectangle r)
            (%record-to-spatial-tree-rectangle record))))
  (tree-output-record-entry-cached-rectangle r))

(defun %make-tree-output-record-tree ()
  (spatial-trees:make-spatial-tree :r
                        :rectfun #'%output-record-entry-to-spatial-tree-rectangle))

(defclass standard-tree-output-record (compound-output-record)
  ((children-tree :initform (%make-tree-output-record-tree)
                  :accessor %tree-record-children)
   (children-hash :initform (make-hash-table :test #'eql)
                  :reader %tree-record-children-cache)
   (child-count :initform 0)
   (last-insertion-nr :initform 0 :accessor last-insertion-nr)))

(defun %entry-in-children-cache (record child)
  (gethash child (%tree-record-children-cache record)))

(defun (setf %entry-in-children-cache) (new-val record child)
  (setf (gethash child (%tree-record-children-cache record)) new-val))

(defun %remove-entry-from-children-cache (record child)
  (remhash child (%tree-record-children-cache record)))

(defun %refresh-entry-in-children-cache (record child)
  (let ((rtree (%tree-record-children record))
        (entry (%entry-in-children-cache record child)))
    (spatial-trees:delete entry rtree)
    (setf (tree-output-record-entry-cached-rectangle entry) nil)
    (spatial-trees:insert entry rtree)))

(defmethod output-record-children ((record standard-tree-output-record))
  (map 'list #'tree-output-record-entry-record
       (spatial-trees:search %infinite-rectangle%
                             (%tree-record-children record))))

(defmethod add-output-record (child (record standard-tree-output-record))
  (let ((entry (make-tree-output-record-entry
                child (incf (last-insertion-nr record)))))
    (spatial-trees:insert entry (%tree-record-children record))
    (setf (output-record-parent child) record)
    (setf (%entry-in-children-cache record child) entry))
  (incf (slot-value record 'child-count))
  (values))

(defmethod delete-output-record
    (child (record standard-tree-output-record) &optional (errorp t))
  (if-let ((entry (find child (spatial-trees:search
                               (%entry-in-children-cache record child)
                               (%tree-record-children record))
                        :key #'tree-output-record-entry-record)))
    (progn
      (decf (slot-value record 'child-count))
      (spatial-trees:delete entry (%tree-record-children record))
      (%remove-entry-from-children-cache record child)
      (setf (output-record-parent child) nil))
    (when errorp
      (error "~S is not a child of ~S" child record))))

(defmethod* (setf output-record-position) :after
  (nx ny (record standard-tree-output-record))
  (declare (ignore nx ny))
  (dolist (child (output-record-children record))
    (%refresh-entry-in-children-cache record child)))

(defmethod clear-output-record ((record standard-tree-output-record))
  (map nil (lambda (child)
             (setf (output-record-parent child) nil)
             (%remove-entry-from-children-cache record child))
       (output-record-children record))
  (setf (slot-value record 'child-count) 0)
  (setf (last-insertion-nr record) 0)
  (setf (%tree-record-children record) (%make-tree-output-record-tree)))

(defmethod output-record-count ((record standard-tree-output-record))
  (slot-value record 'child-count))

(defun map-over-tree-output-records
    (function record rectangle sort-order function-args)
  (dolist (child (sort (spatial-trees:search rectangle
                                             (%tree-record-children record))
                       (ecase sort-order
                         (:most-recent-first #'>)
                         (:most-recent-last #'<))
                       :key #'tree-output-record-entry-inserted-nr))
    (apply function (tree-output-record-entry-record child) function-args)))

(defmethod map-over-output-records-1
    (function (record standard-tree-output-record) args)
  (map-over-tree-output-records
   function record %infinite-rectangle% :most-recent-last args))

(defmethod map-over-output-records-containing-position
    (function (record standard-tree-output-record) x y
     &optional x-offset y-offset &rest function-args)
  (declare (ignore x-offset y-offset))
  (flet ((refined-test-function (record)
           (when (output-record-refined-position-test record x y)
             (apply function record function-args))))
    (declare (dynamic-extent #'refined-test-function))
    (let ((rectangle (rectangles:make-rectangle :lows `(,x ,y) :highs `(,x ,y))))
      (map-over-tree-output-records
       #'refined-test-function record rectangle :most-recent-first nil))))

(defmethod map-over-output-records-overlapping-region
    (function (record standard-tree-output-record) region
     &optional x-offset y-offset &rest function-args)
  (declare (ignore x-offset y-offset))
  (typecase region
    (everywhere-region (map-over-output-records-1 function record function-args))
    (nowhere-region nil)
    (otherwise (map-over-tree-output-records
                (lambda (child)
                  (when (region-intersects-region-p
                         (multiple-value-call 'make-rectangle*
                           (bounding-rectangle* child))
                         region)
                    (apply function child function-args)))
                record
                (%record-to-spatial-tree-rectangle (bounding-rectangle region))
                :most-recent-last
                '()))))

(defmethod recompute-extent-for-changed-child :before
    ((record standard-tree-output-record) child
     old-min-x old-min-y old-max-x old-max-y)
  (declare (ignore old-min-x old-min-y old-max-x old-max-y))
  (when (eql record (output-record-parent child))
    (%refresh-entry-in-children-cache record child)))

;;;

(defmethod match-output-records ((record t) &rest args)
  (apply #'match-output-records-1 record args))

(defmethod replay-output-record :around
    ((record gs-ink-mixin) stream &optional region x-offset y-offset)
  (declare (ignore region x-offset y-offset))
  (with-drawing-options (stream :ink (graphics-state-ink record))
    (call-next-method)))

(defmethod* (setf output-record-position) :before
    (nx ny (record gs-ink-mixin))
    (with-standard-rectangle* (x1 y1) record
      (let* ((dx (- nx x1))
             (dy (- ny y1))
             (tr (make-translation-transformation dx dy)))
        (with-slots (ink) record
          (setf (graphics-state-ink record)
                (transform-region tr ink))))))

(defrecord-predicate gs-ink-mixin (ink)
  (if-supplied (ink)
    (design-equalp (slot-value record 'ink) ink)))

(defmethod replay-output-record :around
    ((record gs-line-style-mixin) stream &optional region x-offset y-offset)
  (declare (ignore region x-offset y-offset))
  (with-drawing-options (stream :line-style (graphics-state-line-style record))
    (call-next-method)))

(defrecord-predicate gs-line-style-mixin (line-style)
  (if-supplied (line-style)
    (line-style-equalp (slot-value record 'line-style) line-style)))

(defmethod replay-output-record :around
    ((record gs-text-style-mixin) stream &optional region x-offset y-offset)
  (declare (ignore region x-offset y-offset))
  (with-drawing-options (stream :text-style (graphics-state-text-style record))
    (call-next-method)))

(defrecord-predicate gs-text-style-mixin (text-style)
  (if-supplied (text-style)
    (text-style-equalp (slot-value record 'text-style) text-style)))

(defmethod replay-output-record :around
    ((record gs-transformation-mixin) stream &optional region x-offset y-offset)
  (declare (ignore region x-offset y-offset))
  (with-drawing-options (stream :transformation (graphics-state-transformation record))
    (call-next-method)))

(defmethod* (setf output-record-position) :around
  (nx ny (record gs-transformation-mixin))
  (with-standard-rectangle* (x1 y1) record
    (let ((dx (- nx x1))
          (dy (- ny y1)))
      (multiple-value-prog1 (call-next-method)
        (setf #1=(graphics-state-transformation record)
              (compose-transformation-with-translation #1# dx dy))))))

(defrecord-predicate gs-transformation-mixin (transformation)
  (if-supplied (transformation)
    (transformation-equal (graphics-state-transformation record) transformation)))

;;; 16.3.2. Graphics Displayed Output Records
(defclass standard-displayed-output-record
    (gs-ink-mixin basic-output-record displayed-output-record)
  ((ink :reader displayed-output-record-ink)
   (stream :initarg :stream))
  (:documentation "Implementation class for DISPLAYED-OUTPUT-RECORD.")
  (:default-initargs :stream nil))

(defclass standard-graphics-displayed-output-record
    (standard-displayed-output-record
     graphics-displayed-output-record)
  ())

(defmethod match-output-records-1 and
  ((record standard-displayed-output-record)
   &key (x1 nil x1-p) (y1 nil y1-p)
   (x2 nil x2-p) (y2 nil y2-p)
   (bounding-rectangle nil bounding-rectangle-p))
  (if bounding-rectangle-p
      (region-equal record bounding-rectangle)
      (multiple-value-bind (my-x1 my-y1 my-x2 my-y2)
          (bounding-rectangle* record)
        (macrolet ((coordinate=-or-lose (key mine)
                     `(if (typep ,key 'coordinate)
                          (coordinate= ,mine ,key)
                          (error 'type-error
                                 :datum ,key
                                 :expected-type 'coordinate))))
          (and (or (null x1-p)
                   (coordinate=-or-lose x1 my-x1))
               (or (null y1-p)
                   (coordinate=-or-lose y1 my-y1))
               (or (null x2-p)
                   (coordinate=-or-lose x2 my-x2))
               (or (null y2-p)
                   (coordinate=-or-lose y2 my-y2)))))))

(defmethod output-record-equal and ((record standard-displayed-output-record)
                                    (record2 standard-displayed-output-record))
  (region-equal record record2))

(defclass coord-seq-mixin ()
  ((coord-seq :accessor coord-seq :initarg :coord-seq))
  (:documentation "Mixin class that implements methods for records that contain
   sequences of coordinates."))

(defun coord-seq-bounds (coord-seq border)
  (setf border (ceiling border))
  (let* ((min-x (elt coord-seq 0))
         (min-y (elt coord-seq 1))
         (max-x min-x)
         (max-y min-y))
    (do-sequence ((x y) coord-seq)
      (minf min-x x)
      (minf min-y y)
      (maxf max-x x)
      (maxf max-y y))
    (values (floor (- min-x border))
            (floor (- min-y border))
            (ceiling (+ max-x border))
            (ceiling (+ max-y border)))))

;;; record must be a standard-rectangle

(defmethod* (setf output-record-position) :around
    (nx ny (record coord-seq-mixin))
  (with-standard-rectangle* (x1 y1) record
    (let ((dx (- nx x1))
          (dy (- ny y1))
          (coords (slot-value record 'coord-seq)))
      (multiple-value-prog1
          (call-next-method)
        (let ((odd nil))
          (map-into coords
                    (lambda (val)
                      (prog1
                          (if odd
                              (incf val dy)
                              (incf val dx))
                        (setf odd (not odd))))
                    coords))))))

(defun sequence= (seq1 seq2 &optional (test 'equal))
  (and (= (length seq1) (length seq2))
       (every test seq1 seq2)))

(defmethod match-output-records-1 and ((record coord-seq-mixin)
                                       &key (coord-seq nil coord-seq-p))
  (or (null coord-seq-p)
      (let ((my-coord-seq (slot-value record 'coord-seq)))
        (sequence= my-coord-seq coord-seq #'coordinate=))))

(defun fix-line-style-unit (graphic medium)
  (let* ((line-style (graphics-state-line-style graphic))
         (thickness (line-style-effective-thickness line-style medium)))
    (unless (eq (line-style-unit line-style) :normal)
      (let ((dashes (line-style-effective-dashes line-style medium)))
        (setf (slot-value graphic 'line-style)
              (make-line-style :thickness thickness
                               :joint-shape (line-style-joint-shape line-style)
                               :cap-shape (line-style-cap-shape line-style)
                               :dashes dashes))))
    thickness))

(defmacro generate-medium-recording-body (class-name args)
  (let ((arg-list (alexandria:mappend
                   (lambda (arg)
                     (destructuring-bind (name &optional (recording-form nil formp)
                                                         (storep t))
                         (alexandria:ensure-list arg)
                       (when storep
                         `(,(alexandria:make-keyword name)
                           ,(if formp
                                recording-form
                                name)))))
                   args)))
    `(progn
       (when (stream-recording-p stream)
         (let ((record (make-instance ',class-name :stream stream ,@arg-list)))
           (stream-add-output-record stream record)))
       (when (stream-drawing-p stream)
         (call-next-method)))))

;;; DEF-GRECORDING: This is the central interface through which recording is
;;; implemented for drawing functions. The body provided is used to compute the
;;; bounding rectangle of the rendered output. DEF-GRECORDING will define a
;;; class for the output record, with slots corresponding to the drawing
;;; function arguments. It also defines an INITIALIZE-INSTANCE method computing
;;; the bounding rectangle of the record. It defines a method for the medium
;;; drawing function specialized on output-recording-stream, which is
;;; responsible for creating the output record and adding it to the stream
;;; history. It also defines a REPLAY-OUTPUT-RECORD method, which calls the
;;; medium drawing function based on the recorded slots.
;;;
;;; The macro lambda list of DEF-GRECORDING is loosely based on that
;;; of DEFCLASS with a few differences:
;;;
;;; * The name can either be just a symbol or a list of a symbol followed by
;;;   keyword arguments which control what aspects should be generated: class,
;;;   medium-fn and replay-fn.
;;;
;;; * Instead of slot specifications, a list of argument descriptions is
;;;   supplied which is used to defined slots as well as arguments.  An argument
;;;   is either a symbol or a list of the form (NAME INITFORM STOREP) where
;;;   INITFORM computes the value to store in the output record and STOREP
;;;   controls whether a slot for the argument should be present in the output
;;;   record at all.
;;;
;;; * DEFCLASS options are not accepted, but a body is, as described above.
(defmacro def-grecording (name-and-options (&rest mixins) (&rest args)
                          &body body)
  (destructuring-bind (name &key (class t) (medium-fn t) (replay-fn t))
      (alexandria:ensure-list name-and-options)
    (let* ((method-name (symbol-concat '#:medium- name '*))
           (class-name (symbol-concat name '#:-output-record))
           (medium (gensym "MEDIUM"))
           (arg-names (mapcar #'alexandria:ensure-car args))
           (slot-names (alexandria:mappend
                        (lambda (arg)
                          (destructuring-bind (name &optional form (storep t))
                              (alexandria:ensure-list arg)
                            (declare (ignore form))
                            (when storep `(,name))))
                        args))
           (slots `((stream :initarg :stream)
                    ,@(loop for slot-name in slot-names
                            for initarg = (alexandria:make-keyword slot-name)
                            collect `(,slot-name :initarg ,initarg)))))
      `(progn
         ,@(when class
             `((defclass ,class-name (,@mixins standard-graphics-displayed-output-record)
                 ,slots)
               (defmethod initialize-instance :after ((graphic ,class-name) &key)
                 (with-slots (stream ink line-style text-style ,@slot-names)
                     graphic
                   (let ((medium (sheet-medium stream)))
                     (setf (rectangle-edges* graphic)
                           (progn ,@body)))))))
         ,@(when medium-fn
             `((defmethod ,method-name :around ((stream output-recording-stream) ,@arg-names)
                 ;; XXX STANDARD-OUTPUT-RECORDING-STREAM ^?
                 (generate-medium-recording-body ,class-name ,args))))
         ,@(when replay-fn
             `((defmethod replay-output-record ((record ,class-name) stream
                                                &optional (region +everywhere+)
                                                  (x-offset 0) (y-offset 0))
                 (declare (ignore x-offset y-offset region))
                 (with-slots (,@slot-names) record
                   (let ((,medium (sheet-medium stream)))
                     ;; Graphics state is set up in :around method.
                     (,method-name ,medium ,@arg-names))))))))))

(def-grecording draw-point (gs-line-style-mixin)
    (point-x point-y)
  (let ((border (/ (fix-line-style-unit graphic medium) 2)))
    (with-transformed-position ((medium-transformation medium) point-x point-y)
      (setf (slot-value graphic 'point-x) point-x
            (slot-value graphic 'point-y) point-y)
      (values (- point-x border)
              (- point-y border)
              (+ point-x border)
              (+ point-y border)))))

(defmethod* (setf output-record-position) :around
    (nx ny (record draw-point-output-record))
    (with-standard-rectangle* (x1 y1) record
      (with-slots (point-x point-y) record
        (let ((dx (- nx x1))
              (dy (- ny y1)))
          (multiple-value-prog1
              (call-next-method)
            (incf point-x dx)
            (incf point-y dy))))))

(defrecord-predicate draw-point-output-record (point-x point-y)
  (and (if-supplied (point-x coordinate)
         (coordinate= (slot-value record 'point-x) point-x))
       (if-supplied (point-y coordinate)
         (coordinate= (slot-value record 'point-y) point-y))))

;;; Initialize the output record with a copy of COORD-SEQ, as the replaying code
;;; will modify it to be positioned relative to the output-record's position and
;;; making a temporary is (arguably) less bad than untransforming the coords
;;; back to how they were.
(def-grecording draw-points (coord-seq-mixin gs-line-style-mixin)
    ((coord-seq (copy-sequence-into-vector coord-seq)))
  (let* ((transformed-coord-seq (transform-positions (medium-transformation medium) coord-seq))
         (border (/ (fix-line-style-unit graphic medium) 2)))
    (setf (slot-value graphic 'coord-seq) transformed-coord-seq)
    (coord-seq-bounds transformed-coord-seq border)))

(def-grecording draw-line (gs-line-style-mixin)
    (point-x1 point-y1 point-x2 point-y2)
  (let* ((transform (medium-transformation medium))
         (border (/ (fix-line-style-unit graphic medium) 2)))
    (with-transformed-position (transform point-x1 point-y1)
      (with-transformed-position (transform point-x2 point-y2)
        (setf (slot-value graphic 'point-x1) point-x1
              (slot-value graphic 'point-y1) point-y1
              (slot-value graphic 'point-x2) point-x2
              (slot-value graphic 'point-y2) point-y2)
        (values (- (min point-x1 point-x2) border)
                (- (min point-y1 point-y2) border)
                (+ (max point-x1 point-x2) border)
                (+ (max point-y1 point-y2) border))))))

(defmethod* (setf output-record-position) :around
    (nx ny (record draw-line-output-record))
  (with-standard-rectangle* (x1 y1) record
    (with-slots (point-x1 point-y1 point-x2 point-y2) record
      (let ((dx (- nx x1))
            (dy (- ny y1)))
        (multiple-value-prog1
            (call-next-method)
          (incf point-x1 dx)
          (incf point-y1 dy)
          (incf point-x2 dx)
          (incf point-y2 dy))))))

(defrecord-predicate draw-line-output-record (point-x1 point-y1
                                              point-x2 point-y2)
  (and (if-supplied (point-x1 coordinate)
         (coordinate= (slot-value record 'point-x1) point-x1))
       (if-supplied (point-y1 coordinate)
         (coordinate= (slot-value record 'point-y1) point-y1))
       (if-supplied (point-x2 coordinate)
         (coordinate= (slot-value record 'point-x2) point-x2))
       (if-supplied (point-y2 coordinate)
         (coordinate= (slot-value record 'point-y2) point-y2))))

;;; Regarding COORD-SEQ, see comment for DRAW-POINTS.
(def-grecording draw-lines (coord-seq-mixin gs-line-style-mixin)
    ((coord-seq (copy-sequence-into-vector coord-seq)))
  (let* ((transformation (medium-transformation medium))
         (transformed-coord-seq (transform-positions transformation coord-seq))
         (border (/ (fix-line-style-unit graphic medium) 2)))
    (setf coord-seq transformed-coord-seq)
    (coord-seq-bounds transformed-coord-seq border)))

;;; (setf output-record-position) and predicates for draw-lines-output-record
;;; are taken care of by methods on superclasses.

;;; Helper function
(defun normalize-coords (dx dy &optional unit)
  (let ((norm (sqrt (+ (* dx dx) (* dy dy)))))
    (cond ((= norm 0.0d0)
           (values 0.0d0 0.0d0))
          (unit
           (let ((scale (/ unit norm)))
             (values (* dx scale) (* dy scale))))
          (t (values (/ dx norm) (/ dy norm))))))

(defun polygon-record-bounding-rectangle
    (coord-seq closed filled line-style border miter-limit)
  (cond (filled
         (coord-seq-bounds coord-seq 0))
        ((eq (line-style-joint-shape line-style) :round)
         (coord-seq-bounds coord-seq border))
        (t (let* ((x1 (elt coord-seq 0))
                  (y1 (elt coord-seq 1))
                  (min-x x1)
                  (min-y y1)
                  (max-x x1)
                  (max-y y1)
                  (len (length coord-seq)))
             (unless closed
               (setq min-x (- x1 border)  min-y (- y1 border)
                     max-x (+ x1 border)  max-y (+ y1 border)))
             ;; Setup for iterating over the coordinate vector.  If
             ;; the polygon is closed, deal with the extra segment.
             (multiple-value-bind (initial-xp initial-yp
                                   final-xn final-yn
                                   initial-index final-index)
                 (if closed
                     (values (elt coord-seq (- len 2))
                             (elt coord-seq (- len 1))
                             x1 y1
                             0 (- len 2))
                     (values x1 y1
                             (elt coord-seq (- len 2))
                             (elt coord-seq (- len 1))
                             2 (- len 4)))
               (ecase (line-style-joint-shape line-style)
                 (:miter
                  ;; FIXME: Remove successive positively proportional segments
                  (loop with sin-limit = (sin (* 0.5 miter-limit))
                        and xn and yn
                        for i from initial-index to final-index by 2
                        for xp = initial-xp then x
                        for yp = initial-yp then y
                        for x = (elt coord-seq i)
                        for y = (elt coord-seq (1+ i))
                        do (setf (values xn yn)
                                 (if (eql i final-index)
                                     (values final-xn final-yn)
                                     (values (elt coord-seq (+ i 2))
                                             (elt coord-seq (+ i 3)))))
                           (multiple-value-bind (ex1 ey1)
                               (normalize-coords (- x xp) (- y yp))
                             (multiple-value-bind (ex2 ey2)
                                 (normalize-coords (- x xn) (- y yn))
                               (let ((cos-a)
                                     (sin-a/2))
                                 (cond ((or (and (zerop ex1) (zerop ey2)) ; axis-aligned right angle
                                            (and (zerop ey1) (zerop ex2)))
                                        (minf min-x (- x border))
                                        (minf min-y (- y border))
                                        (maxf max-x (+ x border))
                                        (maxf max-y (+ y border)))
                                       ((progn
                                          (setf cos-a (+ (* ex1 ex2) (* ey1 ey2))
                                                sin-a/2 (sqrt (* 0.5 (max 0 (- 1.0f0 cos-a)))))
                                          (< sin-a/2 sin-limit)) ; almost straight, any direction
                                        (let ((nx (* border (max (abs ey1) (abs ey2))))
                                              (ny (* border (max (abs ex1) (abs ex2)))))
                                          (minf min-x (- x nx))
                                          (minf min-y (- y ny))
                                          (maxf max-x (+ x nx))
                                          (maxf max-y (+ y ny))))
                                       (t ; general case
                                        (let ((length (/ border sin-a/2)))
                                          (multiple-value-bind (dx dy)
                                              (normalize-coords (+ ex1 ex2)
                                                                (+ ey1 ey2)
                                                                length)
                                            (minf min-x (+ x dx))
                                            (minf min-y (+ y dy))
                                            (maxf max-x (+ x dx))
                                            (maxf max-y (+ y dy)))))))))))
                 ((:bevel :none)
                  (loop with xn and yn
                        for i from initial-index to final-index by 2
                        for xp = initial-xp then x
                        for yp = initial-yp then y
                        for x = (elt coord-seq i)
                        for y = (elt coord-seq (1+ i))
                        do (setf (values xn yn)
                                 (if (eql i final-index)
                                     (values final-xn final-yn)
                                     (values (elt coord-seq (+ i 2))
                                             (elt coord-seq (+ i 3)))))
                           (multiple-value-bind (ex1 ey1)
                               (normalize-coords (- x xp) (- y yp))
                             (multiple-value-bind (ex2 ey2)
                                 (normalize-coords (- x xn) (- y yn))
                               (let ((nx (* border (max (abs ey1) (abs ey2))))
                                     (ny (* border (max (abs ex1) (abs ex2)))))
                                 (minf min-x (- x nx))
                                 (minf min-y (- y ny))
                                 (maxf max-x (+ x nx))
                                 (maxf max-y (+ y ny))))))))
               (unless closed
                 (multiple-value-bind (x y)
                     (values (elt coord-seq (- len 2))
                             (elt coord-seq (- len 1)))
                   (minf min-x (- x border))
                   (minf min-y (- y border))
                   (maxf max-x (+ x border))
                   (maxf max-y (+ y border)))))
             (values min-x min-y max-x max-y)))))

(defun bezigon-record-bounding-rectangle (coord-seq filled border)
  (if filled
      (setf border 0)
      (setf border (ceiling border)))
  (let* ((min-x (elt coord-seq 0))
         (min-y (elt coord-seq 1))
         (max-x min-x)
         (max-y min-y))
    (map-over-bezigon-segments*
     (lambda (x0 y0 x1 y1 x2 y2 x3 y3)
       (multiple-value-bind (x1 x2) (cubic-bezier-dimension-min-max x0 x1 x2 x3)
         (minf min-x x1)
         (maxf max-x x2))
       (multiple-value-bind (y1 y2) (cubic-bezier-dimension-min-max y0 y1 y2 y3)
         (minf min-y y1)
         (maxf max-y y2)))
     coord-seq 4)
    (values (floor (- min-x border))
            (floor (- min-y border))
            (ceiling (+ max-x border))
            (ceiling (+ max-y border)))))

;;; Regarding COORD-SEQ, see comment for DRAW-POINTS.
(def-grecording draw-polygon (coord-seq-mixin gs-line-style-mixin)
    ((coord-seq (copy-sequence-into-vector coord-seq))
     closed filled)
  (let* ((transform (medium-transformation medium))
         (transformed-coord-seq (transform-positions transform coord-seq))
         (border (unless filled
                   (/ (fix-line-style-unit graphic medium) 2))))
    (setf coord-seq transformed-coord-seq)
    (polygon-record-bounding-rectangle transformed-coord-seq
                                       closed filled line-style border
                                       (medium-miter-limit medium))))

(defrecord-predicate draw-polygon-output-record (closed filled)
  (and (if-supplied (closed)
         (eql (slot-value record 'closed) closed))
       (if-supplied (filled)
         (eql (slot-value record 'filled) filled))))

(def-grecording draw-bezigon (coord-seq-mixin gs-line-style-mixin)
    ((coord-seq (copy-sequence-into-vector coord-seq))
     filled)
  (let* ((transform (medium-transformation medium))
         (transformed-coord-seq (transform-positions transform coord-seq))
         (border (unless filled
                   (/ (fix-line-style-unit graphic medium) 2))))
    (setf coord-seq transformed-coord-seq)
    (bezigon-record-bounding-rectangle transformed-coord-seq filled border)))

(defrecord-predicate draw-bezigon-output-record (filled)
  (if-supplied (filled)
    (eql (slot-value record 'filled) filled)))

(def-grecording (draw-rectangle :medium-fn nil) (gs-line-style-mixin)
    (left top right bottom filled)
  (let* ((transform (medium-transformation medium))
         (pre-coords (expand-rectangle-coords left top right bottom))
         (coords (transform-positions transform pre-coords))
         (border (unless filled
                   (/ (fix-line-style-unit graphic medium) 2))))
    (setf (values left top) (transform-position transform left top))
    (setf (values right bottom) (transform-position transform right bottom))
    (polygon-record-bounding-rectangle coords t filled line-style border
                                       (medium-miter-limit medium))))

(defmethod medium-draw-rectangle* :around ((stream output-recording-stream)
                                           left top right bottom filled)
  (let ((tr (medium-transformation stream)))
    (if (rectilinear-transformation-p tr)
        (generate-medium-recording-body draw-rectangle-output-record
                                        (left top right bottom filled))
        (medium-draw-polygon* stream
                              (expand-rectangle-coords left top right bottom)
                              t
                              filled))))

(def-grecording (draw-rectangles :medium-fn nil) (coord-seq-mixin gs-line-style-mixin)
    (coord-seq filled)
  (let* ((transform (medium-transformation medium))
         (border (unless filled
                   (/ (fix-line-style-unit graphic medium) 2))))
    (let ((transformed-coord-seq
            (map-repeated-sequence 'vector 2
                                   (lambda (x y)
                                     (with-transformed-position (transform x y)
                                       (values x y)))
                                   coord-seq)))
      (polygon-record-bounding-rectangle transformed-coord-seq
                                         t filled line-style border
                                         (medium-miter-limit medium)))))

(defmethod medium-draw-rectangles* :around ((stream output-recording-stream)
                                            coord-seq filled)
  (let ((tr (medium-transformation stream)))
    (if (rectilinear-transformation-p tr)
        (generate-medium-recording-body
         draw-rectangles-output-record
         ((coord-seq (copy-sequence-into-vector coord-seq)) filled))
        (do-sequence ((left top right bottom) coord-seq)
          (medium-draw-polygon* stream (vector left top
                                               left bottom
                                               right bottom
                                               right top)
                                t filled)))))

(defmethod medium-clear-area :around ((medium output-recording-stream) left top right bottom)
  (declare (ignore left top right bottom))
  (when (stream-drawing-p medium)
    (call-next-method)))

(defmethod* (setf output-record-position) :around
  (nx ny (record draw-rectangle-output-record))
  (with-standard-rectangle* (x1 y1) record
    (with-slots (left top right bottom) record
      (let ((dx (- nx x1))
            (dy (- ny y1)))
        (multiple-value-prog1
            (call-next-method)
          (incf left dx)
          (incf top dy)
          (incf right dx)
          (incf bottom dy))))))

(defrecord-predicate draw-rectangle-output-record (left top right bottom filled)
  (and (if-supplied (left coordinate)
         (coordinate= (slot-value record 'left) left))
       (if-supplied (top coordinate)
         (coordinate= (slot-value record 'top) top))
       (if-supplied (right coordinate)
         (coordinate= (slot-value record 'right) right))
       (if-supplied (bottom coordinate)
         (coordinate= (slot-value record 'bottom) bottom))
       (if-supplied (filled)
         (eql (slot-value record 'filled) filled))))

(def-grecording draw-ellipse (gs-line-style-mixin)
    (center-x center-y radius-1-dx radius-1-dy radius-2-dx radius-2-dy
     start-angle end-angle filled)
  (let ((transform (medium-transformation medium)))
    (setf (values center-x center-y)
          (transform-position transform center-x center-y))
    (setf (values radius-1-dx radius-1-dy)
          (transform-distance transform radius-1-dx radius-1-dy))
    (setf (values radius-2-dx radius-2-dy)
          (transform-distance transform radius-2-dx radius-2-dy))
    ;; We untransform-angle below, as the ellipse angles go counter-clockwise
    ;; in screen coordinates, whereas our transformations rotate clockwise in
    ;; the default coorinate system. -Hefner
    (setf start-angle (untransform-angle transform start-angle))
    (setf end-angle   (untransform-angle transform end-angle))
    (when (reflection-transformation-p transform)
      (rotatef start-angle end-angle))
    (multiple-value-setq (start-angle end-angle)
      (normalize-angle* start-angle end-angle))
    (multiple-value-bind (min-x min-y max-x max-y)
        (ellipse-bounding-rectangle*
         center-x center-y radius-1-dx radius-1-dy radius-2-dx radius-2-dy
         start-angle end-angle filled)
      (if filled
          (values min-x min-y max-x max-y)
          (let ((border (/ (fix-line-style-unit graphic medium) 2)))
            (values (floor (- min-x border))
                    (floor (- min-y border))
                    (ceiling (+ max-x border))
                    (ceiling (+ max-y border))))))))

(defmethod* (setf output-record-position) :around
    (nx ny (record draw-ellipse-output-record))
  (with-standard-rectangle* (x1 y1) record
    (with-slots (center-x center-y) record
      (let ((dx (- nx x1))
            (dy (- ny y1)))
        (multiple-value-prog1
            (call-next-method)
          (incf center-x dx)
          (incf center-y dy))))))

(defrecord-predicate draw-ellipse-output-record (center-x center-y filled)
  (and (if-supplied (center-x coordinate)
                    (coordinate= (slot-value record 'center-x) center-x))
       (if-supplied (center-y coordinate)
                    (coordinate= (slot-value record 'center-y) center-y))
       (if-supplied (filled)
                    (eql (slot-value record 'filled) filled))))

;;; Patterns

;;; Text

(declaim (inline %enclosing-transform-polygon))
(defun %enclosing-transform-polygon (transformation x1 y1 x2 y2)
  (let (min-x min-y max-x max-y)
    (setf (values min-x min-y) (transform-position transformation x1 y1)
          (values max-x max-y) (values min-x min-y))
    (flet ((do-point (x y)
             (with-transformed-position (transformation x y)
               (cond ((< x min-x)
                      (setf min-x x))
                     ((> x max-x)
                      (setf max-x x)))
               (cond ((< y min-y)
                      (setf min-y y))
                     ((> y max-y)
                      (setf max-y y))))))
      (do-point x1 y2)
      (do-point x2 y1)
      (do-point x2 y2))
    (values min-x min-y max-x max-y)))

(def-grecording (draw-text :replay-fn nil) (gs-text-style-mixin gs-transformation-mixin)
    ((string (subseq string (or start 0) end))
     point-x point-y
     (start  nil nil)
     (end    nil nil)
     align-x align-y
     toward-x toward-y transform-glyphs)
  ;; FIXME Text direction.
  ;; FIXME This interpretation of TRANSFORM-GLYPHS is incorrect.
  (let* ((transformation (graphics-state-transformation medium))
         (text-style (graphics-state-text-style graphic)))
    (multiple-value-bind (left top right bottom)
        (text-bounding-rectangle* medium string
                                  :align-x align-x :align-y align-y
                                  :text-style text-style)
      (if transform-glyphs
          (%enclosing-transform-polygon
           transformation
           (+ point-x left) (+ point-y top) (+ point-x right) (+ point-y bottom))
          (with-transformed-position (transformation point-x point-y)
            (values (+ point-x left) (+ point-y top)
                    (+ point-x right) (+ point-y bottom)))))))

(defmethod replay-output-record
    ((record draw-text-output-record) stream
     &optional (region +everywhere+) (x-offset 0) (y-offset 0))
  (declare (ignore x-offset y-offset region))
  (with-slots (string point-x point-y align-x align-y toward-x
               toward-y transform-glyphs transformation)
      record
    (let ((medium (sheet-medium stream)))
      (medium-draw-text* medium string point-x point-y 0 nil align-x
                         align-y toward-x toward-y transform-glyphs))))

#+ (or) ;; See the :around method on GS-TRANSFORMATION-MIXIN.
(defmethod* (setf output-record-position) :around
  (nx ny (record draw-text-output-record))
  (with-standard-rectangle* (x1 y1) record
    (with-slots (point-x point-y toward-x toward-y) record
      (let ((dx (- nx x1))
            (dy (- ny y1)))
        (multiple-value-prog1
            (call-next-method)
          (incf point-x dx)
          (incf point-y dy)
          (incf toward-x dx)
          (incf toward-y dy))))))

(defrecord-predicate draw-text-output-record
    (string (start nil) (end nil) ; START, END are keyword arguments but not slots
     point-x point-y align-x align-y toward-x toward-y transform-glyphs)
  ;; Compare position first because it is cheap and an update is most
  ;; likely to change the position.
  (and (if-supplied (point-x coordinate)
         (coordinate= (slot-value record 'point-x) point-x))
       (if-supplied (point-y coordinate)
         (coordinate= (slot-value record 'point-y) point-y))
       ;; START and END can be supplied as keyword arguments, but the
       ;; output record does not store them in slots. For
       ;; MATCH-OUTPUT-RECORDS-1, compare the designated subsequence
       ;; of the STRING keyword argument to the entire string stored
       ;; in the output record.
       (if-supplied (string)
         (let ((start2 0)
               (end2 nil))
           (if-supplied (start) (setf start2 start))
           (if-supplied (end) (setf end2 end))
           (string= (slot-value record 'string) string
                    :start2 start2 :end2 end2)))
       (if-supplied (align-x)
         (eq (slot-value record 'align-x) align-x))
       (if-supplied (align-y)
         (eq (slot-value record 'align-y) align-y))
       (if-supplied (toward-x coordinate)
         (coordinate= (slot-value record 'toward-x) toward-x))
       (if-supplied (toward-y coordinate)
         (coordinate= (slot-value record 'toward-y) toward-y))
       (if-supplied (transform-glyphs)
         (eq (slot-value record 'transform-glyphs) transform-glyphs))))

;;; 16.3.3. Text Displayed Output Record

(defclass styled-string (gs-text-style-mixin gs-ink-mixin)
  ((start-x :initarg :start-x)
   (string :initarg :string :reader styled-string-string)))

(defmethod output-record-equal and ((record styled-string)
                                    (record2 styled-string))
  (and (coordinate= (slot-value record 'start-x)
                    (slot-value record2 'start-x))
       (string= (slot-value record 'string)
                (slot-value record2 'string))))

;;; The STANDARD-TEXT-DISPLAYED-OUTPUT-RECORD represents a single line of text
;;; composed of styled strings that may have different text styles. There are
;;; two metrics that need to be accounted for with each added string:
;;;
;;; The text line metrics, that is the record initial position, the line width,
;;; height and baseline. Slots: START-X, START-Y, WIDTH, HEIGHT, BASELINE.
;;; Redundantly slots END-X and END-Y are stored for conveniance.
;;;
;;; The glyph metrics (see TEXT-BOUNDING-RECTANGLE*). Glyph may have left and
;;; right bearings and they may reach that reach outside of the line bounding
;;; rectangle. Slots LEFT and RIGHT have the extreme bounds of the record.
;;;
;;; -- jd 2021-11-14
(defclass standard-text-displayed-output-record
    (text-displayed-output-record standard-displayed-output-record)
  (;; All strings making the output record.
   (strings :initform nil)
   ;; The initial position of the output record.
   (initial-x1 :initarg :start-x)
   (initial-y1 :initarg :start-y)
   ;; The text line dimensions.
   (width :initform 0)
   (height :initform nil)
   (baseline :initform 0)
   ;; Bounding box left and right including the glyph bearings.
   (left :initarg :start-x)
   (right :initarg :start-x)
   ;; The current position of the output record.
   (start-x :initarg :start-x)
   (start-y :initarg :start-y)
   (end-x :initarg :start-x)
   (end-y :initarg :start-y)
   (medium :initform nil)))

(defmethod initialize-instance :after
    ((obj standard-text-displayed-output-record) &key stream)
  (with-slots (medium height) obj
    (setf medium (sheet-medium stream)
          height (text-style-height (stream-text-style stream) stream))))

;;; Forget match-output-records-1 for standard-text-displayed-output-record; it
;;; doesn't make much sense because these records have state that is not
;;; initialized via initargs.

(defmethod output-record-equal and
    ((record standard-text-displayed-output-record)
     (record2 standard-text-displayed-output-record))
  (with-slots
        (initial-x1 initial-y1 start-x start-y left right end-x end-y strings)
      record2
    (and (coordinate= (slot-value record 'initial-x1) initial-x1)
         (coordinate= (slot-value record 'initial-y1) initial-y1)
         (coordinate= (slot-value record 'start-x) start-x)
         (coordinate= (slot-value record 'start-y) start-y)
         (coordinate= (slot-value record 'left) left)
         (coordinate= (slot-value record 'right) right)
         (coordinate= (slot-value record 'end-x) end-x)
         (coordinate= (slot-value record 'end-y) end-y)
         (coordinate= (slot-value record 'baseline)
                      (slot-value record2 'baseline))
         (eql (length (slot-value record 'strings)) (length strings));XXX
         (loop for s1 in (slot-value record 'strings)
               for s2 in strings
               always (output-record-equal s1 s2)))))

(defmethod print-object ((self standard-text-displayed-output-record) stream)
  (print-unreadable-object (self stream :type t :identity t)
    (with-slots (start-x start-y strings) self
      (format stream "~D,~D ~S"
              start-x start-y
              (mapcar #'styled-string-string strings)))))

(defmethod* (setf output-record-position) :around
    (nx ny (record standard-text-displayed-output-record))
  (with-standard-rectangle* (x1 y1) record
    (with-slots (start-x start-y end-x end-y strings baseline) record
      (let ((dx (- nx x1))
            (dy (- ny y1)))
        (multiple-value-prog1
            (call-next-method)
          (incf start-x dx)
          (incf start-y dy)
          (incf end-x dx)
          (incf end-y dy)
          (loop for s in strings
                do (incf (slot-value s 'start-x) dx)))))))

(defmethod replay-output-record ((record standard-text-displayed-output-record)
                                 stream
                                 &optional region (x-offset 0) (y-offset 0))
  (declare (ignore region x-offset y-offset))
  (with-slots (strings baseline start-y) record
    (with-sheet-medium (medium stream) ;is sheet a sheet-with-medium-mixin? --GB
      ;; FIXME:
      ;; 1. SLOT-VALUE...
      ;; 2. It should also save a "current line".
      (setf (slot-value stream 'baseline) baseline)
      (loop for substring in strings
         do (with-slots (start-x string) substring
              ;; FIXME: a bit of an abstraction inversion.  Should the styled
              ;; strings here not simply be output records?  Then we could just
              ;; replay them and all would be well.  -- CSR, 20060528.
              ;;
              ;; But then we'd have to implement the output record
              ;; protocols for them. Are we allowed no internal
              ;; structure of our own? -- Hefner, 20080118

              ;; Some optimization might be possible here.
              (with-identity-transformation (stream)
                (with-drawing-options (stream :ink (graphics-state-ink substring)
                                              :text-style (graphics-state-text-style substring))
                  (draw-text* (sheet-medium stream)
                              string start-x (+ start-y (stream-baseline stream))))))))))

(defmethod output-record-start-cursor-position
    ((record standard-text-displayed-output-record))
  (with-slots (start-x start-y) record
    (values start-x start-y)))

(defmethod output-record-end-cursor-position
    ((record standard-text-displayed-output-record))
  (with-slots (end-x end-y) record
    (values end-x end-y)))

(defmethod tree-recompute-extent
    ((text-record standard-text-displayed-output-record))
  (with-standard-rectangle* (nil y1) text-record
    (with-slots (height left right) text-record
      (setf (rectangle-edges* text-record)
            (values (coordinate left)
                    y1
                    (coordinate right)
                    (coordinate (+ y1 height))))))
  text-record)

(defmethod add-character-output-to-text-record
    ((text-record standard-text-displayed-output-record)
     character text-style char-width line-height new-baseline
     &aux (start 0) (end 1))
  (add-string-output-to-text-record text-record character
                                    start end text-style
                                    char-width line-height new-baseline))

(defmethod add-string-output-to-text-record
    ((text-record standard-text-displayed-output-record)
     string start end text-style string-width line-height new-baseline)
  (setf end (or end (etypecase string
                      (character 1)
                      (string (length string)))))
  (let ((length (max 0 (- end start))))
    (with-slots (strings baseline width height
                 left right start-y end-x end-y medium)
        text-record
      (let* ((strings-last-cons (last strings))
             (last-string (first strings-last-cons)))
        (if (and last-string
                 (match-output-records last-string
                                       :text-style text-style
                                       :ink (medium-ink medium)
                                       :clipping-region (medium-clipping-region medium)))
            ;; Simply append the string to the last one.
            (let* ((last-string (styled-string-string last-string))
                   (last-string-length (length last-string))
                   (start1 (length last-string))
                   (end1 (+ start1 length)))
              (when (< (array-dimension last-string 0) end1)
                (adjust-array last-string (max end1 (* 2 last-string-length))))
              (setf (fill-pointer last-string) end1)
              (etypecase string
                (character (setf (char last-string (1- end1)) string))
                (string (replace last-string string
                                 :start1 start1 :end1 end1
                                 :start2 start :end2 end))))
            (let ((styled-string (make-instance
                                  'styled-string
                                  :start-x end-x
                                  :text-style text-style
                                  :medium medium
                                  :string (make-array length
                                                      :element-type 'character
                                                      :adjustable t
                                                      :fill-pointer t))))
              (nconcf strings (list styled-string))
              (etypecase string
                (character (setf (char last-string 0) string))
                (string (replace (styled-string-string styled-string) string
                                 :start2 start :end2 end))))))
      (multiple-value-bind (minx miny maxx maxy)
          (text-bounding-rectangle* medium string
                                    :text-style text-style
                                    :start start :end end)
        (declare (ignore miny maxy))
        (setq baseline (max baseline new-baseline)
              ;; KLUDGE: note that END-X here really means
              ;; START-X of the new string.
              left (min left (+ end-x minx))
              end-x (+ end-x string-width)
              right (+ end-x (max 0 (- maxx string-width)))
              height (max height line-height)
              end-y (max end-y (+ start-y height))
              width (+ width string-width))))
    (tree-recompute-extent text-record)))

(defmethod text-displayed-output-record-string
    ((record standard-text-displayed-output-record))
  (with-slots (strings) record
    (if (= 1 (length strings))
        (styled-string-string (first strings))
        (with-output-to-string (result)
          (loop for styled-string in strings
            do (write-string (styled-string-string styled-string) result))))))

;;; 16.3.4. Top-Level Output Records

(defclass standard-sequence-output-history
    (standard-sequence-output-record stream-output-history-mixin)
  ())

(defclass standard-tree-output-history
    (standard-tree-output-record stream-output-history-mixin)
  ())

;;; 16.4. Output Recording Streams
(defclass standard-output-recording-stream (output-recording-stream)
  ((recording-p :initform t :reader stream-recording-p)
   (drawing-p :initform t :accessor stream-drawing-p)
   (output-history :initform (make-instance 'standard-tree-output-history)
                   :initarg :output-record
                   :reader stream-output-history)
   (current-output-record :accessor stream-current-output-record)
   (current-text-output-record :initform nil
                               :accessor stream-current-text-output-record))
  (:documentation "This class is mixed into some other stream class to
add output recording facilities. It is not instantiable."))

(defmethod initialize-instance :after
    ((stream standard-output-recording-stream) &rest args)
  (declare (ignore args))
  (let ((history (stream-output-history stream)))
    (setf (slot-value history 'stream) stream
          (slot-value stream 'output-history) history
          (stream-current-output-record stream) history)))

;;; 16.4.1 The Output Recording Stream Protocol
(defmethod (setf stream-recording-p)
    (recording-p (stream standard-output-recording-stream))
  (let ((old-val (slot-value stream 'recording-p)))
    (unless (eq old-val recording-p)
      (setf (slot-value stream 'recording-p) recording-p)
      (stream-close-text-output-record stream))
    recording-p))

(defmethod stream-add-output-record
    ((stream standard-output-recording-stream) record)
  (add-output-record record (stream-current-output-record stream)))

(defmethod stream-replay ((stream standard-output-recording-stream)
                          &optional (region (sheet-visible-region stream)))
  (replay (stream-output-history stream) stream region))

(defun output-record-ancestor-p (ancestor child)
  (loop for record = child then parent
     for parent = (output-record-parent record)
     when (eq parent nil) do (return nil)
     when (eq parent ancestor) do (return t)))

(defmethod erase-output-record (record (stream standard-output-recording-stream)
                                &optional (errorp t))
  (with-output-recording-options (stream :record nil)
    (let ((region (rounded-bounding-rectangle record))
          (parent (output-record-parent record)))
      (cond
        ((output-record-ancestor-p (stream-output-history stream) record)
         (delete-output-record record parent))
        (errorp
         (error "~S is not contained in ~S." record stream)))
      (with-bounding-rectangle* (x1 y1 x2 y2) region
        (draw-rectangle* stream x1 y1 x2 y2 :ink +background-ink+)
        (stream-replay stream region)))))

;;; 16.4.3. Text Output Recording
(defmethod stream-text-output-record
    ((stream standard-output-recording-stream) text-style)
  (declare (ignore text-style))
  (let ((record (stream-current-text-output-record stream)))
    (unless (and record (typep record 'standard-text-displayed-output-record))
      (multiple-value-bind (cx cy) (stream-cursor-position stream)
        (setf record (make-instance 'standard-text-displayed-output-record
                                    :x-position cx :y-position cy
                                    :start-x cx :start-y cy
                                    :stream stream)
              (stream-current-text-output-record stream) record)))
    record))

(defmethod stream-close-text-output-record ((stream standard-output-recording-stream))
  (when-let ((record (stream-current-text-output-record stream)))
    (setf (stream-current-text-output-record stream) nil)
    #|record stream-current-cursor-position to (end-x record) - already done|#
    (stream-add-output-record stream record)
    ;; STREAM-WRITE-OUTPUT on recorded stream inhibits eager drawing to collect
    ;; whole output record in order to align line's baseline between strings of
    ;; different height. See \"15.3 The Text Cursor\". -- jd 2019-01-07
    (when (stream-drawing-p stream)
      (replay record stream))))

(defmethod stream-add-character-output ((stream standard-output-recording-stream)
                                        character text-style width height baseline)
  (add-character-output-to-text-record (stream-text-output-record stream text-style)
                                       character text-style width height baseline))

(defmethod stream-add-string-output ((stream standard-output-recording-stream)
                                     string start end text-style
                                     width height baseline)
  (add-string-output-to-text-record (stream-text-output-record stream text-style)
                                    string start end text-style
                                    width height baseline))

;;; Text output catching methods
(defmethod stream-write-output ((stream standard-output-recording-stream) line
                                &optional (start 0) end)
  (unless (stream-recording-p stream)
    (return-from stream-write-output
      ;; Stream will replay output when the output record is closed to maintain
      ;; the baseline. If we are not recording and this method is invoked we
      ;; draw string eagerly (if it is set for drawing). -- jd 2019-01-07
      (when (stream-drawing-p stream)
        (call-next-method))))
  (let* ((medium (sheet-medium stream))
         (text-style (medium-text-style medium))
         (height (text-style-height text-style medium))
         (ascent (text-style-ascent text-style medium)))
    (if (characterp line)
        (stream-add-character-output stream line text-style
                                     (stream-character-width
                                      stream line :text-style text-style)
                                     height
                                     ascent)
        (stream-add-string-output stream line start end text-style
                                  (stream-string-width stream line
                                                       :start start :end end
                                                       :text-style text-style)
                                  height
                                  ascent))))

(defmethod stream-finish-output :after ((stream standard-output-recording-stream))
  (stream-close-text-output-record stream))

(defmethod stream-force-output :after ((stream standard-output-recording-stream))
  (stream-close-text-output-record stream))

(defmethod stream-terpri :after ((stream standard-output-recording-stream))
  (stream-close-text-output-record stream))

(defmethod* (setf stream-cursor-position) :after (x y (stream standard-output-recording-stream))
  (declare (ignore x y))
  (stream-close-text-output-record stream))

;;; 16.4.4. Output Recording Utilities

(defmethod invoke-with-output-recording-options
  ((stream output-recording-stream) continuation record draw)
  "Calls CONTINUATION on STREAM enabling or disabling recording and drawing
according to the flags RECORD and DRAW."
  (letf (((stream-recording-p stream) record)
         ((stream-drawing-p stream) draw))
    (funcall continuation stream)))

(defmethod invoke-with-new-output-record
    ((stream output-recording-stream) continuation record-type
     &rest initargs &key parent)
  (with-keywords-removed (initargs (:parent))
    (stream-close-text-output-record stream)
    (let ((new-record (apply #'make-instance record-type initargs)))
      (letf (((stream-current-output-record stream) new-record))
        ;; Should we switch on recording? -- APD
        (funcall continuation stream new-record)
        (stream-close-text-output-record stream))
      (if parent
          (add-output-record new-record parent)
          (stream-add-output-record stream new-record))
      new-record)))

(defmethod invoke-with-output-to-output-record :around
    ((stream standard-page-layout) continuation record-type &rest initargs)
  (declare (ignore continuation record-type initargs))
  (with-temporary-margins (stream :left   '(:absolute 0)
                                  :top    '(:absolute 0)
                                  :right  '(:relative 0)
                                  :bottom '(:relative 0))
    (call-next-method)))

(defmethod invoke-with-output-to-output-record
    ((stream output-recording-stream) continuation record-type
     &rest initargs)
  (stream-close-text-output-record stream)
  (let ((new-record (apply #'make-instance record-type initargs)))
    (with-output-recording-options (stream :record t :draw nil)
      (letf (((stream-current-output-record stream) new-record)
             ((stream-cursor-position stream) (values 0 0)))
        (funcall continuation stream new-record)
        (stream-close-text-output-record stream)))
    new-record))

(defmethod invoke-with-output-to-pixmap ((sheet output-recording-stream) cont &key width height)
  (unless (and width height)
    ;; What to do when only width or height are given?  And what's the meaning
    ;; of medium-var? -- rudi 2005-09-05
    ;;
    ;; We default WIDTH or HEIGHT to provided values. The output is clipped to a
    ;; rectactangle [0 0 (or width max-x) (height max-y)]. We record the output
    ;; only to learn about dimensions - it is not replayed because the medium
    ;; can't be expected to work with this protocol. To produce the output we
    ;; invoke the continuation again. -- jd 2022-03-16
    (if (output-recording-stream-p sheet)
        (with-bounding-rectangle* (:x2 max-x :y2 max-y)
            (invoke-with-output-to-output-record sheet
                                                 (lambda (sheet record)
                                                   (declare (ignore record))
                                                   (funcall cont sheet))
                                                 'standard-sequence-output-record)
          (setf width (or width max-x)
                height (or height max-y)))
        (error "WITH-OUTPUT-TO-PIXMAP: please provide :WIDTH and :HEIGHT.")))
  (let* ((port (port sheet))
         (pixmap (allocate-pixmap sheet width height))
         (pixmap-medium (make-medium port sheet))
         (drawing-plane (make-rectangle* 0 0 width height)))
    (degraft-medium pixmap-medium port sheet)
    (letf (((medium-drawable pixmap-medium) pixmap)
           ((medium-clipping-region pixmap-medium) drawing-plane))
      (medium-clear-area pixmap-medium 0 0 width height)
      (funcall cont pixmap-medium)
      pixmap)))

(defmethod make-design-from-output-record (record)
  ;; FIXME
  (declare (ignore record))
  (error "Not implemented."))


(defclass clipping-output-record (standard-tree-output-record)
  ((clipping-region :initarg :clipping-region :type region
                    :accessor graphics-state-clip)))

(defmethod replay-output-record
    ((record clipping-output-record) stream &optional region x-offset y-offset)
  (declare (ignore region x-offset y-offset))
  (with-clipping-region (stream (graphics-state-clip record))
    (call-next-method)))

(defmethod* (setf output-record-position) :around
  (nx ny (record clipping-output-record))
  (with-bounding-rectangle* (x1 y1) (graphics-state-clip record)
    (let* ((dx (- nx x1))
           (dy (- ny y1))
           (tr (make-translation-transformation dx dy)))
      (multiple-value-prog1 (call-next-method)
        (setf (graphics-state-clip record)
              (transform-region tr (graphics-state-clip record)))))))

(defmethod output-record-refined-position-test
    ((record clipping-output-record) x y)
  (region-contains-position-p (graphics-state-clip record) x y))

(defmethod invoke-with-clipping-region
    ((sheet output-recording-stream) continuation (region area))
  (declare (ignore continuation))
  (if (stream-recording-p sheet)
      (with-sheet-medium (medium sheet)
        (let* ((tr (medium-transformation medium))
               (clip (transform-region tr region)))
          (with-new-output-record (sheet 'clipping-output-record record
                                         :clipping-region clip)
            (call-next-method)
            (setf (rectangle-edges* record)
                  (bounding-rectangle* clip)))))
      (call-next-method)))


;;; Additional methods
(defmethod handle-repaint :around ((stream output-recording-stream) region)
  (declare (ignore region))
  (with-output-recording-options (stream :record nil)
    (call-next-method)))

;;; FIXME: Change things so the rectangle below is only drawn in response
;;;        to explicit repaint requests from the user, not exposes from X.
;;; FIXME: Use DRAW-DESIGN*, that is fix DRAW-DESIGN*.
(defmethod handle-repaint ((stream output-recording-stream) region)
  (unless (region-equal region +nowhere+) ; ignore repaint requests for +nowhere+
    (let ((region (if (region-equal region +everywhere+)
                      ;; fallback to the sheet's region for +everwhere+.
                      (sheet-region stream)
                      (bounding-rectangle region))))
      (stream-replay stream region))))

(defmethod scroll-extent :around ((stream output-recording-stream) x y)
  (declare (ignore x y))
  (when (stream-drawing-p stream)
    (call-next-method)))

;;; FIXME: think about merging behavior by using WITH-LOCAL-COORDINATES and
;;; WITH-FIRST-QUADRANT-COORDINATES which both work on both mediums and
;;; streams. Also write a documentation chapter describing behavior and
;;; providing some examples.

;;; ----------------------------------------------------------------------------
;;; Complicated, underspecified...
;;;
;;; From examining old Genera documentation, I believe that
;;; with-room-for-graphics is supposed to set the medium transformation to
;;; give the desired coordinate system; i.e., it doesn't preserve any
;;; rotation, scaling or translation in the current medium transformation.
(defmethod invoke-with-room-for-graphics (cont (stream output-recording-stream)
                                          &key (first-quadrant t)
                                               width
                                               height
                                               (move-cursor t)
                                               (record-type
                                                'standard-sequence-output-record))
  (with-sheet-medium (medium stream)
    (multiple-value-bind (cx cy) (stream-cursor-position stream)
      (multiple-value-bind (cy* transformation)
          (if (not first-quadrant)
              (values cy +identity-transformation+)
              (values (+ cy (stream-baseline stream))
                      (make-scaling-transformation 1 -1)))
        (letf (((medium-transformation medium)
                (compose-transformation-with-translation transformation cx cy*)))
          (let ((record (with-new-output-record (stream record-type)
                          (funcall cont stream))))
            (with-bounding-rectangle* (:x2 x2 :y2 y2) record
              (orf width (- x2 cx))
              (orf height (- y2 cy))))))
      (maxf (stream-cursor-height stream) height)
      (setf (stream-cursor-position stream)
            (if move-cursor
                (values (+ cx width) cy)
                (values cx cy))))))

;;; Baseline

(defmethod output-record-baseline ((record output-record))
  "Fall back method"
  (with-bounding-rectangle* (:height height) record
    (values height nil)))

(defmethod output-record-baseline ((record standard-text-displayed-output-record))
  (with-slots (baseline) record
    (values baseline t)))

(defmethod output-record-baseline ((record compound-output-record))
  (map-over-output-records (lambda (sub-record)
                             (multiple-value-bind (baseline definitive)
                                 (output-record-baseline sub-record)
                               (when definitive
                                 (return-from output-record-baseline
                                   (values baseline t)))))
                           record)
  (call-next-method))

;;; copy-textual-output

(defun copy-textual-output-history (window stream &optional region record)
  (unless region (setf region +everywhere+))
  (unless record (setf record (stream-output-history window)))
  (let* ((text-style (medium-default-text-style window))
         (char-width (stream-character-width window #\n :text-style text-style))
         (line-height (+ (stream-line-height window :text-style text-style)
                         (stream-vertical-spacing window))))
    ;; humble first ...
    (let ((cy nil)
          (cx 0))
      (labels ((grok-record (record)
                 (cond ((typep record 'standard-text-displayed-output-record)
                        (with-slots (start-y start-x end-x strings) record
                          (setf cy (or cy start-y))
                          (when (> start-y cy)
                            (dotimes (k (round (- start-y cy) line-height))
                              (terpri stream))
                            (setf cy start-y
                                  cx 0))
                          (dotimes (k (round (- start-x cx) char-width))
                            (princ " " stream))
                          (setf cx end-x)
                          (dolist (string strings)
                            (with-slots (string) string
                              (princ string stream)))))
                       (t
                        (map-over-output-records-overlapping-region #'grok-record
                                                                    record region)))))
        (grok-record record)))))
