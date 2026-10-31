<?php
// Sticky Notes sync: to-dos and machines are records ("item:<id>", "machine:<id>"), each stamped with the server's
// revision counter when it last changed. A device sends what changed on it and gets back everything newer than the
// revision it last saw. Deletes are kept as records too (deleted: true), so they reach the other devices.
// Reminders never come here: they're per device.
//   POST {"token", "since", "changes": [{"type", "id", "deleted"?, "data"?}]}  ->  {"rev", "changes": [records]}
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

function fail($code, $message) {
	http_response_code($code);
	echo json_encode(['error' => $message]);
	exit;
}

$config = @include __DIR__ . '/config.php';
if (!is_array($config) || empty($config['token'])) fail(500, 'config.php missing');
if ($_SERVER['REQUEST_METHOD'] !== 'POST') fail(405, 'POST only');

$request = json_decode(file_get_contents('php://input', false, null, 0, 4000000), true);
if (!is_array($request)) fail(400, 'bad request');
if (!is_string($request['token'] ?? null) || !hash_equals($config['token'], $request['token'])) fail(403, 'bad token');
$since = (int) ($request['since'] ?? 0);
$changes = $request['changes'] ?? [];
if (!is_array($changes) || count($changes) > 2000) fail(400, 'bad changes');

function text($value, $max) {
	$value = is_string($value) ? $value : '';
	return function_exists('mb_substr') ? mb_substr($value, 0, $max, 'UTF-8') : substr($value, 0, $max);
}

function number($value) {
	return is_numeric($value) ? (int) $value : null;
}

// Only the shared fields are kept, whatever a client sends
function clean($type, $data) {
	if (!is_array($data)) $data = [];
	if ($type === 'item') {
		return ['text' => text($data['text'] ?? '', 5000), 'created' => number($data['created'] ?? null) ?? 0];
	}
	return [
		'name' => text($data['name'] ?? '', 200),
		'ip' => text($data['ip'] ?? '', 100),
		'locked' => !empty($data['locked']),
		'draftAppliedAt' => number($data['draftAppliedAt'] ?? null),
		'created' => number($data['created'] ?? null) ?? 0,
	];
}

// The store is a PHP file that exits before its JSON, so it can't be downloaded even where .htaccess is ignored
const GUARD = "<?php http_response_code(404); exit; ?>\n";
$file = __DIR__ . '/data/store.php';
if (!is_dir(dirname($file))) mkdir(dirname($file), 0700, true);
$handle = fopen($file, 'c+');
if (!$handle) fail(500, 'cannot open the store');
flock($handle, LOCK_EX);
$store = json_decode(substr(stream_get_contents($handle), strlen(GUARD)), true);
if (!is_array($store)) $store = ['rev' => 0, 'records' => []];

foreach ($changes as $change) {
	$type = $change['type'] ?? '';
	$id = $change['id'] ?? '';
	if (!in_array($type, ['item', 'machine'], true) || !is_string($id) || !preg_match('/^[A-Za-z0-9_-]{1,64}$/', $id)) continue;
	$deleted = !empty($change['deleted']);
	$store['rev']++;
	$store['records']["$type:$id"] = [
		'type' => $type,
		'id' => $id,
		'rev' => $store['rev'],
		'deleted' => $deleted,
		'data' => $deleted ? null : clean($type, $change['data'] ?? null),
	];
}

if ($changes) {
	ftruncate($handle, 0);
	rewind($handle);
	fwrite($handle, GUARD . json_encode($store, JSON_UNESCAPED_UNICODE));
	fflush($handle);
}
flock($handle, LOCK_UN);
fclose($handle);

// A device ahead of the server (the store was reset) gets everything
if ($since > $store['rev']) $since = 0;
$newer = array_values(array_filter($store['records'], fn($record) => $record['rev'] > $since));
echo json_encode(['rev' => $store['rev'], 'changes' => $newer], JSON_UNESCAPED_UNICODE);
