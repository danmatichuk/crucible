public class DoubleSum
{
    // java claims that this will pass,
    // but it fails for some reason
    public static void main(String[] args)
    {
	double i2 = 2;
	double sum = (3.4 + i2);
	System.out.println(sum);

	if (sum != 5.4) {
	    System.out.println("FAIL");
	}
	else {
	    System.out.println("PASS");
      }	
    }
    
 
}
