module TParsec.Types

import public Control.Monad.State
import public Control.Monad.Trans
import Data.Vect
import Data.Nat
import Data.List
import Util
import Relation.Subset
import Relation.Indexed
import Data.Inspect
import TParsec.Success
import TParsec.Result

||| Position in the input string

public export
record Position where
  constructor MkPosition
  ||| Line number (starting from 0)
  line   : Nat
  ||| Character offset in the given line
  offset : Nat

public export
Show Position where
  show (MkPosition line offset) = show line ++ ":" ++ show offset

public export
Eq Position where
  (MkPosition l1 o1) == (MkPosition l2 o2) = l1 == l2 && o1 == o2

public export
start : Position
start = MkPosition 0 0

||| Every `Char` induces an action on `Position`s
public export
update : Char -> Position -> Position
update c p = if c == '\n'
               then MkPosition (S (line p)) 0
               else record { offset = S (offset p) } p

public export
updates : String -> Position -> Position
updates str p = foldl (flip update) p (unpack str)

||| A parser is parametrised by some types and type constructors.
||| They are grouped in a `Parameters` record.
||| @ m is the monad the parser uses.
public export
record Parameters (m : Type -> Type) where
  constructor MkParameters
  ||| Type of tokens
  Tok : Type
  ||| Type of sized input (~ Vec Tok)
  Toks : Nat -> Type
  ||| The action allowing us to track consumed tokens
  recordToken : Tok -> m ()

||| A parser is the ability to, given an input, return a computation for
||| a success.
||| @ mn the monad used for parsing
||| @ p the parameters
||| @ a the type of value produced
||| @ n an upper bound on the size of the inputs it can deal with
public export
record Parser (mn : Type -> Type)
              (p : Parameters mn)
              (a : Type)
              (n : Nat) where
  constructor MkParser
  runParser : {m : Nat} -> LTE m n -> (Toks p) m -> mn (Success (Toks p) a m)

||| `TParsecT` is the monad transformer one would typically use when defining
||| an instrumented parser
||| @ e the errors the parser may raise
||| @ an the annotations the user can put on subparses
||| @ m the monad the transformer acts upon
||| @ a the type of values it returns
public export
record TParsecT (e : Type) (an : Type) (m : Type -> Type) (a : Type) where
  constructor MkTPT
  runTPT : StateT (Position, List an) (ResultT e m) a

public export
Functor m => Functor (TParsecT e a m) where
  map f (MkTPT a) = MkTPT $ map f a

public export
Monad m => Applicative (TParsecT e a m) where
  pure a = MkTPT $ pure a
  (MkTPT f) <*> (MkTPT a) = MkTPT (f <*> a)

public export
Monad m => Monad (TParsecT e a m) where
  (MkTPT a) >>= f = MkTPT $ a >>= (runTPT . f)

public export
MonadTrans (TParsecT e a) where
  lift = MkTPT . lift . lift

||| The `Alternative` instance recovers from "soft" failures in the left branch
||| by exploring the right one. "hard" failures are final.
public export
(Monad m, Subset (Position, List a) e) => Alternative (TParsecT e a m) where
  empty = MkTPT $ ST $ MkRT . pure . SoftFail . into
  (MkTPT a) <|> (MkTPT b) = MkTPT $ ST $ \pos =>
    MkRT $ (runResultT $ runStateT a pos) >>= (\r => case r of
      SoftFail _ => runResultT $ runStateT b pos
      _ => pure r)

public export
getPosition : Monad m => TParsecT e a m Position
getPosition = MkTPT $ map fst get

public export
getAnnotations : Monad m => TParsecT e a m (List a)
getAnnotations = MkTPT $ map snd get

public export
withAnnotation : Monad m => a -> TParsecT e a m x -> TParsecT e a m x
withAnnotation a (MkTPT ms) = MkTPT $ do modify (map (Prelude.(::) a))
                                         s <- ms
                                         modify (map (List.drop 1))
                                         pure s
  
public export
recordChar : Monad m => Char -> TParsecT e a m ()
recordChar c = MkTPT $ ignore (modify (mapFst (update c)))

||| Commiting to a branch makes all the failures in that branch hard failures
||| that we cannot recover from
public export
commitT : Functor m => TParsecT e a m x -> TParsecT e a m x
commitT (MkTPT m) = MkTPT $ ST $ \pos =>
   MkRT $ map (result HardFail HardFail Value) (runResultT $ runStateT m pos)

public export
commit : Functor mn => All (Parser (TParsecT e an mn) p a :-> Parser (TParsecT e an mn) p a)
commit p = MkParser $ \mlen, ts => commitT $ runParser p mlen ts

||| Specialized versions of `Parameters` and `TParsecT` for common use cases

public export
chars : Monad m => Parameters (TParsecT e a m)
chars = MkParameters Char (\n => Vect n Char) recordChar

public export
TParsecM : (e : Type) -> (an : Type) -> Type -> Type
TParsecM e an = TParsecT e an Identity

public export
TParsecU : Type -> Type
TParsecU = TParsecM () Void

public export
sizedtok : (tok : Type) -> Parameters TParsecU
sizedtok tok = MkParameters tok (\n => Vect n tok) (const $ pure ())

public export
Subset (Position, List Void) () where
  into = const ()