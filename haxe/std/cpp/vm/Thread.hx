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
package cpp.vm;

typedef ThreadHandle = Dynamic;

class Thread {

	var handle : ThreadHandle;

	function new(h) {
		handle = h;
	}

	/**
		Send a message to the thread queue. This message can be readed by using [readMessage].
	**/
	public function sendMessage( msg : Dynamic ) {
		untyped __global__.__hxcpp_thread_send(handle,msg);
	}


	/**
		Returns the current thread.
	**/
	public static function current() {
		return new Thread(untyped __global__.__hxcpp_thread_current());
	}

	/**
		Creates a new thread that will execute the [callb] function, then exit.
	**/
	public static function create( callb : Void -> Void ) {
		return new Thread(untyped __global__.__hxcpp_thread_create(callb));
	}

	/**
		Reads a message from the thread queue. If [block] is true, the function
		blocks until a message is available. If [block] is false, the function
		returns [null] if no message is available.
	**/
	public static function readMessage( block : Bool ) : Dynamic {
		return untyped __global__.__hxcpp_thread_read_message(block);
	}

	function __compare(t) : Int {
		return handle == t.handle ? 0 : 1;
	}

}

