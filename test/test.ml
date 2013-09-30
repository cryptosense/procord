(* Test [delegate_task_create_process], called on ourself. *)

open Arg

let rec fibo x =
  if x < 0 then
    invalid_arg "fibo: negative argument"
  else if x <= 1 then
    1
  else
    fibo (x - 1) + fibo (x - 2)

let rec fact x =
  if x < 0 then
    invalid_arg "fact: negative argument"
  else if x <= 0 then
    1
  else
    x * fact (x - 1)

(* We use the default (marshaling) for fibo, and custom serializing
   functions for fact. *)

let fibo_worker, fibo_delegated =
  Procord_task.make "fibo" fibo

let fact_worker, fact_delegated =
  Procord_task.make
    ~read_input: int_of_string
    ~write_input: string_of_int
    ~read_output: int_of_string
    ~write_output: string_of_int
    ~read_exception: (fun str -> Failure str)
    ~write_exception: Printexc.to_string
    "fact" fact

(* Main program, if we are not a worker. *)
let main () =
  (* Our test function runs a task and checks the output. *)
  let test task input expected_output =
    Printf.printf "Running task %S on input %d...%!"
      (Procord_task.delegated_task_name task) input;
    let process = Procord_process.delegate task input in
    Printf.printf " Running...%!";
    try
      let output = Procord_process.run process in
      if output = expected_output then
        Printf.printf " Result: %d\n%!" output
      else
        Printf.printf " Result: %d (unexpected)\n%!" output
    with
      | e ->
          Printf.printf " Exception: %s\n%!" (Printexc.to_string e)
  in

  (* Perform some tests on fibo. *)
  test fibo_delegated 0 1;
  test fibo_delegated 1 1;
  test fibo_delegated 2 2;
  test fibo_delegated 3 3;
  test fibo_delegated 4 5;
  test fibo_delegated 5 8;
  test fibo_delegated (-1) (-1); (* Shall raise an exception. *)

  (* Perform some tests on fact. *)
  test fact_delegated 0 1;
  test fact_delegated 1 1;
  test fact_delegated 2 2;
  test fact_delegated 3 6;
  test fact_delegated 4 24;
  test fact_delegated 5 120;
  test fact_delegated (-1) (-1); (* Shall raise an exception. *)

  (* Done. *)
  print_endline "Done."

(* Set a printer for UNIX errors. *)
let () =
  Printexc.register_printer
    begin function
      | Unix.Unix_error (error, function_name, string_argument) ->
          Some
            (Printf.sprintf "%s (in Unix.%s, %S)"
               (Unix.error_message error) function_name string_argument)
      | _ ->
          None
    end

(* Entry point. *)
let () =
  try
    (* Just a precaution against DDoS. *)
    Procord_protocol.set_max_message_size 100;

    (* If we are a worker, run as a worker and exit. Else, just parse the
       command-line arguments. *)
    Procord_worker.run
      [
        Procord_worker.task fibo_worker;
        Procord_worker.task fact_worker;
      ];

    (* If we are here, then we are not a worker, we are the main program. *)
    main ()
  with e ->
      prerr_endline (Printexc.to_string e)
