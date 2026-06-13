EMACS ?= emacs

.PHONY: check test compile package-lint checkdoc clean

check: test compile checkdoc

test:
	$(EMACS) -Q --batch -L . -l test/ookcite-test.el -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch -L . -f batch-byte-compile ookcite.el

package-lint:
	$(EMACS) -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (require 'package-lint) (package-lint-batch-and-exit))" ookcite.el

checkdoc:
	$(EMACS) -Q --batch -L . --eval "(progn (require 'checkdoc) (checkdoc-file \"ookcite.el\"))"

clean:
	$(RM) *.elc
