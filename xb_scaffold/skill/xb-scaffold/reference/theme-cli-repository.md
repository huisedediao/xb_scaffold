# XB Scaffold Theme System, Data Layer, and CLI

## Theme system

`XBScaffold(themeConfigs: [...])` builds one `XBTheme` per index:

```dart
XBThemeConfig({required Color primaryColor, required String imgPrefix});
```

Switch themes at runtime: `XBThemeVM().changeTheme(1)` (index of `themeConfigs`). Read the active theme anywhere with the global getters:

```dart
XBTheme get app;                 // full theme
XBThemeColor get colors;         // colors.primary (default #007AFF), colors.randColor
XBThemeSpace get spaces;         // gapDef 17.5, gapLess 13.5, gapLarge 35
XBThemeFontSize get fontSizes;   // s8..s40 (s31..s35, s37..s39 missing), def = 16
XBThemeFontWeight get fontWeights; // bold, semiBold(w600), medium(w500), normal, thin(w200)
XBThemeImage get images;         // images.imgPath('icon.png') -> '<imgPrefix>icon.png'
```

Image fallback: each theme's `imgPrefix` is scanned against the AssetManifest; when a non-default theme lacks an asset, it falls back to theme 0's prefix.

Pages rebuild on theme change by default (`needRebuildWhileAppThemeChanged => true`).

### Extending the theme

To **change** built-in values, subclass the corresponding class and inject it: build your own `XBTheme(images: MyImage(...))` and register with `XBThemeVM().setThemeForIndex(theme, i)`.

To **add** new tokens, use Dart extensions — this is the recommended workflow and what `xb.extension` scaffolds:

```dart
extension CustomColors on XBThemeColor {
  Color get customBlue => const Color(0xFF2196F3);
}
extension AppImages on XBThemeImage {
  String get icHome => imgPath('ic_home.png');
}
// usage: Container(color: colors.customBlue)
```

Generated extension files (`xb.extension [dir]`, default `lib/`): `app_theme_color.dart`, `app_theme_font_size.dart`, `app_theme_font_weights.dart`, `app_theme_image.dart`, `app_theme_space.dart` inside a `xb_scaffold_extension` directory. `xb.updateimg [imgDir]` (default `./assets/images`) incrementally appends `String get xxx => imgPath('relative/path');` into `app_theme_image.dart` (name-collision suffixes `_png`/`_svg`).

## Data layer (Repository / Service / DataSource)

Three abstract classes forming an ownership chain with mirrored init/dispose:

```
XBRepository            (services: List<XBService>)
  └── XBService         (dataSources: List<XBDataSource>)
        └── XBDataSource
```

- `XBRepository.init()` inits services in order; `dispose()` disposes in reverse.
- Attach to a VM: `vm.setRepo(MyRepo())` — the repo is disposed automatically with the VM. Retrieve: `vm.repo<MyRepo>()`.

```dart
class UserDataSource extends XBDataSource {
  @override
  void init() { /* open streams, caches */ }
  @override
  void dispose() { /* release */ }
}

class UserService extends XBService {
  @override
  List<XBDataSource> get dataSources => [UserDataSource()];
  Future<User> fetchUser(String id) => ...;   // business methods live on services
}

class UserRepo extends XBRepository {
  final userService = UserService();
  @override
  List<XBService> get services => [userService];
}
```

## CLI tools (`xb.*`)

One-time setup in a consuming project: `dart run xb_scaffold:xb xb.setup`
(generates `Makefile`, runs `make install-cli`, fixes PATH, then runs `xb.extension` + `xb.updateimg`; afterwards the short `xb` command is available). `xb.setup` also generates the AI self-install guide (see `xb.skill` below).

All commands also work without install via `dart run xb_scaffold:xb <command>`.

| Command | Usage | Effect |
|---|---|---|
| `xb.page <name> [dir]` | `xb.page user_detail lib/pages/` | Generates `user_detail.dart` (XBPage) + `user_detail_vm.dart` (XBPageVM), mutually imported, name → PascalCase class. |
| `xb.widget <name> [path]` | `xb.widget UserCard lib/widgets/user_card.dart` | Prints or writes an `XBWidget` + `XBVM` template. |
| `xb.extension [dir]` | `xb.extension lib/public/` | Creates theme extension starter files (see above). |
| `xb.updateimg [imgDir]` | `xb.updateimg ./assets/images` | Scans images, appends getters to `app_theme_image.dart`. |
| `xb.parsemodel <file>` | `xb.parsemodel lib/model/user_model.dart` | Prints `fromJson`/`toJson` snippets per class (uses `xbParse`/`xbParseList`, non-null fields get default values). |
| `xb.newmodel <name> [outPath] '<json>'` | `xb.newmodel user lib/model/ '{"id":"1"}'` | Generates a full model class (nullable fields, ctor, fromJson/toJson) to stdout or file. |
| `xb.skill [--out <path>] [--force]` | `xb.skill` | Generates the AI self-install guide at the project root (see below). |
| `xb.setup` | `xb.setup` | One-time CLI bootstrap (see above). |

### xb.skill — generate the AI self-install guide

```bash
xb.skill                       # -> ./xb-scaffold-ai-guide.md (project root)
xb.skill --out docs/xb.md      # custom location
xb.skill --force               # overwrite without asking
```

Generates a single self-contained guide document containing (1) instructions
for AI assistants on how to convert the knowledge into a native skill/rule of
whatever tool they run in, and (2) the full skill knowledge base split by
`<!-- section: ... -->` markers. It is tool-agnostic: ask your AI assistant to
read and execute the instructions in the generated file; it will install the
skill itself (e.g. `.qoder/skills/`, `.claude/skills/`, `.cursor/rules/`, or
its own rules mechanism).
