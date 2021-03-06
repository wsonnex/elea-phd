data Bool = True | False;
data List a = Nil | Cons a (List a);
data Nat = Z | Suc Nat;

even (add (len xs) (len ys)) where

even = \n -> 
  case n of {
    Z -> True;
    Suc n1 ->
      case n1 of {
        Z -> False;
        Suc n2 -> even n2;
      };
  };
  
add = \n m ->
  case n of {
    Z -> m;
    Suc n1 -> Suc (add n1 m);
  };
  
app = \xs ys ->
	case xs of {
		Nil -> ys;
		Cons x1 xs1 -> Cons x1 (app xs1 ys);
	};
	
len = \xs ->
  case xs of {
    Nil -> Z;
    Cons x xs1 -> Suc (len xs1);
  };