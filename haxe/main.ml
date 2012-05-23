(*
 *  Haxe Compiler
 *  Copyright (c)2005-2008 Nicolas Cannasse
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
open Printf
open Genswf
open Common
open Type

type context = {
	com : Common.context;
	mutable flush : unit -> unit;
	mutable setup : unit -> unit;
	mutable messages : string list;
	mutable has_next : bool;
	mutable has_error : bool;
}

type cache = {
	mutable c_haxelib : (string list, string list) Hashtbl.t;
	mutable c_files : (string, float * Ast.package) Hashtbl.t;
	mutable c_modules : (path * string, module_def) Hashtbl.t;
}

exception Abort
exception Completion of string

let version = 209

let measure_times = ref false
let prompt = ref false
let start_time = ref (get_time())
let global_cache = ref None

let executable_path() =
	Extc.executable_path()

let normalize_path p =
	let l = String.length p in
	if l = 0 then
		"./"
	else match p.[l-1] with
		| '\\' | '/' -> p
		| _ -> p ^ "/"

let format msg p =
	if p = Ast.null_pos then
		msg
	else begin
		let error_printer file line = sprintf "%s:%d:" file line in
		let epos = Lexer.get_error_pos error_printer p in
		let msg = String.concat ("\n" ^ epos ^ " : ") (ExtString.String.nsplit msg "\n") in
		sprintf "%s : %s" epos msg
	end

let ssend sock str =
	let rec loop pos len =
		if len = 0 then
			()
		else
			let s = Unix.send sock str pos len [] in
			loop (pos + s) (len - s)
	in
	loop 0 (String.length str)

let message ctx msg p =
	ctx.messages <- format msg p :: ctx.messages

let error ctx msg p =
	message ctx msg p;
	ctx.has_error <- true

let htmlescape s =
	let s = String.concat "&lt;" (ExtString.String.nsplit s "<") in
	let s = String.concat "&gt;" (ExtString.String.nsplit s ">") in
	s

let complete_fields fields =
	let b = Buffer.create 0 in
	Buffer.add_string b "<list>\n";
	List.iter (fun (n,t,d) ->
		Buffer.add_string b (Printf.sprintf "<i n=\"%s\"><t>%s</t><d>%s</d></i>\n" n (htmlescape t) (htmlescape d))
	) (List.sort (fun (a,_,_) (b,_,_) -> compare a b) fields);
	Buffer.add_string b "</list>\n";
	raise (Completion (Buffer.contents b))

let report_times print =
	let tot = ref 0. in
	Hashtbl.iter (fun _ t -> tot := !tot +. t.total) Common.htimers;
	print (Printf.sprintf "Total time : %.3fs" !tot);
	print "------------------------------------";
	let timers = List.sort (fun t1 t2 -> compare t1.name t2.name) (Hashtbl.fold (fun _ t acc -> t :: acc) Common.htimers []) in
	List.iter (fun t -> print (Printf.sprintf "  %s : %.3fs, %.0f%%" t.name t.total (t.total *. 100. /. !tot))) timers

let file_extension f =
	let cl = ExtString.String.nsplit f "." in
	match List.rev cl with
	| [] -> ""
	| x :: _ -> x

let make_path f =
	let f = String.concat "/" (ExtString.String.nsplit f "\\") in
	let cl = ExtString.String.nsplit f "." in
	let cl = (match List.rev cl with
		| ["hx";path] -> ExtString.String.nsplit path "/"
		| _ -> cl
	) in
	let error() = failwith ("Invalid class name " ^ f) in
	let invalid_char x =
		for i = 1 to String.length x - 1 do
			match x.[i] with
			| 'A'..'Z' | 'a'..'z' | '0'..'9' | '_' -> ()
			| _ -> error()
		done;
		false
	in
	let rec loop = function
		| [] -> error()
		| [x] -> if String.length x = 0 || not (x.[0] = '_' || (x.[0] >= 'A' && x.[0] <= 'Z')) || invalid_char x then error() else [] , x
		| x :: l ->
			if String.length x = 0 || x.[0] < 'a' || x.[0] > 'z' || invalid_char x then error() else
				let path , name = loop l in
				x :: path , name
	in
	loop cl

let unique l =
	let rec _unique = function
		| [] -> []
		| x1 :: x2 :: l when x1 = x2 -> _unique (x2 :: l)
		| x :: l -> x :: _unique l
	in
	_unique (List.sort compare l)

let rec read_type_path com p =
	let classes = ref [] in
	let packages = ref [] in
	let p = (match p with
		| x :: l ->
			(try
				match PMap.find x com.package_rules with
				| Directory d -> d :: l
				| Remap s -> s :: l
				| _ -> p
			with
				Not_found -> p)
		| _ -> p
	) in
	List.iter (fun path ->
		let dir = path ^ String.concat "/" p in
		let r = (try Sys.readdir dir with _ -> [||]) in
		Array.iter (fun f ->
			if (try (Unix.stat (dir ^ "/" ^ f)).Unix.st_kind = Unix.S_DIR with _ -> false) then begin
				if f.[0] >= 'a' && f.[0] <= 'z' then begin
					if p = ["."] then
						match read_type_path com [f] with
						| [] , [] -> ()
						| _ ->
							try
								match PMap.find f com.package_rules with
								| Forbidden -> ()
								| Remap f -> packages := f :: !packages
								| Directory _ -> raise Not_found
							with Not_found ->
								packages := f :: !packages
					else
						packages := f :: !packages
				end;
			end else if file_extension f = "hx" then begin
				let c = Filename.chop_extension f in
				if String.length c < 2 || String.sub c (String.length c - 2) 2 <> "__" then classes := c :: !classes;
			end;
		) r;
	) com.class_path;
	List.iter (fun (_,_,extract) ->
		Hashtbl.iter (fun (path,name) _ ->
			if path = p then classes := name :: !classes else
			let rec loop p1 p2 =
				match p1, p2 with
				| [], _ -> ()
				| x :: _, [] -> packages := x :: !packages
				| a :: p1, b :: p2 -> if a = b then loop p1 p2
			in
			loop path p
		) (extract());
	) com.swf_libs;
	unique !packages, unique !classes

let delete_file f = try Sys.remove f with _ -> ()

let expand_env ?(h=None) path  =
	let r = Str.regexp "%\\([A-Za-z0-9_]+\\)%" in
	Str.global_substitute r (fun s ->
		let key = Str.matched_group 1 s in
		try
			Sys.getenv key
		with Not_found -> try
			match h with
			| None -> raise Not_found
			| Some h -> Hashtbl.find h key
		with Not_found ->
			"%" ^ key ^ "%"
	) path

let unquote v =
	let len = String.length v in
	if len > 0 && v.[0] = '"' && v.[len - 1] = '"' then String.sub v 1 (len - 2) else v

let parse_hxml_data data =
	let lines = Str.split (Str.regexp "[\r\n]+") data in
	List.concat (List.map (fun l ->
		let l = unquote (ExtString.String.strip l) in
		if l = "" || l.[0] = '#' then
			[]
		else if l.[0] = '-' then
			try
				let a, b = ExtString.String.split l " " in
				[unquote a; unquote (ExtString.String.strip b)]
			with
				_ -> [l]
		else
			[l]
	) lines)

let parse_hxml file =
	let ch = IO.input_channel (try open_in_bin file with _ -> failwith ("File not found " ^ file)) in
	let data = IO.read_all ch in
	IO.close_in ch;
	parse_hxml_data data

let lookup_classes com spath =
	let rec loop = function
		| [] -> []
		| cp :: l ->
			let cp = (if cp = "" then "./" else cp) in
			let c =  Extc.get_real_path (Common.unique_full_path (normalize_path cp)) in
			let clen = String.length c in
			if clen < String.length spath && String.sub spath 0 clen = c then begin
				let path = String.sub spath clen (String.length spath - clen) in
				(try
					let path = make_path path in
					(match loop l with
					| [x] when String.length (Ast.s_type_path x) < String.length (Ast.s_type_path path) -> [x]
					| _ -> [path])
				with _ -> loop l)
			end else
				loop l
	in
	loop com.class_path

let add_swf_lib com file =
	let swf_data = ref None in
	let swf_classes = ref None in
	let getSWF = (fun() ->
		match !swf_data with
		| None ->
			let d = Genswf.parse_swf com file in
			swf_data := Some d;
			d
		| Some d -> d
	) in
	let extract = (fun() ->
		match !swf_classes with
		| None ->
			let d = Genswf.extract_data (getSWF()) in
			swf_classes := Some d;
			d
		| Some d -> d
	) in
	let build cl p =
		match (try Some (Hashtbl.find (extract()) cl) with Not_found -> None) with
		| None -> None
		| Some c -> Some (file, Genswf.build_class com c file)
	in
	com.load_extern_type <- com.load_extern_type @ [build];
	com.swf_libs <- (file,getSWF,extract) :: com.swf_libs

let add_libs com libs =
	let call_haxelib() =
		let t = Common.timer "haxelib" in
		let cmd = "haxelib path " ^ String.concat " " libs in
		let p = Unix.open_process_in cmd in
		let lines = Std.input_list p in
		let ret = Unix.close_process_in p in
		if ret <> Unix.WEXITED 0 then failwith (String.concat "\n" lines);
		t();
		lines
	in
	match libs with
	| [] -> ()
	| _ ->
		let lines = match !global_cache with
			| Some cache ->
				(try
					(* if we are compiling, really call haxelib since library path might have changed *)
					if not com.display then raise Not_found;
					Hashtbl.find cache.c_haxelib libs
				with Not_found ->
					let lines = call_haxelib() in
					Hashtbl.replace cache.c_haxelib libs lines;
					lines)
			| _ -> call_haxelib()
		in
		let lines = List.fold_left (fun acc l ->
			let p = String.length l - 1 in
			let l = (if l.[p] = '\r' then String.sub l 0 p else l) in
			match (if p > 3 then String.sub l 0 3 else "") with
			| "-D " ->
				Common.define com (String.sub l 3 (String.length l - 3));
				acc
			| "-L " ->
				com.neko_libs <- String.sub l 3 (String.length l - 3) :: com.neko_libs;
				acc
			| _ ->
				l :: acc
		) [] lines in
		com.class_path <- lines @ com.class_path

let default_flush ctx =
	List.iter prerr_endline (List.rev ctx.messages);
	if ctx.has_error && !prompt then begin
		print_endline "Press enter to exit...";
		ignore(read_line());
	end;
	if ctx.has_error then exit 1

let create_context params =
	let ctx = {
		com = Common.create version params;
		flush = (fun()->());
		setup = (fun()->());
		messages = [];
		has_next = false;
		has_error = false;
	} in
	ctx.flush <- (fun() -> default_flush ctx);
	ctx

let rec process_params create acc = function
	| [] ->
		let ctx = create (List.rev acc) in
		init ctx;
		ctx.flush()
	| "--next" :: l ->
		let ctx = create (List.rev acc) in
		ctx.has_next <- true;
		init ctx;
		ctx.flush();
		process_params create [] l
	| "--cwd" :: dir :: l ->
		(* we need to change it immediately since it will affect hxml loading *)
		(try Unix.chdir dir with _ -> ());
		process_params create (dir :: "--cwd" :: acc) l
	| "--connect" :: hp :: l ->
		(match !global_cache with
		| None ->
			let host, port = (try ExtString.String.split hp ":" with _ -> "127.0.0.1", hp) in
			do_connect host (try int_of_string port with _ -> raise (Arg.Bad "Invalid port")) ((List.rev acc) @ l)
		| Some _ ->
			(* already connected : skip *)
			process_params create acc l)
	| arg :: l ->
		match List.rev (ExtString.String.nsplit arg ".") with
		| "hxml" :: _ -> process_params create acc (parse_hxml arg @ l)
		| _ -> process_params create (arg :: acc) l

and wait_loop boot_com host port =
	let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
	(try Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_of_string host,port)) with _ -> failwith ("Couldn't wait on " ^ host ^ ":" ^ string_of_int port));
	Unix.listen sock 10;
	Sys.catch_break false;
	let verbose = boot_com.verbose in
	let has_parse_error = ref false in
	if verbose then print_endline ("Waiting on " ^ host ^ ":" ^ string_of_int port);
	let bufsize = 1024 in
	let tmp = String.create bufsize in
	let cache = {
		c_haxelib = Hashtbl.create 0;
		c_files = Hashtbl.create 0;
		c_modules = Hashtbl.create 0;
	} in
	global_cache := Some cache;
	Typeload.parse_hook := (fun com2 file p ->
		let sign = get_signature com2 in
		let ffile = Common.unique_full_path file in
		let ftime = file_time ffile in
		let fkey = ffile ^ "!" ^ sign in
		try
			let time, data = Hashtbl.find cache.c_files fkey in
			if time <> ftime then raise Not_found;
			data
		with Not_found ->
			has_parse_error := false;
			let data = Typeload.parse_file com2 file p in
			if verbose then print_endline ("Parsed " ^ ffile);
			if not !has_parse_error && ffile <> (!Parser.resume_display).Ast.pfile then Hashtbl.replace cache.c_files fkey (ftime,data);
			data
	);
	let cache_module m =
		Hashtbl.replace cache.c_modules (m.m_path,m.m_extra.m_sign) m;
	in
	let check_module_path com m p =
		m.m_extra.m_file = Common.unique_full_path (Typeload.resolve_module_file com m.m_path (ref[]) p)
	in
	let compilation_step = ref 0 in
	let compilation_mark = ref 0 in
	let mark_loop = ref 0 in
	Typeload.type_module_hook := (fun (ctx:Typecore.typer) mpath p ->
		let t = Common.timer "module cache check" in
		let com2 = ctx.Typecore.com in
		let sign = get_signature com2 in
		let dep = ref None in
		incr mark_loop;
		let mark = !mark_loop in
		let start_mark = !compilation_mark in
		let rec check m =
			if m.m_extra.m_dirty then begin
				dep := Some m;
				false
			end else if m.m_extra.m_mark = mark then
				true
			else try
				if m.m_extra.m_mark <= start_mark then begin
					(match m.m_extra.m_kind with
					| MFake -> () (* don't get classpath *)
					| MCode -> if not (check_module_path com2 m p) then raise Not_found;
					| MMacro when ctx.Typecore.in_macro -> if not (check_module_path com2 m p) then raise Not_found;
					| MMacro ->
						let _, mctx = Typer.get_macro_context ctx p in
						if not (check_module_path mctx.Typecore.com m p) then raise Not_found;
					);
					if file_time m.m_extra.m_file <> m.m_extra.m_time then begin
						if m.m_extra.m_kind = MFake then Hashtbl.remove Typecore.fake_modules m.m_extra.m_file;
						raise Not_found;
					end;
				end;
				m.m_extra.m_mark <- mark;
				PMap.iter (fun _ m2 -> if not (check m2) then begin dep := Some m2; raise Not_found end) m.m_extra.m_deps;
				true
			with Not_found ->
				m.m_extra.m_dirty <- true;
				false
		in
		let rec add_modules m0 m =
			if m.m_extra.m_added < !compilation_step then begin
				(match m0.m_extra.m_kind, m.m_extra.m_kind with
				| MCode, MMacro | MMacro, MCode ->
					(* this was just a dependency to check : do not add to the context *)
					()
				| _ ->
					if verbose then print_endline ("Reusing  cached module " ^ Ast.s_type_path m.m_path);
					m.m_extra.m_added <- !compilation_step;
					List.iter (fun t ->
						match t with
						| TClassDecl c -> c.cl_restore()
						| TEnumDecl e ->
							let rec loop acc = function
								| [] -> ()
								| (":real",[Ast.EConst (Ast.String path),_],_) :: l ->
									e.e_path <- Ast.parse_path path;
									e.e_meta <- (List.rev acc) @ l;
								| x :: l -> loop (x::acc) l
							in
							loop [] e.e_meta
						| _ -> ()
					) m.m_types;
					Typeload.add_module ctx m p;
					PMap.iter (Hashtbl.add com2.resources) m.m_extra.m_binded_res;
					PMap.iter (fun _ m2 -> add_modules m0 m2) m.m_extra.m_deps);
					List.iter (Typer.call_init_macro ctx) m.m_extra.m_macro_calls
			end
		in
		try
			let m = Hashtbl.find cache.c_modules (mpath,sign) in
			if com2.dead_code_elimination then raise Not_found;
			if not (check m) then begin
				if verbose then print_endline ("Skipping cached module " ^ Ast.s_type_path mpath ^ (match !dep with None -> "" | Some m -> "(" ^ Ast.s_type_path m.m_path ^ ")"));
				raise Not_found;
			end;
			add_modules m m;
			t();
			Some m
		with Not_found ->
			t();
			None
	);
	let run_count = ref 0 in
	while true do
		let sin, _ = Unix.accept sock in
		let t0 = get_time() in
		Unix.set_nonblock sin;
		if verbose then print_endline "Client connected";
		let b = Buffer.create 0 in
		let rec read_loop() =
			try
				let r = Unix.recv sin tmp 0 bufsize [] in
				if verbose then Printf.printf "Reading %d bytes\n" r;
				Buffer.add_substring b tmp 0 r;
				if r > 0 && tmp.[r-1] = '\000' then Buffer.sub b 0 (Buffer.length b - 1) else read_loop();
			with Unix.Unix_error((Unix.EWOULDBLOCK|Unix.EAGAIN),_,_) ->
				if verbose then print_endline "Waiting for data...";
				ignore(Unix.select [] [] [] 0.1);
				read_loop()
		in
		let rec cache_context com =
			if not com.dead_code_elimination then begin
				List.iter cache_module com.modules;
				if verbose then print_endline ("Cached " ^ string_of_int (List.length com.modules) ^ " modules");
			end;
			match com.get_macros() with
			| None -> ()
			| Some com -> cache_context com
		in
		let create params =
			let ctx = create_context params in
			ctx.flush <- (fun() ->
				incr compilation_step;
				compilation_mark := !mark_loop;
				List.iter (fun s -> ssend sin (s ^ "\n"); if verbose then print_endline ("> " ^ s)) (List.rev ctx.messages);
				if ctx.has_error then ssend sin "\x02\n" else cache_context ctx.com;
			);
			ctx.setup <- (fun() ->
				Parser.display_error := (fun e p -> has_parse_error := true; ctx.com.error (Parser.error_msg e) p);
				if ctx.com.display then begin
					let file = (!Parser.resume_display).Ast.pfile in
					let fkey = file ^ "!" ^ get_signature ctx.com in
					(* force parsing again : if the completion point have been changed *)
					Hashtbl.remove cache.c_files fkey;
					(* force module reloading (if cached) *)
					Hashtbl.iter (fun _ m -> if m.m_extra.m_file = file then m.m_extra.m_dirty <- true) cache.c_modules
				end
			);
			ctx.com.print <- (fun str -> ssend sin ("\x01" ^ String.concat "\x01" (ExtString.String.nsplit str "\n") ^ "\n"));
			ctx
		in
		(try
			let data = parse_hxml_data (read_loop()) in
			Unix.clear_nonblock sin;
			if verbose then print_endline ("Processing Arguments [" ^ String.concat "," data ^ "]");
			(try
				Common.display_default := false;
				Parser.resume_display := Ast.null_pos;
				Typeload.return_partial_type := false;
				measure_times := false;
				close_times();
				stats.s_files_parsed := 0;
				stats.s_classes_built := 0;
				stats.s_methods_typed := 0;
				stats.s_macros_called := 0;
				Hashtbl.clear Common.htimers;
				let _ = Common.timer "other" in
				incr compilation_step;
				compilation_mark := !mark_loop;
				start_time := get_time();
				process_params create [] data;
				close_times();
				if !measure_times then report_times (fun s -> ssend sin (s ^ "\n"))
			with Completion str ->
				if verbose then print_endline ("Completion Response =\n" ^ str);
				ssend sin str
			);
			if verbose then begin
				print_endline (Printf.sprintf "Stats = %d files, %d classes, %d methods, %d macros" !(stats.s_files_parsed) !(stats.s_classes_built) !(stats.s_methods_typed) !(stats.s_macros_called));
				print_endline (Printf.sprintf "Time spent : %.3fs" (get_time() -. t0));
			end
		with Unix.Unix_error _ ->
			if verbose then print_endline "Connection Aborted");
		Unix.close sin;
		(* prevent too much fragmentation by doing some compactions every X run *)
		incr run_count;
		if !run_count mod 1 = 50 then begin
			let t0 = get_time() in
			Gc.compact();
			if verbose then begin
				let stat = Gc.quick_stat() in
				let size = (float_of_int stat.Gc.heap_words) *. 4. in
				print_endline (Printf.sprintf "Compacted memory %.3fs %.1fMB" (get_time() -. t0) (size /. (1024. *. 1024.)));
			end
		end else Gc.minor();
	done

and do_connect host port args =
	let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
	(try Unix.connect sock (Unix.ADDR_INET (Unix.inet_addr_of_string host,port)) with _ -> failwith ("Couldn't connect on " ^ host ^ ":" ^ string_of_int port));
	let args = ("--cwd " ^ Unix.getcwd()) :: args in
	ssend sock (String.concat "" (List.map (fun a -> a ^ "\n") args) ^ "\000");
	let buf = Buffer.create 0 in
	let tmp = String.create 100 in
	let rec loop() =
		let b = Unix.recv sock tmp 0 100 [] in
		Buffer.add_substring buf tmp 0 b;
		if b > 0 then loop()
	in
	loop();
	let has_error = ref false in
	let rec print line =
		match (if line = "" then '\x00' else line.[0]) with
		| '\x01' ->
			print_string (String.concat "\n" (List.tl (ExtString.String.nsplit line "\x01")))
		| '\x02' ->
			has_error := true;
		| _ ->
			prerr_endline line;
	in
	let lines = ExtString.String.nsplit (Buffer.contents buf) "\n" in
	let lines = (match List.rev lines with "" :: l -> List.rev l | _ -> lines) in
	List.iter print lines;
	if !has_error then exit 1

and init ctx =
	let usage = Printf.sprintf
		"haXe Compiler %d.%.2d - (c)2005-2012 Motion-Twin\n Usage : haxe%s -main <class> [-swf|-js|-neko|-php|-cpp|-as3] <output> [options]\n Options :"
		(version / 100) (version mod 100) (if Sys.os_type = "Win32" then ".exe" else "")
	in
	let com = ctx.com in
	let classes = ref [([],"Std")] in
try
	let xml_out = ref None in
	let swf_header = ref None in
	let cmds = ref [] in
	let config_macros = ref [] in
	let cp_libs = ref [] in
	let gen_as3 = ref false in
	let no_output = ref false in
	let did_something = ref false in
	let force_typing = ref false in
	let pre_compilation = ref [] in
	let interp = ref false in
	Common.define com ("haxe_" ^ string_of_int version);
	com.warning <- (fun msg p -> message ctx ("Warning : " ^ msg) p);
	com.error <- error ctx;
	Parser.display_error := (fun e p -> com.error (Parser.error_msg e) p);
	Parser.use_doc := !Common.display_default || (!global_cache <> None);
	(try
		let p = Sys.getenv "HAXE_LIBRARY_PATH" in
		let rec loop = function
			| drive :: path :: l ->
				if String.length drive = 1 && ((drive.[0] >= 'a' && drive.[0] <= 'z') || (drive.[0] >= 'A' && drive.[0] <= 'Z')) then
					(drive ^ ":" ^ path) :: loop l
				else
					drive :: loop (path :: l)
			| l ->
				l
		in
		let parts = "" :: Str.split_delim (Str.regexp "[;:]") p in
		com.class_path <- List.map normalize_path (loop parts)
	with
		Not_found ->
			if Sys.os_type = "Unix" then
				com.class_path <- ["/usr/lib/haxe/std/";"/usr/local/lib/haxe/std/";"";"/"]
			else
				let base_path = normalize_path (try executable_path() with _ -> "./") in
				com.class_path <- [base_path ^ "std/";""]);
	com.std_path <- List.filter (fun p -> ExtString.String.ends_with p "std/" || ExtString.String.ends_with p "std\\") com.class_path;
	let set_platform pf file =
		if com.platform <> Cross then failwith "Multiple targets";
		Common.init_platform com pf;
		com.file <- file;
		if (pf = Flash8 || pf = Flash) && file_extension file = "swc" then Common.define com "swc";
	in
	let define f = Arg.Unit (fun () -> Common.define com f) in
	let basic_args_spec = [
		("-cp",Arg.String (fun path ->
			add_libs com (!cp_libs);
			cp_libs := [];
			com.class_path <- normalize_path path :: com.class_path
		),"<path> : add a directory to find source files");
		("-js",Arg.String (set_platform Js),"<file> : compile code to JavaScript file");
		("-swf",Arg.String (set_platform Flash),"<file> : compile code to Flash SWF file");
		("-as3",Arg.String (fun dir ->
			set_platform Flash dir;
			gen_as3 := true;
			Common.define com "as3";
			Common.define com "no_inline";
		),"<directory> : generate AS3 code into target directory");
		("-neko",Arg.String (set_platform Neko),"<file> : compile code to Neko Binary");
		("-php",Arg.String (fun dir ->
			classes := (["php"],"Boot") :: !classes;
			set_platform Php dir;
		),"<directory> : generate PHP code into target directory");
		("-cpp",Arg.String (fun dir ->
			set_platform Cpp dir;
		),"<directory> : generate C++ code into target directory");
		("-xml",Arg.String (fun file ->
			Parser.use_doc := true;
			xml_out := Some file
		),"<file> : generate XML types description");
		("-main",Arg.String (fun cl ->
			if com.main_class <> None then raise (Arg.Bad "Multiple -main");
			let cpath = make_path cl in
			com.main_class <- Some cpath;
			classes := cpath :: !classes
		),"<class> : select startup class");
		("-lib",Arg.String (fun l ->
			cp_libs := l :: !cp_libs;
			Common.define com l;
		),"<library[:version]> : use a haxelib library");
		("-D",Arg.String (fun var ->
			(match var with
			| "use_rtti_doc" -> Parser.use_doc := true
			| "no_opt" -> com.foptimize <- false
			| _ -> ());
			Common.define com var
		),"<var> : define a conditional compilation flag");
		("-v",Arg.Unit (fun () ->
			com.verbose <- true
		),": turn on verbose mode");
		("-debug", Arg.Unit (fun() ->
			Common.define com "debug"; com.debug <- true
		), ": add debug informations to the compiled code");
	] in
	let adv_args_spec = [
		("-swf-version",Arg.Float (fun v ->
			com.flash_version <- v;
		),"<version> : change the SWF version (6 to 10)");
		("-swf-header",Arg.String (fun h ->
			try
				swf_header := Some (match ExtString.String.nsplit h ":" with
				| [width; height; fps] ->
					(int_of_string width,int_of_string height,float_of_string fps,0xFFFFFF)
				| [width; height; fps; color] ->
					(int_of_string width, int_of_string height, float_of_string fps, int_of_string ("0x" ^ color))
				| _ -> raise Exit)
			with
				_ -> raise (Arg.Bad "Invalid SWF header format")
		),"<header> : define SWF header (width:height:fps:color)");
		("-swf-lib",Arg.String (fun file ->
			add_swf_lib com file
		),"<file> : add the SWF library to the compiled SWF");
		("-x", Arg.String (fun file ->
			let neko_file = file ^ ".n" in
			set_platform Neko neko_file;
			if com.main_class = None then begin
				let cpath = make_path file in
				com.main_class <- Some cpath;
				classes := cpath :: !classes
			end;
			cmds := ("neko " ^ neko_file) :: !cmds;
		),"<file> : shortcut for compiling and executing a neko file");
		("-resource",Arg.String (fun res ->
			let file, name = (match ExtString.String.nsplit res "@" with
				| [file; name] -> file, name
				| [file] -> file, file
				| _ -> raise (Arg.Bad "Invalid Resource format : should be file@name")
			) in
			let file = (try Common.find_file com file with Not_found -> file) in
			let data = (try
				let s = Std.input_file ~bin:true file in
				if String.length s > 12000000 then raise Exit;
				s;
			with
				| Sys_error _ -> failwith ("Resource file not found : " ^ file)
				| _ -> failwith ("Resource '" ^ file ^ "' excess the maximum size of 12MB")
			) in
			if Hashtbl.mem com.resources name then failwith ("Duplicate resource name " ^ name);
			Hashtbl.add com.resources name data
		),"<file>[@name] : add a named resource file");
		("-prompt", Arg.Unit (fun() -> prompt := true),": prompt on error");
		("-cmd", Arg.String (fun cmd ->
			cmds := unquote cmd :: !cmds
		),": run the specified command after successful compilation");
		("--flash-strict", define "flash_strict", ": more type strict flash API");
		("--no-traces", define "no_traces", ": don't compile trace calls in the program");
		("--flash-use-stage", define "flash_use_stage", ": place objects found on the stage of the SWF lib");
		("--gen-hx-classes", Arg.Unit (fun() ->
			force_typing := true;
			pre_compilation := (fun() ->
				List.iter (fun (_,_,extract) ->
					Hashtbl.iter (fun n _ -> classes := n :: !classes) (extract())
				) com.swf_libs;
			) :: !pre_compilation;
			xml_out := Some "hx"
		),": generate hx headers for all input classes");
		("--next", Arg.Unit (fun() -> assert false), ": separate several haxe compilations");
		("--display", Arg.String (fun file_pos ->
			match file_pos with
			| "classes" ->
				pre_compilation := (fun() -> raise (Parser.TypePath (["."],None))) :: !pre_compilation;
			| "keywords" ->
				complete_fields (Hashtbl.fold (fun k _ acc -> (k,"","") :: acc) Lexer.keywords [])
			| _ ->
				let file, pos = try ExtString.String.split file_pos "@" with _ -> failwith ("Invalid format : " ^ file_pos) in
				let file = unquote file in
				let pos = try int_of_string pos with _ -> failwith ("Invalid format : "  ^ pos) in
				com.display <- true;
				Common.display_default := true;
				Common.define com "display";
				Parser.use_doc := true;
				Parser.resume_display := {
					Ast.pfile = Common.unique_full_path file;
					Ast.pmin = pos;
					Ast.pmax = pos;
				};
		),": display code tips");
		("--no-output", Arg.Unit (fun() -> no_output := true),": compiles but does not generate any file");
		("--times", Arg.Unit (fun() -> measure_times := true),": measure compilation times");
		("--no-inline", define "no_inline", ": disable inlining");
		("--no-opt", Arg.Unit (fun() ->
			com.foptimize <- false;
			Common.define com "no_opt";
		), ": disable code optimizations");
		("--js-modern", Arg.Unit (fun() ->
			Common.define com "js_modern";
		), ": wrap JS output in a closure, strict mode, and other upcoming features");
		("--php-front",Arg.String (fun f ->
			if com.php_front <> None then raise (Arg.Bad "Multiple --php-front");
			com.php_front <- Some f;
		),"<filename> : select the name for the php front file");
		("--php-lib",Arg.String (fun f ->
 			if com.php_lib <> None then raise (Arg.Bad "Multiple --php-lib");
 			com.php_lib <- Some f;
 		),"<filename> : select the name for the php lib folder");
		("--php-prefix", Arg.String (fun f ->
			if com.php_prefix <> None then raise (Arg.Bad "Multiple --php-prefix");
			com.php_prefix <- Some f;
			Common.define com "php_prefix";
		),"<name> : prefix all classes with given name");
		("--remap", Arg.String (fun s ->
			let pack, target = (try ExtString.String.split s ":" with _ -> raise (Arg.Bad "Invalid format")) in
			com.package_rules <- PMap.add pack (Remap target) com.package_rules;
		),"<package:target> : remap a package to another one");
		("--interp", Arg.Unit (fun() ->
			Common.define com "macro";
			set_platform Neko "";
			no_output := true;
			interp := true;
		),": interpret the program using internal macro system");
		("--macro", Arg.String (fun e ->
			force_typing := true;
			config_macros := e :: !config_macros
		)," : call the given macro before typing anything else");
		("--dead-code-elimination", Arg.Unit (fun () ->
			com.dead_code_elimination <- true;
		)," : remove unused methods");
		("--wait", Arg.String (fun hp ->
			let host, port = (try ExtString.String.split hp ":" with _ -> "127.0.0.1", hp) in
			wait_loop com host (try int_of_string port with _ -> raise (Arg.Bad "Invalid port"))
		),"<[host:]port> : wait on the given port for commands to run)");
		("--connect",Arg.String (fun _ ->
			assert false
		),"<[host:]port> : connect on the given port and run commands there)");
		("--cwd", Arg.String (fun dir ->
			(try Unix.chdir dir with _ -> raise (Arg.Bad "Invalid directory"))
		),"<dir> : set current working directory");
		("-swf9",Arg.String (fun file ->
			set_platform Flash file;
		),"<file> : [deprecated] compile code to Flash9 SWF file");
	] in
	let current = ref 0 in
	let args = Array.of_list ("" :: List.map expand_env ctx.com.args) in
	let args_callback cl = classes := make_path cl :: !classes in
	Arg.parse_argv ~current args (basic_args_spec @ adv_args_spec) args_callback usage;
	add_libs com (!cp_libs);
	(try ignore(Common.find_file com "mt/Include.hx"); Common.define com "mt"; with Not_found -> ());
	if com.display then begin
		xml_out := None;
		no_output := true;
		com.warning <- message ctx;
		com.error <- error ctx;
		com.main_class <- None;
		let real = Extc.get_real_path (!Parser.resume_display).Ast.pfile in
		classes := lookup_classes com real;
		Common.log com ("Display file : " ^ real);
		Common.log com ("Classes found : ["  ^ (String.concat "," (List.map Ast.s_type_path !classes)) ^ "]");
	end;
	let add_std dir =
		com.class_path <- List.filter (fun s -> not (List.mem s com.std_path)) com.class_path @ List.map (fun p -> p ^ dir ^ "/_std/") com.std_path @ com.std_path
	in
	let ext = (match com.platform with
		| Cross ->
			(* no platform selected *)
			set_platform Cross "";
			"?"
		| Flash8 | Flash ->
			if com.flash_version >= 9. then begin
				let rec loop = function
					| [] -> ()
					| (v,_) :: _ when v > com.flash_version -> ()
					| (v,def) :: l ->
						Common.define com ("flash" ^ def);
						loop l
				in
				loop Common.flash_versions;
				Common.define com "flash";
				com.defines <- PMap.remove "flash8" com.defines;
				com.package_rules <- PMap.remove "flash" com.package_rules;
				add_std "flash";
			end else begin
				com.package_rules <- PMap.add "flash" (Directory "flash8") com.package_rules;
				com.package_rules <- PMap.add "flash8" Forbidden com.package_rules;
				Common.define com "flash";
				Common.define com ("flash" ^ string_of_int (int_of_float com.flash_version));
				com.platform <- Flash8;
				add_std "flash8";
			end;
			"swf"
		| Neko ->
			add_std "neko";
			"n"
		| Js ->
			add_std "js";
			"js"
		| Php ->
			add_std "php";
			"php"
		| Cpp ->
			add_std "cpp";
			"cpp"
	) in
	(* if we are at the last compilation step, allow all packages accesses - in case of macros or opening another project file *)
	if com.display && not ctx.has_next then com.package_rules <- PMap.foldi (fun p r acc -> match r with Forbidden -> acc | _ -> PMap.add p r acc) com.package_rules PMap.empty;

	(* check file extension. In case of wrong commandline, we don't want
		to accidentaly delete a source file. *)
	if not !no_output && file_extension com.file = ext then delete_file com.file;
	List.iter (fun f -> f()) (List.rev (!pre_compilation));
	if !classes = [([],"Std")] && not !force_typing then begin
		if !cmds = [] && not !did_something then Arg.usage basic_args_spec usage;
	end else begin
		ctx.setup();
		Common.log com ("Classpath : " ^ (String.concat ";" com.class_path));
		Common.log com ("Defines : " ^ (String.concat ";" (PMap.foldi (fun v _ acc -> v :: acc) com.defines [])));
		let t = Common.timer "typing" in
		Typecore.type_expr_ref := (fun ctx e need_val -> Typer.type_expr ~need_val ctx e);
		let tctx = Typer.create com in
		List.iter (Typer.call_init_macro tctx) (List.rev !config_macros);
		List.iter (fun cpath -> ignore(tctx.Typecore.g.Typecore.do_load_module tctx cpath Ast.null_pos)) (List.rev !classes);
		Typer.finalize tctx;
		t();
		if ctx.has_error then raise Abort;
		let t = Common.timer "filters" in
		let main, types, modules = Typer.generate tctx in
		com.main <- main;
		com.types <- types;
		com.modules <- modules;
		let filters = [
			if com.foptimize then Optimizer.reduce_expression tctx else Optimizer.sanitize tctx;
			Codegen.check_local_vars_init;
			Codegen.captured_vars com;
			Codegen.rename_local_vars com;
		] in
		Codegen.post_process com.types filters;
		Common.add_filter com (fun() -> List.iter (Codegen.on_generate tctx) com.types);
		List.iter (fun f -> f()) (List.rev com.filters);
		(match !xml_out with
		| None -> ()
		| Some "hx" ->
			Genxml.generate_hx com
		| Some file ->
			Common.log com ("Generating xml : " ^ com.file);
			Genxml.generate com file);
		if com.platform = Flash || com.platform = Cpp then List.iter (Codegen.fix_overrides com) com.types;
		if Common.defined com "dump" then Codegen.dump_types com;
		t();
		(match com.platform with
		| _ when !no_output ->
			if !interp then begin
				let ctx = Interp.create com (Typer.make_macro_api tctx Ast.null_pos) in
				Interp.add_types ctx com.types;
				(match com.main with
				| None -> ()
				| Some e -> ignore(Interp.eval_expr ctx e));
			end;
		| Cross ->
			()
		| Flash8 | Flash when !gen_as3 ->
			Common.log com ("Generating AS3 in : " ^ com.file);
			Genas3.generate com;
		| Flash8 | Flash ->
			Common.log com ("Generating swf : " ^ com.file);
			Genswf.generate com !swf_header;
		| Neko ->
			Common.log com ("Generating neko : " ^ com.file);
			Genneko.generate com;
		| Js ->
			Common.log com ("Generating js : " ^ com.file);
			Genjs.generate com
		| Php ->
			Common.log com ("Generating PHP in : " ^ com.file);
			Genphp.generate com;
		| Cpp ->
			Common.log com ("Generating Cpp in : " ^ com.file);
			Gencpp.generate com;
		);
	end;
	Sys.catch_break false;
	if not !no_output then List.iter (fun cmd ->
		let h = Hashtbl.create 0 in
		Hashtbl.add h "__file__" com.file;
		Hashtbl.add h "__platform__" (platform_name com.platform);
		let t = Common.timer "command" in
		let cmd = expand_env ~h:(Some h) cmd in
		let len = String.length cmd in
		if len > 3 && String.sub cmd 0 3 = "cd " then
			Sys.chdir (String.sub cmd 3 (len - 3))
		else begin
			let binary_string s =
				if Sys.os_type <> "Win32" && Sys.os_type <> "Cygwin" then s else String.concat "\n" (Str.split (Str.regexp "\r\n") s)
			in
			let pout, pin, perr = Unix.open_process_full cmd (Unix.environment()) in
			let iout = Unix.descr_of_in_channel pout in
			let ierr = Unix.descr_of_in_channel perr in
			let berr = Buffer.create 0 in
			let bout = Buffer.create 0 in
			let tmp = String.create 1024 in
			let result = ref None in
			(*
				we need to read available content on process out/err if we want to prevent
				the process from blocking when the pipe is full
			*)
			let is_process_running() =
				let pid, r = Unix.waitpid [Unix.WNOHANG] (-1) in
				if pid = 0 then
					true
				else begin
					result := Some r;
					false;
				end
			in
			let rec loop ins =
				let (ch,_,_), timeout = (try Unix.select ins [] [] 0.02, true with _ -> ([],[],[]),false) in
				match ch with
				| [] ->
					(* make sure we read all *)
					if timeout && is_process_running() then
						loop ins
					else begin
						Buffer.add_string berr (IO.read_all (IO.input_channel perr));
						Buffer.add_string bout (IO.read_all (IO.input_channel pout));
					end
				| s :: _ ->
					let n = Unix.read s tmp 0 (String.length tmp) in
					Buffer.add_substring (if s == iout then bout else berr) tmp 0 n;
					loop (if n = 0 then List.filter ((!=) s) ins else ins)
			in
			loop [iout;ierr];
			let serr = binary_string (Buffer.contents berr) in
			let sout = binary_string (Buffer.contents bout) in
			if serr <> "" then ctx.messages <- (if serr.[String.length serr - 1] = '\n' then String.sub serr 0 (String.length serr - 1) else serr) :: ctx.messages;
			if sout <> "" then ctx.com.print sout;
			match (try Unix.close_process_full (pout,pin,perr) with Unix.Unix_error (Unix.ECHILD,_,_) -> (match !result with None -> assert false | Some r -> r)) with
			| Unix.WEXITED e -> if e <> 0 then failwith ("Command failed with error " ^ string_of_int e)
			| Unix.WSIGNALED s | Unix.WSTOPPED s -> failwith ("Command stopped with signal " ^ string_of_int s)
		end;
		t();
	) (List.rev !cmds)
with
	| Abort ->
		()
	| Common.Abort (m,p) ->
		error ctx m p
	| Lexer.Error (m,p) ->
		error ctx (Lexer.error_msg m) p
	| Parser.Error (m,p) ->
		error ctx (Parser.error_msg m) p
	| Typecore.Error (Typecore.Forbid_package _,_) when !Common.display_default && ctx.has_next ->
		()
	| Typecore.Error (m,p) ->
		error ctx (Typecore.error_msg m) p
	| Interp.Error (msg,p :: l) ->
		message ctx msg p;
		List.iter (message ctx "Called from") l;
		error ctx "Aborted" Ast.null_pos;
	| Failure msg | Arg.Bad msg ->
		error ctx ("Error : " ^ msg) Ast.null_pos
	| Arg.Help msg ->
		print_string msg
	| Typer.DisplayFields fields ->
		let ctx = print_context() in
		let fields = List.map (fun (name,t,doc) -> name, s_type ctx t, (match doc with None -> "" | Some d -> d)) fields in
		let fields = if !measure_times then begin
			close_times();
			let tot = ref 0. in
			Hashtbl.iter (fun _ t -> tot := !tot +. t.total) Common.htimers;
			let fields = ("@TOTAL", Printf.sprintf "%.3fs" (get_time() -. !start_time), "") :: fields in
			Hashtbl.fold (fun _ t acc ->
				("@TIME " ^ t.name, Printf.sprintf "%.3fs (%.0f%%)" t.total (t.total *. 100. /. !tot), "") :: acc
			) Common.htimers fields;
		end else
			fields
		in
		complete_fields fields
	| Typer.DisplayTypes tl ->
		let ctx = print_context() in
		let b = Buffer.create 0 in
		List.iter (fun t ->
			Buffer.add_string b "<type>\n";
			Buffer.add_string b (htmlescape (s_type ctx t));
			Buffer.add_string b "\n</type>\n";
		) tl;
		raise (Completion (Buffer.contents b))
	| Parser.TypePath (p,c) ->
		(match c with
		| None ->
			let packs, classes = read_type_path com p in
			if packs = [] && classes = [] then
				error ctx ("No classes found in " ^ String.concat "." p) Ast.null_pos
			else
				complete_fields (List.map (fun f -> f,"","") (packs @ classes))
		| Some (c,cur_package) ->
			try
				let ctx = Typer.create com in
				let rec lookup p =
					try
						Typeload.load_module ctx (p,c) Ast.null_pos
					with e ->
						if cur_package then
							match List.rev p with
							| [] -> raise e
							| _ :: p -> lookup (List.rev p)
						else
							raise e
				in
				let m = lookup p in
				complete_fields (List.map (fun t -> snd (t_path t),"","") (List.filter (fun t -> not (t_infos t).mt_private) m.m_types))
			with Completion c ->
				raise (Completion c)
			| _ ->
				error ctx ("Could not load module " ^ (Ast.s_type_path (p,c))) Ast.null_pos)
	| e when (try Sys.getenv "OCAMLRUNPARAM" <> "b" with _ -> true) ->
		error ctx (Printexc.to_string e) Ast.null_pos

;;
let other = Common.timer "other" in
Sys.catch_break true;
(try
	process_params create_context [] (List.tl (Array.to_list Sys.argv));
with Completion c ->
	prerr_endline c;
	exit 0
);
other();
if !measure_times then report_times prerr_endline
