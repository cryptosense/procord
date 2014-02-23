(* Example showing how to print to the main program's stdout and stderr.

   To ensure workers communicate correctly with the main program,
   workers should not print to stdout directly. Instead, they should print to
   [Format.std_formatter], for instance using [Format.printf].
   [Format.err_formatter] is also redirected.
   See the documentation of [Procord_worker] for more information.

   If you want the worker to print something on its own terminal, you can
   print to [stderr]. *)

(* Compile:
     ocamlfind ocamlc -package procord -linkpkg redirect.ml -o redirect
   then run:
     ./redirect --procord-server
   and, in another terminal:
     ./redirect --procord-hostname localhost
   The text that the worker outputs will not appear in the worker terminal
   but in the main program terminal. *)

(* function that we want to run in another process. *)
let rec fibo x =
  (* Print something in the main program's standard output. *)
  Format.printf "Working on fibo %d.\n%!" x;

  (* Sleep a bit, to show that the output was flushed. *)
  Unix.sleep 1;

  (* Compute the result. *)
  let result = if x <= 1 then 1 else fibo (x - 1) + fibo (x - 2) in

  (* Print the result in the main program's standard output. *)
  Format.printf "Computed fibo %d = %d.\n%!" x result;

  (* Return the result. *)
  result

(* Let's define a task for our function. *)
let fibo_worker, fibo_delegated =
  Procord_task.make "fibo" fibo

(* Entry point. *)
let () =
  (* [Procord_worker.run] will take care of the redirection for us. *)
  Procord_worker.run [ Procord_worker.task fibo_worker ];

  (* Start a process and wait for the result. *)
  let process = Procord_process.delegate fibo_delegated 10 in
  let result = Procord_process.run process in
  Printf.printf "Final result: %d\n%!" result
