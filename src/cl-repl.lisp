(in-package #:cl-user)
(defpackage #:cl-repl
  (:use #:cl))
(in-package #:cl-repl)

(defconstant +version+ :0.2.0)

(defun bold (string)
  (format nil "~C[~Am~A~C[0m" (code-char #o33) "1" string (code-char #o33)))

(defvar *splash*
  (bold
   (cl-ansi-text:red
    "  ___  __          ____  ____  ____  __
 / __)(  )    ___ (  _ \\(  __)(  _ \\(  )
( (__ / (_/\\ (___) )   / ) _)  ) __// (_/\\
 \\___)\\____/      (__\\_)(____)(__)  \\____/
")))


(defvar *last-input* nil)
(defvar *history* nil)

(define-condition exit-error (error) nil)

(defun exit-with-prompt ()
  (finish-output)
  (alexandria:switch
   ((rl:readline :prompt "Do you really want to exit ([y]/n)? ") :test #'equal)
   ("y" (error 'exit-error))
   (nil (progn (format t "~%") (error 'exit-error)))
   ("n" (setf *last-input* "nil"))
   (t (exit-with-prompt))))

(defun prompt ()
  (format nil "~a> " (car (package-nicknames *package*))))

(defun newline (prompt)
  (format nil "~a "
          (apply
           #'concatenate 'string
           (loop
              repeat (1- (length prompt))
              collect "."))))

(defun read-input (&key (prompt (prompt)))
  (let ((input (rl:readline :prompt (bold (cl-ansi-text:green prompt)) :add-history t)))
    (if (not input)
        (progn
          (format t "~%")
          (exit-with-prompt))
        (setf *last-input* input)))
  (loop
     (let ((left (count "(" *last-input* :test #'string-equal))
           (right (count ")" *last-input* :test #'string-equal)))
       (if (>= right left) (return)))
     (let ((input (rl:readline :prompt (newline prompt) :add-history t)))
       (if (not input)
           (progn
             (format t "~%")
             (return))
           (setf *last-input* (concatenate 'string *last-input* " " input)))))
  (read-from-string *last-input*))

(defun write-output (output)
  (push *last-input* *history*)
  (if (> (length (princ-to-string output)) 0)
      (format t "~a ~a~%" (bold (cl-ansi-text:red "[OUT]:"))  output))
  (finish-output))

(defun print-condition (condition)
  (princ (bold (format  nil (cl-ansi-text:red "Error: ~a~%") condition))) "")

(defun debugger (condition)
  (print-condition condition)
  (format t
          (cl-ansi-text:blue (bold "~a~%~a~%~%"))
          "[0]: Try evaluating again."
          "[1]: Return to top level.")
  (finish-output)
  (let ((last-input *last-input*))
    (loop
       (handler-case
           (let ((input (read-input :prompt "DEBUG> ")))
             (alexandria:switch (input)
                                (0 (progn
                                     (write-output
                                      (eval (read-from-string last-input))) (return)))
                                (1 (return))
                                (t (write-output (eval input)))))
         (exit-error () (progn (finish-output) (return "")))
         (error (condition)
           (print-condition condition)))
       (finish-output))))

(defun common-prefix (items)
  (subseq
   (car items)
   0
   (apply
    #'min
    (mapcar
     #'(lambda (i) (or (mismatch (car items) i) (length i)))
     (cdr items)))))

(defun package-prefix (str)
  (cond
    ((let ((pos (search "::" str)))
       (when pos
         (list (subseq str (+ pos 2)) (subseq str 0 pos) nil))))
    ((let ((pos (position #\: str)))
       (when pos
         (list
          (subseq str (+ pos 1))
          (if (zerop pos)
              "KEYWORD"
              (subseq str 0 pos))
          t))))
    (t (list str nil nil))))

(defun completer (text start end)
  (declare (ignore start end))
  (if (string-equal text "")
      (return-from completer '(" ")))
  (let ((text (string-upcase text))
        (els))
    (flet ((body (sym text prefix)
             (let ((name (string sym)))
               (when (eql 0 (search text name))
                 (push (format nil "~(~a~a~)" prefix name)
                       els)))))
      (destructuring-bind (symbol-name package external-p)
          (package-prefix text)
        (when (and package (not (find-package package)))
          (return-from completer nil))
        (cond ((and package external-p)
               (do-external-symbols (sym package)
                 (body sym symbol-name
                       (if (equal (package-name :keyword)
                                  (package-name package))
                           ":"
                           (format nil "~a:" package)))))
              (package
               (do-symbols (sym package)
                 (body sym symbol-name (format nil "~a::" package))))
              (t
               (do-symbols (sym *package*)
                 (body sym symbol-name ""))
               (dolist (package (list-all-packages))
                 (body (format nil "~a:" (package-name package))
                       symbol-name "")
                 (dolist (package-name (package-nicknames package))
                   (body (format nil "~a:" package-name)
                         symbol-name "")))))))
    (if (cdr els)
        (cons (common-prefix els) els)
        els)))

#+sbcl (rl:register-function :complete #'completer)
#-sbcl (progn
         (cffi:define-foreign-library readline
             (:darwin (:or "libreadline.dylib"))
           (:unix (:or "libreadline.so.6.3"
                       "libreadline.so.6"
                       "libreadline.so"))
           (t (:default "libreadline")))
         (cffi:use-foreign-library readline)
         (setf rl::*attempted-completion-function*
               (rl::produce-callback
                (lambda (text start end)
                  (prog1
                      (rl::to-array-of-strings
                       (funcall #'completer text start end))
                    (setf rl::*attempted-completion-over* t)))
                :pointer
                (:string :int :int))))

(defun introspectionp (input)
  (alexandria:starts-with-subseq "?" input))

(defun shell-commandp (input)
  (alexandria:starts-with-subseq "!" input))

(defun magic-commandp (input)
  (alexandria:starts-with-subseq "%" input))

(defun load-magic (args)
  (mapcar (lambda (x) (ql:quickload x :silent t)) args))

(defun print-second (time)
  (format t "~a sec~%" (float (/ time internal-time-units-per-second))))

(defun time-magic (args)
  (let ((results nil))
    (handler-case
        (trivial-timeout:with-timeout (10)
          (loop repeat 100 do
               (let ((code (read-from-string (format nil "~{~a~^ ~}" args)))
                     (start (get-internal-real-time)))
                 (eval code)
                 (setf results
                       (cons
                        (/ (- (get-internal-real-time) start)
                           internal-time-units-per-second
                           0.001)
                        results)))))
      (trivial-timeout:timeout-error ()))
    (let ((ntimes (length results)))
      (if (zerop ntimes)
          (error 'trivial-timeout:timeout-error)
          (format t "~a loops, average: ~f ms, best: ~f ms~%"
                  ntimes
                  (alexandria:mean results)
                  (apply #'min results))))))

(defun save-magic (args)
  (let ((fname (first args)))
    (if (not fname)
      (error "Empty file name."))
    (with-open-file (out fname :direction :output)
      (dolist (line (reverse *history*))
        (if (not (or (shell-commandp line)
                     (magic-commandp line)))
            (format out "~a~%" line))))))

(defun introspection ()
  (let ((object (subseq *last-input* 1)))
    (if (not object)
      (return-from introspection ""))
    (let ((spec (car (trivial-documentation:symbol-definitions (read-from-string object)))))
      (let ((aspec (alexandria:plist-alist spec)))
        (if (not (cdr (assoc :kind aspec)))
          (return-from introspection ""))
        (format t "~a~a~%" (bold (cl-ansi-text:red "Type: "))
                           (string-downcase (princ-to-string (cdr (assoc :kind aspec)))))
        (if (assoc :lambda-list aspec)
          (format t "~a~a~%" (bold (cl-ansi-text:red "Args: "))
                             (string-downcase (princ-to-string (cdr (assoc :lambda-list aspec))))))
        (if (assoc :value aspec)
          (format t "~a~a~%" (bold (cl-ansi-text:red "Value: ")) (cdr (assoc :value aspec))))
        (if (cdr (assoc :documentation aspec))
          (let ((doc (cdr (assoc :documentation aspec))))
            (format t "~a~w~%" (bold (cl-ansi-text:red "Docstring: ")) doc))))))
  "")

(defun magic ()
  (let ((inputs (split-sequence:split-sequence #\space (subseq *last-input* 1))))
    (let ((cmd (car inputs)) (args (cdr inputs)))
      (alexandria:switch
       (cmd :test #'equal)
       ("load" (load-magic args))
       ("time" (time-magic args))
       ("save" (save-magic args)))))
  "")

(defun shell ()
  (princ
   (trivial-shell:shell-command (subseq *last-input* 1)))
  "")

(let (* ** *** - + ++ +++ / // /// values)
  (defun eval-input (-)
    (cond
      ((introspectionp *last-input*) (introspection))
      ((magic-commandp *last-input*) (magic))
      ((shell-commandp *last-input*) (shell))
      (t (progn
           (setq
            values
            (multiple-value-list
             (eval -)))
           (setq +++ ++ /// // *** (car ///)
                 ++ + // / ** (car //)
                 + - / values * (car /)) )))))

(defun repl ()
  (in-package :cl-user)
  (loop
     (handler-case
         (write-output (eval-input (read-input)))
       (exit-error () (return))
       (condition (c)
         (debugger c)))))