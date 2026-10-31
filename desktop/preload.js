const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("notes", {
	get: () => ipcRenderer.invoke("items:get"),
	set: (items) => ipcRenderer.invoke("items:set", items),
	setMachines: (machines) => ipcRenderer.invoke("machines:set", machines),
	setTab: (tab) => ipcRenderer.invoke("tab:set", tab),
	copy: (text) => ipcRenderer.invoke("clipboard:write", text),
	setOnTop: (onTop) => ipcRenderer.invoke("window:onTop", onTop),
	minimize: () => ipcRenderer.invoke("window:minimize"),
	close: () => ipcRenderer.invoke("window:close"),
	alarm: (text) => ipcRenderer.invoke("alarm", text),
	alarmDone: () => ipcRenderer.invoke("alarm:done"),
	// Records changed on the other devices: [{ type: "item" | "machine", id, deleted, data }]
	onRemote: (callback) => ipcRenderer.on("remote", (_e, records) => callback(records)),
});
