data Bool = True | False;
data List a = Nil | Cons a (List a);
data Nat = Z | Suc Nat;

add (count n (Cons x Nil)) (count n xs) where

add = \n m ->
  case n of {
    Z -> m;
    Suc n1 -> Suc (add n1 m);
  };
  
eq = \n m ->
  case n of {
    Z -> case m of {
      Z -> True;
      Suc m1 -> False; 
    };
    Suc n1 -> case m of {
      Z -> False;
      Suc m1 -> eq n1 m1;
    };
  };
  
count = \n xs ->
  case xs of {
    Nil -> Z;
    Cons x xs1 ->
      case eq n x of {
        True -> Suc (count n xs1);
        False -> count n xs1;
      };
  };