class Fib
{
	static public function main()
	{
		trace( fib( 10 ) );
	}

	static public function fib( n : Int ) : Int
	{
		if( n <= 1 )
		{
			return 1;
		}
		else
		{
			return fib( n-1 ) + fib( n-2 );
		}
	}
}

