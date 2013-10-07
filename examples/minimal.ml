(* Minimal example. *)

(* Compile:
     ocamlfind ocamlc -package procord -linkpkg minimal.ml -o minimal
   then run:
     ./minimal *)

(* First, let's write the function that we want to run in another process. *)
let rec fibo x =
  if x <= 1 then 1 else fibo (x - 1) + fibo (x - 2)

(* Let's define a task for our function.

   [fibo_worker] is for the worker process, [fibo_delegated] is for the
   main program. *)
let fibo_worker, fibo_delegated =
  Procord_task.make "fibo" fibo

let process input =
  Procord_process.delegate fibo_delegated input

(* Entry point. *)
let () =
  (* We want our program to be able to act both as a worker (local or distant)
     and as the main program. The easiest way to achieve this is to call
     [Procord_worker.run].

     [Procord_worker.run] reads command-line arguments.
     If [--procord-worker] or [--procord-server] is given,
     [Procord_worker.run] starts the worker and never returns.
     Else, [Procord_worker.run] returns immediately. *)
  Procord_worker.run [ Procord_worker.task fibo_worker ];

  (* If we are past [Procord_worker.run] then it means we are the main program.
     We start a process which will run in parallel to compute [fibo 10]. *)
  let process = Procord_process.delegate fibo_delegated 10 in

  (* We wait for the result. *)
  let result = Procord_process.run process in

  (* Finally, we print the result. *)
  Printf.printf "%d\n%!" result

(* You can experiment with the command-line options:
     ./minimal --help
   Try to run a server:
     ./minimal --procord-server
   and connect to it:
     ./minimal --procord-hostname localhost *)
