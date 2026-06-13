EMACS ?= emacs
PACKAGE_USER_DIR ?=
PACKAGE_LINT_LOAD_PATH ?=

PACKAGE_USER_DIR_EVAL = $(if $(PACKAGE_USER_DIR),--eval "(setq package-user-dir \"$(PACKAGE_USER_DIR)\")")
PACKAGE_LINT_LOAD_FLAGS = $(foreach dir,$(PACKAGE_LINT_LOAD_PATH),-L $(dir))

.PHONY: check test compile package-lint package-lint-install checkdoc clean

check: test compile checkdoc

test:
	$(EMACS) -Q --batch -L . -l test/ookcite-test.el -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch -L . -f batch-byte-compile ookcite.el

package-lint:
	$(EMACS) -Q --batch $(PACKAGE_USER_DIR_EVAL) $(PACKAGE_LINT_LOAD_FLAGS) -L . --eval "(progn (require 'package) (package-initialize) (require 'package-lint) (package-lint-batch-and-exit))" ookcite.el

package-lint-install:
	$(EMACS) -Q --batch $(PACKAGE_USER_DIR_EVAL) --eval "(progn (require 'package) (add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t) (package-initialize) (package-refresh-contents) (unless (package-installed-p 'package-lint) (package-install 'package-lint)))"

checkdoc:
	$(EMACS) -Q --batch -L . --eval "(progn (require 'checkdoc) (checkdoc-file \"ookcite.el\"))"

clean:
	$(RM) *.elc
