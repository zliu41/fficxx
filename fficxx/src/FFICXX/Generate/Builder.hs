{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module FFICXX.Generate.Builder where

import           Control.Monad                           ( void, when )
import qualified Data.ByteString.Lazy.Char8        as L
import           Data.Char                               ( toUpper )
import           Data.Digest.Pure.MD5                    ( md5 )
import           Data.Foldable                           ( for_ )
import           Data.Monoid                             ( (<>), mempty )
import           Language.Haskell.Exts.Pretty            ( prettyPrint )
import           System.FilePath                         ( (</>), (<.>), splitExtension )
import           System.Directory                        ( copyFile
                                                         , createDirectoryIfMissing
                                                         , doesFileExist
                                                         )
import           System.IO                               ( hPutStrLn, withFile, IOMode(..) )
import           System.Process                          ( readProcess )
--
import           FFICXX.Runtime.CodeGen.Cxx              ( HeaderName(..) )
--
import           FFICXX.Generate.Code.Cabal              ( buildCabalFile
                                                         , buildJSONFile
                                                         )
import           FFICXX.Generate.Dependency              ( findModuleUnitImports
                                                         , mkHSBOOTCandidateList
                                                         , mkPackageConfig
                                                         )
import           FFICXX.Generate.Config                  ( FFICXXConfig(..)
                                                         , SimpleBuilderConfig(..)
                                                         )
import           FFICXX.Generate.ContentMaker
import           FFICXX.Generate.Type.Cabal              ( Cabal(..)
                                                         , CabalName(..)
                                                         , AddCInc(..)
                                                         , AddCSrc(..)
                                                         )
import           FFICXX.Generate.Type.Class              ( hasProxy )
import           FFICXX.Generate.Type.Module             ( ClassImportHeader(..)
                                                         , ClassModule(..)
                                                         , PackageConfig(..)
                                                         , TemplateClassModule(..)
                                                         , TopLevelImportHeader(..)
                                                         )
import           FFICXX.Generate.Util                    ( moduleDirFile )
--

macrofy :: String -> String
macrofy = map ((\x->if x=='-' then '_' else x) . toUpper)


simpleBuilder :: FFICXXConfig -> SimpleBuilderConfig -> IO ()
simpleBuilder cfg sbc = do
  putStrLn "----------------------------------------------------"
  putStrLn "-- fficxx code generation for Haskell-C++ binding --"
  putStrLn "----------------------------------------------------"
  let SimpleBuilderConfig
        topLevelMod
        mumap
        cabal
        classes
        toplevelfunctions
        templates
        extralibs
        extramods
        staticFiles
        = sbc
      pkgname = cabal_pkgname cabal
  putStrLn ("Generating " <> unCabalName pkgname)
  let workingDir = fficxxconfig_workingDir cfg
      installDir = fficxxconfig_installBaseDir cfg
      staticDir  = fficxxconfig_staticFileDir cfg

      pkgconfig@(PkgConfig mods cihs tih tcms _tcihs _ _) =
        mkPackageConfig
          (pkgname, findModuleUnitImports mumap)
          (classes, toplevelfunctions,templates,extramods)
          (cabal_additional_c_incs cabal)
          (cabal_additional_c_srcs cabal)
      hsbootlst = mkHSBOOTCandidateList mods
      cabalFileName = unCabalName pkgname <.> "cabal"
      jsonFileName = unCabalName pkgname <.> "json"
  --
  createDirectoryIfMissing True workingDir
  createDirectoryIfMissing True installDir
  createDirectoryIfMissing True (installDir </> "src")
  createDirectoryIfMissing True (installDir </> "csrc")
  --
  putStrLn "Copying static files"
  mapM_ (\x->copyFileWithMD5Check (staticDir </> x) (installDir </> x)) staticFiles
  --
  putStrLn "Generating Cabal file"
  buildCabalFile cabal topLevelMod pkgconfig extralibs (workingDir</>cabalFileName)
  --
  putStrLn "Generating JSON file"
  buildJSONFile cabal topLevelMod pkgconfig extralibs (workingDir</>jsonFileName)
  --
  putStrLn "Generating Header file"
  let
      gen :: FilePath -> String -> IO ()
      gen file str =
        let path = workingDir </> file in withFile path WriteMode (flip hPutStrLn str)


  gen (unCabalName pkgname <> "Type.h") (buildTypeDeclHeader (map cihClass cihs))
  for_ cihs $ \hdr -> gen
                        (unHdrName (cihSelfHeader hdr))
                        (buildDeclHeader (unCabalName pkgname) hdr)
  gen
    (tihHeaderFileName tih <.> "h")
    (buildTopLevelHeader (unCabalName pkgname) tih)

  putStrLn "Generating Cpp file"
  for_ cihs (\hdr -> gen (cihSelfCpp hdr) (buildDefMain hdr))
  gen (tihHeaderFileName tih <.> "cpp") (buildTopLevelCppDef tih)
  --
  putStrLn "Generating Additional Header/Source"
  for_ (cabal_additional_c_incs cabal) (\(AddCInc hdr txt) -> gen hdr txt)
  for_ (cabal_additional_c_srcs cabal) (\(AddCSrc hdr txt) -> gen hdr txt)
  --
  putStrLn "Generating RawType.hs"
  for_ mods $ \m -> gen
                      (cmModule m <.> "RawType" <.> "hs")
                      (prettyPrint (buildRawTypeHs m))
  --
  putStrLn "Generating FFI.hsc"
  for_ mods $ \m -> gen
                      (cmModule m <.> "FFI" <.> "hsc")
                      (prettyPrint (buildFFIHsc m))
  --
  putStrLn "Generating Interface.hs"
  for_ mods $ \m -> gen
                      (cmModule m <.> "Interface" <.> "hs")
                      (prettyPrint (buildInterfaceHs mempty m))
  --
  putStrLn "Generating Cast.hs"
  for_ mods $ \m -> gen
                      (cmModule m <.> "Cast" <.> "hs")
                      (prettyPrint (buildCastHs m))
  --
  putStrLn "Generating Implementation.hs"
  for_ mods $ \m -> gen
                      (cmModule m <.> "Implementation" <.> "hs")
                      (prettyPrint (buildImplementationHs mempty m))
 --
  putStrLn "Generating Proxy.hs"
  for_ mods $ \m ->
    when (hasProxy . cihClass . cmCIH $ m) $
      gen (cmModule m <.> "Proxy" <.> "hs") (prettyPrint (buildProxyHs m))
  --
  putStrLn "Generating Template.hs"
  for_ tcms $ \m -> gen
                      (tcmModule m <.> "Template" <.> "hs")
                      (prettyPrint (buildTemplateHs m))
  --
  putStrLn "Generating TH.hs"
  for_ tcms $ \m -> gen
                      (tcmModule m <.> "TH" <.> "hs")
                      (prettyPrint (buildTHHs m))

  --
  -- TODO: Template.hs-boot need to be generated as well
  putStrLn "Generating hs-boot file"
  for_ hsbootlst $ \m -> gen
                           (m <.> "Interface" <.> "hs-boot")
                           (prettyPrint (buildInterfaceHSBOOT m))
  --
  putStrLn "Generating Module summary file"
  for_ mods $ \m -> gen
                      (cmModule m <.> "hs")
                      (prettyPrint (buildModuleHs m))
  --
  putStrLn "Generating Top-level Module"
  gen (topLevelMod <.> "hs") (prettyPrint (buildTopLevelHs topLevelMod (mods,tcms) tih))
  --
  putStrLn "Copying generated files to target directory"
  touch (workingDir </> "LICENSE")
  copyFileWithMD5Check (workingDir </> cabalFileName)  (installDir </> cabalFileName)
  copyFileWithMD5Check (workingDir </> jsonFileName)  (installDir </> jsonFileName)
  copyFileWithMD5Check (workingDir </> "LICENSE") (installDir </> "LICENSE")

  copyCppFiles workingDir (csrcDir installDir) (unCabalName pkgname) pkgconfig
  for_ mods (copyModule workingDir (srcDir installDir))
  for_ tcms (copyTemplateModule workingDir (srcDir installDir))
  moduleFileCopy workingDir (srcDir installDir) $ topLevelMod <.> "hs"

  putStrLn "----------------------------------------------------"
  putStrLn "-- Code generation has been completed. Enjoy!     --"
  putStrLn "----------------------------------------------------"


-- | some dirty hack. later, we will do it with more proper approcah.

touch :: FilePath -> IO ()
touch fp = void (readProcess "touch" [fp] "")


copyFileWithMD5Check :: FilePath -> FilePath -> IO ()
copyFileWithMD5Check src tgt = do
  b <- doesFileExist tgt
  if b
    then do
      srcmd5 <- md5 <$> L.readFile src
      tgtmd5 <- md5 <$> L.readFile tgt
      if srcmd5 == tgtmd5 then return () else copyFile src tgt
    else copyFile src tgt


copyCppFiles :: FilePath -> FilePath -> String -> PackageConfig -> IO ()
copyCppFiles wdir ddir cprefix (PkgConfig _ cihs tih _ _tcihs acincs acsrcs) = do
  let thfile = cprefix <> "Type.h"
      tlhfile = tihHeaderFileName tih <.> "h"
      tlcppfile = tihHeaderFileName tih <.> "cpp"
  copyFileWithMD5Check (wdir </> thfile) (ddir </> thfile)
  doesFileExist (wdir </> tlhfile)
    >>= flip when (copyFileWithMD5Check (wdir </> tlhfile) (ddir </> tlhfile))
  doesFileExist (wdir </> tlcppfile)
    >>= flip when (copyFileWithMD5Check (wdir </> tlcppfile) (ddir </> tlcppfile))
  for_ cihs $ \header-> do
    let hfile = unHdrName (cihSelfHeader header)
        cppfile = cihSelfCpp header
    copyFileWithMD5Check (wdir </> hfile) (ddir </> hfile)
    copyFileWithMD5Check (wdir </> cppfile) (ddir </> cppfile)

  for_ acincs $ \(AddCInc header _) ->
    copyFileWithMD5Check (wdir </> header) (ddir </> header)

  for_ acsrcs $ \(AddCSrc csrc _) ->
    copyFileWithMD5Check (wdir </> csrc) (ddir </> csrc)


moduleFileCopy :: FilePath -> FilePath -> FilePath -> IO ()
moduleFileCopy wdir ddir fname = do
  let (fnamebody,fnameext) = splitExtension fname
      (mdir,mfile) = moduleDirFile fnamebody
      origfpath = wdir </> fname
      (mfile',_mext') = splitExtension mfile
      newfpath = ddir </> mdir </> mfile' <> fnameext
  b <- doesFileExist origfpath
  when b $ do
    createDirectoryIfMissing True (ddir </> mdir)
    copyFileWithMD5Check origfpath newfpath


copyModule :: FilePath -> FilePath -> ClassModule -> IO ()
copyModule wdir ddir m = do
  let modbase = cmModule m
  moduleFileCopy wdir ddir $ modbase <> ".hs"
  moduleFileCopy wdir ddir $ modbase <> ".RawType.hs"
  moduleFileCopy wdir ddir $ modbase <> ".FFI.hsc"
  moduleFileCopy wdir ddir $ modbase <> ".Interface.hs"
  moduleFileCopy wdir ddir $ modbase <> ".Cast.hs"
  moduleFileCopy wdir ddir $ modbase <> ".Implementation.hs"
  moduleFileCopy wdir ddir $ modbase <> ".Interface.hs-boot"
  when (hasProxy . cihClass . cmCIH $ m) $
    moduleFileCopy wdir ddir $ modbase <> ".Proxy.hs"


copyTemplateModule :: FilePath -> FilePath -> TemplateClassModule -> IO ()
copyTemplateModule wdir ddir m = do
  let modbase = tcmModule m
  moduleFileCopy wdir ddir $ modbase <> ".Template.hs"
  moduleFileCopy wdir ddir $ modbase <> ".TH.hs"
