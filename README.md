# ookcite.el

`ookcite.el` connects Emacs to OokCite for citation creation and collection
work, and to Ridley-style PDF metadata for reading notes.

## What It Does

- Resolve DOI, ISBN, title, or messy citation text through OokCite.
- Append resolved entries to BibTeX files and insert `cite:@key` references.
- Search CSL styles and format references.
- Import/export OokCite collections as BibTeX/RIS, including adding one
  resolved citation directly to a collection with async interactive commands.
- Create org-noter-compatible reading notes from Ridley item JSON or a chosen
  PDF path, including from a citation key at point.
- Use Citar first when it is loaded: cached key-at-point, cached entries,
  associated PDF files, and Citar's own completion UI.
- Expose standard completion metadata, so Vertico and other completion UIs can
  show annotations without package-specific glue.

## Installation

```elisp
(add-to-list 'load-path "/path/to/ookcite.el")
(require 'ookcite)
```

With `use-package`:

```elisp
(use-package ookcite
  :load-path "/path/to/ookcite.el"
  :hook (org-mode . ookcite-mode)
  :custom
  (ookcite-bibliography-files '("~/refs/library.bib"))
  (ookcite-ridley-notes-file "~/org/bibnotes.org")
  (ookcite-ridley-item-json-files
   '("~/Git/Github/TurtleTech-ehf/ridley-desktop/fixtures/seed.json")))
```

With Citar loaded, keep your normal Citar bibliography/file configuration. The
OokCite/Ridley path checks Citar caches before reading BibTeX files directly:

```elisp
(use-package citar
  :custom
  (citar-bibliography '("~/refs/library.bib"))
  (citar-library-paths '("~/refs/pdfs")))
```

For a MELPA recipe:

```elisp
(ookcite
 :fetcher github
 :repo "HaoZeke/ookcite.el"
 :files ("ookcite.el"))
```

## Authentication

Anonymous lookup endpoints work with tighter rate limits. Collection operations
need an API key:

```sh
export OOKCITE_API_KEY=ookc_...
```

or:

```text
machine ookcite-api.turtletech.us login apikey password ookc_...
```

## Commands

`ookcite-mode` binds:

| Key | Command |
| --- | --- |
| `C-c C-o c` | `ookcite-insert-org-cite` |
| `C-c C-o d` | `ookcite-insert-org-cite-from-doi` |
| `C-c C-o a` | `ookcite-add-citation-to-bib` |
| `C-c C-o A` | `ookcite-add-citation-to-collection` |
| `C-c C-o D` | `ookcite-add-doi-to-collection` |
| `C-c C-o f` | `ookcite-format-doi` |
| `C-c C-o l` | `ookcite-lookup-doi` |
| `C-c C-o p` | `ookcite-parse-region` |
| `C-c C-o s` | `ookcite-search-styles` |
| `C-c C-o r` | `ookcite-ridley-read` |
| `C-c C-o R` | `ookcite-ridley-read-at-point` |
| `C-c C-o o` | `ookcite-ridley-read-reference` |

Collection helpers:

- `ookcite-list-collections`
- `ookcite-add-doi-to-collection`
- `ookcite-add-citation-to-collection`
- `ookcite-import-bibliography-file`
- `ookcite-export-collection-bibtex`
- `ookcite-check-collection-duplicates`
- `ookcite-share-collection`

Ridley reading helpers:

- `ookcite-ridley-read`
- `ookcite-ridley-read-at-point`
- `ookcite-ridley-read-reference`
- `ookcite-ridley-read-bibtex-key`
- `ookcite-ridley-read-pdf`
- `ookcite-ridley-add-doi-and-read`

`ookcite-ridley-read` consumes JSON files listed in
`ookcite-ridley-item-json-files`. Each file can be a Ridley seed fixture with
an `items` array, a raw array of item records, or a single item object. PDF
paths are read from `attachmentPath` or asset extras such as `local_path`,
`path`, and `attachmentPath`.

`ookcite-ridley-read-at-point` reads the org-cite key under point, matches it
against explicit Ridley key fields or the generated citation key, and opens the
same reading-note flow. If no Ridley item matches, it falls back to configured
BibTeX files and uses the entry's `file` field for the PDF path. Direct paths
and bibtex-completion-style values such as `:/path/to/paper.pdf:PDF` are
supported.

When Citar is loaded, `ookcite-ridley-read-at-point` asks Citar for the key and
cached entry first. `ookcite-ridley-read-reference` uses Citar's reference
selector when available, which means Vertico/Orderless/Marginalia setups keep
their normal bibliography UI. Ridley JSON files are cached until their
modification times change; run `M-x ookcite-ridley-clear-cache` to clear that
cache manually.

The note shape matches the org-ref/org-noter flow:

```org
* TODO Paper Title :reading:ridley:
:PROPERTIES:
:Custom_ID: key2026
:ROAM_KEY: cite:key2026
:NOTER_DOCUMENT: /path/to/paper.pdf
:NOTER_NOTES_BEHAVIOR: (start scroll)
:NOTER_NOTES_LOCATION: horizontal-split
:NOTER_DOCUMENT_SPLIT_FRACTION: (0.55 . 0.45)
:NOTER_AUTO_SAVE_LAST_LOCATION: t
:RIDLEY_ITEM_ID: 01...
:DOI: 10....
:END:
```

Those org-noter session properties come from
`ookcite-ridley-org-noter-properties`; set it to nil or replace entries if you
prefer global org-noter defaults.

## Verification

```sh
make test
make compile
make checkdoc
make package-lint
```
