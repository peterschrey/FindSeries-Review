import { stopE2eStack } from './stack.mjs';

export default async function globalTeardown() {
  await stopE2eStack();
}
