export type AsrBackend = "MlxQwen3" | "WhisperCpp" | "DashScope" | "OpenAiWhisper";

export interface AsrProfile {
  id: string;
  name: string;
  backend: AsrBackend;
  apiKey: string;
  apiBase: string;
  modelName: string;
  whisperCppPath: string;
  whisperModelPath: string;
  installHint: string;
}
