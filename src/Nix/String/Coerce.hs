{-# language CPP #-}

module Nix.String.Coerce where

import           Control.Monad.Catch            ( MonadThrow )
import           GHC.Exception                  ( ErrorCall(ErrorCall) )
import qualified Data.HashMap.Lazy             as M
import           Nix.Atoms
import           Nix.Expr.Types                 ( VarName )
import           Nix.Effects
import           Nix.Frames
import           Nix.String
import           Nix.Value
import           Nix.Value.Monad

#ifdef MIN_VERSION_ghc_datasize
import           GHC.DataSize
#endif

-- | Data type to avoid boolean blindness on what used to be called coerceMore
data CoercionLevel
  = CoerceStringy
  -- ^ Coerce only stringlike types: strings, paths, and appropriate sets
  | CoerceAny
  -- ^ Coerce everything but functions
  deriving (Eq,Ord,Enum,Bounded)

-- | Data type to avoid boolean blindness on what used to be called copyToStore
data CopyToStoreMode
  = CopyToStore
  -- ^ Add paths to the store as they are encountered
  | DontCopyToStore
  -- ^ Add paths to the store as they are encountered
  deriving (Eq,Ord,Enum,Bounded)

--  2021-10-30: NOTE: This seems like metafunction that really is a bunch of functions thrown together.
-- Both code blocks are `\case` - which means they can be or 2 functions, or just as well can be one `\case` that goes through all of them and does not require a `CoercionLevel`. Use of function shows that - the `CoercionLevel` not once was used polymorphically.
-- Also `CopyToStoreMode` acts only in case of `NVPath` - that is a separate function
coerceToString
  :: forall e t f m
   . ( Framed e m
     , MonadStore m
     , MonadThrow m
     , MonadDataErrorContext t f m
     , MonadValue (NValue t f m) m
     )
  => (NValue t f m -> NValue t f m -> m (NValue t f m))
  -> CopyToStoreMode
  -> CoercionLevel
  -> NValue t f m
  -> m NixString
coerceToString call ctsm clevel = go
 where
  go :: NValue t f m -> m NixString
  go x =
    bool
      coerceAny
      coerceStringy
      (clevel == CoerceStringy)
      =<< demand x
     where

      castToNixString = pure . mkNixStringWithoutContext

      coerceAny :: NValue t f m -> m NixString
      coerceAny =
        \case
          -- TODO Return a singleton for "" and "1"
          NVConstant (NBool b) ->
            castToNixString $ "1" `whenTrue` b
          NVConstant (NInt n) ->
            castToNixString $ show n
          NVConstant (NFloat n) ->
            castToNixString $ show n
          NVConstant NNull ->
            castToNixString mempty
          -- NVConstant: NAtom (NURI Text) is not matched
          NVList l ->
            nixStringUnwords <$> traverse go l
          v -> coerceStringy v
       where
        nixStringUnwords = intercalateNixString $ mkNixStringWithoutContext " "

      coerceStringy :: NValue t f m -> m NixString
      coerceStringy = coerceStringlikeToNixString call ctsm

coerceStringlikeToNixString
  :: forall e t f m
   . ( Framed e m
     , MonadStore m
     , MonadThrow m
     , MonadDataErrorContext t f m
     , MonadValue (NValue t f m) m
     )
  => (NValue t f m -> NValue t f m -> m (NValue t f m))
  -> CopyToStoreMode
  -> NValue t f m
  -> m NixString
coerceStringlikeToNixString call ctsm = go <=< demand
 where
  go :: NValue t f m -> m NixString
  go =
    \case
      NVStr ns -> pure ns
      NVPath p -> coercePathToNixString ctsm p
      --  2021-10-30: NOTE: Code quality famously counts in WTFs. Set is String-like?
      -- It probaly needs a separate function with an understandable name.
      v@(NVSet _ s) ->
        fromMaybe
          (err v)
          $ continueOnKey (`call` v) "__toString"
          <|> continueOnKey pure "outPath"
       where
        continueOnKey :: (NValue t f m -> m (NValue t f m)) -> VarName -> Maybe (m NixString)
        continueOnKey f = fmap (go <=< f <=< demand) . (`M.lookup` s)
      v -> err v
      where
      err v = throwError $ ErrorCall $ "Expected a string, but saw: " <> show v

-- | Convert @Path@ into @NixString@.
-- With an additional option to store the resolved path into Nix Store.
coercePathToNixString :: (MonadStore m, Framed e m) => CopyToStoreMode -> Path -> m NixString
coercePathToNixString ctsm =
  bool
    (pure . mkNixStringWithoutContext . fromString . coerce)
    (fmap storePathToNixString . addPath)
    (ctsm == CopyToStore)
 where
  storePathToNixString :: StorePath -> NixString
  storePathToNixString (fromString . coerce -> sp) =
    join (flip mkNixStringWithSingletonContext . (`StringContext` DirectPath)) sp
