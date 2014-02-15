{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}


module Hunt.GeoFrontend.Common where

import           GHC.Generics (Generic)

import           Control.Arrow (second)

import           Control.Monad (mzero)

import           Control.Lens hiding ((.=))

import           Data.Text (Text)
import qualified Data.Text as T
-- import qualified Data.Text.Lazy as TL

import qualified Data.HashMap.Lazy as HML
import qualified Data.Map          as M    (Map (), fromList)

import           Data.Aeson (FromJSON, ToJSON, Object, (.=), (.:), (.:?), (.!=))
import qualified Data.Aeson  as JSON
import qualified Data.Aeson.Types as JSON

import qualified Hunt.Server.Client as H
import qualified Hunt.Index.Schema.Normalize.Position as P

import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Control.Monad.Trans.Class (MonadTrans, lift)
import           Control.Monad.Reader (ReaderT, MonadReader, ask, runReaderT)

import qualified Hunt.Common.ApiDocument as H


data OSMType = Way | Node
    deriving (Show, Eq, Generic, Ord)

instance ToJSON OSMType where
    toJSON = JSON.genericToJSON H.lowercaseConstructorsOptions

instance FromJSON OSMType where
    parseJSON = JSON.genericParseJSON H.lowercaseConstructorsOptions

data GeoDocument = GeoDocument {
    osmId :: Integer,
    name :: Text,
    lon  :: Double,
    lat  :: Double,
    kind :: OSMType,
    tags :: [(Text, Text)]
} deriving (Eq, Ord)

geoDocToMap :: GeoDocument -> M.Map Text Text
geoDocToMap d = M.fromList $ otherTags ++ (map . second) ($ d) [("name", name), ("position", position), ("kind", fromShow . kind)]
    where
        position d' = ((fromShow $ lon d') `T.append` "-" `T.append` (fromShow $ lat d'))
        otherTags = map (uncurry (,)) $ tags d

geoDocIdToUri :: GeoDocument -> Text
geoDocIdToUri d = "osm://" `T.append` (fromShow $ osmId d) 

geoDocToHuntDoc :: GeoDocument -> H.ApiDocument
geoDocToHuntDoc d = H.ApiDocument {H.apiDocUri = geoDocIdToUri d, H.apiDocIndexMap = geoDocToMap d, H.apiDocDescrMap = geoDocToMap d}

instance FromJSON GeoDocument where
    parseJSON (JSON.Object o) = do
        u <- o .: "uri" 
        (JSON.Object descr) <- o .: "desc"
        n  <- descr .: "name"
        k  <- descr .: "kind"
        p  <- (descr .: "position") :: JSON.Parser Text
        -- TODO: use a parser. This fails on "1234-"
        let (lon', lat') = over both (read . T.unpack) $ over _2 (maybe ("0") id . T.stripPrefix "-") $ T.span (/= '-') p
        -- tags' <- JSON.parse v
        let tags' = HML.toList $ descr `HML.difference` (HML.fromList [("name", undefined), ("kind", undefined), ("position", undefined)])
        tags'' <- (mapM . traverse) JSON.parseJSON tags'
        let osmId' = read $ snd $ splitAt 6 u
        return $ GeoDocument (osmId') n lon' lat' k (tags'')
            

    parseJSON _ = mzero

fromShow :: (Show a) => a -> Text 
fromShow = T.pack . show


newtype GeoServer a = GeoServer { runGeoServer :: ReaderT H.ServerAndManager IO a }
    deriving (Monad, MonadIO, MonadReader (H.ServerAndManager))

geoServer :: MonadTrans t => GeoServer a -> t GeoServer a
geoServer = lift 

runGeoReader :: GeoServer a -> H.ServerAndManager -> IO a
runGeoReader = runReaderT . runGeoServer

withServerAndManager' :: H.HolumbusConnectionT IO b -> GeoServer b
withServerAndManager' x = do
    sm <- ask
    --sm <- liftIO $ STM.readTVarIO var
    liftIO $ H.withServerAndManager x sm

autocomplete :: Text -> GeoServer (Either Text [Text])
autocomplete q = withServerAndManager' $ H.autocomplete q

query :: Text -> GeoServer (Either Text (H.LimitedResult GeoDocument))
query q = withServerAndManager' $ H.query q