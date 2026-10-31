// Sticky Notes: one small paper window, always on top, that keeps a to-do list.
// Data (items + window place) lives in a JSON file in the app's user data folder, written on every change.
const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");
const { app, BrowserWindow, clipboard, ipcMain, Menu, nativeImage, Notification, screen, Tray } = require("electron");

// STICKY_NOTES_DATA: another data folder (and so another instance), e.g. to try things without touching the list
if (process.env.STICKY_NOTES_DATA) {
	app.setPath("userData", process.env.STICKY_NOTES_DATA);
}

const FILE = () => path.join(app.getPath("userData"), "notes.json");

function load() {
	try {
		return JSON.parse(fs.readFileSync(FILE(), "utf8"));
	} catch {
		return { items: [], bounds: null, onTop: true };
	}
}

let state = load();
// Machines tab: people's machines (name, IP, whether I locked it). They come from the sync server when there are none here
const uid = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
if (!Array.isArray(state.machines)) {
	state.machines = [];
}
// Machines are kept in the order they were added: older ones get a "created" so every device sorts them the same
state.machines.forEach((m, i) => (m.created ||= Date.now() - (state.machines.length - i)));
state.dirty ||= {};
let saveTimer = null;

// Written shortly after the last change (typing, moving the window) and atomically (temp file + rename)
function save() {
	clearTimeout(saveTimer);
	saveTimer = setTimeout(saveNow, 250);
}

function saveNow() {
	clearTimeout(saveTimer);
	fs.mkdirSync(path.dirname(FILE()), { recursive: true });
	const tmp = `${FILE()}.tmp`;
	fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
	fs.renameSync(tmp, FILE());
}

// A saved place only if it's still on a screen (monitors change)
function initialBounds() {
	const size = { width: 340, height: 480 };
	const b = state.bounds;
	if (b && screen.getAllDisplays().some((d) => b.x >= d.bounds.x - 50 && b.y >= d.bounds.y - 50 && b.x < d.bounds.x + d.bounds.width - 50 && b.y < d.bounds.y + d.bounds.height - 50)) {
		return b;
	}
	const area = screen.getPrimaryDisplay().workArea;
	return { ...size, x: area.x + area.width - size.width - 24, y: area.y + 24 };
}

if (!app.requestSingleInstanceLock()) {
	app.quit();
}

let win;
let tray;

function showWindow() {
	if (win.isMinimized()) {
		win.restore();
	}
	win.show();
	win.focus();
	updateTray();
}

// Top bar icon (Ubuntu's AppIndicator): the way back to the note, since it isn't in Alt+Tab or the dock
function createTray() {
	tray = new Tray(nativeImage.createFromPath(path.join(__dirname, "icon.png")).resize({ width: 22, height: 22 }));
	tray.setToolTip("Sticky Notes");
	tray.on("click", () => (win.isVisible() ? win.hide() : showWindow()));
	updateTray();
}

function updateTray() {
	if (!tray) return;
	const visible = win.isVisible() && !win.isMinimized();
	tray.setContextMenu(
		Menu.buildFromTemplate([
			{ label: visible ? "Hide notes" : "Show notes", click: () => (visible ? win.hide() : showWindow()) },
			{ type: "separator" },
			{ label: "Quit", click: () => app.quit() },
		]),
	);
}

