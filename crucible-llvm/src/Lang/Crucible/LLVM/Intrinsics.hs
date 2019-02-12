-- |
-- Module           : Lang.Crucible.LLVM.Intrinsics
-- Description      : Override definitions for LLVM intrinsic and basic
--                    library functions
-- Copyright        : (c) Galois, Inc 2015-2016
-- License          : BSD3
-- Maintainer       : Rob Dockins <rdockins@galois.com>
-- Stability        : provisional
------------------------------------------------------------------------

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
module Lang.Crucible.LLVM.Intrinsics
( LLVM
, llvmIntrinsicTypes
, LLVMHandleInfo(..)
, LLVMContext(..)
, LLVMOverride(..)
, SymbolHandleMap
, symbolMap
, llvmTypeCtx
, mkLLVMContext
, register_llvm_override
, register_llvm_overrides
, build_llvm_override
, llvmDeclToFunHandleRepr
) where

import           GHC.TypeNats (KnownNat)
import           Control.Lens hiding (op, (:>), Empty)
import           Control.Monad.Reader
import           Control.Monad.State
import           Control.Monad.Trans.Maybe
import           Data.Bits
import           Data.Foldable( asum )
import qualified Data.Vector as V
import qualified Text.LLVM.AST as L

import qualified Data.Parameterized.Context as Ctx
import           Data.Parameterized.Context ( pattern (:>), pattern Empty )
import qualified Data.Parameterized.Map as MapF

import           What4.Interface

import           Lang.Crucible.Backend
import           Lang.Crucible.CFG.Common
import           Lang.Crucible.Types
import           Lang.Crucible.Simulator.Intrinsics
import           Lang.Crucible.Simulator.OverrideSim
import           Lang.Crucible.Simulator.RegMap
import           Lang.Crucible.Simulator.SimError (SimErrorReason(AssertFailureSimError))

import           Lang.Crucible.LLVM.Bytes (Bytes(..))
import           Lang.Crucible.LLVM.DataLayout (noAlignment)
import           Lang.Crucible.LLVM.Extension (ArchWidth, LLVM)
import           Lang.Crucible.LLVM.MemModel
import           Lang.Crucible.LLVM.Translation.Types
import           Lang.Crucible.LLVM.TypeContext (TypeContext)

import           Lang.Crucible.LLVM.Intrinsics.Common
import qualified Lang.Crucible.LLVM.Intrinsics.Libc as Libc
import qualified Lang.Crucible.LLVM.Intrinsics.Libcxx as Libcxx

llvmIntrinsicTypes :: IsSymInterface sym => IntrinsicTypes sym
llvmIntrinsicTypes =
   MapF.insert (knownSymbol :: SymbolRepr "LLVM_memory") IntrinsicMuxFn $
   MapF.insert (knownSymbol :: SymbolRepr "LLVM_pointer") IntrinsicMuxFn $
   MapF.empty

-- | Register all declare and define overrides
register_llvm_overrides ::
  (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch) =>
  L.Module ->
  LLVMContext arch ->
  OverrideSim p sym (LLVM arch) rtp l a (LLVMContext arch)
register_llvm_overrides llvmModule llvmctx =
  register_llvm_define_overrides llvmModule llvmctx >>=
    register_llvm_declare_overrides llvmModule

-- | Helper function for registering overrides
register_llvm_overrides_ ::
  (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch) =>
  LLVMContext arch ->
  [RegOverrideM p sym arch rtp l a ()] ->
  [L.Declare] ->
  OverrideSim p sym (LLVM arch) rtp l a (LLVMContext arch)
register_llvm_overrides_ llvmctx acts decls =
  flip execStateT llvmctx $
    forM_ decls $ \decl ->
      runMaybeT (flip runReaderT decl $ asum acts) >> return ()

register_llvm_define_overrides ::
  (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch) =>
  L.Module ->
  LLVMContext arch ->
  OverrideSim p sym (LLVM arch) rtp l a (LLVMContext arch)
register_llvm_define_overrides llvmModule llvmctx =
  let ?lc = llvmctx^.llvmTypeCtx
  in register_llvm_overrides_ llvmctx define_overrides $
       map defToDecl (L.modDefines llvmModule) ++ L.modDeclares llvmModule
  where defToDecl :: L.Define -> L.Declare
        defToDecl def =
          L.Declare { L.decRetType = L.defRetType def
                    , L.decName    = L.defName def
                    , L.decArgs    = map L.typedType (L.defArgs def)
                    , L.decVarArgs = L.defVarArgs def
                    , L.decAttrs   = L.defAttrs def
                    , L.decComdat  = Nothing
                    }

register_llvm_declare_overrides ::
  (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch) =>
  L.Module ->
  LLVMContext arch ->
  OverrideSim p sym (LLVM arch) rtp l a (LLVMContext arch)
register_llvm_declare_overrides llvmModule llvmctx =
  let ?lc = llvmctx^.llvmTypeCtx
  in register_llvm_overrides_ llvmctx declare_overrides $
       L.modDeclares llvmModule


-- | Register overrides for declared-but-not-defined functions
declare_overrides ::
  (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch, ?lc :: TypeContext) =>
  [RegOverrideM p sym arch rtp l a ()]
