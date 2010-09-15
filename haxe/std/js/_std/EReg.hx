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

@:core_api class EReg {

	var r : Dynamic;

	public function new( r : String, opt : String ) : Void {
		opt = opt.split("u").join(""); // 'u' (utf8) depends on page encoding
		this.r = untyped __new__("RegExp",r,opt);
	}

	public function match( s : String ) : Bool {
		r.m = r.exec(s);
		r.s = s;
		r.l = untyped __js__("RegExp.leftContext");
		r.r = untyped __js__("RegExp.rightContext");
		return (r.m != null);
	}

	public function matched( n : Int ) : String {
		return if( r.m != null && n >= 0 && n < r.m.length ) r.m[n] else throw "EReg::matched";
	}

	public function matchedLeft() : String {
		if( r.m == null ) throw "No string matched";
		if( r.l == null ) return r.s.substr(0,r.m.index);
		return r.l;
	}

	public function matchedRight() : String {
		if( r.m == null ) throw "No string matched";
		if( r.r == null ) {
			var sz = r.m.index+r.m[0].length;
			return r.s.substr(sz,r.s.length-sz);
		}
		return r.r;
	}

	public function matchedPos() : { pos : Int, len : Int } {
		if( r.m == null ) throw "No string matched";
		return { pos : r.m.index, len : r.m[0].length };
	}

	public function split( s : String ) : Array<String> {
		// we can't use directly s.split because it's ignoring the 'g' flag
		var d = "#__delim__#";
		return untyped s.replace(r,d).split(d);
	}

	public function replace( s : String, by : String ) : String {
		return untyped s.replace(r,by);
	}

	public function customReplace( s : String, f : EReg -> String ) : String {
		var buf = new StringBuf();
		while( true ) {
			if( !match(s) )
				break;
			buf.add(matchedLeft());
			buf.add(f(this));
			s = matchedRight();
		}
		buf.add(s);
		return buf.toString();
	}

}
