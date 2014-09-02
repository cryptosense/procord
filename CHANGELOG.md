v0.2.0
------

- It is possible to redirect Format.std_formatter and
  Format.err_formatter from the worker to the main program. The goal
  is to be able to execute a worker as if it was in the context of the
  main program, or to be able to send custom messages.

- Added a synchronous interface to Procord_connection. This can be
  useful when using Procord not for parallel processing but as an
  abstraction over UNIX file descriptors.

- Added a function to read, from a connection, the timeout given to
  Procord_connection.connect or Procord_connection.custom.

- Added examples/recursive.ml.

- Waiting on a closed connection should no longer cause the program to
  freeze forever.

- Added new option --procord-dont-fork for server workers.
