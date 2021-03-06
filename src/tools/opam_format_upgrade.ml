(**************************************************************************)
(*                                                                        *)
(*    Copyright 2016 OCamlPro                                             *)
(*                                                                        *)
(*  All rights reserved. This file is distributed under the terms of the  *)
(*  GNU Lesser General Public License version 2.1, with the special       *)
(*  exception on linking described in the file LICENSE.                   *)
(*                                                                        *)
(**************************************************************************)

open OpamTypes
open OpamProcess.Job.Op
open OpamStd.Option.Op

module O = OpamFile.OPAM

type args = {
  clear_cache: bool;
}

let args =
  let open Cmdliner in
  let clear_cache =
    let doc = "Remove the cache of compiler archive hashes" in
    Arg.(value & flag & info ["clear-cache"] ~doc)
  in
  Term.(pure (fun clear_cache -> { clear_cache; }) $ clear_cache)


let ocaml_pkgname = OpamPackage.Name.of_string "ocaml"

let ocaml_wrapper_pkgname = OpamPackage.Name.of_string "ocaml"
let ocaml_official_pkgname = OpamPackage.Name.of_string "ocaml-base-compiler"
let ocaml_variants_pkgname = OpamPackage.Name.of_string "ocaml-variants"
let ocaml_system_pkgname = OpamPackage.Name.of_string "ocaml-system"

let ocaml_package_names =
  [ocaml_wrapper_pkgname;
   ocaml_official_pkgname;
   ocaml_variants_pkgname;
   ocaml_system_pkgname]

(* OCaml script that generates the .config file for a given ocaml compiler *)
let wrapper_conf_script =
  "let () =\n\
  \  let ocaml_version =\n\
  \    let v = Sys.ocaml_version in\n\
  \    try String.sub v 0 (String.index v '+') with Not_found -> v\n\
  \  in\n\
  \  if ocaml_version <> \"%{_:version}%\" then\n\
  \    (Printf.eprintf\n\
  \       \"OCaml version mismatch: %%s, expected %{_:version}%\"\n\
  \       ocaml_version;\n\
  \     exit 1)\n\
  \  else\n\
  \  let oc = open_out \"%{_:name}%.config\" in\n\
  \  let ocaml = Sys.executable_name in\n\
  \  let ocamlc = ocaml^\"c\" in\n\
  \  let libdir =\n\
  \    let ic = Unix.open_process_in (ocamlc^\" -where\") in\n\
  \    let r = input_line ic in\n\
  \    if Unix.close_process_in ic <> Unix.WEXITED 0 then \n\
  \      failwith \"Bad return from 'ocamlc -where'\";\n\
  \    r\n\
  \  in\n\
  \  let stubsdir =\n\
  \    let ic = open_in (Filename.concat libdir \"ld.conf\") in\n\
  \    let rec r acc = try r (input_line ic::acc) with End_of_file -> acc in\n\
  \    let lines = List.rev (r []) in\n\
  \    close_in ic;\n\
  \    String.concat \":\" lines\n\
  \  in\n\
  \  let p fmt = Printf.fprintf oc (fmt ^^ \"\\n\") in\n\
  \  p \"opam-version: \\\"2.0\\\"\";\n\
  \  p \"variables {\";\n\
  \  p \"  native: %%b\"\n\
  \    (Sys.file_exists (ocaml^\"opt\"));\n\
  \  p \"  native-tools: %%b\"\n\
  \    (Sys.file_exists (ocamlc^\".opt\"));\n\
  \  p \"  native-dynlink: %%b\"\n\
  \    (Sys.file_exists (Filename.concat libdir \"dynlink.cmxa\"));\n\
  \  p \"  stubsdir: %%S\"\n\
  \    stubsdir;\n\
  \  p \"}\";\n\
  \  close_out oc\n\
  "

