// The list: add at the top with Enter, tick to finish (it leaves after a moment, Undo brings it back),
// double-click to edit, × to delete. Every change is saved at once.
const list = document.getElementById("list");
const input = document.getElementById("new");
const count = document.getElementById("count");
const toast = document.getElementById("toast");
const toastText = document.getElementById("toastText");
const pin = document.getElementById("pin");

const DONE_DELAY = 3500; // how long a ticked item stays before leaving
let items = []; // { id, text, created, remindAt?, ringing? }
let removed = []; // what Undo brings back: [{ item, index }]
let toastTimer = null;
const leaving = new Map(); // id -> timer

const persist = () => window.notes.set(items);
const uid = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 7);

function age(ms) {
	const m = Math.floor((Date.now() - ms) / 60000);
	if (m < 1) return "now";
	if (m < 60) return `${m}m`;
	const h = Math.floor(m / 60);
	if (h < 24) return `${h}h`;
	return `${Math.floor(h / 24)}d`;
}

// Rows already on screen don't fade in again when the list is redrawn
const shown = new Set();

function render() {
	list.textContent = "";
	count.textContent = items.length;
	if (!items.length) {
		const empty = document.createElement("div");
		empty.className = "empty";
		empty.textContent = "All done ✓";
		list.appendChild(empty);
		return;
	}
	for (const item of items) {
		list.appendChild(row(item));
	}
}

function row(item) {
	const li = document.createElement("li");
	li.dataset.id = item.id;
	if (!shown.has(item.id)) {
		li.classList.add("new");
		shown.add(item.id);
	}
	if (leaving.has(item.id)) li.classList.add("done");

	const check = document.createElement("button");
	check.className = "check";
	check.title = "Done";
	check.innerHTML = '<svg viewBox="0 0 20 20"><rect class="box" x="2" y="2" width="16" height="16" rx="5"/><path class="tick" d="M5.5 10.5l3 3 6-7"/></svg>';
	check.onclick = () => toggleDone(item.id, li);

	const text = document.createElement("div");
	text.className = "text";
	text.textContent = item.text;
	text.ondblclick = () => edit(item, text);

	const when = document.createElement("span");
	when.className = "age";
	setWhen(when, item);

	const bell = document.createElement("button");
	bell.className = `icon bell${item.remindAt ? " set" : ""}`;
	bell.title = item.remindAt ? `Reminder at ${clock(item.remindAt)} (click to change)` : "Remind me";
	bell.innerHTML = BELL;
	bell.onclick = (e) => {
		e.stopPropagation();
		openPicker(item, bell);
	};
	if (item.ringing) {
		li.classList.add("ringing");
		li.onclick = () => stopRinging(item);
	}

	const del = document.createElement("button");
	del.className = "icon del";
	del.title = "Delete";
	del.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M18 6 6 18M6 6l12 12"/></svg>';
	del.onclick = () => remove(item.id, "Deleted");

	li.append(check, text, when, bell, del);
	return li;
}

// ------------------------------------------------------------------------------------------------ reminders
const BELL = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/></svg>';
const clock = (ms) => new Date(ms).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
let picker = null;
let chimeTimer = null;

// The age, or the time left on a reminder ("in 4:59"), or "now!" while it rings
function setWhen(el, item) {
	if (item.ringing) {
		el.textContent = "now!";
		el.className = "age due";
		return;
	}
	if (item.remindAt) {
		const left = Math.max(0, item.remindAt - Date.now());
		const m = Math.floor(left / 60000);
		const s = Math.floor((left % 60000) / 1000);
		el.textContent = m >= 60 ? `⏰ ${clock(item.remindAt)}` : `⏰ ${m}:${String(s).padStart(2, "0")}`;
		el.className = "age timer";
		el.title = `Reminder at ${clock(item.remindAt)}`;
		return;
	}
	el.textContent = age(item.created);
	el.className = "age";
	el.title = new Date(item.created).toLocaleString();
}

function setReminder(item, at) {
	item.remindAt = at;
	item.ringing = false;
	persist();
	render();
}

