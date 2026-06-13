# ookcite.el

`ookcite.el` connects Emacs to OokCite for citation creation and collection
work, and to Ridley-style PDF metadata for reading notes.

## What It Does

- Resolve DOI, ISBN, title, or messy citation text through OokCite.
- Append resolved entries to BibTeX files and insert `cite:@key` references.
- Search CSL styles and format references.
- Import/export OokCite collections as BibTeX/RIS.
- Create org-noter-compatible reading notes from Ridley item JSON or a chosen
  PDF path.

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
| `C-c C-o f` | `ookcite-format-doi` |
| `C-c C-o l` | `ookcite-lookup-doi` |
| `C-c C-o p` | `ookcite-parse-region` |
| `C-c C-o s` | `ookcite-search-styles` |
| `C-c C-o r` | `ookcite-ridley-read` |

Collection helpers:

- `ookcite-list-collections`
- `ookcite-import-bibliography-file`
- `ookcite-export-collection-bibtex`
- `ookcite-check-collection-duplicates`
- `ookcite-share-collection`

Ridley reading helpers:

- `ookcite-ridley-read`
- `ookcite-ridley-read-pdf`
- `ookcite-ridley-add-doi-and-read`

`ookcite-ridley-read` consumes JSON files listed in
`ookcite-ridley-item-json-files`. Each file can be a Ridley seed fixture with
an `items` array, a raw array of item records, or a single item object. PDF
paths are read from `attachmentPath` or asset extras such as `local_path`,
`path`, and `attachmentPath`.

The note shape matches the org-ref/org-noter flow:

```org
* TODO Paper Title :reading:ridley:
:PROPERTIES:
:Custom_ID: key2026
:ROAM_KEY: cite:key2026
:NOTER_DOCUMENT: /path/to/paper.pdf
:RIDLEY_ITEM_ID: 01...
:DOI: 10....
:END:
```

## Verification

```sh
make test
make compile
make checkdoc
make package-lint
```
