/**
 * Node.js unit tests for lux.mjs importPackage function.
 *
 * Run with: node --test test/node/lux.test.mjs
 *
 * These tests verify the Node.js side of the Lux integration,
 * including input validation, error handling, and package management.
 */
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

// We test the module's exported functions by importing directly
// Note: These tests require the module to be importable from this path
const luxPath = new URL('../../priv/node/lux.mjs', import.meta.url);

describe('lux.mjs', () => {
  describe('importPackage', () => {
    it('should be an async function', async () => {
      const mod = await import(luxPath);
      assert.equal(typeof mod.importPackage, 'function');
    });

    it('should reject empty package names', async () => {
      const { importPackage } = await import(luxPath);
      await assert.rejects(
        () => importPackage(''),
        { name: 'TypeError' }
      );
    });

    it('should reject whitespace-only package names', async () => {
      const { importPackage } = await import(luxPath);
      await assert.rejects(
        () => importPackage('   '),
        { name: 'TypeError' }
      );
    });

    it('should reject non-string package names', async () => {
      const { importPackage } = await import(luxPath);
      await assert.rejects(
        () => importPackage(null),
        { name: 'TypeError' }
      );
    });

    it('should return error for non-existent packages', async () => {
      const { importPackage } = await import(luxPath);
      const result = await importPackage('nonexistent-package-xyz-12345', {
        update_lock_file: false
      });
      assert.equal(result.success, false);
      assert.ok(result.error);
    });
  });
});
