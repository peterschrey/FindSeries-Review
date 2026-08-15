import { stopE2eStack } from './stack.mjs';

export default async function globalTeardown() {
  stopE2eStack();
}