// 5 / 10 / 15 / 30 minutes, or a custom one: minutes ("45") or a time of day ("14:30")
function openPicker(item, anchor) {
	closePicker();
	picker = document.createElement("div");
	picker.className = "picker";
	picker.onclick = (e) => e.stopPropagation();
	for (const m of [5, 10, 15, 30]) {
		const b = document.createElement("button");
		b.textContent = `${m} min`;
		b.onclick = () => {
			setReminder(item, Date.now() + m * 60000);
			closePicker();
		};
		picker.appendChild(b);
	}
	const custom = document.createElement("input");
	custom.placeholder = "45 or 14:30";
	custom.title = "Minutes from now, or a time of day";
	custom.onkeydown = (e) => {
		if (e.key === "Escape") {
			closePicker();
		}
		if (e.key !== "Enter") {
			return;
		}
		const v = custom.value.trim();
		let at = null;
		const t = /^(\d{1,2})[:h.](\d{2})$/.exec(v);
		if (t) {
			const d = new Date();
			d.setHours(Number(t[1]), Number(t[2]), 0, 0);
			if (d.getTime() <= Date.now()) {
				d.setDate(d.getDate() + 1); // that time tomorrow
			}
			at = d.getTime();
		} else if (/^\d+$/.test(v) && Number(v) > 0) {
			at = Date.now() + Number(v) * 60000;
		}
		if (at) {
			setReminder(item, at);
			closePicker();
		} else {
			custom.classList.add("bad");
		}
	};
	picker.appendChild(custom);
	if (item.remindAt) {
		const off = document.createElement("button");
		off.className = "off";
		off.textContent = "Remove";
		off.onclick = () => {
			setReminder(item, undefined);
			closePicker();
		};
		picker.appendChild(off);
	}
	document.querySelector(".paper").appendChild(picker);
	// Below the bell, kept inside the note
	const paper = document.querySelector(".paper").getBoundingClientRect();
	const a = anchor.getBoundingClientRect();
	const top = a.bottom - paper.top + 4;
	picker.style.top = `${Math.min(top, paper.height - picker.offsetHeight - 8)}px`;
	picker.style.right = "10px";
	custom.focus();
}

function closePicker() {
	picker?.remove();
	picker = null;
}
document.addEventListener("click", closePicker);

// A soft two-note chime (no sound file needed)
function chime() {
	const ctx = (chime.ctx ||= new AudioContext());
	const now = ctx.currentTime;
	for (const [i, f] of [[0, 880], [1, 1318.5]]) {
		const o = ctx.createOscillator();
		const g = ctx.createGain();
		o.type = "sine";
		o.frequency.value = f;
		g.gain.setValueAtTime(0, now + i * 0.18);
		g.gain.linearRampToValueAtTime(0.25, now + i * 0.18 + 0.02);
		g.gain.exponentialRampToValueAtTime(0.001, now + i * 0.18 + 0.9);
		o.connect(g).connect(ctx.destination);
		o.start(now + i * 0.18);
		o.stop(now + i * 0.18 + 1);
	}
}

function ring(item) {
	item.remindAt = undefined;
	item.ringing = true;
	persist();
	render();
	window.notes.alarm(item.text);
	chime();
	clearInterval(chimeTimer);
	chimeTimer = setInterval(() => (items.some((i) => i.ringing) ? chime() : clearInterval(chimeTimer)), 4000);
}

// Clicking a ringing item stops it (the item stays on the list)
function stopRinging(item) {
	item.ringing = false;
	persist();
	render();
	if (!items.some((i) => i.ringing)) {
		clearInterval(chimeTimer);
		window.notes.alarmDone();
	}
}

// Every second: due reminders ring, countdowns move
setInterval(() => {
	const now = Date.now();
	for (const item of items) {
		if (item.remindAt && item.remindAt <= now && !item.ringing) {
			ring(item);
		}
	}
	for (const li of list.querySelectorAll("li")) {
		const item = items.find((i) => i.id === li.dataset.id);
		if (item?.remindAt) {
			setWhen(li.querySelector(".age"), item);
		}
	}
}, 1000);

function add(text) {
	text = text.trim();
	if (!text) return;
	items.unshift({ id: uid(), text, created: Date.now() });
	persist();
	render();
}

// Ticked: struck through for a moment (tick again to keep it), then it leaves
function toggleDone(id, li) {
	if (leaving.has(id)) {
		clearTimeout(leaving.get(id));
		leaving.delete(id);
		li.classList.remove("done");
		return;
	}
	li.classList.add("done");
	leaving.set(
		id,
		setTimeout(() => {
			leaving.delete(id);
			li.classList.add("leaving");
			setTimeout(() => remove(id, "Done"), 250);
		}, DONE_DELAY),
	);
}