let system_conf_script =
  "let () =\n\
  \  let ocamlc = Sys.executable_name ^ \"c\" in\n\
  \  if Sys.ocaml_version <> \"%{_:version}%\" then\n\
  \    (Printf.eprintf\n\
  \       \"ERROR: The compiler found at %%s has version %%s,\\n\\\n\
  \        and this package requires %{_:version}%.\\n\\\n\
  \        You should use e.g. 'opam switch %{_:name}%.%%s' \\\n\
  \        instead.\"\n\
  \       ocamlc Sys.ocaml_version Sys.ocaml_version;\n\
  \     exit 1)\n\
  \  else\n\
  \  let oc = open_out \"%{_:name}%.config\" in\n\
  \  Printf.fprintf oc \"opam-version: \\\"2.0\\\"\\n\\\n\
  \                     file-depends: [ %%S %%S ]\\n\\\n\
  \                     variables { path: %%S }\\n\"\n\
  \    ocamlc (Digest.to_hex (Digest.file ocamlc)) (Filename.dirname ocamlc);\n\
  \  close_out oc\n\
  "

let conf_script_name = "gen_ocaml_config.ml"

let all_base_packages =
  OpamPackage.Name.Set.of_list (List.map OpamPackage.Name.of_string [
      "base-bigarray";
      "base-threads";
      "base-unix";
    ])

