module Bindings.Cxx.Generate.Generator.Driver where

import System.Directory 
import System.FilePath
import System.IO
import System.Process
import Text.StringTemplate
-- import Text.StringTemplate.Helpers
--
import Bindings.Cxx.Generate.Type.Class
import Bindings.Cxx.Generate.Type.Annotate
import Bindings.Cxx.Generate.Generator.ContentMaker 
import Bindings.Cxx.Generate.Util



----
---- Header and Cpp file
----

-- | 
writeTypeDeclHeaders :: STGroup String 
                     -> String  -- ^ type macro 
                     -> FilePath 
                     -> String  -- ^ cprefix 
                     -> [ClassImportHeader]
                     -> IO ()
writeTypeDeclHeaders templates typemacro wdir cprefix headers = do 
  let fn = wdir </> cprefix ++ "Type.h"
      classes = map cihClass headers
  withFile fn WriteMode $ \h -> do 
    hPutStrLn h (mkTypeDeclHeader templates typemacro classes)

-- | 
writeDeclHeaders :: STGroup String -> ClassGlobal 
                 -> FilePath -> String -> ClassImportHeader
                 -> IO () 
writeDeclHeaders templates cglobal wdir cprefix header = do 
  let fn = wdir </> cihSelfHeader header
  withFile fn WriteMode $ \h -> do 
    hPutStrLn h (mkDeclHeader templates cglobal cprefix header)

writeCppDef :: STGroup String -> FilePath -> ClassImportHeader -> IO () 
writeCppDef templates wdir header = do 
  let fn = wdir </> cihSelfCpp header
  withFile fn WriteMode $ \h -> do 
    hPutStrLn h (mkDefMain templates header)

-- | 
writeRawTypeHs :: STGroup String -> FilePath -> ClassModule -> IO ()
writeRawTypeHs templates wdir m = do
  let fn = wdir </> cmModule m <.> rawtypeHsFileName
  withFile fn WriteMode $ \h -> do 
    hPutStrLn h (mkRawTypeHs templates m) 

-- | 
writeFFIHsc :: STGroup String -> FilePath -> ClassModule -> IO ()
writeFFIHsc templates wdir m = do 
  let fn = wdir </> cmModule m <.> ffiHscFileName
  withFile fn WriteMode $ \h -> do 
    hPutStrLn h (mkFFIHsc templates m)

-- | 
writeInterfaceHs :: AnnotateMap -> STGroup String -> FilePath 
                 -> ClassModule 
                 -> IO ()
writeInterfaceHs amap templates wdir m = do 
  let fn = wdir </> cmModule m <.> interfaceHsFileName
  withFile fn WriteMode $ \h -> do 
    hPutStrLn h (mkInterfaceHs amap templates m)

-- |
writeCastHs :: STGroup String -> FilePath -> ClassModule -> IO ()
writeCastHs templates wdir m = do 
  let fn = wdir </> cmModule m <.> castHsFileName
  withFile fn WriteMode $ \h -> do 
    hPutStrLn h (mkCastHs templates m)

-- | 
writeImplementationHs :: AnnotateMap 
                      -> STGroup String 
                      -> FilePath 
                      -> ClassModule 
                      -> IO ()
writeImplementationHs amap templates wdir m = do 
  let fn = wdir </> cmModule m <.> implementationHsFileName
  withFile fn WriteMode $ \h -> do 
    hPutStrLn h (mkImplementationHs amap templates m)

-- | 
writeExistentialHs :: STGroup String 
                   -> ClassGlobal 
                   -> FilePath 
                   -> ClassModule 
                   -> IO ()
writeExistentialHs templates cglobal wdir m = do 
  let fn = wdir </> cmModule m <.> existentialHsFileName
  withFile fn WriteMode $ \h -> do 
    hPutStrLn h (mkExistentialHs templates cglobal m)

-- |
writeModuleHs :: STGroup String -> FilePath -> ClassModule -> IO () 
writeModuleHs templates wdir m = do 
  let fn = wdir </> cmModule m <.> "hs"
  withFile fn WriteMode $ \h -> do 
    hPutStrLn h (mkModuleHs templates m)

writePkgHs :: String -- ^ summary module 
           -> STGroup String 
           -> FilePath 
           -> [ClassModule] 
           -> IO () 
writePkgHs modname templates wdir mods = do 
  let fn = wdir </> modname <.> "hs"
      exportListStr = intercalateWith conncomma ((\x->" module " ++ x).cmModule) mods 
      importListStr = intercalateWith connRet ((\x->"import " ++ x).cmModule) mods
      str = renderTemplateGroup 
              templates 
              [ ("summarymod", modname)
              , ("exportList", exportListStr) 
              , ("importList", importListStr) ]
              "Pkg.hs"
  withFile fn WriteMode $ \h -> do 
    hPutStrLn h str


notExistThenCreate :: FilePath -> IO () 
notExistThenCreate dir = do 
    b <- doesDirectoryExist dir
    if b then return () else system ("mkdir -p " ++ dir) >> return ()


-- | now only create directory
copyPredefined :: FilePath -> FilePath -> String -> IO () 
copyPredefined _tdir _ddir _prefix = do 
    return () 
    -- notExistThenCreate (ddir </> prefix)
    -- copyFile (tdir </> "TypeCast.hs" ) (ddir </> prefix </> "TypeCast.hs") 


copyCppFiles :: FilePath -> FilePath -> String -> ClassImportHeader -> IO ()
copyCppFiles wdir ddir cprefix header = do 
  let thfile = cprefix ++ "Type.h"
      hfile = cihSelfHeader header
      cppfile = cihSelfCpp header
  copyFile (wdir </> thfile) (ddir </> thfile) 
  copyFile (wdir </> hfile) (ddir </> hfile) 
  copyFile (wdir </> cppfile) (ddir </> cppfile)

copyModule :: FilePath -> FilePath -> String -> ClassModule -> IO ()
copyModule wdir ddir summarymod m = do 
  let modbase = cmModule m 
  let onefilecopy fname = do 
        let (fnamebody,fnameext) = splitExtension fname
            (mdir,mfile) = moduleDirFile fnamebody
            origfpath = wdir </> fname
            (mfile',_mext') = splitExtension mfile
            newfpath = ddir </> mdir </> mfile' ++ fnameext   
        notExistThenCreate (ddir </> mdir) 
        copyFile origfpath newfpath 

  onefilecopy $ modbase ++ ".hs"
  onefilecopy $ modbase ++ ".RawType.hs"
  onefilecopy $ modbase ++ ".FFI.hsc"
  onefilecopy $ modbase ++ ".Interface.hs"
  onefilecopy $ modbase ++ ".Cast.hs"
  onefilecopy $ modbase ++ ".Implementation.hs"
  -- onefilecopy $ prefix <.> modbase ++ ".Existential.hs"
  onefilecopy $ summarymod <.> "hs"
  -- copyFile (wdir </> summarymod <.> "hs") (ddir </> summarymod <.> "hs")
  return ()
