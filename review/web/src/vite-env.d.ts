/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_REVIEW_PROJECT_ID?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
