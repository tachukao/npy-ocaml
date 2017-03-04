let verbose = false

(* Saves a npy file and reread it checking that the read content is identical. *)
let save_and_read (type a b) (array : (a, b, Bigarray.c_layout) Bigarray.Genarray.t) filename =
  Npy.write array filename;
  let Npy.P rarray = Npy.read_mmap filename ~shared:false in
  begin
    match Bigarray.Genarray.layout rarray with
    | Bigarray.Fortran_layout -> assert false
    | Bigarray.C_layout ->
      match Bigarray.Genarray.kind array, Bigarray.Genarray.kind rarray with
      | Bigarray.Float32, Bigarray.Float32 -> assert (array = rarray)
      | Bigarray.Float64, Bigarray.Float64 -> assert (array = rarray)
      | Bigarray.Int32, Bigarray.Int32 -> assert (array = rarray)
      | Bigarray.Int64, Bigarray.Int64 -> assert (array = rarray)
      | _ -> assert false
  end

(* Save a npy file using python and numpy. *)
let save_with_python (type a b) (array : (a, b, Bigarray.c_layout) Bigarray.Genarray.t) filename =
  let run array to_string dtype =
    let rec to_string_loop dim idxs =
      if dim = Bigarray.Genarray.num_dims array
      then Bigarray.Genarray.get array (List.rev idxs |> Array.of_list) |> to_string
      else
        Array.init
          (Bigarray.Genarray.nth_dim array dim)
          (fun i -> to_string_loop (dim + 1) (i :: idxs))
        |> Array.to_list
        |> String.concat ", "
        |> Printf.sprintf "[ %s ]"
    in
    let cmd =
      Printf.sprintf
        "python -c 'import numpy as np\n\
                    arr = np.array(%s)\n\
                    np.save(\"%s\", arr.astype(\"%s\"))'"
        (to_string_loop 0 [])
        filename
        dtype
    in
    if verbose
    then Printf.printf "Running: %s\n\n%!" cmd;
    assert (Unix.system cmd = WEXITED 0)
  in
  match Bigarray.Genarray.kind array with
  | Bigarray.Float32 -> run array string_of_float "f4"
  | Bigarray.Float64 -> run array string_of_float "f8"
  | Bigarray.Int32 -> run array Int32.to_string "i4"
  | Bigarray.Int64 -> run array Int64.to_string "i8"
  | _ -> assert false

let load_and_save_using_python input_filename output_filename =
  let cmd =
    Printf.sprintf
      "python -c 'import numpy as np\n\
                  arr = np.load(\"%s\")\n\
                  np.save(\"%s\", arr)'"
      input_filename
      output_filename
  in
  if verbose
  then Printf.printf "Running: %s\n\n%!" cmd;
  assert (Unix.system cmd = WEXITED 0)

let batch_count = 5
(* - Save a npy file using the library.
   - Load the npy file, check that the content is identical to the input.
   - Save the npy file using python and numpy.
   - Check that the two npy files have the same md5 sum.
*)
let run_test
      ?(python_save = true)
      (type a b)
      (array : (a, b, Bigarray.c_layout) Bigarray.Genarray.t)
      filename
  =
  save_and_read array filename;
  let md5 = Digest.file filename in
  if python_save
  then begin
    let python_filename = "p" ^ filename in
    save_with_python array python_filename;
    let md5p = Digest.file python_filename in
    if verbose
    then Printf.printf "%s %s %s\n%!" filename (Digest.to_hex md5) (Digest.to_hex md5p);
    assert (md5 = md5p);
  end;
  let batch_filename = "b" ^ filename in
  let total_len = Bigarray.Genarray.nth_dim array 0 in
  let batch_writer = Npy.Batch_writer.create batch_filename in
  let batch_size = 1 + total_len / batch_count in
  for batch_idx = 0 to batch_count - 1 do
    let start_idx = batch_size * batch_idx in
    let batch_size = min total_len ((batch_idx + 1)*batch_size) - start_idx in
    if batch_size > 0
    then
      let lines = Bigarray.Genarray.sub_left array start_idx batch_size in
      Npy.Batch_writer.append batch_writer lines
  done;
  Npy.Batch_writer.close batch_writer;
  let batchp_filename = "bp" ^ filename in
  load_and_save_using_python batch_filename batchp_filename;
  let md5b = Digest.file batchp_filename in
  if verbose
  then Printf.printf "%s %s %s\n%!" filename (Digest.to_hex md5) (Digest.to_hex md5b);
  assert (md5 = md5b)

let array2_test ?python_save (type a) (kind : (a, _) Bigarray.kind) (random : unit -> a) filename ~dim1 ~dim2 =
  let bigarray =
    Bigarray.Array2.create
      kind
      C_layout
      dim1
      dim2
  in
  for idx1 = 0 to dim1 - 1 do
    for idx2 = 0 to dim2 - 1 do
      Bigarray.Array2.set bigarray idx1 idx2 (random ())
    done;
  done;
  run_test ?python_save (Bigarray.genarray_of_array2 bigarray) filename

let to_array1 bigarray =
  match Bigarray.Genarray.dims bigarray with
  | [| n |] -> Array.init n (fun i -> Bigarray.Genarray.get bigarray [| i |])
  | _ -> assert false

let to_array2 bigarray =
  match Bigarray.Genarray.dims bigarray with
  | [| n; m |] ->
    Array.init n (fun i ->
      Array.init m (fun j -> Bigarray.Genarray.get bigarray [| i; j |]))
  | _ -> assert false

let npz_test () =
  let npz = Npy.Npz.create "test.npz" in
  let Npy.P array1 = Npy.Npz.read_copy npz "test1.npy" in
  let Npy.P array2 = Npy.Npz.read_copy npz "test2.npy" in
  begin
    match Bigarray.Genarray.kind array1 with
    | Bigarray.Float32 ->
      let array1 = to_array1 array1 in
      assert (array1 = [| 1.; 2.; 3. |]);
    | _ -> assert false
  end;
  begin
    match Bigarray.Genarray.kind array2 with
    | Bigarray.Float32 ->
      let array2 = to_array2 array2 in
      assert (array2 = [| [| 4.; 5.; 6. |]; [| 7.; 8.; 9. |] |]);
    | _ -> assert false
  end;
  Npy.Npz.close npz

let () =
  Random.init 42;
  let random_float () = Random.float 1e9 |> floor in
  let random_int32 () = Int32.sub (Random.int32 2_000_000l) 1_000_000l in
  let random_int64 () =
    Int64.sub (Random.int64 2_000_000_000_000_000L) 1_000_000_000_000_000L
  in
  array2_test Float32 random_float "test_g.npy" ~dim1:2 ~dim2:3;
  array2_test Float64 random_float "test_g.npy" ~dim1:8 ~dim2:21;
  array2_test Int32 random_int32 "test_g.npy" ~dim1:7 ~dim2:4;
  array2_test Int64 random_int64 "test_g.npy" ~dim1:8 ~dim2:21;
  array2_test ~python_save:false Float64 random_float "test_g.npy"
    ~dim1:65536 ~dim2:512;
  npz_test ()
