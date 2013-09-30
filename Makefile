################################################################################
#                              Ocamlbuild Invokation                           #
################################################################################

OCAMLBUILD := ocamlbuild
OCAMLBUILD := $(OCAMLBUILD) -no-links
OCAMLBUILD := $(OCAMLBUILD) -I source
OCAMLBUILD := $(OCAMLBUILD) -tag annot

################################################################################
#                             Targets for Ocamlbuild                           #
################################################################################

BYTE = source/procord.cma
NATIVE = source/procord.cmxa
DOC = documentation/procord.docdir/index.html
TESTS = test/test.byte

################################################################################

all:
	$(OCAMLBUILD) $(BYTE) $(NATIVE) $(DOC)
	ln -sf _build/$(DOC) documentation.html

byte:
	$(OCAMLBUILD) $(BYTE)

native:
	$(OCAMLBUILD) $(NATIVE)

doc:
	$(OCAMLBUILD) $(DOC)
	ln -sf _build/$(DOC) documentation.html

################################################################################

ALL_TESTS = $(TESTS) $(TESTS:.byte=.native)

test:
	$(OCAMLBUILD) -lib unix $(ALL_TESTS)

test.byte:
	$(OCAMLBUILD) -lib unix $(TESTS)

test.native:
	$(OCAMLBUILD) -lib unix $(TESTS:.byte=.native)

test.exec:
	$(OCAMLBUILD) -lib unix $(ALL_TESTS)
	for i in $(ALL_TESTS); do _build/$$i; done
	@echo "Now run $(ALL_TESTS) using --client and --server options."

################################################################################
#                                  Other Rules                                 #
################################################################################

%:
	$(OCAMLBUILD) $*

%.exec %.byte.exec:
	$(OCAMLBUILD) $*.byte --

%.native.exec:
	$(OCAMLBUILD) $*.native.byte --

clean:
	rm -rf _build documentation.html

wc:
	ocamlwc source/*.ml source/*.mli

################################################################################

.PHONY: all byte native doc test test.byte test.native test.exec clean wc