declare_overrides =
  [ register_llvm_override llvmLifetimeStartOverride
  , register_llvm_override llvmLifetimeEndOverride
  , register_llvm_override (llvmLifetimeOverrideOverload "start" (knownNat @8))
  , register_llvm_override (llvmLifetimeOverrideOverload "end" (knownNat @8))
  , register_llvm_override llvmMemcpyOverride_8_8_32
  , register_llvm_override llvmMemcpyOverride_8_8_64
  , register_llvm_override llvmMemmoveOverride_8_8_32
  , register_llvm_override llvmMemmoveOverride_8_8_64
  , register_llvm_override llvmMemsetOverride_8_32
  , register_llvm_override llvmMemsetOverride_8_64

  , register_llvm_override llvmObjectsizeOverride_32
  , register_llvm_override llvmObjectsizeOverride_64

  , register_llvm_override llvmObjectsizeOverride_32'
  , register_llvm_override llvmObjectsizeOverride_64'

  , register_llvm_override llvmStacksave
  , register_llvm_override llvmStackrestore

  , register_1arg_polymorphic_override "llvm.ctlz" (\w -> SomeLLVMOverride (llvmCtlz w))
  , register_1arg_polymorphic_override "llvm.cttz" (\w -> SomeLLVMOverride (llvmCttz w))
  , register_1arg_polymorphic_override "llvm.ctpop" (\w -> SomeLLVMOverride (llvmCtpop w))
  , register_1arg_polymorphic_override "llvm.bitreverse" (\w -> SomeLLVMOverride (llvmBitreverse w))

  , register_llvm_override (llvmBSwapOverride (knownNat @2))  -- 16 = 2 * 8
  , register_llvm_override (llvmBSwapOverride (knownNat @4))  -- 32 = 4 * 8
  , register_llvm_override (llvmBSwapOverride (knownNat @6))  -- 48 = 6 * 8
  , register_llvm_override (llvmBSwapOverride (knownNat @8))  -- 64 = 8 * 8
  , register_llvm_override (llvmBSwapOverride (knownNat @10)) -- 80 = 10 * 8
  , register_llvm_override (llvmBSwapOverride (knownNat @12)) -- 96 = 12 * 8
  , register_llvm_override (llvmBSwapOverride (knownNat @14)) -- 112 = 14 * 8
  , register_llvm_override (llvmBSwapOverride (knownNat @16)) -- 128 = 16 * 8

  , register_1arg_polymorphic_override "llvm.sadd.with.overflow"
      (\w -> SomeLLVMOverride (llvmSaddWithOverflow w))
  , register_1arg_polymorphic_override "llvm.uadd.with.overflow"
      (\w -> SomeLLVMOverride (llvmUaddWithOverflow w))
  , register_1arg_polymorphic_override "llvm.ssub.with.overflow"
      (\w -> SomeLLVMOverride (llvmSsubWithOverflow w))
  , register_1arg_polymorphic_override "llvm.usub.with.overflow"
      (\w -> SomeLLVMOverride (llvmUsubWithOverflow w))
  , register_1arg_polymorphic_override "llvm.smul.with.overflow"
      (\w -> SomeLLVMOverride (llvmSmulWithOverflow w))
  , register_1arg_polymorphic_override "llvm.umul.with.overflow"
      (\w -> SomeLLVMOverride (llvmUmulWithOverflow w))

  -- C standard library functions
  , register_llvm_override Libc.llvmAssertRtnOverride
  , register_llvm_override Libc.llvmMemcpyOverride
  , register_llvm_override Libc.llvmMemcpyChkOverride
  , register_llvm_override Libc.llvmMemmoveOverride
  , register_llvm_override Libc.llvmMemsetOverride
  , register_llvm_override Libc.llvmMemsetChkOverride
  , register_llvm_override Libc.llvmMallocOverride
  , register_llvm_override Libc.llvmCallocOverride
  , register_llvm_override Libc.llvmFreeOverride
  , register_llvm_override Libc.llvmReallocOverride
  , register_llvm_override Libc.llvmStrlenOverride
  , register_llvm_override Libc.llvmPrintfOverride
  , register_llvm_override Libc.llvmPrintfChkOverride
  , register_llvm_override Libc.llvmPutsOverride
  , register_llvm_override Libc.llvmPutCharOverride

  -- C++ standard library functions
  , Libcxx.register_cpp_override Libcxx.endlOverride

  -- Some architecture-dependent intrinsics
  , register_llvm_override llvmX86_SSE2_storeu_dq
  , register_llvm_override llvmX86_pclmulqdq
  ]


-- | Register those overrides that should apply even when the corresponding
-- function has a definition
define_overrides ::
  (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch, ?lc :: TypeContext) =>
  [RegOverrideM p sym arch rtp l a ()]
define_overrides =
  [ Libcxx.register_cpp_override Libcxx.putToOverride12
  , Libcxx.register_cpp_override Libcxx.endlOverride
  , Libcxx.register_cpp_override Libcxx.sentryOverride
  ]


-- | This intrinsic is currently a no-op.
--
-- We might want to support this in the future to catch undefined memory
-- accesses.
--
-- <https://llvm.org/docs/LangRef.html#llvm-lifetime-start-intrinsic LLVM docs>
llvmLifetimeStartOverride
  :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => LLVMOverride p sym arch (EmptyCtx ::> BVType 64 ::> LLVMPointerType wptr) UnitType
llvmLifetimeStartOverride =
  let nm = "llvm.lifetime.start" in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.PrimType $ L.Void
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PrimType $ L.Integer 64, L.PtrTo (L.PrimType $ L.Integer 8) ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> KnownBV @64 :> PtrRepr)
  UnitRepr
  (\_ops _sym _args -> return ())

-- | See comment on 'llvmLifetimeStartOverride'
--
-- <https://llvm.org/docs/LangRef.html#llvm-lifetime-end-intrinsic LLVM docs>
llvmLifetimeEndOverride
  :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => LLVMOverride p sym arch (EmptyCtx ::> BVType 64 ::> LLVMPointerType wptr) UnitType
