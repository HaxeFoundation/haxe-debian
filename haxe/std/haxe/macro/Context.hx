/*
 * Copyright (c) 2005-2010, The haXe Project Contributors
 * All rights reserved.
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *   - Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 *   - Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE HAXE PROJECT CONTRIBUTORS "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE HAXE PROJECT CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
 * DAMAGE.
 */
package haxe.macro;
import haxe.macro.Expr;

/**
	This is an API that can be used by macros implementations.
**/
class Context {

#if neko
	/**
		Display a compilation error at the given position in code
	**/
	public static function error( msg : String, pos : Position ) : Dynamic {
		return load("error",2)(untyped msg.__s, pos);
	}

	/**
		Display a compilation warning at the given position in code
	**/
	public static function warning( msg : String, pos : Position ) {
		load("warning",2)(untyped msg.__s, pos);
	}

	/**
		Resolve a filename based on current classpath.
	**/
	public static function resolvePath( file : String ) {
		return new String(load("resolve",1)(untyped file.__s));
	}

	/**
		Return the current classpath
	**/
	public static function getClassPath() : Array<String> {
		var c : neko.NativeArray<neko.NativeString> = load("class_path",0)();
		var a = new Array();
		for( i in 0...neko.NativeArray.length(c) )
			a.push(Std.string(c[i]));
		return a;
	}

	/**
		Returns the position at which the macro is called
	**/
	public static function currentPos() : Position {
		return load("curpos", 0)();
	}

	/**
		Returns the current class in which the macro is called
	**/
	public static function getLocalClass() : Null<Type.Ref<Type.ClassType>> {
		var l : Type = load("curclass", 0)();
		if( l == null ) return null;
		return switch( l ) {
		case TInst(c,_): c;
		default: null;
		}
	}

	/**
		Tells is the given compiler directive has been defined with -D
	**/
	public static function defined( s : String ) : Bool {
		return load("defined", 1)(untyped s.__s);
	}

	/**
		Resolve a type from its name.
	**/
	public static function getType( name : String ) : Type {
		return load("get_type", 1)(untyped name.__s);
	}

	/**
		Return the list of types defined in the given compilation unit module
	**/
	public static function getModule( name : String ) : Array<Type> {
		return load("get_module", 1)(untyped name.__s);
	}

	/**
		Parse an expression.
	**/
	public static function parse( expr : String, pos : Position ) : Expr {
		return load("parse", 2)(untyped expr.__s, pos);
	}

	/**
		Quickly build an hashed MD5 signature for any given value
	**/
	public static function signature( v : Dynamic ) : String {
		return new String(load("signature", 1)(v));
	}

	/**
		Set a callback function that will return all the types compiled before they get generated.
	**/
	public static function onGenerate( callb : Array<Type> -> Void ) {
		load("on_generate",1)(callb);
	}

	/**
		Evaluate the type a given expression would have in the context of the current macro call.
	**/
	public static function typeof( e : Expr ) : Type {
		return load("typeof", 1)(e);
	}

	/**
		Get the informations stored into a given position.
	**/
	public static function getPosInfos( p : Position ) : { min : Int, max : Int, file : String } {
		var i = load("get_pos_infos",1)(p);
		i.file = new String(i.file);
		return i;
	}

	/**
		Build a position with the given informations.
	**/
	public static function makePosition( inf : { min : Int, max : Int, file : String } ) : Position {
		return load("make_pos",3)(inf.min,inf.max,untyped inf.file.__s);
	}

	/**
		Add or modify a resource that will be accessible with haxe.Resource api.
	**/
	public static function addResource( name : String, data : haxe.io.Bytes ) {
		return load("add_resource",2)(untyped name.__s,data.getData());
	}

	static function load( f, nargs ) : Dynamic {
		#if macro
		return neko.Lib.load("macro", f, nargs);
		#else
		return Reflect.makeVarArgs(function(_) throw "Can't be called outside of macro");
		#end
	}

#end

}