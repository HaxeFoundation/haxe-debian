/*
 * Copyright (c) 2005, The haXe Project Contributors
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
package flash;

class Lib {

	public static var _global : Dynamic;
	public static var _root : MovieClip;
	public static var current : MovieClip;
	static var onerror : String -> Array<String> -> Void;

	public static function trace( str : String ) {
		untyped __trace__(str);
	}

	public static function eval( str : String ) : Dynamic {
		return untyped __eval__(str);
	}

	public static function getURL( url : String, ?target : String ) {
		untyped __geturl__(url,if( target == null ) "_self" else target);
	}

	public static function fscommand( cmd : String, ?param : Dynamic ) {
		untyped __geturl__("FSCommand:"+cmd,if( param == null ) "" else param);
	}

	public static function print( cmd : String, ?kind : String ) {
		kind = if (kind == "bframe" || kind == "bmax") "print:#"+kind else "print:";
		untyped __geturl__(kind,cmd);
	}

	public inline static function getTimer() : Int {
		return untyped __gettimer__();
	}

	public static function getVersion() : String {
		return untyped _root["$version"];
	}

	public static function registerClass( name : String, cl : {} ) {
		untyped _global["Object"]["registerClass"](name,cl);
	}

	public static function keys( v : Dynamic ) : Array<String> {
		return untyped __keys__(v);
	}

	public static function setErrorHandler(f) {
		onerror = f;
	}

}


