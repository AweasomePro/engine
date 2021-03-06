// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io' as io;
import 'package:path/path.dart' as pathlib;
import 'package:web_driver_installer/chrome_driver_installer.dart';

import 'common.dart';
import 'environment.dart';
import 'utils.dart';

class IntegrationTestsManager {
  final String _browser;

  /// Installation directory for browser's driver.
  ///
  /// Always re-install since driver can change frequently.
  /// It usually changes with each the browser version changes.
  /// A better solution would be installing the browser and the driver at the
  /// same time.
  // TODO(nurhan): change the web installers to install driver and the browser
  // at the same time.
  final io.Directory _browserDriverDir;

  /// This is the parent directory for all drivers.
  ///
  /// This directory is saved to [temporaryDirectories] and deleted before
  /// tests shutdown.
  final io.Directory _drivers;

  IntegrationTestsManager(this._browser)
      : this._browserDriverDir = io.Directory(
            pathlib.join(environment.webUiRootDir.path, 'drivers', _browser)),
        this._drivers = io.Directory(
            pathlib.join(environment.webUiRootDir.path, 'drivers'));

  Future<bool> runTests() async {
    if (_browser != 'chrome') {
      print('WARNING: integration tests are only supported on chrome for now');
      return false;
    } else {
      await prepareDriver();
      // TODO(nurhan): https://github.com/flutter/flutter/issues/52987
      return await _runTests();
    }
  }

  void _cloneWebInstallers() async {
    final int exitCode = await runProcess(
      'git',
      <String>[
        'clone',
        'https://github.com/flutter/web_installers.git',
      ],
      workingDirectory: _browserDriverDir.path,
    );

    if (exitCode != 0) {
      io.stderr.writeln('ERROR: '
          'Failed to clone web installers. Exited with exit code $exitCode');
      throw DriverException('ERROR: '
          'Failed to clone web installers. Exited with exit code $exitCode');
    }
  }

  Future<bool> _runPubGet(String workingDirectory) async {
    final String executable = isCirrus ? environment.pubExecutable : 'flutter';
    final List<String> arguments = isCirrus
        ? <String>[
            'get',
          ]
        : <String>[
            'pub',
            'get',
          ];
    final int exitCode = await runProcess(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );

    if (exitCode != 0) {
      io.stderr.writeln(
          'ERROR: Failed to run pub get. Exited with exit code $exitCode');
      return false;
    } else {
      return true;
    }
  }

  void _runDriver() async {
    final int exitCode = await runProcess(
      environment.dartExecutable,
      <String>[
        'lib/web_driver_installer.dart',
        '${_browser}driver',
        '--install-only',
      ],
      workingDirectory: pathlib.join(
          _browserDriverDir.path, 'web_installers', 'packages', 'web_drivers'),
    );

    if (exitCode != 0) {
      io.stderr.writeln(
          'ERROR: Failed to run driver. Exited with exit code $exitCode');
      throw DriverException(
          'ERROR: Failed to run driver. Exited with exit code $exitCode');
    }
    startProcess(
      './chromedriver/chromedriver',
      ['--port=4444'],
      workingDirectory: pathlib.join(
          _browserDriverDir.path, 'web_installers', 'packages', 'web_drivers'),
    );
    print('INFO: Driver started');
  }

  void prepareDriver() async {
    final io.Directory priorCurrentDirectory = io.Directory.current;
    if (_browserDriverDir.existsSync()) {
      _browserDriverDir.deleteSync(recursive: true);
    }

    _browserDriverDir.createSync(recursive: true);
    temporaryDirectories.add(_drivers);

    // TODO(nurhan): We currently need git clone for getting the driver lock
    // file. Remove this after making changes in web_installers.
    await _cloneWebInstallers();
    // Change the directory to the driver_lock.yaml file's directory.
    io.Directory.current = pathlib.join(
        _browserDriverDir.path, 'web_installers', 'packages', 'web_drivers');
    // Chrome is the only browser supporting integration tests for now.
    ChromeDriverInstaller chromeDriverInstaller = ChromeDriverInstaller();
    bool installation = await chromeDriverInstaller.install();

    if (installation) {
      io.Directory.current = priorCurrentDirectory;
      await _runDriver();
    } else {
      throw DriverException('ERROR: Installing driver failed');
    }
  }

  /// Runs all the web tests under e2e_tests/web.
  Future<bool> _runTests() async {
    // Only list the files under e2e_tests/web.
    final List<io.FileSystemEntity> entities =
        environment.integrationTestsDir.listSync(followLinks: false);

    bool allTestsPassed = true;
    for (io.FileSystemEntity e in entities) {
      // The tests should be under this directories.
      if (e is io.Directory) {
        allTestsPassed = allTestsPassed && await _validateAndRunTests(e);
      }
    }
    return allTestsPassed;
  }

  /// Run tests in a single directory under: e2e_tests/web.
  ///
  /// Run `flutter pub get` as the first step.
  ///
  /// Validate the directory before running the tests. Each directory is
  /// expected to be a test project which includes a `pubspec.yaml` file
  /// and a `test_driver` directory.
  Future<bool> _validateAndRunTests(io.Directory directory) async {
    _validateTestDirectory(directory);
    await _runPubGet(directory.path);
    final bool testResults = await _runTestsInDirectory(directory);
    return testResults;
  }

