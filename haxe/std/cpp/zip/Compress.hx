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
package cpp.zip;
 
class Compress {
 
	var s : Dynamic;
 
	public function new( level : Int ) {
		s = _deflate_init(level);
	}
 
	public function execute( src : haxe.io.Bytes, srcPos : Int, dst : haxe.io.Bytes, dstPos : Int ) : { done : Bool, read : Int, write : Int } {
		return _deflate_buffer(s,src.getData(),srcPos,dst.getData(),dstPos);
	}
 
	public function setFlushMode( f : Flush ) {
		_set_flush_mode(s,Std.string(f));
	}
 
	public function close() {
		_deflate_end(s);
	}
 
	public static function run( s : haxe.io.Bytes, level : Int ) : haxe.io.Bytes {
		var c = new Compress(level);
		c.setFlushMode(Flush.FINISH);
		var out = haxe.io.Bytes.alloc(_deflate_bound(c.s,s.length));
		var r = c.execute(s,0,out,0);
		c.close();
		if( !r.done || r.read != s.length )
			throw "Compression failed";
		return out.sub(0,r.write);
	}
 
	static var _deflate_init = cpp.Lib.load("zlib","deflate_init",1);
	static var _deflate_bound = cpp.Lib.load("zlib","deflate_bound",2);
	static var _deflate_buffer = cpp.Lib.load("zlib","deflate_buffer",5);
	static var _deflate_end = cpp.Lib.load("zlib","deflate_end",1);
	static var _set_flush_mode = cpp.Lib.load("zlib","set_flush_mode",2);
 
}
