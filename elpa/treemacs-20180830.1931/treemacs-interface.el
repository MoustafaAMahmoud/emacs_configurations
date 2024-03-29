;;; treemacs.el --- A tree style file viewer package -*- lexical-binding: t -*-

;; Copyright (C) 2018 Alexander Miller

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;; Not autoloaded, but user-facing functions.

;;; Code:

(require 'hl-line)
(require 'bookmark)
(require 'button)
(require 'f)
(require 's)
(require 'dash)
(require 'treemacs-impl)
(require 'treemacs-filewatch-mode)
(require 'treemacs-branch-creation)
(require 'treemacs-follow-mode)
(require 'treemacs-tag-follow-mode)
(require 'treemacs-mouse-interface)
(require 'treemacs-customization)
(require 'treemacs-workspaces)
(eval-and-compile
  (require 'cl-lib)
  (require 'treemacs-macros))

(treemacs-import-functions-from "treemacs"
  treemacs-select-window)

(defconst treemacs-valid-button-states
  '(root-node-open
    root-node-closed
    dir-node-open
    dir-node-closed
    file-node-open
    file-node-closed
    tag-node-open
    tag-node-closed
    tag-node)
  "List of all valid values for treemacs buttons' :state property.")

(defun treemacs-next-line (&optional count)
  "Goto next line.
A COUNT argument, moves COUNT lines down."
  (interactive "p")
  (forward-line count)
  (treemacs--evade-image))

(defun treemacs-previous-line (&optional count)
  "Goto previous line.
A COUNT argument, moves COUNT lines up."
  (interactive "p")
  (forward-line (- count))
  (treemacs--evade-image))

(defun treemacs-toggle-node (&optional arg)
  "Expand or close the current node.
If a prefix ARG is provided the open/close process is done recursively. When
opening directories that means that all sub-directories are opened as well. When
opening files all their tag sections will be opened.
Recursively closing any kind of node means that treemacs will forget about
everything that was expanded below that node.

Since tags cannot be opened or closed a goto definition action will called on
them instead."
  (interactive)
  (treemacs-do-for-button-state
   :on-root-node-open   (treemacs--collapse-root-node btn arg)
   :on-root-node-closed (treemacs--expand-root-node btn)
   :on-dir-node-open    (treemacs--collapse-dir-node btn arg)
   :on-dir-node-closed  (treemacs--expand-dir-node btn :recursive arg)
   :on-file-node-open   (treemacs--collapse-file-node btn arg)
   :on-file-node-closed (treemacs--expand-file-node btn arg)
   :on-tag-node-open    (treemacs--collapse-tag-node btn arg)
   :on-tag-node-closed  (treemacs--expand-tag-node btn arg)
   :on-tag-node-leaf    (progn (other-window 1) (treemacs--goto-tag btn))
   :on-nil              (treemacs-pulse-on-failure "There is nothing to do here.")))

(defun treemacs-toggle-node-prefer-tag-visit (&optional arg)
  "Same as `treemacs-toggle-node' but will visit a tag node in some conditions.
Tag nodes, despite being expandable sections, will be visited in the following
conditions:

 * Tags belong to a .py file and the tag section's first child element's label
   ends in \" definition*\". This indicates the section is the parent element in
   a nested class/function definition and can be moved to.
 * Tags belong to a .org file and the tag section element possesses a
   'org-imenu-marker text property. This indicates that the section is a
   headline with further org elements below it.

The prefix argument ARG is treated the same way as with `treemacs-toggle-node'."
  (interactive)
  (treemacs-do-for-button-state
   :on-root-node-open   (treemacs--collapse-root-node btn arg)
   :on-root-node-closed (treemacs--expand-root-node btn)
   :on-dir-node-open    (treemacs--collapse-dir-node btn arg)
   :on-dir-node-closed  (treemacs--expand-dir-node btn :recursive arg)
   :on-file-node-open   (treemacs--collapse-file-node btn arg)
   :on-file-node-closed (treemacs--expand-file-node btn arg)
   :on-tag-node-open    (treemacs--visit-or-expand/collapse-tag-node btn arg t)
   :on-tag-node-closed  (treemacs--visit-or-expand/collapse-tag-node btn arg t)
   :on-tag-node-leaf    (progn (other-window 1) (treemacs--goto-tag btn))
   :on-nil              (treemacs-pulse-on-failure "There is nothing to do here.")))

(defun treemacs-TAB-action (&optional arg)
  "Run the appropriate TAB action for the current node.

In the default configuration this usually means to expand or close the content
of the currently selected node. A potential prefix ARG is passed on to the
executed action, if possible.

This function's exact configuration is stored in `treemacs-TAB-actions-config'."
  (interactive "P")
  (-when-let (state (treemacs--prop-at-point :state))
    (funcall (cdr (assq state treemacs-TAB-actions-config)) arg)
    (treemacs--evade-image)))

(defun treemacs-goto-parent-node ()
  "Select parent of selected node, if possible."
  (interactive)
  (--if-let (-some-> (treemacs-current-button) (button-get :parent))
      (goto-char it)
    (treemacs-pulse-on-failure "There is no parent to move up to.")))

(defun treemacs-next-neighbour ()
  "Select next node at the same depth as currently selected node, if possible."
  (interactive)
  (or (-some-> (treemacs-current-button)
            (treemacs--next-neighbour-of)
            (goto-char))
      (treemacs-pulse-on-failure)))

(defun treemacs-previous-neighbour ()
  "Select previous node at the same depth as currently selected node, if possible."
  (interactive)
  (or (-some-> (treemacs-current-button)
            (treemacs--prev-neighbour-of)
            (goto-char))
      (treemacs-pulse-on-failure)))

(defun treemacs-visit-node-vertical-split (&optional arg)
  "Open current file or tag by vertically splitting `next-window'.
Stay in current window with a prefix argument ARG."
  (interactive "P")
  (treemacs--execute-button-action
   :split-function #'split-window-vertically
   :file-action (find-file (treemacs-safe-button-get btn :path))
   :dir-action (dired (treemacs-safe-button-get btn :path))
   :tag-section-action (treemacs--visit-or-expand/collapse-tag-node btn arg nil)
   :tag-action (treemacs--goto-tag btn)
   :save-window arg
   :no-match-explanation "Node is neither a file, a directory or a tag - nothing to do here."))

(defun treemacs-visit-node-horizontal-split (&optional arg)
  "Open current file or tag by horizontally splitting `next-window'.
Stay in current window with a prefix argument ARG."
  (interactive "P")
  (treemacs--execute-button-action
   :split-function #'split-window-horizontally
   :file-action (find-file (treemacs-safe-button-get btn :path))
   :dir-action (dired (treemacs-safe-button-get btn :path))
   :tag-section-action (treemacs--visit-or-expand/collapse-tag-node btn arg nil)
   :tag-action (treemacs--goto-tag btn)
   :save-window arg
   :no-match-explanation "Node is neither a file, a directory or a tag - nothing to do here."))

(defun treemacs-visit-node-no-split (&optional arg)
  "Open current file or tag within the window the file is already opened in.
If the file/tag is no visible opened in any window use `next-window' instead.
Stay in current window with a prefix argument ARG."
  (interactive "P")
  (treemacs--execute-button-action
   :file-action (find-file (treemacs-safe-button-get btn :path))
   :dir-action (dired (treemacs-safe-button-get btn :path))
   :tag-section-action (treemacs--visit-or-expand/collapse-tag-node btn arg nil)
   :tag-action (treemacs--goto-tag btn)
   :save-window arg
   :ensure-window-split t
   :window  (-some-> btn (treemacs--nearest-path) (get-file-buffer) (get-buffer-window))
   :no-match-explanation "Node is neither a file, a directory or a tag - nothing to do here."))

(defun treemacs-visit-node-ace (&optional arg)
  "Open current file or tag in window selected by `ace-window'.
Stay in current window with a prefix argument ARG."
  (interactive "P")
  (treemacs--execute-button-action
   :window (aw-select "Select window")
   :file-action (find-file (treemacs-safe-button-get btn :path))
   :dir-action (dired (treemacs-safe-button-get btn :path))
   :tag-section-action (treemacs--visit-or-expand/collapse-tag-node btn arg nil)
   :tag-action (treemacs--goto-tag btn)
   :save-window arg
   :ensure-window-split t
   :no-match-explanation "Node is neither a file, a directory or a tag - nothing to do here."))

(defun treemacs-visit-node-ace-horizontal-split (&optional arg)
  "Open current file by horizontally splitting window selected by `ace-window'.
Stay in current window with a prefix argument ARG."
  (interactive "P")
  (treemacs--execute-button-action
   :split-function #'split-window-horizontally
   :window (aw-select "Select window")
   :file-action (find-file (treemacs-safe-button-get btn :path))
   :dir-action (dired (treemacs-safe-button-get btn :path))
   :tag-section-action (treemacs--visit-or-expand/collapse-tag-node btn arg nil)
   :tag-action (treemacs--goto-tag btn)
   :save-window arg
   :no-match-explanation "Node is neither a file, a directory or a tag - nothing to do here."))

(defun treemacs-visit-node-ace-vertical-split (&optional arg)
  "Open current file by vertically splitting window selected by `ace-window'.
Stay in current window with a prefix argument ARG."
  (interactive "P")
  (treemacs--execute-button-action
   :split-function #'split-window-vertically
   :window (aw-select "Select window")
   :file-action (find-file (treemacs-safe-button-get btn :path))
   :dir-action (dired (treemacs-safe-button-get btn :path))
   :tag-section-action (treemacs--visit-or-expand/collapse-tag-node btn arg nil)
   :tag-action (treemacs--goto-tag btn)
   :save-window arg
   :no-match-explanation "Node is neither a file, a directory or a tag - nothing to do here."))

(defun treemacs-RET-action (&optional arg)
  "Run the appropriate RET action for the current button.

In the default configuration this usually means to open the content of the
currently selected node. A potential prefix ARG is passed on to the executed
action, if possible.

This function's exact configuration is stored in `treemacs-RET-actions-config'."
  (interactive "P")
  (-when-let (state (treemacs--prop-at-point :state))
    (funcall (cdr (assq state treemacs-RET-actions-config)) arg)))

(defun treemacs-define-RET-action (state action)
  "Define the behaviour of `treemacs-RET-action'.
Determines that a button with a given STATE should lead to the execution of
ACTION.

First deletes the previous entry with key STATE from
`treemacs-RET-actions-config'and then inserts the new tuple."
  (setq treemacs-RET-actions-config (assq-delete-all state treemacs-RET-actions-config))
  (push (cons state action) treemacs-RET-actions-config))

(defun treemacs-define-TAB-action (state action)
  "Define the behaviour of `treemacs-TAB-action'.
Determines that a button with a given STATE should lead to the execution of
ACTION.

First deletes the previous entry with key STATE from
`treemacs-TAB-actions-config' and then inserts the new tuple."
  (setq treemacs-TAB-actions-config (assq-delete-all state treemacs-TAB-actions-config))
  (push (cons state action) treemacs-TAB-actions-config))

(defun treemacs-visit-node-in-external-application ()
  "Open current file according to its mime type in an external application.
Treemacs knows how to open files on linux, windows and macos."
  (interactive)
  ;; code adapted from ranger.el
  (-if-let (path (treemacs--prop-at-point :path))
      (pcase system-type
       ('windows-nt
        (declare-function w32-shell-execute "w32fns.c")
        (w32-shell-execute "open" (replace-regexp-in-string "/" "\\" path t t)))
       ('darwin
        (shell-command (format "open \"%s\"" path)))
       ('gnu/linux
        (let ((process-connection-type nil))
          (start-process "" nil "xdg-open" path)))
       (_ (treemacs-pulse-on-failure "Don't know how to open files on %s."
                         (propertize (symbol-name system-type) 'face 'font-lock-string-face))))
    (treemacs-pulse-on-failure "Nothing to open here.")))

(defun treemacs-kill-buffer ()
  "Kill the treemacs buffer."
  (interactive)
  (when (eq 'treemacs-mode major-mode)
    ;; teardown logic handled in kill hook
    (if (one-window-p)
        (kill-this-buffer)
      (kill-buffer-and-window))))

(defun treemacs-delete (&optional arg)
  "Delete node at point.
A delete action must always be confirmed. Directories are deleted recursively.
By default files are deleted by moving them to the trash. With a prefix ARG they
will instead be wiped irreversibly."
  (interactive "P")
  (-if-let (btn (treemacs-current-button))
      (if (not (memq (button-get btn :state) '(file-node-open file-node-closed dir-node-open dir-node-closed)))
          (treemacs-pulse-on-failure "Only files and directories can be deleted.")
        (let* ((delete-by-moving-to-trash (not arg))
               (path (button-get btn :path))
               (file-name (f-filename path)))
          (when
              (cond
               ((f-file? path)
                (when (yes-or-no-p (format "Delete %s ? " file-name))
                  (treemacs--without-filewatch (delete-file path delete-by-moving-to-trash))
                  t))
               ((f-directory? path)
                (when (yes-or-no-p (format "Recursively delete %s ? " file-name))
                  (treemacs--without-filewatch (delete-directory path t delete-by-moving-to-trash))
                  t))
               (t (progn
                    (treemacs-pulse-on-failure
                        "Item is neither a file, nor a directory - treemacs does not know how to delete it. (Maybe it no longer exists?)")
                    nil)))
            (treemacs--on-file-deletion path)
            (treemacs-without-messages
             (treemacs-run-in-every-buffer
              (-when-let (project (treemacs--find-project-for-path path))
                (when (treemacs-is-path-visible? path)
                  (treemacs--do-refresh (current-buffer) project))))))))
    (treemacs-pulse-on-failure "Nothing to delete here."))
  (treemacs--evade-image))

(defun treemacs-create-file ()
  "Create a new file.
Enter first the directory to create the new file in, then the new file's name.
The preselection for what directory to create in is based on the \"nearest\"
path to point - the containing directory for tags and files or the directory
itself, using $HOME when there is no path at or near point to grab."
  (interactive)
  (treemacs--create-file/dir t))

(cl-defun treemacs-rename ()
  "Rename the currently selected node.
Buffers visiting the renamed file or visiting a file inside a renamed directory
and windows showing them will be reloaded. The list of recent files will
likewise be updated."
  (interactive)
  (cl-block body
    (-let [btn (treemacs-current-button)]
      (unless btn
        (cl-return-from body
         (treemacs-pulse-on-failure "Found nothing to rename here.")))
      (let* ((old-path (button-get btn :path))
             (project (treemacs--find-project-for-path old-path))
             (new-path nil)
             (new-name nil)
             (dir nil))
        (unless old-path
          (cl-return-from body
            (treemacs-pulse-on-failure "Found nothing to rename here.")))
        (unless (file-exists-p old-path)
          (cl-return-from body
           (treemacs-pulse-on-failure "The file to be renamed does not exist.")))
        (setq new-name (read-string "New name: " (file-name-nondirectory old-path))
              dir      (f-dirname old-path)
              new-path (f-join dir new-name))
        (when (file-exists-p new-path)
          (cl-return-from body
           (treemacs-pulse-on-failure "A file named %s already exists."
             (propertize new-name 'face font-lock-string-face))))
        (treemacs--without-filewatch (rename-file old-path new-path))
        (treemacs--replace-recentf-entry old-path new-path)
        (-let [treemacs-silent-refresh t]
          (treemacs-run-in-every-buffer
           (treemacs--on-rename old-path new-path)
           (treemacs--do-refresh (current-buffer) project)))
        (treemacs--reload-buffers-after-rename old-path new-path)
        (treemacs-goto-button new-path project)
        (treemacs-pulse-on-success "Renamed %s to %s."
          (propertize (f-filename old-path) 'face font-lock-string-face)
          (propertize new-name 'face font-lock-string-face))))))

(defun treemacs-create-dir ()
  "Create a new directory.
Enter first the directory to create the new dir in, then the new dir's name.
The preselection for what directory to create in is based on the \"nearest\"
path to point - the containing directory for tags and files or the directory
itself, using $HOME when there is no path at or near pooint to grab."
  (interactive)
  (treemacs--create-file/dir nil))

(defun treemacs-toggle-show-dotfiles ()
  "Toggle the hiding and displaying of dotfiles."
  (interactive)
  (setq treemacs-show-hidden-files (not treemacs-show-hidden-files))
  (--each (-map #'cdr treemacs--buffer-access) (treemacs--do-refresh it 'all))
  (treemacs-log (concat "Dotfiles will now be "
                         (if treemacs-show-hidden-files
                             "displayed." "hidden."))))

(defun treemacs-toggle-fixed-width ()
  "Toggle whether the treemacs buffer should have a fixed width.
See also `treemacs-width.'"
  (interactive)
  (setq treemacs--width-is-locked (not treemacs--width-is-locked))
  (treemacs-log "Window width has been %s."
                 (propertize (if treemacs--width-is-locked "locked" "unlocked")
                             'face 'font-lock-string-face)))

(defun treemacs-set-width (&optional arg)
  "Select a new value for `treemacs-width'.
With a prefix ARG simply reset the width of the treemacs window."
  (interactive "P")
  (unless arg
    (setq treemacs-width
          (->> treemacs-width
               (format "New Width (current = %s): ")
               (read-number))))
  (treemacs--set-width treemacs-width))

(defun treemacs-copy-path-at-point ()
  "Copy the absolute path of the node at point."
  (interactive)
  (--if-let (-some-> (treemacs--prop-at-point :path) (f-full) (kill-new))
        (treemacs-pulse-on-success "Copied path: %s" (propertize it 'face 'font-lock-string-face))
    (treemacs-pulse-on-failure  "There is nothing to copy here")))

(defun treemacs-copy-project-root ()
  "Copy the absolute path of the current treemacs root."
  (interactive)
  (--if-let (treemacs-current-button)
      (-let [path (-> it (treemacs--nearest-path) (treemacs--find-project-for-path) (treemacs-project->path))]
        (kill-new path)
        (treemacs-log "Copied project root: %s" (propertize path 'face 'font-lock-string-face)))
    (treemacs-pulse-on-failure "There is no project to copy from here.")))

(defun treemacs-delete-other-windows ()
  "Same as `delete-other-windows', but will not delete the treemacs window.
If this command is run when the treemacs window is selected `next-window' will
also not be deleted."
  (interactive)
  (save-selected-window
    (-let [w (treemacs-get-local-window)]
      (when (eq w (selected-window))
        (select-window (next-window)))
      (delete-other-windows)
      ;; we still want to call `delete-other-windows' since it contains plenty of nontrivial code
      ;; that we shouldn't prevent from running, so we just restore treemacs instead of preventing
      ;; it from being deleted
      ;; 'no-delete-other-windows could be used instead, but it's only available for emacs 26
      (when w
        (treemacs--select-not-visible-window)))))

(defun treemacs-temp-resort-root (&optional sort-method)
  "Temporarily resort the entire treemacs buffer.
SORT-METHOD is a cons of a string describing the method and the actual sort
value, as returned by `treemacs--sort-value-selection'. SORT-METHOD will be
provided when this function is called from `treemacs-resort' and will be
interactively read otherwise. This way this function can be bound directly,
without the need to call `treemacs-resort' with a prefix arg."
  (interactive)
  (-let* (((sort-name . sort-method) (or sort-method (treemacs--sort-value-selection)))
          (treemacs-sorting sort-method))
    (treemacs-without-messages (treemacs-refresh))
    (treemacs-log "Temporarily resorted everything with sort method '%s.'"
                   (propertize sort-name 'face 'font-lock-type-face))))

(defun treemacs-temp-resort-current-dir (&optional sort-method)
  "Temporarily resort the current directory.
SORT-METHOD is a cons of a string describing the method and the actual sort
value, as returned by `treemacs--sort-value-selection'. SORT-METHOD will be
provided when this function is called from `treemacs-resort' and will be
interactively read otherwise. This way this function can be bound directly,
without the need to call `treemacs-resort' with a prefix arg."
  (interactive)
  (-let* (((sort-name . sort-method) (or sort-method (treemacs--sort-value-selection)))
          (treemacs-sorting sort-method))
    (-if-let (btn (treemacs-current-button))
             (pcase (button-get btn :state)
               ('dir-node-closed
                (treemacs--expand-dir-node btn)
                (treemacs-log "Resorted %s with sort method '%s'."
                               (propertize (treemacs--get-label-of btn) 'face 'font-lock-string-face)
                               (propertize sort-name 'face 'font-lock-type-face)))
               ('dir-node-open
                (treemacs--collapse-dir-node btn)
                (goto-char (button-start btn))
                (treemacs--expand-dir-node btn)
                (treemacs-log "Resorted %s with sort method '%s'."
                               (propertize (treemacs--get-label-of btn) 'face 'font-lock-string-face)
                               (propertize sort-name 'face 'font-lock-type-face)))
               ((or 'file-node-open 'file-node-closed 'tag-node-open 'tag-node-closed 'tag-node)
                (let* ((parent (button-get btn :parent)))
                  (while (and parent
                              (not (-some-> parent (button-get :path) (f-directory?))))
                    (setq parent (button-get parent :parent)))
                  (if parent
                      (let ((line (line-number-at-pos))
                            (window-point (window-point)))
                        (goto-char (button-start parent))
                        (treemacs--collapse-dir-node parent)
                        (goto-char (button-start btn))
                        (treemacs--expand-dir-node parent)
                        (set-window-point (selected-window) window-point)
                        (with-no-warnings (goto-line line))
                        (treemacs-log "Resorted %s with sort method '%s'."
                                       (propertize (treemacs--get-label-of parent) 'face 'font-lock-string-face)
                                       (propertize sort-name 'face 'font-lock-type-face)))
                    ;; a top level file's containing dir is root
                    (treemacs-without-messages (treemacs-refresh))
                    (treemacs-log "Resorted root directory with sort method '%s'."
                                   (propertize sort-name 'face 'font-lock-type-face)))))))))

(defun treemacs-resort (&optional arg)
  "Select a new permanent value for `treemacs-sorting' and refresh.
With a single prefix ARG use the new sort value to *temporarily* resort the
\(closest\) directory at point.
With a double prefix ARG use the new sort value to *temporarily* resort the
entire treemacs view.

Temporary sorting will only stick around until the next refresh, either manual
or automatic via `treemacs-filewatch-mode'.

Instead of calling this with a prefix arg you can also direcrly call
`treemacs-temp-resort-current-dir' and `treemacs-temp-resort-root'."
  (interactive "P")
  (pcase arg
    ;; Resort current dir only
    (`(4)
     (treemacs-temp-resort-current-dir))
    ;; Temporarily resort everything
    (`(16)
     (treemacs-temp-resort-root))
    ;; Set new permanent value
    (_
     (-let (((sort-name . sort-value) (treemacs--sort-value-selection)))
       (setq treemacs-sorting sort-value)
       (treemacs-without-messages (treemacs-refresh))
       (treemacs-log "Sorting method changed to '%s'."
                      (propertize sort-name 'face 'font-lock-type-face)))))
  (treemacs--evade-image))

(defun treemacs-add-bookmark ()
  "Add the current node to Emacs' list of bookmarks.
For file and directory nodes their absolute path is saved. Tag nodes
additionally also save the tag's position. A tag can only be bookmarked if the
treemacs node is pointing to a valid buffer position."
  (interactive)
  (treemacs-with-current-button
   "There is nothing to bookmark here."
   (pcase (button-get current-btn :state)
     ((or 'file-node-open 'file-node-closed 'dir-node-open 'dir-node-closed)
      (-let [name (read-string "Bookmark name: ")]
        (bookmark-store name `((filename . ,(button-get current-btn :path))) nil)))
     ('tag-node
      (-let [(tag-buffer . tag-pos) (treemacs--extract-position (button-get current-btn :marker))]
        (if (buffer-live-p tag-buffer)
            (bookmark-store
             (read-string "Bookmark name: ")
             `((filename . ,(buffer-file-name tag-buffer))
               (position . ,tag-pos))
             nil)
          (treemacs-log "Tag info can not be saved because it is not pointing to a live buffer."))))
     ((or 'tag-node-open 'tag-node-closed)
      (treemacs-pulse-on-failure "There is nothing to bookmark here.")))))

(defun treemacs-next-line-other-window (&optional count)
  "Scroll forward COUNT lines in `next-window'."
  (interactive "p")
  (treemacs-without-following
   (with-selected-window (next-window)
     (scroll-up-line count))))

(defun treemacs-previous-line-other-window (&optional count)
  "Scroll backward COUNT lines in `next-window'."
  (interactive "p")
  (treemacs-without-following
   (with-selected-window (next-window)
     (scroll-down-line count))))

(defun treemacs-next-page-other-window (&optional count)
  "Scroll forward COUNT pages in `next-window'.
For slower scrolling see `treemacs-next-line-other-window'"
  (interactive "p")
  (treemacs-without-following
   (with-selected-window (next-window)
     (condition-case _
         (dotimes (_ (or count 1))
           (scroll-up nil))
       (end-of-buffer (goto-char (point-max)))))))

(defun treemacs-previous-page-other-window (&optional count)
  "Scroll baclward COUNT pages in `next-window'.
For slower scrolling see `treemacs-previous-line-other-window'"
  (interactive "p")
  (treemacs-without-following
   (with-selected-window (next-window)
     (condition-case _
         (dotimes (_ (or count 1))
           (scroll-down nil))
       (beginning-of-buffer (goto-char (point-min)))))))

(defun treemacs-next-project ()
  "Move to the next project root node."
  (interactive)
  (-let [pos (next-single-char-property-change (point-at-eol) :project)]
    (if (or (= pos (point))
            (= pos (point-max)))
        (treemacs-pulse-on-failure "There is no next project to move to.")
      (goto-char pos))))

(defun treemacs-previous-project ()
  "Move to the next project root node."
  (interactive)
  (-let [pos (previous-single-char-property-change (point-at-bol) :project)]
    (if (or (= pos (point))
            (= pos (point-min)))
        (treemacs-pulse-on-failure "There is no previous project to move to.")
      (goto-char pos))))

(defun treemacs-rename-project ()
  "Give the project at point a new name."
  (interactive)
  (treemacs-with-writable-buffer
   (treemacs-unless-let (project (treemacs-project-at-point))
       (treemacs-pulse-on-failure "There is no project here.")
     (let* ((old-name (treemacs-project->name project))
            (project-btn (treemacs-project->position project))
            (state (button-get project-btn :state))
            (new-name (read-string "New name: " (treemacs-project->name project))))
       (treemacs-save-position
        (progn
          (setf (treemacs-project->name project) new-name)
          (treemacs--forget-last-highlight)
          ;; after renaming, delete and redisplay the project
          (goto-char (button-end project-btn))
          (delete-region (point-at-bol) (point-at-eol))
          (treemacs--add-root-element project)
          (when (eq state 'root-node-open)
            (treemacs--collapse-root-node (treemacs-project->position project))
            (treemacs--expand-root-node (treemacs-project->position project))))
        (treemacs-pulse-on-success "Renamed project %s to %s."
          (propertize old-name 'face 'font-lock-type-face)
          (propertize new-name 'face 'font-lock-type-face))))))
  (treemacs--evade-image))

(defun treemacs-add-project-to-workspace (path)
  "Add a projec at given PATH to the current workspace."
  (interactive "DProject root: ")
  (pcase (treemacs-do-add-project-to-workspace path)
    (`(success ,project)
     (treemacs-pulse-on-success "Added project %s to the workspace."
       (propertize (treemacs-project->name project) 'face 'font-lock-type-face)))
    (`(invalid-name ,name)
     (treemacs-pulse-on-failure "Name '%s' is invalid."
       (propertize name 'face 'font-lock-string-face)))
    (`(duplicate-project ,duplicate)
     (goto-char (treemacs-project->position duplicate))
     (treemacs-pulse-on-success "A project for %s already exists."
       (propertize (treemacs-project->path duplicate) 'face 'font-lock-string-face)))
    (`(duplicate-name ,duplicate)
     (goto-char (treemacs-project->position duplicate))
     (treemacs-pulse-on-failure "A project with the name %s already exists."
             (propertize (treemacs-project->name duplicate) 'face 'font-lock-type-face)))))
(defalias 'treemacs-add-project #'treemacs-add-project-to-workspace)
(with-no-warnings
  (make-obsolete #'treemacs-add-project #'treemacs-add-project-to-workspace "v2.2.1"))

(defun treemacs-remove-project-from-workspace ()
  "Remove the project at point from the current workspace."
  (interactive)
  (treemacs-unless-let (project (treemacs-project-at-point))
      (treemacs-pulse-on-failure "There is no project here.")
    (treemacs-do-remove-project-from-workspace project)
    (treemacs-pulse-on-success "Removed project %s from the workspace."
      (propertize (treemacs-project->name project) 'face 'font-lock-type-face))))

(defun treemacs-create-workspace ()
  "Create a new workspace."
  (interactive)
  (pcase (treemacs-do-create-workspace)
    (`(success ,workspace)
     (treemacs-pulse-on-success "Workspace %s successfully created."
       (propertize (treemacs-workspace->name workspace) 'face 'font-lock-type-face)))
    (`(invalid-name ,name)
     (treemacs-pulse-on-failure "Name '%s' is invalid."
       (propertize name 'face 'font-lock-string-face)))
    (`(duplicate-name ,duplicate)
     (treemacs-pulse-on-failure "A workspace with the name %s already exists."
       (propertize (treemacs-workspace->name duplicate) 'face 'font-lock-string-face)))))

(defun treemacs-remove-workspace ()
  "Delete a workspace."
  (interactive)
  (pcase (treemacs-do-remove-workspace :ask-to-confirm)
    ('only-one-workspace
     (treemacs-pulse-on-failure "You cannot delete the last workspace."))
    ('user-cancel
     (ignore))
    (`(success ,deleted ,_)
     (treemacs-pulse-on-success "Workspace %s was deleted."
       (propertize (treemacs-workspace->name deleted) 'face 'font-lock-type-face)))))

(defun treemacs-switch-workspace ()
  "Select a different workspace for treemacs."
  (interactive)
  (pcase (treemacs-do-switch-workspace)
    ('only-one-workspace
     (treemacs-pulse-on-failure "There are no other workspaces to select."))
    (`(success ,workspace)
     (let ((window-visible? nil)
           (buffer-exists? nil))
       (pcase (treemacs-current-visibility)
         ('visible
          (setq window-visible? t
                buffer-exists? t))
         ('exists
          (setq buffer-exists? t)))
       (when window-visible?
         (delete-window (treemacs-get-local-window)))
       (when buffer-exists?
         (kill-buffer (treemacs-get-local-buffer)))
       (when buffer-exists?
         (let ((treemacs-follow-after-init nil)
               (treemacs-follow-mode nil))
           (treemacs-select-window)))
       (when (not window-visible?)
         (bury-buffer)))
     (treemacs-pulse-on-success "Selected workspace %s."
       (propertize (treemacs-workspace->name workspace))))))

(defun treemacs-refresh ()
  "Refresh the project at point."
  (interactive)
  (treemacs-unless-let (btn (treemacs-current-button))
      (treemacs-log "There is nothing to refresh.")
    (->> btn
         (treemacs--nearest-path)
         (treemacs--find-project-for-path)
         (treemacs--do-refresh (current-buffer)))
    (unless (pos-visible-in-window-p)
      (recenter))))

(defun treemacs-collapse-project (&optional arg)
  "Close the project at point.
With a prefix ARG also forget about all the nodes opened in the project."
  (interactive "P")
  (treemacs-unless-let (btn (treemacs-current-button))
      (treemacs-pulse-on-failure "There is nothing to close here.")
    (while (not (button-get btn :project))
      (setq btn (button-get btn :parent)))
    (when (eq 'root-node-open (button-get btn :state))
      (treemacs--forget-last-highlight)
      (goto-char btn)
      (treemacs--collapse-root-node btn arg)
      (treemacs--maybe-recenter))))

(defun treemacs-collapse-all-projects (&optional arg)
  "Collapses all projects.
With a prefix ARG also forget about all the nodes opened in the projects."
  (interactive "P")
  (save-excursion
    (treemacs--forget-last-highlight)
    (dolist (project (treemacs-workspace->projects (treemacs-current-workspace)))
      (-when-let (pos (treemacs-project->position project))
        (when (eq 'root-node-open (button-get pos :state))
          (goto-char pos)
          (treemacs--collapse-root-node pos arg)))))
  (treemacs--maybe-recenter))

(defun treemacs-collapse-other-projects (&optional arg)
  "Collapses all projects except the project at point.
With a prefix ARG also forget about all the nodes opened in the projects."
  (interactive "P")
  (save-excursion
    (-let [curr-project (-some-> (treemacs-current-button)
                                 (treemacs--nearest-path)
                                 (treemacs--find-project-for-path))]
      (dolist (project (treemacs-workspace->projects (treemacs-current-workspace)))
        (unless (eq project curr-project)
          (-when-let (pos (treemacs-project->position project))
            (when (eq 'root-node-open (button-get pos :state))
              (goto-char pos)
              (treemacs--collapse-root-node pos arg)))))))
  (treemacs--maybe-recenter))

(defun treemacs-peek ()
  "Peek at the content of the node at point.
This will display the file (or tag) at point in `next-window' much like
`treemacs-visit-node-no-split' would. The difference that the file is not
really (or rather permanently) opened - any command other than `treemacs-peek',
`treemacs-next-line-other-window', `treemacs-previous-line-other-window',
`treemacs-next-page-other-window' or `treemacs-previous-page-other-window' will
cause it to be closed again and the previously shown buffer to be restored. The
buffer visiting the peeked file will also be killed again, unless it was already
open before eing used for peeking."
  (interactive)
  (treemacs--execute-button-action
   :save-window t
   :ensure-window-split t
   :window (-some-> btn (treemacs--nearest-path) (get-file-buffer) (get-buffer-window))
   :no-match-explanation "Only files and tags are peekable."
   :file-action (treemacs--setup-peek-buffer btn)
   :tag-action (treemacs--setup-peek-buffer btn t)))

(defun treemacs-root-up ()
  "Move treemacs' root one level upward.
Only works with a single project in the workspace."
  (interactive)
  (cl-block body
    (unless (= 1 (length (treemacs-workspace->projects (treemacs-current-workspace))))
      (cl-return-from body
        (treemacs-pulse-on-failure "Ad-hoc navigation is only possible when there is but a single project in the workspace.")))
    (-let [btn (treemacs-current-button)]
      (unless btn
        (setq btn (previous-button (point))))
      (let* ((project (-> btn (treemacs--nearest-path) (treemacs--find-project-for-path)))
             (root (treemacs-project->path project))
             (new-root (treemacs--parent root))
             (new-name (if (f-root? new-root)
                           "/"
                         (file-name-nondirectory new-root)))
             (treemacs--no-messages t)
             (treemacs-pulse-on-success nil))
        (unless (string= root new-root)
          (treemacs-remove-project-from-workspace)
          (treemacs-do-add-project-to-workspace new-root new-name)
          (treemacs-goto-button new-root)
          (treemacs-toggle-node))))))

(defun treemacs-root-down ()
  "Move treemacs' root into the directory at point.
Only works with a single project in the workspace."
  (interactive)
  (cl-block body
    (unless (= 1 (length (treemacs-workspace->projects (treemacs-current-workspace))))
      (cl-return-from body
        (treemacs-pulse-on-failure "Ad-hoc navigation is only possible when there is but a single project in the workspace.")))
    (treemacs-unless-let (btn (treemacs-current-button))
        (treemacs-pulse-on-failure
            "There is no directory to move into here.")
      (pcase (button-get btn :state)
        ((or 'dir-node-open 'dir-node-closed)
         (let ((new-root (button-get btn :path))
               (treemacs--no-messages t)
               (treemacs-pulse-on-success nil))
           (treemacs-remove-project-from-workspace)
           (treemacs-do-add-project-to-workspace new-root (file-name-nondirectory new-root))
           (treemacs-goto-button new-root)
           (treemacs-toggle-node)))
        (_
         (treemacs-pulse-on-failure "Button at point is not a directory."))))))

(provide 'treemacs-interface)

;;; treemacs-interface.el ends here