llvmLifetimeEndOverride =
  let nm = "llvm.lifetime.end" in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.PrimType $ L.Void
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PrimType $ L.Integer 64, L.PtrTo (L.PrimType $ L.Integer 8) ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> KnownBV @64 :> PtrRepr)
  UnitRepr
  (\_ops _sym _args -> return ())

-- | This is a no-op.
--
-- The language reference doesn't mention the use of this intrinsic.
llvmLifetimeOverrideOverload
  :: forall width sym wptr arch p
   . ( 1 <= width, KnownNat width
     , IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => String -- ^ "start" or "end"
  -> NatRepr width
  -> LLVMOverride p sym arch
        (EmptyCtx ::> BVType 64 ::> LLVMPointerType wptr)
        UnitType -- It appears in practice that this is always void
llvmLifetimeOverrideOverload startOrEnd widthRepr =
  let
    width' :: Int
    width' = widthVal widthRepr
    nm = "llvm.lifetime." ++ startOrEnd ++ ".p0i" ++ show width'
  in LLVMOverride
      ( L.Declare
        { L.decRetType = L.PrimType $ L.Void
        , L.decName    = L.Symbol nm
        , L.decArgs    = [ L.PrimType $ L.Integer $ 64
                         , L.PtrTo $ L.PrimType $ L.Integer $ fromIntegral width'
                         ]
        , L.decVarArgs = False
        , L.decAttrs   = []
        , L.decComdat  = mempty
        }
      )
      (Empty :> KnownBV @64 :> PtrRepr)
      UnitRepr
      (\_ops _sym _args -> return ())

llvmStacksave
  :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => LLVMOverride p sym arch EmptyCtx (LLVMPointerType wptr)
llvmStacksave =
  let nm = "llvm.stacksave" in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.PtrTo $ L.PrimType $ L.Integer 8
    , L.decName    = L.Symbol nm
    , L.decArgs    = [
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  Empty
  PtrRepr
  (\_memOps sym _args -> liftIO (mkNullPointer sym PtrWidth))


llvmStackrestore
  :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => LLVMOverride p sym arch (EmptyCtx ::> LLVMPointerType wptr) UnitType
llvmStackrestore =
  let nm = "llvm.stackrestore" in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.PrimType $ L.Void
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PtrTo $ L.PrimType $ L.Integer 8
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> PtrRepr)
  UnitRepr
  (\_memOps _sym _args -> return ())

llvmMemmoveOverride_8_8_32
  :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => LLVMOverride p sym arch
         (EmptyCtx ::> LLVMPointerType wptr ::> LLVMPointerType wptr
                   ::> BVType 32 ::> BVType 32 ::> BVType 1)
         UnitType
llvmMemmoveOverride_8_8_32 =
  let nm = "llvm.memmove.p0i8.p0i8.i32" in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.PrimType L.Void
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PtrTo (L.PrimType $ L.Integer 8)
                     , L.PtrTo (L.PrimType $ L.Integer 8)
                     , L.PrimType $ L.Integer 32
                     , L.PrimType $ L.Integer 32
                     , L.PrimType $ L.Integer 1
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> PtrRepr :> PtrRepr :> KnownBV @32 :> KnownBV @32 :> KnownBV @1)
  UnitRepr
  (\memOps sym args -> Ctx.uncurryAssignment (Libc.callMemmove sym memOps) args)


llvmMemmoveOverride_8_8_64
  :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => LLVMOverride p sym arch
         (EmptyCtx ::> LLVMPointerType wptr ::> LLVMPointerType wptr
                   ::> BVType 64 ::> BVType 32 ::> BVType 1)
         UnitType
llvmMemmoveOverride_8_8_64 =
  let nm = "llvm.memmove.p0i8.p0i8.i64" in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.PrimType L.Void
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PtrTo (L.PrimType $ L.Integer 8)
                     , L.PtrTo (L.PrimType $ L.Integer 8)
                     , L.PrimType $ L.Integer 64
                     , L.PrimType $ L.Integer 32
                     , L.PrimType $ L.Integer 1
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> PtrRepr :> PtrRepr :> KnownBV @64 :> KnownBV @32 :> KnownBV @1)
  UnitRepr
  (\memOps sym args -> Ctx.uncurryAssignment (Libc.callMemmove sym memOps) args)


llvmMemsetOverride_8_64
  :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => LLVMOverride p sym arch
         (EmptyCtx ::> LLVMPointerType wptr
                   ::> BVType  8
                   ::> BVType 64
                   ::> BVType 32
                   ::> BVType 1)
         UnitType
llvmMemsetOverride_8_64 =
  let nm = "llvm.memset.p0i8.i64" in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.PrimType $ L.Void
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PtrTo (L.PrimType $ L.Integer 8)
                     , L.PrimType $ L.Integer  8
                     , L.PrimType $ L.Integer 64
                     , L.PrimType $ L.Integer 32
                     , L.PrimType $ L.Integer  1
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> PtrRepr :> KnownBV @8 :> KnownBV @64 :> KnownBV @32 :> KnownBV @1)
  UnitRepr
  (\memOps sym args -> Ctx.uncurryAssignment (Libc.callMemset sym memOps) args)


llvmMemsetOverride_8_32
  :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => LLVMOverride p sym arch
         (EmptyCtx ::> LLVMPointerType wptr
                   ::> BVType  8
                   ::> BVType 32
                   ::> BVType 32
                   ::> BVType 1)
         UnitType
