import { FeatureFlagDefinition } from './types';
import { isProConsole } from '../../utils/proConsole';
import globals from '../../Globals';

const relationshipTabTablesId = 'f6c57c31-abd3-46d9-aae9-b97435793273';
const importActionFromOpenApiId = '12e5aaf4-c794-4b8f-b762-5fda0bff946a';
const permissionsNewUI = '5f7b1673-b2ef-4c98-89f7-f30cb64f0136';

const importActionFromOpenApi: FeatureFlagDefinition = {
  id: importActionFromOpenApiId,
  title: 'Import Action from OpenAPI',
  description:
    'Try out the very experimental feature to generate one action from an OpenAPI endpoint',
  section: 'data',
  status: 'experimental',
  defaultValue: false,
  discussionUrl: '',
};

export const availableFeatureFlagIds = {
  relationshipTabTablesId,
  importActionFromOpenApiId,
  permissionsNewUI,
};

export const availableFeatureFlags: FeatureFlagDefinition[] = [
  {
    id: relationshipTabTablesId,
    title: 'New Relationship tab UI for tables/views',
    description:
      'Use the new UI for the Relationship tab of Tables/Views in Data section.',
    section: 'data',
    status: 'release candidate',
    defaultValue: true,
    discussionUrl: '',
  },
  {
    id: permissionsNewUI,
    title: 'Enable the revamped UI for Permissions',
    description: 'Try out the new UI experience for setting table permissions.',
    section: 'data',
    status: 'experimental',
    defaultValue: false,
    discussionUrl: '',
  },
  // eslint-disable-next-line no-underscore-dangle
  ...(isProConsole(globals) ? [importActionFromOpenApi] : []),
];
