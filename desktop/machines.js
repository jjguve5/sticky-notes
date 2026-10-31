// Machines tab: people's machines by name and IP (click the IP to copy it) and whether I locked them.
// Add with a name + IP (Enter), × deletes (Undo brings it back), the lock toggles. The draft icon: hover shows when I
// last applied their draft, click stamps it now (Undo takes it back); green when it was today.
const mlist = document.getElementById("mlist");
const mname = document.getElementById("mname");
const mip = document.getElementById("mip");
const mcount = document.getElementById("mcount");
let machines = [];
let tab = "todo";

const LOCK_CLOSED = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>';
const LOCK_OPEN = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 7.5-1.9"/></svg>';

const DRAFT_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/><path d="m9 14 2 2 4-4"/></svg>';

const saveMachines = () => window.notes.setMachines(machines);

// Rows already on screen don't fade in again when the list is redrawn
const shownMachines = new Set();
// The draft buttons on screen, so their "x min ago" can be updated in place
let drafts = new Map();

function draftState(draft, m) {
	const today = m.draftAppliedAt && new Date(m.draftAppliedAt).toDateString() === new Date().toDateString();
	draft.className = "draft" + (m.draftAppliedAt ? " set" : "") + (today ? " today" : "");
	draft.dataset.tip = m.draftAppliedAt
		? `Draft applied ${ago(m.draftAppliedAt)} · ${stamp(m.draftAppliedAt)}\nClick when you apply a new one`
		: "No draft applied yet\nClick when you apply one";
	draft.setAttribute("aria-label", draft.dataset.tip);
}

function renderMachines() {
	mlist.textContent = "";
	drafts = new Map();
	const locked = machines.filter((m) => m.locked).length;
	mcount.textContent = locked ? `${locked} 🔒` : machines.length;
	if (!machines.length) {
		const empty = document.createElement("div");
		empty.className = "empty";
		empty.textContent = "No machines yet";
		mlist.appendChild(empty);
		return;
	}
	for (const m of machines) {
		const li = document.createElement("li");
		li.classList.toggle("locked", !!m.locked);
		if (!shownMachines.has(m.id)) {
			li.classList.add("new");
			shownMachines.add(m.id);
		}

		const lock = document.createElement("button");
		lock.className = "lock";
		lock.title = m.locked ? "Locked (click when you unlock it)" : "Not locked (click when you lock it)";
		lock.innerHTML = m.locked ? LOCK_CLOSED : LOCK_OPEN;
		lock.onclick = () => {
			m.locked = !m.locked;
			saveMachines();
			renderMachines();
		};

		const name = document.createElement("div");
		name.className = "mname text";
		name.textContent = m.name;
		name.title = "Double-click to rename";
		name.ondblclick = () => editMachine(m, name, "name");

		const state = document.createElement("span");
		state.className = "mstate";
		state.textContent = m.locked ? "locked" : "";

		const ip = document.createElement("button");
		ip.className = "ip";
		ip.textContent = m.ip;
		ip.title = "Click to copy · double-click to change";
		let clickTimer = null;
		ip.onclick = () => {
			clearTimeout(clickTimer);
			clickTimer = setTimeout(() => {
				window.notes.copy(m.ip);
				ip.classList.add("copied");
				ip.textContent = "copied";
				setTimeout(() => {
					ip.classList.remove("copied");
					ip.textContent = m.ip;
				}, 900);
			}, 220);
		};
		ip.ondblclick = () => {
			clearTimeout(clickTimer);
			editMachine(m, ip, "ip");
		};

		const del = document.createElement("button");
		del.className = "icon del";
		del.title = "Delete";
		del.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M18 6 6 18M6 6l12 12"/></svg>';
		del.onclick = () => removeMachine(m);

		const draft = document.createElement("button");
		draft.innerHTML = DRAFT_ICON;
		draftState(draft, m);
		draft.onclick = () => applyDraft(m);
		drafts.set(draft, m);

		li.append(lock, name, state, draft, ip, del);
		mlist.appendChild(li);
	}
}

