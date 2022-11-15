-- | This module provides operations to load and modify metadata
-- relating to GraphQL Data Connectors.
module Hasura.RQL.DDL.DataConnector
  ( -- * DC Add Agent
    DCAddAgent (..),
    runAddDataConnectorAgent,

    -- * DC Delete Agent
    DCDeleteAgent (..),
    runDeleteDataConnectorAgent,
  )
where

--------------------------------------------------------------------------------

import Data.Aeson (FromJSON, ToJSON, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.HashMap.Strict.InsOrd qualified as InsOrdHashMap
import Data.Text.Extended (ToTxt (..))
import Hasura.Backends.DataConnector.Adapter.Types qualified as DC.Types
import Hasura.Base.Error qualified as Error
import Hasura.EncJSON (EncJSON)
import Hasura.Prelude
import Hasura.RQL.DDL.SourceKinds
import Hasura.RQL.Types.Common qualified as Common
import Hasura.RQL.Types.Metadata qualified as Metadata
import Hasura.RQL.Types.SchemaCache.Build qualified as SC.Build
import Hasura.SQL.Backend qualified as Backend
import Hasura.SQL.BackendMap qualified as BackendMap
import Servant.Client qualified as Servant

--------------------------------------------------------------------------------

data DCAddAgent = DCAddAgent
  { _gdcaName :: DC.Types.DataConnectorName,
    _gdcaUrl :: Servant.BaseUrl
  }

instance FromJSON DCAddAgent where
  parseJSON = Aeson.withObject "DCAddAgent" \o -> do
    _gdcaName <- o .: "name"
    mUri <- o .: "url"
    case mUri of
      Just _gdcaUrl -> pure DCAddAgent {..}
      Nothing -> fail "Failed to parse Agent URL"

instance ToJSON DCAddAgent where
  toJSON DCAddAgent {..} = Aeson.object ["name" .= _gdcaName, "url" .= show _gdcaUrl]

-- | Insert a new Data Connector Agent into Metadata.
runAddDataConnectorAgent ::
  ( Metadata.MetadataM m,
    SC.Build.CacheRWM m,
    MonadError Error.QErr m
  ) =>
  DCAddAgent ->
  m EncJSON
runAddDataConnectorAgent DCAddAgent {..} = do
  let agent = DC.Types.DataConnectorOptions _gdcaUrl
  sourceKinds <- (:) "postgres" . fmap _skiSourceKind <$> fetchSourceKinds

  if toTxt _gdcaName `elem` sourceKinds
    then Error.throw400 Error.AlreadyExists $ "SourceKind '" <> toTxt _gdcaName <> "' already exists."
    else do
      let modifier =
            Metadata.MetadataModifier $
              Metadata.metaBackendConfigs %~ BackendMap.modify @'Backend.DataConnector \oldMap ->
                Metadata.BackendConfigWrapper $ InsOrdHashMap.insert _gdcaName agent (coerce oldMap)

      SC.Build.withNewInconsistentObjsCheck $ SC.Build.buildSchemaCache modifier

      pure Common.successMsg

--------------------------------------------------------------------------------

newtype DCDeleteAgent = DCDeleteAgent {_dcdaName :: DC.Types.DataConnectorName}

instance FromJSON DCDeleteAgent where
  parseJSON = Aeson.withObject "DCDeleteAgent" \o -> do
    _dcdaName <- o .: "name"
    pure $ DCDeleteAgent {..}

instance ToJSON DCDeleteAgent where
  toJSON DCDeleteAgent {..} = Aeson.object ["name" .= _dcdaName]

-- | Delete a Data Connector Agent from the Metadata.
runDeleteDataConnectorAgent ::
  ( SC.Build.CacheRWM m,
    Metadata.MetadataM m,
    MonadError Error.QErr m
  ) =>
  DCDeleteAgent ->
  m EncJSON
runDeleteDataConnectorAgent DCDeleteAgent {..} = do
  oldMetadata <- Metadata.getMetadata

  let kindExists = do
        agentMap <- BackendMap.lookup @'Backend.DataConnector $ Metadata._metaBackendConfigs oldMetadata
        InsOrdHashMap.lookup _dcdaName $ Metadata.unBackendConfigWrapper agentMap
  case kindExists of
    Nothing -> Error.throw400 Error.NotFound $ "DC Agent '" <> toTxt _dcdaName <> "' not found"
    Just _ -> do
      let modifier =
            Metadata.MetadataModifier $
              Metadata.metaBackendConfigs
                %~ BackendMap.alter @'Backend.DataConnector
                  (fmap (coerce . InsOrdHashMap.delete _dcdaName . Metadata.unBackendConfigWrapper))

      SC.Build.withNewInconsistentObjsCheck $ SC.Build.buildSchemaCache modifier
      pure Common.successMsg
