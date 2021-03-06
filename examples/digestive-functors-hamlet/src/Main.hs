{-# LANGUAGE TypeFamilies, QuasiQuotes, TemplateHaskell, MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where
{-
  Example using digestive functors with hamlet templates.
  We demonstrate composing nested forms with validation,
    nested views defined in hamlet templates,
    and how to wire it together with wai-routes.
  TODO: Perhaps create a digestive-functors-wai-routes package
-}

import Wai.Routes

import Control.Applicative ((<$>), (<*>))

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Data.Maybe (isJust, maybeToList)

import Network.Wai.Handler.Warp (run)
import Network.Wai.Application.Static (staticApp, defaultFileServerSettings)

import Text.Hamlet (hamlet, HtmlUrl, Html, shamlet)
import Text.Blaze.Html5 (toHtml)
import Text.Blaze.Html.Renderer.Text (renderHtml)
import Text.Digestive.Util (readMaybe)
import Text.Digestive.Blaze.Html5 (inputSubmit, inputSelect, inputText, errorList, childErrorList)
import Text.Digestive (Form, View, getForm, postForm, FormInput(TextInput), text, check, (.:), Result(Error, Success), validate, choice, subView)

-- Our master datatype
data MyApp = MyApp

-- The 'Route' type represents the type of the typesafe Routes generated by wai-routes
-- 'Route MyApp' means the 'Route' type generated for the master datatype 'MyApp'
-- We alias it to 'MyRoute' for convenience
type MyRoute = Route MyApp

-- Generate routes
-- We handle both GET (which displays the form) and POST (to submit the form)
mkRoute "MyApp" [parseRoutes|
/ HomeR GET POST
|]

-- Handle Displaying the form
getHomeR :: Handler MyApp
getHomeR = runHandlerM $ do
  -- On a GET request, we simply run the releaseForm to get a digestive-functor view definition
  view <- getForm "release" releaseForm
  -- This is some boilerplate to convert the digestive-functor view to appropriate format
  let view' = fmap toHtml view
  -- Then we render the view definition with a hamlet template called releaseView
  html $ TL.toStrict $ renderHtml $ releaseView view' showRouteQuery

-- Handle posts made to the form
postHomeR :: Handler MyApp
postHomeR = runHandlerM $ do
  -- Run the releaseForm to get a view definition and a result
  (view, result) <- postForm "release" releaseForm fetchParam
  -- Again boilerplate to convert the digestive-functor view to appropriate format
  let view' = fmap toHtml view
  -- Then we render the view definition differently, depending on the result
  html $ TL.toStrict $ renderHtml $ case result of
    -- If the POST had incomplete data, or failed validation, then just display the original release form
    -- The releaseView has code to display any errors to the user. We could also have used a dedicated errorView
    Nothing -> releaseView view' showRouteQuery
    -- If we managed to get a complete result, then display the result using a hamlet template called releaseReceivedView
    Just release -> releaseReceivedView release view' showRouteQuery
  where
    -- This function is the link between wai-routes and digestive-functors
    -- It tells digestive-functors how to fetch form parameters in a wai-route handler monad
    fetchParam _encType = return $ \path ->
      -- digestive-functor sends us a 'path' i.e. a list of path fragments
      -- To convert a path to a parameter, we just use '.' separated text
      -- TODO: Handle files. We currently always return a TextInput
      getPostParam (T.intercalate "." path) >>= return . map TextInput . maybeToList

-- Define Application using RouteM Monad
application :: RouteM ()
application = do
  middleware logStdoutDev
  route MyApp
  catchall $ staticApp $ defaultFileServerSettings "static"

-- Run the application
main :: IO ()
main = do
  putStrLn "Starting server on port 8080"
  run 8080 (waiApp application)



-- THE ACTUAL BUSINESS LOGIC AND TEMPLATES FOLLOW

--  The User datatype
data User = User
  { userName :: Text
  , userMail :: Text
  } deriving (Show)

-- A Form to fetch a user's details
userForm :: Monad m => Form Text m User
userForm = User
  <$> "name" .: text Nothing
  -- We validate the email address
  <*> "mail" .: check "Not a valid email address" checkEmail (text Nothing)
  where
    checkEmail :: Text -> Bool
    checkEmail = isJust . T.find (== '@')

-- Hamlet template to display a User
-- Note the use of errorList to display failed validation errors for email
userView :: View Html -> Html
userView view = [shamlet|
  <label name="name"> Name:
  #{inputText "name" view}
  <br>
  #{errorList "mail" view}
  <label name="mail"> Email address:
  #{inputText "mail" view}
  <br>
|]


-- The Package data type
data Package = Package Text Version Category
    deriving (Show)

-- Package version number
type Version = [Int]

-- Package category
data Category = Web | Text | Math
    deriving (Bounded, Enum, Eq, Show)

-- A Form to fetch a package's details
packageForm :: Monad m => Form Text m Package
packageForm = Package
    <$> "name"     .: text Nothing
    -- We validate version numbers
    <*> "version"  .: validate validateVersion (text (Just "0.0.0.1"))
    <*> "category" .: choice categories Nothing
  where
    -- Category can only be selected from a prepopulated list
    -- [minBound..maxBound] is a shortcut to enumerate all the constructors of Category
    categories = [(x, T.pack (show x)) | x <- [minBound .. maxBound]]
    -- Version validator
    validateVersion = maybe (Error "Cannot parse version") Success .
        mapM (readMaybe . T.unpack) . T.split (== '.')

-- A Release is a Package's details uploaded by a User
data Release = Release User Package
    deriving (Show)

-- Form to capture a release
-- Note that this is simply composed of the user and package sub-forms
releaseForm :: Monad m => Form Text m Release
releaseForm = Release
    <$> "author"  .: userForm
    <*> "package" .: packageForm

-- Hamlet template to display a Release
-- Note that we simply use userView as a sub-view
-- We could also have made a separate packageView sub-view
-- Note the use of childErrorList to display all validation errors related to packages
releaseView :: View Html -> HtmlUrl MyRoute
releaseView view = [hamlet|
  <form action=@{HomeR} method=POST>
    <h2>Author
    #{userView $ subView "author" view}
    <h2>Package
    #{childErrorList "package" view}
    <label name="package.name"> Name:
    #{inputText "package.name" view}
    <br>
    <label name="package.version"> Version:
    #{inputText "package.version" view}
    <br>
    <label name="package.category"> Category:
    #{inputSelect "package.category" view}
    <br>
    #{inputSubmit "Submit"}
|]

-- Hamlet template to display a correctly POSTed Release
-- We simply print the contents of the release data structure in a <pre> tag
-- And then use the previously defined releaseView sub-view to show the form. Don't repeat yourself!
releaseReceivedView :: Release -> View Html -> HtmlUrl MyRoute
releaseReceivedView release view = [hamlet|
  <h1> Release received
  <pre> #{show $ release}
  ^{releaseView view}
|]
