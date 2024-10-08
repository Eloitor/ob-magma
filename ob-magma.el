;;; ob-magma.el --- org-babel functions for magma evaluation

;; Copyright (C) 2015-2017 Thibaut Verron (thibaut.verron@gmail.com)

;; Author: Thibaut Verron
;; Keywords: literate programming, reproducible research, magma
;; Homepage: https://github.com/ThibautVerron/ob-magma
;; Version: 0.02

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; This file provides support for Magma evaluation within org-babel. It includes two modes of execution:
;; 1. **magma**: Evaluation in a local Magma session, using comint.
;; 2. **magma-free**: Evaluation through an HTTP API, suitable for users who do not have a local Magma installation.

;; These functions provide support for magma evaluation with
;; org-babel. Evaluation is made in a unique magma session by default,
;; explicit naming of sessions is possible.

;; Results type can be either 'output or 'value, in which case magma
;; tries to determine whether the output is a table or not. If your
;; output is a sequence and you do not wish to format it as a table,
;; use 'output for this code block.

;; The parameter `:magma-eval t' causes the block to be enclosed in an
;; `eval' form. The output value is given by the `return'
;; statement. At the moment, the return statement is handled like
;; other forms of output (for example calls to `print'). Note that no
;; side-effect is possible in an `eval' form. This is useful if you
;; want to run a test without changing the environment, but don't want
;; to fire up a new session just for this test.

;;; Requirements:

;; Use this section to list the requirements of this language.  Most
;; languages will require that at least the language be installed on
;; the user's system, and the Emacs major mode relevant to the
;; language be installed as well.

;;; Code:
(require 'ob)
(require 'ob-ref)
(require 'ob-comint)
(require 'ob-eval)
(require 's)
(require 'dash)
(require 'url)
(require 'xml)

;; possibly require modes required for your language
(require 'magma-mode)


;; optionally define a file extension for this language
(add-to-list 'org-babel-tangle-lang-exts '("magma" . "m"))

;; optionally declare default header arguments for this language
(defvar org-babel-default-header-args:magma '())
(defvar org-babel-default-header-args:magma-free '())

(defconst org-babel-magma-eoe "end-of-echo")
(defconst org-babel-magma-prompt "[> ")

(defun org-babel-magma-wrap-in-eval (body)
  "Wraps BODY in an eval form (escapes what needs to be)"
  (concat
   "eval \""
   (s-replace "\"" "\\\"" body)
   "\";"))

(defconst org-babel-magma--scan-output
  "function ob_magma_scanOutput (str)
    try 
        res := eval str;
        if Type(res) eq SeqEnum then
            return \"table\";
        else
            return \"string\";
        end if;
    catch e 
        res := \"output\";
    end try;
    return res;
end function;"
  )

;; In a recent update, `org-babel-get-header' was removed from org-mode, which
;; is something a fair number of babel plugins use. So until those plugins
;; update, this polyfill will do:
(defun org-babel-get-header (params key &optional others)
  (cl-loop with fn = (if others #'not #'identity)
           for p in params
           if (funcall fn (eq (car p) key))
           collect p))

;; This function expands the body of a source code block by doing
;; things like prepending argument definitions to the body, it should
;; be called by the `org-babel-execute:magma' function below.
(defun org-babel-expand-body:magma (body params )
  "Expand BODY according to PARAMS, return the expanded body."
  (let ((vars (mapcar #'cdr (org-babel-get-header params :var)))
        (eval (cdr (assoc :magma-eval params))))
    (concat
     (mapconcat ;; define any variables
      (lambda (pair)
        (format "%s := eval %S;"
                (car pair) (org-babel-magma-var-to-magma (cdr pair))))
      vars "\n")
     "\n"
     (if eval
         (org-babel-magma-wrap-in-eval body)
       body)
     )))

;; This is the main function which is called to evaluate a code
;; block.
;;
;; This function will evaluate the body of the source code and
;; return the results as emacs-lisp depending on the value of the
;; :results header argument
;; - output means that the output to STDOUT will be captured and
;;   returned
;; - value means that the value of the last statement in the
;;   source code block will be returned
;;
;; The most common first step in this function is the expansion of the
;; PARAMS argument using `org-babel-process-params'.
;;
;; Please feel free to not implement options which aren't appropriate
;; for your language (e.g. not all languages support interactive
;; "session" evaluation).  Also you are free to define any new header
;; arguments which you feel may be useful -- all header arguments
;; specified by the user will be available in the PARAMS variable.
(defun org-babel-execute:magma (body params)
  "Execute a block of Magma code with org-babel.
This function is called by `org-babel-execute-src-block'"
  (message "executing Magma source code block")
  (let* ((processed-params (org-babel-process-params params))
         ;; set the session if the session variable is non-nil
         (session (org-babel-magma-initiate-session (cdr (assoc :session params))))
         ;; variables assigned for use in the block
         ;(vars (cdr (assoc :vars params)))
         (result-params (cdr (assoc :result-params params)))
         ;; either OUTPUT or VALUE which should behave as described above
         (result-type (cdr (assoc :result-type params)))
         ;; expand the body with `org-babel-expand-body:magma'
         (full-body (concat (org-babel-expand-body:magma
                             body params )
                            (format "\nprint \"%s\";" org-babel-magma-eoe)))
         (results
          (s-join
           "\n"
           (butlast
            ;; (-filter
            ;;  (lambda (s) (not (s-equals? "" s)))
             (org-babel-comint-with-output
                (session org-babel-magma-eoe t full-body)
              (funcall #'insert full-body)
              (funcall #'comint-send-input)
              ;;(funcall #'insert org-babel-magma-eoe)
              ))))
         ;;)
         (results-wo-eoe (s-join "\n" (butlast (split-string results "\n") 2)))
         )
    ;; actually execute the source-code block either in a session or
    ;; possibly by dropping it to a temporary file and evaluating the
    ;; file.
    ;; 
    ;; for session based evaluation the functions defined in
    ;; `org-babel-comint' will probably be helpful.
    ;;
    ;; for external evaluation the functions defined in
    ;; `org-babel-eval' will probably be helpful.
    ;;
    ;; when forming a shell command, or a fragment of code in some
    ;; other language, please preprocess any file names involved with
    ;; the function `org-babel-process-file-name'. (See the way that
    ;; function is used in the language files)
    (if (or (eq result-type 'value) (eq result-type 'eval))
        (let* ((scan-body
                (concat "ob_magma_scanOutput(\""
                       results-wo-eoe
                       "\");\n"
                       (format "print \"%s\";\n" org-babel-magma-eoe)
                       ))
               (scan-res (nth 0 (org-babel-comint-with-output
                                (session org-babel-magma-eoe nil nil)
                              (funcall #'insert scan-body)
                              (funcall #'comint-send-input))))
               (type (car (split-string scan-res "\n"))))
          (if (s-matches? "^.*table[ \n]?$" type)
              (org-babel-script-escape results-wo-eoe)
            results-wo-eoe))
      results-wo-eoe))
    ;; (org-babel-reassemble-table
    ;;  results
    ;;  (org-babel-pick-name (cdr (assoc :colname-names params))
    ;;     		  (cdr (assoc :colnames params)))
    ;;  (org-babel-pick-name (cdr (assoc :rowname-names params))
    ;;     		  (cdr (assoc :rownames params))))
    )

;; This function should be used to assign any variables in params in
;; the context of the session environment.
(defun org-babel-prep-session:magma (session params)
  "Prepare SESSION according to the header arguments specified in PARAMS."
  )

(defun org-babel-magma-var-to-magma (var)
  "Convert an elisp var into a string of magma source code
specifying a var of the same value."
  (if (listp var)
      (concat "[" (mapconcat #'org-babel-magma-var-to-magma var ", ") "]")
    (if (equal var 'hline) ""
      (format
       ;;(if (and (stringp var) (string-match "[\n\r]" var)) "\"\"%s\"\"" "%s")
       "%S"
       (if (stringp var) (substring-no-properties var) var)))))

(defun org-babel-magma-table-or-string (results)
  "If the results look like a table, then convert them into an
Emacs-lisp table, otherwise return the results as a string."
  (org-babel-script-escape results)
  )

(defun org-babel-magma-send-initial-code (buffer)
  (with-current-buffer buffer
    (insert (concat
             org-babel-magma--scan-output
             "\n"
             (format "SetPrompt(%S);" org-babel-magma-prompt)
             "SetAutoColumns(false);\n"
             "SetColumns(0);\n"
             "SetLineEditor(false);"))
    (comint-send-input)
    (setq-local comint-prompt-regexp "^[^\n]*\\[> ")))

(defun org-babel-magma-initiate-session (&optional session)
  "If there is not a current inferior-process-buffer in SESSION then create.
Return the initialized session."
  (let* ((magma-interactive-use-comint t)
         (ob-magma-session (if (string= session "none") "org" session))
         (bufname (magma-make-buffer-name ob-magma-session)))
    (unless (comint-check-proc bufname)
      (magma-run ob-magma-session)
      (org-babel-magma-send-initial-code bufname))
    (get-buffer bufname)))

;; We try to apply specific settings making it easier to work in the
;; snippet buffers.




;; magma-free functions
(defun magma-send-request (input)
  "Send INPUT to the Magma calculator API and return the response."
  (let ((url-request-method "GET")
        (url (format "http://magma.maths.usyd.edu.au/xml/calculator.xml?input=%s" (url-hexify-string input))))
    (with-current-buffer (url-retrieve-synchronously url)
      (goto-char (point-min))
      (re-search-forward "\n\n")
      (let ((response (buffer-substring (point) (point-max))))
        (kill-buffer (current-buffer))
        response))))

(defun magma-parse-response (response)
  "Parse the XML RESPONSE from Magma and return the result as a string."
  (let ((xml (with-temp-buffer
               (insert response)
               (xml-parse-region (point-min) (point-max)))))
    (mapconcat (lambda (line)
                 (car (xml-node-children line)))
               (xml-get-children (car (xml-get-children (car xml) 'results)) 'line)
               "\n")))

(defun org-babel-execute:magma-free (body params)
  "Execute a block of Magma code with org-babel via the Magma API."
  (message "executing Magma-free source code block via API")
  (let* ((processed-params (org-babel-process-params params))
         (expanded-body (org-babel-expand-body:magma body params))
         (response (magma-send-request expanded-body))
         (result (magma-parse-response response)))
    (if (or (eq (cdr (assoc :result-type params)) 'value))
        (org-babel-script-escape result)
      result)))

;; magma-free does not require session management, so no session functions are defined


(provide 'ob-magma)
;;; ob-magma.el ends here
