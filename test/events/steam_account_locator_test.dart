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
}
