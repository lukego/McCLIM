;;; -*- Mode: Lisp; Package: CLIM-DEMO -*-

;;;  (c) copyright 2001 by
;;;           Arnaud Rouanet (rouanet@emi.u-bordeaux.fr)
;;;           Lionel Salabartan (salabart@emi.u-bordeaux.fr)

;;; This library is free software; you can redistribute it and/or
;;; modify it under the terms of the GNU Library General Public
;;; License as published by the Free Software Foundation; either
;;; version 2 of the License, or (at your option) any later version.
;;;
;;; This library is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; Library General Public License for more details.
;;;
;;; You should have received a copy of the GNU Library General Public
;;; License along with this library; if not, write to the
;;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;;; Boston, MA  02111-1307  USA.

(in-package :CLIM)

(export '(canvas-pane))

(defclass canvas-pane (application-pane)
  ((first-point-x :initform nil)
   (first-point-y :initform nil)
   (canvas-pixmap :initform nil)))

(defmethod handle-event ((pane canvas-pane) (event pointer-button-press-event))
  (when (= (pointer-event-button event) +pointer-left-button+)
    (with-slots (first-point-x first-point-y canvas-pixmap) pane
      (let ((pixmap-width (round (bounding-rectangle-width (sheet-region pane))))
	    (pixmap-height (round (bounding-rectangle-height (sheet-region pane)))))
	(setq first-point-x (pointer-event-x event))
	(setq first-point-y (pointer-event-y event))
	(with-slots (clim-demo::line-width clim-demo::current-color) *application-frame*
	  (case (clim-demo::clim-fig-drawing-mode *application-frame*)
	    (:point
	     (draw-point* pane first-point-x first-point-y
			  :ink clim-demo::current-color
                          :line-thickness clim-demo::line-width))))
	(setf canvas-pixmap (allocate-pixmap pane pixmap-width pixmap-height))
	(copy-to-pixmap pane 0 0 pixmap-width pixmap-height canvas-pixmap)))))

(defmethod handle-event ((pane canvas-pane) (event pointer-motion-event))
  (with-slots (first-point-x first-point-y canvas-pixmap) pane
      (when (and first-point-x first-point-y)
	(let* ((x (pointer-event-x event))
	       (y (pointer-event-y event))
	       (radius (distance first-point-x first-point-y x y))
	       (pixmap-width (round (bounding-rectangle-width (sheet-region pane))))
	       (pixmap-height (round (bounding-rectangle-height (sheet-region pane)))))
	  (with-slots (clim-demo::current-color) *application-frame*
	    (with-output-recording-options (pane :record nil)
	      (copy-from-pixmap canvas-pixmap 0 0 pixmap-width pixmap-height pane 0 0)
	      (case (clim-demo::clim-fig-drawing-mode *application-frame*)
		(:point nil)
		(:line
		 (draw-line* pane first-point-x first-point-y x y
			     :ink clim-demo::current-color :line-thickness 1))
		((:rectangle :filled-rectangle)
		 (draw-rectangle* pane first-point-x first-point-y x y :filled nil
				  :ink clim-demo::current-color :line-thickness 1))
		((:circle :filled-circle)
		 (draw-circle* pane first-point-x first-point-y radius :filled nil
			       :ink clim-demo::current-color :line-thickness 1)))))))))

(defun distance (x1 y1 x2 y2)
  (let ((diff-x (- x2 x1))
	(diff-y (- y2 y1)))
    (sqrt (+ (* diff-x diff-x)
	     (* diff-y diff-y)))))

(defmethod handle-event ((pane canvas-pane) (event pointer-button-release-event))
  (when (= (pointer-event-button event) +pointer-left-button+)
    (with-slots (first-point-x first-point-y canvas-pixmap) pane
      (let ((pixmap-width (round (bounding-rectangle-width (sheet-region pane))))
	    (pixmap-height (round (bounding-rectangle-height (sheet-region pane)))))
	(when (and first-point-x first-point-y)
          (copy-from-pixmap canvas-pixmap 0 0 pixmap-width pixmap-height pane 0 0)
          (deallocate-pixmap canvas-pixmap)
          (setf canvas-pixmap nil)
	  (with-slots (clim-demo::line-width clim-demo::current-color) *application-frame*
	    (let* ((x (pointer-event-x event))
		   (y (pointer-event-y event))
		   (radius (distance first-point-x first-point-y x y)))
	      (case (clim-demo::clim-fig-drawing-mode *application-frame*)
		(:line
		 (draw-line* pane first-point-x first-point-y x y
			     :ink clim-demo::current-color
                             :line-thickness clim-demo::line-width))
		(:rectangle
		 (draw-rectangle* pane first-point-x first-point-y x y :filled nil
				  :ink clim-demo::current-color
                                  :line-thickness clim-demo::line-width))
		(:filled-rectangle
		 (draw-rectangle* pane first-point-x first-point-y x y
				  :ink clim-demo::current-color
                                  :line-thickness clim-demo::line-width))
		(:circle
		 (draw-circle* pane first-point-x first-point-y radius :filled nil
			       :ink clim-demo::current-color
                               :line-thickness clim-demo::line-width))
		(:filled-circle
		 (draw-circle* pane first-point-x first-point-y radius
			       :ink clim-demo::current-color
                               :line-thickness clim-demo::line-width))))
	    (setf (clim-demo::clim-fig-redo-list *application-frame*) nil))
	  (setf first-point-x nil
		first-point-y nil))))))

(in-package :CLIM-DEMO)

(defun clim-fig ()
  (loop for port in climi::*all-ports*
      do (destroy-port port))
  (setq climi::*all-ports* nil)
  (run-frame-top-level (make-application-frame 'clim-fig)))

(defun make-colored-button (color &key width height)
  (make-pane 'push-button-pane
	     :label " "
	     :activate-callback
             #'(lambda (gadget)
                 (setf (clim-fig-current-color (gadget-client gadget))
                       color))
	     :width width :height height
	     :normal color :pushed-and-highlighted color
	     :highlighted color))

(defun make-drawing-mode-button (label mode &key width height)
  (make-pane 'push-button-pane
	     :label label
	     :activate-callback
             #'(lambda (gadget)
                 (setf (clim-fig-drawing-mode (gadget-client gadget))
                       mode))
	     :width width :height height))

(define-command com-exit ()
  (throw 'exit nil))

(define-command com-undo ()
  (let* ((output-history (stream-current-output-record *standard-output*))
         (record (first (last (output-record-children output-history)))))
    (unless (null record)
      (with-output-recording-options (*standard-output* :record nil)
        (with-bounding-rectangle* (x1 y1 x2 y2) record
                                  (draw-rectangle* *standard-output* x1 y1 x2 y2 :ink +background-ink+)
                                  (delete-output-record record output-history)
                                  (push record (clim-fig-redo-list *application-frame*))
                                  (replay-output-record output-history *standard-output*
                                                        (make-rectangle* x1 y1 x2 y2)))))))

(define-command com-redo ()
  (let* ((output-history (stream-current-output-record *standard-output*))
         (record (pop (clim-fig-redo-list *application-frame*))))
    (when record
      (with-output-recording-options (*standard-output* :record nil)
        (with-bounding-rectangle* (x1 y1 x2 y2) record
          (draw-rectangle* *standard-output* x1 y1 x2 y2 :ink +background-ink+)
          (add-output-record record output-history)
          (replay-output-record output-history *standard-output*
                                (make-rectangle* x1 y1 x2 y2)))))))

(define-command com-clear ()
  (let ((output-history (stream-current-output-record *standard-output*)))
    (with-output-recording-options (*standard-output* :record nil)
      (with-bounding-rectangle* (x1 y1 x2 y2) (sheet-region *standard-output*)
                                (draw-rectangle* *standard-output* x1 y1 x2 y2 :ink +background-ink+)))
    (setf (clim-demo::clim-fig-redo-list *application-frame*)
          (append (output-record-children output-history)
                  (clim-demo::clim-fig-redo-list *application-frame*)))
    (clear-output-record output-history)))

(make-command-table 'file-command-table
		    :errorp nil
		    :menu '(("Exit" :command com-exit)))

(make-command-table 'edit-command-table
		    :errorp nil
		    :menu '(("Undo" :command com-undo)
			    ("Redo" :command com-redo)
                            ("Clear" :command com-clear)))

(make-command-table 'menubar-command-table
		    :errorp nil
		    :menu '(("File" :menu file-command-table)
                            ("Edit" :menu edit-command-table)))

(define-application-frame clim-fig ()
  ((drawing-mode :initform :point :accessor clim-fig-drawing-mode)
   (redo-list :initform nil :accessor clim-fig-redo-list)
   (current-color :initform +black+ :accessor clim-fig-current-color)
   (line-width :initform 1 :accessor clim-fig-line-width))
  (:panes
   (canvas :canvas)
   (menu-bar (climi::make-menu-bar 'menubar-command-table :height 25))
   (line-width-slider :slider
		      :label "Line Width"
		      :value 1
		      :min-value 1
		      :max-value 100
		      :value-changed-callback
                      #'(lambda (gadget value)
                          (declare (ignore gadget))
                          (setf (clim-fig-line-width *application-frame*)
                                (round value)))
		      :show-value-p nil
		      :height 50
		      :orientation :horizontal)

   ;; Drawing modes
   (point-button (make-drawing-mode-button "Point" :point))
   (line-button (make-drawing-mode-button "Line" :line))
   (circle-button (make-drawing-mode-button "Circle" :circle))
   (filled-circle-button (make-drawing-mode-button "Filled Circle" :filled-circle))
   (rectangle-button (make-drawing-mode-button "Rectangle" :rectangle))
   (filled-rectangle-button (make-drawing-mode-button "Filled Rectangle" :filled-rectangle))

   ;; Colors
   (black-button (make-colored-button +black+))
   (blue-button (make-colored-button +blue+))
   (green-button (make-colored-button +green+))
   (cyan-button (make-colored-button +cyan+))
   (red-button (make-colored-button +red+))
   (magenta-button (make-colored-button +magenta+))
   (yellow-button (make-colored-button +yellow+))
   (white-button (make-colored-button +white+))
   (turquoise-button (make-colored-button +turquoise+))
   (grey-button (make-colored-button +grey+))
   (brown-button (make-colored-button +brown+))
   (orange-button (make-colored-button +orange+))

   (undo :push-button
         :label "Undo"
         :activate-callback #'(lambda (x)
                                (declare (ignore x))
                                (com-undo)))
   (redo :push-button
         :label "Redo"
         :activate-callback #'(lambda (x)
                                (declare (ignore x))
                                (com-redo)))
   (clear :push-button
          :label "Clear"
          :activate-callback #'(lambda (x)
                                 (declare (ignore x))
                                 (com-clear))))
   (:layouts
    (default
      (vertically ()
        menu-bar
        (horizontally ()
          (vertically (:width 150)
            (tabling (:height 60)
              (list black-button blue-button green-button cyan-button)
              (list red-button magenta-button yellow-button white-button)
              (list turquoise-button grey-button brown-button orange-button))
            line-width-slider
            point-button line-button
            circle-button filled-circle-button
            rectangle-button filled-rectangle-button)
          (scrolling (:width 600 :height 400) canvas))
        (horizontally (:height 30) clear undo redo))))
   (:top-level (clim-fig-frame-top-level)))

(defmethod clim-fig-frame-top-level ((frame application-frame) &key)
  (let ((*standard-input* (frame-standard-input frame))
	(*standard-output* (frame-standard-output frame))
	(*query-io* (frame-query-io frame)))
    (catch 'exit
      (loop (read-command (frame-pane frame))))
    (destroy-port (climi::port frame))))