function remove(id, verb) {
	const index = items.findIndex((i) => i.id === id);
	if (index < 0) return;
	removed.push({ item: items[index], index });
	items[index].ringing = false;
	items.splice(index, 1);
	if (!items.some((i) => i.ringing)) {
		clearInterval(chimeTimer);
		window.notes.alarmDone();
	}
	persist();
	render();
	showToast(`${verb}: ${items.length === 0 ? "list clear" : truncate(removed[removed.length - 1].item.text)}`);
}

function undo() {
	const last = removed.pop();
	if (!last) return;
	items.splice(Math.min(last.index, items.length), 0, last.item);
	persist();
	render();
	hideToast();
}

function edit(item, el) {
	el.contentEditable = "true";
	el.focus();
	document.getSelection().selectAllChildren(el);
	const finish = (save) => {
		el.contentEditable = "false";
		el.onkeydown = el.onblur = null;
		const text = el.textContent.trim();
		if (!save) {
			el.textContent = item.text;
		} else if (!text) {
			remove(item.id, "Deleted");
		} else if (text !== item.text) {
			item.text = text;
			persist();
		}
	};
	el.onkeydown = (e) => {
		if (e.key === "Enter" && !e.shiftKey) {
			e.preventDefault();
			finish(true);
		} else if (e.key === "Escape") {
			finish(false);
		}
	};
	el.onblur = () => finish(true);
}

function truncate(s) {
	return s.length > 28 ? `${s.slice(0, 27)}…` : s;
}

function showToast(text) {
	toastText.textContent = text;
	toast.classList.add("show");
	clearTimeout(toastTimer);
	toastTimer = setTimeout(hideToast, 5000);
}

function hideToast() {
	toast.classList.remove("show");
}

input.addEventListener("keydown", (e) => {
	if (e.key === "Enter") {
		add(input.value);
		input.value = "";
	} else if (e.key === "Escape") {
		input.value = "";
		input.blur();
	}
});

// Typing anywhere writes a new item; Ctrl+Z brings back the last one that left
document.addEventListener("keydown", (e) => {
	if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "z" && document.activeElement !== input && !document.activeElement.isContentEditable) {
		e.preventDefault();
		undo();
		return;
	}
	if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "n") {
		e.preventDefault();
		input.focus();
		return;
	}
	const typing = e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey;
	// (the Machines tab has its own fields)
	if (typing && tab === "todo" && document.activeElement.tagName !== "INPUT" && !document.activeElement.isContentEditable) {
		input.focus();
	}
});

document.getElementById("undo").onclick = undo;
document.getElementById("min").onclick = () => window.notes.minimize();
document.getElementById("close").onclick = () => window.notes.close();
pin.onclick = async () => {
	const on = await window.notes.setOnTop(!pin.classList.contains("on"));
	pin.classList.toggle("on", on);
	pin.title = on ? "Kept on top (click to release)" : "Keep on top";
};

// ------------------------------------------------------------------------------------------------ sync
// Changes from the other devices (main has them already): merged into the list in place, keeping this computer's
// reminders. Not while something is being edited or the reminder picker is open: they wait until it's done.
let incoming = [];

function mergeRemote(list, records, type) {
	for (const r of records.filter((x) => x.type === type)) {
		const index = list.findIndex((x) => x.id === r.id);
		if (r.deleted) {
			if (index >= 0) list.splice(index, 1);
		} else if (index >= 0) {
			Object.assign(list[index], r.data);
		} else {
			list.push({ id: r.id, ...r.data });
		}
	}
}

function busy() {
	return document.activeElement?.isContentEditable || !!picker;
}

function applyIncoming() {
	if (!incoming.length) return;
	if (busy()) {
		setTimeout(applyIncoming, 1000);
		return;
	}
	const records = incoming;
	incoming = [];
	mergeRemote(items, records, "item");
	items.sort((a, b) => b.created - a.created);
	render();
	if (typeof onRemoteMachines === "function") onRemoteMachines(records);
}

window.notes.onRemote((records) => {
	const waiting = incoming.length > 0;
	incoming.push(...records);
	if (!waiting) applyIncoming();
});

// The ages ("5m", "2h") stay current
setInterval(() => {
	for (const li of list.querySelectorAll("li")) {
		const item = items.find((i) => i.id === li.dataset.id);
		if (item) setWhen(li.querySelector(".age"), item);
	}
}, 60000);

window.notes.get().then(({ items: saved, onTop }) => {
	items = saved || [];
	pin.classList.toggle("on", onTop);
	pin.title = onTop ? "Kept on top (click to release)" : "Keep on top";
	render();
	input.focus();
	for (const item of items) {
		if (item.ringing) {
			item.ringing = false;
			item.remindAt = Date.now();
		}
	}
});
