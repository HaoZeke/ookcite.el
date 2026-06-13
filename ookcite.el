;;; ookcite.el --- OokCite lookup, BibTeX, collections, and Ridley notes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Rohit Goswami

;; Author: Rohit Goswami <rgoswami@ieee.org>
;; Maintainer: Rohit Goswami <rgoswami@ieee.org>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, convenience, wp
;; URL: https://github.com/HaoZeke/ookcite.el

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; ookcite.el provides a small Emacs client for OokCite and a reading-note
;; bridge for Ridley PDF metadata.
;;
;; The OokCite layer resolves DOI/ISBN/free-text citations, appends BibTeX,
;; inserts org-cite references, searches CSL styles, formats references, and
;; imports/exports OokCite collections, including one-entry imports for
;; adding a resolved citation directly to a collection.
;;
;; The Ridley layer creates org-noter-compatible notes from Ridley item JSON,
;; seed fixture JSON, or a chosen PDF path.  It writes `:NOTER_DOCUMENT:' plus
;; Ridley identifiers as Org properties so the note opens like an
;; org-ref/org-noter-style PDF reading flow.  It can also open that flow from an
;; org-cite key at point.

;;; Code:

(require 'auth-source)
(require 'bibtex)
(require 'cl-lib)
(require 'json)
(require 'pp)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'url-util)

(defgroup ookcite nil
  "OokCite citation and Ridley reading-note integration."
  :group 'tools
  :prefix "ookcite-")

(defcustom ookcite-base-url "https://ookcite-api.turtletech.us"
  "Base URL for the OokCite HTTP API origin.

The value is the origin only; endpoint paths include `/api/v1'."
  :type 'string
  :group 'ookcite)