// "5 min ago", "3 h ago", "yesterday", "4 days ago"
function ago(time) {
	const minutes = Math.floor((Date.now() - time) / 60000);
	if (minutes < 1) return "just now";
	if (minutes < 60) return `${minutes} min ago`;
	const hours = Math.floor(minutes / 60);
	const sameDay = new Date(time).toDateString() === new Date().toDateString();
	if (sameDay || hours < 12) return `${hours} h ago`;
	const days = Math.round((new Date().setHours(0, 0, 0, 0) - new Date(time).setHours(0, 0, 0, 0)) / 86400000);
	return days <= 1 ? "yesterday" : `${days} days ago`;
}

// "14:30" today, else "Tue 21 Oct 14:30"
function stamp(time) {
	const d = new Date(time);
	const hm = d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
	if (d.toDateString() === new Date().toDateString()) return hm;
	return `${d.toLocaleDateString([], { weekday: "short", day: "numeric", month: "short" })} ${hm}`;
}

let undoDraft = null;
function applyDraft(m) {
	undoDraft = { m, previous: m.draftAppliedAt || null };
	removedMachine = null;
	m.draftAppliedAt = Date.now();
	saveMachines();
	renderMachines();
	showToast(`Draft applied: ${m.name}`);
}

// The "x min ago" texts stay current, updated in place (no redraw)
setInterval(() => {
	for (const [draft, m] of drafts) draftState(draft, m);
}, 60000);

function addMachine() {
	const name = mname.value.trim();
	const ip = mip.value.trim();
	if (!name || !ip) {
		(name ? mip : mname).focus();
		return;
	}
	machines.push({ id: uid(), name, ip, locked: false, created: Date.now() });
	saveMachines();
	renderMachines();
	mname.value = mip.value = "";
	mname.focus();
}

let removedMachine = null;
function removeMachine(m) {
	const index = machines.indexOf(m);
	machines.splice(index, 1);
	removedMachine = { m, index };
	undoDraft = null;
	saveMachines();
	renderMachines();
	showToast(`Deleted: ${m.name}`);
}

function editMachine(m, el, field) {
	el.contentEditable = "true";
	el.focus();
	document.getSelection().selectAllChildren(el);
	const finish = (save) => {
		el.contentEditable = "false";
		el.onkeydown = el.onblur = null;
		const value = el.textContent.trim();
		if (save && value) {
			m[field] = value;
			saveMachines();
		}
		renderMachines();
	};
	el.onkeydown = (e) => {
		if (e.key === "Enter") {
			e.preventDefault();
			finish(true);
		} else if (e.key === "Escape") {
			finish(false);
		}
	};
	el.onblur = () => finish(true);
}

for (const input of [mname, mip]) {
	input.addEventListener("keydown", (e) => {
		if (e.key === "Enter") {
			e.preventDefault();
			if (input === mname && !mip.value.trim()) {
				mip.focus();
			} else {
				addMachine();
			}
		} else if (e.key === "Escape") {
			input.value = "";
			input.blur();
		}
	});
}

// Undo also brings back a deleted machine (the to-do Undo button and Ctrl+Z)
const undoTodo = undo;
undo = function () {
	if (tab === "machines" && undoDraft) {
		undoDraft.m.draftAppliedAt = undoDraft.previous;
		undoDraft = null;
		saveMachines();
		renderMachines();
		hideToast();
		return;
	}
	if (tab === "machines" && removedMachine) {
		machines.splice(Math.min(removedMachine.index, machines.length), 0, removedMachine.m);
		removedMachine = null;
		saveMachines();
		renderMachines();
		hideToast();
		return;
	}
	undoTodo();
};
document.getElementById("undo").onclick = () => undo();

function showTab(name) {
	tab = name;
	for (const t of document.querySelectorAll(".tab")) {
		t.classList.toggle("active", t.dataset.tab === name);
	}
	document.getElementById("todoView").classList.toggle("hidden", name !== "todo");
	document.getElementById("machinesView").classList.toggle("hidden", name !== "machines");
	window.notes.setTab(name);
	(name === "todo" ? input : mname).focus();
}
for (const t of document.querySelectorAll(".tab")) {
	t.onclick = () => showTab(t.dataset.tab);
}

// Machines changed on the other devices (called by renderer.js once nothing is being edited)
function onRemoteMachines(records) {
	if (!records.some((r) => r.type === "machine")) return;
	mergeRemote(machines, records, "machine");
	machines.sort((a, b) => a.created - b.created);
	renderMachines();
}

window.notes.get().then((data) => {
	machines = data.machines || [];
	renderMachines();
	showTab(data.tab || "todo");
});
