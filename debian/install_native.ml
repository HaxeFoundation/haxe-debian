(* 
 * This file is based on http://haxe.org/file/install.ml and
 * was modified by Jens Peter Secher for the Debian distribution 
 * to use ocamlfind to locate external ocaml libraries.  The original
 * file had the following boilerplate:
 *)

(*
 *  Haxe installer
 *  Copyright (c)2005 Nicolas Cannasse
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *)

#load "unix.cma"

(* ----- BEGIN CONFIGURATION ---- *)

let bytecode = false
let native = true

(* ------ END CONFIGURATION ----- *)

let os_type = Sys.os_type

(* remove the comment to compile with windows using ocaml cygwin *)
(* let os_type = "Cygwin" *)

let obj_ext = match os_type with "Win32" -> ".obj" | _ -> ".o"
let exe_ext = match os_type with "Win32" | "Cygwin" -> ".exe" | _ -> ""
let ocamloptflags = match os_type with "Unix" -> "-cclib -fno-stack-protector " | _ -> ""

let msg m =
	prerr_endline m;
	flush stdout

let command c =
	msg ("> " ^ c);
	if Sys.command c <> 0 then failwith ("Error while running " ^ c)

let ocamlc file =
	if bytecode then command ("ocamlfind ocamlc -c " ^ file);
	if native then command ("ocamlfind ocamlopt -c " ^ ocamloptflags ^ file)

let modules l ext =
	String.concat " " (List.map (fun f -> f ^ ext) l)

;;

let compile_libs() =
	(* EXTLIB *)
	Sys.chdir "ocaml/extlib-dev";
	command ("ocaml install.ml -nodoc -d .. " ^ (if bytecode then "-b " else "") ^ (if native then "-n" else ""));
	msg "";
	Sys.chdir "../..";

	(* EXTC *)
	Sys.chdir "ocaml/extc";
	let c_opts = (if Sys.ocaml_version < "3.08" then " -ccopt -Dcaml_copy_string=copy_string " else " ") in
	command ("ocamlfind ocamlc" ^ c_opts ^ " -I .. -I ../ extc_stubs.c");

	let options = "-cclib ../ocaml/extc/extc_stubs" ^ obj_ext ^ " -cclib -lz extc.ml" in
	if bytecode then command ("ocamlfind ocamlc -a -I .. -o extc.cma " ^ options);
	if native then command ("ocamlfind ocamlopt -a -I .. -o extc.cmxa " ^ options);
	Sys.chdir "../..";

	(* SWFLIB *)
	Sys.chdir "ocaml/swflib";

	let files = "-I .. -I ../extc as3.mli as3hl.mli as3code.ml as3parse.ml as3hlparse.ml swf.ml actionScript.ml swfParser.ml" in
	if bytecode then command ("ocamlfind ocamlc -a -o swflib.cma " ^ files);
	if native then command ("ocamlfind ocamlopt -a -o swflib.cmxa " ^ files);
	Sys.chdir "../..";

in

let compile() =

	(try Unix.mkdir "bin" 0o740 with Unix.Unix_error(Unix.EEXIST,_,_) -> ());

	compile_libs();

	(* HAXE *)
	Sys.chdir "haxe";
	command "ocamllex lexer.mll";
	let libs = [
		"../ocaml/extLib";
		"../ocaml/extc/extc";
		"../ocaml/swflib/swflib";
		"/usr/lib/ocaml/xml-light/xml-light";
		"unix";
		"str"
	] in
	let neko = "../neko/libs/include/ocaml" in
	let paths = [
		"../ocaml";
		"../ocaml/swflib";
		"/usr/lib/ocaml/xml-light";
		"../ocaml/extc";
		neko
	] in
	let mlist = [
		"ast";"lexer";"type";"common";"parser";"typecore";
		"genxml";"typeload";"codegen";"optimizer";
		neko^"/nast";neko^"/binast";neko^"/nxml";
		"genneko";"genas3";"genjs";"genswf8";"genswf9";"genswf";"genphp";"gencpp";
		"interp";"typer";"main";
	] in
	let pkgs_str = " -linkpkg -package xml-light" in
	let path_str = String.concat " " (List.map (fun s -> "-I " ^ s) paths) in
	let libs_str ext = " " ^ String.concat " " (List.map (fun l -> l ^ ext) libs) ^ " " in
	ocamlc (path_str ^ pkgs_str ^ " -pp camlp4o " ^ modules mlist ".ml");
	if bytecode then command ("ocamlfind ocamlc -custom -o ../bin/haxe" ^ pkgs_str ^ libs_str ".cma" ^ modules mlist ".cmo");
	if native then command ("ocamlfind ocamlopt -o ../bin/haxe" ^ pkgs_str ^ libs_str ".cmxa" ^ modules mlist ".cmx");

in
let startdir = Sys.getcwd() in
try
	compile();
	Sys.chdir startdir;
with
	Failure msg ->
		Sys.chdir startdir;
		prerr_endline msg; exit 1
