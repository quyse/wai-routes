{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances #-}
{-# LANGUAGE TemplateHaskell, QuasiQuotes #-}
{- |
Module      :  Network.Wai.Middleware.Routes.Routes
Copyright   :  (c) Anupam Jain 2011
License     :  GNU GPL Version 3 (see the file LICENSE)

Maintainer  :  ajnsit@gmail.com
Stability   :  experimental
Portability :  non-portable (uses ghc extensions)

This package provides typesafe URLs for Wai applications.
-}
module Network.Wai.Middleware.Routes.Routes
    ( -- * Quasi Quoters
      parseRoutes            -- | Parse Routes declared inline
    , parseRoutesFile        -- | Parse routes declared in a file
    , parseRoutesNoCheck     -- | Parse routes declared inline, without checking for overlaps
    , parseRoutesFileNoCheck -- | Parse routes declared in a file, without checking for overlaps

    -- * Template Haskell methods
    , mkRoute

    -- * Dispatch
    , routeDispatch

    -- * URL rendering
    , showRoute

    -- * Application Handlers
    , Handler

    -- * Generated Datatypes
    , Routable(..)
    , RenderRoute(..)        -- | A `RenderRoute` instance for your site datatype is automatically generated by `mkRoute`

    )
    where

-- Wai
import Network.Wai (Middleware, Application, pathInfo, requestMethod)
import Network.HTTP.Types (StdMethod(GET), parseMethod)

-- Yesod Routes
import Yesod.Routes.Class (Route, RenderRoute(..))
import Yesod.Routes.Parse (parseRoutes, parseRoutesNoCheck, parseRoutesFile, parseRoutesFileNoCheck, parseType)
import Yesod.Routes.TH (mkRenderRouteInstance, mkDispatchClause, ResourceTree(..))

-- Text
import qualified Data.Text as T
import Data.Text (Text)

-- TH
import Language.Haskell.TH.Syntax

-- | Generates all the things needed for efficient routing,
-- including your application's `Route` datatype, and a `RenderRoute` instance
mkRoute :: String -> [ResourceTree String] -> Q [Dec]
mkRoute typName routes = do
  let typ = parseType typName
  inst <- mkRenderRouteInstance typ $ map (fmap parseType) routes
  disp <- mkDispatchClause [|runHandler|] [|dispatcher|] [|id|] routes
  return $ InstanceD []
          (ConT ''Routable `AppT` typ)
          [FunD (mkName "dispatcher") [disp]]
        : inst

-- | A `Handler` generates an `Application` from the master datatype
type Handler master = master -> Application

-- PRIVATE
runHandler
  :: Handler master
  -> master
  -> master
  -> Maybe (Route master)
  -> (Route master -> Route master)
  -> Handler master
runHandler h _ _ _ _ = h

-- | A `Routable` instance can be used in dispatching.
--   An appropriate instance for your site datatype is
--   automatically generated by `mkRoute`
class Routable master where
  dispatcher
    :: master
    -> master
    -> (Route master -> Route master)
    -> Handler master -- 404 page
    -> (Route master -> Handler master) -- 405 page
    -> Text -- method
    -> [Text]
    -> Handler master

-- | Generates the application middleware from a `Routable` master datatype
routeDispatch :: Routable master => master -> Middleware
routeDispatch master def req = app master req
  where
    app = dispatcher master master id def404 def405 (T.pack $ show $ method req) (pathInfo req)
    def404 = const def
    def405 = const $ const def -- TODO: This should ideally NOT pass on handling to the next resource
    method req' = case parseMethod $ requestMethod req' of
      Right m -> m
      Left  _ -> GET

-- | Renders a `Route` as Text
showRoute :: RenderRoute master => Route master -> Text
-- TODO: Verify that intercalate "/" is sufficient and correct for all cases
-- HACK: We add a '/' to the front of the URL (by adding an empty piece at
-- the front of the url [Text]) to make everything relative to the root.
-- This ensures that the links always work.
showRoute = T.intercalate (T.pack "/") . (T.pack "" :) . fst . renderRoute
