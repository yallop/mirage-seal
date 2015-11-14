(*
 * Copyright (c) 2015 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Cmdliner
open Printf

let (/) = Filename.concat

let err fmt = ksprintf failwith fmt
let cmd fmt =
  ksprintf (fun str ->
      printf "=> %s\n%!" str;
      let i = Sys.command str in
      if i <> 0 then err "%s: failed with exit code %d." str i
    ) fmt

let verbose =
  let doc = Arg.info ~doc:"Be more verbose." ["v";"verbose"] in
  Arg.(value & flag & doc)

let data =
  let doc =
    Arg.info ~docv:"DIR" ["d"; "data"]
      ~doc:"Location of the local directory containing the data to seal."
  in
  Arg.(required & opt (some string) None & doc)

let keys =
  let doc =
    Arg.info ~docv:"DIR" ["k";"keys"]
      ~doc:"Location of the private keys (server.pem and server.key) to sign \
            the sealing."
  in
  Arg.(value & opt (some string) None & doc)

let no_tls =
  let doc =
    Arg.info ["no-tls"]
      ~doc:"Do not use TLS and serve the static files over HTTP only."
  in
  Arg.(value & flag & doc)

let mode =
  let doc =
    Arg.info ~docv:"MODE" ["t";"target"]
      ~doc:"Target platform to compile the unikernel for. Valid values are: \
            $(i,xen), $(i,unix), $(i,macosx), $(i,rumprun)."
  in
  Arg.(value & opt (some string) None & doc)

let ip_address =
  let doc =
    Arg.info ~docv:"IP" ["ip"] ~doc:"IP address of the seal unikernel."
  in
  Arg.(value & opt (some string) None & doc)

let ip_netmask =
  let doc =
    Arg.info ~docv:"IP" ["nm"] ~doc:"IP netmask of the seal unikernel."
  in
  Arg.(value & opt (some string) None & doc)

let ip_gateway =
  let doc =
    Arg.info ~docv:"IP" ["gw"] ~doc:"IP gateway of the seal unikernel."
  in
  Arg.(value & opt (some string) None & doc)

let sockets =
  let doc = Arg.info ~doc:"Use the kernel TCP/IP network stack." ["sockets"] in
  Arg.(value & flag & doc)

let output_static ~dir name =
  match Static.read name with
  | None   -> err "%s: file not found" name
  | Some f ->
    let oc = open_out (dir / name) in
    output_string oc f;
    close_out oc

let copy_file ~dst src =
  if Sys.file_exists src && not (Sys.is_directory src) &&
     Sys.file_exists dst && Sys.is_directory dst then
    cmd "cp %s %s" src dst
  else
    err "copy-file: %s is not a valid directory" dst

let copy_dir ~dst src =
  if Sys.file_exists src && Sys.is_directory src &&
     not (Sys.file_exists dst) then
    cmd "cp -r %s %s" src dst
  else
    err "copy-dir: %s is not a valid directory" dst

(* FIXME: proper real-path *)
let realpath dir =
  if Filename.is_relative dir then Sys.getcwd () / dir else dir

let rmdir dir = cmd "rm -rf %s" dir

let mkdir dir =
  if not (Sys.file_exists dir) then cmd "mkdir -p %s" dir
  else err "%s already exists." dir

let mirage_configure ~dir ~mode keys =
  let mode = match mode with
    | `Xen -> "-t xen"
    | `Unix -> "-t unix"
    | `MacOSX -> "-t macosx"
    | `Rumprun -> "-t rumprun"
  in
  let keys =
    List.map (fun (k,v) -> sprintf "SEAL_%s=%s" k v) keys
    |> String.concat " "
  in
  cmd "cd %s && %s mirage configure %s" dir keys mode

let seal verbose seal_data seal_keys mode ip_address ip_netmask ip_gateway
    sockets no_tls =
  if verbose then Log.set_log_level Log.DEBUG;
  let mode = match sockets, mode with
    | true, None -> `Unix
    | false, (None | Some "xen") -> `Xen
    | _, Some "unix" -> `Unix
    | _, Some "macosx" -> `MacOSX
    | _, Some "rumprun" -> `Rumprun
    | _, Some m -> err "%s is not a valid mirage target" m
  in
  let dhcp =
    not sockets && ip_address = None && ip_netmask = None && ip_gateway = None
  in
  let ip_address = match sockets, dhcp, ip_address with
    | false, false, Some ip -> ["ADDRESS", ip]
    | _ -> []
  in
  let ip_netmask = match sockets, dhcp, ip_netmask with
    | false, false, Some ip -> ["NETMASK", ip]
    | _ -> []
  in
  let ip_gateway = match sockets, dhcp, ip_gateway with
    | false, false, Some ip -> ["GATEWAY", ip]
    | _ -> []
  in
  let net = match sockets with
    | true  -> ["NET", "socket"]
    | false -> []
  in
  let exec_dir = Filename.get_temp_dir_name () / "mirage-seal" in
  let tls_dir = exec_dir / "keys" / "tls" in
  rmdir exec_dir;
  mkdir exec_dir;
  mkdir tls_dir;
  printf "exec-dir: %s\n%!" exec_dir;
  let seal_data = realpath seal_data in
  output_static ~dir:exec_dir "https_dispatch.ml";
  output_static ~dir:exec_dir "dispatch.ml";
  output_static ~dir:exec_dir "config.ml";
  let () = match no_tls, seal_keys with
    | true , None   -> ()
    | false, None   -> err "Need either --no-tls or -k <path-to-secrets>"
    | true , Some d -> err "You cannot use -k and --no-tls simultaneously"
    | false, Some d ->
      copy_file (d / "server.pem") ~dst:tls_dir;
      copy_file (d / "server.key") ~dst:tls_dir;
  in
  let keys = match seal_keys with
    | None   -> ["HTTPS", "0"]
    | Some _ -> ["HTTPS", "1"; "KEYS", exec_dir / "keys"]
  in
  mirage_configure ~dir:exec_dir ~mode ([
      "DATA", seal_data;
      "DHCP", string_of_bool dhcp;
    ] @ ip_address @ ip_netmask @ ip_gateway @ net @ keys);
  cmd "cd %s && make" exec_dir;
  if mode = `Xen && not (Sys.file_exists "seal.xl") then
    output_static ~dir:(Sys.getcwd ()) "seal.xl";
  let exec_file = match mode with
    | `Unix | `MacOSX | `Rumprun -> exec_dir / "mir-seal"
    | `Xen -> exec_dir / "mir-seal.xen"
  in
  copy_file exec_file ~dst:(Sys.getcwd ());
  match mode with
  | `Unix | `MacOSX ->
    printf "\n\nTo run your sealed unikernel, use `sudo ./mir-seal`\n\n%!"
  | `Xen ->
    printf "\n\nTo run your sealed unikernel, use `sudo xl create seal.xl -c`\n\n%!"
  | `Rumprun ->
    printf "\n\nTo run your sealed unikernel, use `rumpbake` and `rumprun` on ./mir-seal as appropriate\n\n%!"

let cmd =
  let doc = "Seal a local directory into a Mirage unikernel." in
  let man = [
    `S "AUTHORS";
    `P "Thomas Gazagnaire   <thomas@gazagnaire.org>";

    `S "BUGS";
    `P "Check bug reports at https://github.com/samoht/mirage-seal/issues.";
  ] in
  Term.(pure seal $ verbose $ data $ keys $ mode
        $ ip_address $ ip_netmask $ ip_gateway $ sockets
        $ no_tls),
  Term.info "mirage-seal" ~version:Version.current ~doc ~man

let () = match Term.eval cmd with `Error _ -> exit 1 | _ -> exit 0
