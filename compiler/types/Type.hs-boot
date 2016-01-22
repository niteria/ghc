{-# LANGUAGE ImplicitParams #-}
module Type where
import TyCon
import {-# SOURCE #-} TyCoRep( Type, Kind )
import GHC.Stack (CallStack)

isPredTy :: Type -> Bool
isCoercionTy :: Type -> Bool

mkAppTy :: Type -> Type -> Type
piResultTy :: (?callStack :: CallStack) => Type -> Type -> Type

typeKind :: Type -> Kind
eqType :: Type -> Type -> Bool

coreViewOneStarKind :: Type -> Maybe Type

partitionInvisibles :: TyCon -> (a -> Type) -> [a] -> ([a], [a])

coreView :: Type -> Maybe Type
