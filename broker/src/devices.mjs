import { resolve } from "node:path";
import { DeviceStore } from "./server.mjs";

const dataFile = resolve(process.env.CMUX_BROKER_DATA_DIR ?? "./data", "devices.json");
const store = new DeviceStore(dataFile);
await store.load();

const [command, deviceId] = process.argv.slice(2);
switch (command) {
case "list":
  for (const device of store.allDevices()) {
    console.log([
      device.device_id,
      device.relay_id,
      device.device_name,
      device.registered_at,
    ].join("\t"));
  }
  break;
case "revoke":
  if (!deviceId) {
    console.error("usage: npm run devices -- revoke <device-id>");
    process.exitCode = 2;
    break;
  }
  if (await store.revoke(deviceId)) {
    console.log(`revoked ${deviceId}`);
  } else {
    console.error(`unknown device: ${deviceId}`);
    process.exitCode = 1;
  }
  break;
default:
  console.error("usage: npm run devices -- <list|revoke DEVICE_ID>");
  process.exitCode = 2;
}
