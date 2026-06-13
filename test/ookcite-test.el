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

(ert-deftest ookcite-test-citation-key-at-point ()
  (with-temp-buffer
    (insert "See cite:@vaswani2017 for the transformer baseline.")
    (goto-char (point-min))
    (search-forward "vaswani")
    (should (equal (ookcite-citation-key-at-point) "vaswani2017"))))

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
