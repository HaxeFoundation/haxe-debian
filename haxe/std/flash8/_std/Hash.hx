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

@:core_api class Hash<T> {

	private var h : Dynamic;

	public function new() : Void {
		h = untyped __new__(_global["Object"]);
	}

	public function set( key : String, value : T ) : Void {
		untyped h["$"+key] = value;
	}

	public function get( key : String ) : Null<T> {
		return untyped h["$"+key];
	}

	public function exists( key : String ) : Bool {
		return untyped h["hasOwnProperty"]("$"+key);
	}

	public function remove( key : String ) : Bool {
		key = "$"+key;
		if( untyped !h["hasOwnProperty"](key) ) return false;
		untyped __delete__(h,key);
		return true;
	}

	public function keys() : Iterator<String> {
		return untyped (__hkeys__(h))["iterator"]();
	}

	public function iterator() : Iterator<T> {
		return untyped {
			ref : h,
			it : __keys__(h)["iterator"](),
			hasNext : function() { return __this__.it[__unprotect__("hasNext")](); },
			next : function() { var i = __this__.it[__unprotect__("next")](); return __this__.ref[i]; }
		};
	}

	public function toString() : String {
		var s = new StringBuf();
		s.add("{");
		var it = keys();
		for( i in it ) {
			s.add(i);
			s.add(" => ");
			s.add(Std.string(get(i)));
			if( it.hasNext() )
				s.add(", ");
		}
		s.add("}");
		return s.toString();
	}

}
