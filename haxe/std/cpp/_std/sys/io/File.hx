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
package sys.io;

@:core_api
class File {

	public static function getContent( path : String ) : String {
		var b = getBytes(path);
		return b.toString();
	}

	public static function getBytes( path : String ) : haxe.io.Bytes {
		var data:haxe.io.BytesData = file_contents(path);
		return haxe.io.Bytes.ofData(data);
	}

	public static function saveContent( path : String, content : String ) : Void {
		var f = write(path);
		f.writeString(content);
		f.close();
	}

	public static function saveBytes( path : String, bytes : haxe.io.Bytes ) : Void {
		var f = write(path);
		f.write(bytes);
		f.close();
	}

	public static function read( path : String, binary : Bool = true ) : FileInput {
		return untyped new FileInput(file_open(path,(if( binary ) "rb" else "r")));
	}

	public static function write( path : String, binary : Bool = true ) : FileOutput {
		return untyped new FileOutput(file_open(path,(if( binary ) "wb" else "w")));
	}

	public static function append( path : String, binary : Bool = true ) : FileOutput {
		return untyped new FileOutput(file_open(path,(if( binary ) "ab" else "a")));
	}

	public static function copy( src : String, dst : String ) : Void {
		var s = read(src,true);
		var d = write(dst,true);
		d.writeInput(s);
		s.close();
		d.close();
	}

	private static var file_contents = cpp.Lib.load("std","file_contents",1);
	private static var file_open = cpp.Lib.load("std","file_open",2);


}
