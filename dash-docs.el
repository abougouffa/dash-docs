;;; dash-docs.el --- Offline documentation browser using Dash docsets  -*- lexical-binding: t; -*-
;; Copyright (C) 2013-2014, 2025  Raimon Grau
;; Copyright (C) 2013-2014  Toni Reina
;; Copyright (C) 2025       Abdelhak Bougouffa

;; Author: Raimon Grau <raimonster@gmail.com>
;;         Toni Reina  <areina0@gmail.com>
;;         Bryan Gilbert <bryan@bryan.sh>
;;         Abdelhak Bougouffa <abougouffa@fedoraproject.org>
;;
;; URL: http://github.com/abougouffa/dash-docs
;; Version: 2.0.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: docs

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
;;
;;; Commentary:
;;
;; A library that exposes functionality to work with and search dash
;; docsets.
;;
;; More info in the project site https://github.com/abougouffa/dash-docs
;;
;;; Code:

(require 'cl-lib)
(require 'json)
(require 'xml)
(require 'format-spec)
(require 'thingatpt)
(require 'sqlite)

(defgroup dash-docs nil
  "Search Dash docsets."
  :prefix "dash-docs-"
  :group 'applications)

(defcustom dash-docs-docsets-path
  (if-let* ((docsets-path (cond ((memq system-type '(gnu gnu/linux gnu/freebsd)) "~/.local/share/Zeal/Zeal/docsets")
                                ((eq system-type 'darwin) "~/Library/Application Support/Dash/DocSets")))
            (docsets-path (expand-file-name docsets-path))
            ((file-directory-p docsets-path)))
      docsets-path
    (if-let* ((docsets-path (expand-file-name "~/.docsets"))
              ((file-directory-p docsets-path)))
        docsets-path
      (locate-user-emacs-file "docsets/")))
  "Default path for docsets.
If you're setting this option manually, set it to an absolute
path.  You can use `expand-file-name' function for that."
  :set (lambda (opt val) (set opt (expand-file-name val)))
  :type 'directory
  :group 'dash-docs)

(defcustom dash-docs-docsets-url "https://raw.github.com/Kapeli/feeds/master"
  "Feeds URL for dash docsets."
  :type 'string
  :group 'dash-docs)

(defcustom dash-docs-min-length 3
  "Minimum length to start searching in docsets.
0 facilitates discoverability, but may be a bit heavy when lots
of docsets are active.  Between 0 and 3 is sane."
  :type 'natnum
  :group 'dash-docs)

(defcustom dash-docs-candidate-format "%d %n (%t)"
  "Format of the displayed candidates.
Available formats are
   %d - docset name
   %n - name of the token
   %t - type of the token
   %f - file name"
  :type 'string
  :group 'dash-docs)

(defcustom dash-docs-extra-feeds-alist
  '(("User Contributions" . "https://zealusercontributions.vercel.app/api/docsets")
    ("Generated" . "https://zealusercontributions.vercel.app/api/generated")
    ("Cheat Sheets" . "https://zealusercontributions.vercel.app/api/cheatsheets"))
  "An alist of (feed-name . url) of extra docsets feeds."
  :type 'alist
  :group 'dash-docs)

(defcustom dash-docs-browser-function 'browse-url
  "Default function to browse Dash's docsets.
Suggested values are:
 * `browse-url'
 * `eww-browse-url'
 * `xwidget-webkit-browse-url'"
  :type 'function
  :group 'dash-docs)

(defvar-local dash-docs-docsets nil
  "Buffer-local list of relevant docsets.")

(defvar dash-docs-common-docsets nil
  "List of Docsets to search active by default.")

(define-obsolete-function-alias 'dash-docs-async-install-docset 'dash-docs-install-docset "2.0.0")
(define-obsolete-function-alias 'dash-docs-async-install-docset-from-file 'dash-docs-install-docset-from-file "2.0.0")
(define-obsolete-function-alias 'dash-docs-install-user-docset 'dash-docs-install-extra-docset "2.0.0")
(define-obsolete-variable-alias 'dash-docs-browser-func 'dash-docs-browser-function "2.0.0")

(defalias 'dash-docs-update-docset 'dash-docs-install-docset)

(defun dash-docs-buffer-local-docsets ()
  "Get the installed buffer-local docsets."
  (cl-intersection dash-docs-docsets (dash-docs-installed-docsets) :test #'equal))

(defun dash-docs-docset-path (docset)
  "Return the full path of the directory for DOCSET."
  (let* ((base (dash-docs-docsets-path))
         (docdir (expand-file-name docset base)))
    (cl-loop for dir in (list (format "%s/%s.docset" base docset)
                              (format "%s/%s.docset" docdir docset)
                              (when (file-directory-p docdir)
                                (cl-first (directory-files docdir t "\\.docset\\'"))))
             when (and dir (file-directory-p dir))
             return dir)))

(defun dash-docs-docset-db-path (docset)
  "Compose the path to sqlite DOCSET."
  (let ((path (dash-docs-docset-path docset)))
    (if path
        (expand-file-name "Contents/Resources/docSet.dsidx" path)
      (error "Cannot find docset '%s' in `dash-docs-docsets-path'" docset))))

(defvar dash-docs--connections nil "List of conses like (\"Go\" . connection).")

(defun dash-docs-docsets-path ()
  "Return the path where Dash's docsets are stored."
  (let ((path (expand-file-name dash-docs-docsets-path)))
    (unless (file-exists-p path) (mkdir path :parents))
    (expand-file-name path)))

(defun dash-docs-sql (db-path sql)
  "Run in the db located at DB-PATH the SQL command and return the results."
  (let ((db (sqlite-open db-path t)))
    (sqlite-execute db sql)))

(defun dash-docs-parse-sql-results (sql-result-string)
  "Parse SQL-RESULT-STRING splitting it by newline and '|' chars."
  (mapcar (lambda (x) (split-string x "|" t))
          (split-string sql-result-string "\n" t)))

(defun dash-docs-filter-connections ()
  "Filter connections using `dash-docs--connections-filters'."
  (delq nil (mapcar (lambda (y) (assoc y dash-docs--connections))
                    (append (dash-docs-buffer-local-docsets) dash-docs-common-docsets))))

(defun dash-docs-create-common-connections ()
  "Create connections to sqlite docsets for common docsets."
  (when (not dash-docs--connections)
    (setq dash-docs--connections
          (mapcar (lambda (x)
                    (let ((db-path (dash-docs-docset-db-path x)))
                      (list x db-path (dash-docs-docset-type db-path))))
                  dash-docs-common-docsets))))

(defun dash-docs-create-buffer-connections ()
  "Create connections to sqlite docsets for buffer-local docsets."
  (mapc (lambda (x)
          (when (not (assoc x dash-docs--connections))
            (let ((connection (dash-docs-docset-db-path x)))
              (setq dash-docs--connections
                    (cons (list x connection (dash-docs-docset-type connection))
                          dash-docs--connections)))))
        (dash-docs-buffer-local-docsets)))

(defun dash-docs-reset-connections ()
  "Wipe all connections to docsets."
  (interactive)
  (setq dash-docs--connections nil))

(defun dash-docs-docset-type (db-path)
  "Return the type of the docset based in db schema.
Possible values are \"DASH\" and \"ZDASH\".
The Argument DB-PATH should be a string with the sqlite db path."
  (let ((sql "SELECT name FROM sqlite_master WHERE type = 'table' LIMIT 1"))
    (if (member "searchIndex" (car (dash-docs-sql db-path sql)))
        "DASH"
      "ZDASH")))

(defun dash-docs-read-json-from-url (url)
  "Read and return a JSON object from URL."
  (with-current-buffer (url-retrieve-synchronously url)
    (goto-char url-http-end-of-headers)
    (json-read)))


(defun dash-docs-unofficial-docsets (feed)
  "Return a list of lists with docsets contributed by users from FEED.
The first element is the docset's name second the docset's archive url."
  (let ((user-docs (dash-docs-read-json-from-url feed)))
    (mapcar (lambda (docset)
              (list (assoc-default 'name docset)
                    (seq-first (assoc-default 'urls docset))))
            user-docs)))

(defvar dash-docs-ignored-docsets
  '("Bootstrap" "Drupal" "Zend_Framework" "Ruby_Installed_Gems" "Man_Pages")
  "Return a list of ignored docsets.
These docsets are not available to install.
See here the reason: https://github.com/areina/helm-dash/issues/17.")

(defun dash-docs-official-docsets ()
  "Return a list of official docsets (http://kapeli.com/docset_links)."
  (let ((docsets (dash-docs-read-json-from-url "https://api.github.com/repos/Kapeli/feeds/contents/")))
    (delq nil (mapcar (lambda (docset)
                        (let ((name (assoc-default 'name docset)))
                          (if (and (equal (file-name-extension name) "xml")
                                   (not (member (file-name-sans-extension name) dash-docs-ignored-docsets)))
                              (file-name-sans-extension name))))
                      docsets))))

(defun dash-docs-installed-docsets ()
  "Return a list of installed docsets."
  (let ((docset-path (dash-docs-docsets-path)))
    (cl-loop for dir in (directory-files docset-path nil "^[^.]")
             for full-path = (expand-file-name dir docset-path)
             for subdir = (and (file-directory-p full-path)
                               (cl-first (directory-files full-path t "\\.docset\\'")))
             when (or (string-match-p "\\.docset\\'" dir)
                      (file-directory-p (expand-file-name (format "%s.docset" dir) full-path))
                      (and subdir (file-directory-p subdir)))
             collecting (replace-regexp-in-string "\\.docset\\'" "" dir))))

(defun dash-docs-read-docset (prompt choices)
  "PROMPT user to choose one of the docsets in CHOICES.
Report an error unless a valid docset is selected."
  (let ((completion-ignore-case t))
    (completing-read (format "%s (%s): " prompt (car choices)) choices nil t nil nil choices)))

;;;###autoload
(defun dash-docs-activate-docset (docset)
  "Activate DOCSET.  If called interactively prompts for the docset name."
  (interactive (list (dash-docs-read-docset "Activate docset" (dash-docs-installed-docsets))))
  (add-to-list 'dash-docs-common-docsets docset)
  (dash-docs-reset-connections))

;;;###autoload
(defun dash-docs-deactivate-docset (docset)
  "Deactivate DOCSET.  If called interactively prompts for the docset name."
  (interactive (list (dash-docs-read-docset "Deactivate docset" dash-docs-common-docsets)))
  (setq dash-docs-common-docsets (delete docset dash-docs-common-docsets)))

(defun dash-docs--install-docset (url docset-name)
  "Download a docset from URL and install with name DOCSET-NAME."
  (let ((docset-tmp-path (format "%s%s-docset.tgz" temporary-file-directory docset-name)))
    (url-copy-file url docset-tmp-path t)
    (dash-docs-install-docset-from-file docset-tmp-path)))

;;;###autoload
(defun dash-docs-activate-docset-for-buffer (docsets)
  "Register DOCSETS for the current buffer's mode."
  (interactive (list (completing-read-multiple "Select docsets: " (dash-docs-installed-docsets) nil t)))
  (setq-local dash-docs-docsets (cl-remove-duplicates (append dash-docs-docsets docsets))))

(defun dash-docs-extract-and-get-folder (docset-temp-path)
  "Extract DOCSET-TEMP-PATH to DASH-DOCS-DOCSETS-PATH, and return the folder that was newly extracted."
  (with-temp-buffer
    (let* ((call-process-args (list "tar" nil t nil))
           (process-args (list "xfv" docset-temp-path "-C" (dash-docs-docsets-path)))
           ;; On Windows, several elements need to be removed from filenames, see
           ;; https://docs.microsoft.com/en-us/windows/desktop/FileIO/naming-a-file#naming-conventions.
           ;; We replace with underscores on windows. This might lead to broken links.
           (windows-args (list "--force-local" "--transform" "s/[<>\":?*^|]/_/g"))
           (result (apply #'call-process (append call-process-args process-args (when (eq system-type 'windows-nt) windows-args)))))
      (goto-char (point-max))
      (cond
       ((and (not (equal result 0))
             ;; TODO: Adjust to proper text. Also requires correct locale.
             (search-backward "too long" nil t))
        (error "Failed to extract %s to %s. Filename too long. Consider changing `dash-docs-docsets-path' to a shorter value" docset-temp-path (dash-docs-docsets-path)))
       ((not (equal result 0)) (error "Failed to extract %s to %s. Error: %s" docset-temp-path (dash-docs-docsets-path) result)))
      (goto-char (point-max))
      (replace-regexp-in-string "^x " "" (car (split-string (thing-at-point 'line) "\\." t))))))

;;;###autoload
(defun dash-docs-install-docset-from-file (docset-tmp-path)
  "Extract the content of DOCSET-TMP-PATH, move it to `dash-docs-docsets-path` and activate the docset."
  (interactive (list (car (find-file-read-args "Docset Tarball: " t))))
  (let ((docset-folder (dash-docs-extract-and-get-folder docset-tmp-path)))
    (dash-docs-activate-docset docset-folder)
    (message "Docset installed. Add \"%s\" to dash-docs-common-docsets or dash-docs-docsets." docset-folder)))

;;;###autoload
(defun dash-docs-install-docset (docset-name)
  "Download an official docset with specified DOCSET-NAME and move its stuff to docsets-path."
  (interactive (list (dash-docs-read-docset "Install docset" (dash-docs-official-docsets))))
  (let ((feed-url (format "%s/%s.xml" dash-docs-docsets-url docset-name))
        (feed-tmp-path (format "%s%s-feed.xml" temporary-file-directory docset-name)))
    (url-copy-file feed-url feed-tmp-path t)
    (dash-docs--install-docset (dash-docs-get-docset-url feed-tmp-path) docset-name)))

;;;###autoload
(defun dash-docs-install-extra-docset (docset feed)
  "Install the unofficial DOCSET from FEED."
  (interactive (list nil (completing-read "Select the feed: " (mapcar #'car dash-docs-extra-feeds-alist) nil t)))
  (let* ((docsets (dash-docs-unofficial-docsets (alist-get feed dash-docs-extra-feeds-alist nil nil #'equal)))
         (docset (or docset (dash-docs-read-docset "Install docset" (mapcar 'car docsets)))))
    (dash-docs--install-docset (car (assoc-default docset docsets)) docset)))

(defun dash-docs-docset-installed-p (docset)
  "Return non-nil if DOCSET is installed."
  (member (replace-regexp-in-string "_" " " docset) (dash-docs-installed-docsets)))

;;;###autoload
(defun dash-docs-ensure-docset-installed (docset)
  "Install DOCSET if it is not currently installed."
  (unless (dash-docs-docset-installed-p docset)
    (dash-docs-install-docset docset)))

(defun dash-docs-get-docset-url (feed-path)
  "Parse a xml feed with docset urls and return the first url.
The Argument FEED-PATH should be a string with the path of the xml file."
  (let* ((xml (xml-parse-file feed-path))
         (urls (car xml))
         (url (xml-get-children urls 'url)))
    (cl-caddr (cl-first url))))

(defvar dash-docs--sql-queries
  '((DASH . (lambda (pattern)
              (let ((like (dash-docs-sql-compose-like "t.name" pattern))
                    (query "SELECT t.type, t.name, t.path FROM searchIndex t WHERE %s ORDER BY LENGTH(t.name), LOWER(t.name) LIMIT 1000"))
                (format query like))))
    (ZDASH . (lambda (pattern)
               (let ((like (dash-docs-sql-compose-like "t.ZTOKENNAME" pattern))
                     (query "SELECT ty.ZTYPENAME, t.ZTOKENNAME, f.ZPATH, m.ZANCHOR FROM ZTOKEN t, ZTOKENTYPE ty, ZFILEPATH f, ZTOKENMETAINFORMATION m WHERE ty.Z_PK = t.ZTOKENTYPE AND f.Z_PK = m.ZFILE AND m.ZTOKEN = t.Z_PK AND %s ORDER BY LENGTH(t.ZTOKENNAME), LOWER(t.ZTOKENNAME) LIMIT 1000"))
                 (format query like))))))

(defun dash-docs-sql-compose-like (column pattern)
  "Return a query fragment for a sql where clause.
Search in column COLUMN by multiple terms splitting the PATTERN
by whitespace and using like sql operator."
  (let ((conditions (mapcar (lambda (word) (format "%s like '%%%s%%'" column word))
                            (split-string pattern " "))))
    (format "%s" (mapconcat 'identity conditions " AND "))))

(defun dash-docs-sql-query (docset-type pattern)
  "Return a SQL query to search documentation in dash docsets.
A different query is returned depending on DOCSET-TYPE.  PATTERN
is used to compose the SQL WHERE clause."
  (when-let* ((func (alist-get (intern docset-type) dash-docs--sql-queries)))
    (funcall func pattern)))

(defun dash-docs-maybe-narrow-docsets (pattern)
  "Return a list of dash-docs-connections.
If PATTERN starts with the name of a docset followed by a space, narrow
the used connections to just that one. We're looping on all connections,
but it shouldn't be a problem as there won't be many."
  (let ((conns (dash-docs-filter-connections)))
    (or (cl-loop for x in conns
                 if (string-prefix-p
                     (concat (downcase (car x)) " ")
                     (downcase pattern))
                 return (list x))
        conns)))

(defun dash-docs-sub-docset-name-in-pattern (pattern docset-name)
  "Remove from PATTERN the DOCSET-NAME if this includes it.
If the search starts with the name of the docset, ignore it.
Ex: This avoids searching for redis in redis unless you type 'redis redis'"
  (replace-regexp-in-string
   (format "^%s " (regexp-quote (downcase docset-name))) "" pattern))

(defun dash-docs--run-query (docset search-pattern)
  "Execute an sql query in dash docset DOCSET looking for SEARCH-PATTERN.
Return a list of db results.  Ex:

'((\"func\" \"BLPOP\" \"commands/blpop.html\")
  (\"func\" \"PUBLISH\" \"commands/publish.html\")
  (\"func\" \"problems\" \"topics/problems.html\"))"
  (let ((docset-type (cl-caddr docset)))
    (dash-docs-sql
     (cadr docset)
     (dash-docs-sql-query
      docset-type
      (dash-docs-sub-docset-name-in-pattern search-pattern (car docset))))))

(defun dash-docs--candidate (docset row)
  "Return list extracting info from DOCSET and ROW to build a result candidate.
First element is the display message of the candidate, rest is used to build
candidate opts."
  (cons (format-spec dash-docs-candidate-format
                     (list (cons ?d (cl-first docset))
                           (cons ?n (cl-second row))
                           (cons ?t (cl-first row))
                           (cons ?f (replace-regexp-in-string
                                     "^.*/\\([^/]*\\)\\.html?#?.*"
                                     "\\1"
                                     (cl-third row)))))
        (list (car docset) row)))

(defun dash-docs-result-url (docset-name filename &optional anchor)
  "Return the full, absolute URL to documentation.
Either a file:/// URL joining DOCSET-NAME, FILENAME & ANCHOR with sanitization
of spaces or a http(s):// URL formed as-is if FILENAME is a full HTTP(S) URL."
  (let* ((clean-filename (replace-regexp-in-string "<dash_entry_.*>" "" filename))
         (path (format "%s%s" clean-filename (if anchor (format "#%s" anchor) ""))))
    (if (string-match-p "^https?://" path)
        path
      (replace-regexp-in-string
       " "
       "%20"
       (concat
        "file:///"
        (expand-file-name "Contents/Resources/Documents/" (dash-docs-docset-path docset-name))
        path)))))

(defun dash-docs-browse-url (search-result)
  "Call to `browse-url' with the result returned by `dash-docs-result-url'.
Get required params to call `dash-docs-result-url' from SEARCH-RESULT."
  (let ((docset-name (car search-result))
        (filename (nth 2 (cadr search-result)))
        (anchor (nth 3 (cadr search-result))))
    (funcall dash-docs-browser-function (dash-docs-result-url docset-name filename anchor))))

(defun dash-docs-add-to-kill-ring (search-result)
  "Add to kill ring a formatted string to call `dash-docs-browse-url' with SEARCH-RESULT."
  (kill-new (format "(dash-docs-browse-url '%S)" search-result)))

(defun dash-docs-actions (actions doc-item)
  "Return an alist with the possible ACTIONS to execute with DOC-ITEM."
  (ignore doc-item)
  (ignore actions)
  `(("Go to doc" . dash-docs-browse-url)
    ("Copy to clipboard" . dash-docs-add-to-kill-ring)))

(defun dash-docs-search-docset (docset pattern)
  "Given a string PATTERN, query DOCSET and retrieve result."
  (cl-loop for row in (dash-docs--run-query docset pattern)
           collect (dash-docs--candidate docset row)))

;;;###autoload
(defun dash-docs-search (pattern)
  "Given a string PATTERN, query docsets and retrieve result."
  (when (>= (length pattern) dash-docs-min-length)
    (cl-loop for docset in (dash-docs-maybe-narrow-docsets pattern)
             appending (dash-docs-search-docset docset pattern))))

;; Extend `use-package' with `:dash' keyword
;;;###autoload(with-eval-after-load 'use-package (require 'use-package-dash-docs))

(provide 'dash-docs)
;;; dash-docs.el ends here
