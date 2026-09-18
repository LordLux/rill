import { get } from './tree.ts';
import { logger } from '../log.ts';

const log = logger('entities');

/**
 * A store for view-based entities.
 * 
 * YouTube is migrating from nested renderer trees to a flat entity model, where
 * UI components (like comments) only carry a reference key, and the actual data
 * ships in a separate `frameworkUpdates.entityBatchUpdate.mutations` array.
 */
export class EntityStore {
  private store = new Map<string, any>();

  constructor(root: any) {
    const mutations = get(root, 'frameworkUpdates', 'entityBatchUpdate', 'mutations');
    if (Array.isArray(mutations)) {
      for (const m of mutations) {
        if (m.payload) {
          for (const type of Object.keys(m.payload)) {
            const entity = m.payload[type];
            if (entity && typeof entity.key === 'string') {
              this.store.set(entity.key, entity);
            }
          }
        }
      }
    }
  }

  /** Gets an entity by key, returning `null` (and logging) if missing. */
  get<T>(key: string | null | undefined): T | null {
    if (!key) return null;
    const value = this.store.get(key);
    if (value === undefined) {
      log.warn(`entity missing for key ${key}`);
      return null;
    }
    return value as T;
  }
}