function create() {
	win = new BrowserWindow({
		...initialBounds(),
		minWidth: 240,
		minHeight: 220,
		frame: false,
		transparent: true,
		resizable: true,
		alwaysOnTop: state.onTop !== false,
		// Not in Alt+Tab or the dock (it's always on screen anyway): the top bar icon brings it back when hidden
		skipTaskbar: true,
		title: "Sticky Notes",
		icon: path.join(__dirname, "icon.png"),
		backgroundColor: "#00000000",
		webPreferences: { preload: path.join(__dirname, "preload.js"), contextIsolation: true, nodeIntegration: false },
	});
	// Above full-screen apps too
	win.setAlwaysOnTop(state.onTop !== false, "floating");
	win.loadFile(path.join(__dirname, "index.html"));
	const remember = () => {
		if (!win.isMinimized()) {
			state.bounds = win.getBounds();
			save();
		}
	};
	win.on("moved", remember);
	win.on("resized", remember);
	win.on("close", remember);
	// Linux applies "skip taskbar" (which also keeps it out of Alt+Tab) only to a mapped window: set it on every show
	const skipTaskbar = () => {
		win.setSkipTaskbar(true);
		if (process.platform === "linux") {
			// Electron's call doesn't reach GNOME: ask the window manager directly (skip-taskbar.py)
			const handle = win.getNativeWindowHandle();
			const xid = handle.length >= 8 ? Number(handle.readBigUInt64LE(0)) : handle.readUInt32LE(0);
			execFile("python3", [path.join(__dirname, "skip-taskbar.py"), String(xid)], () => {});
		}
	};
	win.on("ready-to-show", skipTaskbar);
	win.on("show", () => {
		skipTaskbar();
		setTimeout(skipTaskbar, 200);
		updateTray();
	});
	win.webContents.on("did-finish-load", skipTaskbar);
	win.on("hide", updateTray);
}

app.on("second-instance", () => {
	if (win) {
		showWindow();
	}
});

ipcMain.handle("items:get", () => ({ items: state.items, machines: state.machines, tab: state.tab || "todo", onTop: state.onTop !== false }));
ipcMain.handle("machines:set", (_e, machines) => {
	const before = new Map(state.machines.map((m) => [m.id, m]));
	for (const m of machines) m.created ||= before.get(m.id)?.created || Date.now();
	markChanges("machine", state.machines, machines);
	state.machines = machines;
	save();
});
ipcMain.handle("tab:set", (_e, tab) => {
	state.tab = tab;
	save();
});
ipcMain.handle("clipboard:write", (_e, text) => clipboard.writeText(String(text)));
ipcMain.handle("items:set", (_e, items) => {
	markChanges("item", state.items, items);
	state.items = items;
	save();
});
ipcMain.handle("window:onTop", (_e, onTop) => {
	state.onTop = onTop;
	win.setAlwaysOnTop(onTop, "floating");
	save();
	return onTop;
});
// Hidden, not minimized: it has no dock entry to come back from; the top bar icon (or starting it again) shows it
ipcMain.handle("window:minimize", () => win.hide());
ipcMain.handle("window:close", () => win.close());
// A reminder is due: the note comes back in front of everything, flashes in the taskbar, and the desktop notifies
ipcMain.handle("alarm", (_e, text) => {
	if (win.isMinimized()) {
		win.restore();
	}
	win.show();
	win.setAlwaysOnTop(true, "floating");
	win.moveTop();
	win.focus();
	win.flashFrame(true);
	if (Notification.isSupported()) {
		const n = new Notification({ title: "Reminder", body: text, icon: path.join(__dirname, "icon.png"), urgency: "critical" });
		n.on("click", () => {
			win.show();
			win.focus();
		});
		n.show();
	}
});
// Back to the pin setting once the alarm is acknowledged
ipcMain.handle("alarm:done", () => {
	win.flashFrame(false);
	win.setAlwaysOnTop(state.onTop !== false, "floating");
});

// ------------------------------------------------------------------------------------------------ sync
// To-dos and machines sync with the other devices through the PHP backend, set in sync.json in the data folder:
// { "url": "https://…/sync.php", "token": "…" }. Reminders (remindAt, ringing) and the window stay on this computer.
// state.dirty: "item:<id>" / "machine:<id>" changed here and not yet on the server (kept across restarts, so offline
// changes go up later). state.rev: the last server revision seen.
const SYNC_FILE = () => path.join(app.getPath("userData"), "sync.json");
const SYNC_EVERY = 5000;