llvmMemsetOverride_8_32 =
  let nm = "llvm.memset.p0i8.i32" in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.PrimType $ L.Void
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PtrTo (L.PrimType $ L.Integer 8)
                     , L.PrimType $ L.Integer  8
                     , L.PrimType $ L.Integer 32
                     , L.PrimType $ L.Integer 32
                     , L.PrimType $ L.Integer  1
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> PtrRepr :> KnownBV @8 :> KnownBV @32 :> KnownBV @32 :> KnownBV @1)
  UnitRepr
  (\memOps sym args -> Ctx.uncurryAssignment (Libc.callMemset sym memOps) args)

llvmMemcpyOverride_8_8_32
  :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => LLVMOverride p sym arch
          (EmptyCtx ::> LLVMPointerType wptr ::> LLVMPointerType wptr
                    ::> BVType 32 ::> BVType 32 ::> BVType 1)
          UnitType
llvmMemcpyOverride_8_8_32 =
  let nm = "llvm.memcpy.p0i8.p0i8.i32" in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.PrimType L.Void
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PtrTo (L.PrimType $ L.Integer 8)
                     , L.PtrTo (L.PrimType $ L.Integer 8)
                     , L.PrimType $ L.Integer 32
                     , L.PrimType $ L.Integer 32
                     , L.PrimType $ L.Integer 1
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> PtrRepr :> PtrRepr :> KnownBV @32 :> KnownBV @32 :> KnownBV @1)
  UnitRepr
  (\memOps sym args -> Ctx.uncurryAssignment (Libc.callMemcpy sym memOps) args)


llvmMemcpyOverride_8_8_64
  :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => LLVMOverride p sym arch
         (EmptyCtx ::> LLVMPointerType wptr ::> LLVMPointerType wptr
                   ::> BVType 64 ::> BVType 32 ::> BVType 1)
         UnitType
llvmMemcpyOverride_8_8_64 =
  let nm = "llvm.memcpy.p0i8.p0i8.i64" in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.PrimType L.Void
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PtrTo (L.PrimType $ L.Integer 8)
                     , L.PtrTo (L.PrimType $ L.Integer 8)
                     , L.PrimType $ L.Integer 64
                     , L.PrimType $ L.Integer 32
                     , L.PrimType $ L.Integer 1
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> PtrRepr :> PtrRepr :> KnownBV @64 :> KnownBV @32 :> KnownBV @1)
  UnitRepr
  (\memOps sym args -> Ctx.uncurryAssignment (Libc.callMemcpy sym memOps) args)

llvmObjectsizeOverride_32
  :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => LLVMOverride p sym arch (EmptyCtx ::> LLVMPointerType wptr ::> BVType 1) (BVType 32)
llvmObjectsizeOverride_32 =
  let nm = "llvm.objectsize.i32.p0i8" in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.PrimType $ L.Integer 32
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PtrTo $ L.PrimType $ L.Integer 8
                     , L.PrimType $ L.Integer 1
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> PtrRepr :> KnownBV @1)
  (KnownBV @32)
  (\memOps sym args -> Ctx.uncurryAssignment (callObjectsize sym memOps knownNat) args)

llvmObjectsizeOverride_32'
  :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => LLVMOverride p sym arch (EmptyCtx ::> LLVMPointerType wptr ::> BVType 1 ::> BVType 1) (BVType 32)
