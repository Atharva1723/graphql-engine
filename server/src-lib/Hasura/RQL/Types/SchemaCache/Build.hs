{-# LANGUAGE Arrows #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Types and functions used in the process of building the schema cache from metadata information
-- stored in the @hdb_catalog@ schema in Postgres.
module Hasura.RQL.Types.SchemaCache.Build
  ( MetadataDependency (..),
    recordInconsistency,
    recordInconsistencyM,
    recordInconsistenciesM,
    recordDependencies,
    recordDependenciesM,
    withRecordInconsistency,
    withRecordInconsistencyM,
    CacheRWM (..),
    BuildReason (..),
    CacheInvalidations (..),
    MetadataM (..),
    MetadataT (..),
    runMetadataT,
    buildSchemaCacheWithInvalidations,
    buildSchemaCache,
    buildSchemaCacheFor,
    throwOnInconsistencies,
    withNewInconsistentObjsCheck,
    getInconsistentQueryCollections,
  )
where

import Control.Arrow.Extended
import Control.Lens
import Control.Monad.Morph
import Control.Monad.Trans.Control (MonadBaseControl)
import Data.Aeson (Value, toJSON)
import Data.Aeson.TH
import Data.HashMap.Strict.Extended qualified as Map
import Data.HashMap.Strict.InsOrd qualified as OMap
import Data.HashMap.Strict.Multi qualified as MultiMap
import Data.List qualified as L
import Data.List.Extended qualified as L
import Data.Sequence qualified as Seq
import Data.Text.Extended
import Data.Text.NonEmpty (unNonEmptyText)
import Data.Trie qualified as Trie
import Database.PG.Query qualified as PG
import Hasura.Backends.DataConnector.Adapter.Types (DataConnectorName)
import Hasura.Backends.Postgres.Connection
import Hasura.Base.Error
import Hasura.GraphQL.Analyse
import Hasura.GraphQL.Transport.HTTP.Protocol
import Hasura.Prelude
import Hasura.RQL.Types.Allowlist (NormalizedQuery, unNormalizedQuery)
import Hasura.RQL.Types.Common
import Hasura.RQL.Types.Endpoint
import Hasura.RQL.Types.Metadata
import Hasura.RQL.Types.Metadata.Object
import Hasura.RQL.Types.QueryCollection
import Hasura.RQL.Types.SchemaCache
import Hasura.RemoteSchema.Metadata (RemoteSchemaName)
import Hasura.Server.Types
import Hasura.Session
import Hasura.Tracing (TraceT)
import Hasura.Tracing qualified as Tracing
import Language.GraphQL.Draft.Syntax qualified as G
import Network.HTTP.Client.Manager (HasHttpManagerM (..))

-- * Inconsistencies

recordInconsistency ::
  (ArrowWriter (Seq (Either InconsistentMetadata md)) arr) => ((Maybe Value, MetadataObject), Text) `arr` ()
recordInconsistency = proc ((val, mo), reason) ->
  tellA -< Seq.singleton $ Left $ InconsistentObject reason val mo

recordInconsistencyM ::
  (MonadWriter (Seq (Either InconsistentMetadata md)) m) => Maybe Value -> MetadataObject -> Text -> m ()
recordInconsistencyM val mo reason = recordInconsistenciesM' [(val, mo)] reason

recordInconsistenciesM ::
  (MonadWriter (Seq (Either InconsistentMetadata md)) m) => [MetadataObject] -> Text -> m ()
recordInconsistenciesM metadataObjects reason = recordInconsistenciesM' ((Nothing,) <$> metadataObjects) reason

recordInconsistenciesM' ::
  (MonadWriter (Seq (Either InconsistentMetadata md)) m) => [(Maybe Value, MetadataObject)] -> Text -> m ()
recordInconsistenciesM' metadataObjects reason =
  tell $ Seq.fromList $ map (Left . uncurry (InconsistentObject reason)) metadataObjects

-- * Dependencies

data MetadataDependency
  = MetadataDependency
      MetadataObject
      -- ^ for error reporting on missing dependencies
      SchemaObjId
      SchemaDependency
  deriving (Eq)

recordDependencies ::
  (ArrowWriter (Seq (Either im MetadataDependency)) arr) =>
  (MetadataObject, SchemaObjId, Seq SchemaDependency) `arr` ()
recordDependencies = proc (metadataObject, schemaObjectId, dependencies) ->
  tellA -< Right . MetadataDependency metadataObject schemaObjectId <$> dependencies

recordDependenciesM ::
  (MonadWriter (Seq (Either im MetadataDependency)) m) =>
  MetadataObject ->
  SchemaObjId ->
  Seq SchemaDependency ->
  m ()
recordDependenciesM metadataObject schemaObjectId dependencies = do
  tell $ Right . MetadataDependency metadataObject schemaObjectId <$> dependencies

-- * Helpers

-- | Monadic version of 'withRecordInconsistency'
withRecordInconsistencyM ::
  (MonadWriter (Seq (Either InconsistentMetadata md)) m) =>
  MetadataObject ->
  ExceptT QErr m a ->
  m (Maybe a)
withRecordInconsistencyM metadataObject f = do
  result <- runExceptT f
  case result of
    Left err -> do
      case qeInternal err of
        Just (ExtraExtensions exts) ->
          -- the QErr type contains an optional qeInternal :: Maybe QErrExtra field, which either stores an error coming
          -- from an action webhook (ExtraExtensions) or an internal error thrown somewhere within graphql-engine.
          --
          -- if we do have an error here, it should be an internal error and hence never be of the former case:
          recordInconsistencyM (Just (toJSON exts)) metadataObject "withRecordInconsistency: unexpected ExtraExtensions"
        Just (ExtraInternal internal) ->
          recordInconsistencyM (Just (toJSON internal)) metadataObject (qeError err)
        Just HideInconsistencies ->
          pure ()
        Nothing ->
          recordInconsistencyM Nothing metadataObject (qeError err)
      return Nothing
    Right v -> return $ Just v

-- | Record any errors resulting from a computation as inconsistencies
withRecordInconsistency ::
  (ArrowChoice arr, ArrowWriter (Seq (Either InconsistentMetadata md)) arr) =>
  ErrorA QErr arr (e, s) a ->
  arr (e, (MetadataObject, s)) (Maybe a)
withRecordInconsistency f = proc (e, (metadataObject, s)) -> do
  result <- runErrorA f -< (e, s)
  case result of
    Left err -> do
      case qeInternal err of
        Just (ExtraExtensions exts) ->
          -- the QErr type contains an optional qeInternal :: Maybe QErrExtra field, which either stores an error coming
          -- from an action webhook (ExtraExtensions) or an internal error thrown somewhere within graphql-engine.
          --
          -- if we do have an error here, it should be an internal error and hence never be of the former case:
          recordInconsistency -< ((Just (toJSON exts), metadataObject), "withRecordInconsistency: unexpected ExtraExtensions")
        Just (ExtraInternal internal) ->
          recordInconsistency -< ((Just (toJSON internal), metadataObject), qeError err)
        Just HideInconsistencies ->
          returnA -< ()
        Nothing ->
          recordInconsistency -< ((Nothing, metadataObject), qeError err)
      returnA -< Nothing
    Right v -> returnA -< Just v
{-# INLINEABLE withRecordInconsistency #-}

-- ----------------------------------------------------------------------------
-- operations for triggering a schema cache rebuild

class (CacheRM m) => CacheRWM m where
  buildSchemaCacheWithOptions ::
    BuildReason -> CacheInvalidations -> Metadata -> m ()
  setMetadataResourceVersionInSchemaCache :: MetadataResourceVersion -> m ()

data BuildReason
  = -- | The build was triggered by an update this instance made to the catalog (in the
    -- currently-active transaction), so information in Postgres that needs to be kept in sync with
    -- the catalog (i.e. table event triggers in @hdb_catalog@ schema) should be updated.
    CatalogUpdate (Maybe (HashSet SourceName))
  | -- | The build was triggered by a notification that some other currently-running Hasura instance
    -- updated the catalog. Since that instance already updated table event triggers in @hdb_catalog@,
    -- this build should be read-only.
    CatalogSync
  deriving (Eq, Show)

data CacheInvalidations = CacheInvalidations
  { -- | Force reloading of all database information, including information not technically stored in
    -- metadata (currently just enum values). Set by the @reload_metadata@ API.
    ciMetadata :: Bool,
    -- | Force refetching of the given remote schemas, even if their definition has not changed. Set
    -- by the @reload_remote_schema@ API.
    ciRemoteSchemas :: HashSet RemoteSchemaName,
    -- | Force re-establishing connections of the given data sources, even if their configuration has not changed. Set
    -- by the @pg_reload_source@ API.
    ciSources :: HashSet SourceName,
    -- | Force re-fetching of `DataConnectorInfo` from the named data connectors.
    ciDataConnectors :: HashSet DataConnectorName
  }

$(deriveJSON hasuraJSON ''CacheInvalidations)

instance Semigroup CacheInvalidations where
  CacheInvalidations a1 b1 c1 d1 <> CacheInvalidations a2 b2 c2 d2 =
    CacheInvalidations (a1 || a2) (b1 <> b2) (c1 <> c2) (d1 <> d2)

instance Monoid CacheInvalidations where
  mempty = CacheInvalidations False mempty mempty mempty

instance (CacheRWM m) => CacheRWM (ReaderT r m) where
  buildSchemaCacheWithOptions a b c = lift $ buildSchemaCacheWithOptions a b c
  setMetadataResourceVersionInSchemaCache = lift . setMetadataResourceVersionInSchemaCache

instance (CacheRWM m) => CacheRWM (StateT s m) where
  buildSchemaCacheWithOptions a b c = lift $ buildSchemaCacheWithOptions a b c
  setMetadataResourceVersionInSchemaCache = lift . setMetadataResourceVersionInSchemaCache

instance (CacheRWM m) => CacheRWM (TraceT m) where
  buildSchemaCacheWithOptions a b c = lift $ buildSchemaCacheWithOptions a b c
  setMetadataResourceVersionInSchemaCache = lift . setMetadataResourceVersionInSchemaCache

instance (CacheRWM m) => CacheRWM (PG.TxET QErr m) where
  buildSchemaCacheWithOptions a b c = lift $ buildSchemaCacheWithOptions a b c
  setMetadataResourceVersionInSchemaCache = lift . setMetadataResourceVersionInSchemaCache

newtype MetadataT m a = MetadataT {unMetadataT :: StateT Metadata m a}
  deriving
    ( Functor,
      Applicative,
      Monad,
      MonadTrans,
      MonadIO,
      MonadReader r,
      MonadError e,
      MonadTx,
      TableCoreInfoRM b,
      CacheRM,
      CacheRWM,
      MFunctor,
      Tracing.MonadTrace,
      MonadBase b,
      MonadBaseControl b
    )

instance (Monad m) => MetadataM (MetadataT m) where
  getMetadata = MetadataT get
  putMetadata = MetadataT . put

instance (HasHttpManagerM m) => HasHttpManagerM (MetadataT m) where
  askHttpManager = lift askHttpManager

instance (UserInfoM m) => UserInfoM (MetadataT m) where
  askUserInfo = lift askUserInfo

instance HasServerConfigCtx m => HasServerConfigCtx (MetadataT m) where
  askServerConfigCtx = lift askServerConfigCtx

-- | @runMetadataT@ puts a stateful metadata in scope. @MetadataDefaults@ is
-- provided so that it can be considered from the --metadataDefaults arguments.
runMetadataT :: Metadata -> MetadataDefaults -> MetadataT m a -> m (a, Metadata)
runMetadataT metadata defaults (MetadataT m) =
  runStateT m (metadata `overrideMetadataDefaults` defaults)

buildSchemaCacheWithInvalidations :: (MetadataM m, CacheRWM m) => CacheInvalidations -> MetadataModifier -> m ()
buildSchemaCacheWithInvalidations cacheInvalidations MetadataModifier {..} = do
  metadata <- getMetadata
  let modifiedMetadata = runMetadataModifier metadata
  buildSchemaCacheWithOptions (CatalogUpdate mempty) cacheInvalidations modifiedMetadata
  putMetadata modifiedMetadata

buildSchemaCache :: (MetadataM m, CacheRWM m) => MetadataModifier -> m ()
buildSchemaCache = buildSchemaCacheWithInvalidations mempty

-- | Rebuilds the schema cache after modifying metadata. If an object with the given object id became newly inconsistent,
-- raises an error about it specifically. Otherwise, raises a generic metadata inconsistency error.
buildSchemaCacheFor ::
  (QErrM m, CacheRWM m, MetadataM m) =>
  MetadataObjId ->
  MetadataModifier ->
  m ()
buildSchemaCacheFor objectId metadataModifier = do
  oldSchemaCache <- askSchemaCache
  buildSchemaCache metadataModifier
  newSchemaCache <- askSchemaCache

  let diffInconsistentObjects = Map.difference `on` (groupInconsistentMetadataById . scInconsistentObjs)
      newInconsistentObjects = newSchemaCache `diffInconsistentObjects` oldSchemaCache

  for_ (Map.lookup objectId newInconsistentObjects) $ \matchingObjects -> do
    let reasons = commaSeparated $ imReason <$> matchingObjects
    throwError (err400 InvalidConfiguration reasons) {qeInternal = Just $ ExtraInternal $ toJSON matchingObjects}

  unless (null newInconsistentObjects) $
    throwError
      (err400 Unexpected "cannot continue due to new inconsistent metadata")
        { qeInternal = Just $ ExtraInternal $ toJSON (L.nub . concatMap toList $ Map.elems newInconsistentObjects)
        }

-- | Requests the schema cache, and fails if there is any inconsistent metadata.
throwOnInconsistencies :: (QErrM m, CacheRWM m) => m ()
throwOnInconsistencies = do
  sc <- askSchemaCache
  let inconsObjs = scInconsistentObjs sc
  unless (null inconsObjs) $ do
    let err = err400 Unexpected "cannot continue due to inconsistent metadata"
    throwError err {qeInternal = Just $ ExtraInternal $ toJSON inconsObjs}

-- | Executes the given action, and if any new 'InconsistentMetadata's are added to the schema
-- cache as a result of its execution, raises an error.
withNewInconsistentObjsCheck :: (QErrM m, CacheRM m) => m a -> m a
withNewInconsistentObjsCheck action = do
  originalObjects <- scInconsistentObjs <$> askSchemaCache
  result <- action
  currentObjects <- scInconsistentObjs <$> askSchemaCache

  let diffInconsistentObjects = Map.difference `on` groupInconsistentMetadataById
      newInconsistentObjects =
        L.uniques $ concatMap toList $ Map.elems (currentObjects `diffInconsistentObjects` originalObjects)
  unless (null newInconsistentObjects) $
    throwError
      (err500 Unexpected "cannot continue due to newly found inconsistent metadata")
        { qeInternal = Just $ ExtraInternal $ toJSON newInconsistentObjects
        }

  pure result

-- | getInconsistentQueryCollections is a helper function that runs the
-- static analysis over the saved queries and reports any inconsistenties
-- with the current schema.
getInconsistentQueryCollections ::
  (MonadError QErr m) =>
  G.SchemaIntrospection ->
  QueryCollections ->
  ((CollectionName, ListedQuery) -> MetadataObject) ->
  EndpointTrie GQLQueryWithText ->
  [NormalizedQuery] ->
  m [InconsistentMetadata]
getInconsistentQueryCollections rs qcs lqToMetadataObj restEndpoints allowLst = do
  inconsistentMetaObjs <- lefts <$> traverse (validateQuery rs (lqToMetadataObj) formatError) lqLst
  pure $ map (\(o, t) -> InconsistentObject t Nothing o) inconsistentMetaObjs
  where
    zipLQwithDef :: (CollectionName, CreateCollection) -> [((CollectionName, ListedQuery), [G.ExecutableDefinition G.Name])]
    zipLQwithDef (cName, cc) = map (\lq -> ((cName, lq), (G.getExecutableDefinitions . unGQLQuery . getGQLQuery . _lqQuery $ lq))) lqs
      where
        lqs = _cdQueries . _ccDefinition $ cc

    inAllowList :: [NormalizedQuery] -> (ListedQuery) -> Bool
    inAllowList nqList (ListedQuery {..}) = any (\nq -> unNormalizedQuery nq == (unGQLQuery . getGQLQuery) _lqQuery) nqList

    inRESTEndpoints :: EndpointTrie GQLQueryWithText -> (ListedQuery) -> [Text]
    inRESTEndpoints edTrie lq = map fst $ filter (queryIsFaulty) allQueries
      where
        methodMaps = Trie.elems edTrie
        endpoints = concatMap snd $ concatMap (MultiMap.toList) methodMaps
        allQueries :: [(Text, GQLQueryWithText)]
        allQueries = map (\d -> (unNonEmptyText . unEndpointName . _ceName $ d, _edQuery . _ceDefinition $ d)) endpoints

        queryIsFaulty :: (Text, GQLQueryWithText) -> Bool
        queryIsFaulty (_, gqlQ) = (_lqQuery lq) == gqlQ

    lqLst = concatMap zipLQwithDef (OMap.toList qcs)

    formatError :: (CollectionName, ListedQuery) -> [Text] -> Text
    formatError (cName, lq) allErrs = msgInit <> lToTxt allErrs <> faultyEndpoints <> isInAllowList
      where
        msgInit = "In query collection \"" <> toTxt cName <> "\" the query \"" <> (toTxt . _lqName) lq <> "\" is invalid with the following error(s): "
        lToTxt = dquoteList . reverse
        faultyEndpoints = case inRESTEndpoints restEndpoints lq of
          [] -> ""
          ePoints -> ". This query is being used in the following REST endpoint(s): " <> lToTxt ePoints

        isInAllowList = if inAllowList allowLst lq then ". This query is in allowlist." else ""

validateQuery ::
  (MonadError QErr m) =>
  G.SchemaIntrospection ->
  (a -> MetadataObject) ->
  (a -> [Text] -> Text) ->
  (a, [G.ExecutableDefinition G.Name]) ->
  m (Either (MetadataObject, Text) ())
validateQuery rSchema getMetaObj formatError (eMeta, eDefs) = do
  -- create the gql request object
  let gqlRequest = GQLReq Nothing (GQLExecDoc eDefs) Nothing

  -- @getSingleOperation@ will do the fragment inlining
  singleOperation <- getSingleOperation gqlRequest

  -- perform the validation
  pure $ case diagnoseGraphQLQuery rSchema singleOperation of
    Nothing -> Right ()
    Just errors -> Left (getMetaObj eMeta, formatError eMeta errors)
