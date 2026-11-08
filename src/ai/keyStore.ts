// The user's Anthropic API key and model choice, kept in the iOS keychain via
// expo-secure-store. The key never goes into db.json, logs or the bundle.

import * as SecureStore from 'expo-secure-store';
import { DEFAULT_MODEL, MODEL_OPTIONS, type ClaudeModel } from './claude';

const KEY = 'lumber.anthropicApiKey';
const MODEL = 'lumber.anthropicModel';

export async function loadApiKey(): Promise<string | null> {
  try {
    return (await SecureStore.getItemAsync(KEY)) || null;
  } catch {
    return null;
  }
}

export const saveApiKey = (key: string) => SecureStore.setItemAsync(KEY, key.trim());
export const clearApiKey = () => SecureStore.deleteItemAsync(KEY);

export async function loadModel(): Promise<ClaudeModel> {
  try {
    const m = await SecureStore.getItemAsync(MODEL);
    return MODEL_OPTIONS.some((o) => o.id === m) ? (m as ClaudeModel) : DEFAULT_MODEL;
  } catch {
    return DEFAULT_MODEL;
  }
}

export const saveModel = (m: ClaudeModel) => SecureStore.setItemAsync(MODEL, m);

/** Light sanity check before saving (Anthropic keys start with "sk-ant-"). */
export const looksLikeApiKey = (k: string) => /^sk-ant-[A-Za-z0-9_-]{20,}$/.test(k.trim());

/** "sk-ant-…abcd" for display. */
export const maskKey = (k: string) => (k.length > 12 ? `${k.slice(0, 7)}…${k.slice(-4)}` : '••••');
