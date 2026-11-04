// Reads and changes the statusLine setting in a Claude Code settings.json for run.sh, with the JSON
// parser macOS always has (JavaScript for Automation), keeping every other setting as it is:
//
//   osascript -l JavaScript settings.js command FILE          -> the current statusLine command, or nothing
//   osascript -l JavaScript settings.js get FILE              -> the statusLine value as JSON ("null" if unset)
//   osascript -l JavaScript settings.js set FILE COMMANDFILE [COPYFILE]
//                                       -> statusLine.command = COMMANDFILE's text; COPYFILE gets the new
//                                          text first, so it exists whenever FILE has changed
//   osascript -l JavaScript settings.js restore FILE OLDFILE  -> statusLine = OLDFILE's JSON (null removes it)
ObjC.import('Foundation');

function readText(path) {
  const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  return (text && !text.isNil()) ? ObjC.unwrap(text) : null;
}

function writeText(path, text) {
  if (!$(text).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)) {
    throw new Error('Could not write ' + path);
  }
}

// Only a missing file counts as no settings: one that can't be read (permissions, not UTF-8) stops
// here, so a switch can't replace it with a file that holds nothing but statusLine.
function load(path) {
  const text = readText(path);
  if (text !== null) return JSON.parse(text);
  if ($.NSFileManager.defaultManager.fileExistsAtPath(path)) throw new Error('Could not read ' + path);
  return {};
}

function save(path, settings) {
  writeText(path, JSON.stringify(settings, null, 2) + '\n');
}

function run(argv) {
  const mode = argv[0];
  const path = argv[1];
  const settings = load(path);
  const current = settings.statusLine;
  if (mode === 'command') {
    return (current && typeof current === 'object' && typeof current.command === 'string') ? current.command : '';
  }
  if (mode === 'get') {
    return JSON.stringify(current === undefined ? null : current);
  }
  if (mode === 'set') {
    const command = readText(argv[2]);
    if (command === null || command.length === 0) throw new Error('No command in ' + argv[2]);
    const kept = (current && typeof current === 'object') ? current : {};
    settings.statusLine = Object.assign({}, kept, { type: 'command', command: command });
    const text = JSON.stringify(settings, null, 2) + '\n';
    if (argv[3]) writeText(argv[3], text);
    writeText(path, text);
    return 'ok';
  }
  if (mode === 'restore') {
    const old = JSON.parse(readText(argv[2]));
    if (old === null) {
      delete settings.statusLine;
    } else {
      settings.statusLine = old;
    }
    save(path, settings);
    return 'ok';
  }
  throw new Error('Unknown mode ' + mode);
}
