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

(provide 'ookcite-test)
;;; ookcite-test.el ends here