llvmObjectsizeOverride_32' =
  let nm = "llvm.objectsize.i32.p0i8" in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.PrimType $ L.Integer 32
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PtrTo $ L.PrimType $ L.Integer 8
                     , L.PrimType $ L.Integer 1
                     , L.PrimType $ L.Integer 1
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> PtrRepr :> KnownBV @1 :> KnownBV @1)
  (KnownBV @32)
  (\memOps sym args -> Ctx.uncurryAssignment (callObjectsize' sym memOps knownNat) args)

llvmObjectsizeOverride_64
  :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => LLVMOverride p sym arch (EmptyCtx ::> LLVMPointerType wptr ::> BVType 1) (BVType 64)
llvmObjectsizeOverride_64 =
  let nm = "llvm.objectsize.i64.p0i8" in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.PrimType $ L.Integer 64
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PtrTo $ L.PrimType $ L.Integer 8
                     , L.PrimType $ L.Integer 1
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> PtrRepr :> KnownBV @1)
  (KnownBV @64)
  (\memOps sym args -> Ctx.uncurryAssignment (callObjectsize sym memOps knownNat) args)

llvmObjectsizeOverride_64'
  :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => LLVMOverride p sym arch (EmptyCtx ::> LLVMPointerType wptr ::> BVType 1 ::> BVType 1) (BVType 64)
llvmObjectsizeOverride_64' =
  let nm = "llvm.objectsize.i64.p0i8" in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.PrimType $ L.Integer 64
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PtrTo $ L.PrimType $ L.Integer 8
                     , L.PrimType $ L.Integer 1
                     , L.PrimType $ L.Integer 1
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> PtrRepr :> KnownBV @1 :> KnownBV @1)
  (KnownBV @64)
  (\memOps sym args -> Ctx.uncurryAssignment (callObjectsize' sym memOps knownNat) args)

llvmSaddWithOverflow
  :: (1 <= w, IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => NatRepr w ->
     LLVMOverride p sym arch
         (EmptyCtx ::> BVType w ::> BVType w)
         (StructType (EmptyCtx ::> BVType w ::> BVType 1))
llvmSaddWithOverflow w =
  let nm = "llvm.sadd.with.overflow.i" ++ show (natValue w) in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.Struct
                     [ L.PrimType $ L.Integer (fromIntegral (natValue w))
                     , L.PrimType $ L.Integer 1
                     ]
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PrimType $ L.Integer (fromIntegral (natValue w))
                     , L.PrimType $ L.Integer (fromIntegral (natValue w))
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> BVRepr w :> BVRepr w)
  (StructRepr (Empty :> BVRepr w :> BVRepr (knownNat @1)))
  (\memOps sym args -> Ctx.uncurryAssignment (callSaddWithOverflow sym memOps) args)


llvmUaddWithOverflow
  :: (1 <= w, IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => NatRepr w ->
     LLVMOverride p sym arch
         (EmptyCtx ::> BVType w ::> BVType w)
         (StructType (EmptyCtx ::> BVType w ::> BVType 1))
llvmUaddWithOverflow w =
  let nm = "llvm.uadd.with.overflow.i" ++ show (natValue w) in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.Struct
                     [ L.PrimType $ L.Integer (fromIntegral (natValue w))
                     , L.PrimType $ L.Integer 1
                     ]
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PrimType $ L.Integer (fromIntegral (natValue w))
                     , L.PrimType $ L.Integer (fromIntegral (natValue w))
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> BVRepr w :> BVRepr w)
  (StructRepr (Empty :> BVRepr w :> BVRepr (knownNat @1)))
  (\memOps sym args -> Ctx.uncurryAssignment (callUaddWithOverflow sym memOps) args)


llvmSsubWithOverflow
  :: (1 <= w, IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => NatRepr w ->
     LLVMOverride p sym arch
         (EmptyCtx ::> BVType w ::> BVType w)
         (StructType (EmptyCtx ::> BVType w ::> BVType 1))
llvmSsubWithOverflow w =
  let nm = "llvm.ssub.with.overflow.i" ++ show (natValue w) in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.Struct
                     [ L.PrimType $ L.Integer (fromIntegral (natValue w))
                     , L.PrimType $ L.Integer 1
                     ]
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PrimType $ L.Integer (fromIntegral (natValue w))
                     , L.PrimType $ L.Integer (fromIntegral (natValue w))
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> BVRepr w :> BVRepr w)
  (StructRepr (Empty :> BVRepr w :> BVRepr (knownNat @1)))
  (\memOps sym args -> Ctx.uncurryAssignment (callSsubWithOverflow sym memOps) args)


llvmUsubWithOverflow
  :: (1 <= w, IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => NatRepr w ->
     LLVMOverride p sym arch
         (EmptyCtx ::> BVType w ::> BVType w)
         (StructType (EmptyCtx ::> BVType w ::> BVType 1))
llvmUsubWithOverflow w =
  let nm = "llvm.usub.with.overflow.i" ++ show (natValue w) in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.Struct
                     [ L.PrimType $ L.Integer (fromIntegral (natValue w))
                     , L.PrimType $ L.Integer 1
                     ]
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PrimType $ L.Integer (fromIntegral (natValue w))
                     , L.PrimType $ L.Integer (fromIntegral (natValue w))
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> BVRepr w :> BVRepr w)
  (StructRepr (Empty :> BVRepr w :> BVRepr (knownNat @1)))
  (\memOps sym args -> Ctx.uncurryAssignment (callUsubWithOverflow sym memOps) args)

llvmSmulWithOverflow
  :: (1 <= w, IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => NatRepr w ->
     LLVMOverride p sym arch
         (EmptyCtx ::> BVType w ::> BVType w)
         (StructType (EmptyCtx ::> BVType w ::> BVType 1))
llvmSmulWithOverflow w =
  let nm = "llvm.smul.with.overflow.i" ++ show (natValue w) in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.Struct
                     [ L.PrimType $ L.Integer (fromIntegral (natValue w))
                     , L.PrimType $ L.Integer 1
                     ]
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PrimType $ L.Integer (fromIntegral (natValue w))
                     , L.PrimType $ L.Integer (fromIntegral (natValue w))
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> BVRepr w :> BVRepr w)
  (StructRepr (Empty :> BVRepr w :> BVRepr (knownNat @1)))
  (\memOps sym args -> Ctx.uncurryAssignment (callSmulWithOverflow sym memOps) args)

llvmUmulWithOverflow
  :: (1 <= w, IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => NatRepr w ->
     LLVMOverride p sym arch
         (EmptyCtx ::> BVType w ::> BVType w)
         (StructType (EmptyCtx ::> BVType w ::> BVType 1))
llvmUmulWithOverflow w =
  let nm = "llvm.umul.with.overflow.i" ++ show (natValue w) in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.Struct
                     [ L.PrimType $ L.Integer (fromIntegral (natValue w))
                     , L.PrimType $ L.Integer 1
                     ]
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PrimType $ L.Integer (fromIntegral (natValue w))
                     , L.PrimType $ L.Integer (fromIntegral (natValue w))
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> BVRepr w :> BVRepr w)
  (StructRepr (Empty :> BVRepr w :> BVRepr (knownNat @1)))
  (\memOps sym args -> Ctx.uncurryAssignment (callUmulWithOverflow sym memOps) args)


llvmCtlz
  :: (1 <= w, IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => NatRepr w ->
     LLVMOverride p sym arch
         (EmptyCtx ::> BVType w ::> BVType 1)
         (BVType w)
llvmCtlz w =
  let nm = "llvm.ctlz.i" ++ show (natValue w) in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.PrimType $ L.Integer (fromIntegral (natValue w))
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PrimType $ L.Integer (fromIntegral (natValue w))
                     , L.PrimType $ L.Integer 1
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> BVRepr w :> KnownBV @1)
  (BVRepr w)
  (\memOps sym args -> Ctx.uncurryAssignment (callCtlz sym memOps) args)


llvmCttz
  :: (1 <= w, IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => NatRepr w
  -> LLVMOverride p sym arch
         (EmptyCtx ::> BVType w ::> BVType 1)
         (BVType w)
llvmCttz w =
  let nm = "llvm.cttz.i" ++ show (natValue w) in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.PrimType $ L.Integer (fromIntegral (natValue w))
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PrimType $ L.Integer (fromIntegral (natValue w))
                     , L.PrimType $ L.Integer 1
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> BVRepr w :> KnownBV @1)
  (BVRepr w)
  (\memOps sym args -> Ctx.uncurryAssignment (callCttz sym memOps) args)

llvmCtpop
  :: (1 <= w, IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => NatRepr w
  -> LLVMOverride p sym arch
         (EmptyCtx ::> BVType w)
         (BVType w)
llvmCtpop w =
  let nm = "llvm.ctpop.i" ++ show (natValue w) in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.PrimType $ L.Integer (fromIntegral (natValue w))
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PrimType $ L.Integer (fromIntegral (natValue w))
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> BVRepr w)
  (BVRepr w)
  (\memOps sym args -> Ctx.uncurryAssignment (callCtpop sym memOps) args)

llvmBitreverse
  :: (1 <= w, IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => NatRepr w
  -> LLVMOverride p sym arch
         (EmptyCtx ::> BVType w)
         (BVType w)
llvmBitreverse w =
  let nm = "llvm.bitreverse.i" ++ show (natValue w) in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.PrimType $ L.Integer (fromIntegral (natValue w))
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PrimType $ L.Integer (fromIntegral (natValue w))
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> BVRepr w)
  (BVRepr w)
  (\memOps sym args -> Ctx.uncurryAssignment (callBitreverse sym memOps) args)


-- | <https://llvm.org/docs/LangRef.html#llvm-bswap-intrinsics LLVM docs>
llvmBSwapOverride
  :: forall width sym wptr arch p
   . ( 1 <= width, IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => NatRepr width
  -> LLVMOverride p sym arch
         (EmptyCtx ::> BVType (width * 8))
         (BVType (width * 8))
llvmBSwapOverride widthRepr =
  let width8 = natMultiply widthRepr (knownNat @8)
      width' :: Int
      width' = widthVal width8
      nm = "llvm.bswap.i" ++ show width'
  in
    case mulComm widthRepr (knownNat @8) of { Refl ->
    case leqMulMono (knownNat @8) widthRepr :: LeqProof width (width * 8) of { LeqProof ->
    case leqTrans (LeqProof :: LeqProof 1 width)
                  (LeqProof :: LeqProof width (width * 8)) of { LeqProof ->
      LLVMOverride
        ( -- From the LLVM docs:
          -- declare i16 @llvm.bswap.i16(i16 <id>)
          L.Declare
          { L.decRetType = L.PrimType $ L.Integer $ fromIntegral width'
          , L.decName    = L.Symbol nm
          , L.decArgs    = [ L.PrimType $ L.Integer $ fromIntegral width' ]
          , L.decVarArgs = False
          , L.decAttrs   = []
          , L.decComdat  = mempty
          }
        )
        (Empty :> BVRepr width8)
        (BVRepr width8)
        (\_ sym args -> liftIO $
            let vec :: SymBV sym (width * 8)
                vec = regValue (args^._1)
            in bvSwap sym widthRepr vec)
    }}}


llvmX86_pclmulqdq
--declare <2 x i64> @llvm.x86.pclmulqdq(<2 x i64>, <2 x i64>, i8) #1
  :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => LLVMOverride p sym arch
         (EmptyCtx ::> VectorType (BVType 64)
                   ::> VectorType (BVType 64)
                   ::> BVType 8)
         (VectorType (BVType 64))
llvmX86_pclmulqdq =
  let nm = "llvm.x86.pclmulqdq" in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.Vector 2 (L.PrimType $ L.Integer 64)
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.Vector 2 (L.PrimType $ L.Integer 64)
                     , L.Vector 2 (L.PrimType $ L.Integer 64)
                     , L.PrimType $ L.Integer 8
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> VectorRepr (KnownBV @64) :> VectorRepr (KnownBV @64) :> KnownBV @8)
  (VectorRepr (KnownBV @64))
  (\memOps sym args -> Ctx.uncurryAssignment (callX86_pclmulqdq sym memOps) args)


llvmX86_SSE2_storeu_dq
  :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => LLVMOverride p sym arch
         (EmptyCtx ::> LLVMPointerType wptr
                   ::> VectorType (BVType 8))
         UnitType
llvmX86_SSE2_storeu_dq =
  let nm = "llvm.x86.sse2.storeu.dq" in
  LLVMOverride
  ( L.Declare
    { L.decRetType = L.PrimType $ L.Void
    , L.decName    = L.Symbol nm
    , L.decArgs    = [ L.PtrTo (L.PrimType $ L.Integer 8)
                     , L.Vector 16 (L.PrimType $ L.Integer 8)
                     ]
    , L.decVarArgs = False
    , L.decAttrs   = []
    , L.decComdat  = mempty
    }
  )
  (Empty :> PtrRepr :> VectorRepr (KnownBV @8))
  UnitRepr
  (\memOps sym args -> Ctx.uncurryAssignment (callStoreudq sym memOps) args)


callX86_pclmulqdq :: forall p sym arch wptr r args ret.
  (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch) =>
  sym ->
  GlobalVar Mem ->
  RegEntry sym (VectorType (BVType 64)) ->
  RegEntry sym (VectorType (BVType 64)) ->
  RegEntry sym (BVType 8) ->
  OverrideSim p sym (LLVM arch) r args ret (RegValue sym (VectorType (BVType 64)))
callX86_pclmulqdq sym _mvar
  (regValue -> xs)
  (regValue -> ys)
  (regValue -> imm) =
    do unless (V.length xs == 2) $
          liftIO $ addFailedAssertion sym $ AssertFailureSimError $ unlines
           ["Vector length mismatch in llvm.x86.pclmulqdq intrinsic"
           ,"Expected <2 x i64>, but got vector of length ", show (V.length xs)
           ]
       unless (V.length ys == 2) $
          liftIO $ addFailedAssertion sym $ AssertFailureSimError $ unlines
           ["Vector length mismatch in llvm.x86.pclmulqdq intrinsic"
           ,"Expected <2 x i64>, but got vector of length ", show (V.length ys)
           ]
       case asUnsignedBV imm of
         Just byte ->
           do let xidx = if byte .&. 0x01 == 0 then 0 else 1
              let yidx = if byte .&. 0x10 == 0 then 0 else 1
              liftIO $ doPcmul (xs V.! xidx) (ys V.! yidx)
         _ ->
             liftIO $ addFailedAssertion sym $ AssertFailureSimError $ unlines
                ["Illegal selector argument to llvm.x86.pclmulqdq"
                ,"  Expected concrete value but got ", show (printSymExpr imm)
                ]
  where
  doPcmul :: SymBV sym 64 -> SymBV sym 64 -> IO (V.Vector (SymBV sym 64))
  doPcmul x y =
    do r <- carrylessMultiply sym x y
       lo <- bvTrunc sym (knownNat @64) r
       hi <- bvSelect sym (knownNat @64) (knownNat @64) r
       -- NB, little endian because X86
       return $ V.fromList [ lo, hi ]

callStoreudq
  :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
  => sym
  -> GlobalVar Mem
  -> RegEntry sym (LLVMPointerType wptr)
  -> RegEntry sym (VectorType (BVType 8))
  -> OverrideSim p sym (LLVM arch) r args ret ()
callStoreudq sym mvar
  (regValue -> dest)
  (regValue -> vec) =
    do mem <- readGlobal mvar
       unless (V.length vec == 16) $
          liftIO $ addFailedAssertion sym $ AssertFailureSimError $ unlines
           ["Vector length mismatch in stored_qu intrinsic."
           ,"Expected <16 x i8>, but got vector of length ", show (V.length vec)
           ]
       mem' <- liftIO $ doStore
                 sym
                 mem
                 dest
                 (VectorRepr (KnownBV @8))
                 (arrayType 16 (bitvectorType (Bytes 1)))
                 noAlignment
                 vec
       writeGlobal mvar mem'


-- Excerpt from the LLVM documentation:
--
-- The llvm.objectsize intrinsic is designed to provide information to
-- the optimizers to determine at compile time whether a) an operation
-- (like memcpy) will overflow a buffer that corresponds to an object,
-- or b) that a runtime check for overflow isn’t necessary. An object
-- in this context means an allocation of a specific class, structure,
-- array, or other object.
--
-- The llvm.objectsize intrinsic takes two arguments. The first
-- argument is a pointer to or into the object. The second argument is
-- a boolean and determines whether llvm.objectsize returns 0 (if
-- true) or -1 (if false) when the object size is unknown. The second
-- argument only accepts constants.
--
-- The llvm.objectsize intrinsic is lowered to a constant representing
-- the size of the object concerned. If the size cannot be determined
-- at compile time, llvm.objectsize returns i32/i64 -1 or 0 (depending
-- on the min argument).
callObjectsize
  :: (1 <= w, IsSymInterface sym)
  => sym
  -> GlobalVar Mem
  -> NatRepr w
  -> RegEntry sym (LLVMPointerType wptr)
  -> RegEntry sym (BVType 1)
  -> OverrideSim p sym (LLVM arch) r args ret (RegValue sym (BVType w))
callObjectsize sym _mvar w
  (regValue -> _ptr)
  (regValue -> flag) = liftIO $ do
    -- Ignore the pointer value, and just return the value for unknown, as
    -- defined by the documenatation.  If an `objectsize` invocation survives
    -- through compilation for us to see, that means the compiler could not
    -- determine the value.
    t <- bvIsNonzero sym flag
    z <- bvLit sym w 0
    n <- bvNotBits sym z -- NB: -1 is the boolean negation of zero
    bvIte sym t z n

callObjectsize'
  :: (1 <= w, IsSymInterface sym)
  => sym
  -> GlobalVar Mem
  -> NatRepr w
  -> RegEntry sym (LLVMPointerType wptr)
  -> RegEntry sym (BVType 1)
  -> RegEntry sym (BVType 1)
  -> OverrideSim p sym (LLVM arch) r args ret (RegValue sym (BVType w))
callObjectsize' sym mvar w ptr flag _nullKnown = callObjectsize sym mvar w ptr flag


callCtlz
  :: (1 <= w, IsSymInterface sym)
  => sym
  -> GlobalVar Mem
  -> RegEntry sym (BVType w)
  -> RegEntry sym (BVType 1)
  -> OverrideSim p sym (LLVM arch) r args ret (RegValue sym (BVType w))
callCtlz sym _mvar
  (regValue -> val)
  (regValue -> isZeroUndef) = liftIO $
    do isNonzero <- bvIsNonzero sym val
       zeroOK    <- notPred sym =<< bvIsNonzero sym isZeroUndef
       p <- orPred sym isNonzero zeroOK
       assert sym p (AssertFailureSimError "Ctlz called with disallowed zero value")
       bvCountLeadingZeros sym val

callSaddWithOverflow
  :: (1 <= w, IsSymInterface sym)
  => sym
  -> GlobalVar Mem
  -> RegEntry sym (BVType w)
  -> RegEntry sym (BVType w)
  -> OverrideSim p sym (LLVM arch) r args ret (RegValue sym (StructType (EmptyCtx ::> BVType w ::> BVType 1)))
callSaddWithOverflow sym _mvar
  (regValue -> x)
  (regValue -> y) = liftIO $
    do (ov, z) <- addSignedOF sym x y
       ov' <- predToBV sym ov (knownNat @1)
       return (Empty :> RV z :> RV ov')

callUaddWithOverflow
  :: (1 <= w, IsSymInterface sym)
  => sym
  -> GlobalVar Mem
  -> RegEntry sym (BVType w)
  -> RegEntry sym (BVType w)
  -> OverrideSim p sym (LLVM arch) r args ret (RegValue sym (StructType (EmptyCtx ::> BVType w ::> BVType 1)))
callUaddWithOverflow sym _mvar
  (regValue -> x)
  (regValue -> y) = liftIO $
    do (ov, z) <- addUnsignedOF sym x y
       ov' <- predToBV sym ov (knownNat @1)
       return (Empty :> RV z :> RV ov')

callUsubWithOverflow
  :: (1 <= w, IsSymInterface sym)
  => sym
  -> GlobalVar Mem
  -> RegEntry sym (BVType w)
  -> RegEntry sym (BVType w)
  -> OverrideSim p sym (LLVM arch) r args ret (RegValue sym (StructType (EmptyCtx ::> BVType w ::> BVType 1)))
callUsubWithOverflow sym _mvar
  (regValue -> x)
  (regValue -> y) = liftIO $
    do (ov, z) <- subUnsignedOF sym x y
       ov' <- predToBV sym ov (knownNat @1)
       return (Empty :> RV z :> RV ov')

callSsubWithOverflow
  :: (1 <= w, IsSymInterface sym)
  => sym
  -> GlobalVar Mem
  -> RegEntry sym (BVType w)
  -> RegEntry sym (BVType w)
  -> OverrideSim p sym (LLVM arch) r args ret (RegValue sym (StructType (EmptyCtx ::> BVType w ::> BVType 1)))
callSsubWithOverflow sym _mvar
  (regValue -> x)
  (regValue -> y) = liftIO $
    do (ov, z) <- subSignedOF sym x y
       ov' <- predToBV sym ov (knownNat @1)
       return (Empty :> RV z :> RV ov')

callSmulWithOverflow
  :: (1 <= w, IsSymInterface sym)
  => sym
  -> GlobalVar Mem
  -> RegEntry sym (BVType w)
  -> RegEntry sym (BVType w)
  -> OverrideSim p sym (LLVM arch) r args ret (RegValue sym (StructType (EmptyCtx ::> BVType w ::> BVType 1)))
callSmulWithOverflow sym _mvar
  (regValue -> x)
  (regValue -> y) = liftIO $
    do (ov, z) <- mulSignedOF sym x y
       ov' <- predToBV sym ov (knownNat @1)
       return (Empty :> RV z :> RV ov')

callUmulWithOverflow
  :: (1 <= w, IsSymInterface sym)
  => sym
  -> GlobalVar Mem
  -> RegEntry sym (BVType w)
  -> RegEntry sym (BVType w)
  -> OverrideSim p sym (LLVM arch) r args ret (RegValue sym (StructType (EmptyCtx ::> BVType w ::> BVType 1)))
callUmulWithOverflow sym _mvar
  (regValue -> x)
  (regValue -> y) = liftIO $
    do (ov, z) <- mulUnsignedOF sym x y
       ov' <- predToBV sym ov (knownNat @1)
       return (Empty :> RV z :> RV ov')


callCttz
  :: (1 <= w, IsSymInterface sym)
  => sym
  -> GlobalVar Mem
  -> RegEntry sym (BVType w)
  -> RegEntry sym (BVType 1)
  -> OverrideSim p sym (LLVM arch) r args ret (RegValue sym (BVType w))
callCttz sym _mvar
  (regValue -> val)
  (regValue -> isZeroUndef) = liftIO $
    do isNonzero <- bvIsNonzero sym val
       zeroOK    <- notPred sym =<< bvIsNonzero sym isZeroUndef
       p <- orPred sym isNonzero zeroOK
       assert sym p (AssertFailureSimError "Cttz called with disallowed zero value")
       bvCountTrailingZeros sym val

callCtpop
  :: (1 <= w, IsSymInterface sym)
  => sym
  -> GlobalVar Mem
  -> RegEntry sym (BVType w)
  -> OverrideSim p sym (LLVM arch) r args ret (RegValue sym (BVType w))
callCtpop sym _mvar
  (regValue -> val) = liftIO $ bvPopcount sym val

callBitreverse
  :: (1 <= w, IsSymInterface sym)
  => sym
  -> GlobalVar Mem
  -> RegEntry sym (BVType w)
  -> OverrideSim p sym (LLVM arch) r args ret (RegValue sym (BVType w))
callBitreverse sym _mvar
  (regValue -> val) = liftIO $ bvBitreverse sym val