function syncConfig() {
	try {
		const config = JSON.parse(fs.readFileSync(SYNC_FILE(), "utf8"));
		return config.url && config.token ? config : null;
	} catch {
		return null;
	}
}

// What the other devices get of a record
const shared = {
	item: (i) => ({ text: i.text, created: i.created }),
	machine: (m) => ({ name: m.name, ip: m.ip, locked: !!m.locked, draftAppliedAt: m.draftAppliedAt || null, created: m.created }),
};
const same = (type, a, b) => JSON.stringify(shared[type](a)) === JSON.stringify(shared[type](b));

// A new list from the window: whatever was added, changed (in its shared fields) or removed goes up
function markChanges(type, before, after) {
	const old = new Map(before.map((r) => [r.id, r]));
	for (const r of after) {
		if (!old.has(r.id) || !same(type, old.get(r.id), r)) {
			state.dirty[`${type}:${r.id}`] = uid();
		}
		old.delete(r.id);
	}
	for (const id of old.keys()) {
		state.dirty[`${type}:${id}`] = uid();
	}
	if (Object.keys(state.dirty).length) {
		scheduleSync(600);
	}
}

// The other devices' changes, except for records changed here since (those go up next); returns what was applied
function applyRemote(records) {
	const applied = [];
	for (const r of records) {
		if (state.dirty[`${r.type}:${r.id}`]) continue;
		const list = r.type === "item" ? state.items : state.machines;
		const index = list.findIndex((x) => x.id === r.id);
		if (r.deleted) {
			if (index >= 0) {
				list.splice(index, 1);
				applied.push(r);
			}
		} else if (index < 0) {
			list.push({ id: r.id, ...r.data });
			applied.push(r);
		} else if (!same(r.type, list[index], { ...list[index], ...r.data })) {
			Object.assign(list[index], r.data);
			applied.push(r);
		}
	}
	if (applied.length) {
		state.items.sort((a, b) => b.created - a.created);
		state.machines.sort((a, b) => a.created - b.created);
	}
	return applied;
}

let syncTimer = null;
let syncing = false;

function scheduleSync(ms) {
	clearTimeout(syncTimer);
	syncTimer = setTimeout(syncNow, ms);
}

async function syncNow() {
	clearTimeout(syncTimer);
	const config = syncConfig();
	if (!config || syncing) {
		scheduleSync(SYNC_EVERY);
		return;
	}
	syncing = true;
	try {
		// Never synced: everything here goes up
		if (state.rev === undefined) {
			for (const i of state.items) state.dirty[`item:${i.id}`] ||= uid();
			for (const m of state.machines) state.dirty[`machine:${m.id}`] ||= uid();
		}
		const sent = { ...state.dirty };
		const changes = Object.keys(sent).map((key) => {
			const [type, id] = [key.slice(0, key.indexOf(":")), key.slice(key.indexOf(":") + 1)];
			const record = (type === "item" ? state.items : state.machines).find((r) => r.id === id);
			return record ? { type, id, data: shared[type](record) } : { type, id, deleted: true };
		});
		const res = await fetch(config.url, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ token: config.token, since: state.rev || 0, changes }),
			signal: AbortSignal.timeout(15000),
		});
		if (!res.ok) throw new Error(`sync: HTTP ${res.status}`);
		const reply = await res.json();
		// Up, unless changed again meanwhile
		for (const [key, version] of Object.entries(sent)) {
			if (state.dirty[key] === version) delete state.dirty[key];
		}
		const applied = applyRemote(reply.changes);
		if (applied.length) {
			win?.webContents.send("remote", applied);
		}
		state.rev = reply.rev;
		save();
	} catch (e) {
		// Offline or the server is down: the changes stay marked and go next time
		console.warn(e.message);
	} finally {
		syncing = false;
		scheduleSync(SYNC_EVERY);
	}
}

app.whenReady().then(() => {
	create();
	createTray();
	syncNow();
});
app.on("before-quit", saveNow);
app.on("window-all-closed", () => app.quit());
