(* 
 * This file is based on http://haxe.org/file/install.ml and
 * was modified by Jens Peter Secher for the Debian distribution 
 * to use ocamlfind to locate external ocaml libraries.  Also,
 * all non-unix setup was removed.  The original file had the
 * following boilerplate:
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

let bytecode = true
let native = false

(* ------ END CONFIGURATION ----- *)

let ocamloptflags = "-cclib -fno-stack-protector "

let zlib = 
	try
		List.find Sys.file_exists ["/usr/lib64/libz.so.1";"/usr/lib/libz.so.1";"/usr/lib/libz.so"]
	with
		Not_found ->
			failwith "LibZ was not found on your system, please install it or modify the search directories in the install script"

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
	(* EXTC *)
	Sys.chdir "ocaml/extc";
	let c_opts = (if Sys.ocaml_version < "3.08" then " -ccopt -Dcaml_copy_string=copy_string " else " ") in
	command ("ocamlc" ^ c_opts ^ " -I .." ^ " extc_stubs.c");

	let options = "-cclib ../ocaml/extc/extc_stubs.o" ^ " -cclib " ^ zlib ^ " extc.mli extc.ml" in
	if bytecode then command ("ocamlc -a -o extc.cma " ^ options);
	if native then command ("ocamlopt -a -o extc.cmxa " ^ options);
	Sys.chdir "../..";

	(* SWFLIB *)
	Sys.chdir "ocaml/swflib";
	let files = "-I .. -I ../extc as3.mli as3hl.mli as3code.ml as3parse.ml as3hlparse.ml swf.ml swfZip.ml actionScript.ml swfParser.ml" in
	if bytecode then command ("ocamlfind ocamlc -a -o swflib.cma -package extlib " ^ files);
	if native then command ("ocamlfind ocamlopt -a -o swflib.cmxa -package extlib " ^ files);
	Sys.chdir "../..";

in

let compile() =

	(try Unix.mkdir "bin" 0o740 with Unix.Unix_error(Unix.EEXIST,_,_) -> ());

	compile_libs();

	(* HAXE *)
	Sys.chdir "haxe";
	command "ocamllex lexer.mll";
	let libs = [
		"../ocaml/extc/extc";
		"../ocaml/swflib/swflib";
		"unix";
		"str"
	] in
	let neko = "../neko/libs/include/ocaml" in
	let paths = [
		"../ocaml";
		"../ocaml/swflib";
		"../ocaml/extc";
		neko
	] in
	let mlist = [
		"ast";"lexer";"type";"common";"parser";"typecore";
		"genxml";"typeload";"codegen";"optimizer";"typer";
		neko^"/nast";neko^"/binast";neko^"/nxml";
		"genneko";"genas3";"genjs";"genswf8";"genswf9";"genswf";"genphp";"gencpp";
		"main";
	] in
	let pkgs_str = " -linkpkg -package extlib,xml-light" in
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
