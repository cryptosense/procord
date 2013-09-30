(******************************************************************************)
(*                                Worker Tasks                                *)
(******************************************************************************)

type ('a, 'b) worker_task =
  {
    read_input: string -> 'a;
    write_output: 'b -> string;
    write_exception: exn -> string;
    run: 'a -> 'b;
    w_name: string;
  }

(* Default behavior for [write_exception] is to raise its argument.
   It will be caught by the worker main function and will be sent as a
   [Worker_unknown_exception] using [Printexc]. *)
let make_worker_task
    ?(read_input = fun buf -> Marshal.from_string buf 0)
    ?(write_output = fun value -> Marshal.to_string value [])
    ?(write_exception = raise)
    w_name run =
  {
    read_input;
    write_output;
    write_exception;
    run;
    w_name;
  }

let read_input task =
  task.read_input

let write_output task =
  task.write_output

let write_exception task =
  task.write_exception

let run task =
  task.run

let worker_task_name task =
  task.w_name

(******************************************************************************)
(*                               Delegated Tasks                              *)
(******************************************************************************)

type ('a, 'b) delegated_task =
  {
    write_input: 'a -> string;
    read_output: string -> 'b;
    read_exception: (string -> exn) option;
    d_name: string;
  }

let make_delegated_task
    ?(write_input = fun value -> Marshal.to_string value [])
    ?(read_output = fun buf -> Marshal.from_string buf 0)
    ?read_exception
    d_name =
  {
    write_input;
    read_output;
    read_exception;
    d_name;
  }

let write_input task =
  task.write_input

let read_output task =
  task.read_output

let read_exception task =
  task.read_exception

let delegated_task_name task =
  task.d_name

(******************************************************************************)
(*                                  Task Pairs                                *)
(******************************************************************************)

let make
    ?read_input ?write_input
    ?read_output ?write_output
    ?read_exception ?write_exception
    name run =
  make_worker_task ?read_input ?write_output ?write_exception name run,
  make_delegated_task ?write_input ?read_output ?read_exception name
