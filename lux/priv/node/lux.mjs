/**
 * @module lux-node
 * @description Node.js integration module for the Lux framework.
 * Provides utilities for importing and managing Node.js packages
 * within the Lux Elixir runtime environment.
 *
 * @example
 * // Import a package
 * const result = await importPackage('lodash');
 * // => { success: true }
 *
 * @example
 * // Import without updating lock file
 * const result = await importPackage('lodash', { update_lock_file: false });
 * // => { success: true }
 */

import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { writeFile, readFile } from 'fs/promises';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

/**
 * Validates that a package name is a non-empty string.
 * @param {string} packageName - The package name to validate.
 * @throws {TypeError} If packageName is not a non-empty string.
 */
function validatePackageName(packageName) {
  if (typeof packageName !== 'string' || packageName.trim().length === 0) {
    throw new TypeError('Package name must be a non-empty string');
  }
}

/**
 * Reads the current package.json and package-lock.json files,
 * returning their contents for later restoration.
 * @returns {Promise<{packageJson: string, packageLock: string}>}
 */
async function readPackageFiles() {
  const packageJsonPath = join(__dirname, 'package.json');
  const packageLockPath = join(__dirname, 'package-lock.json');

  const [packageJson, packageLock] = await Promise.all([
    readFile(packageJsonPath, 'utf8'),
    readFile(packageLockPath, 'utf8').catch(() => null),
  ]);

  return { packageJson, packageLock };
}

/**
 * Restores package.json and package-lock.json to their original contents.
 * @param {string} packageJson - Original package.json content.
 * @param {string|null} packageLock - Original package-lock.json content.
 * @returns {Promise<void>}
 */
async function restorePackageFiles(packageJson, packageLock) {
  const packageJsonPath = join(__dirname, 'package.json');
  const packageLockPath = join(__dirname, 'package-lock.json');

  const writes = [writeFile(packageJsonPath, packageJson, 'utf8')];
  if (packageLock !== null) {
    writes.push(writeFile(packageLockPath, packageLock, 'utf8'));
  }
  await Promise.all(writes);
}

/**
 * Imports a Node.js package, making it available for use within Lux.
 * This function installs the package if not already installed, verifies
 * it can be imported, and optionally restores the lock file to its
 * original state.
 *
 * @param {string} packageName - The npm package name to import.
 * @param {Object} [options={}] - Import options.
 * @param {boolean} [options.update_lock_file=true] - Whether to persist
 *   changes to package-lock.json after installation.
 * @returns {Promise<{success: boolean, error?: string}>} Result object
 *   indicating success or failure with an optional error code.
 *
 * @example
 * // Basic import
 * const result = await importPackage('lodash');
 * if (result.success) {
 *   console.log('Package imported successfully');
 * }
 *
 * @example
 * // Import without modifying lock file
 * const result = await importPackage('flatten', { update_lock_file: false });
 */
export const importPackage = async (packageName, options = {}) => {
  validatePackageName(packageName);

  const { update_lock_file = true } = options;
  let savedFiles;

  try {
    savedFiles = await readPackageFiles();
  } catch (error) {
    return { success: false, error: 'ERR_READING_PACKAGE_FILES', message: error.message };
  }

  try {
    // Dynamically import nypm to check/install dependency
    const { ensureDependencyInstalled } = await import('nypm');

    await ensureDependencyInstalled(packageName, {
      cwd: __dirname,
      silent: true,
    });

    // Verify the package can actually be imported
    await import(packageName);

    return { success: true };
  } catch (error) {
    const errorCode = error.code || 'ERR_UNKNOWN';
    const errorMessage = error.message || 'Unknown error occurred';

    return {
      success: false,
      error: errorCode,
      message: errorMessage,
    };
  } finally {
    if (!update_lock_file) {
      try {
        await restorePackageFiles(savedFiles.packageJson, savedFiles.packageLock);
      } catch (restoreError) {
        // Log but don't throw - the main operation may have succeeded
        console.error('Failed to restore package files:', restoreError.message);
      }
    }
  }
};
