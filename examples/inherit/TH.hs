{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

module TH where

import Language.Haskell.TH
import Language.Haskell.TH.Syntax
--
import FFICXX.Runtime.CodeGen.C
import FFICXX.Runtime.TH          ( FunctionParamInfo(..), IsCPrimitive(..), TemplateParamInfo(..) )
import FFICXX.Runtime.Function.Template
import FFICXX.Runtime.Function.TH ( genFunctionInstanceFor )

genFunctionInstanceFor
  [t|IO ()|]
  FPInfo {
    fpinfoCxxArgTypes = []
  , fpinfoCxxRetType = Nothing
  , fpinfoCxxHeaders =  []
  , fpinfoCxxNamespaces = []
  , fpinfoSuffix = "f1"
  }


-- newImplSub :: () => IO ImplSUb
-- newImplSub = xformnull c_impl_newimpl

genImplProxy :: Q [Dec]
genImplProxy = do
  addModFinalizer
    (addForeignSource LangCxx
      (   concatMap (renderCMacro . Include) ["functional", "Function.h", "InheritTestImpl.h", "test.h"]
       ++ "class ImplSub : public Impl {\n\
          \private:\n\
          \  std::function<void()>* fn;\n\
          \public:\n\
          \  ImplSub( void* fp ) {\n\
          \    fn = static_cast<std::function<void()>*>(fp);\n\
          \  }\n\
          \  virtual ~ImplSub() {}\n\
          \  virtual void action();\n\
          \};\n\
          \\n\
          \void ImplSub::action() {\n\
          \ (*(this->fn))();\n\
          \}\n\
          \\n\
          \typedef struct ImplSub_tag ImplSub_t;\n\
          \typedef ImplSub_t * ImplSub_p;\n\
          \typedef ImplSub_t const* const_ImplSub_p;\n\
          \\n\
          \IMPL_DEF_VIRT(ImplSub)\n\
          \\n"
      )
    )
  pure []

       {- ++ let headers = fpinfoCxxHeaders param
              f x = renderCMacro (Include x)
          in concatMap f headers
       ++ let nss = fpinfoCxxNamespaces param
              f x = renderCStmt (UsingNamespace x)
          in concatMap f nss
       ++ let retstr = fromMaybe "void" (fpinfoCxxRetType param)
              argstr = let args = fpinfoCxxArgTypes param
                           vs = case args of
                                  [] -> "(,)"
                                  _ -> intercalate "," $
                                         map (\(t,x) -> "(" ++ t ++ "," ++ x ++ ")") args
                       in "(" ++ vs ++ ")"
          in "Function(" ++ suffix ++ "," ++ retstr ++ "," ++ argstr ++ ")\n")) -}