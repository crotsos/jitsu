PACKAGES=-package lwt.syntax,lwt,dns.lwt,libvirt,cmdliner,ezxmlm,ipaddr,str,conduit,conduit.lwt-unix,xen-api-client
INCLUDE=
OPT=-linkpkg -g 
OCAMLOPT=ocamlopt -w A-4-44
FILES=synjitsu.mli synjitsu.ml jitsu.mli jitsu.ml main.ml
PWD=$(shell pwd)
SRC=$(PWD)/src
BIN=$(PWD)/bin
INSTALLDIR=/usr/local/bin

all: $(BIN)/jitsu

$(BIN)/jitsu: $(SRC)/jitsu.ml $(SRC)/main.ml $(SRC)/synjitsu.ml
	mkdir -p $(BIN)
	cd $(SRC) ; ocamlfind $(OCAMLOPT) $(INCLUDE) $(PACKAGES) $(OPT) $(FILES) -o $(BIN)/jitsu -syntax camlp4o

install: $(BIN)/jitsu
	@echo "Installing jitsu in $(INSTALLDIR)..."
	install -s $(BIN)/jitsu $(INSTALLDIR)/jitsu

clean:
	cd $(SRC) ; rm -f jitsu jitsu.cmx jitsu.cmi jitsu.o 
	cd $(SRC) ; rm -f main.o main.cmx main.cmi 
	cd $(SRC) ; rm -f synjitsu.o synjitsu.cmx synjitsu.cmi
	cd $(SRC) ; rm -f *~ tags
	cd $(BIN) ; rm -f jitsu
