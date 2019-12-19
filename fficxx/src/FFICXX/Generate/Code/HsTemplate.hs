{-# LANGUAGE RecordWildCards   #-}

module FFICXX.Generate.Code.HsTemplate where

import Data.Monoid                    ( (<>) )
import qualified Data.List as L       ( foldr1, intercalate )
import Language.Haskell.Exts.Build    ( app, binds, caseE, doE
                                      , letE, letStmt, name
                                      , pApp, paren, pTuple
                                      , qualStmt, strE, tuple
                                      )
import Language.Haskell.Exts.Syntax   ( Boxed(Boxed), Decl(..), Type(TyTuple) )
--
import FFICXX.Runtime.CodeGen.Cxx     ( HeaderName(..) )
import qualified FFICXX.Runtime.CodeGen.Cxx as R
import FFICXX.Runtime.TH              ( IsCPrimitive(CPrim,NonCPrim) )
--
import FFICXX.Generate.Code.Cpp       ( genTmplClassCpp, genTmplFunCpp )

import FFICXX.Generate.Code.Primitive ( functionSignatureT
                                      , functionSignatureTT
                                      , functionSignatureTMF
                                      )
import FFICXX.Generate.Code.HsCast    ( castBody )
import FFICXX.Generate.Name           ( ffiTmplFuncName
                                      , hsTemplateClassName
                                      , hsTemplateMemberFunctionName
                                      , hsTemplateMemberFunctionNameTH
                                      , hsTmplFuncName
                                      , hsTmplFuncNameTH
                                      , typeclassNameT
                                      )
import FFICXX.Generate.Type.Class     ( Class(..)
                                      , TemplateClass(..)
                                      , TemplateFunction(..)
                                      , TemplateMemberFunction(..)
                                      )
import FFICXX.Generate.Type.Module    ( ClassImportHeader(..)
                                      , TemplateClassImportHeader(..)
                                      )
import FFICXX.Generate.Util.HaskellSrcExts
                                      ( bracketExp
                                      , con, conDecl, cxEmpty, clsDecl
                                      , generator
                                      , inapp, insDecl, insType
                                      , lambda, list
                                      , match, mkBind1, mkTBind, mkData, mkNewtype
                                      , mkFun, mkFunSig, mkClass, mkInstance
                                      , mkPVar, mkTVar, mkVar
                                      , op, pbind_
                                      , qualConDecl, qualifier
                                      , tyapp, tycon, tyfun, tylist, tyPtr
                                      , typeBracket
                                      )


------------------------------
-- Template member function --
------------------------------

genTemplateMemberFunctions :: ClassImportHeader -> [Decl ()]
genTemplateMemberFunctions cih =
  let c = cihClass cih
  in concatMap (\f -> genTMFExp c f <> genTMFInstance cih f) (class_tmpl_funcs c)


genTMFExp :: Class -> TemplateMemberFunction -> [Decl ()]
genTMFExp c f = mkFun nh sig [p "typ", p "suffix"] rhs (Just bstmts)
  where
    nh = hsTemplateMemberFunctionNameTH c f
    sig = tycon "Type" `tyfun` (tycon "String" `tyfun` (tyapp (tycon "Q") (tycon "Exp")))
    v = mkVar
    p = mkPVar
    tp = tmf_param f
    lit' = strE (hsTemplateMemberFunctionName c f <> "_")
    lam = lambda [p "n"] ( lit' `app` v "<>" `app` v "n")
    rhs = app (v "mkTFunc") (tuple [v "typ", v "suffix", lam, v "tyf"])
    sig' = functionSignatureTMF c f
    bstmts = binds [ mkBind1 "tyf" [mkPVar "n"]
                       (letE [ pbind_ (p tp) (v "pure" `app` (v "typ")) ]
                          (bracketExp (typeBracket sig')))
                       Nothing
                   ]

genTMFInstance :: ClassImportHeader -> TemplateMemberFunction -> [Decl ()]
genTMFInstance cih f = mkFun fname sig [p "isCprim", p "qtyp", p "param"] rhs Nothing
  where
    c = cihClass cih
    fname = "genInstanceFor_" <> hsTemplateMemberFunctionName c f
    p = mkPVar
    v = mkVar
    sig =         tycon "IsCPrimitive"
          `tyfun` (tycon "Q" `tyapp` tycon "Type")
          `tyfun` tycon "TemplateParamInfo"
          `tyfun` (tycon "Q" `tyapp` tylist (tycon "Dec"))
    rhs = doE [suffixstmt, qtypstmt, genstmt, foreignSrcStmt, letStmt lststmt, qualStmt retstmt]
    suffixstmt = letStmt [ pbind_ (p "suffix") (v "tpinfoSuffix" `app` v "param" ) ]
    qtypstmt = generator (p "typ") (v "qtyp")
    genstmt = generator
                (p "f1")
                (v "mkMember" `app` (     strE (hsTemplateMemberFunctionName c f <> "_")
                                    `app` v "<>"
                                    `app` v "suffix"
                                    )
                              `app` v (hsTemplateMemberFunctionNameTH c f)
                              `app` v "typ"
                              `app` v "suffix"
                )
    lststmt = [ pbind_ (p "lst") (list ([v "f1"])) ]
    retstmt = v "pure" `app` v "lst"
    -- TODO: refactor out the following code.
    foreignSrcStmt =
      qualifier $
              (v "addModFinalizer")
        `app` (      v "addForeignSource"
               `app` con "LangCxx"
               `app` (L.foldr1 (\x y -> inapp x (op "++") y)
                        [ includeStatic
                        , includeDynamic
                        , namespaceStr
                        , strE (hsTemplateMemberFunctionName c f)
                        , strE "("
                        , v "suffix"
                        , strE ")\n"
                        ]
                     )
              )
      where
        includeStatic =
          strE $ concatMap ((<>"\n") . R.renderCMacro . R.Include) $
               [ HdrName "MacroPatternMatch.h", cihSelfHeader cih ]
            <> cihIncludedHPkgHeadersInCPP cih
            <> cihIncludedCPkgHeaders cih
        includeDynamic =
          letE
            [ pbind_ (p "headers") (v "tpinfoCxxHeaders" `app` v "param" )
            , pbind_ (pApp (name "f") [p "x"])
                (v "renderCMacro" `app` (con "Include" `app` v "x"))
            ]
            (v "concatMap" `app` v "f" `app` v "headers")
        namespaceStr =
          letE
            [ pbind_ (p "nss") (v "tpinfoCxxNamespaces" `app` v "param" )
            , pbind_ (pApp (name "f") [p "x"])
                (v "renderCStmt" `app` (con "UsingNamespace" `app` v "x"))
            ]
            (v "concatMap" `app` v "f" `app` v "nss")

--------------------
-- Template Class --
--------------------

genTmplInterface :: TemplateClass -> [Decl ()]
genTmplInterface t =
  [ mkData rname (map mkTBind tps) [] Nothing
  , mkNewtype hname (map mkTBind tps)
      [ qualConDecl Nothing Nothing (conDecl hname [tyapp tyPtr rawtype]) ] Nothing
  , mkClass cxEmpty (typeclassNameT t) (map mkTBind tps) methods
  , mkInstance cxEmpty "FPtr" [ hightype ] fptrbody
  , mkInstance cxEmpty "Castable" [ hightype, tyapp tyPtr rawtype ] castBody
  ]
 where (hname,rname) = hsTemplateClassName t
       tps = tclass_params t
       fs = tclass_funcs t
       rawtype  = foldl1 tyapp (tycon rname : map mkTVar tps)
       hightype = foldl1 tyapp (tycon hname : map mkTVar tps)
       sigdecl f = mkFunSig (hsTmplFuncName t f) (functionSignatureT t f)
       methods = map (clsDecl . sigdecl) fs
       fptrbody = [ insType (tyapp (tycon "Raw") hightype) rawtype
                  , insDecl (mkBind1 "get_fptr" [pApp (name hname) [mkPVar "ptr"]] (mkVar "ptr") Nothing)
                  , insDecl (mkBind1 "cast_fptr_to_obj" [] (con hname) Nothing)
                  ]


genTmplImplementation :: TemplateClass -> [Decl ()]
genTmplImplementation t = concatMap gen (tclass_funcs t)
  where
    gen f = mkFun nh sig (tvars_p ++ [p "suffix"]) rhs (Just bstmts)
      where nh = hsTmplFuncNameTH t f
            nc = ffiTmplFuncName f
            v = mkVar
            p = mkPVar
            itps = zip ([1..]::[Int]) (tclass_params t)
            tvars = map (\(i,_) -> "typ" ++ show i) itps
            nparams = length itps
            tparams = if nparams == 1 then tycon "Type" else TyTuple () Boxed (replicate nparams (tycon "Type"))
            sig = foldr1 tyfun [tparams , tycon "String", tyapp (tycon "Q") (tycon "Exp") ]
            tvars_p = if nparams == 1 then map p tvars else [pTuple (map p tvars)]
            prefix = tclass_name t
            lit' = strE (prefix<>"_"<>nc<>"_")
            lam = lambda [p "n"] ( lit' `app` v "<>" `app` v "n")
            rhs = app (v "mkTFunc") $
                    let typs = if nparams == 1 then map v tvars else [tuple (map v tvars)]
                    in tuple (typs ++ [ v "suffix", lam, v "tyf"])
            sig' = functionSignatureTT t f
            tassgns = map (\(i,tp) -> pbind_ (p tp) (v "pure" `app` (v ("typ" ++ show i)))) itps
            bstmts = binds [ mkBind1 "tyf" [mkPVar "n"]
                               (letE tassgns
                                  (bracketExp (typeBracket sig')))
                               Nothing
                           ]

genTmplInstance ::
     TemplateClassImportHeader
  -> [Decl ()]
genTmplInstance tcih =
    mkFun fname sig ([p "isCprim"] ++ map p qtvars ++ [p "param"]) rhs Nothing
  where t = tcihTClass tcih
        fs = tclass_funcs t
        tname = tclass_name t
        fname = "gen" <> tname <> "InstanceFor"
        p = mkPVar
        v = mkVar
        itps = zip ([1..]::[Int]) (tclass_params t)
        tvars = map (\(i,_) -> "typ" ++ show i) itps
        qtvars = map (\(i,_) -> "qtyp" ++ show i) itps
        nparams = length itps
        typs_v = if nparams == 1 then v (tvars !! 0) else tuple (map v tvars)
        sig = foldr1 tyfun $
                   [ tycon "IsCPrimitive" ]
                ++ replicate nparams (tycon "Q" `tyapp` tycon "Type")
                ++ [ tycon "TemplateParamInfo"
                   , tycon "Q" `tyapp` tylist (tycon "Dec")
                   ]
        nfs = zip ([1..] :: [Int]) fs
        rhs = doE (   [ suffixstmt ]
                   <> map genqtypstmt (zip tvars qtvars)
                   <> map genstmt nfs
                   <> [foreignSrcStmt, letStmt (lststmt nfs), qualStmt retstmt]
                  )
        suffixstmt = letStmt [ pbind_ (p "suffix") (v "tpinfoSuffix" `app` v "param" ) ]
        genqtypstmt (tvar,qtvar) = generator (p tvar) (v qtvar)
        genstmt (n,f@TFun    {..}) = generator
                                       (p ("f"<>show n))
                                       (v "mkMember" `app` strE (hsTmplFuncName t f)
                                                     `app` v    (hsTmplFuncNameTH t f)
                                                     `app` typs_v
                                                     `app` v    "suffix"
                                       )
        genstmt (n,f@TFunNew {..}) = generator
                                       (p ("f"<>show n))
                                       (v "mkNew"    `app` strE (hsTmplFuncName t f)
                                                     `app` v    (hsTmplFuncNameTH t f)
                                                     `app` typs_v
                                                     `app` v    "suffix"
                                       )
        genstmt (n,f@TFunDelete)   = generator
                                       (p ("f"<>show n))
                                       (v "mkDelete" `app` strE (hsTmplFuncName t f)
                                                     `app` v    (hsTmplFuncNameTH t f)
                                                     `app` typs_v
                                                     `app` v    "suffix"
                                       )
        lststmt xs = [ pbind_ (p "lst") (list (map (v . (\n->"f"<>show n) . fst) xs)) ]
        -- TODO: refactor out the following code.
        foreignSrcStmt =
          qualifier $
                  (v "addModFinalizer")
            `app` (      v "addForeignSource"
                   `app` con "LangCxx"
                   `app` (L.foldr1 (\x y -> inapp x (op "++") y)
                            [ includeStatic
                            , includeDynamic
                            , namespaceStr
                            , strE (tname <> "_instance")
                            , paren $
                                caseE
                                  (v "isCprim")
                                  [ match (p "CPrim")    (strE "_s")
                                  , match (p "NonCPrim") (strE "")
                                  ]
                            , strE "("
                            , v "suffix"
                            , strE ")\n"
                            ]
                         )
                  )
          where
            -- temporary

            body = let
                     t = tcihTClass tcih
                     fs = tclass_funcs t
                   in map R.renderCMacro $
                           map R.Include (tcihCxxHeaders tcih)
                        ++ map (genTmplFunCpp NonCPrim t) fs
                        ++ map (genTmplFunCpp CPrim    t) fs
                        ++ [ genTmplClassCpp NonCPrim t fs
                           , genTmplClassCpp CPrim    t fs
                           ]

            includeStatic =
              strE $ concatMap (<> "\n")
                       (   [ R.renderCMacro (R.Include (HdrName "MacroPatternMatch.h")) ]
                        ++ body
                       )
            includeDynamic =
              letE
                [ pbind_ (p "headers") (v "tpinfoCxxHeaders" `app` v "param" )
                , pbind_ (pApp (name "f") [p "x"])
                    (v "renderCMacro" `app` (con "Include" `app` v "x"))
                ]
                (v "concatMap" `app` v "f" `app` v "headers")
            namespaceStr =
              letE
                [ pbind_ (p "nss") (v "tpinfoCxxNamespaces" `app` v "param" )
                , pbind_ (pApp (name "f") [p "x"])
                    (v "renderCStmt" `app` (con "UsingNamespace" `app` v "x"))
                ]
                (v "concatMap" `app` v "f" `app` v "nss")


        retstmt = v "pure"
                  `app` list [ v "mkInstance"
                               `app` list []
                               `app` foldl1
                                       (\f x -> con "AppT" `app` f `app` x)
                                       (v "con" `app` strE (typeclassNameT t) : map v tvars)
                               `app` (v "lst")
                             ]
