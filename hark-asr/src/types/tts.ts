export type TtsBackend = "Edge" | "CosyVoice";

export interface TtsVoice {
  id: string;
  name: string;
  locale: string;
  gender: string;
}

export interface TtsConfig {
  backend: TtsBackend;
  api_key: string | null;
  voice: string;
  rate: string;
}

export interface TtsBackendStatus {
  backend: string;
  installed: boolean;
  hint: string;
}

export interface SynthesizeResult {
  path: string;
  cached: boolean;
}