(defcustom ookcite-api-key nil
  "OokCite API key.

When nil, `ookcite' checks `ookcite-api-key-env-var' and then
`auth-source'."
  :type '(choice (const :tag "Read from environment or auth-source" nil)
                 string)
  :group 'ookcite)

(defcustom ookcite-api-key-env-var "OOKCITE_API_KEY"
  "Environment variable containing an OokCite API key."
  :type 'string
  :group 'ookcite)

(defcustom ookcite-auth-source-host "ookcite-api.turtletech.us"
  "Host name used when reading an OokCite API key from `auth-source'."
  :type 'string
  :group 'ookcite)

(defcustom ookcite-request-timeout 30
  "Seconds to wait for synchronous OokCite requests."
  :type 'integer
  :group 'ookcite)

(defcustom ookcite-default-style "apa"
  "Default CSL style used by formatting commands."
  :type 'string
  :group 'ookcite)

(defcustom ookcite-default-locale "en-US"
  "Default CSL locale passed to OokCite formatting endpoints."
  :type 'string
  :group 'ookcite)

(defcustom ookcite-bibliography-files nil
  "BibTeX files managed by `ookcite'.

When nil, commands consult `org-cite-global-bibliography'."
  :type '(repeat file)
  :group 'ookcite)

(defcustom ookcite-add-to-bibliography-on-insert t
  "Non-nil means citation insertion commands append a BibTeX entry first."
  :type 'boolean
  :group 'ookcite)

(defcustom ookcite-use-live-queries nil
  "Non-nil means resolve commands ask OokCite to query live upstream sources."
  :type 'boolean
  :group 'ookcite)

(defcustom ookcite-use-citar t
  "Non-nil means use Citar caches and commands when Citar is loaded."
  :type 'boolean
  :group 'ookcite)

(defcustom ookcite-max-candidates 5
  "Maximum number of candidates requested from OokCite resolve."
  :type 'integer
  :group 'ookcite)

(defcustom ookcite-org-cite-prefix "cite"
  "Org citation prefix inserted by `ookcite-insert-org-cite'."
  :type 'string
  :group 'ookcite)

(defcustom ookcite-after-bibliography-update-hook nil
  "Hook run after `ookcite' updates a BibTeX file."
  :type 'hook
  :group 'ookcite)

(defcustom ookcite-ridley-notes-file nil
  "Org file used for Ridley reading notes.

When nil, `ookcite-ridley-read' prompts for a note file."
  :type '(choice (const :tag "Prompt for note file" nil)
                 file)
  :group 'ookcite)

(defcustom ookcite-ridley-item-json-files nil
  "Ridley JSON files searched by `ookcite-ridley-read'.

Each file can be a Ridley seed fixture with an `items' array, a raw item
array, or a single item object."
  :type '(repeat file)
  :group 'ookcite)

(defcustom ookcite-ridley-cache-items t
  "Non-nil means cache parsed Ridley item JSON until source mtimes change."
  :type 'boolean
  :group 'ookcite)

(defcustom ookcite-ridley-open-note-after-create t
  "Non-nil means Ridley reading commands call `org-noter' when available."
  :type 'boolean
  :group 'ookcite)

(defcustom ookcite-ridley-note-heading-todo "TODO"
  "Todo keyword used in Ridley reading-note headings."
  :type 'string
  :group 'ookcite)

(defcustom ookcite-ridley-note-tags '("reading" "ridley")
  "Tags added to Ridley reading-note headings."
  :type '(repeat string)
  :group 'ookcite)

(defcustom ookcite-ridley-org-noter-properties
  '(("NOTER_NOTES_BEHAVIOR" . "(start scroll)")
    ("NOTER_NOTES_LOCATION" . "horizontal-split")
    ("NOTER_DOCUMENT_SPLIT_FRACTION" . "(0.55 . 0.45)")
    ("NOTER_AUTO_SAVE_LAST_LOCATION" . "t"))
  "Org-noter session properties written to Ridley reading notes."
  :type '(alist :key-type string :value-type string)
  :group 'ookcite)

(defcustom ookcite-ridley-note-format-function
  #'ookcite-ridley-default-note-text
  "Function used to render Ridley org-noter note text.
The function receives ITEM, PDF-FILE, and citation KEY."
  :type 'function
  :group 'ookcite)

(define-error 'ookcite-error "OokCite error")
(define-error 'ookcite-http-error "OokCite HTTP error" 'ookcite-error)

(defconst ookcite--endpoints
  '((lookup-doi . ("POST" . "/api/v1/lookup/doi"))
    (lookup-isbn . ("POST" . "/api/v1/lookup/isbn"))
    (reverse . ("POST" . "/api/v1/reverse"))
    (resolve . ("POST" . "/api/v1/resolve"))
    (parse-citations . ("POST" . "/api/v1/parse-citations"))
    (resolve-debug . ("POST" . "/api/v1/resolve/debug"))
    (health . ("GET" . "/api/health"))
    (me . ("GET" . "/api/v1/me"))
    (format . ("POST" . "/api/v1/format"))
    (format-group-cite . ("POST" . "/api/v1/format/group-cite"))
    (styles-search . ("GET" . "/api/v1/styles/search"))
    (collections . ("GET" . "/api/v1/collections"))
    (collections-create . ("POST" . "/api/v1/collections"))
    (collection . ("GET" . "/api/v1/collections/{id}"))
    (collection-import . ("POST" . "/api/v1/collections/{id}/import"))
    (collection-export-bib . ("GET" . "/api/v1/collections/{id}/export.bib"))
    (collection-check-duplicates . ("POST" . "/api/v1/collections/{id}/check-duplicates"))
    (collection-share . ("POST" . "/api/v1/collections/{id}/share"))
    (collection-unshare . ("DELETE" . "/api/v1/collections/{id}/share"))))

(defconst ookcite--user-agent "ookcite.el/0.1")

(defvar ookcite-ridley--items-cache nil
  "Cached Ridley item records.")

(defvar ookcite-ridley--items-cache-signature nil
  "Source-file signature for `ookcite-ridley--items-cache'.")

(defun ookcite--nonempty-string-p (value)
  "Return non-nil when VALUE is a non-empty string."
  (and (stringp value)
       (not (string-empty-p (string-trim value)))))

(defun ookcite--trim-right-slash (value)
  "Return VALUE without trailing slashes."
  (replace-regexp-in-string "/+\\'" "" value))

(defun ookcite--endpoint (name)
  "Return endpoint pair for NAME."
  (or (alist-get name ookcite--endpoints)
      (signal 'ookcite-error (list (format "Unknown endpoint: %S" name)))))

(defun ookcite--endpoint-method (name)
  "Return HTTP method for endpoint NAME."
  (car (ookcite--endpoint name)))

(defun ookcite--endpoint-path (name)
  "Return path template for endpoint NAME."
  (cdr (ookcite--endpoint name)))

(defun ookcite--render-path (path params)
  "Render PATH by substituting PARAMS into `{name}' placeholders."
  (let ((rendered path))
    (dolist (param params)
      (let* ((name (format "%s" (car param)))
             (placeholder (format "{%s}" name))
             (value (url-hexify-string (format "%s" (cdr param)))))
        (unless (string-match-p (regexp-quote placeholder) rendered)
          (signal 'ookcite-error
                  (list (format "No placeholder named {%s} in %s"
                                name path))))
        (setq rendered
              (replace-regexp-in-string
               (regexp-quote placeholder) value rendered t t))))
    (when (string-match-p "{[^}]+}" rendered)
      (signal 'ookcite-error
              (list (format "Unfilled endpoint placeholder in %s" rendered))))
    rendered))

(defun ookcite--query-string (query)
  "Encode QUERY alist as a URL query string."
  (mapconcat
   (lambda (pair)
     (format "%s=%s"
             (url-hexify-string (format "%s" (car pair)))
             (url-hexify-string (format "%s" (cdr pair)))))
   (cl-remove-if-not (lambda (pair) (cdr pair)) query)
   "&"))

(defun ookcite--url (endpoint &optional params query)
  "Return URL for ENDPOINT with PARAMS and QUERY."
  (let* ((base (ookcite--trim-right-slash ookcite-base-url))
         (path (ookcite--render-path (ookcite--endpoint-path endpoint)
                                     params))
         (url (concat base path))
         (query-string (and query (ookcite--query-string query))))
    (if (and query-string (not (string-empty-p query-string)))
        (concat url "?" query-string)
      url)))

(defun ookcite--auth-source-secret ()
  "Return an OokCite API key from `auth-source', or nil."
  (let* ((match (car (auth-source-search
                      :host ookcite-auth-source-host
                      :user "apikey"
                      :require '(:secret)
                      :max 1)))
         (secret (plist-get match :secret)))
    (cond
     ((functionp secret) (funcall secret))
     ((stringp secret) secret)
     (t nil))))

(defun ookcite--api-key ()
  "Return the configured OokCite API key, or nil."
  (or (and (ookcite--nonempty-string-p ookcite-api-key)
           ookcite-api-key)
      (let ((env (getenv ookcite-api-key-env-var)))
        (and (ookcite--nonempty-string-p env) env))
      (ookcite--auth-source-secret)))

(defun ookcite--headers (&optional json-body)
  "Return request headers.

When JSON-BODY is non-nil, include a JSON content type."
  (let ((headers `(("Accept" . "application/json")
                   ("User-Agent" . ,ookcite--user-agent))))
    (when json-body
      (push '("Content-Type" . "application/json; charset=utf-8") headers))
    (let ((api-key (ookcite--api-key)))
      (when api-key
        (push (cons "Authorization" (concat "Bearer " api-key)) headers)))
    headers))

(defun ookcite--json-encode (data)
  "Encode DATA as UTF-8 JSON."
  (encode-coding-string (json-encode data) 'utf-8))

(defun ookcite--body-start ()
  "Return the response body start position in the current URL buffer."
  (or (and (boundp 'url-http-end-of-headers)
           (markerp url-http-end-of-headers)
           (marker-position url-http-end-of-headers))
      (save-excursion
        (goto-char (point-min))
        (when (re-search-forward "\r?\n\r?\n" nil t)
          (point)))))

(defun ookcite--parse-body (raw)
  "Parse the current response body.

When RAW is non-nil, return the body as text."
  (let* ((start (or (ookcite--body-start) (point-min)))
         (body (buffer-substring-no-properties start (point-max)))
         (trimmed (string-trim body)))
    (cond
     (raw body)
     ((string-empty-p trimmed) nil)
     (t (json-parse-string trimmed
                           :object-type 'alist
                           :array-type 'list
                           :null-object nil
                           :false-object :json-false)))))

(defun ookcite--get (object key)
  "Return KEY from OBJECT, accepting symbol and string alist keys."
  (when (listp object)
    (or (alist-get key object nil nil #'eq)
        (alist-get (if (symbolp key) (symbol-name key) key)
                   object nil nil #'string=))))

(defun ookcite--nested-get (object &rest keys)
  "Return nested KEYS from OBJECT."
  (let ((value object))
    (dolist (key keys)
      (setq value (ookcite--get value key)))
    value))

(defun ookcite--error-message (status body)
  "Return a compact error message from STATUS and BODY."
  (let* ((parsed (ignore-errors
                   (json-parse-string body
                                      :object-type 'alist
                                      :array-type 'list
                                      :null-object nil
                                      :false-object :json-false)))
         (message (or (and parsed (ookcite--get parsed 'error))
                      (and parsed (ookcite--get parsed 'message))
                      (string-trim body))))
    (format "HTTP %s%s"
            (or status "?")
            (if (ookcite--nonempty-string-p message)
                (concat ": " message)
              ""))))

(defun ookcite--read-response (&optional raw)
  "Read the current URL buffer response.

When RAW is non-nil, return the body as text."
  (let* ((status (and (boundp 'url-http-response-status)
                      url-http-response-status))
         (body-start (or (ookcite--body-start) (point-min)))
         (body (buffer-substring-no-properties body-start (point-max))))
    (unless (or (null status) (and (>= status 200) (< status 300)))
      (signal 'ookcite-http-error
              (list (ookcite--error-message status body) status body)))
    (ookcite--parse-body raw)))

(defun ookcite-request (endpoint &optional data method query params raw)
  "Synchronously call OokCite ENDPOINT.

DATA is JSON-encoded when non-nil.  METHOD, QUERY, PARAMS, and RAW
override the endpoint defaults."
  (let* ((url-request-method (or method (ookcite--endpoint-method endpoint)))
         (url-request-data (and data (ookcite--json-encode data)))
         (url-request-extra-headers (ookcite--headers data))
         (url (ookcite--url endpoint params query))
         (buffer (url-retrieve-synchronously
                  url t t ookcite-request-timeout)))
    (unless buffer
      (signal 'ookcite-error (list (format "No response from %s" url))))
    (unwind-protect
        (with-current-buffer buffer
          (ookcite--read-response raw))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun ookcite-request-async (endpoint data callback
                                       &optional method query params raw)
  "Asynchronously call OokCite ENDPOINT and invoke CALLBACK.

CALLBACK receives two arguments: ERROR and RESULT.  ERROR is nil on
success.  DATA, METHOD, QUERY, PARAMS, and RAW behave as in
`ookcite-request'."
  (let* ((url-request-method (or method (ookcite--endpoint-method endpoint)))
         (url-request-data (and data (ookcite--json-encode data)))
         (url-request-extra-headers (ookcite--headers data))
         (url (ookcite--url endpoint params query)))
    (url-retrieve
     url #'ookcite--request-async-callback
     (list callback raw) t t)))

(defun ookcite--request-async-callback (status callback raw)
  "Parse async request STATUS and pass the result to CALLBACK.

RAW is forwarded to `ookcite--read-response'."
  (unwind-protect
      (if-let ((error (plist-get status :error)))
          (funcall callback (format "%s" error) nil)
        (condition-case err
            (funcall callback nil (ookcite--read-response raw))
          (error (funcall callback (error-message-string err) nil))))
    (when (buffer-live-p (current-buffer))
      (kill-buffer (current-buffer)))))

(defun ookcite--entry-authors (entry)
  "Return authors from ENTRY."
  (or (ookcite--get entry 'authors)
      (ookcite--get entry 'author)
      (ookcite--get entry 'creators)))

(defun ookcite--entry-title (entry)
  "Return title from ENTRY."
  (or (ookcite--get entry 'title)
      (ookcite--nested-get entry 'fields 'title)
      "Untitled"))

(defun ookcite--entry-doi (entry)
  "Return DOI from ENTRY."
  (or (ookcite--get entry 'doi)
      (ookcite--get entry 'DOI)
      (ookcite--nested-get entry 'fields 'DOI)))

(defun ookcite--entry-year (entry)
  "Return publication year from ENTRY as a string, or nil."
  (let ((year (or (ookcite--nested-get entry 'date 'year)
                  (ookcite--get entry 'year)
                  (ookcite--get entry 'date)
                  (caar (ookcite--nested-get entry 'issued 'date-parts))
                  (ookcite--nested-get entry 'fields 'date))))
    (cond
     ((numberp year) (number-to-string year))
     ((and (stringp year)
           (string-match "\\b\\([12][0-9][0-9][0-9]\\)\\b" year))
      (match-string 1 year))
     ((stringp year) year)
     (t nil))))

(defun ookcite--person-family (person)
  "Return PERSON family name or literal name."
  (if (stringp person)
      person
    (or (ookcite--get person 'family)
        (ookcite--get person 'lastName)
        (ookcite--get person 'last)
        (ookcite--get person 'literal)
        (ookcite--get person 'name))))

(defun ookcite--person-bibtex (person)
  "Return BibTeX name for PERSON."
  (if (stringp person)
      person
    (let ((literal (ookcite--get person 'literal))
          (family (or (ookcite--get person 'family)
                      (ookcite--get person 'lastName)
                      (ookcite--get person 'last)))
          (given (or (ookcite--get person 'given)
                     (ookcite--get person 'firstName)
                     (ookcite--get person 'first))))
      (cond
       ((ookcite--nonempty-string-p literal) literal)
       ((and family given) (format "%s, %s" family given))
       (family family)
       (given given)
       (t "Anonymous")))))

(defun ookcite-entry-authors-string (entry)
  "Return ENTRY authors formatted for display."
  (let ((authors (ookcite--entry-authors entry)))
    (cond
     ((stringp authors) authors)
     ((listp authors) (mapconcat #'ookcite--person-bibtex authors ", "))
     (t nil))))

(defun ookcite--ascii-slug (value)
  "Return an ASCII citation-key slug from VALUE."
  (downcase
   (apply #'string
          (cl-loop for char across (format "%s" value)
                   when (or (and (>= char ?a) (<= char ?z))
                            (and (>= char ?A) (<= char ?Z))
                            (and (>= char ?0) (<= char ?9)))
                   collect char))))

(defun ookcite-entry-citation-key (entry)
  "Return a stable citation key for ENTRY."
  (let* ((first-author (car (ookcite--entry-authors entry)))
         (family (and first-author (ookcite--person-family first-author)))
         (year (ookcite--entry-year entry))
         (doi (ookcite--entry-doi entry))
         (base (cond
                ((or family year)
                 (concat (ookcite--ascii-slug (or family "item"))
                         (or year "")))
                (doi
                 (ookcite--ascii-slug
                  (car (last (split-string doi "/")))))
                (t
                 (ookcite--ascii-slug (ookcite--entry-title entry))))))
    (if (string-empty-p base) "item" base)))

(defun ookcite--entry-summary (entry)
  "Return one-line display summary for ENTRY."
  (let ((title (ookcite--entry-title entry))
        (author-list (ookcite-entry-authors-string entry))
        (year (ookcite--entry-year entry))
        (doi (ookcite--entry-doi entry)))
    (string-join
     (cl-remove-if-not
      #'ookcite--nonempty-string-p
      (list title
            (and author-list (format "[%s]" author-list))
            year
            doi))
     " | ")))

(defun ookcite--resolve-payload (query &optional filters use-live max-candidates)
  "Return OokCite resolve payload for QUERY.

FILTERS is an alist containing optional author, journal, year, affiliation,
orcid, or similar resolver filters.  USE-LIVE toggles live upstream
queries.  MAX-CANDIDATES controls the resolver candidate count."
  `((input . ((kind . "text") (text . ,query)))
    (filters . ,(or filters '()))
    (options . ((max_candidates . ,(or max-candidates ookcite-max-candidates))
                (prefer_exact_identifier . t)
                (use_live_queries . ,(if use-live t :json-false))))))

(defun ookcite--candidate-metadata-list (response)
  "Return candidate metadata entries from resolve RESPONSE."
  (cond
   ((ookcite--get response 'paper)
    (list (ookcite--get response 'paper)))
   ((ookcite--get response 'candidates)
    (delq nil
          (mapcar (lambda (candidate)
                    (or (ookcite--get candidate 'metadata) candidate))
                  (ookcite--get response 'candidates))))
   ((and (listp response) (ookcite--get (car response) 'metadata))
    (delq nil
          (mapcar (lambda (candidate)
                    (ookcite--get candidate 'metadata))
                  response)))
   ((and (listp response) (ookcite--get (car response) 'title))
    response)
   (t nil)))

(defun ookcite--read-entry (entries)
  "Prompt for a citation entry from ENTRIES when needed."
  (pcase entries
    (`nil (signal 'ookcite-error (list "No citation candidates found")))
    (`(,single) single)
    (_
     (let* ((choices
             (cl-loop for entry in entries
                      for index from 1
                      collect (cons (format "%d. %s"
                                            index
                                            (ookcite--entry-summary entry))
                                    entry)))
            (choice (completing-read "Citation: " choices nil t)))
       (cdr (assoc choice choices))))))

(defun ookcite-lookup-doi-sync (doi)
  "Synchronously look up DOI metadata using OokCite."
  (ookcite-request 'lookup-doi `((doi . ,doi))))

(defun ookcite-lookup-isbn-sync (isbn)
  "Synchronously look up ISBN metadata using OokCite."
  (ookcite-request 'lookup-isbn `((isbn . ,isbn))))

(defun ookcite-resolve-sync (query &optional filters use-live)
  "Synchronously resolve QUERY using OokCite.

FILTERS and USE-LIVE are forwarded to `ookcite--resolve-payload'."
  (ookcite-request
   'resolve
   (ookcite--resolve-payload
    query filters (or use-live ookcite-use-live-queries))))

(defun ookcite-resolve-async (query callback &optional filters use-live)
  "Asynchronously resolve QUERY and invoke CALLBACK with ERROR and ENTRIES.

FILTERS and USE-LIVE are forwarded to `ookcite--resolve-payload'."
  (ookcite-request-async
   'resolve
   (ookcite--resolve-payload
    query filters (or use-live ookcite-use-live-queries))
   (lambda (error result)
     (funcall callback error
              (and result (ookcite--candidate-metadata-list result))))))

(defun ookcite-format-entries-sync (entries style)
  "Synchronously format ENTRIES with CSL STYLE."
  (ookcite-request
   'format
   `((entries . ,(vconcat entries))
     (style . ,style)
     (locale . ,ookcite-default-locale))))

(defun ookcite--display (buffer-name value)
  "Display VALUE in BUFFER-NAME."
  (with-help-window buffer-name
    (with-current-buffer buffer-name
      (if (stringp value)
          (insert value)
        (pp value (current-buffer))))))

;;;###autoload
(defun ookcite-lookup-doi (doi)
  "Look up DOI metadata with OokCite and display the response."
  (interactive "sDOI: ")
  (ookcite-request-async
   'lookup-doi `((doi . ,doi))
   (lambda (error result)
     (if error
         (user-error "%s" error)
       (ookcite--display "*ookcite lookup*" result)))))

;;;###autoload
(defun ookcite-lookup-isbn (isbn)
  "Look up ISBN metadata with OokCite and display the response."
  (interactive "sISBN: ")
  (ookcite-request-async
   'lookup-isbn `((isbn . ,isbn))
   (lambda (error result)
     (if error
         (user-error "%s" error)
       (ookcite--display "*ookcite lookup*" result)))))

;;;###autoload
(defun ookcite-resolve (query)
  "Resolve QUERY through OokCite and display the selected candidate."
  (interactive "sCitation, DOI, ISBN, or title: ")
  (ookcite-resolve-async
   query
   (lambda (error entries)
     (if error
         (user-error "%s" error)
       (ookcite--display "*ookcite resolve*"
                         (ookcite--read-entry entries))))))

;;;###autoload
(defun ookcite-format-doi (doi style)
  "Format DOI with CSL STYLE and display the formatted reference."
  (interactive
   (list (read-string "DOI: ")
         (read-string "CSL style: " ookcite-default-style)))
  (ookcite-request-async
   'lookup-doi `((doi . ,doi))
   (lambda (lookup-error entry)
     (if lookup-error
         (user-error "%s" lookup-error)
       (ookcite-request-async
        'format
        `((entries . ,(vector entry))
          (style . ,style)
          (locale . ,ookcite-default-locale))
        (lambda (format-error result)
          (if format-error
              (user-error "%s" format-error)
            (ookcite--display
             "*ookcite formatted*"
             (or (ookcite--get result 'plain) result)))))))))

;;;###autoload
(defun ookcite-search-styles (query)
  "Search OokCite CSL styles using QUERY."
  (interactive "sStyle search: ")
  (ookcite-request-async
   'styles-search nil
   (lambda (error result)
     (if error
         (user-error "%s" error)
       (ookcite--display "*ookcite styles*" result)))
   "GET" `((q . ,query))))

;;;###autoload
(defun ookcite-parse-region (beg end)
  "Parse citations in the region from BEG to END using OokCite."
  (interactive "r")
  (unless (use-region-p)
    (user-error "Select a bibliography region first"))
  (let ((text (buffer-substring-no-properties beg end)))
    (ookcite-request-async
     'parse-citations `((text . ,text))
     (lambda (error result)
       (if error
           (user-error "%s" error)
         (ookcite--display "*ookcite parsed citations*" result))))))

(defun ookcite--org-bibliography-files ()
  "Return Org citation bibliography files, when available."
  (when (and (boundp 'org-cite-global-bibliography)
             (listp (symbol-value 'org-cite-global-bibliography)))
    (symbol-value 'org-cite-global-bibliography)))

(defun ookcite--default-bibliography-file ()
  "Return the first configured bibliography file that exists."
  (or (car (cl-remove-if-not #'file-exists-p ookcite-bibliography-files))
      (car (cl-remove-if-not #'file-exists-p
                             (ookcite--org-bibliography-files)))))

(defun ookcite-read-bibliography-file ()
  "Read a BibTeX path, defaulting to configured citation files."
  (let ((default (ookcite--default-bibliography-file)))
    (read-file-name "BibTeX file: "
                    (and default (file-name-directory default))
                    default nil
                    (and default (file-name-nondirectory default)))))

(defun ookcite--bibtex-escape (value)
  "Escape VALUE for a brace-delimited BibTeX field."
  (let ((text (replace-regexp-in-string
               "[\n\r\t]+" " " (format "%s" value))))
    (setq text (replace-regexp-in-string "{" (lambda (_) "\\{") text t t))
    (replace-regexp-in-string "}" (lambda (_) "\\}") text t t)))

(defun ookcite--bibtex-kind (entry)
  "Return BibTeX entry kind for ENTRY."
  (let ((kind (downcase
               (or (ookcite--get entry 'entry_type)
                   (ookcite--get entry 'type)
                   (ookcite--get entry 'itemType)
                   ""))))
    (cond
     ((member kind '("article" "article-journal" "journalarticle")) "article")
     ((member kind '("book")) "book")
     ((member kind '("chapter" "booksection")) "incollection")
     ((member kind '("paper-conference" "conferencepaper")) "inproceedings")
     ((member kind '("thesis" "phdthesis")) "phdthesis")
     ((member kind '("report" "techreport")) "techreport")
     (t "misc"))))

(defun ookcite--entry-field (entry &rest keys)
  "Return the first non-empty field from ENTRY matching KEYS."
  (cl-loop for key in keys
           for value = (ookcite--get entry key)
           when (ookcite--nonempty-string-p value)
           return value))

(defun ookcite-entry-bibtex (entry &optional key pdf-file)
  "Return a BibTeX representation of ENTRY.

KEY overrides the synthesized citation key.  PDF-FILE writes a `file'
field compatible with org-ref and bibtex-completion."
  (let* ((cite-key (or key (ookcite-entry-citation-key entry)))
         (lines (list (format "@%s{%s,"
                              (ookcite--bibtex-kind entry) cite-key)))
         (author-list (ookcite--entry-authors entry))
         (year (ookcite--entry-year entry)))
    (cl-labels ((push-field
                 (name value)
                 (when (ookcite--nonempty-string-p value)
                   (push (format "  %s = {%s},"
                                 name (ookcite--bibtex-escape value))
                         lines))))
      (push-field "title" (ookcite--entry-title entry))
      (when author-list
        (push-field "author"
                    (mapconcat #'ookcite--person-bibtex author-list " and ")))
      (push-field "year" year)
      (push-field "journal"
                  (ookcite--entry-field entry 'journal 'container-title
                                        'publicationTitle))
      (push-field "booktitle" (ookcite--get entry 'proceedingsTitle))
      (push-field "volume" (ookcite--get entry 'volume))
      (push-field "number" (ookcite--get entry 'issue))
      (push-field "pages" (ookcite--get entry 'pages))
      (push-field "publisher" (ookcite--get entry 'publisher))
      (push-field "doi" (ookcite--entry-doi entry))
      (push-field "isbn" (or (ookcite--get entry 'isbn)
                             (ookcite--get entry 'ISBN)))
      (push-field "url" (ookcite--get entry 'url))
      (push-field "file" pdf-file))
    (push "}" lines)
    (concat (mapconcat #'identity (nreverse lines) "\n") "\n\n")))

(defun ookcite--bibtex-key-exists-p (file key)
  "Return non-nil when FILE already has BibTeX KEY."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (re-search-forward
       (format "@[[:alnum:]]+[{(][[:space:]\n]*%s[[:space:]\n]*,"
               (regexp-quote key))
       nil t))))

(defun ookcite-bibliography-file-list ()
  "Return configured bibliography files for lookup."
  (delete-dups
   (cl-remove-if-not
    #'ookcite--nonempty-string-p
    (append (when (and ookcite-use-citar
                       (boundp 'citar-bibliography))
              (let ((bibliography (symbol-value 'citar-bibliography)))
                (if (listp bibliography)
                    bibliography
                  (list bibliography))))
            ookcite-bibliography-files
            (ookcite--org-bibliography-files)))))

(defun ookcite-citar-entry-by-key (key)
  "Return Citar's cached entry for KEY when Citar is available."
  (when (and ookcite-use-citar
             (fboundp 'citar-get-entry))
    (funcall 'citar-get-entry key)))

(defun ookcite-citar-pdf-file-by-key (key)
  "Return the first Citar PDF file associated with KEY, or nil."
  (when (and ookcite-use-citar
             (fboundp 'citar-get-files))
    (let* ((files-by-key (funcall 'citar-get-files key))
           (files (and (hash-table-p files-by-key)
                       (gethash key files-by-key))))
      (cl-find-if
       (lambda (file)
         (and (ookcite--nonempty-string-p file)
              (string-match-p "\\.pdf\\'" file)))
       files))))

(defun ookcite-bibtex-entry-by-key (key &optional files)
  "Return the BibTeX entry matching KEY from FILES.

When FILES is nil, use `ookcite-bibliography-file-list'."
  (or (ookcite-citar-entry-by-key key)
      (catch 'entry
        (dolist (file (or files (ookcite-bibliography-file-list)))
          (when (file-readable-p file)
            (with-temp-buffer
              (insert-file-contents file)
              (bibtex-mode)
              (goto-char (point-min))
              (when (bibtex-search-entry key nil)
                (throw 'entry (bibtex-parse-entry t))))))
        nil)))

(defun ookcite-bibtex-pdf-file (entry)
  "Return the first PDF path in BibTeX ENTRY's `file' field."
  (when-let ((file-field (ookcite--get entry 'file)))
    (let ((parts (split-string file-field "[;\n]" t "[[:space:]]+"))
          pdf-file)
      (while (and parts (not pdf-file))
        (let ((part (pop parts)))
          (when (string-match
                 "\\(?:\\`\\|:\\)\\([^:;]+\\.pdf\\)\\(?:[:;]\\|\\'\\)"
                 part)
            (setq pdf-file
                  (expand-file-name
                   (substitute-in-file-name
                    (match-string 1 part)))))))
      pdf-file)))

(defun ookcite-add-entry-to-bibliography (entry &optional file pdf-file)
  "Append ENTRY to BibTeX FILE and return its citation key.

When FILE is nil, prompt for a bibliography path.  PDF-FILE is written
into the BibTeX `file' field when non-nil."
  (let* ((bib-file (or file (ookcite-read-bibliography-file)))
         (key (ookcite-entry-citation-key entry)))
    (make-directory (file-name-directory bib-file) t)
    (unless (ookcite--bibtex-key-exists-p bib-file key)
      (with-temp-buffer
        (when (file-exists-p bib-file)
          (insert-file-contents bib-file)
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (unless (or (bobp)
                      (save-excursion
                        (forward-line -1)
                        (looking-at-p "[[:space:]]*$")))
            (insert "\n")))
        (insert (ookcite-entry-bibtex entry key pdf-file))
        (write-region (point-min) (point-max) bib-file nil 'silent)))
    (run-hooks 'ookcite-after-bibliography-update-hook)
    (ookcite--refresh-citation-frontends)
    key))

(defun ookcite--refresh-citation-frontends ()
  "Refresh known citation frontends after a BibTeX update."
  (when (fboundp 'citar-refresh)
    (funcall 'citar-refresh))
  (when (fboundp 'bibtex-completion-clear-cache)
    (funcall 'bibtex-completion-clear-cache)))

(defun ookcite--insert-org-citation-key (key)
  "Insert org-cite KEY at point."
  (insert (format "%s:@%s" ookcite-org-cite-prefix key)))

(defun ookcite-citation-key-at-point ()
  "Return an org-cite or BibTeX citation key at point, or nil."
  (or (and ookcite-use-citar
           (fboundp 'citar-key-at-point)
           (funcall 'citar-key-at-point))
      (and ookcite-use-citar
           (fboundp 'citar-citation-at-point)
           (car (funcall 'citar-citation-at-point)))
      (let ((position (point))
            key)
        (save-excursion
          (goto-char (line-beginning-position))
          (while (and (not key)
                      (re-search-forward
                       "@\\([[:alnum:]_:+.-]+\\)"
                       (line-end-position) t))
            (when (and (>= position (match-beginning 0))
                       (<= position (match-end 1)))
              (setq key (match-string-no-properties 1)))))
        key)))

;;;###autoload
(defun ookcite-add-doi-to-bib (doi &optional bib-file pdf-file)
  "Look up DOI and add it to BIB-FILE.

PDF-FILE is written into the BibTeX `file' field when provided."
  (interactive
   (list (read-string "DOI: ")
         (ookcite-read-bibliography-file)
         (let ((file (read-file-name "PDF file, empty for none: " nil nil nil)))
           (and (ookcite--nonempty-string-p file) file))))
  (let* ((entry (ookcite-lookup-doi-sync doi))
         (key (ookcite-add-entry-to-bibliography entry bib-file pdf-file)))
    (message "Added %s" key)
    key))

;;;###autoload
(defun ookcite-add-citation-to-bib (query &optional bib-file pdf-file)
  "Resolve QUERY and add the selected result to BIB-FILE.

PDF-FILE is written into the BibTeX `file' field when provided."
  (interactive
   (list (read-string "Citation, DOI, ISBN, or title: ")
         (ookcite-read-bibliography-file)
         (let ((file (read-file-name "PDF file, empty for none: " nil nil nil)))
           (and (ookcite--nonempty-string-p file) file))))
  (let* ((entries (ookcite--candidate-metadata-list
                   (ookcite-resolve-sync query)))
         (entry (ookcite--read-entry entries))
         (key (ookcite-add-entry-to-bibliography entry bib-file pdf-file)))
    (message "Added %s" key)
    key))

;;;###autoload
(defun ookcite-insert-org-cite (query)
  "Resolve QUERY, optionally append BibTeX, and insert an org-cite key."
  (interactive "sCitation, DOI, ISBN, or title: ")
  (let ((buffer (current-buffer))
        (marker (point-marker)))
    (ookcite-resolve-async
     query
     (lambda (error entries)
       (unwind-protect
           (if error
               (user-error "%s" error)
             (let* ((entry (ookcite--read-entry entries))
                    (key (if ookcite-add-to-bibliography-on-insert
                             (ookcite-add-entry-to-bibliography entry)
                           (ookcite-entry-citation-key entry))))
               (unless (buffer-live-p buffer)
                 (user-error "Original buffer is gone"))
               (with-current-buffer buffer
                 (save-excursion
                   (goto-char marker)
                   (ookcite--insert-org-citation-key key)))
               (message "Inserted citation %s" key)))
         (set-marker marker nil))))))

;;;###autoload
(defun ookcite-insert-org-cite-from-doi (doi)
  "Look up DOI, optionally append BibTeX, and insert an org-cite key."
  (interactive "sDOI: ")
  (ookcite-insert-org-cite doi))

(defun ookcite--collection-display (collection)
  "Return display string for COLLECTION."
  (format "%s%s"
          (or (ookcite--get collection 'name)
              (ookcite--get collection 'id)
              "collection")
          (if-let ((id (ookcite--get collection 'id)))
              (format " [%s]" id)
            "")))

(defun ookcite--read-collection-id (&optional create)
  "Read an OokCite collection id.

When CREATE is non-nil, create a collection when the entered name does
not match an existing collection."
  (let* ((collections (ookcite-request 'collections))
         (choices (mapcar (lambda (collection)
                            (cons (ookcite--collection-display collection)
                                  collection))
                          collections))
         (input (completing-read "Collection: " choices nil nil)))
    (if-let ((collection (cdr (assoc input choices))))
        (ookcite--get collection 'id)
      (if create
          (ookcite--get
           (ookcite-request
            'collections-create
            `((name . ,input)
              (default_style . ,ookcite-default-style)))
           'id)
        input))))

;;;###autoload
(defun ookcite-list-collections ()
  "Display OokCite collections visible to the configured API key."
  (interactive)
  (ookcite--display "*ookcite collections*" (ookcite-request 'collections)))

;;;###autoload
(defun ookcite-import-bibliography-file (file collection-id format)
  "Import bibliography FILE into OokCite COLLECTION-ID as FORMAT.

FORMAT is usually `bibtex' or `ris'."
  (interactive
   (list (read-file-name "Bibliography file: "
                         nil (ookcite--default-bibliography-file) t)
         (ookcite--read-collection-id t)
         (completing-read "Format: " '("bibtex" "ris") nil t nil nil "bibtex")))
  (ookcite--display
   "*ookcite import*"
   (ookcite-request
    'collection-import
    `((content . ,(with-temp-buffer
                    (insert-file-contents file)
                    (buffer-string)))
      (format . ,format))
    "POST" nil `((id . ,collection-id)))))

;;;###autoload
(defun ookcite-add-entry-to-collection (entry collection-id
                                              &optional key pdf-file)
  "Import ENTRY into OokCite COLLECTION-ID as a single BibTeX record.

KEY overrides the generated citation key.  PDF-FILE is written to the
BibTeX `file' field when non-nil."
  (ookcite-request
   'collection-import
   `((content . ,(ookcite-entry-bibtex entry key pdf-file))
     (format . "bibtex"))
   "POST" nil `((id . ,collection-id))))

;;;###autoload
(defun ookcite-add-entry-to-collection-async (entry collection-id callback
                                                    &optional key pdf-file)
  "Asynchronously import ENTRY into OokCite COLLECTION-ID.

CALLBACK receives ERROR and RESULT.  KEY and PDF-FILE behave as in
`ookcite-add-entry-to-collection'."
  (ookcite-request-async
   'collection-import
   `((content . ,(ookcite-entry-bibtex entry key pdf-file))
     (format . "bibtex"))
   callback
   "POST" nil `((id . ,collection-id))))

;;;###autoload
(defun ookcite-add-doi-to-collection-async (doi collection-id callback
                                                &optional pdf-file)
  "Asynchronously look up DOI and import it into COLLECTION-ID.

CALLBACK receives ERROR and RESULT.  PDF-FILE is written to the generated
BibTeX `file' field when non-nil."
  (ookcite-request-async
   'lookup-doi `((doi . ,doi))
   (lambda (error entry)
     (if error
         (funcall callback error nil)
       (ookcite-add-entry-to-collection-async
        entry collection-id callback nil pdf-file)))))

;;;###autoload
(defun ookcite-add-citation-to-collection-async (query collection-id callback
                                                       &optional pdf-file)
  "Asynchronously resolve QUERY and import it into COLLECTION-ID.

CALLBACK receives ERROR and RESULT.  PDF-FILE is written to the generated
BibTeX `file' field when non-nil."
  (ookcite-resolve-async
   query
   (lambda (error entries)
     (if error
         (funcall callback error nil)
       (let ((entry (ookcite--read-entry entries)))
         (ookcite-add-entry-to-collection-async
          entry collection-id callback nil pdf-file))))))

;;;###autoload
(defun ookcite-add-doi-to-collection (doi collection-id &optional pdf-file)
  "Look up DOI and import it into OokCite COLLECTION-ID.

PDF-FILE is written to the generated BibTeX `file' field when non-nil."
  (interactive
   (list (read-string "DOI: ")
         (ookcite--read-collection-id t)
         (let ((file (read-file-name "PDF file, empty for none: " nil nil nil)))
           (and (ookcite--nonempty-string-p file) file))))
  (if (called-interactively-p 'interactive)
      (ookcite-add-doi-to-collection-async
       doi collection-id
       (lambda (error _result)
         (if error
             (user-error "%s" error)
           (message "Imported DOI into %s" collection-id)))
       pdf-file)
    (ookcite-add-entry-to-collection
     (ookcite-lookup-doi-sync doi) collection-id nil pdf-file)))

;;;###autoload
(defun ookcite-add-citation-to-collection (query collection-id
                                                 &optional pdf-file)
  "Resolve QUERY and import the selected result into COLLECTION-ID.

PDF-FILE is written to the generated BibTeX `file' field when non-nil."
  (interactive
   (list (read-string "Citation, DOI, ISBN, or title: ")
         (ookcite--read-collection-id t)
         (let ((file (read-file-name "PDF file, empty for none: " nil nil nil)))
           (and (ookcite--nonempty-string-p file) file))))
  (if (called-interactively-p 'interactive)
      (ookcite-add-citation-to-collection-async
       query collection-id
       (lambda (error _result)
         (if error
             (user-error "%s" error)
           (message "Imported citation into %s" collection-id)))
       pdf-file)
    (let* ((entries (ookcite--candidate-metadata-list
                     (ookcite-resolve-sync query)))
           (entry (ookcite--read-entry entries)))
      (ookcite-add-entry-to-collection entry collection-id nil pdf-file))))

;;;###autoload
(defun ookcite-export-collection-bibtex (collection-id file)
  "Export OokCite COLLECTION-ID as BibTeX to FILE."
  (interactive
   (let ((collection-id (ookcite--read-collection-id)))
     (list collection-id
           (read-file-name "Write BibTeX to: " nil nil nil
                           (format "%s.bib" collection-id)))))
  (let ((body (ookcite-request
               'collection-export-bib nil "GET" nil
               `((id . ,collection-id)) t)))
    (with-temp-buffer
      (insert body)
      (write-region (point-min) (point-max) file nil 'silent))
    (message "Wrote %s" file)))

;;;###autoload
(defun ookcite-check-collection-duplicates (collection-id query)
  "Check whether QUERY duplicates entries in COLLECTION-ID."
  (interactive
   (list (ookcite--read-collection-id)
         (read-string "DOI or citation query: ")))
  (ookcite--display
   "*ookcite duplicates*"
   (ookcite-request
    'collection-check-duplicates
    `((query . ,query)
      (use_live_queries . ,(if ookcite-use-live-queries t :json-false)))
    "POST" nil `((id . ,collection-id)))))

;;;###autoload
(defun ookcite-share-collection (collection-id)
  "Create or display an OokCite sharing token for COLLECTION-ID."
  (interactive (list (ookcite--read-collection-id)))
  (ookcite--display
   "*ookcite share*"
   (ookcite-request 'collection-share nil "POST" nil
                    `((id . ,collection-id)))))

(defun ookcite-ridley--json-file (file)
  "Read FILE as JSON and return alists/lists."
  (with-temp-buffer
    (insert-file-contents file)
    (json-parse-buffer
     :object-type 'alist
     :array-type 'list
     :null-object nil
     :false-object :json-false)))

(defun ookcite-ridley--bundle-metadata-file (bundle name)
  "Return metadata NAME path from directory BUNDLE."
  (expand-file-name name (expand-file-name "metadata" bundle)))

(defun ookcite-ridley--manifest-files (manifest)
  "Return file records from bundle MANIFEST."
  (or (ookcite--get manifest 'files)
      (ookcite--get manifest 'assets)))

(defun ookcite-ridley--manifest-primary-pdf (manifest)
  "Return primary PDF path from bundle MANIFEST."
  (cl-loop for file in (ookcite-ridley--manifest-files manifest)
           for path = (or (ookcite--get file 'path)
                          (ookcite--get file 'package_path)
                          (ookcite--get file 'packagePath))
           for content-type = (or (ookcite--get file 'content_type)
                                  (ookcite--get file 'contentType))
           when (and path
                     (or (string-match-p "\\.pdf\\'" path)
                         (equal content-type "application/pdf")))
           return path))

(defun ookcite-ridley--directory-bundle-item (bundle)
  "Return a Ridley item from directory BUNDLE."
  (let ((item-file (ookcite-ridley--bundle-metadata-file bundle "item.json"))
        (manifest-file (ookcite-ridley--bundle-metadata-file bundle
                                                            "manifest.json")))
    (when (file-readable-p item-file)
      (let* ((item (ookcite-ridley--json-file item-file))
             (manifest (and (file-readable-p manifest-file)
                            (ookcite-ridley--json-file manifest-file)))
             (pdf-path (and manifest
                            (ookcite-ridley--manifest-primary-pdf manifest))))
        (append item
                `((ookcite_bundle_path . ,bundle)
                  ,@(when pdf-path
                      `((ookcite_bundle_pdf_file
                         . ,(expand-file-name pdf-path bundle))))))))))

(defun ookcite-ridley--item-list (value)
  "Return a flat item list from Ridley JSON VALUE."
  (cond
   ((and (listp value) (ookcite--get value 'items))
    (ookcite--get value 'items))
   ((and (listp value) (ookcite--get (car value) 'title))
    value)
   ((and (listp value)
         (or (ookcite--get value 'title)
             (ookcite--get value 'fields)))
    (list value))
   (t nil)))

(defun ookcite-ridley-read-items-from-file (file)
  "Return Ridley item records from FILE."
  (if (file-directory-p file)
      (when-let ((item (ookcite-ridley--directory-bundle-item file)))
        (list item))
    (ookcite-ridley--item-list (ookcite-ridley--json-file file))))

(defun ookcite-ridley--source-files ()
  "Return configured Ridley source files that exist."
  (cl-remove-if-not #'file-exists-p ookcite-ridley-item-json-files))

(defun ookcite-ridley--source-signature ()
  "Return cache signature for configured Ridley source files."
  (mapcar
   (lambda (file)
     (list file (file-attribute-modification-time (file-attributes file))))
   (ookcite-ridley--source-files)))

;;;###autoload
(defun ookcite-ridley-clear-cache ()
  "Clear cached Ridley item records."
  (interactive)
  (setq ookcite-ridley--items-cache nil
        ookcite-ridley--items-cache-signature nil))

(defun ookcite-ridley-all-items ()
  "Return all Ridley items from `ookcite-ridley-item-json-files'."
  (let ((signature (ookcite-ridley--source-signature)))
    (if (and ookcite-ridley-cache-items
             ookcite-ridley--items-cache
             (equal signature ookcite-ridley--items-cache-signature))
        ookcite-ridley--items-cache
      (let ((items (apply #'append
                          (mapcar #'ookcite-ridley-read-items-from-file
                                  (ookcite-ridley--source-files)))))
        (when ookcite-ridley-cache-items
          (setq ookcite-ridley--items-cache items
                ookcite-ridley--items-cache-signature signature))
        items))))

(defun ookcite-ridley--item-id (item)
  "Return Ridley ITEM id when present."
  (or (ookcite--get item 'item_id)
      (ookcite--get item 'itemId)
      (ookcite--get item 'id)))

(defun ookcite-ridley--asset-id (asset)
  "Return Ridley ASSET id when present."
  (or (ookcite--get asset 'asset_id)
      (ookcite--get asset 'assetId)
      (ookcite--get asset 'id)))

(defun ookcite-ridley--field (item key)
  "Return Ridley ITEM field KEY from flat or v2 item shapes."
  (or (ookcite--get item key)
      (ookcite--nested-get item 'fields key)))

(defun ookcite-ridley--creator-family (creator)
  "Return last name from Ridley CREATOR."
  (or (ookcite--get creator 'lastName)
      (ookcite--get creator 'last)
      (ookcite--get creator 'name)
      (ookcite--get creator 'family)))

(defun ookcite-ridley--authors-string (item)
  "Return author string for Ridley ITEM."
  (let ((creators (or (ookcite--get item 'creators)
                      (ookcite--get item 'authors)
                      (ookcite--get item 'author))))
    (cond
     ((stringp creators) creators)
     ((listp creators)
      (mapconcat
       (lambda (creator)
         (if (stringp creator)
             creator
           (let ((first (or (ookcite--get creator 'firstName)
                            (ookcite--get creator 'first)
                            (ookcite--get creator 'given)))
                 (last (ookcite-ridley--creator-family creator)))
             (string-join (cl-remove-if-not #'ookcite--nonempty-string-p
                                            (list first last))
                          " "))))
       creators
       ", "))
     (t nil))))

(defun ookcite-ridley--path-reference-candidates (raw)
  "Return filesystem path candidates for RAW."
  (let ((trimmed (and raw (string-trim raw))))
    (unless (ookcite--nonempty-string-p trimmed)
      (setq trimmed nil))
    (when trimmed
      (list
       (cond
        ((string-prefix-p "file://" trimmed)
         (url-unhex-string (substring trimmed 7)))
        ((string-prefix-p "~/" trimmed)
         (expand-file-name trimmed))
        (t trimmed))))))

(defun ookcite-ridley--asset-path-candidates (asset)
  "Return local path candidates for Ridley ASSET."
  (apply
   #'append
   (mapcar (lambda (key)
             (ookcite-ridley--path-reference-candidates
              (ookcite--get asset key)))
           '(local_path path attachmentPath))))

(defun ookcite-ridley--item-path-candidates (item)
  "Return local PDF path candidates for Ridley ITEM."
  (let ((direct (ookcite-ridley--path-reference-candidates
                 (ookcite-ridley--field item 'attachmentPath)))
        (bundle-pdf (ookcite--get item 'ookcite_bundle_pdf_file))
        (asset-paths
         (apply #'append
                (mapcar #'ookcite-ridley--asset-path-candidates
                        (or (ookcite--get item 'assets) nil)))))
    (delete-dups (append direct (and bundle-pdf (list bundle-pdf)) asset-paths))))

(defun ookcite-ridley-item-pdf-file (item)
  "Return the best local PDF file path for Ridley ITEM."
  (let* ((candidates (ookcite-ridley--item-path-candidates item))
         (existing (cl-find-if #'file-exists-p candidates)))
    (or existing (car candidates))))

(defun ookcite-ridley--item-summary (item)
  "Return one-line display summary for Ridley ITEM."
  (string-join
   (cl-remove-if-not
    #'ookcite--nonempty-string-p
    (list (ookcite--entry-title item)
          (ookcite-ridley--authors-string item)
          (ookcite--entry-year item)
          (ookcite--entry-doi item)
          (ookcite-ridley-item-pdf-file item)))
   " | "))

(defun ookcite-ridley--item-citation-keys (item)
  "Return possible citation keys for Ridley ITEM."
  (delete-dups
   (cl-remove-if-not
    #'ookcite--nonempty-string-p
    (list (ookcite-ridley--field item 'citationKey)
          (ookcite-ridley--field item 'citation_key)
          (ookcite-ridley--field item 'citekey)
          (ookcite-ridley--field item 'key)
          (ookcite-entry-citation-key item)))))

(defun ookcite-ridley-find-item-by-key (key)
  "Return the Ridley item matching citation KEY, or nil."
  (cl-find-if
   (lambda (item)
     (member key (ookcite-ridley--item-citation-keys item)))
   (ookcite-ridley-all-items)))

(defun ookcite-ridley--completion-annotation (choices candidate)
  "Return completion annotation for CANDIDATE in CHOICES."
  (let ((item (cdr (assoc candidate choices))))
    (concat
     " "
     (string-join
      (cl-remove-if-not
       #'ookcite--nonempty-string-p
       (list (ookcite--entry-year item)
             (ookcite--entry-doi item)
             (ookcite-ridley-item-pdf-file item)))
      " | "))))

(defun ookcite-ridley--completion-table (choices)
  "Return a metadata-rich completion table for Ridley CHOICES."
  (let ((metadata `(metadata
                   (category . ookcite-ridley-item)
                   (annotation-function
                    . ,(lambda (candidate)
                         (ookcite-ridley--completion-annotation
                          choices candidate))))))
    (lambda (string predicate action)
      (if (eq action 'metadata)
          metadata
        (complete-with-action action (mapcar #'car choices)
                              string predicate)))))

(defun ookcite-ridley-read-item ()
  "Prompt for a Ridley item from configured JSON sources."
  (let* ((items (ookcite-ridley-all-items))
         (items-with-docs
          (cl-remove-if-not #'ookcite-ridley-item-pdf-file items))
         (choices
          (cl-loop for item in items-with-docs
                   collect (cons (ookcite-ridley--item-summary item) item)))
         (choice (let ((completion-extra-properties
                        `(:annotation-function
                          ,(lambda (candidate)
                             (ookcite-ridley--completion-annotation
                              choices candidate)))))
                   (completing-read
                    "Ridley item: "
                    (ookcite-ridley--completion-table choices)
                    nil t))))
    (or (cdr (assoc choice choices))
        (signal 'ookcite-error (list "No Ridley item selected")))))

(defun ookcite-ridley--note-slug (key title)
  "Return a stable note filename stem from KEY and TITLE."
  (let ((slug (ookcite--ascii-slug (or key title "paper"))))
    (if (string-empty-p slug) "paper" slug)))

(defun ookcite-ridley--read-note-file (item key)
  "Read note file path for ITEM and KEY."
  (or ookcite-ridley-notes-file
      (read-file-name "Ridley notes file: " nil nil nil
                      (concat (ookcite-ridley--note-slug
                               key (ookcite--entry-title item))
                              ".org"))))

(defun ookcite-ridley--org-noter-properties-text ()
  "Return Org property lines for configured org-noter session properties."
  (mapconcat
   (pcase-lambda (`(,property . ,value))
     (format ":%s: %s" property value))
   (cl-remove-if-not
    (pcase-lambda (`(,property . ,value))
      (and (ookcite--nonempty-string-p property)
           (ookcite--nonempty-string-p value)))
    ookcite-ridley-org-noter-properties)
   "\n"))

(defun ookcite-ridley-default-note-text (item pdf-file &optional key)
  "Return org-noter note text for Ridley ITEM and PDF-FILE.

KEY overrides the citation key in Org properties."
  (let* ((cite-key (or key (ookcite-entry-citation-key item)))
         (title (ookcite--entry-title item))
         (tags (and ookcite-ridley-note-tags
                    (concat " :" (string-join ookcite-ridley-note-tags ":") ":")))
         (heading (string-join
                   (cl-remove-if-not
                    #'ookcite--nonempty-string-p
                    (list "*" ookcite-ridley-note-heading-todo title))
                   " ")))
    (concat heading tags "\n"
            ":PROPERTIES:\n"
            (format ":Custom_ID: %s\n" cite-key)
            (format ":ROAM_KEY: cite:%s\n" cite-key)
            (format ":NOTER_DOCUMENT: %s\n" pdf-file)
            (when-let ((properties (ookcite-ridley--org-noter-properties-text)))
              (and (not (string-empty-p properties))
                   (concat properties "\n")))
            (when-let ((ridley-id (ookcite-ridley--item-id item)))
              (format ":RIDLEY_ITEM_ID: %s\n" ridley-id))
            (when-let ((doi (ookcite--entry-doi item)))
              (format ":DOI: %s\n" doi))
            (when-let ((url (or (ookcite--get item 'url)
                                (ookcite-ridley--field item 'url))))
              (format ":URL: %s\n" url))
            (when-let ((author (ookcite-ridley--authors-string item)))
              (and (ookcite--nonempty-string-p author)
                   (format ":AUTHOR: %s\n" author)))
            (when-let ((journal (or (ookcite-ridley--field item 'publicationTitle)
                                    (ookcite-ridley--field item 'journal))))
              (format ":JOURNAL: %s\n" journal))
            (when-let ((year (ookcite--entry-year item)))
              (format ":YEAR: %s\n" year))
            ":END:\n\n"
            (format "[[%s][PDF]]\n\n" pdf-file)
            (format "cite:@%s\n\n" cite-key))))

(defun ookcite-ridley-note-text (item pdf-file &optional key)
  "Return org-noter note text for Ridley ITEM and PDF-FILE.

KEY overrides the citation key in Org properties."
  (funcall ookcite-ridley-note-format-function item pdf-file key))

(defun ookcite-ridley--goto-note (key)
  "Move point to a note with Custom_ID KEY when it exists."
  (goto-char (point-min))
  (re-search-forward
   (format "^[ \t]*:Custom_ID:[ \t]+%s[ \t]*$" (regexp-quote key))
   nil t))

(defun ookcite-ridley-create-note (item pdf-file &optional note-file key)
  "Create or visit a Ridley reading note for ITEM and PDF-FILE.

NOTE-FILE overrides `ookcite-ridley-notes-file'.  KEY overrides the
synthesized citation key."
  (let* ((cite-key (or key (ookcite-entry-citation-key item)))
         (file (or note-file (ookcite-ridley--read-note-file item cite-key))))
    (make-directory (file-name-directory file) t)
    (find-file file)
    (unless (ookcite-ridley--goto-note cite-key)
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (unless (or (bobp)
                  (save-excursion
                    (forward-line -1)
                    (looking-at-p "[[:space:]]*$")))
        (insert "\n"))
      (insert (ookcite-ridley-note-text item pdf-file cite-key))
      (ookcite-ridley--goto-note cite-key)
      (save-buffer))
    (when (and ookcite-ridley-open-note-after-create
               (fboundp 'org-noter))
      (funcall 'org-noter))
    cite-key))

;;;###autoload
(defun ookcite-ridley-read (&optional item)
  "Create/open an org-noter reading note for Ridley ITEM.

Interactively, choose from `ookcite-ridley-item-json-files'."
  (interactive)
  (let* ((item (or item (ookcite-ridley-read-item)))
         (pdf-file (or (ookcite-ridley-item-pdf-file item)
                       (read-file-name "PDF file: " nil nil t))))
    (ookcite-ridley-create-note item pdf-file)))

;;;###autoload
(defun ookcite-ridley-read-pdf (pdf-file title)
  "Create/open an org-noter reading note for standalone PDF-FILE and TITLE."
  (interactive
   (list (read-file-name "PDF file: " nil nil t)
         (read-string "Title: ")))
  (let ((item `((title . ,title)
                (itemType . "journalArticle")
                (attachmentPath . ,pdf-file))))
    (ookcite-ridley-create-note item pdf-file)))

;;;###autoload
(defun ookcite-ridley-read-bibtex-key (key &optional entry)
  "Create/open a reading note for BibTeX KEY.

ENTRY overrides the parsed BibTeX entry."
  (interactive
   (list (or (ookcite-citation-key-at-point)
             (read-string "Citation key: "))))
  (let* ((bibtex-entry (or entry (ookcite-bibtex-entry-by-key key)))
         (pdf-file (or (ookcite-citar-pdf-file-by-key key)
                       (and bibtex-entry
                            (ookcite-bibtex-pdf-file bibtex-entry)))))
    (unless bibtex-entry
      (user-error "No BibTeX entry found for %s" key))
    (unless pdf-file
      (user-error "No PDF file field found for %s" key))
    (ookcite-ridley-create-note bibtex-entry pdf-file nil key)))

;;;###autoload
(defun ookcite-ridley-read-at-point (&optional key)
  "Create/open a Ridley reading note for citation KEY at point."
  (interactive)
  (let* ((cite-key (or key
                       (ookcite-citation-key-at-point)
                       (read-string "Citation key: ")))
         (item (ookcite-ridley-find-item-by-key cite-key)))
    (if item
        (ookcite-ridley-read item)
      (ookcite-ridley-read-bibtex-key cite-key))))

;;;###autoload
(defun ookcite-ridley-read-reference (&optional key)
  "Select a citation KEY and create/open its Ridley reading note."
  (interactive)
  (ookcite-ridley-read-at-point
   (or key
       (and ookcite-use-citar
            (fboundp 'citar-select-ref)
            (funcall 'citar-select-ref))
       (read-string "Citation key: "))))

;;;###autoload
(defun ookcite-ridley-add-doi-and-read (doi bib-file pdf-file)
  "Add DOI to BIB-FILE with PDF-FILE and create/open a reading note."
  (interactive
   (list (read-string "DOI: ")
         (ookcite-read-bibliography-file)
         (read-file-name "PDF file: " nil nil t)))
  (let* ((entry (ookcite-lookup-doi-sync doi))
         (key (ookcite-add-entry-to-bibliography entry bib-file pdf-file)))
    (ookcite-ridley-create-note entry pdf-file nil key)))

(defvar ookcite-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-o c") #'ookcite-insert-org-cite)
    (define-key map (kbd "C-c C-o d") #'ookcite-insert-org-cite-from-doi)
    (define-key map (kbd "C-c C-o a") #'ookcite-add-citation-to-bib)
    (define-key map (kbd "C-c C-o A") #'ookcite-add-citation-to-collection)
    (define-key map (kbd "C-c C-o D") #'ookcite-add-doi-to-collection)
    (define-key map (kbd "C-c C-o f") #'ookcite-format-doi)
    (define-key map (kbd "C-c C-o l") #'ookcite-lookup-doi)
    (define-key map (kbd "C-c C-o p") #'ookcite-parse-region)
    (define-key map (kbd "C-c C-o s") #'ookcite-search-styles)
    (define-key map (kbd "C-c C-o r") #'ookcite-ridley-read)
    (define-key map (kbd "C-c C-o R") #'ookcite-ridley-read-at-point)
    (define-key map (kbd "C-c C-o o") #'ookcite-ridley-read-reference)
    map)
  "Keymap for `ookcite-mode'.")

;;;###autoload
(define-minor-mode ookcite-mode
  "Minor mode for OokCite and Ridley citation commands."
  :lighter " Ook"
  :keymap ookcite-mode-map)

(provide 'ookcite)
;;; ookcite.el ends here