  Future<bool> _runTestsInDirectory(io.Directory directory) async {
    final io.Directory testDirectory =
        io.Directory(pathlib.join(directory.path, 'test_driver'));
    final List<io.FileSystemEntity> entities = testDirectory
        .listSync(followLinks: false)
        .whereType<io.File>()
        .toList();

    final List<String> e2eTestsToRun = List<String>();

    // The following loops over the contents of the directory and saves an
    // expected driver file name for each e2e test assuming any dart file
    // not ending with `_test.dart` is an e2e test.
    // Other files are not considered since developers can add files such as
    // README.
    for (io.File f in entities) {
      final String basename = pathlib.basename(f.path);
      if (!basename.contains('_test.dart') && basename.endsWith('.dart')) {
        e2eTestsToRun.add(basename);
      }
    }

    print(
        'INFO: In project ${directory} ${e2eTestsToRun.length} tests to run.');

    int numberOfPassedTests = 0;
    int numberOfFailedTests = 0;
    for (String fileName in e2eTestsToRun) {
      final bool testResults =
          await _runTestsInProfileMode(directory, fileName);
      if (testResults) {
        numberOfPassedTests++;
      } else {
        numberOfFailedTests++;
      }
    }
    final int numberOfTestsRun = numberOfPassedTests + numberOfFailedTests;

    print('INFO: ${numberOfTestsRun} tests run. ${numberOfPassedTests} passed '
        'and ${numberOfFailedTests} failed.');
    return numberOfFailedTests == 0;
  }

  Future<bool> _runTestsInProfileMode(
      io.Directory directory, String testName) async {
    final int exitCode = await runProcess(
      'flutter',
      <String>[
        'drive',
        '--target=test_driver/${testName}',
        '-d',
        'web-server',
        '--profile',
        '--browser-name=$_browser',
        '--local-engine=host_debug_unopt',
      ],
      workingDirectory: directory.path,
    );

    if (exitCode != 0) {
      final String statementToRun = 'flutter drive '
          '--target=test_driver/${testName} -d web-server --profile '
          '--browser-name=$_browser --local-engine=host_debug_unopt';
      io.stderr
          .writeln('ERROR: Failed to run test. Exited with exit code $exitCode'
              '. Statement to run $testName locally use the following '
              'command:\n\n$statementToRun');
      return false;
    } else {
      return true;
    }
  }

  /// Validate the directory has a `pubspec.yaml` file and a `test_driver`
  /// directory.
  ///
  /// Also check the validity of files under `test_driver` directory calling
  /// [_checkE2ETestsValidity] method.
  void _validateTestDirectory(io.Directory directory) {
    final List<io.FileSystemEntity> entities =
        directory.listSync(followLinks: false);

    // Whether the project has the pubspec.yaml file.
    bool pubSpecFound = false;
    // The test directory 'test_driver'.
    io.Directory testDirectory = null;

    for (io.FileSystemEntity e in entities) {
      // The tests should be under this directories.
      final String baseName = pathlib.basename(e.path);
      if (e is io.Directory && baseName == 'test_driver') {
        testDirectory = e;
      }
      if (e is io.File && baseName == 'pubspec.yaml') {
        pubSpecFound = true;
      }
    }
    if (!pubSpecFound) {
      throw StateError('ERROR: pubspec.yaml file not found in the test project '
          'in the directory ${directory.path}.');
    }
    if (testDirectory == null) {
      throw StateError(
          'ERROR: test_driver folder not found in the test project.'
          'in the directory ${directory.path}.');
    } else {
      _checkE2ETestsValidity(testDirectory);
    }
  }

  /// Checks if each e2e test file in the directory has a driver test
  /// file to run it.
  ///
  /// Prints informative message to the developer if an error has found.
  /// For each e2e test which has name {name}.dart there will be a driver
  /// file which drives it. The driver file should be named:
  /// {name}_test.dart
  void _checkE2ETestsValidity(io.Directory testDirectory) {
    final Iterable<io.Directory> directories =
        testDirectory.listSync(followLinks: false).whereType<io.Directory>();

    if (directories.length > 0) {
      throw StateError('${testDirectory.path} directory should not contain '
          'any sub-directories');
    }

    final Iterable<io.File> entities =
        testDirectory.listSync(followLinks: false).whereType<io.File>();

    final Set<String> expectedDriverFileNames = Set<String>();
    final Set<String> foundDriverFileNames = Set<String>();
    int numberOfTests = 0;

    // The following loops over the contents of the directory and saves an
    // expected driver file name for each e2e test assuming any file
    // not ending with `_test.dart` is an e2e test.
    for (io.File f in entities) {
      final String basename = pathlib.basename(f.path);
      if (basename.contains('_test.dart')) {
        // First remove this from expectedSet if not there add to the foundSet.
        if (!expectedDriverFileNames.remove(basename)) {
          foundDriverFileNames.add(basename);
        }
      } else if (basename.contains('.dart')) {
        // Only run on dart files.
        final String e2efileName = pathlib.basenameWithoutExtension(f.path);
        final String expectedDriverName = '${e2efileName}_test.dart';
        numberOfTests++;
        // First remove this from foundSet if not there add to the expectedSet.
        if (!foundDriverFileNames.remove(expectedDriverName)) {
          expectedDriverFileNames.add(expectedDriverName);
        }
      }
    }

    if (numberOfTests == 0) {
      throw StateError(
          'WARNING: No tests to run in this directory ${testDirectory.path}');
    }

    // TODO(nurhan): In order to reduce the work required from team members,
    // remove the need for driver file, by using the same template file.
    // Some driver files are missing.
    if (expectedDriverFileNames.length > 0) {
      for (String expectedDriverName in expectedDriverFileNames) {
        print('ERROR: Test driver file named has ${expectedDriverName} '
            'not found under directory ${testDirectory.path}. Stopping the '
            'integration tests. Please add ${expectedDriverName}. Check to '
            'README file on more details on how to setup integration tests.');
      }
      throw StateError('Error in test files. Check the logs for '
          'further instructions');
    }
  }
}
