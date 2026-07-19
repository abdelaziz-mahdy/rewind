import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/events/steam_account_locator.dart';

void main() {
  group('parseLoginUsersVdf', () {
    test('parses a single account', () {
      const vdf = '''
"users"
{
	"76561197960287930"
	{
		"AccountName"		"someuser"
		"PersonaName"		"Some User"
		"RememberPassword"		"1"
		"MostRecent"		"1"
		"Timestamp"		"1234567890"
	}
}
''';
      final entries = parseLoginUsersVdf(vdf);
      expect(entries, hasLength(1));
      expect(entries.single.steamId64, '76561197960287930');
      expect(entries.single.personaName, 'Some User');
      expect(entries.single.mostRecent, isTrue);
    });

    test('parses multiple accounts with one flagged MostRecent', () {
      const vdf = '''
"users"
{
	"76561197960287930"
	{
		"AccountName"		"olduser"
		"PersonaName"		"Old User"
		"MostRecent"		"0"
	}
	"76561198012345678"
	{
		"AccountName"		"newuser"
		"PersonaName"		"New User"
		"MostRecent"		"1"
	}
}
''';
      final entries = parseLoginUsersVdf(vdf);
      expect(entries, hasLength(2));
      final picked = pickMostLikelyAccount(entries);
      expect(picked, isNotNull);
      expect(picked!.steamId64, '76561198012345678');
      expect(picked.personaName, 'New User');
    });

    test('parses multiple accounts with none flagged MostRecent', () {
      const vdf = '''
"users"
{
	"76561197960287930"
	{
		"PersonaName"		"Old User"
		"MostRecent"		"0"
	}
	"76561198012345678"
	{
		"PersonaName"		"New User"
		"MostRecent"		"0"
	}
}
''';
      final entries = parseLoginUsersVdf(vdf);
      expect(entries, hasLength(2));
      expect(pickMostLikelyAccount(entries), isNull);
    });

    test('malformed content returns an empty list, never throws', () {
      expect(parseLoginUsersVdf('not a vdf file at all'), isEmpty);
      expect(parseLoginUsersVdf(''), isEmpty);
      expect(parseLoginUsersVdf('"12345"{"PersonaName""tooShortId"}'), isEmpty);
    });

    test('a missing PersonaName still yields an entry with an empty name', () {
      const vdf = '''
"users"
{
	"76561197960287930"
	{
		"MostRecent"		"1"
	}
}
''';
      final entries = parseLoginUsersVdf(vdf);
      expect(entries, hasLength(1));
      expect(entries.single.personaName, isEmpty);
      expect(entries.single.mostRecent, isTrue);
    });
  });

  group('pickMostLikelyAccount', () {
    test('null for an empty list', () {
      expect(pickMostLikelyAccount(const []), isNull);
    });

    test('the sole account when there is exactly one', () {
      const entry = SteamAccountEntry(
          steamId64: '76561197960287930',
          personaName: 'Solo',
          mostRecent: false);
      expect(pickMostLikelyAccount(const [entry]), entry);
    });
  });

  group('locateSteamAccounts', () {
    test('macOS: reads the native Steam path first', () async {
      final reads = <String>[];
      final result = await locateSteamAccounts(
        homeDir: '/Users/tester',
        isMacOS: true,
        isWindows: false,
        readFile: (path) async {
          reads.add(path);
          if (path ==
              '/Users/tester/Library/Application Support/Steam/config/'
                  'loginusers.vdf') {
            return '"76561197960287930"{"PersonaName""Native User"'
                '"MostRecent""1"}';
          }
          return null;
        },
      );
      expect(reads, [
        '/Users/tester/Library/Application Support/Steam/config/'
            'loginusers.vdf'
      ]);
      expect(result, hasLength(1));
      expect(result.single.personaName, 'Native User');
    });

    test('macOS: falls through to a CrossOver bottle when native is absent',
        () async {
      final result = await locateSteamAccounts(
        homeDir: '/Users/tester',
        isMacOS: true,
        isWindows: false,
        readFile: (path) async => path.contains('CrossOver')
            ? '"76561197960287930"{"PersonaName""Bottle User"'
                '"MostRecent""1"}'
            : null,
        listCrossOverBottleVdfPaths: () => [
          '/Users/tester/Library/Application Support/CrossOver/Bottles/'
              'Steam/drive_c/Program Files (x86)/Steam/config/'
              'loginusers.vdf',
        ],
      );
      expect(result, hasLength(1));
      expect(result.single.personaName, 'Bottle User');
    });

    test('windows: reads the fixed Program Files path', () async {
      final result = await locateSteamAccounts(
        homeDir: r'C:\Users\tester',
        isMacOS: false,
        isWindows: true,
        readFile: (path) async {
          expect(path, r'C:\Program Files (x86)\Steam\config\loginusers.vdf');
          return '"76561197960287930"{"PersonaName""Windows User"'
              '"MostRecent""1"}';
        },
      );
      expect(result, hasLength(1));
      expect(result.single.personaName, 'Windows User');
    });

    test('no candidate exists: returns empty, never throws', () async {
      final result = await locateSteamAccounts(
        homeDir: '/Users/tester',
        isMacOS: true,
        isWindows: false,
        readFile: (path) async => null,
      );
      expect(result, isEmpty);
    });

    test('an unsupported platform yields no candidates at all', () async {
      var readCalls = 0;
      final result = await locateSteamAccounts(
        homeDir: '/home/tester',
        isMacOS: false,
        isWindows: false,
        readFile: (path) async {
          readCalls++;
          return null;
        },
      );
      expect(result, isEmpty);
      expect(readCalls, 0);
    });
  });

  group('accountId3FromSteamId64', () {
    test('subtracts the fixed id64->id3 offset', () {
      expect(accountId3FromSteamId64('76561197960287930'), 22202);
    });

    test('non-numeric input returns null', () {
      expect(accountId3FromSteamId64('someVanityName'), isNull);
      expect(accountId3FromSteamId64(''), isNull);
    });

    test('an id64 below the offset (would be a negative id3) returns null', () {
      expect(accountId3FromSteamId64('1'), isNull);
    });
  });

  group('locateSteamTrees', () {
    test('macOS: finds the native tree with its account id3s', () async {
      final result = await locateSteamTrees(
        homeDir: '/Users/tester',
        isMacOS: true,
        isWindows: false,
        isLinux: false,
        readFile: (path) async {
          if (path ==
              '/Users/tester/Library/Application Support/Steam/config/'
                  'loginusers.vdf') {
            return '"76561197960287930"{"PersonaName""Native User"'
                '"MostRecent""1"}';
          }
          return null;
        },
      );
      expect(result, hasLength(1));
      expect(result.single.rootPath,
          '/Users/tester/Library/Application Support/Steam');
      expect(result.single.accountId3s, [22202]);
    });

    test(
        'macOS: native AND every CrossOver bottle are watched simultaneously '
        '-- not first-match-wins', () async {
      final result = await locateSteamTrees(
        homeDir: '/Users/tester',
        isMacOS: true,
        isWindows: false,
        isLinux: false,
        readFile: (path) async {
          if (path.contains('CrossOver')) {
            return '"76561198012345678"{"PersonaName""Bottle User"'
                '"MostRecent""1"}';
          }
          if (path ==
              '/Users/tester/Library/Application Support/Steam/config/'
                  'loginusers.vdf') {
            return '"76561197960287930"{"PersonaName""Native User"'
                '"MostRecent""1"}';
          }
          return null;
        },
        listCrossOverBottleSteamRoots: () => [
          '/Users/tester/Library/Application Support/CrossOver/Bottles/'
              'Steam/drive_c/Program Files (x86)/Steam',
        ],
      );
      expect(result, hasLength(2));
      expect(result.map((t) => t.rootPath), [
        '/Users/tester/Library/Application Support/Steam',
        '/Users/tester/Library/Application Support/CrossOver/Bottles/Steam/'
            'drive_c/Program Files (x86)/Steam',
      ]);
    });

    test('windows: reads the fixed Program Files path', () async {
      final result = await locateSteamTrees(
        homeDir: r'C:\Users\tester',
        isMacOS: false,
        isWindows: true,
        isLinux: false,
        readFile: (path) async {
          expect(path, r'C:\Program Files (x86)\Steam\config\loginusers.vdf');
          return '"76561197960287930"{"PersonaName""Windows User"'
              '"MostRecent""1"}';
        },
      );
      expect(result, hasLength(1));
      expect(result.single.rootPath, r'C:\Program Files (x86)\Steam');
    });

    test('linux: checks both ~/.steam/steam and ~/.local/share/Steam',
        () async {
      final reads = <String>[];
      final result = await locateSteamTrees(
        homeDir: '/home/tester',
        isMacOS: false,
        isWindows: false,
        isLinux: true,
        readFile: (path) async {
          reads.add(path);
          if (path ==
              '/home/tester/.local/share/Steam/config/'
                  'loginusers.vdf') {
            return '"76561197960287930"{"PersonaName""Linux User"'
                '"MostRecent""1"}';
          }
          return null;
        },
      );
      expect(reads, [
        '/home/tester/.steam/steam/config/loginusers.vdf',
        '/home/tester/.local/share/Steam/config/loginusers.vdf',
      ]);
      expect(result, hasLength(1));
      expect(result.single.rootPath, '/home/tester/.local/share/Steam');
    });

    test(
        'a tree with no loginusers.vdf (never logged in) contributes '
        'nothing -- empty/missing dirs are normal, not an error', () async {
      final result = await locateSteamTrees(
        homeDir: '/Users/tester',
        isMacOS: true,
        isWindows: false,
        isLinux: false,
        readFile: (path) async => null,
      );
      expect(result, isEmpty);
    });

    test(
        'a tree whose loginusers.vdf has no parseable 17-digit accounts '
        'contributes nothing', () async {
      final result = await locateSteamTrees(
        homeDir: '/Users/tester',
        isMacOS: true,
        isWindows: false,
        isLinux: false,
        readFile: (path) async => 'not a vdf file at all',
      );
      expect(result, isEmpty);
    });

    test('multiple accounts logged into the same tree all surface', () async {
      final result = await locateSteamTrees(
        homeDir: '/Users/tester',
        isMacOS: true,
        isWindows: false,
        isLinux: false,
        readFile: (path) async => '"76561197960287930"'
            '{"PersonaName""A""MostRecent""0"}'
            '"76561198012345678"{"PersonaName""B""MostRecent""1"}',
      );
      expect(result, hasLength(1));
      expect(result.single.accountId3s, containsAll([22202, 52079950]));
    });

    test('an unsupported platform yields no trees at all', () async {
      var readCalls = 0;
      final result = await locateSteamTrees(
        homeDir: '/home/tester',
        isMacOS: false,
        isWindows: false,
        isLinux: false,
        readFile: (path) async {
          readCalls++;
          return null;
        },
      );
      expect(result, isEmpty);
      expect(readCalls, 0);
    });
  });
}
