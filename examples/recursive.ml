(* Example which uses Procord recursively: workers spawn workers themselves.

   The workers spawn workers using Unix.create_process even if the workers
   are in the server mode, but this can be changed by using the specialized
   delegation fonction [Procord_process.delegate_task_socket] instead
   of [Procord_process.delegate].

   The main difficulty is to define, recursively, a function and
   its own task. This is not possible directly because of the value
   restriction. *)

(* Compile:
     ocamlfind ocamlc -package procord -linkpkg recursive.ml -o recursive
   then run:
     ./recursive *)

(* This reference will be set later to the delegated task. *)
let fibo_delegated_ref = ref None

(* Retrieve the contents of [fibo_delegated]. *)
let get_fibo_delegated () =
  match !fibo_delegated_ref with
    | None ->
        failwith "get_fibo_delegated: fibo_delegated is not initialized"
    | Some fibo_delegated ->
        fibo_delegated

(* First, let's write the function that we want to run in another process. *)
let rec fibo x =
  let fibo_delegated = get_fibo_delegated () in

  if x <= 1 then
    1
  else
    (* Start two sub-processes. *)
    let process1 = Procord_process.delegate fibo_delegated (x - 1) in
    let process2 = Procord_process.delegate fibo_delegated (x - 2) in

    (* If you want to observe the process tree using pstree, you may slow down
       the computation by uncommenting the following line.
       Note that this causes a delay before the input data is sent to the
       sub-processes, and they wont create their own sub-processes before
       they receive their input values. *)
    (* Unix.sleep 1; *)

    (* Build a waiter. *)
    let waiter1 = Procord_process.waiter process1 in
    let waiter2 = Procord_process.waiter process2 in
    let waiter = Procord_connection.waiter_of_list [ waiter1; waiter2 ] in

    (* Wait for the two sub-processes to finish. *)
    let rec wait () =
      (* We apply the WUS methodology (Wait, Update, Status).
         In future versions, this could be simplified thanks to a
         [Procord_lwt] or [Procord_async] module, or thanks to a
         [Procord_process.run_list] function. This would also remove the
         need to build the waiter manually. *)
      let (_: bool) = Procord_connection.wait waiter in
      Procord_process.update process1;
      Procord_process.update process2;
      match
        Procord_process.status process1,
        Procord_process.status process2
      with
        | Procord_process.Working, _ | _, Procord_process.Working ->
            (* One of the sub-process is still working.
               We need to continue waiting. *)
            wait ()
        | _ ->
            (* Stop waiting. *)
            ()
    in

    (* Retreive the results. *)
    let result1 = Procord_process.run process1 in
    let result2 = Procord_process.run process2 in

    (* Return the sum of the results. *)
    result1 + result2

(* Define a task for our function. *)
let fibo_worker, fibo_delegated =
  Procord_task.make "fibo" fibo

(* Fill the reference to the delegated task. *)
let () =
  fibo_delegated_ref := Some fibo_delegated

(* Entry point. It is a copy-paste of minimal.ml. *)
let () =
  Procord_worker.run [ Procord_worker.task fibo_worker ];
  let process = Procord_process.delegate fibo_delegated 10 in
  let result = Procord_process.run process in
  Printf.printf "%d\n%!" result
