procord
=======

Procord is a portable OCaml library to delegate tasks to other processes.

Prerequisites
-------------

To compile Procord, you only need the OCaml compiler.
Procord has been tested with OCaml 3.12.1 and OCaml 4.00.1.

You need ocamlfind (also called findlib) to use "make install".

Compiling and installing
------------------------

Just do:

    make
    make install

Uninstalling
------------

To uninstall Procord, run:

    make uninstall

Or, if you no longer have the source:

    ocamlfind remove procord

Documentation
-------------

There is a minimal, commented example to get you started in:

    examples/minimal.ml

You can browse the OCamlDoc documentation here:

http://cryptosense.github.io/procord/api/index.html

You can also generate the OCamlDoc documentation yourself using:

    make doc

You can then open documentation.html.