let process args =

  let cache_file : string list list OpamFile.t =
    OpamFile.make @@
    OpamFilename.of_string "~/.cache/opam-compilers-to-packages/url-hashes"
  in

  if args.clear_cache then
    OpamFilename.remove (OpamFile.filename cache_file)
  else

  let repo = OpamRepositoryBackend.local (OpamFilename.cwd ()) in

  let write_opam ?(add_files=[]) opam =
    let nv = O.package opam in
    let pfx = Some (OpamPackage.name_to_string nv) in
    let files_dir = OpamRepositoryPath.files repo pfx nv in
    O.write (OpamRepositoryPath.opam repo pfx nv) opam;
    List.iter (fun (base,contents) ->
        OpamFilename.(write Op.(files_dir // base) contents))
      add_files
  in

  let compilers =
    let compilers_dir = OpamFilename.Op.(repo.repo_root / "compilers") in
    if OpamFilename.exists_dir compilers_dir then (
      List.fold_left (fun map f ->
          if OpamFilename.check_suffix f ".comp" then
            let c = OpamFilename.(Base.to_string (basename (chop_extension f))) in
            OpamStd.String.Map.add c f map
          else
            map)
        OpamStd.String.Map.empty (OpamFilename.rec_files compilers_dir)
    ) else
      OpamStd.String.Map.empty
  in

  let ocaml_versions =
    OpamStd.String.Map.fold (fun c comp_file ocaml_versions ->
      let comp = OpamFile.Comp.read (OpamFile.make comp_file) in
      let descr_file =
        OpamFilename.(opt_file (add_extension (chop_extension comp_file) "descr"))
      in
      let descr = descr_file >>| fun f -> OpamFile.Descr.read (OpamFile.make f) in
      let comp =
        let drop_names = [ OpamPackage.Name.of_string "base-ocamlbuild" ] in
        (* ocamlbuild has requirements on variable ocaml-version: it can't be in
           the dependencies *)
        OpamFile.Comp.with_packages
          (OpamFormula.map
             (fun ((name, _) as atom) ->
                if List.mem name drop_names then OpamFormula.Empty
                else Atom atom)
             (OpamFile.Comp.packages comp))
          comp
      in

      let nv, ocaml_version, variant =
        match OpamStd.String.cut_at c '+' with
        | None ->
          OpamPackage.create ocaml_official_pkgname
            (OpamPackage.Version.of_string c),
          c, None
        | Some (version,variant) ->
          OpamPackage.create ocaml_variants_pkgname
            (OpamPackage.Version.of_string (version^"+"^variant)),
          version, Some variant
      in

      (* (Some exotic compiler variants have e.g. 'lwt' as base package, which
         won't work in our current setup. They'll need to be rewritten, but
         break the following detection of all base packages, which isn't
         idempotent anyway...)

         List.iter (fun (name, _) ->
             all_base_packages := OpamPackage.Name.Set.add name !all_base_packages)
           (OpamFormula.atoms (OpamFile.Comp.packages comp));
      *)

      let opam = OpamFile.Comp.to_package ~package:nv comp descr in
      let opam =
        if variant = None then
          opam |>
          O.with_conflicts (OpamFormula.ors [
              Atom (ocaml_system_pkgname, Empty);
              Atom (ocaml_variants_pkgname, Empty);
            ])
        else opam
      in
      let patches = OpamFile.Comp.patches comp in
      if patches <> [] then
        OpamConsole.msg "Fetching patches of %s to check their checksums...\n"
          (OpamPackage.to_string nv);
      let url_md5 =
        (OpamFile.Lines.read_opt cache_file +! [] |> List.map @@ function
          | [url; md5] -> OpamUrl.of_string url, md5
          | _ -> failwith "Bad cache") |>
        OpamUrl.Map.of_list
      in
      let extra_sources =
        (* Download them just to get their mandatory MD5 *)
        OpamParallel.map
          ~jobs:3
          ~command:(fun url ->
              try Done (Some (url, OpamUrl.Map.find url url_md5, None))
              with Not_found ->
                let err e =
                  OpamConsole.error
                    "Could not get patch file for %s from %s (%s), skipping"
                    (OpamPackage.to_string nv) (OpamUrl.to_string url)
                    (Printexc.to_string e);
                  Done None
                in
                OpamFilename.with_tmp_dir_job @@ fun dir ->
                try
                  OpamProcess.Job.catch err
                    (OpamDownload.download ~overwrite:false url dir @@| fun f ->
                     Some (url, OpamFilename.digest f, None))
                with e -> err e)
          (OpamFile.Comp.patches comp)
      in
      List.fold_left
        (fun url_md5 -> function
           | Some (url,md5,_) -> OpamUrl.Map.add url md5 url_md5
           | None -> url_md5)
        url_md5 extra_sources |>
      OpamUrl.Map.bindings |>
      List.map (fun (url,m) -> [OpamUrl.to_string url; m]) |>
      OpamFile.Lines.write cache_file;
      if List.mem None extra_sources then ocaml_versions
      else
      let opam =
        opam |>
        OpamFile.OPAM.with_extra_sources
          (OpamStd.List.filter_some extra_sources)
      in
      write_opam opam;

      if variant = None then begin
        (* "official" compiler release: generate a system compiler package *)
        let sys_nv = OpamPackage.create ocaml_system_pkgname nv.version in
        let system_opam =
          O.create sys_nv |>
          O.with_substs [OpamFilename.Base.of_string conf_script_name] |>
          O.with_build [
            List.map (fun s -> CString s, None)
              [ "ocaml"; conf_script_name ],
            None
          ] |>
          O.with_conflicts (OpamFormula.ors [
              Atom (ocaml_official_pkgname, Empty);
              Atom (ocaml_variants_pkgname, Empty);
            ]) |>
          O.with_maintainer [ "platform@lists.ocaml.org" ] |>
          O.with_flags [Pkgflag_Compiler] |>
          O.with_descr
            (OpamFile.Descr.create
                 "The OCaml compiler (system version, from outside of opam)") |>
          O.with_available
            (FOp (FIdent ([],OpamVariable.of_string "sys-ocaml-version",None),
                  `Eq,
                  FString (OpamPackage.Version.to_string nv.version)))
            (* add depext towards an 'ocaml' package ? *)
        in
        write_opam ~add_files:[conf_script_name^".in", system_conf_script]
          system_opam
      end;

      (* cleanup *)
      OpamFilename.remove comp_file;
      OpamStd.Option.iter OpamFilename.remove descr_file;
      OpamFilename.rmdir_cleanup (OpamFilename.dirname comp_file);
      OpamConsole.status_line
        "Compiler %s successfully converted to package %s"
        c (OpamPackage.to_string nv);
      OpamStd.String.Set.add ocaml_version ocaml_versions
      )
    compilers OpamStd.String.Set.empty
  in

  (* Generate "ocaml" package wrappers depending on one of the implementations
     at the appropriate version *)
  let gen_ocaml_wrapper str_version =
    let version = OpamPackage.Version.of_string str_version in
    let wrapper_nv = OpamPackage.create ocaml_wrapper_pkgname version in
    let upper_bound_v =
      let g = Re.(exec @@ compile @@ seq [rep digit; eos]) str_version in
      try
        let sn = Re.Group.get g 0 in
        String.sub str_version 0 (fst (Re.Group.offset g 0)) ^
        (string_of_int (1 + int_of_string sn)) ^ "~"
      with Not_found -> str_version ^ "a"
    in
    let wrapper_opam =
      O.create wrapper_nv |>
      O.with_substs [OpamFilename.Base.of_string conf_script_name] |>
      O.with_build [
        List.map (fun s -> CString s, None)
          [ "ocaml"; "unix.cma"; conf_script_name ],
        None
      ] |>
      O.with_maintainer [ "platform@lists.ocaml.org" ] |>
      O.with_build_env ["CAML_LD_LIBRARY_PATH", Eq, "", None] |>
      O.with_env [
        "CAML_LD_LIBRARY_PATH", Eq, "%{_:stubsdir}%", None;
        "CAML_LD_LIBRARY_PATH", PlusEq, "%{lib}%/stublibs", None
      ] |>
      (* leave the Compiler flag to the implementations (since the user
         needs to select one)
         O.with_flags [Pkgflag_Compiler] |> *)
      O.with_descr
        (OpamFile.Descr.create
           "The OCaml compiler (virtual package)\n\
            This package requires a matching implementation of OCaml,\n\
            and polls it to initialise specific variables like \
            `ocaml:native-dynlink`") |>
      O.with_depends
        (OpamFormula.ors [
            Atom (
              ocaml_official_pkgname,
              Atom (Constraint (`Eq, FString str_version))
            );
            Atom (
              ocaml_variants_pkgname,
              OpamFormula.ands [
                Atom (Constraint (`Geq, FString str_version));
                Atom (Constraint (`Lt, FString upper_bound_v));
              ]
            );
            Atom (
              ocaml_system_pkgname,
              Atom (Constraint (`Eq, FString str_version))
            )
          ]) |>
      O.with_features [
        OpamVariable.of_string "preinstalled",
        "The concrete compiler was installed outside of opam",
        FIdent ([ocaml_system_pkgname], OpamVariable.of_string "installed",
                None);
        OpamVariable.of_string "compiler",
        "Detailed OCaml or variant compiler name",
        FString
          (Printf.sprintf "%%{%s:installed?system:}%%\
                           %%{%s:installed?%s:}%%\
                           %%{%s:version}%%"
             (OpamPackage.Name.to_string ocaml_system_pkgname)
             (OpamPackage.Name.to_string ocaml_official_pkgname) str_version
             (OpamPackage.Name.to_string ocaml_variants_pkgname));
      ]
    in
    write_opam ~add_files:[conf_script_name^".in", wrapper_conf_script]
      wrapper_opam
  in
  OpamStd.String.Set.iter gen_ocaml_wrapper ocaml_versions;

  let packages = OpamRepository.packages_with_prefixes repo in

  OpamConsole.msg "Will not update base packages: %s\n"
    (OpamPackage.Name.Set.to_string all_base_packages);

  OpamPackage.Map.iter (fun package prefix ->
      let opam_file = OpamRepositoryPath.opam repo prefix package in
      let opam0 = OpamFile.OPAM.read opam_file in
      let nv = OpamFile.OPAM.package opam0 in
      if not (List.mem nv.name ocaml_package_names) &&
         not (OpamPackage.Name.Set.mem nv.name all_base_packages) then
        let opam =
          OpamFormatUpgrade.opam_file_from_1_2_to_2_0 ~filename:opam_file opam0
        in
        if opam <> opam0 then
          (OpamFile.OPAM.write_with_preserved_format opam_file opam;
           OpamConsole.status_line "Updated %s" (OpamFile.to_string opam_file))
    )
    packages;

  let repo_file = OpamRepositoryPath.repo repo in
  OpamFile.Repo.write repo_file
    (OpamFile.Repo.with_opam_version (OpamVersion.of_string "2.0")
       (OpamFile.Repo.safe_read repo_file))
