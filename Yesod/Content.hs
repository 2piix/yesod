{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE CPP #-}

module Yesod.Content
    ( -- * Content
      Content (..)
    , toContent
      -- * Mime types
      -- ** Data type
    , ContentType
    , typeHtml
    , typePlain
    , typeJson
    , typeXml
    , typeAtom
    , typeJpeg
    , typePng
    , typeGif
    , typeJavascript
    , typeCss
    , typeFlv
    , typeOgv
    , typeOctet
      -- ** File extensions
    , typeByExt
    , ext
      -- * Utilities
    , simpleContentType
      -- * Representations
    , ChooseRep
    , HasReps (..)
    , defChooseRep
      -- ** Specific content types
    , RepHtml (..)
    , RepJson (..)
    , RepHtmlJson (..)
    , RepPlain (..)
    , RepXml (..)
      -- * Utilities
    , formatW3
#if TEST
    , testSuite
#endif
    ) where

import Data.Maybe (mapMaybe)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.Text.Lazy (Text)
import qualified Data.Text as T
import Data.Convertible.Text

import qualified Network.Wai as W
import qualified Network.Wai.Enumerator as WE

import Data.Function (on)
import Data.Time
import System.Locale

#if TEST
import Test.Framework (testGroup, Test)
import Test.Framework.Providers.HUnit
import Test.Framework.Providers.QuickCheck2 (testProperty)
import Test.HUnit hiding (Test)
#endif

-- | There are two different methods available for providing content in the
-- response: via files and enumerators. The former allows server to use
-- optimizations (usually the sendfile system call) for serving static files.
-- The latter is a space-efficient approach to content.
--
-- It can be tedious to write enumerators; often times, you will be well served
-- to use 'toContent'.
data Content = ContentFile FilePath
             | ContentEnum (forall a.
                             (a -> B.ByteString -> IO (Either a a))
                          -> a
                          -> IO (Either a a))

instance ConvertSuccess B.ByteString Content where
    convertSuccess bs = ContentEnum $ \f a -> f a bs
instance ConvertSuccess L.ByteString Content where
    convertSuccess = swapEnum . WE.fromLBS
instance ConvertSuccess T.Text Content where
    convertSuccess t = cs (cs t :: B.ByteString)
instance ConvertSuccess Text Content where
    convertSuccess lt = cs (cs lt :: L.ByteString)
instance ConvertSuccess String Content where
    convertSuccess s = cs (cs s :: Text)
instance ConvertSuccess (IO Text) Content where
    convertSuccess = swapEnum . WE.fromLBS' . fmap cs

-- | A synonym for 'convertSuccess' to make the desired output type explicit.
toContent :: ConvertSuccess x Content => x -> Content
toContent = cs

-- | A function which gives targetted representations of content based on the
-- content-types the user accepts.
type ChooseRep =
    [ContentType] -- ^ list of content-types user accepts, ordered by preference
 -> IO (ContentType, Content)

swapEnum :: W.Enumerator -> Content
swapEnum (W.Enumerator e) = ContentEnum e

-- | Any type which can be converted to representations.
class HasReps a where
    chooseRep :: a -> ChooseRep

-- | A helper method for generating 'HasReps' instances.
--
-- This function should be given a list of pairs of content type and conversion
-- functions. If none of the content types match, the first pair is used.
defChooseRep :: [(ContentType, a -> IO Content)] -> a -> ChooseRep
defChooseRep reps a ts = do
  let (ct, c) =
        case mapMaybe helper ts of
            (x:_) -> x
            [] -> case reps of
                    [] -> error "Empty reps to defChooseRep"
                    (x:_) -> x
  c' <- c a
  return (ct, c')
        where
            helper ct = do
                c <- lookup ct reps
                return (ct, c)

instance HasReps ChooseRep where
    chooseRep = id

instance HasReps () where
    chooseRep = defChooseRep [(typePlain, const $ return $ cs "")]

instance HasReps [(ContentType, Content)] where
    chooseRep a cts = return $
        case filter (\(ct, _) -> go ct `elem` map go cts) a of
            ((ct, c):_) -> (ct, c)
            _ -> case a of
                    (x:_) -> x
                    _ -> error "chooseRep [(ContentType, Content)] of empty"
      where
        go = simpleContentType

newtype RepHtml = RepHtml Content
instance HasReps RepHtml where
    chooseRep (RepHtml c) _ = return (typeHtml, c)
newtype RepJson = RepJson Content
instance HasReps RepJson where
    chooseRep (RepJson c) _ = return (typeJson, c)
data RepHtmlJson = RepHtmlJson Content Content
instance HasReps RepHtmlJson where
    chooseRep (RepHtmlJson html json) = chooseRep
        [ (typeHtml, html)
        , (typeJson, json)
        ]
newtype RepPlain = RepPlain Content
instance HasReps RepPlain where
    chooseRep (RepPlain c) _ = return (typePlain, c)
newtype RepXml = RepXml Content
instance HasReps RepXml where
    chooseRep (RepXml c) _ = return (typeXml, c)

type ContentType = String

typeHtml :: ContentType
typeHtml = "text/html; charset=utf-8"

typePlain :: ContentType
typePlain = "text/plain; charset=utf-8"

typeJson :: ContentType
typeJson = "application/json; charset=utf-8"

typeXml :: ContentType
typeXml = "text/xml"

typeAtom :: ContentType
typeAtom = "application/atom+xml"

typeJpeg :: ContentType
typeJpeg = "image/jpeg"

typePng :: ContentType
typePng = "image/png"

typeGif :: ContentType
typeGif = "image/gif"

typeJavascript :: ContentType
typeJavascript = "text/javascript; charset=utf-8"

typeCss :: ContentType
typeCss = "text/css; charset=utf-8"

typeFlv :: ContentType
typeFlv = "video/x-flv"

typeOgv :: ContentType
typeOgv = "video/ogg"

typeOctet :: ContentType
typeOctet = "application/octet-stream"

-- | Removes \"extra\" information at the end of a content type string. In
-- particular, removes everything after the semicolon, if present.
--
-- For example, \"text/html; charset=utf-8\" is commonly used to specify the
-- character encoding for HTML data. This function would return \"text/html\".
simpleContentType :: String -> String
simpleContentType = fst . span (/= ';')

-- | Determine a mime-type based on the file extension.
typeByExt :: String -> ContentType
typeByExt "jpg" = typeJpeg
typeByExt "jpeg" = typeJpeg
typeByExt "js" = typeJavascript
typeByExt "css" = typeCss
typeByExt "html" = typeHtml
typeByExt "png" = typePng
typeByExt "gif" = typeGif
typeByExt "txt" = typePlain
typeByExt "flv" = typeFlv
typeByExt "ogv" = typeOgv
typeByExt _ = typeOctet

-- | Get a file extension (everything after last period).
ext :: String -> String
ext = reverse . fst . break (== '.') . reverse

#if TEST
---- Testing
testSuite :: Test
testSuite = testGroup "Yesod.Resource"
    [ testProperty "ext" propExt
    , testCase "typeByExt" caseTypeByExt
    ]

propExt :: String -> Bool
propExt s =
    let s' = filter (/= '.') s
     in s' == ext ("foobarbaz." ++ s')

caseTypeByExt :: Assertion
caseTypeByExt = do
    TypeJavascript @=? typeByExt (ext "foo.js")
    typeHtml @=? typeByExt (ext "foo.html")
#endif

-- | Format a 'UTCTime' in W3 format; useful for setting cookies.
formatW3 :: UTCTime -> String
formatW3 = formatTime defaultTimeLocale "%FT%X-00:00"