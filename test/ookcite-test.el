;;; ookcite-test.el --- Tests for ookcite -*- lexical-binding: t; -*-

(require 'ert)
(setq load-prefer-newer t)
(add-to-list 'load-path
             (file-name-directory
              (directory-file-name
               (file-name-directory load-file-name))))
(require 'ookcite)

(ert-deftest ookcite-test-endpoint-url ()
  (let ((ookcite-base-url "https://example.test/"))
    (should (equal (ookcite--url 'lookup-doi)
                   "https://example.test/api/v1/lookup/doi"))
    (should (equal (ookcite--url 'collection '((id . "abc 123/x")))
                   "https://example.test/api/v1/collections/abc%20123%2Fx"))
    (should (equal (ookcite--url 'styles-search nil
                                 '((q . "american chemical society")
                                   (limit . 5)))
                   (concat "https://example.test/api/v1/styles/search"
                           "?q=american%20chemical%20society&limit=5")))))

(ert-deftest ookcite-test-resolve-payload ()
  (let ((payload (ookcite--resolve-payload
                  "Goswami MethodsX 2026"
                  '((author . "Goswami") (year . 2026))
                  t 3)))
    (should (equal (ookcite--nested-get payload 'input 'kind) "text"))
    (should (equal (ookcite--nested-get payload 'input 'text)
                   "Goswami MethodsX 2026"))
    (should (equal (ookcite--nested-get payload 'filters 'author)
                   "Goswami"))
    (should (equal (ookcite--nested-get payload 'options 'max_candidates) 3))
    (should (eq (ookcite--nested-get payload 'options 'use_live_queries) t))))

(ert-deftest ookcite-test-candidate-extraction ()
  (let* ((metadata '((title . "Paper") (doi . "10.5555/example")))
         (response `((paper)
                     (candidates . (((score . 12.0)
                                     (metadata . ,metadata)))))))
    (should (equal (ookcite--candidate-metadata-list response)
                   (list metadata)))))

(ert-deftest ookcite-test-citation-key-ookcite-shape ()
  (let ((entry '((title . "An Example Paper")
                 (authors . (((family . "O'Neill") (given . "Ada"))))
                 (date . ((year . 2024)))
                 (doi . "10.5555/example"))))
    (should (equal (ookcite-entry-citation-key entry) "oneill2024"))))

(ert-deftest ookcite-test-citation-key-ridley-seed-shape ()
  (let ((entry '((itemType . "journalArticle")
                 (title . "Attention Is All You Need")
                 (creators . (((firstName . "Ashish") (lastName . "Vaswani"))))
                 (date . "2017")
                 (DOI . "10.5555/attention"))))
    (should (equal (ookcite-entry-citation-key entry) "vaswani2017"))))

(ert-deftest ookcite-test-bibtex-rendering ()
  (let* ((entry '((title . "A {Brace} Paper")
                  (entry_type . "Article")
                  (authors . (((family . "Smith") (given . "Ada"))))
                  (date . ((year . 2020)))
                  (journal . "Journal of Tests")
                  (doi . "10.5555/test")))
         (bibtex (ookcite-entry-bibtex entry "smith2020" "/tmp/paper.pdf")))
    (should (string-match-p "@article{smith2020," bibtex))
    (should (string-search "title = {A \\{Brace\\} Paper}," bibtex))
    (should (string-match-p "author = {Smith, Ada}," bibtex))
    (should (string-match-p "year = {2020}," bibtex))
    (should (string-match-p "doi = {10.5555/test}," bibtex))
    (should (string-match-p "file = {/tmp/paper.pdf}," bibtex))))

(ert-deftest ookcite-test-bibtex-string-authors-stay-readable ()
  (let ((entry '((title . "Computing Machinery")
                 (author . "Turing, Alan and Lovelace, Ada")
                 (year . "1950"))))
    (should (equal (ookcite-entry-authors-string entry)
                   "Turing, Alan and Lovelace, Ada"))))

(ert-deftest ookcite-test-ridley-note-text-keeps-bibtex-string-author ()
  (let* ((item '((title . "Computing Machinery")
                 (author . "Turing, Alan and Lovelace, Ada")
                 (year . "1950")
                 (doi . "10.5555/turing")))
         (note (ookcite-ridley-note-text item "/tmp/turing.pdf"
                                         "turing1950")))
    (should (string-match-p
             ":AUTHOR: Turing, Alan and Lovelace, Ada" note))
    (should-not (string-match-p "Anonymous" note))))

(ert-deftest ookcite-test-bibtex-key-exists ()
  (let ((file (make-temp-file "ookcite" nil ".bib")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "@article{smith2020,\n  title = {Test},\n}\n"))
          (should (ookcite--bibtex-key-exists-p file "smith2020"))
          (should-not (ookcite--bibtex-key-exists-p file "doe2021")))
      (delete-file file))))

(ert-deftest ookcite-test-add-entry-to-collection-imports-single-bibtex ()
  (let* ((entry '((title . "Collection Paper")
                  (entry_type . "Article")
                  (authors . (((family . "Curie") (given . "Marie"))))
                  (date . ((year . 1911)))
                  (doi . "10.5555/collection")))
         (captured nil))
    (cl-letf (((symbol-function 'ookcite-request)
               (lambda (endpoint data method query params &optional raw)
                 (setq captured
                       (list endpoint data method query params raw))
                 '((imported . 1)))))
      (should (equal (ookcite-add-entry-to-collection
                      entry "readings" "curie1911" "/tmp/curie.pdf")
                     '((imported . 1))))
      (pcase-let ((`(,endpoint ,data ,method ,query ,params ,raw) captured))
        (should (eq endpoint 'collection-import))
        (should (equal method "POST"))
        (should-not query)
        (should-not raw)
        (should (equal params '((id . "readings"))))
        (should (equal (ookcite--get data 'format) "bibtex"))
        (should (string-match-p "@article{curie1911,"
                                (ookcite--get data 'content)))
        (should (string-match-p "file = {/tmp/curie.pdf},"
                                (ookcite--get data 'content)))))))

(ert-deftest ookcite-test-add-doi-to-collection-uses-lookup-result ()
  (let ((entry '((title . "Lookup Paper")
                 (authors . (((family . "Noether") (given . "Emmy"))))
                 (date . ((year . 1918)))
                 (doi . "10.5555/noether")))
        captured)
    (cl-letf (((symbol-function 'ookcite-lookup-doi-sync)
               (lambda (doi)
                 (should (equal doi "10.5555/noether"))
                 entry))
              ((symbol-function 'ookcite-add-entry-to-collection)
               (lambda (entry collection-id &optional key pdf-file)
                 (setq captured
                       (list entry collection-id key pdf-file))
                 '((imported . 1)))))
      (should (equal (ookcite-add-doi-to-collection
                      "10.5555/noether" "math" "/tmp/noether.pdf")
                     '((imported . 1))))
      (should (equal captured
                     (list entry "math" nil "/tmp/noether.pdf"))))))

(ert-deftest ookcite-test-add-citation-to-collection-uses-resolve-result ()
  (let ((entry '((title . "Resolved Paper")
                 (authors . (((family . "Franklin") (given . "Rosalind"))))
                 (date . ((year . 1953)))
                 (doi . "10.5555/franklin")))
        captured)
    (cl-letf (((symbol-function 'ookcite-resolve-sync)
               (lambda (query)
                 (should (equal query "Franklin DNA 1953"))
                 `((paper . ,entry))))
              ((symbol-function 'ookcite-add-entry-to-collection)
               (lambda (entry collection-id &optional key pdf-file)
                 (setq captured
                       (list entry collection-id key pdf-file))
                 '((imported . 1)))))
      (should (equal (ookcite-add-citation-to-collection
                      "Franklin DNA 1953" "biology" "/tmp/franklin.pdf")
                     '((imported . 1))))
      (should (equal captured
                     (list entry "biology" nil "/tmp/franklin.pdf"))))))

(ert-deftest ookcite-test-ridley-seed-file-items ()
  (let ((file (make-temp-file "ookcite-ridley" nil ".json")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "{\"items\":[{\"title\":\"Paper\",\"attachmentPath\":\"/tmp/paper.pdf\"}]}"))
          (let ((items (ookcite-ridley-read-items-from-file file)))
            (should (= (length items) 1))
            (should (equal (ookcite--entry-title (car items)) "Paper"))
            (should (equal (ookcite-ridley-item-pdf-file (car items))
                           "/tmp/paper.pdf"))))
      (delete-file file))))

(ert-deftest ookcite-test-ridley-directory-bundle-items ()
  (let* ((dir (make-temp-file "ookcite-ridley-bundle" t))
         (metadata-dir (expand-file-name "metadata" dir))
         (files-dir (expand-file-name "files" dir))
         (pdf-file (expand-file-name "paper.pdf" files-dir)))
    (unwind-protect
        (progn
          (make-directory metadata-dir t)
          (make-directory files-dir t)
          (with-temp-file (expand-file-name "item.json" metadata-dir)
            (insert "{\"title\":\"Bundled Paper\",\"creators\":[{\"firstName\":\"Ada\",\"lastName\":\"Lovelace\"}],\"date\":\"1843\"}"))
          (with-temp-file (expand-file-name "manifest.json" metadata-dir)
            (insert "{\"files\":[{\"path\":\"files/paper.pdf\",\"content_type\":\"application/pdf\"}]}"))
          (with-temp-file pdf-file
            (insert "%PDF-1.7\n"))
          (let ((items (ookcite-ridley-read-items-from-file dir)))
            (should (= (length items) 1))
            (should (equal (ookcite--entry-title (car items))
                           "Bundled Paper"))
            (should (equal (ookcite-ridley-item-pdf-file (car items))
                           pdf-file))))
      (delete-directory dir t))))

(ert-deftest ookcite-test-ridley-zip-bundle-items ()
  (let* ((dir (make-temp-file "ookcite-ridley-zip-src" t))
         (cache-dir (make-temp-file "ookcite-ridley-zip-cache" t))
         (metadata-dir (expand-file-name "metadata" dir))
         (files-dir (expand-file-name "files" dir))
         (zip-file (expand-file-name "bundle.ridley.zip" dir))
         (materialized nil))
    (unwind-protect
        (progn
          (make-directory metadata-dir t)
          (make-directory files-dir t)
          (with-temp-file (expand-file-name "item.json" metadata-dir)
            (insert "{\"title\":\"Archived Paper\",\"creators\":[{\"firstName\":\"Grace\",\"lastName\":\"Hopper\"}],\"date\":\"1952\"}"))
          (with-temp-file (expand-file-name "manifest.json" metadata-dir)
            (insert "{\"files\":[{\"path\":\"files/paper.pdf\",\"content_type\":\"application/pdf\"}]}"))
          (with-temp-file (expand-file-name "paper.pdf" files-dir)
            (insert "%PDF-1.7\nArchived"))
          (let ((default-directory dir))
            (should (zerop (process-file "zip" nil nil nil "-qr"
                                         zip-file "metadata" "files"))))
          (let* ((ookcite-ridley-bundle-extract-directory cache-dir)
                 (items (ookcite-ridley-read-items-from-file zip-file))
                 (item (car items)))
            (should (= (length items) 1))
            (should (equal (ookcite--entry-title item) "Archived Paper"))
            (setq materialized (ookcite-ridley-item-pdf-file item))
            (should (file-exists-p materialized))
            (with-temp-buffer
              (insert-file-contents materialized)
              (should (string-search "Archived" (buffer-string))))))
      (delete-directory dir t)
      (delete-directory cache-dir t))))

(ert-deftest ookcite-test-ridley-completion-annotation-keeps-zip-pdf-cold ()
  (let* ((dir (make-temp-file "ookcite-ridley-zip-src" t))
         (cache-dir (make-temp-file "ookcite-ridley-zip-cache" t))
         (metadata-dir (expand-file-name "metadata" dir))
         (files-dir (expand-file-name "files" dir))
         (zip-file (expand-file-name "bundle.ridley.zip" dir)))
    (unwind-protect
        (progn
          (make-directory metadata-dir t)
          (make-directory files-dir t)
          (with-temp-file (expand-file-name "item.json" metadata-dir)
            (insert "{\"title\":\"Cold Paper\",\"creators\":[{\"firstName\":\"Grace\",\"lastName\":\"Hopper\"}],\"date\":\"1952\"}"))
          (with-temp-file (expand-file-name "manifest.json" metadata-dir)
            (insert "{\"files\":[{\"path\":\"files/paper.pdf\",\"content_type\":\"application/pdf\"}]}"))
          (with-temp-file (expand-file-name "paper.pdf" files-dir)
            (insert "%PDF-1.7\nCold"))
          (let ((default-directory dir))
            (should (zerop (process-file "zip" nil nil nil "-qr"
                                         zip-file "metadata" "files"))))
          (let* ((ookcite-ridley-bundle-extract-directory cache-dir)
                 (item (car (ookcite-ridley-read-items-from-file zip-file)))
                 (candidate "Cold")
                 (choices `((,candidate . ,item)))
                 (cache-file (ookcite-ridley-item-pdf-file item t)))
            (should-not (file-exists-p cache-file))
            (should (string-match-p "1952"
                                    (ookcite-ridley--completion-annotation
                                     choices candidate)))
            (should-not (file-exists-p cache-file))))
      (delete-directory dir t)
      (delete-directory cache-dir t))))

(ert-deftest ookcite-test-ridley-note-text ()
  (let* ((item '((item_id . "01ABC")
                 (itemType . "journalArticle")
                 (title . "Readable Paper")
                 (creators . (((firstName . "Ada") (lastName . "Lovelace"))))
                 (date . "1843")
                 (DOI . "10.5555/readable")
                 (publicationTitle . "Scientific Memoirs")))
         (note (let ((ookcite-ridley-note-tags '("reading" "ridley")))
                 (ookcite-ridley-note-text item "/tmp/readable.pdf"
                                           "lovelace1843"))))
    (should (string-match-p "\\* TODO Readable Paper :reading:ridley:" note))
    (should (string-match-p ":Custom_ID: lovelace1843" note))
    (should (string-match-p ":NOTER_DOCUMENT: /tmp/readable.pdf" note))
    (should (string-match-p ":RIDLEY_ITEM_ID: 01ABC" note))
    (should (string-match-p "cite:@lovelace1843" note))))

(ert-deftest ookcite-test-ridley-note-text-org-noter-properties ()
  (let* ((item '((title . "Readable Paper")
                 (date . "1843")
                 (attachmentPath . "/tmp/readable.pdf")))
         (ookcite-ridley-org-noter-properties
          '(("NOTER_NOTES_BEHAVIOR" . "(start scroll)")
            ("NOTER_NOTES_LOCATION" . "horizontal-split")
            ("NOTER_DOCUMENT_SPLIT_FRACTION" . "(0.55 . 0.45)")
            ("NOTER_AUTO_SAVE_LAST_LOCATION" . "t")))
         (note (ookcite-ridley-note-text item "/tmp/readable.pdf"
                                         "lovelace1843")))
    (should (string-match-p ":NOTER_NOTES_BEHAVIOR: (start scroll)" note))
    (should (string-match-p ":NOTER_NOTES_LOCATION: horizontal-split" note))
    (should (string-match-p
             ":NOTER_DOCUMENT_SPLIT_FRACTION: (0.55 . 0.45)"
             note))
    (should (string-match-p ":NOTER_AUTO_SAVE_LAST_LOCATION: t" note))))

(ert-deftest ookcite-test-citation-key-at-point ()
  (with-temp-buffer
    (insert "See cite:@vaswani2017 for the transformer baseline.")
    (goto-char (point-min))
    (search-forward "vaswani")
    (should (equal (ookcite-citation-key-at-point) "vaswani2017"))))

(ert-deftest ookcite-test-citation-key-at-point-prefers-citar ()
  (with-temp-buffer
    (insert "fallback cite:@slow2024")
    (goto-char (point-min))
    (cl-letf (((symbol-function 'citar-key-at-point)
               (lambda () "fast2026")))
      (let ((ookcite-use-citar t))
        (should (equal (ookcite-citation-key-at-point) "fast2026"))))))

(ert-deftest ookcite-test-citar-entry-by-key ()
  (let ((entry '(("=key=" . "fast2026")
                 ("title" . "Cached Paper")
                 ("file" . ":/tmp/cached.pdf:PDF"))))
    (cl-letf (((symbol-function 'citar-get-entry)
               (lambda (key)
                 (should (equal key "fast2026"))
                 entry)))
      (let ((ookcite-use-citar t))
        (should (eq (ookcite-citar-entry-by-key "fast2026") entry))))))

(ert-deftest ookcite-test-bibtex-entry-by-key ()
  (let ((file (make-temp-file "ookcite-bib" nil ".bib")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "@article{lovelace1843,\n"
                    "  title = {Readable Paper},\n"
                    "  author = {Lovelace, Ada},\n"
                    "  year = {1843},\n"
                    "  doi = {10.5555/readable},\n"
                    "  file = {/tmp/readable.pdf},\n"
                    "}\n"))
          (let* ((ookcite-bibliography-files (list file))
                 (entry (ookcite-bibtex-entry-by-key "lovelace1843")))
            (should (equal (ookcite--get entry '=key=) "lovelace1843"))
            (should (equal (ookcite--get entry 'title) "Readable Paper"))
            (should (equal (ookcite--entry-year entry) "1843"))
            (should (equal (ookcite-bibtex-pdf-file entry)
                           "/tmp/readable.pdf"))))
      (delete-file file))))

(ert-deftest ookcite-test-bibtex-entry-by-key-prefers-citar-cache ()
  (let ((entry '(("=key=" . "fast2026")
                 ("title" . "Cached Paper")
                 ("file" . ":/tmp/cached.pdf:PDF"))))
    (cl-letf (((symbol-function 'citar-get-entry)
               (lambda (_key) entry)))
      (let ((ookcite-use-citar t))
        (should (eq (ookcite-bibtex-entry-by-key "fast2026") entry))))))

(ert-deftest ookcite-test-citar-pdf-file-by-key ()
  (let ((files (make-hash-table :test 'equal)))
    (puthash "fast2026" '("/tmp/first.pdf" "/tmp/second.pdf") files)
    (cl-letf (((symbol-function 'citar-get-files)
               (lambda (key)
                 (should (equal key "fast2026"))
                 files)))
      (let ((ookcite-use-citar t))
        (should (equal (ookcite-citar-pdf-file-by-key "fast2026")
                       "/tmp/first.pdf"))))))

(ert-deftest ookcite-test-ridley-all-items-caches-source-files ()
  (let ((file (make-temp-file "ookcite-ridley" nil ".json"))
        (calls 0))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "{\"items\":[{\"title\":\"Cached\",\"attachmentPath\":\"/tmp/cached.pdf\"}]}"))
          (let ((ookcite-ridley-item-json-files (list file))
                (ookcite-ridley-cache-items t))
            (ookcite-ridley-clear-cache)
            (cl-letf (((symbol-function 'ookcite-ridley-read-items-from-file)
                       (lambda (_file)
                         (cl-incf calls)
                         '(((title . "Cached")
                            (attachmentPath . "/tmp/cached.pdf"))))))
              (should (= (length (ookcite-ridley-all-items)) 1))
              (should (= (length (ookcite-ridley-all-items)) 1))
              (should (= calls 1)))))
      (delete-file file))))

(ert-deftest ookcite-test-ridley-directory-bundle-cache-includes-metadata ()
  (let* ((dir (make-temp-file "ookcite-ridley-cache-bundle" t))
         (metadata-dir (expand-file-name "metadata" dir))
         (files-dir (expand-file-name "files" dir))
         (item-file (expand-file-name "item.json" metadata-dir))
         (manifest-file (expand-file-name "manifest.json" metadata-dir))
         (fixed-directory-time (encode-time 0 0 0 1 1 2026)))
    (unwind-protect
        (progn
          (make-directory metadata-dir t)
          (make-directory files-dir t)
          (with-temp-file item-file
            (insert "{\"title\":\"First\",\"attachmentPath\":\"files/paper.pdf\"}"))
          (with-temp-file manifest-file
            (insert "{\"files\":[{\"path\":\"files/paper.pdf\",\"content_type\":\"application/pdf\"}]}"))
          (with-temp-file (expand-file-name "paper.pdf" files-dir)
            (insert "%PDF-1.7\n"))
          (set-file-times dir fixed-directory-time)
          (let ((ookcite-ridley-item-json-files (list dir))
                (ookcite-ridley-cache-items t))
            (ookcite-ridley-clear-cache)
            (should (equal (ookcite--entry-title
                            (car (ookcite-ridley-all-items)))
                           "First"))
            (with-temp-file item-file
              (insert "{\"title\":\"Second\",\"attachmentPath\":\"files/paper.pdf\"}"))
            (set-file-times item-file (encode-time 0 0 0 2 1 2026))
            (set-file-times dir fixed-directory-time)
            (should (equal (ookcite--entry-title
                            (car (ookcite-ridley-all-items)))
                           "Second"))))
      (delete-directory dir t))))

(ert-deftest ookcite-test-ridley-completion-table-has-metadata ()
  (let* ((item '((title . "Attention Is All You Need")
                 (creators . (((firstName . "Ashish") (lastName . "Vaswani"))))
                 (date . "2017")
                 (attachmentPath . "/tmp/attention.pdf")))
         (choices `(("Attention" . ,item)))
         (table (ookcite-ridley--completion-table choices))
         (metadata (funcall table "" nil 'metadata))
         (annotation (cdr (assq 'annotation-function (cdr metadata)))))
    (should (eq (cdr (assq 'category (cdr metadata)))
                'ookcite-ridley-item))
    (should (string-match-p "2017" (funcall annotation "Attention")))
    (should (equal (funcall table "Att" nil t) '("Attention")))))

(ert-deftest ookcite-test-ridley-candidate-item-uses-completion-cache ()
  (let* ((item '((title . "Attention Is All You Need")
                 (creators . (((firstName . "Ashish") (lastName . "Vaswani"))))
                 (date . "2017")
                 (attachmentPath . "/tmp/attention.pdf")))
         (ookcite-ridley--completion-choices `(("Attention" . ,item))))
    (should (eq (ookcite-ridley-candidate-item "Attention") item))))

(ert-deftest ookcite-test-embark-setup-registers-ridley-category ()
  (let ((previous-bound (boundp 'embark-keymap-alist))
        (previous-value (and (boundp 'embark-keymap-alist)
                             (symbol-value 'embark-keymap-alist))))
    (unwind-protect
        (progn
          (set 'embark-keymap-alist nil)
          (ookcite-embark-setup)
          (should (eq (alist-get 'ookcite-ridley-item
                                 (symbol-value 'embark-keymap-alist))
                      ookcite-ridley-embark-map)))
      (if previous-bound
          (set 'embark-keymap-alist previous-value)
        (makunbound 'embark-keymap-alist)))))

(ert-deftest ookcite-test-add-entry-to-collection-async ()
  (let* ((entry '((title . "Async Paper")
                  (authors . (((family . "Hopper") (given . "Grace"))))
                  (date . ((year . 1952)))
                  (doi . "10.5555/async")))
         captured
         callback-result)
    (cl-letf (((symbol-function 'ookcite-request-async)
               (lambda (endpoint data callback method query params &optional raw)
                 (setq captured
                       (list endpoint data method query params raw))
                 (funcall callback nil '((imported . 1))))))
      (ookcite-add-entry-to-collection-async
       entry "systems"
       (lambda (error result)
         (setq callback-result (list error result)))
       "hopper1952" "/tmp/hopper.pdf")
      (pcase-let ((`(,endpoint ,data ,method ,query ,params ,raw) captured))
        (should (eq endpoint 'collection-import))
        (should (equal method "POST"))
        (should-not query)
        (should-not raw)
        (should (equal params '((id . "systems"))))
        (should (string-match-p "@misc{hopper1952,"
                                (ookcite--get data 'content))))
      (should (equal callback-result '(nil ((imported . 1))))))))

(ert-deftest ookcite-test-ridley-find-item-by-key ()
  (let ((item '((itemType . "journalArticle")
                (title . "Attention Is All You Need")
                (creators . (((firstName . "Ashish") (lastName . "Vaswani"))))
                (date . "2017")
                (DOI . "10.5555/attention")
                (attachmentPath . "/tmp/attention.pdf"))))
    (cl-letf (((symbol-function 'ookcite-ridley-all-items)
               (lambda () (list item))))
      (should (eq (ookcite-ridley-find-item-by-key "vaswani2017") item)))))

(ert-deftest ookcite-test-ridley-read-at-point-opens-matched-item ()
  (let ((item '((itemType . "journalArticle")
                (title . "Attention Is All You Need")
                (creators . (((firstName . "Ashish") (lastName . "Vaswani"))))
                (date . "2017")
                (attachmentPath . "/tmp/attention.pdf")))
        selected)
    (with-temp-buffer
      (insert "Review cite:@vaswani2017 before annotating.")
      (goto-char (point-min))
      (search-forward "vaswani")
      (cl-letf (((symbol-function 'ookcite-ridley-find-item-by-key)
                 (lambda (key)
                   (should (equal key "vaswani2017"))
                   item))
                ((symbol-function 'ookcite-ridley-read)
                 (lambda (&optional item)
                   (setq selected item)
                   "opened")))
        (should (equal (ookcite-ridley-read-at-point) "opened"))
        (should (eq selected item))))))

(ert-deftest ookcite-test-ridley-read-at-point-falls-back-to-bibtex ()
  (let ((file (make-temp-file "ookcite-bib" nil ".bib"))
        captured)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "@article{lovelace1843,\n"
                    "  title = {Readable Paper},\n"
                    "  author = {Lovelace, Ada},\n"
                    "  year = {1843},\n"
                    "  doi = {10.5555/readable},\n"
                    "  file = {:/tmp/readable.pdf:PDF},\n"
                    "}\n"))
          (let ((ookcite-bibliography-files (list file)))
            (with-temp-buffer
              (insert "Annotate cite:@lovelace1843 with the PDF notes.")
              (goto-char (point-min))
              (search-forward "lovelace")
              (cl-letf (((symbol-function 'ookcite-ridley-find-item-by-key)
                         (lambda (_key) nil))
                        ((symbol-function 'ookcite-ridley-create-note)
                         (lambda (item pdf-file &optional note-file key)
                           (setq captured
                                 (list item pdf-file note-file key))
                           "opened")))
                (should (equal (ookcite-ridley-read-at-point) "opened"))
                (pcase-let ((`(,item ,pdf-file ,note-file ,key) captured))
                  (should (equal (ookcite--get item 'title) "Readable Paper"))
                  (should (equal pdf-file "/tmp/readable.pdf"))
                  (should-not note-file)
                  (should (equal key "lovelace1843")))))))
      (delete-file file))))

(provide 'ookcite-test)
;;; ookcite-test.el ends here
