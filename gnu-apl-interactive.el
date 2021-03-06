;;; -*- lexical-binding: t -*-

(defvar gnu-apl-current-session nil
  "The buffer that holds the currently active GNU APL session,
or NIL if there is no active session.")

(defun gnu-apl-interactive-send-string (string)
  (let ((p (get-buffer-process (gnu-apl--get-interactive-session)))
        (string-with-ret (if (and (plusp (length string))
                                  (= (aref string (1- (length string))) ?\n))
                             string
                           (concat string "\n"))))
    (comint-send-string p string-with-ret)))

(defun gnu-apl--get-interactive-session ()
  (unless gnu-apl-current-session
    (user-error "No active GNU APL session"))
  (let ((proc-status (comint-check-proc gnu-apl-current-session)))
    (unless (eq (car proc-status) 'run)
      (user-error "GNU APL session has exited"))
    gnu-apl-current-session))

(defvar *gnu-apl-native-lib* "EMACS_NATIVE")
(defvar *gnu-apl-ignore-start* "IGNORE-START")
(defvar *gnu-apl-ignore-end* "IGNORE-END")
(defvar *gnu-apl-network-start* "NATIVE-STARTUP-START")
(defvar *gnu-apl-network-end* "NATIVE-STARTUP-END")

(defun gnu-apl--send (proc string)
  "Filter for any commands that are sent to comint"
  (let* ((trimmed (gnu-apl--trim-spaces string)))
    (cond ((and gnu-apl-auto-function-editor-popup
                (plusp (length trimmed))
                (string= (subseq trimmed 0 1) "∇"))
           ;; The command is a functiond definition command
           (unless (gnu-apl--parse-function-header (subseq trimmed 1))
             (user-error "Error when parsing function definition command"))
           (unwind-protect
               (gnu-apl--get-function (gnu-apl--trim-spaces (subseq string 1)))
             (let ((buffer (process-buffer proc)))
               (with-current-buffer buffer
                 (let ((inhibit-read-only t))
                   (save-excursion
                     (save-restriction
                       (widen)
                       (goto-char (process-mark proc))
                       (insert "      ")
                       (set-marker (process-mark proc) (point))))))))
           nil)

          (t
           ;; Default, simply pass the input to the process
           (comint-simple-send proc string)))))

(defun gnu-apl--set-face-for-parsed-text (start end mode string)
  (case mode
    (cerr (add-text-properties start end '(font-lock-face gnu-apl-error) string))
    (uerr (add-text-properties start end '(font-lock-face gnu-apl-user-status-text) string))))

(defun gnu-apl--parse-text (string)  
  (let ((tags nil))
    (let ((result (with-output-to-string
                    (loop with current-mode = gnu-apl-input-display-type
                          with pos = 0
                          for i from 0 below (length string)
                          for char = (aref string i)
                          for newmode = (case char
                                          (#xf00c0 'cin)
                                          (#xf00c1 'cout)
                                          (#xf00c2 'cerr)
                                          (#xf00c3 'uerr)
                                          (t nil))
                          if (and newmode (not (eq current-mode newmode)))
                          do (progn
                               (push (list pos newmode) tags)
                               (setq current-mode newmode))
                          unless newmode
                          do (progn
                               (princ (char-to-string char))
                               (incf pos))))))
      (let ((prevmode gnu-apl-input-display-type)
            (prevpos 0))
        (loop for v in (reverse tags)
              for newpos = (car v)
              unless (= prevpos newpos)
              do (gnu-apl--set-face-for-parsed-text prevpos newpos prevmode result)
              do (progn
                   (setq prevpos newpos)
                   (setq prevmode (cadr v))))
        (unless (= prevpos (length result))
          (gnu-apl--set-face-for-parsed-text prevpos (length result) prevmode result))
        (setq gnu-apl-input-display-type prevmode)
        result))))

(defun gnu-apl--erase-and-set-function (name content)
  (gnu-apl-interactive-send-string (concat "'" *gnu-apl-ignore-start* "'"))
  (gnu-apl-interactive-send-string (concat ")ERASE " name))
  (gnu-apl-interactive-send-string (concat "'" *gnu-apl-ignore-end* "'"))
  (setq gnu-apl-function-content-lines (split-string content "\n"))
  (gnu-apl-interactive-send-string (concat "'" *gnu-apl-send-content-start* "'")))

(defun gnu-apl--output-disconnected-message (output-fn)
  (funcall output-fn "The GNU APL environment has been started, but the Emacs mode was
unable to connect to the backend. Because of this, some
functionality will not be available, such as the external
function editor.
      "))

(defun gnu-apl--preoutput-filter (line)
  (let ((result "")
        (first t))

    (labels ((add-to-result (s)
                              (if first
                                  (setq first nil)
                                (setq result (concat result "\n")))
                              (setq result (concat result s))))

      (dolist (plain (split-string line "\n"))
        (let ((command (gnu-apl--parse-text plain)))
          (ecase gnu-apl-preoutput-filter-state
            ;; Default parse state
            (normal
             (cond ((string-match (regexp-quote *gnu-apl-ignore-start*) command)
                    (setq gnu-apl-preoutput-filter-state 'ignore))
                   ((string-match (regexp-quote *gnu-apl-network-start*) command)
                    (setq gnu-apl-preoutput-filter-state 'native))
                   (t
                    (add-to-result command))))

            ;; Ignoring output
            (ignore
             (cond ((string-match (regexp-quote *gnu-apl-ignore-end*) command)
                    (setq gnu-apl-preoutput-filter-state 'normal))
                   (t
                    nil)))

            ;; Initialising native code
            (native
             (cond ((string-match (regexp-quote *gnu-apl-network-end*) command)
                    (unless (and (boundp 'gnu-apl--connection)
                                 gnu-apl--connection
                                 (process-live-p gnu-apl--connection))
                      (gnu-apl--output-disconnected-message #'add-to-result))
                    (setq gnu-apl-preoutput-filter-state 'normal))
                   ((string-match (concat "Network listener started.*"
                                          "mode:\\([a-z]+\\) "
                                          "addr:\\([a-zA-Z0-9/]+\\)")
                                  command)
                    (let ((mode (match-string 1 command))
                          (addr (match-string 2 command)))
                      (gnu-apl--connect mode addr)
                      (message "Connected to APL interpreter")
                      (add-to-result command)))
                   (t
                    (add-to-result command))))))))
    result))

(defvar gnu-apl-interactive-mode-map
  (let ((map (gnu-apl--make-mode-map "s-")))
    (define-key map (kbd "C-c C-f") 'gnu-apl-edit-function)
    (define-key map (kbd "C-c C-v") 'gnu-apl-edit-variable)
    (define-key map (kbd "C-c C-m") 'gnu-apl-plot-line)
    (define-key map [menu-bar gnu-apl edit-function] '("Edit function" . gnu-apl-edit-function))
    (define-key map [menu-bar gnu-apl edit-matrix] '("Edit variable" . gnu-apl-edit-variable))
    (define-key map [menu-bar gnu-apl plot-line] '("Plot line graph of variable content" . gnu-apl-plot-line))
    map))

(define-derived-mode gnu-apl-interactive-mode comint-mode "GNU APL/Comint"
  "Major mode for interacting with GNU APL."
  :syntax-table gnu-apl-mode-syntax-table
  :group 'gnu-apl
  (use-local-map gnu-apl-interactive-mode-map)
  (gnu-apl--init-mode-common)

  (setq comint-prompt-regexp "^\\(      \\)\\|\\(\\[[0-9]+\\] \\)")
  (set (make-local-variable 'gnu-apl-preoutput-filter-state) 'normal)
  (set (make-local-variable 'gnu-apl-input-display-type) 'cout)
  (set (make-local-variable 'comint-input-sender) 'gnu-apl--send)
  (add-hook 'comint-preoutput-filter-functions 'gnu-apl--preoutput-filter nil t)

  (setq font-lock-defaults '(nil t)))

(defun gnu-apl-open-customise ()
  (interactive)
  (customize-group 'gnu-apl t))

(defun gnu-apl--insert-tips ()
  (insert "This is the gnu-apl-mode interactive buffer.\n\n"
          "To toggle keyboard help, call M-x gnu-apl-show-keyboard (C-c C-k by default).\n"
          "APL symbols are bound to the standard keys with the Super key. You can also\n"
          "activate the APL-Z ")
  (insert-button "input method"
                 'action 'toggle-input-method
                 'follow-link t)
  (insert " (M-x toggle-input-method or C-\\) which\n"
          "allows you to input APL symbols by prefixing the key with a \".\" (period).\n\n"
          "There are several ")
  (insert-button "customisation"
                 'action #'(lambda (event) (customize-group 'gnu-apl t))
                 'follow-link t)
  (insert " options that can be set.\n"
          "Click the link or run M-x customize-group RET gnu-apl to set up.\n\n"
          "To disable this message, set gnu-apl-show-tips-on-start to nil.\n\n"))

(defun gnu-apl (apl-executable)
  "Start the GNU APL interpreter in a buffer. APL-EXECUTABLE is
the path to the apl program (defaults to `gnu-apl-executable')."
  (interactive (list (when current-prefix-arg
                       (read-file-name "Location of GNU APL Executable: " nil nil t))))
  (let ((buffer (get-buffer-create "*gnu-apl*"))
        (resolved-binary (or apl-executable gnu-apl-executable)))
    (unless resolved-binary
      (user-error "GNU APL Executable was not set"))
    (pop-to-buffer-same-window buffer)
    (unless (comint-check-proc buffer)
      (when gnu-apl-show-tips-on-start
        (gnu-apl--insert-tips))
      (apply #'make-comint-in-buffer
             "apl" buffer resolved-binary nil
             "--rawCIN" "--emacs" (append (if (not gnu-apl-show-apl-welcome) (list "--silent"))))
      (setq gnu-apl-current-session buffer)

      (gnu-apl-interactive-mode)
      (set-buffer-process-coding-system 'utf-8 'utf-8)
      (when gnu-apl-native-communication
        (gnu-apl--send buffer (concat "'" *gnu-apl-network-start* "'"))
        (gnu-apl--send buffer (concat "'libemacs' ⎕FX "
                                      "'" *gnu-apl-native-lib* "'"))
        (gnu-apl--send buffer (format "%s[1] %d" *gnu-apl-native-lib* 7293))
        (gnu-apl--send buffer (concat "'" *gnu-apl-network-end* "'"))))
    (when gnu-apl-show-keymap-on-startup
      (run-at-time "0 sec" nil #'(lambda () (gnu-apl-show-keyboard 1))))))

(defun gnu-apl--parse-function-header (string)
  "Parse a function definition string. Returns the name of the
function or nil if the function could not be parsed."
  (let ((line (gnu-apl--trim-spaces string)))
    (cond ((string-match (concat "^\\(?:[a-z0-9∆_]+ *← *\\)?" ; result variable
                                 "\\([a-za-z0-9∆_ ]+\\)" ; function and arguments
                                 "\\(?:;.*\\)?$" ; local variables
                                 )
                         line)
           ;; Plain function definition
           (let ((parts (split-string (match-string 1 line))))
             (ecase (length parts)
               (1 (car parts))
               (2 (car parts))
               (3 (cadr parts)))))
          
          ((string-match (concat "^\\(?:[a-z0-9∆_]+ *← *\\)?" ; result variable
                                 "\\(?: *[a-z0-9∆_]+ *\\)?" ; optional left argument
                                 "(\\([a-za-z0-9∆_ ]+\\))" ; left argument and function name
                                 ".*$" ; don't care about what comes after
                                 )
                         line)
           ;; Axis operator definition
           (let ((parts (split-string (match-string 1 line))))
             (case (length parts)
               (2 (cadr parts))
               (3 (cadr parts))))))))
